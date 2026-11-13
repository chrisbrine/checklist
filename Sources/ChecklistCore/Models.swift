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
/// Two lowercase hexadecimal digits for each byte: the same bytes as `String(format: "%02x")`
/// for each byte, without a format parse and a String for each byte (CL-363).
private let lowercaseHexDigits: [UInt8] = Array("0123456789abcdef".utf8)
func lowercaseHex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var text: [UInt8] = []
    text.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes { text.append(lowercaseHexDigits[Int(byte >> 4)]); text.append(lowercaseHexDigits[Int(byte & 0x0f)]) }
    return String(decoding: text, as: UTF8.self)
}
func hash(_ data: Data) -> String { lowercaseHex(SHA256.hash(data: data)) }
func uuid() -> String { UUID().uuidString.lowercased() }
func now() -> String { StoredClock.shared.currentString() }
/// CL-363: `now()` and other call sites built a new `ISO8601DateFormatter` for each timestamp.
/// This type owns one formatter with the default options (internet date time, GMT). Each
/// function returns what a new default formatter returns for the same input.
///
/// Thread safety: every use of the formatter and of the cached value holds `lock`. The type
/// has no other state, so any thread may call it.
final class StoredClock: @unchecked Sendable {
    static let shared = StoredClock()
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var cachedSecond = -Double.infinity
    private var cachedText = ""
    /// The same result as `ISO8601DateFormatter().string(from:)`.
    func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
    /// The text of the current time (or of `date`). Calls in one second share one formatter
    /// call. The formatter rounds a date to a millisecond before it drops the fraction, so
    /// the kept text serves only a date in the middle of its second (2 ms to 997 ms), where
    /// every rounding rule gives that second. A date near a second boundary asks the formatter.
    func currentString(at date: Date = Date()) -> String {
        let seconds = date.timeIntervalSinceReferenceDate
        let whole = seconds.rounded(.down), fraction = seconds - whole
        lock.lock(); defer { lock.unlock() }
        guard fraction >= 0.002, fraction <= 0.997 else { return formatter.string(from: date) }
        if whole == cachedSecond { return cachedText }
        let text = formatter.string(from: date)
        cachedSecond = whole; cachedText = text
        return text
    }
    /// The same result as `ISO8601DateFormatter().date(from:)`.
    func date(from text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}
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
