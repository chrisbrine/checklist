import ChecklistDomain
import Foundation
import GRDB

extension CommandRouter {
    func batchTriageKey(_ db: Database,_ batch: JSON) -> String? {
        if let key = batch["triage_key"] as? String { return key }
        guard let id = batch["triage_id"] as? String,let pid = batch["project_id"] as? String else { return nil }
        return (try? scoped(db,id,pid,type:"group"))?["key"] as? String
    }
    /// The prepared record never changes. Claims and results are separate records/projections.
    func batchDigest(_ batch: JSON) throws -> String {
        hash(Data(try jsonString(batch.filter {$0.key != "digest"}).utf8))
    }

    func batchRead(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c)
        if method == "batch_list" {
            return ["batches":try records(db,type:"batch",project:pid).filter {p["triage_id"] == nil || $0["triage_id"] as? String == p["triage_id"] as? String}.map {try batchProjection(db,$0)}]
        }
        return try batchProjection(db,scoped(db,try text(p,"batch_id"),pid,type:"batch"))
    }

    func batchPrepare(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        let group = try scoped(db,try text(p,"triage_id"),pid,type:"group");try revision(p,group)
        guard group["kind"] as? String == "triage",!bool(group,"archived") else { throw CoreError("INVALID_INPUT","Prepare a batch from an active Triage.") }
        let phase = try text(p,"phase")
        guard AttemptPhase.wireValues.contains(phase),let selected = p["tasks"] as? [JSON],!selected.isEmpty,selected.count <= 200 else { throw CoreError("INVALID_INPUT","Select one phase and between 1 and 200 exact Triage members.") }
        guard triagePhase(group) == phase else { throw CoreError("TRIAGE_PHASE_CONFLICT","The batch phase must match its Triage. Use a separate Triage for the next phase.") }
        let ids = selected.compactMap {$0["task_id"] as? String}
        guard ids.count == selected.count,Set(ids).count == ids.count,Set(ids).isSubset(of:Set(triageMemberIDs(group))) else { throw CoreError("REVISION_CONFLICT","Select unique current members of this Triage before preparing a batch.") }
        let project = try record(db,pid,type:"project")
        var frozen: [JSON] = []
        for member in selected {
            let base: Set<String> = ["task_id","expected_revision","file_scopes","lane_scopes"]
            let allowed = phase == "review" ? base.union(["review_request_id","target_manifest_id","gate","key","contributor_session_ids"]) : base
            guard Set(member.keys).isSubset(of:allowed) else { throw CoreError("INVALID_INPUT","Batch members contain unsupported fields or review selectors in an implementation batch.") }
            guard let expected = member["expected_revision"] as? NSNumber,CFGetTypeID(expected) != CFBooleanGetTypeID(),expected.doubleValue.rounded() == expected.doubleValue,expected.intValue >= 1,(member["file_scopes"] == nil || member["file_scopes"] is [JSON]),(member["lane_scopes"] == nil || member["lane_scopes"] is [JSON]) else { throw CoreError("INVALID_INPUT","Each selected member needs a positive task revision and structured file/lane scopes.") }
            let task = try scoped(db,try text(member,"task_id"),pid,type:"task");try revision(member,task)
            if member["key"] != nil,member["key"] as? String != task["key"] as? String { throw CoreError("INVALID_INPUT","The supplied ticket key must match its current key.") }
            var snapshot: JSON = [
                "task_id": (try StoredRecord(task, family: "task").requiredValue("id")), "key": task["key"] ?? "", "title": task["title"] ?? "",
                "task_revision": (try StoredRecord(task, family: "task").requiredValue("revision")), "acceptance_revision": task["acceptance_revision"] ?? 1,
                "membership": (group["members"] as? [JSON] ?? []).first { $0["task_id"] as? String == task["id"] as? String } ?? [:],
            ]
            if phase == "review" {
                let request = try scoped(db,try text(member,"review_request_id"),pid,type:"review_request")
                let manifest = try scoped(db,try text(member,"target_manifest_id"),pid,type:"manifest")
                snapshot["review_request_id"] = request["id"];snapshot["review_request_revision"] = request["revision"];snapshot["target_manifest_id"] = manifest["id"];snapshot["manifest_revision"] = manifest["revision"];snapshot["manifest_digest"] = hash(Data(try jsonString(manifest).utf8));snapshot["gate"] = try text(member,"gate")
            }
            let scopes = try normalizedWorkScopes(db,project:project,fileScopes:member["file_scopes"] as? [JSON] ?? [],laneScopes:member["lane_scopes"] as? [JSON] ?? [])
            snapshot["file_scopes"] = scopes.files;snapshot["lane_scopes"] = scopes.lanes
            frozen.append(snapshot)
        }
        var batch: JSON = [
            "id": uuid(), "project_id": pid, "triage_id": (try StoredRecord(group, family: "group").requiredValue("id")),
            "triage_revision": (try StoredRecord(group, family: "group").requiredValue("revision")), "triage_key": group["key"] ?? "", "triage_name": group["name"] ?? "",
            "phase": phase,
            "members": frozen, "checks": p["checks"] ?? [], "policy_revision": project["policy_revision"] ?? 1, "policy_snapshot": project["policy"] ?? [:], "revision": 1,
            "prepared_by": c.principal, "created_at": now(),
        ]
        batch["digest"] = try batchDigest(batch)
        let cohort = try BatchClaimContext(batch: batch)
        // Normalize the entire selection first. Ephemeral attempts use the same cohort
        // predicate as dispatch; rollback removes every provisional authority/effect.
        try db.inSavepoint {
            for (index,member) in selected.enumerated() {
                var input = member;input["project_id"] = pid;input["phase"] = phase;input["policy_revision"] = project["policy_revision"] ?? 1
                let provisional = try work(db,input,c,"work_claim",operation:.triage,batchContext:cohort,includeClaimContext:false)
                frozen[index]["policy_revision"] = provisional["policy_revision"] ?? 1;frozen[index]["policy_snapshot"] = provisional["policy_snapshot"] ?? [:]
            }
            return .rollback
        }
        batch["members"] = frozen
        batch["digest"] = try batchDigest(batch);try save(db,batch,type:"batch")
        try event(
            db, caller: c, project: pid, entity: group["id"] as? String, kind: "batch_prepared",
            data: [
                "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "digest": (try StoredRecord(batch, family: "batch").requiredValue("digest")),
                "triage_revision": (try StoredRecord(group, family: "group").requiredValue("revision")), "task_ids": ids,
            ])
        return try batchProjection(db,batch)
    }

    func batchClaim(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        let batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch");try revision(p,batch)
        try requireBatchNotDiscarded(db,batch)
        guard batch["digest"] as? String == (try batchDigest(batch)) else { throw CoreError("EVIDENCE_STALE","The prepared batch snapshot failed its integrity check.") }
        guard !(try records(db,type:"batch_claim",project:pid).contains {$0["batch_id"] as? String == batch["id"] as? String}) else { throw CoreError("CLAIM_CONFLICT","This fixed batch was already dispatched. Prepare a new batch for further work.") }
        let project = try record(db,pid,type:"project")
        guard let policyRevision = p["policy_revision"] as? NSNumber,CFGetTypeID(policyRevision) != CFBooleanGetTypeID(),policyRevision.doubleValue.isFinite,policyRevision.decimalValue >= 1,policyRevision.decimalValue <= Decimal(Int.max),policyRevision.compare(NSNumber(value:policyRevision.intValue)) == .orderedSame else { throw CoreError("INVALID_INPUT","policy_revision must be a positive integer in the supported range. Use policy_revision returned by batch_prepare; no claims started.") }
        guard int(project,"policy_revision",default:1) == int(batch,"policy_revision") else { throw CoreError("POLICY_CHANGED","The current project policy differs from the prepared batch policy. Prepare a new batch; no claims started.") }
        guard policyRevision.intValue == int(batch,"policy_revision") else { throw CoreError("POLICY_CHANGED","The supplied policy_revision differs from the prepared batch policy_revision. Read the existing batch and current policy before retrying; no claims started.") }
        let members = batch["members"] as? [JSON] ?? []
        // Check all frozen targets before taking any member authority. Live Triage edits intentionally are irrelevant.
        for member in members {
            let task = try scoped(db, (try StoredRecord(member, family: "member").string("task_id")), pid, type: "task")
            try revision(["expected_revision": (try StoredRecord(member, family: "member").requiredValue("task_revision"))], task)
            if batch["phase"] as? String == "review" {
                let request = try scoped(db, (try StoredRecord(member, family: "member").string("review_request_id")), pid, type: "review_request")
                try revision(["expected_revision": (try StoredRecord(member, family: "member").requiredValue("review_request_revision"))], request)
                let manifest = try scoped(db, (try StoredRecord(member, family: "member").string("target_manifest_id")), pid, type: "manifest")
                guard int(manifest,"revision") == int(member,"manifest_revision"),hash(Data(try jsonString(manifest).utf8)) == member["manifest_digest"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","An exact prepared target changed; no claims started.") }
            }
        }
        let cohort = try BatchClaimContext(batch: batch)
        var claims: [JSON] = []
        // Only this fixed batch transaction shares row identities. Writes
        // invalidate their family; every consumer still checks its full scope.
        let selectedTasks = try members.map { try scoped(db, (try StoredRecord($0, family: "member").string("task_id")), pid, type: "task") }
        try withTaskRecordSelection(db,tasks:selectedTasks) {
        for member in members {
                var input: JSON = [
                    "project_id": pid, "task_id": (try StoredRecord(member, family: "member").requiredValue("task_id")),
                    "expected_revision": (try StoredRecord(member, family: "member").requiredValue("task_revision")),
                    "phase": (try StoredRecord(batch, family: "batch").requiredValue("phase")),
                    "policy_revision": (try StoredRecord(batch, family: "batch").requiredValue("policy_revision")),
                    "file_scopes": (member["file_scopes"] as? [JSON] ?? []).map { $0.filter { ["path", "access", "declared_path"].contains($0.key) } },
                    "lane_scopes": member["lane_scopes"] ?? [],
                ]
            for key in ["review_request_id","target_manifest_id","gate"] { if let value = member[key] { input[key] = value } }
            var claim = try work(db,input,c,"work_claim",operation:.triage,batchContext:cohort)
            claim["batch_id"] = batch["id"];claim["key"] = member["key"] ?? (claim["task"] as? JSON)?["key"] ?? "";claim["title"] = member["title"] ?? (claim["task"] as? JSON)?["title"] ?? "";claims.append(claim)
        }
        }
        let receipt: JSON = [
            "id": uuid(), "project_id": pid, "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")),
            "batch_digest": (try StoredRecord(batch, family: "batch").requiredValue("digest")), "attempt_ids": claims.compactMap { $0["id"] as? String }, "principal": c.principal,
            "revision": 1, "created_at": now(),
        ]
        try save(db, receipt, type: "batch_claim");
        try event(
            db, caller: c, project: pid, entity: batch["triage_id"] as? String, kind: "batch_claimed",
            data: [
                "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "claim_id": (try StoredRecord(receipt, family: "receipt").requiredValue("id")),
                "attempt_ids": (try StoredRecord(receipt, family: "receipt").requiredValue("attempt_ids")),
            ])
        return [
            "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
            "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "digest": (try StoredRecord(batch, family: "batch").requiredValue("digest")),
            "claim_id": (try StoredRecord(receipt, family: "receipt").requiredValue("id")), "claims": claims, "triage_effect": "retained_by_batch_workflow",
        ]
    }

    /// The complete active frozen set continues atomically. A batch ID alone never retains an individual ticket.
    func batchWork(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch");try revision(p,batch)
        let action = method == "batch_submit" ? "work_submit" : "review_record"
        let requiredPhase = method == "batch_submit" ? "implementation" : "review"
        guard batch["phase"] as? String == requiredPhase,let inputs = p["members"] as? [JSON],!inputs.isEmpty,inputs.count <= 200 else { throw CoreError("INVALID_TRANSITION","Supply every active member of the matching frozen batch phase.") }
        let expectedIDs = Set(try records(db,type:"attempt",project:pid).filter {$0["state"] as? String == "active" && $0["batch_id"] as? String == batch["id"] as? String && $0["batch_digest"] as? String == batch["digest"] as? String && $0["phase"] as? String == requiredPhase}.compactMap {$0["task_id"] as? String})
        var attempts: [JSON] = []
        for input in inputs {
            let attempt = try claimAttempt(db,input,c,pid)
            guard attempt["batch_id"] as? String == batch["id"] as? String,attempt["batch_digest"] as? String == batch["digest"] as? String,attempt["phase"] as? String == requiredPhase else { throw CoreError("STALE_CLAIM","A member attempt is not an actual claim of this exact frozen batch and phase.") }
            attempts.append(attempt)
        }
        let actualIDs = attempts.compactMap {$0["task_id"] as? String}
        guard Set(actualIDs) == expectedIDs,actualIDs.count == expectedIDs.count else { throw CoreError("REVISION_CONFLICT","The group workflow requires the complete exact active batch set once each. No member changed.") }
        if method == "batch_submit" {
            for (input,attempt) in zip(inputs,attempts) {
                let task = try scoped(db, (try StoredRecord(attempt, family: "attempt").string("task_id")), pid, type: "task")
                _ = try normalizedAcceptanceEvidence(db,params:input,evidence:input["evidence_manifest"] as? JSON ?? [:],task:task,attempt:attempt,caller:c)
            }
        }
        var results: [JSON] = []
        for input in inputs {
            var memberInput = input;memberInput["project_id"] = pid
            // Reviewer-side blockers retain handling membership; implementation returns depart.
            let operation: TicketStatusOperation = method == "batch_review_record" && input["verdict"] as? String == "blocked" && input["blocked_on"] as? String != "implementation" ? .triage : .individual
            var result = try work(db,memberInput,c,action,operation:operation)
            let task = try scoped(db, try StoredAttemptRecord(attempts[results.count]).taskID, pid, type: "task")
            result["task_id"] = task["id"];result["key"] = task["key"];result["title"] = task["title"];results.append(result)
        }
        try event(
            db, caller: c, project: pid, entity: batch["triage_id"] as? String, kind: method == "batch_submit" ? "batch_submitted" : "batch_reviewed",
            data: ["batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "task_ids": actualIDs, "phase_completed": requiredPhase])
        return [
            "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
            "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "results": results, "phase_completed": requiredPhase,
        ]
    }

    /// Release a selected live subset atomically without ending its Triage handling membership.
    func batchRelease(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch")
        let reason = try text(p,"reason")
        guard let inputs = p["members"] as? [JSON],!inputs.isEmpty,inputs.count <= 200 else { throw CoreError("INVALID_INPUT","Select between 1 and 200 live batch claims to release.") }
        var attempts: [JSON] = []
        for input in inputs {
            let attempt = try claimAttempt(db,input,c,pid)
            guard attempt["batch_id"] as? String == batch["id"] as? String,attempt["batch_digest"] as? String == batch["digest"] as? String,attempt["phase"] as? String == batch["phase"] as? String else { throw CoreError("STALE_CLAIM","A member attempt is not a live claim of this exact frozen batch and phase.") }
            attempts.append(attempt)
        }
        let taskIDs = attempts.compactMap {$0["task_id"] as? String}
        guard Set(taskIDs).count == inputs.count else { throw CoreError("INVALID_INPUT","Select each live batch claim once.") }
        var results: [JSON] = []
        for input in inputs {
            var memberInput = input;memberInput["project_id"] = pid;memberInput["reason"] = reason;memberInput["final_report"] = p["final_report"]
            results.append(try work(db,memberInput,c,"work_release",operation:.triage))
        }
        try event(
            db, caller: c, project: pid, entity: batch["triage_id"] as? String, kind: "batch_released",
            data: ["batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "task_ids": taskIDs, "reason": reason])
        return [
            "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
            "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "released_task_ids": taskIDs, "results": results,
        ]
    }

    func redactBatchClaims(_ data: JSON) -> JSON {
        guard let claims = data["claims"] as? [JSON] else { return data }
        var result = data
        result["claims"] = claims.map {claim -> JSON in var claim = claim;claim.removeValue(forKey:"claim_token");return claim}
        return result
    }

    func replayBatchClaims(_ db: Database,_ data: JSON,_ c: Caller) throws -> JSON {
        var result = data
        result["claims"] = try (data["claims"] as? [JSON] ?? []).map {claim -> JSON in
            var claim = claim;claim.removeValue(forKey:"claim_token")
            guard let id = claim["id"] as? String, var attempt = try? record(db, id, type: "attempt"), attempt["state"] as? String == "active",
                attempt["principal"] as? String == c.principal, attempt["session_id"] as? String == (c.sessionID ?? "human"),
                attempt["execution_domain"] as? String == c.executionDomain,
                attempt["incarnation"] as? String == incarnation,
                attempt["session_authorization_generation"] as? String
                    == (try callerSessionGeneration(db, c, project: (try StoredRecord(attempt, family: "attempt").string("project_id"))))
            else { return claim }
            let token = uuid()+uuid();attempt["token_hash"] = hash(Data(token.utf8));try save(db,attempt,type:"attempt");claim["claim_token"] = token;return claim
        }
        return result
    }

    func batchMemberOutcome(_ db: Database,_ batch: JSON,_ member: JSON) throws -> JSON {
        let pid = (try StoredRecord(batch, family: "batch").string("project_id")), tid = (try StoredRecord(member, family: "member").string("task_id")),
            task = try scoped(db, tid, pid, type: "task")
        let attempt = try records(db,type:"attempt",project:pid).last {$0["batch_id"] as? String == batch["id"] as? String && $0["task_id"] as? String == tid}
        let completed = try taskProjection(db,task)["status_category"] as? String == "done"
        var outcome: JSON = [
            "task_id": tid, "task_revision": (try StoredRecord(task, family: "task").requiredValue("revision")), "key": task["key"] ?? tid, "title": task["title"] ?? "",
            "state": "unclaimed", "accepted": false, "completed": completed,
        ]
        guard let attempt = attempt else { return outcome }
        outcome["attempt_id"] = attempt["id"]
        if attempt["state"] as? String == "active" { outcome["state"] = "active";return outcome }
        let manifest: JSON?
        if batch["phase"] as? String == "review" {
            let manifestID = try StoredRecord(member, family: "batch_member").string("target_manifest_id")
            manifest = try? scoped(db,manifestID,pid,type:"manifest")
        }
        else { manifest = try records(db,type:"manifest",project:pid).last {$0["attempt_id"] as? String == attempt["id"] as? String} }
        guard let manifest = manifest else { outcome["state"] = "remaining";return outcome }
        let mid = (try StoredRecord(manifest, family: "manifest").string("id")); outcome["target_manifest_id"] = mid
        let requests = try records(db,type:"review_request",project:pid).filter {$0["task_id"] as? String == tid && $0["manifest_id"] as? String == mid}
        let gates = try manifestGates(db,manifest)
        if gates.contains(where: {gate in requests.last(where: {$0["gate"] as? String == gate})?["state"] as? String == "reject"}) { outcome["state"] = "failed";return outcome }
        // CL-41: a gate that waits for more evidence on the same target is neither failed nor accepted.
        if gates.contains(where: {gate in requests.last(where: {$0["gate"] as? String == gate})?["state"] as? String == "evidence_requested"}) { outcome["state"] = "evidence_requested";return outcome }
        do { _ = try validateManifestTarget(db,task:task,manifestID:mid) }
        catch { outcome["state"] = "stale";return outcome }
        for gate in gates {
            guard let request = requests.last(where: {$0["gate"] as? String == gate}),request["state"] as? String == "pass",let verdictID = request["latest_verdict_id"] as? String,let verdict = try? scoped(db,verdictID,pid,type:"review"),verdict["manifest_id"] as? String == mid,verdict["verdict"] as? String == "pass" else { outcome["state"] = "remaining";return outcome }
        }
        if try records(db,type:"finding",project:pid).contains(where: {$0["task_id"] as? String == tid && $0["state"] as? String == "open" && Self.findingBlocksCompletion($0)}) { outcome["state"] = "failed";return outcome }
        if let hold = task["release_hold"] as? JSON { outcome["release_hold"] = hold }
        outcome["accepted"] = true;outcome["acceptance_label"] = gates.isEmpty ? "No review required" : "All required reviews accepted"
        if try records(db,type:"finding_resolution",project:pid).contains(where: {$0["task_id"] as? String == tid && $0["disposition"] as? String == "waived"}) { outcome["acceptance_label"] = "Accepted with owner-waived findings" }
        outcome["completed"] = completed;outcome["state"] = completed ? "completed" : "accepted";return outcome
    }

    func batchProjection(_ db: Database,_ batch: JSON) throws -> JSON {
        var result = batch
        result["triage_key"] = batchTriageKey(db,batch) as Any? ?? NSNull()
        if let id = batch["triage_id"] as? String,let pid = batch["project_id"] as? String,let group = try? scoped(db,id,pid,type:"group") {
            result["triage_name"] = batch["triage_name"] ?? group["name"] ?? ""
        }
        result["members"] = (batch["members"] as? [JSON] ?? []).map { member -> JSON in
            var member = member
            if let id = member["task_id"] as? String,let pid = batch["project_id"] as? String,let task = try? scoped(db,id,pid,type:"task") {
                member["key"] = member["key"] ?? task["key"];member["title"] = member["title"] ?? task["title"]
            }
            return member
        }
        result["outcomes"] = try (batch["members"] as? [JSON] ?? []).map {try batchMemberOutcome(db,batch,$0)}
        result.merge(try batchLifecycle(db,batch)) { _,new in new }
        return result
    }

    /// Independent completion is explicitly distinct from the all-or-nothing current-membership status command.
    func batchCompletePassing(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch");try revision(p,batch)
        try requireBatchNotDiscarded(db,batch)
        let members = batch["members"] as? [JSON] ?? [],outcomes = try members.map {try batchMemberOutcome(db,batch,$0)}
        let policy = effectiveReviewBatchPolicy(batch["policy_snapshot"] as? JSON ?? [:])
        if policy == "hold_passing_for_batch", outcomes.contains(where: { !bool($0, "accepted") && !bool($0, "completed") }) {
            return [
                "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
                "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "policy": policy, "completed_task_ids": [],
                "held_task_ids": outcomes.filter { bool($0, "accepted") }.compactMap { $0["task_id"] as? String }, "reason": "project_override_holds_passing",
            ]
        }
        let candidates = outcomes.filter {bool($0,"accepted") && !bool($0,"completed")}
        let directionCursors = p["expected_direction_cursors"] as? [String:String] ?? [:]
        guard Set(directionCursors.keys) == Set(candidates.compactMap {$0["task_id"] as? String}) else { throw CoreError("DIRECTION_CURSOR_REQUIRED","Read current task context for each passing completion candidate and provide its observed direction cursor.") }
        var completed: [String] = [],blockers: [JSON] = []
        for outcome in candidates {
            do {
                try db.inSavepoint {
                    _ = try work(
                        db,
                        [
                            "project_id": pid, "task_id": (try StoredRecord(outcome, family: "outcome").requiredValue("task_id")),
                            "expected_revision": (try StoredRecord(outcome, family: "outcome").requiredValue("task_revision")),
                            "current_manifest_id": (try StoredRecord(outcome, family: "outcome").requiredValue("target_manifest_id")),
                            "direction_cursor": directionCursors[(try StoredRecord(outcome, family: "outcome").string("task_id"))]!,
                        ], c, "task_complete")
                    return .commit
                }
                completed.append((try StoredRecord(outcome, family: "outcome").string("task_id")))
            } catch let error as CoreError {
                blockers.append([
                    "task_id": (try StoredRecord(outcome, family: "outcome").requiredValue("task_id")), "key": outcome["key"] ?? "", "title": outcome["title"] ?? "",
                    "code": error.code,
                    "message": error.message,
                ])
            }
        }
        try event(
            db, caller: c, project: pid, entity: batch["triage_id"] as? String, kind: "batch_passing_completed",
            data: ["batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "completed_task_ids": completed, "blockers": blockers])
        return [
            "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
            "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "policy": policy, "completed_task_ids": completed, "blockers": blockers,
            "batch": try batchProjection(db, batch),
        ]
    }

    func batchRetriageRemaining(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch");try revision(p,batch)
        try requireBatchNotDiscarded(db,batch)
        let outcomes = try (batch["members"] as? [JSON] ?? []).map {try batchMemberOutcome(db,batch,$0)}
        // Passing tickets never receive implementation work just because another ticket failed, including under a hold override.
        let remaining = outcomes.filter {!bool($0,"accepted") && !bool($0,"completed")}
        guard !remaining.contains(where: {$0["state"] as? String == "active"}) else { throw CoreError("CLAIM_CONFLICT","Finish or safely release active batch work before preparing its next handling set.") }
        guard !remaining.isEmpty else {
            return [
                "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
                "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "triage": NSNull(), "task_ids": [], "reason": "no_remaining_tasks",
            ]
        }
        var groups: [JSON] = []
        for phase in AttemptPhase.wireValues {
            let phaseMembers = try remaining.filter { member in
                let task = try scoped(db, (try StoredRecord(member, family: "member").string("task_id")), pid, type: "task")
                let currentPhase = try taskProjection(db,task)["status_category"] as? String == "review" && task["current_manifest_id"] != nil ? "review" : "implementation"
                return currentPhase == phase
            }
            if phaseMembers.isEmpty { continue }
            var group = try groupWrite(db,["project_id":pid,"phase":phase,"name":p["name"] ?? (phase.capitalized + ": " + (batch["triage_name"] as? String ?? "Batch") + " · remaining"),"purpose":p["purpose"] ?? "Continue only failed or remaining tickets from the fixed batch."],c,"triage_create")
            for member in phaseMembers {
                group = try groupWrite(
                    db,
                    [
                        "project_id": pid, "group_id": (try StoredRecord(group, family: "group").requiredValue("id")),
                        "expected_revision": (try StoredRecord(group, family: "group").requiredValue("revision")),
                        "task_id": (try StoredRecord(member, family: "member").requiredValue("task_id")),
                        "expected_task_revision": (try StoredRecord(member, family: "member").requiredValue("task_revision")), "action": "add",
                    ], c, "group_membership")
            }
            try event(
                db, caller: c, project: pid, entity: group["id"] as? String, kind: "batch_remaining_retriaged",
                data: [
                    "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "phase": phase, "task_ids": phaseMembers.compactMap { $0["task_id"] as? String },
                ]);
            groups.append(group)
        }
        return [
            "triage_id": batch["triage_id"] ?? NSNull(), "triage_key": batchTriageKey(db, batch) as Any? ?? NSNull(), "triage_name": batch["triage_name"] ?? "",
            "batch_id": (try StoredRecord(batch, family: "batch").requiredValue("id")), "triage": groups.count == 1 ? groups[0] : NSNull(), "triages": groups,
            "task_ids": remaining.compactMap { $0["task_id"] as? String },
        ]
    }
}
