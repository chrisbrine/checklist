import Foundation
import GRDB

extension CommandRouter {
    /// Linked messages are the sole source of correction markers; the original
    /// body, author, origin and delivery rows are never rewritten.
    func appendNoteRevision(_ db: Database, original: JSON, message: inout JSON, params: JSON, caller: Caller) throws {
        if original["origin"] as? String == "human_ui" { try owner(caller) }
        guard original["human_response_id"] == nil, original["human_request_id"] == nil else {
            throw CoreError("INVALID_INPUT", "Request answers keep their own answer history. Only ordinary notes can be corrected or retracted here.")
        }
        let retraction = params["kind"] as? String == "retraction"
        message["correction_of"] = original["id"]
        message["kind"] = retraction ? "retraction" : "correction"
        message["corrected_origin"] = original["origin"]
        message["requires_action"] = false
        if bool(original, "requires_action") {
            guard let tid = original["task_id"] as? String else { throw CoreError("INVALID_INPUT", "Only ticket directions can be retracted through this note flow.") }
            let pid = try StoredRecord(original, family: "message").string("project_id")
            let mid = try StoredRecord(original, family: "message").string("id")
            let acknowledged =
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? AND "
                        + "json_extract(data,'$.state') IN ('acknowledged','addressed'))", arguments: [pid, mid]) ?? false
            message["direction_already_addressed"] = bool(original, "addressed")
            message["direction_already_acknowledged"] = acknowledged
            message["direction_effect"] =
                retraction
                ? "Future action withdrawn; prior acknowledgment and work remain recorded." : "Original direction remains pending unless separately addressed or retracted."
            if retraction {
                let disposition: JSON = [
                    "id": uuid(), "project_id": pid, "task_id": tid, "message_id": mid, "correction_message_id": try StoredRecord(message, family: "message").requiredValue("id"),
                    "state": "retracted", "actor": caller.principal, "origin": "human_ui", "reason": try StoredRecord(message, family: "message").requiredValue("body"),
                    "after_addressed": bool(original, "addressed"), "revision": 1, "created_at": now(),
                ]
                try save(db, disposition, type: "direction_disposition")
            }
        }
    }

    static func unretractedDirectionSQL(_ alias: String = "records") -> String {
        "NOT EXISTS (SELECT 1 FROM records withdrawn WHERE withdrawn.type='direction_disposition' AND withdrawn.project_id=\(alias).project_id "
            + "AND json_extract(withdrawn.data,'$.message_id')=\(alias).id AND json_extract(withdrawn.data,'$.state')='retracted')"
    }

    func hasPendingDirections(_ db: Database, task: JSON) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM records WHERE type='message' AND project_id=? AND json_extract(data,'$.task_id')=? AND "
                + "json_extract(data,'$.requires_action')=1 AND COALESCE(json_extract(data,'$.addressed'),0)=0 AND " + Self.unretractedDirectionSQL() + ")",
            arguments: [try StoredRecord(task, family: "task").string("project_id"), try StoredRecord(task, family: "task").string("id")]) ?? false
    }

    func noteRevisionProjection(_ db: Database, messages: [JSON], project: String) throws -> [JSON] {
        guard !messages.isEmpty else { return [] }
        let ids = try jsonString(messages.compactMap { $0["id"] as? String })
        // Keep selected conversation reads bounded even after many corrections.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Self.canonicalRecordColumns), correction_count, has_retraction FROM (
                  SELECT *, row_number() OVER (PARTITION BY json_extract(data,'$.correction_of') ORDER BY rowid DESC) correction_position,
                    count(*) OVER (PARTITION BY json_extract(data,'$.correction_of')) correction_count,
                    max(CASE WHEN json_extract(data,'$.kind')='retraction' THEN 1 ELSE 0 END) OVER (PARTITION BY json_extract(data,'$.correction_of')) has_retraction
                  FROM records WHERE type='message' AND project_id=? AND json_extract(data,'$.correction_of') IN (SELECT value FROM json_each(?))
                ) WHERE correction_position<=10 ORDER BY correction_position DESC
                """, arguments: [project, ids])
        var byOriginal: [SnapshotRecordIdentity: [JSON]] = [:]
        var counts: [SnapshotRecordIdentity: Int] = [:]
        var retracted = Set<SnapshotRecordIdentity>()
        for row in rows {
            let value = try GRDBRecordEnvelopeAdapter.decode(row).object
            let key = SnapshotRecordIdentity(try StoredRecord(value, family: "message").string("correction_of"))
            byOriginal[key, default: []].append(value)
            counts[key] = row["correction_count"] as Int
            if (row["has_retraction"] as Int) == 1 { retracted.insert(key) }
        }
        return try messages.map { message in
            var result = message
            let key = SnapshotRecordIdentity(try StoredRecord(message, family: "message").string("id"))
            let revisions = byOriginal[key] ?? []
            result["note_revisions"] = revisions
            result["note_revision_count"] = counts[key] ?? 0
            result["note_revisions_truncated"] = (counts[key] ?? 0) > revisions.count
            result["note_revision_state"] = retracted.contains(key) ? "retracted" : revisions.isEmpty ? "original" : "corrected"
            return result
        }
    }
}
