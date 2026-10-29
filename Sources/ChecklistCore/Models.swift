@_exported import ChecklistDomain
import Foundation
import CryptoKit
import GRDB

public struct Caller: Codable, Sendable {
    public var role: String
    public var installation: String
    public var projectIDs: [String]
    public var sessionID: String?
    public var workspace: String?
    public var assistantGrants: [String: [String: Bool]]
    public var executionDomain: String?
    public init(role: String, installation: String, projectIDs: [String], sessionID: String? = nil, workspace: String? = nil, assistantGrants: [String: [String: Bool]] = [:], executionDomain: String? = nil) {
        self.role = role; self.installation = installation; self.projectIDs = projectIDs; self.sessionID = sessionID; self.workspace = workspace; self.assistantGrants = assistantGrants; self.executionDomain = executionDomain
    }
    var principal: String { installation + ":" + (sessionID ?? role) }
    var isOwner: Bool { role == CallerRole.owner.rawValue }
}

public struct CoreError: Error, LocalizedError, @unchecked Sendable {
    public let code: String
    public let message: String
    public let details: [String: Any]
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, details: [String: Any] = [:]) { self.code = code; self.message = message; self.details = details }
    public var dictionary: [String: Any] { ["code": code, "message": message, "retryable": false, "details": details] }
}

typealias JSON = [String: Any]
func jsonString(_ value: Any) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else { throw CoreError("INVALID_INPUT", "Expected a JSON object or array.") }
    return String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
}
func jsonObject(_ text: String) -> JSON { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON ?? [:] }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func uuid() -> String { UUID().uuidString.lowercased() }
func now() -> String { ISO8601DateFormatter().string(from: Date()) }
func text(_ p: JSON, _ key: String, max: Int = 65536, required: Bool = true) throws -> String {
    guard let value = p[key] as? String else { if required { throw CoreError("INVALID_INPUT", "\(key) is required.") }; return "" }
    guard value.utf8.count <= max, !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError("INVALID_INPUT", "\(key) must contain text and be at most \(max) bytes.") }
    return value
}
func int(_ p: JSON, _ key: String, default value: Int = 0) -> Int { (p[key] as? NSNumber)?.intValue ?? value }
func bool(_ p: JSON, _ key: String, default value: Bool = false) -> Bool { (p[key] as? Bool) ?? value }
func strings(_ p: JSON, _ key: String) -> [String] { p[key] as? [String] ?? [] }
func canonical(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
func containsPath(_ root: String, _ child: String) -> Bool { child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

func chronologicalMessages(_ messages: [JSON]) -> [JSON] {
    messages.enumerated().sorted { lhs,rhs in
        let left = lhs.element["created_at"] as? String ?? "",right = rhs.element["created_at"] as? String ?? ""
        // Records arrive in creation order. Preserve that order for equal, whole-second timestamps.
        return left == right ? lhs.offset < rhs.offset : left < right
    }.map { $0.element }
}
