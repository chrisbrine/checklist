import Foundation
import GRDB

extension CommandRouter {
    /// Rechecks the exact immutable target at gate claim, verdict and completion.
    func validateManifestTarget(_ db: Database, task: JSON, manifestID: String) throws -> JSON {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        guard task["current_manifest_id"] as? String == manifestID else { throw CoreError("REVIEW_TARGET_MISMATCH","The task has a different current target. Inspect the new target before reviewing.") }
        let manifest = try scoped(db,manifestID,pid,type:"manifest")
        guard manifest["task_id"] as? String == task["id"] as? String,int(manifest,"acceptance_revision") == int(task,"acceptance_revision",default:1) else { throw CoreError("EVIDENCE_STALE","The task's acceptance changed after this target was captured.") }
        let evidence = manifest["evidence"] as? JSON ?? [:]
        let refs = evidence["artifact_refs"] as? [JSON] ?? []
        let source = try validateSourceTarget(db,evidence:evidence,task:task)
        let decision = evidence["decision"] as? JSON
        if evidence["kind"] as? String == "decision" {
            guard let text = decision?["text"] as? String,decision?["sha256"] as? String == hash(Data(text.utf8)),source == nil,refs.isEmpty else { throw CoreError("EVIDENCE_STALE","The exact recorded decision target changed.") }
        } else if source == nil && refs.isEmpty { throw CoreError("EVIDENCE_STALE","The target has no inspectable immutable evidence.") }
        for ref in refs + acceptanceArtifactRefs(evidence) {
            let attachment = try scoped(db,try text(ref,"artifact_id"),pid,type:"attachment")
            guard attachment["task_id"] as? String == task["id"] as? String,attachment["sha256"] as? String == ref["sha256"] as? String,attachment["mode"] as? String == "managed",attachment["availability"] as? String == "available",let path = attachment["path"] as? String,objectBytesMatch(path,sha256:attachment["sha256"] as? String ?? "") else { throw CoreError("EVIDENCE_STALE","An immutable target original is missing, cleaned or changed. Re-capture it before verification.") }
        }
        try validatePlaytestBundleTarget(evidence:evidence,task:task)
        return manifest
    }
    func bindHumanGate(_ db: Database, request: inout JSON, task: inout JSON, params: JSON) throws {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        let questions = request["questions"] as? [JSON] ?? []
        let approvals = questions.filter {$0["type"] as? String == "approval"}
        let explicit = params["review_request_id"] as? String
        let queued = try records(db,type:"review_request",project:pid).filter {$0["task_id"] as? String == task["id"] as? String && $0["gate"] as? String == "human_approval" && $0["manifest_id"] as? String == task["current_manifest_id"] as? String && $0["state"] as? String == "queued"}
        guard explicit != nil || (!approvals.isEmpty && request["target_attachment_id"] != nil && queued.count == 1) else { return }
        guard approvals.count == 1,let attachmentID = request["target_attachment_id"] as? String else { throw CoreError("INVALID_INPUT","A human approval gate needs one explicit approval question and an immutable attachment target.") }
        var gate = try explicit.map { try scoped(db,$0,pid,type:"review_request") } ?? queued[0]
        guard gate["task_id"] as? String == task["id"] as? String,gate["gate"] as? String == "human_approval",gate["state"] as? String == "queued",let mid = gate["manifest_id"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","Use the exact queued human approval request for this task.") }
        if let supplied = params["target_manifest_id"] as? String,supplied != mid { throw CoreError("REVIEW_TARGET_MISMATCH","The supplied manifest does not match the approval request.") }
        let manifest = try validateManifestTarget(db,task:task,manifestID:mid)
        let refs = (manifest["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []
        guard refs.contains(where: {$0["artifact_id"] as? String == attachmentID && $0["sha256"] as? String == request["target_sha256"] as? String}) else { throw CoreError("REVIEW_TARGET_MISMATCH","This attachment is not part of the exact submitted target.") }
        guard task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("REVIEW_ALREADY_ACTIVE","Release the current verification before requesting human approval.") }
        request["review_request_id"] = gate["id"]; request["target_manifest_id"] = mid; request["gate"] = "human_approval"; request["approval_question_id"] = approvals[0]["id"]
        gate["state"] = "human_pending"; gate["human_request_id"] = request["id"]; try save(db,revised(gate),type:"review_request")
        task["active_verification_request_id"] = request["id"]; task = revised(task); try save(db,task,type:"task")
    }
    func cancelHumanGate(_ db: Database, request: JSON) throws {
        guard let rid = request["review_request_id"] as? String else { return }
        let pid = (try StoredRecord(request, family: "request").string("project_id")); var task = try scoped(db,(try StoredRecord(request, family: "request").string("task_id")),
            pid,type:"task"); var gate = try scoped(db,rid,pid,type:"review_request")
        if task["active_verification_request_id"] as? String == request["id"] as? String { task.removeValue(forKey:"active_verification_request_id"); try save(db,revised(task),type:"task") }
        if gate["state"] as? String == "human_pending",gate["human_request_id"] as? String == request["id"] as? String { gate["state"] = task["current_manifest_id"] as? String == gate["manifest_id"] as? String ? "queued" : "superseded"; gate.removeValue(forKey:"human_request_id"); try save(db,revised(gate),type:"review_request") }
    }
    func recordHumanGate(_ db: Database, request: JSON, answers: [JSON], responseID: String, params: JSON, caller: Caller) throws -> JSON? {
        guard let rid = request["review_request_id"] as? String else { return nil }
        let pid = (try StoredRecord(request, family: "request").string("project_id")); var task = try scoped(db,(try StoredRecord(request, family: "request").string("task_id")),
            pid,type:"task"); var gate = try scoped(db,rid,pid,type:"review_request")
        guard task["active_verification_request_id"] as? String == request["id"] as? String,gate["state"] as? String == "human_pending",gate["human_request_id"] as? String == request["id"] as? String,let mid = request["target_manifest_id"] as? String,gate["manifest_id"] as? String == mid,gate["gate"] as? String == "human_approval" else { throw CoreError("REQUEST_CHANGED","This human verification no longer owns the exact gate.") }
        _ = try validateManifestTarget(db,task:task,manifestID:mid)
        try validateHumanGateDirection(db,request:request,params:params,caller:caller)
        guard let answer = answers.first(where: {$0["question_id"] as? String == request["approval_question_id"] as? String}),let result = answer["result"] as? String ?? answer["value"] as? String,["approved","changes_requested","declined"].contains(result) else { throw CoreError("ANSWER_INCOMPLETE","Choose Approve or Needs changes for the exact inspected target.") }
        let storedRequest = StoredRecord(request, family: "request")
        let attachmentID = try storedRequest.requiredValue("target_attachment_id")
        let targetSHA256 = try storedRequest.requiredValue("target_sha256")
        let verdict = result == "approved" ? "pass" : "reject"
        let review: JSON = ["id":uuid(),"project_id":pid,"task_id":(try StoredRecord(task, family: "task").string("id")),"manifest_id":mid,"review_request_id":rid,
            "human_request_id":(try StoredRecord(request, family: "request").string("id")),"human_response_id":responseID,"target_attachment_id":attachmentID,
            "target_sha256":targetSHA256,"gate":"human_approval","verdict":verdict,"actor":caller.principal,"actor_display":"You","origin":"human_ui",
            "checks":[["label":"Owner inspected exact original","result":result,"target_attachment_id":attachmentID,"sha256":targetSHA256]],
            "findings":[],"revision":1,"created_at":now()]
        try save(db,review,type:"review"); gate["state"] = verdict; gate["latest_verdict_id"] = review["id"]; try save(db,revised(gate),type:"review_request")
        task.removeValue(forKey:"active_verification_request_id")
        if verdict == "reject" { task.removeValue(forKey:"current_manifest_id"); task["status_id"] = try status(db,pid,"queued")["id"]; task.removeValue(forKey:"release_hold") }
        // A pass on the last open gate marks the ticket Done, as after an agent review.
        var completed = false
        let pinned = (try? scoped(db,mid,pid,type:"manifest"))?["policy_snapshot"] as? JSON ?? [:]
        if verdict == "pass",effectiveReviewBatchPolicy(pinned) != "hold_passing_for_batch" {
            do {
                try requirePrerequisitesSatisfied(db,task:task)
                try requireCompletable(db,task:task,pid:pid,answeringRequestID:request["id"] as? String)
                let done = try status(db,pid,"done")
                if done["category"] as? String == "done",!bool(done,"retired") { task["status_id"] = done["id"]; task["completed_at"] = now(); completed = true }
            } catch is CoreError {}
        }
        try save(db,revised(task),type:"task")
        try recordTicketStatusAction(db,task:task,caller:caller)
        try event(db,caller:caller,project:pid,entity:task["id"] as? String,kind:"human_approval_"+verdict,data:["review_id":review["id"]!,"manifest_id":mid,"attachment_id":attachmentID])
        if completed { try event(db,caller:caller,project:pid,entity:task["id"] as? String,kind:"task_completed",data:["origin":"review_pass","review_id":review["id"]!]) }
        return review
    }
}

extension CommandRouter {
    func findingEvidence(_ db: Database, refs: [Any], task: JSON, manifestID: String) throws {
        guard !refs.isEmpty else { throw CoreError("EVIDENCE_STALE","A finding disposition needs evidence from the current immutable target.") }
        let manifest = try validateManifestTarget(db,task:task,manifestID:manifestID)
        let artifacts = (manifest["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []
        let evidence = manifest["evidence"] as? JSON ?? [:]
        for ref in refs {
            if let input = ref as? JSON,let sourceID = input["source_capture_id"] as? String {
                guard let source = evidence["source_capture"] as? JSON,source["id"] as? String == sourceID,source["sha256"] as? String == input["sha256"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","Finding evidence must bind the exact source capture and fingerprint.") };continue
            }
            if let digest = (ref as? JSON)?["decision_sha256"] as? String {
                guard (evidence["decision"] as? JSON)?["sha256"] as? String == digest else { throw CoreError("REVIEW_TARGET_MISMATCH","Finding evidence must bind the exact recorded decision.") };continue
            }
            let id = (ref as? String) ?? (ref as? JSON)?["artifact_id"] as? String ?? ""
            guard let actual = artifacts.first(where: {$0["artifact_id"] as? String == id}) else { throw CoreError("REVIEW_TARGET_MISMATCH","Finding evidence must reference an artifact in the exact reviewed target.") }
            if let claimed = (ref as? JSON)?["sha256"] as? String,claimed != actual["sha256"] as? String { throw CoreError("EVIDENCE_STALE","The finding evidence fingerprint is incorrect.") }
        }
    }
    func applyFindings(_ db: Database, params: JSON, task: JSON, attempt: JSON, reviewID: String, verdict: String, caller: Caller) throws -> (findings: [JSON], resolutions: [JSON]) {
        let pid = (try StoredRecord(task, family: "task").string("project_id")),tid = (try StoredRecord(task, family: "task").string("id")),gate = (try StoredRecord(attempt,
            family: "attempt").string("gate")),mid = (try StoredRecord(attempt, family: "attempt").string("manifest_id"))
        let proposed = params["findings"] as? [JSON] ?? [],dispositions = params["finding_resolutions"] as? [JSON] ?? []
        guard proposed.count <= 100,dispositions.count <= 100,Set(proposed.compactMap {$0["client_ref"] as? String}).count == proposed.count,Set(dispositions.compactMap {$0["finding_id"] as? String}).count == dispositions.count else { throw CoreError("INVALID_INPUT","Findings and dispositions need unique IDs (maximum 100 per review).") }
        // CL-42: a pass may record advice; every other new finding blocks completion.
        if verdict == "pass",proposed.contains(where: {($0["severity"] as? String ?? "blocking") != "advice"}) { throw CoreError("FINDINGS_UNRESOLVED","A passing review can add only advice findings.") }
        let resolved = try resolveReviewFindings(db, dispositions: dispositions, task: task,
            projectID: pid, taskID: tid, gate: gate, manifestID: mid, reviewID: reviewID, caller: caller)
        let created = try createReviewFindings(db, proposed: proposed, projectID: pid,
            taskID: tid, gate: gate, manifestID: mid, reviewID: reviewID, caller: caller)
        if verdict == "pass",try records(db,type:"finding",
            project:pid).contains(where: {
                $0["task_id"] as? String == tid && $0["gate"] as? String == gate &&
                $0["state"] as? String == "open" && Self.findingBlocksCompletion($0)
            }) {
                throw CoreError("FINDINGS_UNRESOLVED",
                    "Resolve, reject with evidence or explicitly waive every applicable finding before a passing verdict.")
            }
        return (created,resolved)
    }
    func resolveReviewFindings(_ db: Database, dispositions: [JSON], task: JSON,
                              projectID pid: String, taskID tid: String, gate: String,
                              manifestID mid: String, reviewID: String, caller: Caller) throws -> [JSON] {
        var resolved: [JSON] = []
        for input in dispositions {
            let id = try text(input,"finding_id"); var finding = try scoped(db,id,pid,type:"finding")
            guard finding["task_id"] as? String == tid,finding["gate"] as? String == gate,finding["state"] as? String == "open" else { throw CoreError("FINDINGS_UNRESOLVED","This finding is not an open finding for this task and gate.") }
            let disposition = try text(input,"disposition"); guard ["resolved","rejected"].contains(disposition) else { throw CoreError("HUMAN_CHANNEL_REQUIRED","Use finding_waive for a separate explicitly attributed waiver.") }
            let reason = try text(input,"reason",max:8000); let refs = input["evidence_refs"] as? [Any] ?? []
            try findingEvidence(db,refs:refs,task:task,manifestID:mid)
            let resolution: JSON = ["id":uuid(),"project_id":pid,"task_id":tid,"finding_id":id,"review_id":reviewID,"manifest_id":mid,"disposition":disposition,"reason":reason,"evidence_refs":refs,"actor":caller.principal,"actor_display":author(db,caller),"created_at":now(),"revision":1]
            try save(db,resolution,type:"finding_resolution"); finding["state"] = disposition; finding["latest_resolution_id"] = resolution["id"]; finding["resolved_on_manifest_id"] = mid; try save(db,revised(finding),type:"finding"); resolved.append(resolution)
            try event(db,caller:caller,project:pid,entity:tid,kind:"finding_"+disposition,data:["finding_id":id,"resolution_id":(try StoredRecord(resolution,
                family: "finding_resolution").string("id")),"review_id":reviewID])
        }
        return resolved
    }

    func createReviewFindings(_ db: Database, proposed: [JSON], projectID pid: String,
                             taskID tid: String, gate: String, manifestID mid: String,
                             reviewID: String, caller: Caller) throws -> [JSON] {
        var created: [JSON] = []
        for input in proposed {
            let severity = input["severity"] as? String ?? "blocking"; guard Self.findingSeverities.contains(severity) else { throw CoreError("INVALID_INPUT","Use severity blocking or advice.") }
            // CL-43: a finding can name an earlier finding of this ticket with the same cause, also a resolved one (a reopen).
            let id = uuid(); var cause = id, earlierID: String? = nil
            if let ref = input["same_cause_as"] {
                let earlier = try scoped(db,try text(["ref":ref],"ref",max:200),pid,type:"finding"); guard earlier["task_id"] as? String == tid else { throw CoreError("REVIEW_TARGET_MISMATCH","same_cause_as must name a finding of this ticket.") }
                cause = try earlier["cause_id"] as? String ?? StoredRecord(earlier, family: "finding").string("id"); earlierID = earlier["id"] as? String
            }
            var finding: JSON = ["id":id,"project_id":pid,"task_id":tid,"gate":gate,"client_ref":try text(input,"client_ref",max:200),"severity":severity,"description":try text(input,"description",max:16000),"evidence_refs":input["evidence_refs"] ?? [],"first_manifest_id":mid,"first_review_id":reviewID,"state":"open","author":caller.principal,"author_display":author(db,caller),"revision":1,"created_at":now()]
            finding["cause_id"] = cause; if let earlierID { finding["same_cause_as"] = earlierID }
            try save(db,finding,type:"finding"); created.append(finding)
        }
        return created
    }

    func reviewRequest(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db,p,c,write:true); var task = try self.task(db,p,pid); try revision(p,task)
        guard task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("REVIEW_ALREADY_ACTIVE","Finish or release the existing verification first.") }
        let mid = try text(p,"target_manifest_id"),gate = try text(p,"gate"); _ = try validateManifestTarget(db,task:task,manifestID:mid)
        let manifest = try scoped(db,mid,pid,type:"manifest"); guard try manifestGates(db,manifest).contains(gate) else { throw CoreError("POLICY_DENIED","This gate is not required by the submitted target’s pinned policy.") }
        let existing = try records(db,type:"review_request",project:pid).last { $0["task_id"] as? String == task["id"] as? String && $0["manifest_id"] as? String == mid && $0["gate"] as? String == gate }
        // A request for the same target/gate continues the current Review phase.
        // New targets and actual phase changes still use the individual status departure.
        let category = try taskProjection(db,task)["status_category"] as? String
        let continuesReview = existing != nil && category == "review"
        if p["supplemental_evidence_refs"] != nil,existing?["state"] as? String != "evidence_requested" { throw CoreError("INVALID_INPUT","Supplemental evidence answers a retained legacy evidence_requested request on this target and gate; new review gaps require a fresh work_submit.") }
        if let existing = existing,existing["state"] as? String == "queued" { if !continuesReview { try recordTicketStatusAction(db,task:task,caller:c) }; var result = existing;result["key"] = task["key"];result["title"] = task["title"];return result }
        if let existing = existing { guard p["supersedes_request_id"] as? String == existing["id"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","Name the current request when explicitly starting another review round.") }; _ = try text(p,"reason",max:8000) }
        var request: JSON = ["id":uuid(),"project_id":pid,"task_id":(try StoredRecord(task, family: "task").string("id")),"manifest_id":mid,"gate":gate,"state":"queued",
            "revision":1,"created_at":now()]
        if let existing = existing { request["supersedes_request_id"] = existing["id"] }
        // Retained legacy CL-41 evidence_requested records can return the same target with added evidence;
        // no new implementation round and no new manifest.
        if let existing,existing["state"] as? String == "evidence_requested" { request["answers_evidence_request"] = existing["evidence_request"] ?? NSNull() }
        if let refs = p["supplemental_evidence_refs"] as? [JSON] {
            guard !refs.isEmpty,refs.count <= 50 else { throw CoreError("INVALID_INPUT","Name 1 to 50 supplemental evidence attachments.") }
            request["supplemental_evidence_refs"] = try refs.map { ref -> JSON in
                let attachment = try scoped(db,try text(ref,"artifact_id",max:200),pid,type:"attachment")
                guard attachment["task_id"] as? String == task["id"] as? String,attachment["sha256"] as? String == ref["sha256"] as? String,attachment["mode"] as? String == "managed",attachment["availability"] as? String == "available",let path = attachment["path"] as? String,objectBytesMatch(path,sha256:attachment["sha256"] as? String ?? "") else { throw CoreError("EVIDENCE_STALE","Supplemental evidence must be an available managed attachment of this ticket with its exact hash.") }
                return ["artifact_id":attachment["id"]!,"sha256":attachment["sha256"]!,"name":attachment["name"] ?? ""]
            }
        } else if p["supplemental_evidence_refs"] != nil { throw CoreError("INVALID_INPUT","supplemental_evidence_refs is a list of attachment references.") }
        try save(db,request,type:"review_request"); if !continuesReview { task["status_id"] = try status(db,pid,"review")["id"] }; try save(db,revised(task),type:"task"); if !continuesReview { try recordTicketStatusAction(db,task:task,caller:c) }
        try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"review_requested",data:["review_request_id":(try StoredRecord(request,
            family: "request").string("id")),"manifest_id":mid,"gate":gate]); request["key"] = task["key"];request["title"] = task["title"];return request
    }
    func findingWaive(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c,write:true); try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:c); var finding = try scoped(db,try text(p,"finding_id"),pid,type:"finding"); try revision(p,finding)
        guard finding["state"] as? String == "open" else { throw CoreError("FINDINGS_UNRESOLVED","Only an open finding can be waived.") }
        let resolution: JSON = ["id":uuid(),"project_id":pid,"task_id":(try StoredRecord(finding, family: "finding").string("task_id")),"finding_id":(try StoredRecord(finding,
            family: "finding").string("id")),"disposition":"waived","reason":try text(p,"reason",max:8000),"actor":c.principal,"actor_display":c.isOwner ? "You" : "Agent",
            "origin":c.isOwner ? "human_ui" : "agent","waiver_kind":c.isOwner ? "owner_waiver" : "agent_waiver","session_id":c.sessionID ?? "human","revision":1,"created_at":now()]
        try save(db,resolution,type:"finding_resolution"); finding["state"] = "waived"; finding["latest_resolution_id"] = resolution["id"]; finding = revised(finding); try save(db,
            finding,type:"finding"); try event(db,caller:c,project:pid,entity:finding["task_id"] as? String,kind:"finding_waived",data:["finding_id":(try StoredRecord(finding,
            family: "finding").string("id")),"resolution_id":(try StoredRecord(resolution, family: "finding_resolution").string("id"))]); return finding
    }
}
