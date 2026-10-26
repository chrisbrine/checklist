import Foundation
import GRDB

extension CommandRouter {
    /// CL-216: a review gap starts fresh implementation work, never revives a submitted token.
    /// The ordinary claim guards recheck the exact author's generation, policy and reservations.
    func returnReviewToImplementation(_ db: Database,task: inout JSON,manifest: JSON,review: JSON,caller: Caller) throws -> JSON {
        let taskRecord = try StoredTaskRecord(task)
        let pid = taskRecord.projectID,tid = taskRecord.id
        let mid = try StoredRecord(manifest, family: "manifest").string("id")
        let reviewRecord = StoredRecord(review, family: "review")
        let reviewID = try reviewRecord.requiredValue("id")
        let taskRevision = try StoredRecord(task, family: "task").requiredValue("revision")
        for var request in try scopedTaskRows(db,type:"review_request",task:task) where request["manifest_id"] as? String == mid && ["queued",
            "blocked","evidence_requested"].contains(request["state"] as? String ?? "") {
            request["state"] = "superseded";request["superseded_by_review_id"] = review["id"];try save(db,revised(request),type:"review_request")
        }
        task["status_id"] = try status(db,pid,"queued")["id"]
        task.removeValue(forKey:"current_manifest_id");task.removeValue(forKey:"release_hold")
        try save(db,task,type:"task")
        var result: JSON = ["state":"queued","review_id":reviewID,"manifest_id":mid]
        do {
            guard let aid = manifest["attempt_id"] as? String,let previous = try? scoped(db,
                aid,pid,type:"attempt"),previous["phase"] as? String == "implementation",previous["state"] as? String == "submitted",
                previous["task_id"] as? String == tid,previous["incarnation"] as? String == incarnation else {
                throw CoreError("IMPLEMENTER_UNAVAILABLE","No current implementing holder is available; any eligible implementer may claim the queued ticket.")
            }
            let holder = try returnedImplementationHolder(db,previous:previous,projectID:pid)
            try db.inSavepoint {
                let input: JSON = ["project_id":pid,"task_id":tid,"expected_revision":taskRevision,"file_scopes":previous["file_scopes"] ?? [],"lane_scopes":previous["lane_scopes"] ?? []]
                let claimed = try work(db,input,holder,"work_claim")
                let claimedRecord = try StoredAttemptRecord(claimed)
                var attempt = try scoped(db,claimedRecord.id,pid,type:"attempt")
                // The secret from the internal claim is discarded, never disclosed to the reviewer.
                // Only the returned holder can pick up/rotate it through work_claim.
                attempt["returned_from_review_id"] = review["id"];attempt["review_return_from_attempt_id"] = aid
                try save(db,attempt,type:"attempt")
                result["state"] = "active";result["attempt_id"] = attempt["id"];result["session_id"] = attempt["session_id"]
                return .commit
            }
        } catch let error as CoreError {
            // Unavailable holders and changed authority may queue the ticket; malformed
            // stored input must abort the entire verdict transaction instead.
            if error.code == "CANONICAL_RECORD_INVALID" { throw error }
            result["code"] = error.code;result["reason"] = error.message
        }
        task = try scoped(db,tid,pid,type:"task")
        try event(db,caller:caller,project:pid,entity:tid,kind:"review_returned_to_implementation",data:result)
        let reason = review["reason"] as? String ?? "Implementation input is needed."
        let findings = "Findings in the exact verdict: \((review["findings"] as? [JSON] ?? []).count)."
        let verdict = try reviewRecord.requiredValue("verdict")
        let state = try StoredRecord(result, family: "review return").requiredValue("state")
        let body = "Review \(verdict) returned this ticket to implementation (\(state)). \(reason)\n\(findings)\n"
            + "Read review \(reviewID) and submit a fresh target after addressing its missing items. "
            + "For an automatic Active return, call work_claim at the current revision to pick up your new claim token."
        let notice = try messageWrite(db,["project_id":pid,"task_id":tid,"body":body],caller,"message_send")
        result["message_id"] = notice["id"]
        return result
    }

    private func returnedImplementationHolder(_ db: Database,previous: JSON,projectID pid: String) throws -> Caller {
        guard let sid = previous["session_id"] as? String,sid != "human" else { throw CoreError("IMPLEMENTER_UNAVAILABLE",
            "There is no native implementing session; the ticket is queued for pickup.") }
        var holder = Caller(role:"worker",installation:previous["installation"] as? String ?? "",
            projectIDs:[pid],sessionID:sid,workspace:(try record(db,pid,type:"project"))["root_path"] as? String,
            executionDomain:previous["execution_domain"] as? String)
        guard holder.principal == previous["principal"] as? String,previous["session_authorization_generation"] as? String == (try callerSessionGeneration(db,holder,project:pid)) else {
            throw CoreError("IMPLEMENTER_UNAVAILABLE","The implementing holder's authorization changed; claim the queued ticket with current authority.")
        }
        if let sid = holder.sessionID {
            let session = try scoped(db,sid,pid,type:"session")
            guard session["installation"] as? String == holder.installation,session["execution_domain"] as? String == holder.executionDomain else {
                throw CoreError("IMPLEMENTER_UNAVAILABLE","The implementing holder's binding changed; claim the queued ticket with current authority.")
            }
            holder.workspace = session["workspace"] as? String
        }
        return holder
    }

    /// Pickup is restricted to the automatically returned holder and its exact live generation.
    /// Old submitted/review tokens remain fenced, and this never expands saved reservations.
    func pickupReturnedImplementation(_ db: Database,params: JSON,task: JSON,caller: Caller) throws -> JSON? {
        let taskRecord = try StoredTaskRecord(task)
        guard [nil,"implementation"].contains(params["phase"] as? String),let aid = task["active_attempt_id"] as? String,
            var attempt = try? scoped(db,aid,taskRecord.projectID,type:"attempt"),attempt["returned_from_review_id"] != nil,
            attempt["phase"] as? String == "implementation",attempt["state"] as? String == "active",
            attempt["principal"] as? String == caller.principal,attempt["incarnation"] as? String == incarnation,
            attempt["execution_domain"] as? String == caller.executionDomain,attempt["session_authorization_generation"] as? String == (try callerSessionGeneration(db,
            caller,project:taskRecord.projectID)) else { return nil }
        if task["planned_assignee"] as? String == "human" || (task["planned_assignee"] as? JSON)?["kind"] as? String == "human" { throw CoreError("POLICY_DENIED",
            "This task is assigned to the owner.") }
        guard (params["file_scopes"] as? [JSON] ?? []).isEmpty,(params["lane_scopes"] as? [JSON] ?? []).isEmpty else { throw CoreError("INVALID_INPUT",
            "Pick up the returned claim without scopes; use work_scope_adjust to change its saved reservations.") }
        try verifyPolicyAuthority(db,attempt:attempt,caller:caller)
        let token = uuid()+uuid();attempt["token_hash"] = hash(Data(token.utf8));try save(db,attempt,type:"attempt")
        try recordTicketStatusAction(db,task:task,caller:caller)
        attempt.removeValue(forKey:"token_hash");attempt["claim_token"] = token;attempt["task"] = try taskProjection(db,task)
        attempt["context"] = try compactTaskContext(db,task:task,caller:caller)
        return attempt
    }
}
