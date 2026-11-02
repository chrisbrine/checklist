import Foundation
import GRDB

extension CommandRouter {
    /// The bound on repeats when a pickup works and its confirmation does not. It is a read
    /// rule with no write. An older note stays in `pending_notes` metadata and `session_inbox`.
    static let codexHookNoteWindow: TimeInterval = 86_400

    /// Recipient observations are computed after the durable command outcome.
    /// The body is available only to the explicit hook pickup, under inbox authority.
    func pendingNoteCandidates(_ db: Database, params: JSON, caller: Caller, hook: Bool = false) throws -> [(delivery: JSON, message: JSON)] {
        guard caller.role == "worker", let sid = caller.sessionID else { return [] }
        var result: [(rowid: Int64, delivery: JSON, message: JSON)] = []
        var seen = Set<Data>()
        let oldestHookNote = Date().timeIntervalSince1970 - Self.codexHookNoteWindow
        let projects = (params["project_id"] as? String).map { [$0] } ?? caller.projectIDs.sorted()
        for pid in projects where seen.insert(Data(pid.utf8)).inserted {
            guard caller.projectIDs.contains(where: { EnvelopeStorageIdentity.equal($0,pid) }) else { continue }
            do { _ = try scope(db,["project_id":pid],caller) }
            catch let error as CoreError where ["FORBIDDEN","ROOT_MISMATCH","NOT_FOUND"].contains(error.code) { continue }
            // A session read error reaches the decorator as unavailable. It is no proof of an empty inbox.
            guard let session = try pendingNoteRecord(db,sid,pid,type:"session"), session["provider"] as? String == "codex",
                  session["role"] as? String == "worker", canReceive(session,project:pid) else { continue }
            // CASE, not AND: SQLite does not guarantee term order. A malformed row cannot name a recipient, so it matches nobody.
            let rows = try Row.fetchAll(db,sql:"""
                SELECT \(Self.canonicalRecordColumns),rowid AS _pending_rowid FROM records
                WHERE type='delivery' AND project_id=CAST(? AS TEXT)
                  AND CASE WHEN json_valid(data) THEN CASE WHEN json_type(data)='object' THEN
                    (json_extract(data,'$.recipient_session_id')=CAST(? AS TEXT) COLLATE BINARY
                     AND json_extract(data,'$.recipient_authorization_generation')=CAST(? AS TEXT) COLLATE BINARY
                     AND COALESCE(json_extract(data,'$.state'),'queued') NOT IN ('acknowledged','addressed','fenced','quarantined')
                     AND json_type(data,'$.restore_incarnation') IS NULL
                     AND (?=0 OR (json_type(data,'$.hook_state') IS NULL AND checklist_timestamp(json_extract(data,'$.created_at'))>=?)))
                    ELSE 0 END ELSE 0 END
                AND NOT EXISTS (SELECT 1 FROM records m WHERE m.type='message' AND m.project_id=records.project_id
                    AND m.id=CASE WHEN json_valid(records.data) THEN json_extract(records.data,'$.message_id') END
                    AND CASE WHEN json_valid(m.data) THEN (json_type(m.data,'$.human_response_id')='text' OR json_extract(m.data,'$.origin')='system') ELSE 0 END)
                ORDER BY rowid DESC LIMIT 9
                """,arguments:[Data(pid.utf8),Data(sid.utf8),Data(sessionGeneration(session).utf8),hook ? 1 : 0,oldestHookNote])
            for row in rows {
                let delivery = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"delivery").object
                guard try deliveryCurrent(db,delivery),try deliveryNativeClosure(db,delivery) == nil,
                      let mid = delivery["message_id"] as? String,
                      let message = try pendingNoteRecord(db,mid,pid,type:"message"),message["human_response_id"] == nil,
                      message["origin"] as? String != "system" else { continue } // CL-389/412 relay limits stay in charge of health notes.
                result.append((row["_pending_rowid"],delivery,message))
            }
        }
        // Newest first across the caller's projects, so older notes cannot hide a new one.
        return result.sorted { $0.rowid > $1.rowid }.prefix(9).map { ($0.delivery,$0.message) }
    }

    private func pendingNoteRecord(_ db: Database, _ id: String, _ project: String, type: String) throws -> JSON? {
        do { return try scoped(db,id,project,type:type) }
        catch let error as CoreError where error.code == "NOT_FOUND" { return nil }
    }

    func pendingNoteItem(_ db: Database, _ candidate: (delivery: JSON, message: JSON)) throws -> JSON {
        let delivery = candidate.delivery, message = candidate.message
        let reference = try subject(db,message:message)
        var item: JSON = ["project_id":delivery["project_id"] ?? "", "message_id":message["id"] ?? "",
            "delivery_id":delivery["id"] ?? "", "delivery_state":delivery["state"] ?? "queued", "subject":reference]
        for key in ["task_id","kind","origin","author_display"] { item[key] = message[key] }
        if reference["kind"] as? String == "ticket" { item["task_key"] = reference["key"];item["task_title"] = reference["title"] }
        item["project_name"] = reference["project_name"]
        return item
    }

    func addingPendingNoteNotices(_ db: Database, output: JSON, params: JSON, caller: Caller) throws -> JSON {
        let pending = try pendingNoteCandidates(db,params:params,caller:caller)
        guard !pending.isEmpty,var data = output["data"] as? JSON else { return output }
        let items = try pending.prefix(8).map { try pendingNoteItem(db,$0) }
        var metadata = data["_checklist"] as? JSON ?? [:]
        metadata["pending_notes"] = ["schema_version":1,"status":"pending_pickup","channel":"authenticated_tool_result",
            "observation":"live_recipient_delivery_state_not_cached_command_outcome","native_codex_wake_qualified":false,
            "items":items,"has_more":pending.count > 8]
        data["_checklist"] = metadata
        var result = output;result["data"] = data
        return result
    }

    /// A read: no write and no `commands` row. A delivery stays unconfirmed until `codexHookConfirm`,
    /// so a lost output or a failed confirmation shows the note again at a later tool call.
    func codexHookPickup(_ db: Database, _ params: JSON, _ caller: Caller) throws -> JSON {
        guard caller.role == "worker",caller.sessionID != nil else { throw CoreError("FORBIDDEN","A hook requires an authenticated Codex worker.") }
        let pending = try pendingNoteCandidates(db,params:params,caller:caller,hook:true)
        var items: [JSON] = []
        for candidate in pending.prefix(8) {
            var item = try pendingNoteItem(db,candidate)
            let body = candidate.message["body"] as? String ?? ""
            // Eight 4 KiB excerpts keep hook context bounded. The inbox retains full text.
            var excerpt = String(body.prefix(4096))
            while excerpt.utf8.count > 4096 { excerpt.removeLast() }
            item["body"] = excerpt;item["body_truncated"] = excerpt != body
            items.append(item)
        }
        return ["pending_notes":["schema_version":1,"status":items.isEmpty ? "empty" : "pending_pickup","items":items,"has_more":pending.count > 8]]
    }

    /// Runs after the hook wrote stdout. The receipt holds delivery IDs only, never a note body.
    /// A delivery of another recipient reads as not found. A delivery that left the current
    /// generation, or that a concurrent hook confirmed, is skipped.
    func codexHookConfirm(_ db: Database, _ params: JSON, _ caller: Caller) throws -> JSON {
        guard caller.role == "worker",let sid = caller.sessionID else { throw CoreError("FORBIDDEN","A hook requires an authenticated Codex worker.") }
        guard let ids = params["delivery_ids"] as? [String],(1...8).contains(ids.count),Set(ids).count == ids.count else { throw CoreError("INVALID_INPUT","delivery_ids needs one to eight distinct deliveries.") }
        var confirmed: [String] = [],skipped: [String] = []
        for id in ids {
            var delivery = try record(db,id,type:"delivery")
            guard let pid = delivery["project_id"] as? String,caller.projectIDs.contains(where: { EnvelopeStorageIdentity.equal($0,pid) }),
                  delivery["recipient_session_id"] as? String == sid else { throw CoreError("NOT_FOUND","This delivery is unavailable.") }
            _ = try scope(db,["project_id":pid],caller)
            guard let session = try pendingNoteRecord(db,sid,pid,type:"session"),canReceive(session,project:pid),
                  delivery["recipient_authorization_generation"] as? String == sessionGeneration(session),delivery["hook_state"] == nil,
                  !["acknowledged","addressed","fenced","quarantined"].contains(delivery["state"] as? String ?? ""),
                  try deliveryCurrent(db,delivery) else { skipped.append(id);continue }
            delivery["hook_route"] = "codex_post_tool_use"
            delivery["hook_state"] = "context_written"
            delivery["hook_written_at"] = now()
            delivery["hook_reason"] = "The hook wrote this note to its stdout. Model receipt is unconfirmed. This is not acknowledgment."
            try save(db,revised(delivery),type:"delivery")
            confirmed.append(id)
        }
        return ["confirmed":confirmed,"skipped":skipped]
    }
}
