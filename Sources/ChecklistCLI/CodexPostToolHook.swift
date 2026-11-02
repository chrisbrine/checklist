import Foundation
import Darwin
import ChecklistIPC
import ChecklistBridges
import ChecklistMCPServer
import MCP

/// A command hook is an observation channel, never an acknowledgment. Delivery is at least
/// once: pickup reads and stamps nothing, this adapter writes stdout, and only then does a
/// confirmation stamp the deliveries. A lost output or a failed confirmation shows the note
/// again at a later tool call. A note can repeat for 24 hours after its creation (the pickup
/// rule in Core), and it stays in the inbox after that.
enum CodexPostToolHook {
    static let command = "codex-post-tool"
    static let timeLimit: TimeInterval = 1.5
    /// Starts after stdout has the bytes, so a slow read cannot cut off the confirmation.
    /// Read and confirmation together stay under the 3-second `timeout` of the hook setup.
    static let confirmLimit: TimeInterval = 1.0
    static let hostTimeout: TimeInterval = 3
    static let inputLimit = 1_048_576

    static func main(_ arguments: [String]) async {
        signal(SIGPIPE, SIG_IGN)
        let log: @Sendable (String) -> Void = { try? FileHandle.standardError.write(contentsOf: Data("Checklist hook: \($0)\n".utf8)) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        // This also bounds native discovery and blocked stdout; returning from a
        // task group would still wait for an uncooperative synchronous operation.
        let watchdog = HookWatchdog(limit: timeLimit) { log("time budget expired; context delivery is unconfirmed"); _exit(0) }
        defer { watchdog.cancel() }
        do {
            guard arguments == [command] else { throw CLIError("Usage: checklist codex-post-tool; no identity or workspace arguments are accepted.") }
            let input = try readInput(.standardInput, deadline: deadline)
            let hookSessionID = try validateInput(input)
            let bridge = makeBridge(hookSessionID: hookSessionID)
            let reply = try await bridge.codexHookPickup(timeBudget: max(0, deadline - ProcessInfo.processInfo.systemUptime), hookSessionID: hookSessionID)
            // FileHandle.write calls write(2) with no user-space buffer, so a return means stdout has the bytes.
            try await deliverBounded(reply, watchdog: watchdog, write: { try FileHandle.standardOutput.write(contentsOf: $0) }, confirm: { ids, budget in
                let result = try await bridge.codexHookConfirm(deliveryIDs: ids, timeBudget: budget)
                if !confirmationRecorded(result) { log("confirmation was refused; these notes show again at a later tool call") }
            })
        } catch { log(error.localizedDescription) }
    }

    @discardableResult static func validateInput(_ input: Data) throws -> String {
        guard input.count <= inputLimit,
              let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["hook_event_name"] as? String == "PostToolUse",
              let session = object["session_id"] as? String, let id = UUID(uuidString: session) else {
            throw CLIError("Expected a bounded PostToolUse JSON object.")
        }
        // session_id only selects among rollouts that the native process holds by kernel
        // descriptor. It cannot name another. transcript_path, cwd and tool text are untrusted.
        // Native discovery uses this process's kernel ancestry and actual cwd.
        return id.uuidString.lowercased()
    }

    static func readInput(_ input: FileHandle, deadline: TimeInterval) throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CLIError("Hook stdin timed out.") }
            var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw CLIError("Hook stdin did not finish within its budget.") }
            let count = Darwin.read(input.fileDescriptor, &bytes, min(bytes.count, inputLimit + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CLIError("Hook stdin could not be read.") }
            if count == 0 { return result }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= inputLimit else { throw CLIError("Hook stdin exceeds 1 MiB.") }
        }
    }

    /// Nothing pending: no output and no confirmation, so nothing is written anywhere.
    static func deliver(_ reply: Value, write: (Data) throws -> Void, confirm: ([String]) async throws -> Void) async throws {
        let items = try pendingItems(reply).items
        guard let output = try output(reply) else { return }
        try write(output)
        try await confirm(items.compactMap { $0["delivery_id"] as? String })
    }

    /// After stdout has the bytes, the confirmation gets `confirmLimit`, whatever time the read used.
    static func deliverBounded(_ reply: Value, watchdog: HookWatchdog, write: (Data) throws -> Void, confirm: ([String], TimeInterval) async throws -> Void) async throws {
        try await deliver(reply, write: { try write($0); watchdog.extend(confirmLimit) }, confirm: { try await confirm($0, confirmLimit) })
    }

    static func confirmationRecorded(_ reply: Value) -> Bool {
        guard let encoded = try? JSONEncoder().encode(reply),
              let envelope = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let data = envelope["data"] as? [String: Any] else { return false }
        return data["confirmed"] is [Any]
    }

    private static func pendingItems(_ reply: Value) throws -> (pending: [String: Any], items: [[String: Any]]) {
        guard let envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any],
              let data = envelope["data"] as? [String: Any],
              let pending = data["pending_notes"] as? [String: Any],
              let items = pending["items"] as? [[String: Any]] else {
            throw CLIError("The service returned no pending-notes observation.")
        }
        return (pending, items)
    }

    static func output(_ reply: Value) throws -> Data? {
        let (pending, items) = try pendingItems(reply)
        guard !items.isEmpty else { return nil }
        var blocks: [String] = []
        for item in items {
            guard let body = item["body"] as? String,
                  let delivery = item["delivery_id"] as? String,
                  let project = item["project_id"] as? String,
                  let message = item["message_id"] as? String else { throw CLIError("The service returned an incomplete pending note.") }
            blocks.append(try CodexHookNoteContent.render(origin: item["origin"] as? String, authorDisplay: item["author_display"] as? String, projectID: project,
                messageID: message, deliveryID: delivery, subject: item["subject"], body: body, bodyTruncated: item["body_truncated"] as? Bool == true))
        }
        blocks.append(CodexHookNoteContent.footer)
        if pending["has_more"] as? Bool == true { blocks.append("More notes remain. Read checklist call session_inbox '{}' from this project before the next main step.") }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": blocks.joined(separator: "\n\n")]]
        var result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        result.append(0x0a)
        return result
    }

    /// A test supplies the last three arguments. Production uses the defaults.
    static func makeBridge(hookSessionID: String, transport: any LocalCommandTransport = MacOSLocalCommandTransport(),
                           credentials: any LocalCredentialReader = HookCredentialReader(), discovery: NativeSessionDiscovery? = nil) -> Bridge {
        // A pickup needs the credential of the installation that bootstrap just verified for this exact
        // native observation, as `checklist call` does. Bootstrap itself sends no stored credential.
        let platform = LocalPlatformServices(transport: transport, lifecycle: HookLifecycle(), credentials: credentials, supportedCapabilities: [.localCommandTransport, .installationCredentialRead])
        let environment = BridgeEnvironment(makeClient: { config in
            ChecklistClient(installation: config.installation, workspace: config.workspace, nativeContext: config.nativeContext, usesStoredCredential: config.usesStoredCredential, platformServices: platform)
        }, discover: { _ in discovery ?? NativeSessionContext.codexHookDiscovery(hookSessionID: hookSessionID) }, serviceJobRunning: { nil }, startService: { throw CLIError("The hook cannot start the service.") })
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath().path
        return Bridge(configuration: .init(workspace: workspace, command: command), environment: environment)
    }
}

/// One timer. A new limit replaces the earlier limit.
final class HookWatchdog: @unchecked Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    init(limit: TimeInterval, expire: @escaping @Sendable () -> Void) {
        timer.schedule(deadline: .now() + limit)
        timer.setEventHandler(handler: expire)
        timer.resume()
    }
    func extend(_ limit: TimeInterval) { timer.schedule(deadline: .now() + limit) }
    func cancel() { timer.cancel() }
}

/// The hook reads only the credential file. Service bootstrap already migrated the credential,
/// so the hook has no Keychain path (`legacyRead` is nil).
private struct HookCredentialReader: LocalCredentialReader {
    func readInstallationCredential(_ installation: String) throws -> String? {
        try InstallationCredentialStore(root: ChecklistPaths.root, instance: .current, legacyRead: nil).read(installation)
    }
}

private struct HookLifecycle: LocalServiceLifecycle {
    func prepare() throws {}
    func registerInstalledBuild() throws { throw CLIError("The hook cannot register an installation.") }
    func startService(timeLimit: TimeInterval) throws { throw CLIError("The hook cannot start the service.") }
}
