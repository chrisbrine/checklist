import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    /// Owner diagnostics contain aggregates only. Never export record data or dynamic labels.
    static let diagnosticRecordTypes: Set<String> = Set([
        "project", "task", "status", "tag", "message", "request", "attachment", "attempt",
        "session", "profile", "group", "review", "review_request", "finding", "finding_resolution",
        "manifest", "source_capture", "source_execution", "checkpoint", "direction_disposition",
        "relation", "task_alias", "policy_revision", "taxonomy_revision", "project_context_revision",
        "batch", "batch_disposition", "storage_hold", "cleanup_preview", "handoff", "delegation"
    ]).union(MediaRecordRegistry.families)

    func diagnosticsSummary(_ db: Database,_ params: JSON,_ caller: Caller) throws -> JSON {
        let pid: String?
        if caller.isOwner { pid = nil }
        else {
            let projectID = try scope(db,params,caller)
            try requireAgentEditAuthority(db,project:try record(db,projectID,type:"project"),caller:caller)
            pid = projectID
        }
        var counts = Dictionary(uniqueKeysWithValues: Self.diagnosticRecordTypes.map { ($0, 0) })
        counts["other"] = 0
        for row in try Row.fetchAll(db, sql: "SELECT type,COUNT(*) AS record_count FROM records" + (pid == nil ? "" : " WHERE project_id = CAST(? AS TEXT)") + " GROUP BY type", arguments: StatementArguments(pid.map { [Data($0.utf8)] } ?? [])) {
            let type: String = row["type"]
            let key = Self.diagnosticRecordTypes.contains(type) ? type : "other"
            counts[key, default: 0] += row["record_count"] as Int
        }
        counts["event"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events" + (pid == nil ? "" : " WHERE project_id = CAST(? AS TEXT)"), arguments: StatementArguments(pid.map { [Data($0.utf8)] } ?? [])) ?? 0
        if pid == nil { counts["command_receipt"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commands") ?? 0 }
        return [
            "schema_version": 1,
            "observed_at": now(),
            "service": ["version": ChecklistBuildVersion.current.version, "build_id": ChecklistBuildVersion.current.buildID, "build_number": ChecklistBuildVersion.current.buildNumber, "state": "responsive"],
            "record_counts": counts
        ]
    }
}
