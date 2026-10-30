import Foundation
import MCP
import ChecklistIPC

/// CL-364: `checklist call --wait` and the `operation_wait` tool, so a caller of a long
/// command needs no operation_get loop. This is one adapter-side read loop, with no
/// service state: the operation keeps running whatever the wait does, and a wait that
/// ends early never cancels, rejects or repeats the original command.
public enum OperationWait {
    public static let toolName = "operation_wait"
    public static let defaultCommandLineWait: TimeInterval = 120
    public static let longestCommandLineWait: TimeInterval = 3600
    /// `checklist call --wait` ended without the final reply. The same code as timeout(1).
    public static let unfinishedExitCode: Int32 = 124
    /// Below Codex's default 60 s MCP tool limit, with room for a connection wait.
    public static let longestToolWait: TimeInterval = 45
    /// The whole tool call, including a wait for a service that does not answer.
    static let toolCallLimit: TimeInterval = 55
    /// The last read can start at the deadline.
    static let lastReadAllowance: TimeInterval = 0.5
    private static let firstPause: TimeInterval = 0.1, longestPause: TimeInterval = 2

    static let tool = Tool(name: toolName,
        description: "Wait for a long command that returned command_outcome=accepted, without an operation_get loop. Returns the original command's final reply when the operation succeeds and its error when the operation fails. After wait_seconds (default and maximum \(Int(longestToolWait))) it returns the operation with its state and wait.finished=false: call this tool again with the same operation_id; do not send a new command. Other calls of this conversation run during the wait. A wait never cancels the operation. Each final read of a work_claim, batch_claim or work_takeover operation issues a fresh claim token; use the latest one. Tool descriptions name the commands that can return an operation.",
        inputSchema: .object(["type": .string("object"), "properties": .object([
            "operation_id": .object(["type": .string("string"), "format": .string("uuid")]),
            "project_id": .object(["type": .string("string"), "description": .string("The original command's project.")]),
            "wait_seconds": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(Int(longestToolWait))])
        ]), "required": .array([.string("operation_id"), .string("project_id")]), "additionalProperties": .bool(false)]),
        annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false))

    /// True when a `--wait` reply is the operation, not the command's final reply.
    public static func isUnfinished(_ reply: Value) -> Bool {
        guard case .object(let envelope) = reply, case .object(let wait)? = envelope["wait"], case .bool(false)? = wait["finished"] else { return false }
        return true
    }

    /// A value above the maximum waits the maximum: the reply says so in wait.limit_seconds.
    static func toolSeconds(_ value: Value?, _ refuse: (String) -> ChecklistError) throws -> TimeInterval {
        switch value {
        case nil: return longestToolWait
        case .int(let seconds)? where seconds >= 0: return min(longestToolWait, TimeInterval(seconds))
        case .double(let seconds)? where seconds.isFinite && seconds >= 0: return min(longestToolWait, seconds)
        default: throw refuse("wait_seconds must be a number from 0 to \(Int(longestToolWait)).")
        }
    }

    struct LimitExpired: Error {}

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func resume(_ result: Result<T, Error>) {
            lock.lock(); let waiting = continuation; continuation = nil; lock.unlock()
            waiting?.resume(with: result)
        }
    }

    /// `work` can be a blocking read of a service that does not answer. It can finish
    /// after the limit; its reply is then dropped.
    static func bounded<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(.failure(LimitExpired()))
            }
            Task {
                do { once.resume(.success(try await work())) }
                catch { once.resume(.failure(error)) }
                timer.cancel()
            }
        }
    }

    /// The MCP tool call keeps its bound even when the connection wait does not.
    static func toolCall(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        do { return try await bounded(toolCallLimit, body) }
        catch is LimitExpired {
            throw ChecklistError("SERVICE_NOT_READY", "The Checklist service did not answer within \(Int(toolCallLimit)) s. The operation's state is unknown and the wait did not change it. Call \(toolName) again.", details: ["retryable": true])
        }
    }

    struct Clock: Sendable {
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    }

    private static func object(_ value: Value) throws -> [String: Any] {
        guard let object = try jsonObject(value) as? [String: Any] else { throw BridgeError("INVALID_RESPONSE: Checklist returned no result object.") }
        return object
    }

    /// Reads until a final state or `limit`. `known` is what the caller already has: the
    /// accepted reply, or nil for a wait on an operation ID alone. A read that fails for
    /// any lasting reason ends the wait unfinished, because a status read cannot reject
    /// an accepted command. Without `known` that same failure is the caller's own error.
    static func read(statusMethod: String, known: Value?, identity: [String: String], limit: TimeInterval, clock: Clock = .init(),
                     status: @escaping @Sendable (TimeInterval) async throws -> Value) async throws -> Value {
        let started = clock.now()
        var last = try known.map(object) ?? ["data": identity.merging(["state": "unknown", "status_method": statusMethod]) { old, _ in old }]
        var observed = known != nil, pause = firstPause
        func unfinished(_ reason: String, _ failure: Error? = nil) throws -> Value {
            let data = last["data"] as? [String: Any] ?? [:]
            var wait: [String: Any] = ["finished": false, "reason": reason, "state": data["state"] ?? "unknown",
                                       "limit_seconds": limit, "waited_ms": Int(((clock.now() - started) * 1000).rounded()),
                                       "next": "The command can still be running. Read \(statusMethod) again with the same ID; do not send a new command."]
            if let failure {
                wait["read_error"] = ["code": (failure as? ChecklistError)?.code ?? "unknown", "message": failure.localizedDescription]
            }
            last["wait"] = wait
            return try mcpValue(last)
        }
        var transient: Error?
        while true {
            var reply: [String: Any]?
            do {
                // A delegated read has no reply timeout of its own.
                let budget = max(limit - (clock.now() - started), lastReadAllowance)
                reply = try object(try await bounded(budget) { try await status(budget) })
            }
            catch is LimitExpired { return try unfinished("timed_out", transient) }
            catch let error as ChecklistError where ServiceWait.applies(error) { transient = error } // A restart or a busy service.
            catch let error as CancellationError { throw error }
            catch {
                guard observed else { throw error }
                return try unfinished("read_failed", error)
            }
            if let reply {
                transient = nil
                let data = reply["data"] as? [String: Any] ?? [:]
                switch data["state"] as? String {
                case "succeeded", "applied":
                    if let result = data["result"] as? [String: Any] { return try mcpValue(result) }
                    last = reply
                    return try unfinished("result_unavailable")
                case "failed":
                    // The command's own outcome, in the form of its former synchronous error.
                    let commandID = data["command_id"] as? String
                    var failure: [String: Any] = [:]
                    failure["error"] = data["error"]
                    failure["command_id"] = commandID
                    _ = try CommandReply.decode(try jsonData(failure), method: "", commandID: commandID)
                    throw CommandReply.unknown(commandID: commandID, reason: "invalid_error_envelope")
                case "queued", "running":
                    last = reply; observed = true
                default:
                    last = reply
                    return try unfinished("state_unknown")
                }
            }
            let remaining = limit - (clock.now() - started)
            if remaining <= 0 { return try unfinished("timed_out", transient) }
            try await clock.sleep(min(pause, remaining))
            pause = min(pause * 2, longestPause)
        }
    }
}

