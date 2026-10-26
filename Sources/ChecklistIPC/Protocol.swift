import Foundation
import Security
import LocalAuthentication
import Darwin
import ChecklistLegacyKeychain

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
    private let detailValues: [String: DiagnosticValue]
    /// A detached value snapshot: callers never receive shared diagnostic objects.
    public var details: [String: Any] { detailValues.mapValues(\.value) }
    public var errorDescription: String? {
        let identity = (details["command_id"] as? String).map { " Command ID: \($0)." } ?? ""
        let reason = ["BACKUP_CAPACITY_EXCEEDED", "BACKUP_DEADLINE_EXCEEDED"].contains(code)
            ? (details["reason"] as? String).map { " Reason: \($0)." } ?? "" : ""
        return "\(code): \(message)" + reason + identity
    }
    public init(_ code: String, _ message: String, details: [String: Any] = [:]) { self.code = code; self.message = message; self.detailValues = details.mapValues(DiagnosticValue.init) }
}

/// Error diagnostics cross dispatch/actor boundaries. Preserve JSON fields and
/// common Foundation values; unsupported reference objects become descriptions
/// rather than retaining mutable objects whose owner cannot be established.
private indirect enum DiagnosticValue: Sendable {
    case string(String), bool(Bool), integer(Int), unsigned(UInt), number(Double)
    case null, array([DiagnosticValue]), object([String: DiagnosticValue])
    case data(Data), date(Date), url(URL), uuid(UUID)

    init(_ value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else if String(cString: value.objCType) == "Q" { self = .unsigned(value.uintValue) }
            else if ["f", "d"].contains(String(cString: value.objCType)) { self = .number(value.doubleValue) }
            else { self = .integer(value.intValue) }
        case is NSNull: self = .null
        case let value as [String: Any]: self = .object(value.mapValues(DiagnosticValue.init))
        case let value as [Any]: self = .array(value.map(DiagnosticValue.init))
        case let value as Data: self = .data(value)
        case let value as Date: self = .date(value)
        case let value as URL: self = .url(value)
        case let value as UUID: self = .uuid(value)
        default: self = .string(String(reflecting: value))
        }
    }

    var value: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .integer(let value): value
        case .unsigned(let value): value
        case .number(let value): value
        case .null: NSNull()
        case .array(let values): values.map(\.value)
        case .object(let values): values.mapValues(\.value)
        case .data(let value): value
        case .date(let value): value
        case .url(let value): value
        case .uuid(let value): value
        }
    }
}

/// Both the file-based login keychain and Data Protection keychain must fail
/// without UI. The legacy interaction flag is process-wide, so serialize every
/// Checklist keychain operation and restore the caller's setting afterwards.
public enum KeychainWithoutUI {
    private static let lock = NSLock()

    @discardableResult
    public static func perform(_ attributes: [String: Any], operation: (CFDictionary) -> OSStatus) -> OSStatus {
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

public enum ChecklistKeychain {
    private static var service: String { ChecklistInstance.current.keychainService }
    public static func read(_ account: String) throws -> String? {
        try read(query: [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account])
    }
    // Tests scope the same production reader to their own temporary keychain.
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
    public static func write(_ account: String, _ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = KeychainWithoutUI.perform(query) { SecItemUpdate($0, values as CFDictionary) }
        if status == errSecItemNotFound {
            var add = query.merging(values) { _, new in new }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Grant only the three signed executables from this exact installation.
            let directory = ChecklistPaths.serviceExecutable.deletingLastPathComponent()
            var trusted: [SecTrustedApplication] = []
            for name in ["ChecklistApp", "ChecklistService", "checklist"] {
                var application: SecTrustedApplication?
                if ChecklistTrustedApplicationCreateFromPath(directory.appendingPathComponent(name).path, &application) == errSecSuccess, let application { trusted.append(application) }
            }
            if !trusted.isEmpty {
                var access: SecAccess?
                if ChecklistAccessCreate("Checklist paired local executables" as CFString, trusted as CFArray, &access) == errSecSuccess, let access { add[kSecAttrAccess as String] = access }
            }
            status = KeychainWithoutUI.perform(add) { SecItemAdd($0, nil) }
        }
        guard status == errSecSuccess else { throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot save pairing (\(status)).") }
    }
    public static func checkRemovalStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot restore the previous paired credential (\(status)).") }
    }
    public static func removeChecked(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        try checkRemovalStatus(KeychainWithoutUI.perform(query) { SecItemDelete($0) })
    }
    public static func remove(_ account: String) { try? removeChecked(account) }
}
