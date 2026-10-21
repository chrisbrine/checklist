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
    }

    public func reportStartupNotice() {
        if let notice = setupNotice ?? connectionStartupNotice { environment.stderr("Checklist: \(notice)\n") }
    }

    public func connect(required: Bool = false) throws -> Value? {
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
        var start = registryStart
        let changed = start.retry(now: environment.now, discover: { self.discover() }, bootstrap: {
            let response = try self.bootstrap($0, required: true)
            try self.verifyBoundSession()
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
        try verifyBoundSession()
        reportConnectionRecovery()
    }

    private func reportConnectionRecovery() {
        if let summary = registryStart.takeRecoverySummary() {
            environment.stderr("Checklist: \(summary)\n")
        }
    }

    private func verifyBoundSession() throws {
        guard let expectedSession else { return }
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
        if let error = registryStart.error, !ClaudeRegistryStart.limitedToolNames.contains(name) { throw error }
        // Discovery repeats for every call: cached schemas never preserve a revoked role.
        let available = try tools()
        guard available.contains(where: { $0.name == name }) else {
            throw BridgeError("METHOD_UNAVAILABLE: This tool is unavailable to the paired connection: \(name)")
        }
        guard let parameters = try jsonObject(arguments) as? [String: Any] else {
            throw BridgeError("Tool arguments must be a JSON object.")
        }
        return try mcpValue(withSetupNotice(client.call(name, parameters)))
    }

    public func serviceInfo() throws -> Value {
        try mcpValue(withSetupNotice(client.call("service_info")))
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
        var resources = [Resource(name: "Checklist service", uri: "checklist://service/status", description: "Limited local service and current paired capability status", mimeType: "application/json")]
        if try tools().contains(where: { $0.name == "project_list" }) {
            resources.append(Resource(name: "Granted projects", uri: "checklist://projects", description: "Projects accessible to this enrolled connection", mimeType: "application/json"))
        }
        return resources
    }

    func readResource(_ uri: String) throws -> Value {
        switch uri {
        case "checklist://service/status": return try serviceInfo()
        case "checklist://projects": return try call("project_list", .object([:]))
        default: throw MCPError.invalidParams("Unknown or inaccessible Checklist resource.")
        }
    }
}