extension Bridge {
    /// The MCP `operation_wait` tool; also `checklist call operation_wait`.
    nonisolated func operationWaitTool(_ arguments: Value) async throws -> Value {
        func refuse(_ message: String) -> ChecklistError {
            ChecklistError("INVALID_INPUT", message, details: ["command_outcome": "not_sent", "command_executed": false])
        }
        guard case .object(let fields) = arguments else { throw refuse("Tool arguments must be a JSON object.") }
        guard Set(fields.keys).isSubset(of: ["operation_id", "project_id", "wait_seconds"]) else { throw refuse("Unknown fields are not accepted by this command.") }
        guard case .string(let operation)? = fields["operation_id"], UUID(uuidString: operation) != nil else { throw refuse("operation_id must be a UUID.") }
        let seconds = try OperationWait.toolSeconds(fields["wait_seconds"], refuse)
        var parameters: [String: Value] = ["operation_id": .string(operation)]
        parameters["project_id"] = fields["project_id"]
        let status = Value.object(parameters)
        return try await OperationWait.read(statusMethod: "operation_get", known: nil, identity: ["operation_id": operation], limit: seconds) { budget in
            try await self.statusRead("operation_get", status, budget: budget)
        }
    }

    /// `checklist call --wait`. Replies other than an accepted operation or a queued
    /// write are already final, and pass unchanged.
    public nonisolated func finalReply(to reply: Value, arguments: Value, limit: TimeInterval) async throws -> Value {
        guard case .object(let envelope) = reply, case .string(let outcome)? = envelope["command_outcome"],
              case .object(let data)? = envelope["data"] else { return reply }
        var parameters: [String: Value] = [:]
        let method: String, key: String
        switch outcome {
        case "accepted": (method, key) = ("operation_get", "operation_id")
        case "queued": (method, key) = ("command_status", "command_id")
        default: return reply
        }
        guard case .string(let id)? = data[key] else { return reply }
        parameters[key] = .string(id)
        if case .object(let input) = arguments { parameters["project_id"] = input["project_id"] }
        let status = Value.object(parameters)
        return try await OperationWait.read(statusMethod: method, known: reply, identity: [key: id], limit: limit) { budget in
            try await self.statusRead(method, status, budget: budget)
        }
    }
}
