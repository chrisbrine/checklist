import Foundation
import Darwin
import ChecklistProviders

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

    public static func discover(providerRegistry: ProviderPluginRegistry = .bundled) -> NativeSessionContext? {
        guard let host = closestNativeHost(providerRegistry: providerRegistry),
              let plugin = providerRegistry.plugin(host.provider, requiring: .workSession) else { return nil }
        let environment = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let registry = nativeRegistry(plugin: plugin, pid: host.pid)
        return observed(provider: host.provider, environment: environment, currentDirectory: cwd, registry: registry,
                        providerRegistry: providerRegistry)
    }

    public static func discovery(registryDirectory: URL? = nil, providerRegistry: ProviderPluginRegistry = .bundled) -> NativeSessionDiscovery {
        discovery(host: closestNativeHost(providerRegistry: providerRegistry), environment: ProcessInfo.processInfo.environment,
                  currentDirectory: FileManager.default.currentDirectoryPath, registryDirectory: registryDirectory,
                  providerRegistry: providerRegistry)
    }

    static func discovery(host: (provider: String, pid: Int32)?, environment: [String: String],
                          currentDirectory: String, registryDirectory: URL?,
                          providerRegistry: ProviderPluginRegistry = .bundled) -> NativeSessionDiscovery {
        guard let host else { return .noHost }
        guard let plugin = providerRegistry.plugin(host.provider, requiring: .workSession) else { return .unavailable }
        let registry = nativeRegistry(plugin: plugin, pid: host.pid, directory: registryDirectory)
        if let failure = (plugin as? NativeBootstrapDiagnostics)?.discoveryFailure(environment: environment,
            currentDirectory: currentDirectory, registry: registry) { return failure }
        guard let context = observed(provider: host.provider, environment: environment,
                                     currentDirectory: currentDirectory, registry: registry,
                                     providerRegistry: providerRegistry) else { return .unavailable }
        return .available(context)
    }

    // Kept separate for deterministic parsing tests. Calling code cannot select a
    // native provider through MCP arguments; discover() uses kernel ancestry.
    static func observed(provider: String, environment: [String: String], currentDirectory: String,
                         registry: [String: Any]? = nil, providerRegistry: ProviderPluginRegistry = .bundled) -> NativeSessionContext? {
        guard let plugin = providerRegistry.plugin(provider, requiring: .workSession),
              let observation = plugin.observe(environment: environment, workspace: currentDirectory, registry: registry) else { return nil }
        return NativeSessionContext(provider: plugin.manifest.providerID, nativeSessionID: observation.sessionID,
                                    workspacePath: observation.workspace, nativeEndpoint: observation.endpoint, hostTitle: observation.title)
    }

    private static func closestNativeHost(providerRegistry: ProviderPluginRegistry) -> (provider: String, pid: Int32)? {
        var pid = getppid()
        var visited = Set<Int32>()
        for _ in 0..<32 {
            guard pid > 1, visited.insert(pid).inserted else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid() else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let executable = URL(fileURLWithPath: String(cString: path)).lastPathComponent.lowercased()
                if let provider = providerRegistry.workProviders.first(where: {
                    providerRegistry.plugin($0, requiring: .workSession)?.nativeHost?.executable == executable
                }) { return (provider, pid) }
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }

    private static func nativeRegistry(plugin: any ChecklistProviderPlugin, pid: Int32, directory: URL? = nil) -> [String: Any]? {
        guard let path = plugin.nativeHost?.registryPath(processID: pid) else { return nil }
        let url = directory?.appendingPathComponent("\(pid).json") ?? URL(fileURLWithPath: path)
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(),
              attributes.st_mode & 0o022 == 0, attributes.st_size > 0, attributes.st_size <= 65536,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == pid else { return nil }
        return object
    }
}
