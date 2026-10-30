import Foundation
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
