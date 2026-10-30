import Foundation
import GRDB

/// Error text that may cross the service boundary to a client.
/// A storage-engine error describes the failing SQL statement and its arguments;
/// a client receives a stable code and the SQLite result code only. The service log
/// keeps the full description.
public enum PublicErrorText {
    public static let storageMessage = "The local store could not complete this command. Preserve its command ID and check the current state before a retry."

    /// The `{"error": ...}` value for one failure.
    public static func payload(_ error: Error) -> [String: Any] {
        if let failure = error as? StorageSnapshotFailure {
            let report = StorageFailureReport(failure)
            report.log()
            return ["code": report.code, "message": scrubbed(report.message), "retryable": report.retryable, "details": scrubbedValue(report.details)]
        }
        if let error = error as? CoreError {
            let error = StorageFailureReport.annotated(error)
            return ["code": error.code, "message": scrubbed(error.message), "retryable": error.details["retryable"] as? Bool ?? false, "details": scrubbedValue(error.details)]
        }
        if let error = error as? DatabaseError {
            return ["code": "STORAGE_ERROR", "message": storageMessage, "retryable": false, "details": ["sqlite_code": Int(error.resultCode.rawValue)]]
        }
        return ["code": "COMMAND_FAILED", "message": describe(error), "retryable": false]
    }

    /// One sentence for an error that another message embeds.
    public static func describe(_ error: Error) -> String {
        if let error = error as? DatabaseError { return "The local store reported SQLite result code \(error.resultCode.rawValue)." }
        if let error = error as? CoreError { return scrubbed(error.message) }
        return scrubbed(error.localizedDescription)
    }

    public static func scrubbed(_ text: String) -> String {
        containsSQL(text) ? storageMessage : text
    }

    public static func scrubbedValue(_ value: Any) -> Any {
        switch value {
        case let text as String: return scrubbed(text)
        case let object as [String: Any]: return object.mapValues { scrubbedValue($0) }
        case let array as [Any]: return array.map { scrubbedValue($0) }
        default: return value
        }
    }

    /// GRDB descriptions start with "SQLite error" and quote the statement after
    /// "while executing"; the keyword pairs catch a statement copied elsewhere.
    public static func containsSQL(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("sqlite error") || lower.contains("while executing") { return true }
        let pairs: [(String, String)] = [("select ", " from "), ("insert into ", ""), ("insert or ", " into "), ("update ", " set "), ("delete from ", ""), ("create table", ""), ("create index", ""), ("drop table", ""), ("alter table", ""), ("pragma ", "")]
        return pairs.contains { first, second in
            guard let range = lower.range(of: first) else { return false }
            return second.isEmpty || lower[range.upperBound...].contains(second)
        }
    }
}
