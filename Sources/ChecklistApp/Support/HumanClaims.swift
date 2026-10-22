import Foundation
import Security
import ChecklistIPC

/// Claim credentials are local authority and never part of task exports or preferences.
enum HumanClaims {
    static var service: String { ChecklistInstance.current.humanClaimService }
    static func query(_ attempt: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: attempt]
    }
    static func save(_ token: String, attempt: String) throws {
        try save(token, query: query(attempt))
    }
    static func save(_ token: String, query: [String: Any]) throws {
        KeychainWithoutUI.perform(query) { SecItemDelete($0) }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = KeychainWithoutUI.perform(entry) { SecItemAdd($0, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not save your work claim in Keychain."]) }
    }
    static func read(_ attempt: String) -> String? {
        read(query: query(attempt))
    }
    // An explicit query also lets integration tests restrict access to a temporary
    // keychain; production always uses the instance service and exact account.
    static func read(query: [String: Any]) -> String? {
        try? readRecovery(query: query)
    }
    /// Recovery distinguishes an absent item from one that cannot be read, without
    /// allowing SecurityAgent or changing ordinary claim-read behavior.
    static func readRecovery(_ attempt: String) throws -> String? {
        try readRecovery(query: query(attempt))
    }
    static func readRecovery(query: [String: Any], copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { SecItemCopyMatching($0, $1) }) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = KeychainWithoutUI.perform(query, operation: { copyMatching($0, &item) })
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status),
                          userInfo: [NSLocalizedDescriptionKey: "The saved change could not be read."])
        }
        return value
    }
    static func remove(_ attempt: String) { remove(query: query(attempt)) }
    static func remove(query: [String: Any]) {
        KeychainWithoutUI.perform(query) { SecItemDelete($0) }
    }
}
