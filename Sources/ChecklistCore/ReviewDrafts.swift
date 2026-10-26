import Foundation
import GRDB

/// CL-44: a reviewer that must stop (for example at its tool limit) saves a draft verdict on its
/// own review claim. The coordinator submits that draft later. The verdict names the reviewer
/// who wrote it as its author and the coordinator only as `submitted_by`.
extension CommandRouter {
    /// Validates the complete verdict as a dry run with the reviewer's own identity, rolls it
    /// back and keeps the input on the claim. The claim stays active; a new save replaces the draft.
    func reviewDraftSave(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: true)
        var a = try claimAttempt(db, p, c, pid); let t = try scoped(db, (try StoredRecord(a, family: "attempt").string("task_id")), pid, type: "task")
        guard a["phase"] as? String == "review", a["parent_attempt_id"] == nil else { throw CoreError("INVALID_TRANSITION", "Only the holder of a review claim saves a draft verdict.") }
        try verifyPolicyAuthority(db, attempt: a, caller: c)
        try db.inSavepoint {
            try validateDirectionCursor(db, params: p, task: t, caller: c, attempt: a)
            _ = try recordReviewVerdict(db, params: p, attempt: a, task: t, reviewer: c, actor: c, operation: .individual)
            return .rollback
        }
        var params = p
        for key in ["attempt_id", "claim_token", "direction_cursor", "project_id", "command_id", "expected_revision"] { params.removeValue(forKey: key) }
        a["draft_verdict"] = ["params": params, "verdict": p["verdict"]!, "saved_at": now(), "author": c.principal, "author_display": author(db, c),
                              "author_session_id": c.sessionID ?? NSNull(), "review_request_id": (try StoredRecord(a, family: "attempt").string("review_request_id")),
                                  "manifest_id": (try StoredRecord(a, family: "attempt").string("manifest_id")), "gate": (try StoredRecord(a, family: "attempt").string("gate"))]
        a = revised(a); try save(db, a, type: "attempt")
        try event(db, caller: c, project: pid, entity: t["id"] as? String, kind: "review_draft_saved", data: ["attempt_id": (try StoredRecord(a, family: "attempt").string("id")),
            "verdict": p["verdict"]!])
        return contextRecord(a, type: "attempt", caller: c)
    }

    /// The owner, or the session that actually orchestrates an active Triage holding this ticket,
    /// submits the reviewer's saved draft. Target freshness, the review contract and the
    /// independence of the draft's reviewer are checked again; the submitter never becomes the reviewer.
    func reviewDraftSubmit(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: true)
        let t = try task(db, p, pid)
        let a = try scoped(db, try text(p, "attempt_id", max: 200), pid, type: "attempt")
        guard a["task_id"] as? String == t["id"] as? String, a["phase"] as? String == "review", a["state"] as? String == "active", t["active_attempt_id"] as? String == a["id"] as? String,
              let draft = a["draft_verdict"] as? JSON, let params = draft["params"] as? JSON else { throw CoreError("REVIEW_DRAFT_REQUIRED", "This ticket's active review claim has no saved draft verdict.") }
        if p["expected_revision"] != nil { guard int(p, "expected_revision") == int(a, "revision") else { throw CoreError("REVISION_CONFLICT", "The review claim or its draft changed. Read the ticket again.") } }
        guard a["principal"] as? String != c.principal else { throw CoreError("INVALID_TRANSITION", "Record your own verdict with review_record.") }
        if !c.isOwner {
            let coordinates = try records(db, type: "group", project: pid).contains { group in
                guard group["kind"] as? String == "triage", triageMemberIDs(group).contains((try StoredRecord(t, family: "task").string("id"))),
                    let orchestration = group["orchestration"] as? JSON else { return false }
                // The orchestration must belong to the submitter's current session generation (finding 6c13b7ee).
                return orchestration["state"] as? String == "active" && orchestration["principal"] as? String == c.principal && orchestration["session_id"] as? String == c.sessionID
                    && orchestration["session_authorization_generation"] as? String == (try? callerSessionGeneration(db, c, project: pid))
            }
            guard coordinates else { throw CoreError("FORBIDDEN", "Only the owner or the session that orchestrates an active Triage holding this ticket submits a reviewer's draft.") }
        }
        // The submitter confirms that it read the ticket's current owner directions.
        try validateDirectionCursor(db, params: p, task: t, caller: c)
        let reviewer = Caller(role: "worker", installation: a["installation"] as? String ?? "", projectIDs: [pid], sessionID: a["session_id"] as? String, executionDomain: a["execution_domain"] as? String)
        guard reviewer.principal == a["principal"] as? String, draft["author"] as? String == reviewer.principal else { throw CoreError("STALE_CLAIM", "The draft's reviewer is not the current review claimant.") }
        // The same live-claim fences as review_record (finding 6c13b7ee): a draft never revives a claim
        // whose service incarnation or session authorization generation has ended.
        guard a["incarnation"] as? String == incarnation, a["session_authorization_generation"] as? String == (try? callerSessionGeneration(db, reviewer, project: pid)) else {
            throw CoreError("STALE_CLAIM", "The draft's review claim is no longer current. A reviewer must claim the review again.")
        }
        let manifest = try validateManifestTarget(db, task: t, manifestID: (try StoredRecord(a, family: "attempt").string("manifest_id")))
        try validateContributorIndependence(manifest: manifest, caller: reviewer)
        try verifyPolicyAuthority(db, attempt: a, caller: reviewer)
        let submittedBy: JSON = ["principal": c.principal, "session_id": c.sessionID ?? NSNull(), "actor_display": author(db, c), "origin": c.isOwner ? "human_ui" : "agent", "submitted_at": now()]
        var input = params; input["project_id"] = pid
        return try recordReviewVerdict(db, params: input, attempt: a, task: t, reviewer: reviewer, actor: c, operation: .individual, submittedBy: submittedBy)
    }
}
