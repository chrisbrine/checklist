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

public actor Bridge {
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
    private var registryStart = ClaudeRegistryStart()
    private(set) var setupNotice: String?
    var connectionNotice: String? { registryStart.notice }
    var connectionStartupNotice: String? { registryStart.startupNotice }

    public init(configuration: BridgeConfiguration, environment: BridgeEnvironment = .init()) {
        self.environment = environment
        client = environment.makeClient(.init(installation: configuration.installation, workspace: configuration.workspace))
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

    public func connect(required: Bool = false) throws -> Value? {
        checkInstalledBuild()
        if delegating { return nil }
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
            bootstrap: { try self.bootstrap($0, required: required, timeBudget: $1) })
    }

    private func discover() -> NativeSessionDiscovery {
        environment.discover(assistantProject != nil)
    }

    private func bootstrap(_ observed: NativeSessionContext?, required: Bool, timeBudget: TimeInterval? = nil) throws -> Value? {
        guard let context = observed else {
            if required || assistantProject != nil { throw BridgeError("NATIVE_CONTEXT_REQUIRED: Run this command from its native local Codex or Claude conversation. Assistant relay mode requires a local Codex helper and explicit project grants.") }
            return nil
        }
        try verifyWorkspace(context.workspacePath)
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
        guard let installation = data["installation"] as? String, !installation.isEmpty else {
            throw BridgeError("INVALID_RESPONSE: Automatic connection returned no installation binding.")
        }
        client = environment.makeClient(.init(installation: installation, workspace: context.workspacePath, nativeContext: nativeContext))
        let value = try mcpValue(response)
        bootstrapResponse = value
        return value
    }

    private func verifyWorkspace(_ workspace: String) throws {
        guard workspace == requestedWorkspace else {
            throw BridgeError("WORKSPACE_MISMATCH: Automatic connection uses the native command's actual working directory. Run it from the intended project; --workspace cannot enroll another directory.")
        }
    }

    func retryConnection() -> Bool {
        checkInstalledBuild()
        if delegating { return false }
        var start = registryStart
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
        return changed
    }

    public func verifySession() throws {
        guard registryStart.error == nil else { return }
        do { try verifyBoundSession() }
        catch let error as ChecklistError where error.code == ClientUpdateRequired.code && environment.shimUpdate != nil {
            checkInstalledBuild(force: true, refused: true)
        }
        reportConnectionRecovery()
    }

    private func reportConnectionRecovery() {
        if let summary = registryStart.takeRecoverySummary() {
            environment.stderr("Checklist: \(summary)\n")
        }
    }

    private func verifyBoundSession() throws {
        guard !delegating, let expectedSession else { return }
        let info = responseData(try client.call("service_info"))
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

    func tools() throws -> [Tool] {
        try forward(current: { try localTools() }, delegate: { try delegateTools() })
    }

    private func localTools() throws -> [Tool] {
        // No project tool is advertised before an actual enrollment exists.
        if let connectionNotice { return ClaudeRegistryStart.limitedToolNames.map { Self.limitedServiceInfo(connectionNotice, name: $0) } }
        if let setupNotice { return [Self.limitedServiceInfo("Read limited local service status. " + setupNotice)] }
        let catalog: [String: Any]
        do { catalog = responseData(try client.call("tool_catalog")) }
        catch let error as ChecklistError where error.code == "SETUP_REQUIRED" {
            // First connection still initializes cleanly and explains pairing.
            return [Self.limitedServiceInfo("Read limited local service status. Connect from the current Codex or Claude conversation with checklist connect; no session-ID form is needed.")]
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
        try forward(current: { try localCall(name, arguments) }, delegate: { try delegateCall(name, arguments) })
    }

    private func localCall(_ name: String, _ arguments: Value) throws -> Value {
        if let error = registryStart.error, !ClaudeRegistryStart.limitedToolNames.contains(name) { throw error }
        // Discovery repeats for every call: cached schemas never preserve a revoked role.
        let available = try localTools()
        guard available.contains(where: { $0.name == name }) else {
            throw BridgeError("METHOD_UNAVAILABLE: This tool is unavailable to the paired connection: \(name)")
        }
        guard let parameters = try jsonObject(arguments) as? [String: Any] else {
            throw BridgeError("Tool arguments must be a JSON object.")
        }
        return try mcpValue(withSetupNotice(client.call(name, parameters)))
    }

    public func serviceInfo() throws -> Value {
        try forward(current: { try mcpValue(withSetupNotice(client.call("service_info"))) },
                    delegate: { try delegateCall("service_info", .object([:])) })
    }

    // The limited start can only reach service_info; its result says why no project is bound.
    private func withSetupNotice(_ response: [String: Any]) -> [String: Any] {
        let connection: [String: Any]
        if let pending = registryStart.connection { connection = pending }
        else if let setupNotice { connection = ["connected": false, "state": "project_setup_required", "message": setupNotice] }
        else { return response }
        var response = response
        if var data = response["data"] as? [String: Any] { data["connection"] = connection; response["data"] = data }
        else { response["connection"] = connection }
        return response
    }

    func resources() throws -> [Resource] {
        try forward(current: { try resourceCatalog(localTools()) }, delegate: { try resourceCatalog(delegateTools()) })
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
        guard updateNoticePending else { return false }
        updateNoticePending = false
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
        } catch let error as ChecklistError where error.code == "NATIVE_SESSION_REQUIRED" {
            throw ChecklistError(error.code, "Restart the Checklist MCP connection: stop its running `checklist mcp` process and start `\(ChecklistInstance.current.cliCommand) mcp` from this same native conversation and project directory. Keep the original command_id when retrying a mutation. An installation label cannot authenticate a native session.", details:error.details)
        }
    }

    private func delegate(_ route: [String], input: Data? = nil, commandID: String? = nil) throws -> Data {
        guard let update = environment.shimUpdate, launchState != .unavailable else { throw ClientUpdateRequired.error }
        var arguments = route + ["--workspace", requestedWorkspace]
        if let expectedSession { arguments += ["--session", expectedSession] }
        if !automatic { arguments += ["--installation", installation] }
        if let assistantProject { arguments += ["--assistant", "--project", assistantProject] }
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
        guard case .object = arguments else { throw BridgeError("Tool arguments must be a JSON object.") }
        let data = try JSONEncoder().encode(arguments)
        guard data.count <= CallArgumentInput.limit else {
            throw ChecklistError("TOO_LARGE", "Input exceeds 1 MiB; no command ran.", details: ["command_outcome": "not_sent", "command_executed": false])
        }
        let commandID: String?
        if case .object(let values) = arguments, case .string(let id)? = values["command_id"] { commandID = id }
        else { commandID = nil }
        return try JSONDecoder().decode(Value.self, from: delegate(["call", name, "-"], input: data, commandID: commandID))
    }

    func readResource(_ uri: String) throws -> Value {
        switch uri {
        case "checklist://service/status": return try serviceInfo()
        case "checklist://projects": return try call("project_list", .object([:]))
        default: throw MCPError.invalidParams("Unknown or inaccessible Checklist resource.")
        }
    }
}

