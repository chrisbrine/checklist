import Foundation

public struct CodexProviderPlugin: ChecklistProviderPlugin {
    public init() {}
    public let manifest = ProviderPluginManifest(pluginID: "org.checklist.codex", version: "1.0.0", providerID: "codex", displayName: "Codex",
        capabilities: [.workSession, .pickup, .correlatedReply, .composer, .assistantRelay, .answerNotice])
    public let nativeHost: ProviderNativeHost? = .init(executable: "codex", signingIdentifier: "codex", signingTeam: "2DC432GLL2",
        applicationBundleID: "com.openai.codex", registryDirectory: nil, identityVerification: "native_process_verified_thread_observed")
    public func observe(environment: [String:String], workspace: String, registry: [String:Any]?) -> ProviderObservedSession? {
        // An invalid child UUID cannot fall back to a parent UUID.
        guard workspace.hasPrefix("/"), let raw = environment["CODEX_THREAD_ID"] ?? environment["CODEX_SESSION_ID"], let id = UUID(uuidString: raw) else { return nil }
        return .init(sessionID: id.uuidString.lowercased(), workspace: canonicalProviderPath(workspace))
    }
    public func composeURL(instruction: String, workspace: String) -> URL? {
        guard !instruction.isEmpty, providerWorkspaceExists(workspace) else { return nil }
        var parts = URLComponents(); parts.scheme = "codex"; parts.host = "threads"; parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "prompt", value: instruction), URLQueryItem(name: "path", value: workspace)]
        return parts.url
    }
    public func validateComposeURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "codex", parts.host == "threads", parts.path == "/new",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).isSubset(of: ["prompt", "path"]), items.filter({ $0.name == "prompt" }).count == 1,
              let prompt = items.first(where: { $0.name == "prompt" })?.value, !prompt.isEmpty, items.filter({ $0.name == "path" }).count <= 1 else { return nil }
        if let item = items.first(where: { $0.name == "path" }) { guard let path = item.value, providerWorkspaceExists(path) else { return nil } }
        return parts.url
    }
}

public struct ClaudeProviderPlugin: ChecklistProviderPlugin {
    public init() {}
    public let registryMismatchMessage = "Claude's current session registry does not match this native process and workspace."
    public let manifest = ProviderPluginManifest(pluginID: "org.checklist.claude", version: "1.0.0", providerID: "claude", displayName: "Claude",
        capabilities: [.workSession, .pickup, .correlatedReply, .nativePeer, .registryClosure])
    public let nativeHost: ProviderNativeHost? = .init(executable: "claude", signingIdentifier: "com.anthropic.claude-code", signingTeam: "Q6L2SF6YDW",
        applicationBundleID: "com.anthropic.claudefordesktop", registryDirectory: ".claude/sessions", identityVerification: "native_process_and_session_registry_verified")
    public func observe(environment: [String:String], workspace: String, registry: [String:Any]?) -> ProviderObservedSession? {
        guard workspace.hasPrefix("/") else { return nil }
        let workspace = canonicalProviderPath(workspace)
        var session = environment["CLAUDE_SESSION_ID"] ?? environment["CLAUDE_CODE_SESSION_ID"]
        var endpoint = environment["CLAUDE_CODE_MESSAGING_SOCKET"], title: String?
        if let registry {
            guard let registered = registry["sessionId"] as? String, let directory = registry["cwd"] as? String else { return nil }
            let root = canonicalProviderPath(directory)
            guard workspace == root || workspace.hasPrefix(root + "/") else { return nil }
            if let session, UUID(uuidString: session) != UUID(uuidString: registered) { return nil }
            session = registered
            if let registeredEndpoint = registry["messagingSocketPath"] as? String, !registeredEndpoint.isEmpty {
                if let endpoint, normalizeProviderEndpoint(endpoint) != normalizeProviderEndpoint(registeredEndpoint) { return nil }
                endpoint = registeredEndpoint
            }
            if let name = registry["name"] as? String, !name.isEmpty { title = String(name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(120)) }
        }
        guard let session, let id = UUID(uuidString: session) else { return nil }
        if let raw = endpoint {
            let normalized = normalizeProviderEndpoint(raw)
            guard normalized.hasPrefix("/"), !normalized.utf8.contains(0) else { return nil }; endpoint = normalized
        }
        return .init(sessionID: id.uuidString.lowercased(), workspace: workspace, endpoint: endpoint, title: title)
    }
    public func registryMatches(_ record: [String:Any], processID: Int32, sessionID: String, workspace: String, endpoint: String?) -> Bool {
        guard (record["pid"] as? NSNumber)?.int32Value == processID, record["sessionId"] as? String == sessionID,
              let directory = record["cwd"] as? String else { return false }
        let root = canonicalProviderPath(directory)
        guard workspace == root || workspace.hasPrefix(root + "/") else { return false }
        return endpoint == nil || record["messagingSocketPath"] as? String == endpoint
    }
    public func hostStatusReason(_ status: String) -> String? { Self.hostStatusReasons[status] }
    public static let hostStatusReasons = [
        "held":"Claude is holding this note because the conversation's permission setting differs from Checklist's. Claude Desktop may show no approval control. To let Checklist notes through automatically, set Claude Code's crossSessionInbound setting to accept. The note stays available at the agent's next Checklist check.",
        "refused":"Claude refused this native delivery. The note stays available at the agent's next Checklist check.",
        "expired":"Claude's approval hold expired without delivery. The note stays available at the agent's next Checklist check."
    ]
}

// Compatibility policy names are persisted project choices, not provider routing
// logic in Core. They never broaden grants or select/launch a model.
public enum ProviderPolicyDefaults {
    public static let presets = ["shared", "claude_coordinates", "codex_led"]
    public static let defaultReviewProvider = "codex"
    public static func providers(role: String, preset: String, allowed: [String]) -> [String] {
        if role == "implementer", preset != "shared" { return allowed.filter { $0 == "codex" } }
        if role == "coordinator", preset == "claude_coordinates" { return allowed.filter { $0 == "claude" } }
        if role == "coordinator", preset == "codex_led" { return allowed.filter { $0 == "codex" } }
        return allowed
    }
}

func canonicalProviderPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
func normalizeProviderEndpoint(_ value: String) -> String { value.hasPrefix("uds:") ? String(value.dropFirst(4)) : value }
func providerWorkspaceExists(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
}
