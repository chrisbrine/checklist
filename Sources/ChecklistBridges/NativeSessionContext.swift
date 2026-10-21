import Foundation
import Darwin

public enum ClaudeRegistryReason: String, Sendable {
    case absent = "registry absent"
    case otherSession = "registry names another session"
    case outsideWorkspace = "registry cwd outside the workspace"
    case serviceMismatch = "service registry mismatch"
}

public enum NativeSessionDiscovery: Equatable, Sendable {
    case available(NativeSessionContext)
    case noHost
    case claudeRegistryNotReady(ClaudeRegistryReason)
    case unavailable

    public var context: NativeSessionContext? {
        if case .available(let context) = self { return context }
        return nil
    }

    public var registryReason: ClaudeRegistryReason? {
        if case .claudeRegistryNotReady(let reason) = self { return reason }
        return nil
    }
}

/// Observed native context is bootstrap evidence, never a credential or an owner
/// grant. The service independently verifies its XPC peer, ancestry and cwd.
public struct NativeSessionContext: Equatable, Sendable {
    public let provider: String
    public let nativeSessionID: String
    public let workspacePath: String
    public let nativeEndpoint: String?
    public let hostTitle: String?

    public var parameters: [String: Any] {
        var value: [String: Any] = ["provider": provider, "native_session_id": nativeSessionID, "workspace_path": workspacePath]
        if let nativeEndpoint { value["native_endpoint"] = nativeEndpoint }
        if let hostTitle { value["host_title"] = hostTitle }
        return value
    }

    public static func discover() -> NativeSessionContext? {
        guard let host = closestNativeHost() else { return nil }
        let environment = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let registry = host.provider == "claude" ? claudeRegistry(pid: host.pid) : nil
        return observed(provider: host.provider, environment: environment, currentDirectory: cwd, registry: registry)
    }

    public static func discovery(registryDirectory: URL? = nil) -> NativeSessionDiscovery {
        discovery(host: closestNativeHost(), environment: ProcessInfo.processInfo.environment,
                  currentDirectory: FileManager.default.currentDirectoryPath, registryDirectory: registryDirectory)
    }

    static func discovery(host: (provider: String, pid: Int32)?, environment: [String: String],
                          currentDirectory: String, registryDirectory: URL?) -> NativeSessionDiscovery {
        guard let host else { return .noHost }
        let registry = host.provider == "claude" ? claudeRegistry(pid: host.pid, directory: registryDirectory) : nil
        if host.provider == "claude", currentDirectory.hasPrefix("/"),
           let session = environment["CLAUDE_SESSION_ID"] ?? environment["CLAUDE_CODE_SESSION_ID"],
           let uuid = UUID(uuidString: session) {
            if registry == nil { return .claudeRegistryNotReady(.absent) }
            if let registered = registry?["sessionId"] as? String, UUID(uuidString: registered) != uuid {
                return .claudeRegistryNotReady(.otherSession)
            }
            if let directory = registry?["cwd"] as? String {
                let workspace = canonical(currentDirectory), root = canonical(directory)
                if workspace != root && !workspace.hasPrefix(root + "/") { return .claudeRegistryNotReady(.outsideWorkspace) }
            }
        }
        guard let context = observed(provider: host.provider, environment: environment,
                                     currentDirectory: currentDirectory, registry: registry) else { return .unavailable }
        return .available(context)
    }

    // Kept separate for deterministic parsing tests. Calling code cannot select a
    // native provider through MCP arguments; discover() uses kernel ancestry.
    static func observed(provider: String, environment: [String: String], currentDirectory: String,
                         registry: [String: Any]? = nil) -> NativeSessionContext? {
        guard currentDirectory.hasPrefix("/") else { return nil }
        let workspace = canonical(currentDirectory)
        var session: String?
        var endpoint: String?
        var title: String?
        switch provider {
        case "codex":
            // A child UUID wins. An invalid child UUID must not select its parent.
            session = environment["CODEX_THREAD_ID"] ?? environment["CODEX_SESSION_ID"]
        case "claude":
            session = environment["CLAUDE_SESSION_ID"] ?? environment["CLAUDE_CODE_SESSION_ID"]
            endpoint = environment["CLAUDE_CODE_MESSAGING_SOCKET"]
            if let registry {
                guard let registered = registry["sessionId"] as? String,
                      let directory = registry["cwd"] as? String else { return nil }
                let root = canonical(directory)
                guard workspace == root || workspace.hasPrefix(root + "/") else { return nil }
                if let session, UUID(uuidString: session) != UUID(uuidString: registered) { return nil }
                session = registered
                if let registeredEndpoint = registry["messagingSocketPath"] as? String, !registeredEndpoint.isEmpty {
                    if let endpoint, normalizeEndpoint(endpoint) != normalizeEndpoint(registeredEndpoint) { return nil }
                    endpoint = registeredEndpoint
                }
                if let name = registry["name"] as? String, !name.isEmpty {
                    title = String(name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(120))
                }
            }
        default: return nil
        }
        guard let session, let uuid = UUID(uuidString: session) else { return nil }
        if let raw = endpoint {
            let normalized = normalizeEndpoint(raw)
            guard normalized.hasPrefix("/"), !normalized.utf8.contains(0) else { return nil }
            endpoint = normalized
        }
        return NativeSessionContext(provider: provider, nativeSessionID: uuid.uuidString.lowercased(), workspacePath: workspace, nativeEndpoint: endpoint, hostTitle: title)
    }

    private static func closestNativeHost() -> (provider: String, pid: Int32)? {
        var pid = getppid()
        var visited = Set<Int32>()
        for _ in 0..<32 {
            guard pid > 1, visited.insert(pid).inserted else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid() else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let executable = URL(fileURLWithPath: String(cString: path)).lastPathComponent.lowercased()
                if executable == "codex" || executable == "claude" { return (executable, pid) }
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }

    private static func claudeRegistry(pid: Int32, directory: URL? = nil) -> [String: Any]? {
        let root = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let url = root.appendingPathComponent("\(pid).json")
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(),
              attributes.st_mode & 0o022 == 0, attributes.st_size > 0, attributes.st_size <= 65536,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == pid else { return nil }
        return object
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func normalizeEndpoint(_ value: String) -> String {
        value.hasPrefix("uds:") ? String(value.dropFirst(4)) : value
    }
}
