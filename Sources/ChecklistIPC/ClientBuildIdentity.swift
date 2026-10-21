import Foundation
import Security

public struct ClientBuildIdentity: Equatable, Sendable {
    public let identifier: String
    public let cdhash: Data

    public init(identifier: String, cdhash: Data) {
        self.identifier = identifier; self.cdhash = cdhash
    }

    public static func read(_ code: SecStaticCode) -> ClientBuildIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        return .init(identifier: identifier, cdhash: hash)
    }

    public static func executable(_ url: URL) -> ClientBuildIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return read(code)
    }

    public static func running(_ code: SecCode) -> ClientBuildIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return read(staticCode)
    }
}

public enum ClientBuildAdmission: Equatable {
    case current, outdated, refused

    /// Only a current hash can reach commands. An old identifier permits an error reply only.
    public static func classify(_ peer: ClientBuildIdentity?, currentHashes: Set<Data>, checklistIdentifiers: Set<String>) -> Self {
        guard !currentHashes.isEmpty, let peer, !peer.cdhash.isEmpty else { return .refused }
        if currentHashes.contains(peer.cdhash) { return .current }
        return checklistIdentifiers.contains(peer.identifier) ? .outdated : .refused
    }
}

public enum ClientUpdateRequired {
    public static let code = "CLIENT_OUTDATED"
    public static let message = "Checklist was updated. This connection runs an earlier Checklist build; no command ran. The MCP server switches to the installed build by itself; if this error repeats, reconnect the checklist MCP server."
    public static var error: ChecklistError {
        ChecklistError(code, message, details: ["command_outcome": "rejected", "command_executed": false])
    }
}

/// This peer has no router, handler, store or enrollment capability.
public final class OutdatedClientPeer: NSObject, ChecklistRPC {
    public func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        reply(Self.response)
    }

    private static let response = try! JSONSerialization.data(withJSONObject: ["error": [
        "code": ClientUpdateRequired.code, "message": ClientUpdateRequired.message,
        "details": ["command_outcome": "rejected", "command_executed": false]
    ]])
}
