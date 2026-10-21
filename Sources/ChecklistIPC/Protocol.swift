import Foundation
import Security
import Darwin

@objc public protocol ChecklistRPC {
    func execute(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum ChecklistPaths {
    public static var root: URL { ChecklistInstance.current.root }
    public static var endpoint: URL { root.appendingPathComponent("service.endpoint") }
    public static var serviceExecutable: URL {
        ChecklistInstance.executableURL.deletingLastPathComponent().appendingPathComponent("ChecklistService")
    }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

public struct ChecklistError: LocalizedError {
    public let code: String
    public let message: String
    public let details: [String: Any]
    public var errorDescription: String? {
        let identity = (details["command_id"] as? String).map { " Command ID: \($0)." } ?? ""
        return "\(code): \(message)" + identity
    }
    public init(_ code: String, _ message: String, details: [String: Any] = [:]) { self.code = code; self.message = message; self.details = details }
}

public enum ChecklistKeychain {
    private static var service: String { ChecklistInstance.current.keychainService }
    public static func read(_ account: String) throws -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot read the paired installation (\(status)).")
        }
        return value
    }
    public static func write(_ account: String, _ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var add = query.merging(values) { _, new in new }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Grant only the three signed executables from this exact installation.
            let directory = ChecklistPaths.serviceExecutable.deletingLastPathComponent()
            var trusted: [SecTrustedApplication] = []
            for name in ["ChecklistApp", "ChecklistService", "checklist"] {
                var application: SecTrustedApplication?
                if SecTrustedApplicationCreateFromPath(directory.appendingPathComponent(name).path, &application) == errSecSuccess, let application { trusted.append(application) }
            }
            if !trusted.isEmpty {
                var access: SecAccess?
                if SecAccessCreate("Checklist paired local executables" as CFString, trusted as CFArray, &access) == errSecSuccess, let access { add[kSecAttrAccess as String] = access }
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot save pairing (\(status)).") }
    }
    public static func checkRemovalStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot restore the previous paired credential (\(status)).") }
    }
    public static func removeChecked(_ account: String) throws {
        try checkRemovalStatus(SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary))
    }
    public static func remove(_ account: String) { try? removeChecked(account) }
}
