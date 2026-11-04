import Foundation
import GRDB

/// CL-125 membership effect of one ticket action. The rules are the membership
/// move table in docs/triage-orchestrators.md; a move never changes a ticket's
/// Epic, claim, planned assignee or status.
enum TriageMembershipEvent: Equatable { case status, claim(review: Bool), submission, verdictReturn }

extension CommandRouter {
    /// The active orchestrator session of a Triage. Nil means the Triage is a plan.
    func triageOrchestratorSession(_ group: JSON) -> String? {
        guard let orchestration = group["orchestration"] as? JSON, orchestration["state"] as? String == "active" else { return nil }
        return orchestration["session_id"] as? String
    }
    /// The caller's orchestrated Triage in a project. After the store upgrade a
    /// conversation can still hold two; new work joins the one it started last.
    func callerOrchestratedTriage(_ db: Database, project pid: String, caller: Caller) throws -> JSON? {
        guard let sid = caller.sessionID else { return nil }
        func started(_ group: JSON) -> String { (group["orchestration"] as? JSON)?["started_at"] as? String ?? "" }
        return try records(db, type: "group", project: pid)
            .filter { $0["kind"] as? String == "triage" && !bool($0, "archived") && triageOrchestratorSession($0) == sid }
            .max { started($0).utf8.lexicographicallyPrecedes(started($1).utf8) }
    }
    /// Rule 3: one conversation orchestrates at most one Triage per project.
    func requireNoOtherOrchestratedTriage(_ db: Database, project pid: String, caller: Caller, except gid: String?) throws {
        guard let sid = caller.sessionID else { return }
        guard let other = try records(db, type: "group", project: pid).first(where: {
            $0["kind"] as? String == "triage" && !bool($0, "archived") && $0["id"] as? String != gid && triageOrchestratorSession($0) == sid
        }) else { return }
        throw CoreError(
            "TRIAGE_ORCHESTRATOR_CONFLICT",
            "This conversation already orchestrates \(try agentReference(db, other)) in this project. One conversation orchestrates at most one Triage per project: finish that Triage before you start or take over another.",
            details: ["triage_id": other["id"] ?? NSNull()])
    }
    /// The guards of a Triage add, shared by `group_membership` and `task_create`.
    /// CL-125 rule 5: only the orchestrator or the owner adds tickets to an orchestrated Triage; anyone eligible edits plans.
    func requireTriageAddAllowed(_ group: JSON, caller c: Caller) throws {
        guard !bool(group, "archived") else { throw CoreError("INVALID_TRANSITION", "Restore this Triage before adding or updating its tickets.") }
        if let orchestrator = triageOrchestratorSession(group), !c.isOwner, c.sessionID != orchestrator {
            throw CoreError("TRIAGE_ORCHESTRATED", "Only this Triage's orchestrator or the owner adds or updates its tickets. Send a note to the orchestrator instead.", details: ["orchestrator_session_id": orchestrator])
        }
    }
    /// CL-411: the Triage named by `task_create`. Every refusal comes before the ticket exists.
    func triageForNewTicket(_ db: Database, value: Any?, project pid: String, caller c: Caller) throws -> JSON? {
        guard let value else { return nil }
        guard let gid = value as? String else { throw CoreError("INVALID_INPUT", "triage_id must be a Triage ID in this project.") }
        let group = try scoped(db, gid, pid, type: "group")
        guard group["kind"] as? String == "triage" else { throw CoreError("INVALID_INPUT", "triage_id must be a Triage ID in this project.") }
        try requireTriageAddAllowed(group, caller: c)
        return group
    }
    /// CL-411: the `task_create` reply states the membership of the new ticket. A new ticket
    /// joins no Triage by itself, because split and follow-up tickets go to an unstarted plan.
    func taskCreateTriageMembership(_ db: Database, task: JSON, joined: JSON?, caller c: Caller) throws -> JSON {
        let tid = try StoredRecord(task, family: "task").string("id"), pid = try StoredRecord(task, family: "task").string("project_id")
        let key = task["key"] as? String ?? tid
        var statement: JSON = ["state": "none", "text": "\(key) is in no Triage."]
        if let joined {
            statement = ["state": "member", "triage_id": joined["id"] ?? NSNull(), "key": joined["key"] ?? NSNull(), "name": joined["name"] ?? NSNull(),
                         "plan": triageOrchestratorSession(joined) == nil, "text": "\(key) is in \(try agentReference(db, joined))."]
        }
        guard let mine = try callerOrchestratedTriage(db, project: pid, caller: c), mine["id"] as? String != joined?["id"] as? String else { return statement }
        let current = statement["text"] as? String ?? ""
        statement["caller_triage"] = ["triage_id": mine["id"] ?? NSNull(), "key": mine["key"] ?? NSNull(), "name": mine["name"] ?? NSNull()]
        statement["add_command"] = ["method": "group_membership", "arguments": [
            "project_id": pid, "group_id": mine["id"] ?? NSNull(), "task_id": tid, "action": "add", "expected_revision": mine["revision"] ?? NSNull()
        ] as JSON] as JSON
        statement["text"] = "\(current) You orchestrate \(try agentReference(db, mine)). Use add_command to add this ticket, and supply a new UUID as its command_id. Do not add a split or follow-up ticket that goes to the next unstarted plan."
        return statement
    }
    /// CL-423: observe membership after the claim move; this never groups a helper's ticket.
    func claimTriageMembership(_ db: Database, task: JSON, caller c: Caller) throws -> JSON {
        let stored = StoredRecord(task, family: "task")
        let tid = try stored.string("id"), pid = try stored.string("project_id")
        let key = AgentReference.sanitized(try stored.string("key"), maximumCharacters: 80, maximumUTF8Bytes: 320)
        if let joined = try currentTriages(db, project: pid, taskID: tid).first {
            // Returned-claim token pickup keeps its existing membership. The
            // orchestrator may have finished since the claim was returned.
            guard triageOrchestratorSession(joined) != nil else {
                return try taskCreateTriageMembership(db, task: task, joined: joined, caller: c)
            }
            let mine = triageOrchestratorSession(joined) == c.sessionID
            let reference = AgentReference.text(joined)
            return ["state": "member", "triage_id": joined["id"] ?? NSNull(), "key": joined["key"] ?? NSNull(),
                    "name": joined["name"] ?? NSNull(), "plan": triageOrchestratorSession(joined) == nil,
                    "text": mine ? "\(key) is in your Triage \(reference)." : "\(key) stays in \(reference), which another conversation orchestrates. You are the ticket holder; its notes reach you and that orchestrator."]
        }
        if try callerOrchestratedTriage(db, project: pid, caller: c) != nil {
            return try taskCreateTriageMembership(db, task: task, joined: nil, caller: c)
        }
        return ["state": "none",
                "text": "\(key) is in no Triage, so only you get its notes. If a conversation sent you this work, ask it to add \(key) to its Triage (group_membership add). If you orchestrate this work, call triage_orchestrate action=start without triage_id, then use add_command.",
                "start_command": ["method": "triage_orchestrate", "arguments": ["project_id": pid, "action": "start", "command_id": uuid()]] as JSON,
                "add_command": ["method": "group_membership", "arguments": ["project_id": pid, "group_id": "<triage_id from start_command>", "task_id": tid,
                    "action": "add", "expected_revision": "<revision from start_command>", "command_id": "<new UUID>"]] as JSON]
    }

