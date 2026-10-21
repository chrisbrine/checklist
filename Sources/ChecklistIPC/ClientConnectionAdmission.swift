import Foundation
import Security

/// A PID check selects the peer. XPC still checks the exact hash on every command message.
public struct ClientConnectionAdmission {
    public let requirement: String?
    public let currentHashes: Set<Data>
    private let identifiers: Set<String>
    private let identitySource: (NSXPCConnection) -> ClientBuildIdentity?

    public init(currentClients: [ClientBuildIdentity], checklistIdentifiers: Set<String>,
                identitySource: @escaping (NSXPCConnection) -> ClientBuildIdentity? = Self.processIdentity) {
        currentHashes = Set(currentClients.map(\.cdhash))
        identifiers = checklistIdentifiers
        self.identitySource = identitySource
        let text = currentClients.map { "cdhash H\"" + $0.cdhash.map { String(format: "%02x", $0) }.joined() + "\"" }.joined(separator: " or ")
        var parsed: SecRequirement?
        requirement = !currentClients.isEmpty && currentClients.allSatisfy { !$0.cdhash.isEmpty }
            && SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess ? text : nil
    }

    public static func processIdentity(_ connection: NSXPCConnection) -> ClientBuildIdentity? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return nil }
        return ClientBuildIdentity.running(guest)
    }

    public func accept(_ connection: NSXPCConnection, peer: () -> any ChecklistRPC) -> Bool {
        guard requirement != nil else { return false }
        switch ClientBuildAdmission.classify(identitySource(connection), currentHashes: currentHashes, checklistIdentifiers: identifiers) {
        case .current:
            guard let requirement else { return false }
            connection.setCodeSigningRequirement(requirement)
            connection.exportedObject = peer()
        case .outdated:
            connection.exportedObject = OutdatedClientPeer()
        case .refused:
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: ChecklistRPC.self)
        connection.resume()
        return true
    }
}
