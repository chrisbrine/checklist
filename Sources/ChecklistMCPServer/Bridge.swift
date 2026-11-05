import CryptoKit
import Foundation
import MCP
import ChecklistIPC
import ChecklistBridges

func jsonData(_ value: Any, pretty: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed])
}

func mcpValue(_ value: Any) throws -> Value {
    try JSONDecoder().decode(Value.self, from: jsonData(value))
}

func jsonObject(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

func responseData(_ response: [String: Any]) -> [String: Any] {
    response["data"] as? [String: Any] ?? response
}

/// The synchronous IPC and installed-shim paths may wait on semaphores or child
/// processes. Keep the actor's serial jobs on a dispatch worker rather than the
/// cooperative executor. Actor isolation still owns all JSON and client state;
/// only the runtime's Sendable job handle crosses to the queue. A connected MCP
/// tool call runs its service request or child CLI off this queue (CL-352).
final class BridgeBlockingExecutor: SerialExecutor {
    let queue = DispatchQueue(label: "org.checklist.mcp.bridge-blocking")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

public actor Bridge {
    enum MCPRequest: Sendable { case tool(Value?), resource, catalog }
    @TaskLocal static var mcpRequest: MCPRequest?

    nonisolated let blockingExecutor = BridgeBlockingExecutor()
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        blockingExecutor.asUnownedSerialExecutor()
    }

    private var client: any BridgeClient
    private let environment: BridgeEnvironment
    private let expectedSession: String?
    private let automatic: Bool
    private let requestedWorkspace: String
    private let assistantProject: String?
    private let command: String
    private let installation: String
    private var delegating = false
    private var launchState = ShimLaunchState.current
    private var updateNoticePending = false
    private var bootstrapResponse: Value?
    /// Selected by Codex wire metadata or the native context of a restart-refused
    /// bootstrap. It never changes, and later calls must identify this same thread.
    private var codexMCPContext: NativeSessionContext?
    private var missingNativeIdentity = false
    private static let nativeIdentityNotice = "This MCP connection is not bound to a native thread because the host supplied no supported native identity at startup. Codex can identify each tool call with host-authored _meta.threadId; a shell connection does not bind this MCP process."
    private var setupContext: NativeSessionContext?
    private var creationNoticePending = false
    private var setupCompletionPending = false
    private var registryStart = ClaudeRegistryStart()
    private(set) var setupNotice: String?
    /// The last MCP connection attempt failed only because the service did not answer.
    private var serviceError: Error?
    /// A hard MCP startup error outside bootstrap; reported as a tool error, never retried.
    private var startupError: Error?
    /// A native evidence refusal has no authority. Only a later identified tool
    /// call may retry it; catalog/resource requests never start a retry or timer.
    private var codexRestartError: ChecklistError?
    private var codexRestartBootstrapRefused = false
    private var codexRestartRetryAt: TimeInterval = 0
    static let codexRestartRetryInterval: TimeInterval = 5
    /// The service wait in progress; concurrent requests share it instead of repeating it.
    private var serviceWaitTask: Task<Bool, Error>?
    public static let serviceWaitLimit: TimeInterval = 60
    static let serviceWaitStep: TimeInterval = 2
    /// The startup connection attempt's reply budget, so initialize answers in about
    /// 3 s even while the service stalls (Codex's default MCP startup limit is 10 s).
    public static let startupConnectBudget: TimeInterval = 2
    private var waitNotice: String? {
        if let serviceError {
            return "This conversation is not connected yet. The Checklist service did not answer (\(serviceError.localizedDescription)) Each request waits for the service and connects by itself; no reconnect is needed."
        }
        if let codexRestartError {
            return "This conversation is not connected yet. " + codexRestartError.localizedDescription
                + " A later tool call with this same _meta.threadId retries the evidence, at most once per 5 s."
        }
        return startupError.map { "This conversation is not connected yet. " + $0.localizedDescription }
    }
    var connectionNotice: String? { waitNotice ?? registryStart.notice ?? (missingNativeIdentity ? Self.nativeIdentityNotice : nil) }
    var connectionStartupNotice: String? { waitNotice ?? registryStart.startupNotice ?? (missingNativeIdentity ? Self.nativeIdentityNotice : nil) }

    public init(configuration: BridgeConfiguration, environment: BridgeEnvironment = .init()) {
        self.environment = environment
        client = environment.makeClient(.init(installation: configuration.installation, workspace: configuration.workspace, usesStoredCredential: !(configuration.automatic && configuration.command == "mcp")))
        expectedSession = configuration.expectedSession
        automatic = configuration.automatic
        requestedWorkspace = configuration.workspace
        assistantProject = configuration.assistantProject
        command = configuration.command
        installation = configuration.installation
    }

    public func reportStartupNotice() {
        if let notice = setupNotice ?? connectionStartupNotice { environment.stderr("Checklist: \(notice)\n") }
    }

    /// `timeBudget` caps each bootstrap attempt's reply budget; nil keeps the client's default.
    public func connect(required: Bool = false, timeBudget: TimeInterval? = nil) throws -> Value? {
        checkInstalledBuild()
        if delegating {
            if automatic, command == "mcp", discover().context == nil { missingNativeIdentity = true }
            return nil
        }
        if let bootstrapResponse { return bootstrapResponse }
        guard automatic else {
            if required { throw BridgeError("Automatic connection uses the current native conversation; omit --installation.") }
            return nil
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath().path
        if cwd != requestedWorkspace, assistantProject == nil, environment.discover(false).registryReason != nil {
            try verifyWorkspace(cwd)
        }
        var start = registryStart
        defer {
            registryStart = start
            if start.error != nil {
                client = environment.makeClient(.init(workspace: requestedWorkspace, usesStoredCredential: false))
            }
        }
        return try start.start(command: command, assistantRelay: assistantProject != nil,
            now: environment.now, sleep: environment.sleep, discover: { self.discover() },
            bootstrap: { observed, budget in
                let capped = timeBudget.map { cap in budget.map { min($0, cap) } ?? cap } ?? budget
                return try self.bootstrap(observed, required: required, timeBudget: capped)
            })
    }

    private func discover() -> NativeSessionDiscovery {
        if let codexMCPContext { return .available(codexMCPContext) }
        return environment.discover(assistantProject != nil)
    }

    /// Called with protocol metadata, never tool arguments. Legacy Codex MCP
    /// connections are private, but each identified call still proves its own
    /// thread and a conflicting caller can never switch this connection.
    func admitMCPTool(threadID: Value?) throws -> Bool {
        guard command == "mcp", automatic, assistantProject == nil else { return false }
        if let context = codexMCPContext {
            guard case .string(let raw)? = threadID, UUID(uuidString: raw) == UUID(uuidString: context.nativeSessionID) else {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "This Codex MCP connection requires its same host-authored _meta.threadId on every tool call. Missing or conflicting metadata cannot use an earlier thread's connection.")
            }
            try verifyWorkspace(context.workspacePath)
            if let expectedSession, UUID(uuidString: expectedSession) != UUID(uuidString: context.nativeSessionID) {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "The bound Codex thread differs from --session; retry cannot select another thread.")
            }
            if delegating { throw ClientUpdateRequired.error }
            if codexRestartError != nil, environment.now() >= codexRestartRetryAt {
                // Actor isolation plus reservation before synchronous bootstrap
                // bounds concurrent calls too. The service rechecks every guard.
                codexRestartRetryAt = environment.now() + Self.codexRestartRetryInterval
                startConnection()
                return bootstrapResponse != nil || setupContext != nil
            }
            return false
        }
        let observed = environment.discover(false).context
        // Claude and other existing native contexts retain their own bootstrap.
        if let observed, observed.provider != "codex" { return false }
        guard let threadID else { return false }
        guard case .string(let raw) = threadID, let id = UUID(uuidString: raw) else {
            throw ChecklistError("NATIVE_SESSION_REQUIRED", "Codex MCP _meta.threadId must be the host's native thread UUID.")
        }
        if let observed {
            guard id == UUID(uuidString: observed.nativeSessionID) else {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "Codex MCP _meta.threadId differs from this process's host-exported native thread identity.")
            }
            return false
        }
        guard let context = environment.discoverCodexMCPThread(id.uuidString.lowercased()),
              context.provider == "codex", UUID(uuidString: context.nativeSessionID) == id else {
            throw ChecklistError("NATIVE_HOST_REQUIRED", "MCP thread metadata can connect only from its native Codex host; client names and tool arguments cannot authenticate a thread.")
        }
        try verifyWorkspace(context.workspacePath)
        if let expectedSession, UUID(uuidString: expectedSession) != id {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "Codex MCP _meta.threadId differs from --session; that option cannot select another thread.")
        }
        // Retain permanent startup refusals. Metadata is no revocation/reconnect bypass.
        if let error = startupError ?? registryStart.error { throw error }
        codexMCPContext = context
        if delegating { throw ClientUpdateRequired.error }
        startConnection()
        if delegating { throw ClientUpdateRequired.error }
        return bootstrapResponse != nil || setupContext != nil
    }

    func requireMCPResourceIdentity() throws {
        guard codexMCPContext != nil else { return }
        // SDK 0.12.1 resources/read has no request metadata. Do not let a request
        // without its own thread observation inherit tools/call authority.
        throw ChecklistError("NATIVE_SESSION_REQUIRED", "Use a Checklist tool call with the host's _meta.threadId. Resource reads cannot identify the caller on this Codex MCP connection.")
    }

    /// Admission can suspend before execution. Recheck the request's own immutable
    /// metadata on the actor at every service/route capture, so a pre-bind request
    /// cannot borrow a binding established while that request was suspended.
    private func validateMCPRequestIdentity(allowCatalog: Bool = false) throws {
        guard let context = codexMCPContext else { return }
        if allowCatalog, case .catalog? = Self.mcpRequest { return }
        guard case .tool(let value)? = Self.mcpRequest,
              case .string(let raw)? = value,
              UUID(uuidString: raw) == UUID(uuidString: context.nativeSessionID) else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "This request has no matching host-authored _meta.threadId and cannot use the bound Codex thread's connection.")
        }
    }

    private func bootstrap(_ observed: NativeSessionContext?, required: Bool, timeBudget: TimeInterval? = nil) throws -> Value? {
        guard let context = observed else {
            if required || assistantProject != nil { throw BridgeError("NATIVE_CONTEXT_REQUIRED: Run this command from its native local Codex or Claude conversation. Assistant relay mode requires a local Codex helper and explicit project grants.") }
            if command == "mcp" {
                missingNativeIdentity = true
                client = environment.makeClient(.init(workspace: requestedWorkspace, usesStoredCredential: false))
            }
            return nil
        }
        try verifyWorkspace(context.workspacePath)
        missingNativeIdentity = false
        var nativeContext = context.parameters
        if let assistantProject {
            guard context.provider == "codex" else {
                throw BridgeError("UNSUPPORTED_HOST: Assistant relay mode currently requires a native local Codex conversation.")
            }
            nativeContext["mode"] = "assistant_relay"
            nativeContext["project_ref"] = assistantProject
        }
        let response: [String: Any]
        do { response = try client.bootstrap(nativeContext, timeBudget: timeBudget) }
        catch let error as ChecklistError where CodexRestartRefusal.applies(error) && context.provider == "codex"
            && automatic && command == "mcp" && assistantProject == nil {
            // Retain identity, never credentials/authority. Anonymous or another
            // thread's next request must not trigger this bootstrap again.
            codexMCPContext = context
            codexRestartBootstrapRefused = true
            throw error
        }
        catch let error as ChecklistError where error.code == ClientUpdateRequired.code && environment.shimUpdate != nil {
            checkInstalledBuild(force: true, refused: true)
            return nil
        }
        catch let error as ChecklistError where UnregisteredWorkspaceStart.applies(errorCode: error.code, command: command, assistantRelay: assistantProject != nil) {
            // Nothing was enrolled. Stay unbound instead of borrowing a stored legacy credential.
            client = environment.makeClient(.init(workspace: context.workspacePath, usesStoredCredential: false))
            setupNotice = UnregisteredWorkspaceStart.notice(workspace: context.workspacePath)
            return nil
        }
        let data = responseData(response)
        if data["state"] as? String == "project_setup_required", data["native_context_verified"] as? Bool == true {
            guard UnregisteredWorkspaceStart.allowsCreation(command:command,assistantRelay:assistantProject != nil) else {
                throw ChecklistError("PROJECT_SETUP_REQUIRED","Create this workspace's project with checklist call project_create or checklist mcp first.")
            }
            // This context has passed the service's ordinary native bootstrap checks.
            // Creation verifies it again; no stored credential is consulted here.
            client = environment.makeClient(.init(workspace:context.workspacePath,nativeContext:nativeContext,usesStoredCredential:false))
            setupContext=context
            setupNotice=UnregisteredWorkspaceStart.creationNotice(workspace:context.workspacePath)
            return nil
        }
        guard let installation = data["installation"] as? String, !installation.isEmpty else {
            throw BridgeError("INVALID_RESPONSE: Automatic connection returned no installation binding.")
        }
        client = environment.makeClient(.init(installation: installation, workspace: context.workspacePath, nativeContext: nativeContext))
        let value = try mcpValue(response)
        setupContext=nil;setupNotice=nil;setupCompletionPending=false
        bootstrapResponse = value
        return value
    }

    private func verifyWorkspace(_ workspace: String) throws {
        guard workspace == requestedWorkspace else {
            throw BridgeError("WORKSPACE_MISMATCH: Automatic connection uses the native command's actual working directory. Run it from the intended project; --workspace cannot enroll another directory.")
        }
    }

    func retryConnection() throws -> Bool {
        try validateMCPRequestIdentity(allowCatalog: true)
        checkInstalledBuild()
        if delegating { return false }
        if setupCompletionPending,let context=setupContext {
            do {
                _ = try bootstrap(context,required:true)
                if setupContext == nil { return true }
            } catch { environment.stderr("Checklist: Project connection is still pending: \(error.localizedDescription)\n") }
        }
        var start = registryStart
        let hadSetupContext = setupContext != nil
        let changed = start.retry(now: environment.now, discover: { self.discover() }, bootstrap: { observed -> Value? in
            let response = try self.bootstrap(observed, required: true)
            do { try self.verifyBoundSession() }
            catch let error as ChecklistError where error.code == ClientUpdateRequired.code && self.environment.shimUpdate != nil {
                self.checkInstalledBuild(force: true, refused: true)
                return nil
            }
            return response
        })
        registryStart = start
        if start.error != nil {
            bootstrapResponse = nil
            client = environment.makeClient(.init(workspace: requestedWorkspace, usesStoredCredential: false))
        }
        if changed { reportConnectionRecovery() }
        // Native verification can recover into an unregistered workspace. Its
        // creation tool is a catalog change even before a project is enrolled.
        return changed || (!hadSetupContext && setupContext != nil)
    }

    /// MCP startup never ends the process. A service that does not answer leaves a
    /// limited catalog and a lazy wait; other errors stay visible as tool errors.
    /// The attempt is bounded by `startupConnectBudget`; a reply timeout is a service
    /// wait, so the first request connects lazily with the full wait.
    public func startConnection() {
        codexRestartBootstrapRefused = false
        let started = environment.now()
        do {
            _ = try connect(timeBudget: Self.startupConnectBudget)
            try verifySession(replyTimeout: max(0.5, Self.startupConnectBudget - (environment.now() - started)))
            serviceError = nil; startupError = nil; codexRestartError = nil
        }
        catch { recordConnectionFailure(error) }
    }

    private func recordConnectionFailure(_ error: Error) {
        defer { codexRestartBootstrapRefused = false }
        bootstrapResponse = nil
        client = environment.makeClient(.init(workspace: requestedWorkspace, usesStoredCredential: false))
        if codexRestartBootstrapRefused, CodexRestartRefusal.applies(error), codexMCPContext?.provider == "codex",
           automatic, command == "mcp", assistantProject == nil {
            codexRestartError = error as? ChecklistError
            codexRestartRetryAt = environment.now() + Self.codexRestartRetryInterval
            // ClaudeRegistryStart also retains bootstrap errors, so clearing only
            // startupError would still latch this Codex evidence failure.
            registryStart = ClaudeRegistryStart()
            serviceError = nil; startupError = nil
            return
        }
        codexRestartError = nil
        serviceError = ServiceWait.applies(error) ? error : nil
        startupError = serviceError == nil && registryStart.error == nil ? error : nil
    }

    /// While the service does not answer, wait with backoff up to `limit`, start its
    /// launchd job at most once when launchd reports it not running, and connect.
    /// True: this request connected. After the bound: a retryable error; the next
    /// request waits again.
    /// A request that arrives during another request's wait shares that wait (one
    /// connect attempt at a time) and gets false, so the catalog notice is sent once.
    func awaitService(limit: TimeInterval = Bridge.serviceWaitLimit) async throws -> Bool {
        try validateMCPRequestIdentity(allowCatalog: true)
        if let serviceWaitTask { _ = try await serviceWaitTask.value; return false }
        guard serviceError != nil else { return false }
        let wait = Task { try await self.waitForService(limit: limit) }
        serviceWaitTask = wait
        defer { serviceWaitTask = nil }
        return try await wait.value
    }

    private func waitForService(limit: TimeInterval) async throws -> Bool {
        let started = environment.now()
        var pause: TimeInterval = 0.25, startRequested = false
        while true {
            // A different request may have bound the connection during the yield.
            // Refuse outside attemptService so A cannot clear B's valid binding.
            try validateMCPRequestIdentity(allowCatalog: true)
            guard let failure = attemptService() else {
                if registryStart.error == nil, startupError == nil, codexRestartError == nil { environment.stderr("Checklist: connected after waiting \(Int(((environment.now() - started) * 1000).rounded())) ms for the service.\n") }
                return true
            }
            if !startRequested, ServiceWait.notRunning(failure), environment.serviceJobRunning() == false {
                startRequested = true
                do { try environment.startService() }
                catch { environment.stderr("Checklist: The service job did not start yet: \(error.localizedDescription)\n") }
            }
            let left = limit - (environment.now() - started)
            guard left > 0 else {
                throw ChecklistError("SERVICE_NOT_READY", "The Checklist service did not answer within \(Int(limit)) s (\(failure.localizedDescription)) No command was sent. Retry the request; it waits for the service again and connects by itself.",
                    details: ["retryable": true, "command_outcome": "not_sent", "command_executed": false, "last_code": (failure as? ChecklistError)?.code ?? "unknown"])
            }
            environment.sleep(min(pause, left)); pause = min(pause * 2, Self.serviceWaitStep)
            await environment.yieldServiceWait()
        }
    }

    /// One full startup connection attempt. Nil unless the service still does not answer.
    private func attemptService() -> Error? {
        codexRestartBootstrapRefused = false
        do { _ = try connect(); try verifySession() }
        catch { recordConnectionFailure(error); return serviceError }
        serviceError = nil; startupError = nil; codexRestartError = nil
        return nil
    }

    public func verifySession(replyTimeout: TimeInterval? = nil) throws {
        guard registryStart.error == nil else { return }
        do { try verifyBoundSession(replyTimeout: replyTimeout) }
        catch let error as ChecklistError where error.code == ClientUpdateRequired.code && environment.shimUpdate != nil {
            checkInstalledBuild(force: true, refused: true)
        }
        reportConnectionRecovery()
    }

    /// One bounded hook pickup, through the same native discovery and authenticated
    /// bootstrap as `call`. No stdin/session argument can select the recipient.
    /// The hook environment cannot start the service. It reads the credential of the
    /// installation that bootstrap named, from the credential file, with no Keychain path.
    public func codexHookPickup(timeBudget: TimeInterval, hookSessionID: String) throws -> Value {
        guard command == "codex-post-tool", automatic, expectedSession == nil, assistantProject == nil,
              let context = discover().context, context.provider == "codex",
              UUID(uuidString: hookSessionID) == UUID(uuidString: context.nativeSessionID) else {
            throw BridgeError("NATIVE_CONTEXT_REQUIRED: The PostToolUse hook requires its actual native Codex worker.")
        }
        let deadline = environment.now() + timeBudget
        func remaining() throws -> TimeInterval {
            let left = deadline - environment.now()
            guard left > 0 else { throw BridgeError("HOOK_TIMEOUT: The pickup budget expired.") }
            return left
        }
        // Bootstrap the exact observation checked above. A second discovery could
        // select another host rollout between validation and pickup.
        guard try bootstrap(context, required: true, timeBudget: remaining()) != nil,
              !delegating, setupContext == nil else {
            throw BridgeError("NATIVE_CONTEXT_REQUIRED: The hook did not obtain a native worker binding.")
        }
        return try mcpValue(client.call("codex_hook_pickup", [:], replyTimeout: remaining()))
    }

    /// The step after stdout is written. Only this step stamps. The command ID derives from the
    /// delivery IDs, so a retry of the same set replays. A failure leaves the note unconfirmed,
    /// and it shows again at a later tool call.
    public func codexHookConfirm(deliveryIDs: [String], timeBudget: TimeInterval) throws -> Value {
        guard command == "codex-post-tool", automatic, expectedSession == nil, assistantProject == nil, !deliveryIDs.isEmpty else {
            throw BridgeError("NATIVE_CONTEXT_REQUIRED: Only the PostToolUse hook confirms its output.")
        }
        guard timeBudget > 0 else { throw BridgeError("HOOK_TIMEOUT: The confirmation budget expired.") }
        let ordered = deliveryIDs.sorted()
        return try mcpValue(client.call("codex_hook_confirm", ["command_id": Self.codexHookConfirmCommandID(ordered), "delivery_ids": ordered], replyTimeout: timeBudget))
    }

    public static func codexHookConfirmCommandID(_ deliveryIDs: [String]) -> String {
        var bytes = Array(SHA256.hash(data: Data(("codex_hook_confirm\n" + deliveryIDs.sorted().joined(separator: "\n")).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
    }

    /// A model that runs `checklist call` or an MCP tool cannot reach the hook commands.
    private static func refuseHookOnly(_ name: String) throws {
        if CommandReply.codexHookOnlyMethods.contains(name) { throw BridgeError("METHOD_UNAVAILABLE: Only the Checklist hook uses this command: \(name)") }
    }

    private func reportConnectionRecovery() {
        if let summary = registryStart.takeRecoverySummary() {
            environment.stderr("Checklist: \(summary)\n")
        }
    }

    private func verifyBoundSession(replyTimeout: TimeInterval? = nil) throws {
        guard !delegating, let expectedSession else { return }
        let info = responseData(try client.call("service_info", [:], replyTimeout: replyTimeout))
        let caller = info["caller"] as? [String: Any]
        let boundSession = info["session_id"] as? String ?? caller?["session_id"] as? String
        guard boundSession == expectedSession else {
            throw BridgeError("SESSION_MISMATCH: --session must match the session paired in Checklist. It cannot authenticate or select another session.")
        }
    }

    public func attachTask(_ reference: String) throws -> Value {
        guard let connection = try connect(required: true),
              var response = try jsonObject(connection) as? [String: Any] else {
            throw BridgeError("INVALID_RESPONSE: Automatic connection returned no binding.")
        }
        var data = responseData(response)
        guard let projectID = data["project_id"] as? String, !projectID.isEmpty else {
            throw BridgeError("INVALID_RESPONSE: Automatic connection returned no project binding.")
        }
        var lookup: [String: Any] = ["project_id": projectID]
        if let id = UUID(uuidString: reference) { lookup["task_id"] = id.uuidString.lowercased() }
        else { lookup["key"] = reference }
        let taskResponse = try call("task_get", mcpValue(lookup))
        guard let taskEnvelope = try jsonObject(taskResponse) as? [String: Any] else {
            throw BridgeError("INVALID_RESPONSE: Checklist returned no task.")
        }
        let task = responseData(taskEnvelope)
        guard let taskID = task["id"] as? String, !taskID.isEmpty,
              task["project_id"] as? String == projectID,
              let key = task["key"] as? String else {
            throw BridgeError("INVALID_RESPONSE: The task does not belong to the connected project.")
        }
        let attachment = try call("session_attach_task", mcpValue([
            "command_id": UUID().uuidString.lowercased(), "project_id": projectID, "task_id": taskID
        ]))
        data["task_id"] = taskID
        data["task_key"] = key
        data["task_attachment"] = try jsonObject(attachment)
        response["data"] = data
        return try mcpValue(response)
    }

    private static func limitedServiceInfo(_ description: String, name: String = "service_info") -> Tool {
        Tool(name: name, description: description, inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]), annotations: .init(readOnlyHint: true, openWorldHint: false))
    }

    private static let workspaceProjectCreate = Tool(name:"project_create",description:"Create a Checklist project for this verified native conversation's own folder and connect this worker atomically. root_path, if supplied, must equal that folder. Continue setup through the full tool set after success.",inputSchema:.object([
        "type":.string("object"),"properties":.object([
            "command_id":.object(["type":.string("string"),"format":.string("uuid"),"maxLength":.int(100)]),
            "name":.object(["type":.string("string"),"maxLength":.int(200)]),"key_prefix":.object(["type":.string("string"),"maxLength":.int(12)]),
            "root_path":.object(["type":.string("string"),"maxLength":.int(4000)]),"icon":.object(["type":.string("string"),"maxLength":.int(4000)]),
            "accent":.object(["type":.string("string"),"maxLength":.int(4000)])
        ]),"required":.array([.string("command_id"),.string("name")]),"additionalProperties":.bool(false)
    ]),annotations:.init(readOnlyHint:false,destructiveHint:false,idempotentHint:true,openWorldHint:false))

    func tools() throws -> [Tool] {
        let tools = try forward(current: { try localTools() }, delegate: { try delegateTools() })
        // This adapter runs the wait on operation_get, for each caller allowed to read it (CL-364).
        guard tools.contains(where: { $0.name == "operation_get" }), !tools.contains(where: { $0.name == OperationWait.toolName }) else { return tools }
        return tools + [OperationWait.tool]
    }

    private func localTools() throws -> [Tool] {
        // Creation is the only project tool before an actual enrollment exists.
        if let connectionNotice { return ClaudeRegistryStart.limitedToolNames.map { Self.limitedServiceInfo(connectionNotice, name: $0) } }
        if let setupNotice {
            var tools=[Self.limitedServiceInfo("Read limited local service status. " + setupNotice)]
            if setupContext != nil { tools.append(Self.workspaceProjectCreate) }
            return tools
        }
        return try Self.catalogTools(client)
    }

    private static func catalogTools(_ client: any BridgeClient) throws -> [Tool] {
        let catalog: [String: Any]
        do { catalog = responseData(try client.call("tool_catalog")) }
        catch let error as ChecklistError where error.code == "SETUP_REQUIRED" {
            // First connection still initializes cleanly and explains pairing.
            return [limitedServiceInfo("Read limited local service status. Connect from the current Codex or Claude conversation with checklist connect; no session-ID form is needed.")]
        }
        guard let rows = catalog["tools"] as? [[String: Any]] else {
            throw BridgeError("Checklist returned an invalid tool catalog. Repair or update the installed app.")
        }
        return try rows.map { try JSONDecoder().decode(Tool.self, from: jsonData($0)) }
    }

    public func toolsResult() throws -> Value {
        let encoded = try JSONEncoder().encode(tools())
        return .object(["tools": try JSONDecoder().decode(Value.self, from: encoded)])
    }

    public func call(_ name: String, _ arguments: Value) throws -> Value {
        try validateMCPRequestIdentity()
        return try forward(current: { try localCall(name, arguments) }, delegate: { try delegateCall(name, arguments) })
    }

    /// What a tool call needs from actor state, captured so its blocking service
    /// request or child CLI run happens off the actor's serial queue (CL-352).
    private enum CallRoute: Sendable {
        case service(any BridgeClient, checksCatalog: Bool)
        case delegate(DelegateTarget)
    }

    /// Nil: the call needs actor state throughout (not connected, limited or setup states).
    private func callRoute() throws -> CallRoute? {
        try validateMCPRequestIdentity()
        if delegating { return .delegate(delegateTarget()) }
        guard startupError == nil, serviceError == nil, codexRestartError == nil, registryStart.error == nil, registryStart.connection == nil,
              connectionNotice == nil, setupNotice == nil, setupContext == nil else { return nil }
        return .service(client, checksCatalog: command != "call")
    }

    /// The MCP tool call. Several calls of one conversation are in flight at once and
    /// each waits only for its own reply. The route (bound client, identity, workspace
    /// and native context) is read on the actor; the request runs on a dispatch worker;
    /// notices are applied on the actor. The arguments, including command_id, pass unchanged.
    public nonisolated func concurrentCall(_ name: String, _ arguments: Value) async throws -> Value {
        if name == OperationWait.toolName, try await callRoute() != nil { return try await operationWaitTool(arguments) }
        guard let route = try await callRoute() else { return try await call(name, arguments) }
        let reply: Data
        do {
            switch route {
            case .delegate(let target): return try await Self.offload { try Self.runDelegateCall(target, name, arguments) }
            case .service(let client, let checksCatalog): reply = try await Self.offload { try Self.serviceCall(client, checksCatalog: checksCatalog, name, arguments) }
            }
        } catch let error as ChecklistError where error.code == ClientUpdateRequired.code {
            if case .service = route, await refuseOutdatedClient() { return try await call(name, arguments) }
            throw Self.reconnectGuidance(error)
        } catch { throw Self.reconnectGuidance(error) }
        return try await finishServiceCall(reply)
    }

    /// One read of a wait loop (CL-364), with its own reply budget and no catalog check.
    /// It runs on a dispatch worker, so other calls of this conversation continue.
    nonisolated func statusRead(_ name: String, _ arguments: Value, budget: TimeInterval) async throws -> Value {
        guard case .service(let client, _)? = try await callRoute() else { return try await concurrentCall(name, arguments) }
        do {
            let reply = try await Self.offload { () throws -> Data in
                guard let parameters = try jsonObject(arguments) as? [String: Any] else { throw BridgeError("Tool arguments must be a JSON object.") }
                return try jsonData(client.call(name, parameters, replyTimeout: budget))
            }
            return try await finishServiceCall(reply)
        } catch let error as ChecklistError where error.code == ClientUpdateRequired.code {
            if await refuseOutdatedClient() { return try await concurrentCall(name, arguments) }
            throw Self.reconnectGuidance(error)
        } catch { throw Self.reconnectGuidance(error) }
    }

    public nonisolated func concurrentReadResource(_ uri: String) async throws -> Value {
        if uri == "checklist://projects" { return try await concurrentCall("project_list", .object([:])) }
        return try await readResource(uri)
    }

    private static func serviceCall(_ client: any BridgeClient, checksCatalog: Bool, _ name: String, _ arguments: Value) throws -> Data {
        try refuseHookOnly(name)
        if checksCatalog, try !catalogTools(client).contains(where: { $0.name == name }) {
            throw BridgeError("METHOD_UNAVAILABLE: This tool is unavailable to the paired connection: \(name)")
        }
        guard let parameters = try jsonObject(arguments) as? [String: Any] else {
            throw BridgeError("Tool arguments must be a JSON object.")
        }
        return try jsonData(client.call(name, parameters))
    }

    private func finishServiceCall(_ reply: Data) throws -> Value {
        guard let response = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw BridgeError("INVALID_RESPONSE: Checklist returned no result object.")
        }
        return try mcpValue(withSetupNotice(response))
    }

    /// Same as `forward`: a refused outdated client switches to the installed CLI.
    private func refuseOutdatedClient() -> Bool {
        guard environment.shimUpdate != nil else { return false }
        checkInstalledBuild(force: true, refused: true)
        return true
    }

    private static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func localCall(_ name: String, _ arguments: Value) throws -> Value {
        try Self.refuseHookOnly(name)
        if let error = startupError ?? serviceError ?? codexRestartError ?? registryStart.error, !ClaudeRegistryStart.limitedToolNames.contains(name) { throw error }
        // Direct CLI calls already bootstrap/verify. The service checks its current
        // caller, catalog/schema and grants for the actual command. Fetching and
        // decoding the entire catalog here adds a serialized round trip per call.
        // Keep local setup restrictions and MCP's advertised-tool checks.
        if command != "call" || setupNotice != nil {
            let available = try localTools()
            guard available.contains(where: { $0.name == name }) else {
                throw BridgeError("METHOD_UNAVAILABLE: This tool is unavailable to the paired connection: \(name)")
            }
        }
        guard let parameters = try jsonObject(arguments) as? [String: Any] else {
            throw BridgeError("Tool arguments must be a JSON object.")
        }
        let response=try client.call(name,parameters)
        if name == "project_create",let context=setupContext {
            // A connection failure after commit must preserve the successful
            // receipt. A later request can finish the same bootstrap safely.
            setupCompletionPending=true
            do {
                _ = try bootstrap(context,required:true)
                if setupContext == nil { creationNoticePending=true }
            } catch {
                setupNotice="The project was created, but completing this conversation's connection is pending. Retry the original project_create command_id or make another request. "+error.localizedDescription
                environment.stderr("Checklist: \(setupNotice!)\n")
            }
        }
        return try mcpValue(withSetupNotice(response))
    }

    public func serviceInfo() throws -> Value {
        try validateMCPRequestIdentity()
        return try forward(current: { try mcpValue(withSetupNotice(client.call("service_info"))) },
                    delegate: { try delegateCall("service_info", .object([:])) })
    }

    // Limited service status explains why the verified workspace has no project yet.
    private func withSetupNotice(_ response: [String: Any]) -> [String: Any] {
        let connection: [String: Any]
        if serviceError != nil, let notice = connectionNotice { connection = ["connected": false, "state": "service_not_answering", "message": notice] }
        else if let error = codexRestartError, let notice = connectionNotice {
            connection = ["connected": false, "state": "connection_failed", "message": notice,
                "retryable": true, "reason": CodexRestartRefusal.reason,
                "retry_after_seconds": max(0, codexRestartRetryAt - environment.now()), "details": error.details]
        }
        else if startupError != nil, let notice = connectionNotice { connection = ["connected": false, "state": "connection_failed", "message": notice] }
        else if let pending = registryStart.connection { connection = pending }
        else if missingNativeIdentity { connection = ["connected": false, "state": "native_thread_identity_unavailable", "message": Self.nativeIdentityNotice] }
        else if let setupNotice { connection = ["connected":false,"state":setupCompletionPending ? "project_connection_pending":"project_setup_required","message":setupNotice] }
        else { return response }
        var response = response
        if var data = response["data"] as? [String: Any] { data["connection"] = connection; response["data"] = data }
        else { response["connection"] = connection }
        return response
    }

    func resources() throws -> [Resource] {
        try requireMCPResourceIdentity()
        return try forward(current: { try resourceCatalog(localTools()) }, delegate: { try resourceCatalog(delegateTools()) })
    }

    private func resourceCatalog(_ tools: [Tool]) -> [Resource] {
        var resources = [Resource(name: "Checklist service", uri: "checklist://service/status", description: "Limited local service and current paired capability status", mimeType: "application/json")]
        if tools.contains(where: { $0.name == "project_list" }) {
            resources.append(Resource(name: "Granted projects", uri: "checklist://projects", description: "Projects accessible to this enrolled connection", mimeType: "application/json"))
        }
        return resources
    }


    private func checkInstalledBuild(force: Bool = false, refused: Bool = false) {
        guard let update = environment.shimUpdate else { return }
        launchState = update.check(force)
        if refused || launchState != .current {
            if !delegating { delegating = true; updateNoticePending = true }
        }
    }

    func takeUpdateNotice() -> Bool {
        guard updateNoticePending || creationNoticePending else { return false }
        updateNoticePending = false;creationNoticePending = false
        return true
    }

    private func forward<T>(current: () throws -> T, delegate: () throws -> T) throws -> T {
        do {
            if delegating { return try delegate() }
            do { return try current() }
            catch let error as ChecklistError where error.code == ClientUpdateRequired.code && environment.shimUpdate != nil {
                checkInstalledBuild(force: true, refused: true)
                return try delegate()
            }
        } catch let error as ChecklistError where error.code == "NATIVE_SESSION_REQUIRED" { throw Self.reconnectGuidance(error) }
    }

    private static func reconnectGuidance(_ error: Error) -> Error {
        guard let error = error as? ChecklistError, error.code == "NATIVE_SESSION_REQUIRED" else { return error }
        return ChecklistError(error.code, "Restart the Checklist MCP connection: stop its running `checklist mcp` process and start `\(ChecklistInstance.current.cliCommand) mcp` from this same native conversation and project directory. Keep the original command_id when retrying a mutation. An installation label cannot authenticate a native session.", details:error.details)
    }

    private struct DelegateTarget: Sendable {
        let update: ShimUpdateEnvironment?
        let suffix: [String]
    }

    private func delegateTarget() -> DelegateTarget {
        var suffix = ["--workspace", requestedWorkspace]
        if let expectedSession { suffix += ["--session", expectedSession] }
        if !automatic { suffix += ["--installation", installation] }
        if let assistantProject { suffix += ["--assistant", "--project", assistantProject] }
        // A delegated CLI lacks this request's wire metadata. Never launch it
        // with a fabricated environment/session argument to preserve authority.
        return DelegateTarget(update: launchState == .unavailable || codexMCPContext != nil || missingNativeIdentity ? nil : environment.shimUpdate, suffix: suffix)
    }

    private func delegate(_ route: [String], input: Data? = nil, commandID: String? = nil) throws -> Data {
        try Self.runDelegate(delegateTarget(), route, input: input, commandID: commandID)
    }

    private static func runDelegate(_ target: DelegateTarget, _ route: [String], input: Data?, commandID: String?) throws -> Data {
        guard let update = target.update else { throw ClientUpdateRequired.error }
        let arguments = route + target.suffix
        let result: ShimChildResult
        do { result = try update.run(arguments, input) }
        catch is ShimInstanceRefusal { throw ClientUpdateRequired.error }
        catch is ShimChildInstanceMismatch {
            var details = DelegateInstanceExpectation.mismatch.details
            if let commandID { details["command_id"] = commandID }
            throw ChecklistError(DelegateInstanceExpectation.mismatch.code, DelegateInstanceExpectation.mismatch.message, details: details)
        }
        catch let error as ShimChildLaunchError {
            var details: [String: Any] = ["command_outcome": "not_sent", "command_executed": false]
            if let commandID { details["command_id"] = commandID }
            throw ChecklistError("DELEGATE_LAUNCH_FAILED", "Cannot start the installed Checklist CLI: " + error.underlying.localizedDescription + " No command ran.", details: details)
        }
        catch { throw CommandReply.unknown(commandID: commandID, reason: "delegate_ended") }
        guard result.termination == .exited else { throw CommandReply.unknown(commandID: commandID, reason: "delegate_ended") }
        if result.status == 0,
           (try? JSONSerialization.jsonObject(with: result.stdout, options: [.fragmentsAllowed])) != nil {
            return result.stdout
        }
        if result.status == 1, let failure = Self.cliError(result.stderr) {
            if failure.code == "DELEGATE_INSTANCE_MISMATCH" {
                var details = DelegateInstanceExpectation.mismatch.details
                if let commandID { details["command_id"] = commandID }
                throw ChecklistError(failure.code, failure.message, details: details)
            }
            let bytes = try jsonData(["error": ["code": failure.code, "message": failure.message]])
            _ = try CommandReply.decode(bytes, method: "", commandID: commandID)
        }
        throw CommandReply.unknown(commandID: commandID, reason: "delegate_ended")
    }

    /// Only the final CLI error line is a result. Earlier lines are diagnostics.
    private static func cliError(_ stderr: String) -> (code: String, message: String)? {
        guard let line = stderr.split(whereSeparator: \.isNewline).last,
              line.hasPrefix("Checklist: ") else { return nil }
        let body = line.dropFirst("Checklist: ".count)
        guard let separator = body.range(of: ": ") else { return nil }
        let code = String(body[..<separator.lowerBound]), message = String(body[separator.upperBound...])
        guard let first = code.utf8.first, (65...90).contains(first), !message.isEmpty,
              code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return (code, message)
    }

    private func delegateTools() throws -> [Tool] {
        struct Catalog: Decodable { let tools: [Tool] }
        return try JSONDecoder().decode(Catalog.self, from: delegate(["tools"])).tools
    }

    private func delegateCall(_ name: String, _ arguments: Value) throws -> Value {
        try Self.runDelegateCall(delegateTarget(), name, arguments)
    }

    private static func runDelegateCall(_ target: DelegateTarget, _ name: String, _ arguments: Value) throws -> Value {
        guard case .object = arguments else { throw BridgeError("Tool arguments must be a JSON object.") }
        let data = try JSONEncoder().encode(arguments)
        guard data.count <= CallArgumentInput.limit else {
            throw ChecklistError("TOO_LARGE", "Input exceeds 1 MiB; no command ran.", details: ["command_outcome": "not_sent", "command_executed": false])
        }
        let commandID: String?
        if case .object(let values) = arguments, case .string(let id)? = values["command_id"] { commandID = id }
        else { commandID = nil }
        return try JSONDecoder().decode(Value.self, from: runDelegate(target, ["call", name, "-"], input: data, commandID: commandID))
    }

    func readResource(_ uri: String) throws -> Value {
        try requireMCPResourceIdentity()
        switch uri {
        case "checklist://service/status": return try serviceInfo()
        case "checklist://projects": return try call("project_list", .object([:]))
        default: throw MCPError.invalidParams("Unknown or inaccessible Checklist resource.")
        }
    }
}
