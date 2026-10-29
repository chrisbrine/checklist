import Foundation
import GRDB

extension CommandRouter {
    /// Exact old-generation receipts only. The original records and their fences
    /// are immutable; queueDirectionDeliveries deduplicates the new generation.
    private func nativeClosureNotices(_ db: Database, closure: JSON) throws -> [JSON] {
        let pid = try StoredRecord(closure, family: "native_closure").string("project_id")
        let sid = try StoredRecord(closure, family: "native_closure").string("session_id")
        let generation = try StoredRecord(closure, family: "native_closure").string("old_authorization_generation")
        return try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns
            + " FROM records WHERE type='delivery' AND project_id=?"
            + " AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY"
            + " AND json_extract(data,'$.recipient_authorization_generation')=? COLLATE BINARY ORDER BY rowid",
            arguments: [pid, sid, generation])
            .map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "delivery").object }
            .filter { !["acknowledged", "addressed", "fenced", "quarantined"].contains($0["state"] as? String ?? "") && $0["owner_disconnect_ref"] == nil && $0["restore_incarnation"] == nil }
    }

    private func nativeClosureNoticeMessage(_ db: Database, delivery: JSON, project: String) throws -> JSON? {
        let mid = try StoredRecord(delivery, family: "delivery").string("message_id")
        let message = try scoped(db, mid, project, type: "message")
        guard !bool(message, "addressed") else { return nil }
        if bool(message, "requires_action"),
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM records WHERE type='message' AND project_id=? AND id=? AND " + Self.unretractedDirectionSQL() + ")", arguments: [project, mid]) != true { return nil }
        return message
    }

    func redeliverNativeClosureNotices(_ db: Database, session: JSON, closure: JSON) throws {
        let pid = try StoredRecord(closure, family: "native_closure").string("project_id")
        let sid = try StoredRecord(session, family: "session").string("id")
        for old in try nativeClosureNotices(db, closure: closure) {
            guard let message = try nativeClosureNoticeMessage(db, delivery: old, project: pid) else { continue }
            let receipts = try queueDirectionDeliveries(db, message: message, recipients: [[
                "session_id": sid, "recipient_role": "resumed_conversation",
                "label": "Notice from this conversation's earlier process; its original delivery remains fenced."
            ]])
            if var receipt = receipts.first(where: { $0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == sessionGeneration(session) }) {
                receipt["resumed_from_delivery_id"] = old["id"]
                receipt["resumed_native_closure_ref"] = closure["id"]
                try save(db, receipt, type: "delivery")
            }
        }
    }

    /// Read-only recovery facts are present on the very first service/inbox read,
    /// including for conversations already resumed before this build. Reading the
    /// stable summary is not acknowledgment, a claim or orchestration authority.
    func nativeResumptionRecovery(_ db: Database, caller: Caller, projects: [String]) throws -> [JSON] {
        guard caller.role == "worker", let sid = caller.sessionID else { return [] }
        var result: [JSON] = []
        for pid in Set(projects).sorted() where caller.projectIDs.contains(pid) {
            guard let session = try? scoped(db, sid, pid, type: "session"),
                  canReceive(session, project: pid), !bool(session, "restore_quarantined"),
                  session["installation"] as? String == caller.installation,
                  session["execution_domain"] as? String == caller.executionDomain,
                  session["resumed_at"] != nil,
                  let ref = strings(session, "prior_native_closure_refs").last else { continue }
            _ = try scope(db, ["project_id": pid], caller)
            let closure = try scoped(db, ref, pid, type: "native_closure")
            guard closure["state"] as? String == "released", closure["session_id"] as? String == sid,
                  closure["provider"] as? String == session["provider"] as? String else { continue }
            var claims: [JSON] = []
            for aid in strings(closure, "released_attempt_ids") {
                guard let attempt = try? scoped(db, aid, pid, type: "attempt"),
                      attempt["native_closure_ref"] as? String == ref,
                      attempt["session_id"] as? String == sid,
                      let tid = attempt["task_id"] as? String,
                      let task = try? scoped(db, tid, pid, type: "task") else { continue }
                claims.append(["attempt_id": aid, "task_id": tid, "key": task["key"] ?? "", "title": task["title"] ?? "",
                    "released_at": attempt["released_at"] ?? attempt["updated_at"] ?? closure["observed_at"] ?? NSNull(),
                    "reason": attempt["reason"] ?? "Verified native process and registry closure.",
                    "recovery_step": "Read task_context, then work_claim at the current revision if eligible; the old claim/token stays released."])
            }
            var orchestrations: [JSON] = []
            let groups = try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns
                + " FROM records WHERE type='group' AND project_id=? AND json_extract(data,'$.kind')='triage'"
                + " AND json_extract(data,'$.orchestration.session_id')=? COLLATE BINARY"
                + " AND json_extract(data,'$.orchestration.state')='active' ORDER BY rowid", arguments: [pid, sid])
            for row in groups {
                let group = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: "group").object
                guard !bool(group, "archived") else { continue }
                guard let orchestration = group["orchestration"] as? JSON, orchestration["state"] as? String == "active",
                      orchestration["session_authorization_generation"] as? String != sessionGeneration(session),
                      let orchestrationClosure = try resumedTriageClosure(db, orchestration, session, pid) else { continue }
                let sourceClosure = try scoped(db, orchestrationClosure, pid, type: "native_closure")
                orchestrations.append(["triage_id": group["id"]!, "key": group["key"] ?? "", "title": group["name"] ?? "",
                    "orchestration_id": orchestration["id"]!, "expected_revision": group["revision"]!,
                    "orchestration_connection": "recovery_required", "recovery_required_at": sourceClosure["observed_at"] ?? NSNull(),
                    "recovery_step": "triage_orchestrate action=resume with triage_id, expected_revision and a reason; member tickets require ordinary claims."])
            }
            // This also summarizes backlog from a resumption predating this build.
            // It is one stable summary per resumption, never a delivery/ack receipt.
            let notices: [JSON] = try nativeClosureNotices(db, closure: closure).compactMap { delivery -> JSON? in
                guard let message = try nativeClosureNoticeMessage(db, delivery: delivery, project: pid) else { return nil }
                return ["delivery_id": delivery["id"]!, "message_id": message["id"]!, "created_at": delivery["created_at"] ?? NSNull(),
                    "subject": try subject(db, message: message), "body": message["body"] ?? "", "state": "fenced"]
            }
            result.append(["summary_id": ref + ":" + sessionGeneration(session), "project_id": pid,
                "session_id": sid, "native_closure_ref": ref, "closed_at": closure["observed_at"] ?? NSNull(),
                "resumed_at": session["resumed_at"]!, "released_claims": claims,
                "recovery_required_orchestrations": orchestrations, "fenced_notices": notices,
                "claims_restored": false, "reading_is_acknowledgment": false])
        }
        return result
    }
}