    func addingClaimTriageMembership(_ db: Database, reply: JSON, task: JSON, caller: Caller) throws -> JSON {
        var result = reply
        let statement = try claimTriageMembership(db, task: task, caller: caller)
        result["triage_membership"] = statement
        if let text = statement["text"] as? String, statement["start_command"] != nil {
            var metadata = result["_checklist"] as? JSON ?? [:]
            metadata["notices"] = (metadata["notices"] as? [String] ?? []) + [text]
            result["_checklist"] = metadata
        }
        return result
    }

    /// Dispatch observes the current membership, before the recipient claims. Unlike
    /// a claim, dispatch never moves a ticket into the caller's Triage automatically.
    func addingDispatchTriageMembership(_ db: Database, reply: JSON, task: JSON, caller: Caller) throws -> JSON {
        let stored = StoredRecord(task, family: "task")
        let joined = try currentTriages(db, project: stored.string("project_id"), taskID: stored.string("id")).first
        if let mine = try callerOrchestratedTriage(db, project: stored.string("project_id"), caller: caller),
           mine["id"] as? String != joined?["id"] as? String {
            var result = reply
            result["triage_membership"] = try taskCreateTriageMembership(db, task: task, joined: joined, caller: caller)
            return result
        }
        return try addingClaimTriageMembership(db, reply: reply, task: task, caller: caller)
    }

