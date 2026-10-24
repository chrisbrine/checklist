import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    func sessionWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c,write:true)
        if c.role == "assistant" && method == "session_register" { throw CoreError("FORBIDDEN","Assistants connect through owner enrollment and never register a work session.") }
        let id: String
        if c.isOwner { id = p["session_id"] as? String ?? uuid() } else { guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","This connection has no bound native session.") }; id = sid }
        if !c.isOwner,(try? scoped(db,id,pid,type:"session")) == nil { throw CoreError("FORBIDDEN","Pair this connection in the app before registering its session.") }
        var r = (try? scoped(db,id,pid,type:"session")) ?? ["id":id,"project_id":pid,"revision":0,"created_at":now()]
        let original = r
        if !c.isOwner, p["state"] as? String == "revoked" || bool(r,"owner_revoked") || bool(r,"owner_reconnect_allowed") || ["revoked","ended"].contains(r["state"] as? String ?? "") {
            throw CoreError("FORBIDDEN","Only the owner can disconnect a conversation or allow it again.")
        }
        if method == "session_update" { try revision(p,r) }
        if let profile = p["profile_id"] as? String { guard (p["role"] as? String ?? r["role"] as? String ?? c.role) == "assistant" else { throw CoreError("FORBIDDEN","Personal assistant identities cannot be bound to worker sessions.") }; _ = try record(db,profile,type:"profile"); if !c.isOwner && r["profile_id"] as? String != profile { throw CoreError("FORBIDDEN","Only the owner pairs a profile to a connection.") }; r["profile_id"] = profile }
        if c.isOwner { r["project_ids"] = (p["project_ids"] != nil ? Array(Set(strings(p,"project_ids") + [pid])) : (r["project_ids"] ?? [pid])); r["role"] = p["role"] as? String ?? r["role"] as? String ?? "worker"; r["provider"] = p["provider"] ?? r["provider"] ?? "manual"; r["workspace"] = p["workspace"] ?? r["workspace"] ?? ""; r["installation"] = p["installation"] ?? r["installation"] ?? c.installation; if let domain = p["execution_domain"] as? String { r["execution_domain"] = domain } }
        else { r["role"] = c.role; r["installation"] = c.installation; r["workspace"] = c.workspace ?? ""; if r["provider"] == nil { r["provider"] = p["provider"] ?? "unverified" } }
        if c.isOwner {
            if method == "session_register" { for field in ["host_identity_verified","host_identity_ref","adapter_registry_id"] { r.removeValue(forKey:field) } }
            let role = r["role"] as? String ?? "worker"
            guard ["worker","assistant"].contains(role) else { throw CoreError("INVALID_INPUT","Connections must use worker or assistant access.") }
            if role == "assistant" {
                let old = r["assistant_grants"] as? [String:[String:Bool]] ?? [:]
                let grants = try normalizedAssistantGrants(p["assistant_grants"] ?? r["assistant_grants"],projects:strings(r,"project_ids"))
                if old != grants || r["grant_generation"] == nil { r["grant_generation"] = uuid() }
                r["assistant_grants"] = grants
            } else { if r["assistant_grants"] != nil { r["grant_generation"] = uuid() }; r.removeValue(forKey:"assistant_grants"); r.removeValue(forKey:"profile_id") }
        }
        r["label"] = p["label"] ?? p["name"] ?? r["label"] ?? "Connected agent"
        r["state"] = p["state"] ?? r["state"] ?? "connected"; r["last_seen"] = now(); r["identity_verification"] = "owner_enrolled_or_self_reported"; r["delivery_capability"] = "pickup_only"; r["native_push"] = false
        let authKeys = ["installation","role","provider","workspace","profile_id","project_ids","assistant_grants","execution_domain"]
        let before = original.filter {authKeys.contains($0.key)},after = r.filter {authKeys.contains($0.key)}
        let endedBefore = ["revoked","ended"].contains(original["state"] as? String ?? ""),endedAfter = ["revoked","ended"].contains(r["state"] as? String ?? "")
        if c.isOwner && !endedAfter { r.removeValue(forKey:"owner_revoked") }
        let identityChanged = try jsonString(before) != jsonString(after)
        if r["authorization_generation"] == nil || (c.isOwner && (method == "session_register" || identityChanged || endedBefore != endedAfter)) { r["authorization_generation"] = uuid() }
        r = revised(r); try save(db,r,type:"session"); try event(db,caller:c,project:pid,entity:id,kind:"session_registered"); return r
    }
    func claimAttempt(_ db: Database,_ p: JSON,_ c: Caller,_ pid: String) throws -> JSON {
        let a = try scoped(db,try text(p,"attempt_id"),pid,type:"attempt")
        guard a["state"] as? String == "active",a["incarnation"] as? String == incarnation, a["principal"] as? String == c.principal,a["session_authorization_generation"] as? String == (try callerSessionGeneration(db,c,project:pid)), let token = p["claim_token"] as? String,a["token_hash"] as? String == hash(Data(token.utf8)) else { throw CoreError("STALE_CLAIM","This claim is no longer live for this session.") }
        return a
    }
    /// Completion checks shared by task_complete and the automatic Done after a
    /// passing review. Prerequisites and the caller's direction cursor are checked
    /// by each caller first. Throws the first unmet condition.
    /// `answeringRequestID` names a human approval being answered in this same command.
    func requireCompletable(_ db: Database,task t: JSON,pid: String,requestedManifestID: String? = nil,acceptedVerdictIDs: [String]? = nil,answeringRequestID: String? = nil,releasingHold: Bool = false) throws {
        // CL-45 (finding ff90ecdf): a ticket held for a release set completes only with its set.
        if !releasingHold,let hold = t["release_hold"] as? JSON { throw CoreError("RELEASE_HOLD_ACTIVE","This ticket waits for release set \(hold["release_set"] as? String ?? ""). Complete it with release_set_complete.") }
        guard try unresolvedSourceExecutions(db,taskID:t["id"] as? String).isEmpty else { throw CoreError("SOURCE_EXECUTION_ACTIVE","Source execution must finish or have verified stop recovery before completion.") }
        guard t["active_attempt_id"] == nil,t["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","Active work must be released before completion.") }
        guard !(try records(db,type:"request",project:pid).contains { $0["task_id"] as? String == t["id"] as? String && $0["state"] as? String == "pending" && bool($0,"blocking") && $0["id"] as? String != answeringRequestID }) else { throw CoreError("DEPENDENCY_UNSATISFIED","Answer the pending human request first.") }
        guard !(try hasPendingDirections(db,task:t)) else { throw CoreError("USER_DIRECTION_PENDING","An owner direction still needs an addressed disposition.") }
        guard let mid = t["current_manifest_id"] as? String else { throw CoreError("EVIDENCE_STALE","Submit current work evidence before completing this task.") }
        if let requested = requestedManifestID,requested != mid { throw CoreError("REVIEW_TARGET_MISMATCH","The requested target is no longer current.") }
        let manifest = try validateManifestTarget(db,task:t,manifestID:mid)
        let gates = try manifestGates(db,manifest)
        // CL-42: open advice findings stay visible but do not block completion.
        guard !(try records(db,type:"finding",project:pid).contains {$0["task_id"] as? String == t["id"] as? String && $0["state"] as? String == "open" && Self.findingBlocksCompletion($0)}) else { throw CoreError("FINDINGS_UNRESOLVED","Open blocking findings must be explicitly resolved, rejected or waived before completion.") }
        let requests = try records(db,type:"review_request",project:pid).filter {$0["task_id"] as? String == t["id"] as? String && $0["manifest_id"] as? String == mid}
        for gate in gates {
            guard let request = requests.last(where: {$0["gate"] as? String == gate}),request["state"] as? String == "pass",let verdictID = request["latest_verdict_id"] as? String else { throw CoreError("DEPENDENCY_UNSATISFIED","The latest \(gate) gate has not passed for the current target.") }
            let verdict = try scoped(db,verdictID,pid,type:"review"); guard verdict["manifest_id"] as? String == mid,verdict["verdict"] as? String == "pass" else { throw CoreError("EVIDENCE_STALE","A gate verdict no longer matches this target.") }
            if let acceptedVerdictIDs,!acceptedVerdictIDs.contains(verdictID) { throw CoreError("EVIDENCE_STALE","The accepted verdict list omits a current required gate.") }
        }
    }
    func work(_ db: Database,_ p: JSON,_ c: Caller,_ method: String,operation: TicketStatusOperation = .individual,batchContext: BatchClaimContext? = nil) throws -> JSON {
        try worker(c); let pid = try scope(db,p,c,write:true)
        if method == "task_complete" {
            var t = try task(db,p,pid); try revision(p,t)
            if let hold = t["release_hold"] as? JSON { throw CoreError("RELEASE_HOLD_ACTIVE","This ticket waits for release set \(hold["release_set"] as? String ?? ""). Complete it with release_set_complete.") }
            try requirePrerequisitesSatisfied(db,task:t)
            try validateDirectionCursor(db,params:p,task:t,caller:c)
            try requireCompletable(db,task:t,pid:pid,requestedManifestID:p["current_manifest_id"] as? String,acceptedVerdictIDs:p["accepted_verdict_ids"] != nil ? strings(p,"accepted_verdict_ids") : nil)
            let target = try (p["target_status_id"] as? String).map { try scoped(db,$0,pid,type:"status") } ?? status(db,pid,"done")
            guard target["category"] as? String == "done",!bool(target,"retired") else { throw CoreError("INVALID_TRANSITION","Completion requires an available Done status in this project.") }
            t["status_id"] = target["id"]; t["completed_at"] = now(); t = revised(t); try save(db,t,type:"task"); try recordTicketStatusAction(db,task:t,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"task_completed"); return try taskProjection(db,t)
        }
        if method == "work_recover" {
            try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:c); var t = try task(db,p,pid); try revision(p,t); guard let aid = p["attempt_id"] as? String ?? t["active_attempt_id"] as? String else { return try taskProjection(db,t) }
            var a = try scoped(db,aid,pid,type:"attempt")
            guard a["state"] as? String == "active" else { throw CoreError("STALE_CLAIM","Only live attempts need verified recovery.") }
            guard a["task_id"] as? String == t["id"] as? String else { throw CoreError("NOT_FOUND","This attempt belongs to another task.") }
            try requireNoWritableChildren(db,attempt:a)
            guard p["action"] as? String == "confirm_stopped_revoke", !(try text(p,"reason")).isEmpty, !strings(p,"observation_refs").isEmpty, !strings(p,"file_state_refs").isEmpty else { throw CoreError("RECOVERY_REQUIRED","Record explicit stop verification and file-state observation references. A timeout is insufficient.") }
            try recoverSourceExecutions(db,attempt:a,params:p,caller:c)
            if let rid = a["review_request_id"] as? String { var request = try scoped(db,rid,pid,type:"review_request");request["state"] = t["current_manifest_id"] as? String == request["manifest_id"] as? String ? "queued" : "superseded";try save(db,revised(request),type:"review_request") }
            a["state"] = "revoked"; a["recovery_reason"] = p["reason"];a["recovery_origin"] = c.isOwner ? "human_ui" : "agent";a["recovered_by"] = c.principal;a["recovery_session_id"] = c.sessionID ?? "human";a["stop_observation_refs"] = p["observation_refs"];a["file_state_refs"] = p["file_state_refs"];a.removeValue(forKey:"token_hash"); try save(db,revised(a),type:"attempt"); if a["parent_attempt_id"] != nil { return ["attempt_id":a["id"]!,"state":"revoked"] };t.removeValue(forKey:"active_attempt_id"); t["status_id"] = try status(db,pid,"blocked")["id"]; t = revised(t); try save(db,t,type:"task"); try recordTicketStatusAction(db,task:t,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"claim_revoked",data:["reason":a["recovery_reason"]!]); return try taskProjection(db,t)
        }
        if method == "work_claim" {
            var t = try task(db,p,pid); try revision(p,t)
            guard !bool(t,"archived"),!bool(t,"trashed"),t["readiness"] as? String == "ready" else { throw CoreError("NOT_READY","Only Ready, visible tasks can be claimed.") }
            try requirePrerequisitesSatisfied(db,task:t)
            if p["phase"] as? String != "review",let returned = try pickupReturnedImplementation(db,params:p,task:t,caller:c) { return returned }
            guard t["active_attempt_id"] == nil,t["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","Another session already holds this task.") }
            if let a = t["planned_assignee"] as? String,a == "human",!c.isOwner,p["phase"] as? String != "review" { throw CoreError("POLICY_DENIED","This task is assigned to the owner.") }
            if let a = t["planned_assignee"] as? JSON,a["kind"] as? String == "human",!c.isOwner,p["phase"] as? String != "review" { throw CoreError("POLICY_DENIED","This task is assigned to the owner.") }
            let phase = p["phase"] as? String ?? "implementation"
            guard ["implementation","review"].contains(phase) else { throw CoreError("INVALID_INPUT","Invalid work phase.") }
            let project = try record(db,pid,type:"project")
            if let pr = p["policy_revision"],(pr as? NSNumber)?.intValue != int(project,"policy_revision",default:1) { throw CoreError("POLICY_CHANGED","Refresh the current workflow rules before claiming.") }
            if !c.isOwner {
                guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","A paired work session is required.") }
                let session = try scoped(db,sid,pid,type:"session"); let provider = (session["provider"] as? String ?? "").lowercased()
                guard session["role"] as? String == "worker",session["state"] as? String != "revoked",providerPlugins.plugin(provider, requiring: .workSession) != nil else { throw CoreError("POLICY_DENIED","This enrolled provider is not enabled for work in this build.") }
            }
            let policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:t["kind"] as? String ?? "work")
            try validatePolicySelection(db,project:project,task:t,caller:c,phase:phase,policy:policy)
            try validateScopeInputs(p)
            let scopes = try normalizedWorkScopes(db,project:project,fileScopes:p["file_scopes"] as? [JSON] ?? [],laneScopes:p["lane_scopes"] as? [JSON] ?? [])
            var a: JSON = ["id":uuid(),"project_id":pid,"task_id":t["id"]!,"phase":phase,"principal":c.principal,"installation":c.installation,"actor_display":author(db,c),"session_id":c.sessionID ?? "human","session_authorization_generation":try callerSessionGeneration(db,c,project:pid),"state":"active","incarnation":incarnation,"revision":1,"started_at":now(),"policy_revision":project["policy_revision"] ?? 1,"policy_snapshot":policy,"file_scopes":scopes.files,"lane_scopes":scopes.lanes]
            if let domain = c.executionDomain { a["execution_domain"] = domain }
            if let context = batchContext { try installBatchContext(context,attempt:&a) }
            try validateWorkReservations(db,candidate:a,batchContext:batchContext)
            if phase == "review" {
                let rid = try text(p,"review_request_id"); var request = try scoped(db,rid,pid,type:"review_request")
                guard request["task_id"] as? String == t["id"] as? String,request["manifest_id"] as? String == p["target_manifest_id"] as? String,request["gate"] as? String == p["gate"] as? String,request["state"] as? String == "queued" else { throw CoreError("REVIEW_TARGET_MISMATCH","Claim the exact queued review request, gate and manifest.") }
                let manifest = try validateManifestTarget(db,task:t,manifestID:request["manifest_id"] as! String)
                try validateContributorIndependence(manifest:manifest,caller:c)
                guard request["gate"] as? String != "human_approval" else { throw CoreError("HUMAN_CHANNEL_REQUIRED","Request exact-target human approval through the owner answer form.") }
                a["review_requirement_snapshot"] = try pinReviewRequirement(db,project:project,task:t)
                if let captured = manifest["policy_snapshot"] as? JSON { a["policy_snapshot"] = captured } else { a["policy_snapshot"] = try attemptPolicy(db,try scoped(db,manifest["attempt_id"] as! String,pid,type:"attempt")) }; a["policy_revision"] = manifest["policy_revision"] ?? a["policy_revision"]; a["review_request_id"] = rid; a["manifest_id"] = request["manifest_id"]; a["gate"] = request["gate"]; request["state"] = "active"; try save(db,revised(request),type:"review_request")
            } else {
                let cat = try taskProjection(db,t)["status_category"] as? String ?? "queued"
                guard ["queued","blocked"].contains(cat) else { throw CoreError("INVALID_TRANSITION","Queue a Parked task before pickup.") }
            }
            let token = uuid()+uuid(); a["token_hash"] = hash(Data(token.utf8)); try save(db,a,type:"attempt")
            // A new implementation round ends any release-set hold of an earlier pass (CL-45).
            if phase != "review" { t.removeValue(forKey:"release_hold") }
            t["active_attempt_id"] = a["id"]; t["status_id"] = try status(db,pid,phase == "review" ? "review" : "active")["id"]; t = revised(t); try save(db,t,type:"task"); try recordTicketStatusAction(db,task:t,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"work_claimed",data:["attempt_id":a["id"]!,"phase":phase]); a.removeValue(forKey:"token_hash"); a["claim_token"] = token; a["task"] = try taskProjection(db,t);a["context"] = try compactTaskContext(db,task:t,caller:c);return a
        }
        var a = try claimAttempt(db,p,c,pid); var t = try scoped(db,a["task_id"] as! String,pid,type:"task")
        try verifyPolicyAuthority(db,attempt:a,caller:c,requireAcknowledgment: !["work_checkpoint","work_release"].contains(method))
        if method == "work_checkpoint" {
            if p["file_scopes"] != nil || p["lane_scopes"] != nil { try verifyPolicyAuthority(db,attempt:a,caller:c);try adjustWorkScopes(db,params:p,attempt:&a) }
            let progress = try text(p,"progress"); recordHealthProgress(&a,progress:progress); a["progress"] = progress; a["last_checkpoint"] = now(); try recordResourceWait(p,attempt:&a); a = revised(a); try save(db,a,type:"attempt"); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"work_checkpoint",data:["progress":a["progress"]!]); let checkpoint = try recordDirectionCheckpoint(db,params:p,attempt:a,progress:a["progress"] as! String,caller:c);a["checkpoint_id"] = checkpoint["id"];a["context"] = try compactTaskContext(db,task:t,caller:c);a["direction_cursor"] = (a["context"] as? JSON)?["direction_cursor"];a.removeValue(forKey:"token_hash");return a
        }
        if method == "work_release" {
            try requireNoSourceExecutions(db,attempt:a)
            try requireNoWritableChildren(db,attempt:a)
            try recordFinalReport(p,caller:c,attempt:&a); a.removeValue(forKey:"draft_verdict")
            if a["parent_attempt_id"] != nil { a["state"] = "released";a["reason"] = try text(p,"reason");a.removeValue(forKey:"token_hash");try save(db,revised(a),type:"attempt");a.removeValue(forKey:"incarnation");return a }
            if let rid = a["review_request_id"] as? String { var request = try scoped(db,rid,pid,type:"review_request"); request["state"] = "queued"; try save(db,revised(request),type:"review_request") }
            a["state"] = "released"; a["reason"] = try text(p,"reason"); a.removeValue(forKey:"token_hash"); try save(db,revised(a),type:"attempt"); t.removeValue(forKey:"active_attempt_id"); t["status_id"] = try status(db,pid,a["phase"] as? String == "review" ? "review" : "queued")["id"]; t = revised(t); try save(db,t,type:"task"); try recordTicketStatusAction(db,task:t,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"work_released",data:["reason":a["reason"]!]); return try taskProjection(db,t)
        }
        if method == "work_submit" {
            guard a["parent_attempt_id"] == nil else { throw CoreError("INVALID_TRANSITION","A contributor releases its bounded work; only the parent submits the ticket.") }
            try requireNoWritableChildren(db,attempt:a)
            try validateDirectionCursor(db,params:p,task:t,caller:c,attempt:a)
            guard a["phase"] as? String == "implementation" else { throw CoreError("INVALID_TRANSITION","Use review_record for review attempts.") }
            guard int(p,"acceptance_revision") == int(t,"acceptance_revision",default:1) else { throw CoreError("EVIDENCE_STALE","Acceptance changed during this attempt.") }
            guard !(try hasPendingDirections(db,task:t)) else { throw CoreError("USER_DIRECTION_PENDING","Address the outstanding owner direction before submission.") }
            guard var evidence = p["evidence_manifest"] as? JSON else { throw CoreError("INVALID_INPUT","Submit target-appropriate immutable evidence.") }
            evidence.removeValue(forKey:"acceptance_evidence")
            if let map = try normalizedAcceptanceEvidence(db,params:p,evidence:evidence,task:t,attempt:a,caller:c) { evidence["acceptance_evidence"] = map }
            try normalizedEvidenceMeasures(&evidence)
            let kind = evidence["kind"] as? String ?? (evidence["source_capture"] != nil ? "source" : "artifact")
            guard ["source","artifact","decision"].contains(kind) else { throw CoreError("INVALID_INPUT","Evidence target must be source, artifact or decision.") }
            evidence["kind"] = kind
            if kind == "artifact",evidence["source_capture"] != nil || evidence["decision"] != nil { throw CoreError("INVALID_INPUT","Artifact evidence cannot carry an unverified source or decision target.") }
            if kind == "source" {
                guard let request = evidence["source_capture"] as? JSON,evidence["decision"] == nil else { throw CoreError("INVALID_INPUT","Source evidence requires a complete source capture request.") }
                evidence["source_capture"] = try captureSource(db,request:request,task:t,attempt:a)
            } else if kind == "decision" {
                let assignment = t["planned_assignee"] as? String ?? (t["planned_assignee"] as? JSON)?["kind"] as? String ?? ""
                let policy = try attemptPolicy(db,a)
                guard t["kind"] as? String == "question" || (assignment == "human" && bool(policy,"allow_human_decision_evidence")),let decision = evidence["decision"] as? JSON,evidence["source_capture"] == nil,(evidence["artifact_refs"] as? [JSON] ?? []).isEmpty else { throw CoreError("INVALID_INPUT","Decision-only evidence is for Questions or explicitly allowed human decision work.") }
                let decisionText = try text(decision,"text")
                evidence["decision"] = ["text":decisionText,"sha256":hash(Data(decisionText.utf8)),"origin":c.isOwner ? "human_ui" : "agent","actor":c.principal,"recorded_at":now()]
            }
            try normalizePlaytestBundle(db,evidence:&evidence,task:t)
            let refs = evidence["artifact_refs"] as? [JSON] ?? []
            if kind == "artifact",refs.isEmpty { throw CoreError("EVIDENCE_STALE","Artifact work requires at least one managed immutable artifact.") }
            for ref in refs {
                let artifact = try scoped(db,try text(ref,"artifact_id"),pid,type:"attachment")
                guard artifact["task_id"] as? String == t["id"] as? String,artifact["sha256"] as? String == ref["sha256"] as? String,artifact["mode"] as? String == "managed",artifact["availability"] as? String == "available",let path = artifact["path"] as? String,objectBytesMatch(path,sha256:artifact["sha256"] as? String ?? "") else { throw CoreError("EVIDENCE_STALE","The evidence artifact is unavailable or mismatched.") }
            }
            let pinnedPolicy = try attemptPolicy(db,a)
            try recordFinalReport(p,caller:c,attempt:&a)
            let mid = uuid(); var manifest: JSON = ["id":mid,"project_id":pid,"task_id":t["id"]!,"attempt_id":a["id"]!,"author_principal":c.principal,"author_installation":c.installation,"author_session_id":c.sessionID ?? "human","acceptance_revision":t["acceptance_revision"]!,"policy_revision":a["policy_revision"] ?? 1,"policy_snapshot":pinnedPolicy,"required_gates":strings(pinnedPolicy,"required_gates"),"evidence":evidence,"digest":hash(Data((try jsonString(evidence)).utf8)),"revision":1,"created_at":now()]
            if let domain = c.executionDomain { manifest["author_execution_domain"] = domain }
            manifest["contributors"] = try contributionHistory(db,attempt:a)
            for var old in try records(db,type:"review_request",project:pid) where old["task_id"] as? String == t["id"] as? String && ["queued","blocked"].contains(old["state"] as? String ?? "") { old["state"] = "superseded"; try save(db,revised(old),type:"review_request") }
            try save(db,manifest,type:"manifest"); t["current_manifest_id"] = mid; t.removeValue(forKey:"active_attempt_id"); t["status_id"] = try status(db,pid,"review")["id"]; t = revised(t); try save(db,t,type:"task"); a["state"] = "submitted"; a.removeValue(forKey:"token_hash"); try save(db,revised(a),type:"attempt")
            var requestIDs: [String] = []
            for gate in strings(pinnedPolicy,"required_gates") { let rid = uuid(); requestIDs.append(rid); try save(db,["id":rid,"project_id":pid,"task_id":t["id"]!,"manifest_id":mid,"gate":gate,"state":"queued","revision":1],type:"review_request") }
            try recordTicketStatusAction(db,task:t,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"work_submitted",data:["manifest_id":mid]); return ["task":try taskProjection(db,t),"manifest_id":mid,"review_request_ids":requestIDs]
        }
        if method == "review_record" {
            try validateDirectionCursor(db,params:p,task:t,caller:c,attempt:a)
            return try recordReviewVerdict(db,params:p,attempt:a,task:t,reviewer:c,actor:c,operation:operation)
        }
        throw CoreError("UNSUPPORTED_METHOD","This work command is not implemented.")
    }

    /// Records one verdict for an active review attempt. `reviewer` wrote the verdict (its claim,
    /// findings and evidence); `actor` runs the command: the reviewer itself, or the coordinator
    /// that submits the reviewer's saved draft (CL-44), named in `submitted_by`.
    func recordReviewVerdict(_ db: Database,params p: JSON,attempt claimed: JSON,task current: JSON,reviewer c: Caller,actor: Caller,operation: TicketStatusOperation,submittedBy: JSON? = nil) throws -> JSON {
        var a = claimed,t = current; let pid = t["project_id"] as! String
        try requireNoSourceExecutions(db,attempt:a)
        guard a["phase"] as? String == "review",a["review_request_id"] as? String == p["review_request_id"] as? String,a["manifest_id"] as? String == p["target_manifest_id"] as? String,a["gate"] as? String == p["gate"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","The verdict must name this claim's exact request, gate and target.") }
        guard t["current_manifest_id"] as? String == a["manifest_id"] as? String else { throw CoreError("EVIDENCE_STALE","The task's target changed.") }
        _ = try validateManifestTarget(db,task:t,manifestID:a["manifest_id"] as! String)
        let verdict = try text(p,"verdict"); guard Self.reviewVerdicts.contains(verdict) else { throw CoreError("INVALID_INPUT","Use pass, reject, blocked, evidence_missing or not_run.") }
        let outcome = try reviewOutcomeDetails(p,verdict:verdict)
        let returnsToImplementation = verdict == "evidence_missing" || verdict == "not_run" || (verdict == "blocked" && outcome["blocked_on"] as? String == "implementation")
        let checks = try normalizedReviewChecks(db,p,task:t)
        let hold = try releaseHoldRequest(p,verdict:verdict)
        let appliedReviewRequirement = try reviewRequirementState(db,task:t)
        let assessment = try validateReviewAssessment(db,params:p,task:t,attempt:a,verdict:verdict,caller:c)
        let inspectionManifest = try scoped(db,a["manifest_id"] as! String,pid,type:"manifest")
        let inspectedImages = try validatedImageInspections(db,params:p,task:t,manifest:inspectionManifest,requireComplete:verdict == "pass")
        let reviewID = uuid(); let applied = try applyFindings(db,params:p,task:t,attempt:a,reviewID:reviewID,verdict:verdict,caller:c)
        var r: JSON = ["id":reviewID,"project_id":pid,"task_id":t["id"]!,"manifest_id":a["manifest_id"]!,"review_request_id":a["review_request_id"]!,"gate":a["gate"]!,"verdict":verdict,"checks":checks,"findings":applied.findings,"finding_resolutions":applied.resolutions,"actor":c.principal,"actor_display":author(db,c),"revision":1,"created_at":now()]
        r["review_requirement_snapshot"] = appliedReviewRequirement["snapshot"]
        r["inspected_images"] = inspectedImages
        if let assessment { r["review_assessment"] = assessment }
        if let retained = try retainCitedPlaytestFiles(db,params:p,task:t,attempt:a,assessment:assessment,verdict:verdict) { r["retained_artifact_refs"] = retained }
        for (key,value) in outcome { r[key] = value }
        if let submittedBy { r["submitted_by"] = submittedBy; r["draft_saved_at"] = (a["draft_verdict"] as? JSON)?["saved_at"] }
        if let previous = p["supersedes_verdict_id"] as? String { let old = try scoped(db,previous,pid,type:"review"); guard old["task_id"] as? String == t["id"] as? String,old["gate"] as? String == a["gate"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","The superseded verdict belongs to another task or gate.") }; r["supersedes_verdict_id"] = previous }
        try save(db,r,type:"review"); var req = try scoped(db,a["review_request_id"] as! String,pid,type:"review_request"); req["latest_verdict_id"] = reviewID
        switch verdict {
        // Reviewer-side blocked returns the same request for reviewer pickup (CL-137); implementation-side blocked returns to implementation below (CL-216).
        case "blocked": req["state"] = "queued"; req["blocked_verdict_ids"] = strings(req,"blocked_verdict_ids") + [reviewID]
        // Keep missing-check details in history; CL-216 closes these requests below without counting a fail.
        case "not_run": req["state"] = "queued"; req["not_run_checks"] = (req["not_run_checks"] as? [JSON] ?? []) + [["check":outcome["check"]!,"reason":outcome["reason"]!,"review_id":reviewID,"recorded_at":now()]]
        // Preserve the evidence request details even when returning to a fresh implementation round.
        case "evidence_missing": req["state"] = "evidence_requested"; req["evidence_request"] = ["reason":outcome["reason"]!,"review_id":reviewID,"requested_at":now()]
        default: req["state"] = verdict
        }
        if returnsToImplementation { req["state"] = "returned";req["return_verdict"] = verdict;req["closed_at"] = now() }
        try recordFinalReport(p,caller:c,attempt:&a)
        try save(db,revised(req),type:"review_request"); a["state"] = "finished"; a.removeValue(forKey:"token_hash"); a.removeValue(forKey:"draft_verdict"); try save(db,revised(a),type:"attempt"); t.removeValue(forKey:"active_attempt_id"); if verdict == "reject" { t["status_id"] = try status(db,pid,"queued")["id"]; t.removeValue(forKey:"current_manifest_id"); t.removeValue(forKey:"release_hold") }
        if returnsToImplementation {
            r["implementation_return"] = try returnReviewToImplementation(db,task:&t,manifest:inspectionManifest,review:r,caller:actor)
            try save(db,r,type:"review")
        }
        // Every verdict ends this review claim. A pass on the last open gate marks the
        // ticket Done when every completion check holds (owner decision, 19 October 2026).
        var completion: JSON = ["completed":false]
        // The explicit project override hold_passing_for_batch keeps a pass in Review for a
        // batch, Triage or task_complete command; the default completes it here.
        let pinned = try (a["batch_id"] as? String).map { try scoped(db,$0,pid,type:"batch")["policy_snapshot"] as? JSON ?? [:] } ?? attemptPolicy(db,a)
        // CL-45: a pass may wait for a named release set, only when the pinned policy enables holds.
        if hold != nil,!bool(pinned,"release_set_holds") { throw CoreError("POLICY_DENIED","This project's policy does not enable release-set holds. Record the pass without release_set.") }
        if let hold {
            t["release_hold"] = ["release_set":hold.set,"reason":hold.reason,"review_id":reviewID,"manifest_id":a["manifest_id"]!,"held_at":now(),"held_by":c.principal]
            completion = ["completed":false,"waiting_for":"RELEASE_SET","release_set":hold.set,"reason":hold.reason]
        } else if verdict == "pass",let existing = t["release_hold"] as? JSON {
            // A pass on a later gate keeps the earlier release hold (finding ff90ecdf).
            completion = ["completed":false,"waiting_for":"RELEASE_SET","release_set":existing["release_set"] ?? NSNull(),"reason":existing["reason"] ?? NSNull()]
        } else if verdict == "pass",effectiveReviewBatchPolicy(pinned) == "hold_passing_for_batch" { completion = ["completed":false,"waiting_for":"PROJECT_HOLD","reason":"The project policy holds passing tickets for an explicit batch, Triage or task_complete command."] }
        else if verdict == "pass" {
            do {
                try requirePrerequisitesSatisfied(db,task:t)
                try requireCompletable(db,task:t,pid:pid)
                let done = try status(db,pid,"done")
                guard done["category"] as? String == "done",!bool(done,"retired") else { throw CoreError("INVALID_TRANSITION","Completion requires an available Done status in this project.") }
                t["status_id"] = done["id"]; t["completed_at"] = now(); completion = ["completed":true]
            } catch let waiting as CoreError { completion = ["completed":false,"waiting_for":waiting.code,"reason":waiting.message] }
        }
        t = revised(t); try save(db,t,type:"task"); try recordTicketStatusAction(db,task:t,caller:actor,operation:returnsToImplementation ? .individual : operation)
        try event(db,caller:actor,project:pid,entity:t["id"] as? String,kind:"review_"+verdict,data:["review_id":reviewID,"review_request_id":a["review_request_id"]!,"manifest_id":a["manifest_id"]!,"reviewer":c.principal,"submitted_draft":submittedBy != nil].merging(outcome) { _,new in new })
        if bool(completion,"completed") { try event(db,caller:actor,project:pid,entity:t["id"] as? String,kind:"task_completed",data:["origin":"review_pass","review_id":reviewID]) }
        r["completion"] = completion; r["task"] = try taskProjection(db,t); return r
    }
}
