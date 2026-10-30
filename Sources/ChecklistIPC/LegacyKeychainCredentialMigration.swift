import Foundation
import Security
import LocalAuthentication
import ChecklistLegacyKeychain

/// Both the file-based login keychain and Data Protection keychain must fail
/// without UI. The legacy interaction flag is process-wide, so serialize every
/// Checklist keychain operation and restore the caller's setting afterwards.
enum KeychainWithoutUI {
    private static let lock = NSLock()

    @discardableResult
    static func perform(_ attributes: [String: Any], operation: (CFDictionary) -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        var wasAllowed: DarwinBoolean = false
        let status = ChecklistKeychainGetUserInteractionAllowed(&wasAllowed)
        guard status == errSecSuccess else { return status }
        let disabled = ChecklistKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { return disabled }
        defer { ChecklistKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var query = attributes
        // LAContext is the supported SecItem no-UI mechanism. Keep the legacy
        // guard above for file-based keychain ACLs, which do not honor it.
        let context = LAContext()
        context.interactionNotAllowed = true
        query.removeValue(forKey: kSecUseAuthenticationUI as String)
        query[kSecUseAuthenticationContext as String] = context
        return operation(query as CFDictionary)
    }
}

/// CL-374: the only Keychain call left in product code. The owner decided on 30 Oct 2026
/// (request 8e06c68a, response db9f7d73) that agent installation credentials leave Keychain.
/// InstallationCredentialStore calls this no-UI read only when a credential has no file yet,
/// on the live instance, from a real bundle. It never writes or deletes an item, so a previous
/// bundle still finds its old items after a rollback.
///
/// Removal condition: delete this file, the ChecklistLegacyKeychain target and the legacy read
/// of the store when both hold: (1) every enrollment in the live connections.json has a file
/// record, and (2) the owner no longer keeps a bundle that reads Keychain for rollback.
enum LegacyKeychainCredentialMigration {
    static func read(account: String, service: String) throws -> String? {
        try read(query: [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account])
    }
    // The skipped fixture class scopes the same reader to its own temporary keychain.
    static func read(query: [String: Any]) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = KeychainWithoutUI.perform(query) { SecItemCopyMatching($0, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot read the paired installation (\(status)).")
        }
        return value
    }
}