    func currentTriages(_ db: Database, project pid: String, taskID tid: String) throws -> [JSON] {
        try records(db, type: "group", project: pid).filter { $0["kind"] as? String == "triage" && triageMemberIDs($0).contains(tid) }
    }
    func triageMember(_ group: JSON, taskID tid: String) -> JSON? {
        (group["members"] as? [JSON] ?? []).first { $0["task_id"] as? String == tid } ?? (triageMemberIDs(group).contains(tid) ? ["task_id": tid] : nil)
    }
    func triageMembers(_ group: JSON) -> [JSON] {
        let members = group["members"] as? [JSON] ?? []
        return members.isEmpty ? triageMemberIDs(group).map { ["task_id": $0] } : members
    }
    /// Closes one membership interval with a reason. A plan that empties archives, with its history kept.
    @discardableResult
    func leaveTriage(_ db: Database, group source: JSON, taskID tid: String, caller: Caller, reason: String, extra: JSON = [:]) throws -> JSON {
        var group = source
        _ = try closeTriageMembership(db, group: group, member: triageMember(group, taskID: tid) ?? ["task_id": tid], caller: caller, reason: reason, extra: extra)
        let members = triageMembers(group).filter { $0["task_id"] as? String != tid }
        group["members"] = members
        group["task_ids"] = members.compactMap { $0["task_id"] as? String }
        group = revised(group)
        try archiveEmptyPlan(db, &group, caller: caller, after: reason)
        try save(db, group, type: "group")
        return group
    }
    /// Rule 11: an empty Triage with no orchestrator archives automatically.
    func archiveEmptyPlan(_ db: Database, _ group: inout JSON, caller: Caller, after reason: String) throws {
        guard group["kind"] as? String == "triage", !bool(group, "archived"), triageOrchestratorSession(group) == nil,
              triageMemberIDs(group).isEmpty else { return }
        group["archived"] = true
        group["archived_at"] = now()
        group["archive_reason"] = "empty_without_orchestrator"
        try event(db, caller: caller, project: try StoredRecord(group, family: "group").string("project_id"), entity: group["id"] as? String,
                  kind: "triage_archived_automatically", data: ["reason": "empty_without_orchestrator", "after": reason, "history_kept": true])
    }
    /// Opens one membership interval with its join reason.
    @discardableResult
    func joinTriage(_ db: Database, group source: JSON, taskID tid: String, caller: Caller, reason: String, returnTriageID: String? = nil) throws -> JSON {
        var group = source
        guard triageMember(group, taskID: tid) == nil else { return group }
        var member: JSON = ["task_id": tid, "join_reason": reason, "joined_at": now(), "updated_at": now()]
        if let returnTriageID { member["return_triage_id"] = returnTriageID }
        member["membership_id"] = try ensureTriageMembershipInterval(db, group: group, member: member, caller: caller, joiningRevision: int(group, "revision") + 1)["id"]
        let members = triageMembers(group) + [member]
        group["members"] = members
        group["task_ids"] = members.compactMap { $0["task_id"] as? String }
        group = revised(group)
        try save(db, group, type: "group")
        try event(db, caller: caller, project: try StoredRecord(group, family: "group").string("project_id"), entity: group["id"] as? String,
                  kind: "triage_member_added", data: ["task_id": tid, "reason": reason])
        return group
    }
    /// Applies the membership move table after a ticket record is saved.
    func applyTriageMembership(_ db: Database, task: JSON, caller: Caller, event membershipEvent: TriageMembershipEvent) throws {
        let pid = try StoredRecord(task, family: "task").string("project_id"), tid = try StoredRecord(task, family: "task").string("id")
        let status = try? record(db, task["status_id"] as? String ?? "", type: "status")
        let category = status.map { $0["category"] as? String ?? "" } ?? (task["status_category"] as? String ?? "")
        let terminal = category == "done" || category == "canceled" || task["disposition"] as? String == "superseded"
        // A retained status action reads only its destination status (no Triage scan).
        if !terminal && membershipEvent == .status { return }
        let current = try currentTriages(db, project: pid, taskID: tid)
        if terminal {
            for group in current {
                var extra: JSON = ["status_id": task["status_id"] ?? NSNull()]
                if category == "done", let mid = task["current_manifest_id"] as? String, let manifest = try? scoped(db, mid, pid, type: "manifest") {
                    extra["target_manifest_id"] = mid
                    extra["label"] = try manifestGates(db, manifest).isEmpty ? "No review required" : "Completed after required gates"
                    if try records(db, type: "finding_resolution", project: pid).contains(where: { $0["task_id"] as? String == tid && $0["disposition"] as? String == "waived" }) {
                        extra["label"] = "Completed with owner-waived findings"
                    }
                }
                try leaveTriage(db, group: group, taskID: tid, caller: caller, reason: category == "done" ? "done" : "canceled", extra: extra)
            }
            return
        }
        switch membershipEvent {
        case .status:
            return
        case .submission:
            // Rule 10: the implementing Triage becomes the return Triage.
            for var group in current {
                let gid = try StoredRecord(group, family: "group").string("id")
                group["members"] = triageMembers(group).map { member -> JSON in
                    guard member["task_id"] as? String == tid else { return member }
                    var member = member
                    member["return_triage_id"] = gid
                    member["updated_at"] = now()
                    return member
                }
                group = revised(group)
                try save(db, group, type: "group")
                try event(db, caller: caller, project: pid, entity: gid, kind: "triage_return_recorded", data: ["task_id": tid, "return_triage_id": gid])
            }
        case .claim(let review):
            guard let mine = try callerOrchestratedTriage(db, project: pid, caller: caller) else {
                // Rule 7: a claim by a session that orchestrates nothing removes the ticket only from a plan.
                for group in current where triageOrchestratorSession(group) == nil {
                    try leaveTriage(db, group: group, taskID: tid, caller: caller, reason: "plan_claim")
                }
                return
            }
            let mineID = try StoredRecord(mine, family: "group").string("id")
            var carried: String?
            for group in current where group["id"] as? String != mineID {
                carried = carried ?? (triageMember(group, taskID: tid)?["return_triage_id"] as? String) ?? (review ? group["id"] as? String : nil)
                let plan = triageOrchestratorSession(group) == nil
                try leaveTriage(db, group: group, taskID: tid, caller: caller, reason: plan ? "plan_claim" : "other_orchestrator", extra: ["moved_to_triage_id": mineID])
            }
            if !current.contains(where: { $0["id"] as? String == mineID }) {
                try joinTriage(db, group: try scoped(db, mineID, pid, type: "group"), taskID: tid, caller: caller,
                               reason: review ? "orchestrator_review_claim" : "orchestrator_claim", returnTriageID: carried)
            }
        case .verdictReturn:
            for group in current {
                let gid = try StoredRecord(group, family: "group").string("id")
                let returnID = triageMember(group, taskID: tid)?["return_triage_id"] as? String ?? gid
                let target: JSON? = returnID == gid ? group : (try? scoped(db, returnID, pid, type: "group"))
                let orchestrated = target.map { $0["kind"] as? String == "triage" && !bool($0, "archived") && triageOrchestratorSession($0) != nil } ?? false
                if returnID == gid && orchestrated { continue }
                try leaveTriage(db, group: group, taskID: tid, caller: caller, reason: "verdict_return",
                                extra: orchestrated ? ["moved_to_triage_id": returnID] : [:])
                if orchestrated {
                    try joinTriage(db, group: try scoped(db, returnID, pid, type: "group"), taskID: tid, caller: caller, reason: "verdict_return")
                }
            }
        }
    }
}
