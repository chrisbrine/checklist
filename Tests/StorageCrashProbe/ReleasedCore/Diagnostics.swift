import Foundation
import GRDB

extension CommandRouter {
    /// Owner diagnostics contain aggregates only. Never export record data or dynamic labels.
    static let diagnosticRecordTypes: Set<String> = [
        "project", "task", "status", "tag", "message", "request", "attachment", "attempt",
        "session", "profile", "group", "review", "review_request", "finding", "finding_resolution",
        "manifest", "source_capture", "source_execution", "checkpoint", "direction_disposition",
        "relation", "task_alias", "policy_revision", "taxonomy_revision", "project_context_revision",
        "batch", "storage_hold", "cleanup_preview", "handoff", "delegation"
    ]

    func diagnosticsSummary(_ db: Database,_ caller: Caller) throws -> JSON {
        try owner(caller)
        var counts = Dictionary(uniqueKeysWithValues: Self.diagnosticRecordTypes.map { ($0, 0) })
        counts["other"] = 0
        for row in try Row.fetchAll(db, sql: "SELECT type,COUNT(*) AS record_count FROM records GROUP BY type") {
            let type: String = row["type"]
            let key = Self.diagnosticRecordTypes.contains(type) ? type : "other"
            counts[key, default: 0] += row["record_count"] as Int
        }
        counts["event"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0
        counts["command_receipt"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commands") ?? 0
        return [
            "schema_version": 1,
            "observed_at": now(),
            "service": ["version": "0.1.0", "state": "responsive"],
            "record_counts": counts
        ]
    }
}
