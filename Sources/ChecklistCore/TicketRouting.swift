import Foundation
import GRDB

/// CL-248 audience of an ordinary ticket note (docs/triage-orchestrators.md#message-routing).
/// Mandatory notices always use `.all`; an audience never narrows them.
enum TicketAudience: String, CaseIterable { case all, holder, orchestrator }

extension CommandRouter {
    static let ticketAudienceValues = TicketAudience.allCases.map(\.rawValue)

    func ticketAudience(_ p: JSON) throws -> TicketAudience? {
        guard let raw = p["audience"] else { return nil }
        guard let value = raw as? String, let audience = TicketAudience(rawValue: value) else {
            throw CoreError("INVALID_INPUT", "audience is all, holder or orchestrator. No message was saved.")
        }
        return audience
    }

    /// "<Provider> · <first 8 characters of the session ID>", the default Triage name form.
    func sessionThreadLabel(_ session: JSON) -> String {
        (session["provider"] as? String ?? "agent").capitalized + " · " + String((session["id"] as? String ?? "").prefix(8))
    }

    /// The ticket's one Triage that has an active orchestration (CL-125 single membership).
    func ticketOrchestratedTriage(_ db: Database, task: JSON) throws -> JSON? {
        // One indexed project/type read filtered in SQL: a note never decodes every group of the project.
        let stored = try StoredTaskRecord(task)
        let sql = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='group' AND project_id=CAST(? AS TEXT)"
            + " AND json_extract(data,'$.kind')='triage' AND COALESCE(json_extract(data,'$.archived'),0)=0"
            + " AND json_extract(data,'$.orchestration.state')='active'"
            + " AND (EXISTS (SELECT 1 FROM json_each(data,'$.task_ids') WHERE value=CAST(? AS TEXT))"
            + " OR EXISTS (SELECT 1 FROM json_each(data,'$.members') WHERE json_extract(value,'$.task_id')=CAST(? AS TEXT))) ORDER BY rowid"
        let rows = try Row.fetchAll(db, sql: sql, arguments: [Data(stored.projectID.utf8), Data(stored.id.utf8), Data(stored.id.utf8)])
        return try rows.map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "group").object }
            .first { !bool($0, "archived") && triageMemberIDs($0).contains(stored.id) && triageOrchestratorSession($0) != nil }
    }

    /// The orchestrator as a delivery recipient. Nil when its session cannot receive or its
    /// authorization generation no longer matches the orchestration record (an ended route).
    func triageOrchestratorRecipient(_ db: Database, group: JSON) -> JSON? {
        guard let orchestration = group["orchestration"] as? JSON, orchestration["state"] as? String == "active",
              let sid = orchestration["session_id"] as? String, let pid = group["project_id"] as? String,
              let session = try? scoped(db, sid, pid, type: "session"), session["role"] as? String == "worker",
              canReceive(session, project: pid),
              sessionGeneration(session) == orchestration["session_authorization_generation"] as? String else { return nil }
        return ["project_id": pid, "session_id": sid, "recipient_role": "triage_orchestrator", "triage_id": group["id"] ?? NSNull(),
                "display_name": session["label"] ?? sessionThreadLabel(session), "authorization_generation": sessionGeneration(session)]
    }

    /// Holder sessions (handler and accepted subagents) plus the Triage orchestrator: one
    /// recipient per session, none for the sender, with the copy labels of the contract.
    func withTriageOrchestratorCopy(_ db: Database, task: JSON, holders allHolders: [JSON], sender: String?,
                                    audience: TicketAudience = .all) throws -> [JSON] {
        let stored = try StoredTaskRecord(task), pid = stored.projectID
        let key = task["key"] as? String ?? "this ticket"
        let group = try ticketOrchestratedTriage(db, task: task)
        let orchestrator = group.flatMap { triageOrchestratorRecipient(db, group: $0) }
        if audience == .orchestrator {
            guard group != nil else {
                throw CoreError("TRIAGE_ORCHESTRATOR_REQUIRED", "\(key) is not in a Triage with an orchestrator. Use audience all or holder. No message was saved.")
            }
            guard orchestrator != nil else {
                throw CoreError("RECIPIENT_CHANGED", "The Triage orchestrator's route ended or its authorization generation changed. No message was saved.")
            }
        }
        let holderIDs = Set(allHolders.compactMap { $0["session_id"] as? String })
        let root = allHolders.first { $0["recipient_role"] as? String == "handler" } ?? allHolders.first
        let holderThread = (root?["session_id"] as? String).flatMap { try? scoped(db, $0, pid, type: "session") }.map(sessionThreadLabel)
        var holders = audience == .orchestrator ? [] : allHolders.filter { $0["session_id"] as? String != sender }
        guard audience != .holder, var copy = orchestrator, let osid = copy["session_id"] as? String, osid != sender,
              audience == .orchestrator || !holderIDs.contains(osid) else { return holders }
        if let holderThread {
            copy["label"] = !holders.isEmpty ? "Also sent to \(holderThread), which holds \(key)."
                : audience == .orchestrator ? "Sent to the Triage orchestrator only; \(holderThread) holds \(key)."
                : "Sent by \(holderThread), which holds \(key)."
        } else {
            copy["label"] = "\(key) has no current holder; sent to the Triage orchestrator."
        }
        let orchestratorThread = (try? scoped(db, osid, pid, type: "session")).map(sessionThreadLabel) ?? osid
        let triageName = group?["name"] as? String ?? "its Triage"
        holders = holders.map { var holder = $0; holder["label"] = "Also sent to \(orchestratorThread), which orchestrates \(triageName)."; return holder }
        return holders + [copy]
    }

    /// Copies the routing label and Triage of a recipient into its delivery receipt.
    func copyRoleLabel(_ recipient: JSON, into delivery: inout JSON) {
        for key in ["label", "triage_id"] { if let value = recipient[key], !(value is NSNull) { delivery[key] = value } }
    }

    /// Mandatory notices (takeover, handoff): an explicit copy to each earlier holder that
    /// can receive, plus the Triage orchestrator. With no receiving earlier holder the
    /// notice uses the default route (holder and orchestrator, never the sender).
    func roleChangeNotices(_ db: Database, task: JSON, earlier: [String], body: String, caller: Caller) throws -> [JSON] {
        let stored = try StoredTaskRecord(task), pid = stored.projectID, tid = stored.id
        var notices: [JSON] = []
        for holder in earlier {
            guard let target = try? scoped(db, holder, pid, type: "session"), canReceive(target, project: pid) else { continue }
            notices.append(try messageWrite(db, ["project_id": pid, "task_id": tid, "body": body, "recipient": ["kind": "session", "session_id": holder]], caller, "message_send"))
        }
        guard !notices.isEmpty else { return [try messageWrite(db, ["project_id": pid, "task_id": tid, "body": body], caller, "message_send")] }
        let current = try scoped(db, tid, pid, type: "task"), key = current["key"] as? String ?? "this ticket"
        if let group = try ticketOrchestratedTriage(db, task: current), var copy = triageOrchestratorRecipient(db, group: group),
           let osid = copy["session_id"] as? String, osid != caller.sessionID, !earlier.contains(osid) {
            let earlierThread = earlier.first.flatMap { try? scoped(db, $0, pid, type: "session") }.map(sessionThreadLabel) ?? "the earlier holder"
            copy["label"] = "Also sent to \(earlierThread), which held \(key)."
            notices[0]["deliveries"] = try queueDirectionDeliveries(db, message: notices[0], recipients: [copy])
            notices[0]["delivery_status"] = "queued"
        }
        return notices
    }

    /// A note with no ticket: a Triage note (triage_id, also inherited by a reply) to the
    /// orchestrator or an exact recipient, or a project note to an exact recipient.
    func triageNoteRoute(_ db: Database, params p: JSON, project pid: String, explicit: String?,
                         audience: TicketAudience?, caller c: Caller) throws -> (recipients: [JSON], pickupPending: Bool) {
        let original: JSON? = try (p["reply_to"] as? String).map { try scoped(db, $0, pid, type: "message") }
        if let original, original["task_id"] != nil { throw CoreError("INVALID_INPUT", "A reply must retain its original ticket and conversation scope.") }
        if let original, let scope = original["triage_id"] as? String, let mine = p["triage_id"] as? String, scope != mine {
            throw CoreError("INVALID_INPUT", "A reply must retain its original Triage scope. No message was saved.")
        }
        guard let gid = p["triage_id"] as? String ?? original?["triage_id"] as? String else {
            guard let sid = explicit, audience == nil else {
                throw CoreError("INVALID_INPUT", "A note with no ticket and no Triage needs an exact recipient. No message was saved.")
            }
            return ([try exactNoteRecipient(db, sid, project: pid)], false)
        }
        let group = try scoped(db, gid, pid, type: "group")
        guard group["kind"] as? String == "triage" else { throw CoreError("INVALID_INPUT", "Select the matching group kind.") }
        if audience == .holder { throw CoreError("INVALID_INPUT", "A Triage note has no ticket holder. Use audience all or orchestrator. No message was saved.") }
        if let sid = explicit { return ([try exactNoteRecipient(db, sid, project: pid)], false) }
        // A correlated reply with no exact recipient returns to the original note's author.
        if let original, let author = original["author_session_id"] as? String, author != c.sessionID,
           let session = try? scoped(db, author, pid, type: "session"), session["role"] as? String == "worker" {
            guard canReceive(session, project: pid) else {
                throw CoreError("RECIPIENT_CHANGED", "The original sender can no longer receive notes. Name an exact recipient. No message was saved.")
            }
            return ([["session_id": author, "recipient_role": "reply_recipient", "triage_id": gid]], false)
        }
        guard triageOrchestratorSession(group) != nil else {
            if audience == .orchestrator {
                throw CoreError("TRIAGE_ORCHESTRATOR_REQUIRED", "This Triage is a plan with no orchestrator. Name an exact recipient or omit audience to save the note for pickup. No message was saved.")
            }
            return ([], true)
        }
        guard var copy = triageOrchestratorRecipient(db, group: group) else {
            throw CoreError("RECIPIENT_CHANGED", "The Triage orchestrator's route ended or its authorization generation changed. No message was saved.")
        }
        guard copy["session_id"] as? String != c.sessionID else { return ([], false) }
        copy["label"] = "Triage note for \(group["name"] as? String ?? "this Triage")."
        return ([copy], false)
    }

    private func exactNoteRecipient(_ db: Database, _ sid: String, project pid: String) throws -> JSON {
        let session = try scoped(db, sid, pid, type: "session")
        guard canReceive(session, project: pid) else { throw CoreError("FORBIDDEN", "This recipient has no current message-receipt grant.") }
        return ["session_id": sid, "recipient_role": "recipient"]
    }

    /// Saved notes with no recipient (pickup_pending) for this Triage and its member tickets,
    /// delivered once when an orchestrator starts or takes over: at most 50 per pickup.
    func deliverSavedTriageNotes(_ db: Database, group: JSON) throws -> (delivered: Int, hasMore: Bool) {
        guard let recipient = triageOrchestratorRecipient(db, group: group) else { return (0, false) }
        let stored = StoredRecord(group, family: "group"), pid = try stored.string("project_id"), gid = try stored.string("id")
        let sql = "SELECT " + Self.canonicalColumns(alias: "m") + " FROM records m WHERE m.type='message' AND m.project_id=CAST(? AS TEXT)"
            + " AND json_extract(m.data,'$.pickup_pending')=1 AND ((json_extract(m.data,'$.triage_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(m.data,'$.task_id') IS NULL)"
            + " OR json_extract(m.data,'$.task_id') IN (SELECT value FROM json_each(?)))"
            + " AND NOT EXISTS (SELECT 1 FROM records d WHERE d.type='delivery' AND d.project_id=m.project_id AND json_extract(d.data,'$.message_id')=m.id) ORDER BY m.rowid LIMIT 51"
        let rows = try Row.fetchAll(db, sql: sql, arguments: [Data(pid.utf8), Data(gid.utf8), try jsonString(triageMemberIDs(group))])
        var delivered = 0
        for row in rows.prefix(50) {
            let message = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: "message").object
            let author = message["author_session_id"] as? String
            var recipients: [JSON]
            if let tid = message["task_id"] as? String {
                let task = try scoped(db, tid, pid, type: "task")
                recipients = try withTriageOrchestratorCopy(db, task: task, holders: ordinaryHandlerRecipients(db, task: task), sender: author)
            } else {
                var copy = recipient; copy["label"] = "Saved Triage note, delivered when you joined \(group["name"] as? String ?? "this Triage")."
                recipients = copy["session_id"] as? String == author ? [] : [copy]
            }
            if !(try queueDirectionDeliveries(db, message: message, recipients: recipients)).isEmpty { delivered += 1 }
        }
        return (delivered, rows.count > 50)
    }
}
