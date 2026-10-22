import Foundation
import GRDB

extension CommandRouter {
    // Every ticket status boundary uses the same rule: its nonblank reason is
    // current, or no reason clears the previous explanation. Batch and Triage
    // handlers emit these per-ticket events too; group events are not boundaries.
    static let ticketStatusEventKinds = [
        "task_transitioned", "status_changed", "status_remapped",
        "work_claimed", "work_released", "work_submitted", "claim_revoked",
        "work_released_native_closure", "review_requested", "review_reject",
        "human_approval_reject", "task_completed"
    ]

    func currentStatusReason(_ db: Database, task: JSON) throws -> JSON? {
        guard let pid = task["project_id"] as? String, let tid = task["id"] as? String else { return nil }
        let kinds = Self.ticketStatusEventKinds.map { _ in "?" }.joined(separator: ",")
        // The existing events_scope index selects this exact ticket. Only the
        // latest status event is decoded; notes and other project history are not.
        let arguments: [DatabaseValueConvertible] = [Data(pid.utf8), Data(tid.utf8)] + Self.ticketStatusEventKinds
        guard let row = try Row.fetchOne(db, sql: "SELECT actor,kind,occurred_at,data FROM events WHERE project_id=CAST(? AS TEXT) AND entity_id=CAST(? AS TEXT) AND kind IN (" + kinds + ") ORDER BY seq DESC LIMIT 1", arguments: StatementArguments(arguments)) else { return nil }
        let data = jsonObject(row["data"]), kind: String = row["kind"]
        guard let reason = data["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let target = data["to_status_id"] as? String {
            guard EnvelopeStorageIdentity.equal(target, task["status_id"] as? String ?? "") else { return nil }
        } else if kind == "work_released" {
            // Older release events have no status ID. Both implementation and
            // review releases are supported; a later status event still clears it.
            let status = try? scoped(db, task["status_id"] as? String ?? "", pid, type: "status")
            guard ["queued", "review"].contains(status?["category"] as? String ?? "") else { return nil }
        }
        let actor: String = row["actor"]
        let display: String
        if let captured = data["actor_display"] as? String { display = captured }
        else if actor.hasSuffix(":owner") { display = "You" }
        else if let sid = actor.split(separator:":").last,
                let session = try? scoped(db,String(sid),pid,type:"session"), let label = session["label"] as? String { display = label }
        else { display = "Agent" }
        return ["text": reason, "actor": actor, "actor_display": display, "at": row["occurred_at"] as String]
    }

    func withStatusReason(_ db: Database, task: JSON) throws -> JSON {
        var task = task
        task["status_reason"] = try currentStatusReason(db, task: task)
        return task
    }
}
