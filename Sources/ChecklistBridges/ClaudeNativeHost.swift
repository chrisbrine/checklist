import Foundation
import CoreFoundation
import ChecklistProviders

/// Native I/O adapters belong to reviewed bundled plugins. The portable plugin
/// target parses observed bootstrap values; these adapters interpret its host's
/// startup diagnostics and registry identity without adding a native route.
protocol NativeBootstrapDiagnostics {
    func discoveryFailure(environment: [String: String], currentDirectory: String, registry: [String: Any]?) -> NativeSessionDiscovery?
}

protocol NativeRegistryIdentityReader {
    func registryIdentity(_ object: [String: Any]) -> (processID: Int32, sessionID: String)?
}

extension ClaudeProviderPlugin: NativeBootstrapDiagnostics, NativeRegistryIdentityReader {
    func nativeEndpointPID(_ endpoint: String) -> Int32? {
        NativeReplyRouting.endpointPID(endpoint)
    }

    func expectedNativeEndpoint(_ processID: Int32) -> String? {
        processID > 1 ? "/tmp/cc-socks/\(processID).sock" : nil
    }

    func validatesNativeEndpoint(_ endpoint: String) -> Bool {
        endpoint.hasPrefix("/tmp/cc-socks/") && endpoint.hasSuffix(".sock")
    }

    func parseNativeHostStatus(_ object: [String: Any]) -> NativeProviderHostStatus? {
        guard let status = ClaudePeerMessageStatus.parse(object) else { return nil }
        return .init(status: status.status, deliveryState: status.deliveryState,
                     originalMessageID: status.originalMessageID, noticeID: status.noticeID,
                     protocolVersion: status.protocolVersion, reason: status.reason)
    }

    func parseNativeReply(_ object: [String: Any]) -> (messageID: String, body: String)? {
        guard object["type"] as? String == "user", let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return NativeReplyRouting.reply(in: content)
    }

    func discoveryFailure(environment: [String: String], currentDirectory: String, registry: [String: Any]?) -> NativeSessionDiscovery? {
        guard currentDirectory.hasPrefix("/"),
              let session = environment["CLAUDE_SESSION_ID"] ?? environment["CLAUDE_CODE_SESSION_ID"],
              let uuid = UUID(uuidString: session) else { return nil }
        guard let registry else { return .claudeRegistryNotReady(.absent) }
        if let registered = registry["sessionId"] as? String, UUID(uuidString: registered) != uuid {
            return .claudeRegistryNotReady(.otherSession)
        }
        if let directory = registry["cwd"] as? String {
            let workspace = canonical(currentDirectory), root = canonical(directory)
            if workspace != root && !workspace.hasPrefix(root + "/") { return .claudeRegistryNotReady(.outsideWorkspace) }
        }
        return nil
    }

    func registryIdentity(_ object: [String: Any]) -> (processID: Int32, sessionID: String)? {
        guard let pid = object["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
              pid.doubleValue == Double(pid.int32Value), pid.int32Value > 1,
              let session = object["sessionId"] as? String, UUID(uuidString: session) != nil,
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        return (pid.int32Value, session)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
