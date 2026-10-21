import Foundation
import GRDB

extension CommandRouter {
    private var contextRecordTypes: [String] { ["message","request","attachment","attempt","review_request","review","finding","finding_resolution","manifest","checkpoint","direction_disposition","source_capture","source_execution","batch"] }

    func contextRecord(_ source: JSON, type: String, caller: Caller) -> JSON {
        var value = source
        for key in ["token_hash","claim_token","incarnation"] { value.removeValue(forKey:key) }
        if !caller.isOwner { for key in ["path","execution_domain"] { value.removeValue(forKey:key) } }
        value["record_type"] = type
        // CL-47: an active claim shows its checkpoint health; a resource wait is never quiet.
        if type == "attempt", let health = Self.checkpointHealth(source) { value["checkpoint_health"] = health }
        return value
    }

    func contextPreview(_ source: JSON) -> JSON {
        var value = source
        for key in ["body","description","progress","final_report"] {
            if let full = value[key] as? String,full.count > 1200 { value[key] = String(full.prefix(1200)); value[key+"_truncated"] = true }
        }
        return value
    }

    func applicableDecisions(_ project: JSON, task: JSON) -> [JSON] {
        let pins = project["pinned_decisions"] as? [JSON] ?? strings(project,"pinned_decisions").enumerated().map { ["id":"legacy-\($0.offset)","body":$0.element,"revision":1,"origin":"legacy_project_context"] as JSON }
        return pins.filter { pin in
            let kinds = strings(pin,"task_kinds"), tags = strings(pin,"tag_ids")
            return (kinds.isEmpty || kinds.contains(task["kind"] as? String ?? "work")) && (tags.isEmpty || !Set(tags).isDisjoint(with:strings(task,"tag_ids")))
        }
    }

    func ownerDirections(_ db: Database, task: JSON) throws -> [JSON] {
        try scopedTaskRows(db,type:"message",task:task,predicate:"json_extract(data,'$.origin')='human_ui' AND json_extract(data,'$.requires_action')=1 AND \(Self.unretractedDirectionSQL())")
    }

    func directionCursorScope(_ db: Database, task: JSON, caller: Caller, attempt: JSON? = nil) throws -> String {
        let pid = task["project_id"] as! String, project = try record(db,pid,type:"project")
        let directions = try ownerDirections(db,task:task).map { ["id":$0["id"]!,"revision":int($0,"revision"),"addressed":bool($0,"addressed")] as JSON }
        let relevant: JSON = ["brief":project["brief"] ?? "","brief_revision":project["brief_revision"] ?? 0,"decisions":applicableDecisions(project,task:task),"directions":directions]
        let callerAttempt = try scopedTaskRows(db,type:"attempt",task:task,predicate:"json_extract(data,'$.state')='active' AND json_extract(data,'$.principal')=?",arguments:[caller.principal],limit:1,descending:true).first
        let round = attempt?["id"] as? String ?? callerAttempt?["id"] as? String ?? task["active_attempt_id"] as? String ?? task["current_manifest_id"] as? String ?? "unclaimed"
        return pid+":directions:"+(task["id"] as! String)+":"+round+":"+hash(Data((try jsonString(relevant)).utf8))+":"+(try authorizationScope(db,caller))+":"+(try callerSessionGeneration(db,caller,project:pid))
    }

    func validateDirectionCursor(_ db: Database, params: JSON, task: JSON, caller: Caller, attempt: JSON? = nil) throws {
        let directions = try ownerDirections(db,task:task)
        guard !directions.contains(where: {!bool($0,"addressed")}) else { throw CoreError("USER_DIRECTION_PENDING","An owner direction still needs a permitted response, checkpoint, evidence or explicit owner waiver.") }
        let project = try record(db,task["project_id"] as! String,type:"project")
        let hasContext = !(project["brief"] as? String ?? "").isEmpty || !applicableDecisions(project,task:task).isEmpty || !directions.isEmpty
        guard let supplied = params["direction_cursor"] as? String else {
            if hasContext { throw CoreError("DIRECTION_CURSOR_REQUIRED","Refresh task context and include its direction cursor before changing the work phase.") }
            return
        }
        _ = try cursorSequence(db,["cursor":supplied],caller:caller,scope:directionCursorScope(db,task:task,caller:caller,attempt:attempt))
    }

    func compactTaskContext(_ db: Database, task: JSON, caller: Caller) throws -> JSON {
        let pid = task["project_id"] as! String, tid = task["id"] as! String, project = try record(db,pid,type:"project")
        let savedNotesMore=try deliverSavedNotesToHandler(db,task:task,caller:caller)
        let directions = try scopedTaskRows(db,type:"message",task:task,predicate:"json_extract(data,'$.origin')='human_ui' AND json_extract(data,'$.requires_action')=1 AND COALESCE(json_extract(data,'$.addressed'),0)=0 AND \(Self.unretractedDirectionSQL())",limit:26)
        let findings = try scopedTaskRows(db,type:"finding",task:task,predicate:"json_extract(data,'$.state')='open'",limit:26)
        let requests = try scopedTaskRows(db,type:"request",task:task,predicate:"json_extract(data,'$.state')='pending'",limit:26)
        let reviews = try scopedTaskRows(db,type:"review_request",task:task,predicate:"json_extract(data,'$.state') IN ('queued','active','blocked','evidence_requested')",limit:26)
        let attempts = try scopedTaskRows(db,type:"attempt",task:task,limit:26,descending:true).reversed().map {$0}
        let active = try (task["active_attempt_id"] as? String).map {try scoped(db,$0,pid,type:"attempt")}
        let messages = chronologicalMessages(try scopedTaskRows(db,type:"message",task:task,limit:11,descending:true))
        let directionIDs = try jsonString(directions.compactMap {$0["id"] as? String})
        let deliveries = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='delivery' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.message_id') IN (SELECT value FROM json_each(?)) ORDER BY rowid DESC LIMIT 51",arguments:[Data(pid.utf8),directionIDs]).reversed().map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        let next: String
        if !directions.isEmpty { next = "address_owner_directions" }
        else if try scopedTaskCount(db,type:"request",task:task,predicate:"json_extract(data,'$.state')='pending' AND json_extract(data,'$.blocking')=1") > 0 { next = "await_human_answer" }
        else if let active { next = active["phase"] as? String == "review" ? "review_exact_target" : "continue_implementation" }
        else if findings.contains(where: Self.findingBlocksCompletion) { next = "fix_unresolved_findings" }
        else if reviews.contains(where: {$0["state"] as? String == "evidence_requested"}) { next = "supply_review_evidence" }
        else if !reviews.isEmpty { next = "claim_pending_review" }
        else if task["current_manifest_id"] != nil { next = "check_completion_gates" }
        else if task["readiness"] as? String != "ready" { next = "refine_draft" }
        else { next = try relationBlockers(db,task:task).isEmpty ? "claim_work" : "wait_for_prerequisites" }
        let source: JSON = ["project_revision":int(project,"revision"),"context_revision":int(project,"context_revision",default:1),"brief_revision":int(project,"brief_revision"),"decisions_revision":int(project,"decisions_revision"),"policy_revision":int(project,"policy_revision",default:1),"task_revision":int(task,"revision"),"acceptance_revision":int(task,"acceptance_revision",default:1),"manifest_id":task["current_manifest_id"] ?? NSNull(),"attempt_id":task["active_attempt_id"] ?? NSNull()]
        let limit = 25
        var result: JSON = ["context_version":1,"source_revisions":source,"next_action":next]
        result["saved_note_delivery_has_more"] = savedNotesMore
        result["task"] = try selectedTaskProjection(db,task:task)
        let common: JSON = ["id":pid,"name":project["name"] ?? "","brief":project["brief"] ?? "","brief_revision":int(project,"brief_revision"),"pinned_decisions":applicableDecisions(project,task:task),"decisions_revision":int(project,"decisions_revision"),"previous_context_revision_id":project["previous_context_revision_id"] ?? NSNull()]
        result["project"] = common
        result["review_requirements"] = try reviewRequirementState(db,task:task)
        // CL-43: failed rounds per gate and repeated-cause warnings; advice only.
        result["review_summary"] = try reviewSummary(db,task:task)
        result["evidence_measures"] = try evidenceMeasuresContext(db,task:task)
        result["direction_cursor"] = try cursor(db,caller:caller,scope:directionCursorScope(db,task:task,caller:caller))
        result["unresolved_directions"] = directions.prefix(limit).map(contextPreview)
        result["review_requests"] = Array(reviews.prefix(limit))
        result["recent_messages"] = messages.suffix(10).map(contextPreview)
        result["direction_deliveries"] = Array(deliveries.suffix(50))
        var counts:JSON=[:]
        counts["unresolved_directions"]=try scopedTaskCount(db,type:"message",task:task,predicate:"json_extract(data,'$.origin')='human_ui' AND json_extract(data,'$.requires_action')=1 AND COALESCE(json_extract(data,'$.addressed'),0)=0 AND \(Self.unretractedDirectionSQL())")
        counts["unresolved_findings"]=try scopedTaskCount(db,type:"finding",task:task,predicate:"json_extract(data,'$.state')='open'")
        counts["pending_requests"]=try scopedTaskCount(db,type:"request",task:task,predicate:"json_extract(data,'$.state')='pending'")
        counts["pending_reviews"]=try scopedTaskCount(db,type:"review_request",task:task,predicate:"json_extract(data,'$.state') IN ('queued','active','blocked','evidence_requested')")
        counts["blocking_findings"]=try scopedTaskCount(db,type:"finding",task:task,predicate:"json_extract(data,'$.state')='open' AND COALESCE(json_extract(data,'$.severity'),'')<>'advice'")
        counts["messages"]=try scopedTaskCount(db,type:"message",task:task)
        counts["attempts"]=try scopedTaskCount(db,type:"attempt",task:task)
        counts["direction_deliveries"]=try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records d JOIN records m ON m.type='message' AND m.project_id=d.project_id AND m.id=json_extract(d.data,'$.message_id') WHERE d.type='delivery' AND m.project_id=CAST(? AS TEXT) AND json_extract(m.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(m.data,'$.origin')='human_ui' AND json_extract(m.data,'$.requires_action')=1 AND COALESCE(json_extract(m.data,'$.addressed'),0)=0 AND \(Self.unretractedDirectionSQL("m"))",arguments:[Data(pid.utf8),Data(tid.utf8)]) ?? 0
        result["counts"]=counts
        let truncatedSections: [Bool] = [directions.count > limit,findings.count > limit,requests.count > limit,reviews.count > limit,messages.count > 10,deliveries.count > 50]
        result["truncated"] = truncatedSections.contains(true)
        result["history_ref"] = ["method":"history_list","project_id":pid,"task_id":tid]
        result["records_ref"] = ["method":"task_context","project_id":pid,"task_id":tid,"detail_level":"full"]
        result["epic"] = try scopedContextEpic(db,task:task)
        result["triages"] = try scopedTaskGroups(db,task:task).map {scopedContextGroup($0,task:task)}
        if let active { result["handler"] = contextRecord(active,type:"attempt",caller:caller) }
        else { result["handler"] = NSNull() }
        result["prior_handler"] = attempts.last(where: {$0["id"] as? String != task["active_attempt_id"] as? String}).map {contextRecord($0,type:"attempt",caller:caller)} ?? NSNull()
        result["handler_recipients"] = try relevantHandlerRecipients(db,task:task)
        result["relation_context"] = try scopedRelationContext(db,task:task)
        let batches = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='batch' AND project_id=CAST(? AS TEXT) AND EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.members')) WHERE json_extract(value,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY) ORDER BY rowid DESC LIMIT 11",arguments:[Data(pid.utf8),Data(tid.utf8)]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        result["batches"] = try batches.prefix(10).reversed().map {batch -> JSON in
            var reference:JSON=[:]
            for key in ["id","project_id","triage_id","triage_key","triage_name","phase","revision","created_at","digest"] {reference[key]=batch[key]}
            reference["triage_key"] = batchTriageKey(db,batch) as Any? ?? NSNull()
            let members=batch["members"] as? [JSON] ?? []
            reference["member_count"]=members.count;reference["members_complete"]=false;reference["outcomes_loaded"]=false
            reference["selected_members"]=members.filter {SnapshotRecordIdentity($0["task_id"] as? String ?? "")==SnapshotRecordIdentity(tid)}.map {member -> JSON in
                var selected:JSON=[:]
                for key in ["task_id","key","title","task_revision","review_request_id","review_request_revision","target_manifest_id","gate"] {selected[key]=member[key]}
                selected["key"] = member["key"] ?? task["key"];selected["title"] = member["title"] ?? task["title"]
                return selected
            }
            reference["snapshot_ref"]=["method":"batch_get","project_id":pid,"batch_id":batch["id"]!]
            return reference
        }
        result["batch_count"] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='batch' AND project_id=CAST(? AS TEXT) AND EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.members')) WHERE json_extract(value,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY)",arguments:[Data(pid.utf8),Data(tid.utf8)]) ?? 0
        result["batches_ref"] = ["method":"task_context","project_id":pid,"task_id":tid,"detail_level":"full"]
        if batches.count > 10 { result["truncated"] = true }
        result["task_sessions"] = try scopedTaskRows(db,type:"task_session",task:task,limit:25,descending:true).map {try taskSessionProjection(db,$0)}
        result["unresolved_findings"] = findings.prefix(limit).map(contextPreview)
        result["pending_requests"] = Array(requests.prefix(limit))
        // Compatibility sections are bounded; records_ref retrieves every omitted record.
        for (key,type) in [("findings","finding"),("finding_resolutions","finding_resolution"),("requests","request"),("reviews","review"),("attachments","attachment"),("attempts","attempt"),("manifests","manifest")] {
            let values = try scopedTaskRows(db,type:type,task:task,limit:limit+1,descending:true).reversed().map {$0}
            result[key] = values.suffix(limit).map {contextPreview(contextRecord($0,type:type,caller:caller))}
            if values.count > limit { result["truncated"] = true }
        }
        result["messages"] = result["recent_messages"]
        return result
    }

    func taskContext(_ db: Database,_ params: JSON,_ caller: Caller) throws -> JSON {
        if params["detail_level"] as? String == "ui" {return try selectedTicketRead(db,params,caller)}
        if params["detail_level"] as? String == "ui_records" {return try selectedTicketRecords(db,params,caller)}
        if params["detail_level"] as? String == "ui_history" {return try selectedTicketHistory(db,params,caller)}
        let pid = try scope(db,params,caller), task = try self.task(db,params,pid)
        let detail = params["detail_level"] as? String ?? "summary"
        guard ["summary","full"].contains(detail) else { throw CoreError("INVALID_INPUT","Choose summary or full task context.") }
        var result = try compactTaskContext(db,task:task,caller:caller)
        if let revisionID = params["context_revision_id"] as? String { result["historical_project_context"] = try scoped(db,revisionID,pid,type:"project_context_revision") }
        if detail == "full" || params["history_cursor"] != nil {
            let scope = pid+":context-records:"+(task["id"] as! String)+":"+(try authorizationScope(db,caller))+":"+(try callerSessionGeneration(db,caller,project:pid))
            var input: JSON = [:]; if let token = params["history_cursor"] { input["cursor"] = token }
            let after = try cursorSequence(db,input,caller:caller,scope:scope)
            let placeholders = contextRecordTypes.map {_ in "?"}.joined(separator:",")
            let values: [DatabaseValueConvertible] = [Data(pid.utf8),Data((task["id"] as! String).utf8),Data((task["id"] as! String).utf8),after] + contextRecordTypes.map {$0 as DatabaseValueConvertible}
            let rows = try Row.fetchAll(db,sql:"SELECT rowid AS position,"+Self.canonicalRecordColumns+" FROM records WHERE project_id=CAST(? AS TEXT) AND (json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY OR (type='batch' AND EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.members')) WHERE json_extract(value,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY))) AND rowid>? AND type IN ("+placeholders+") ORDER BY rowid LIMIT 51",arguments:StatementArguments(values))
            let page = Array(rows.prefix(50))
            result["records"] = try page.map {let envelope=try GRDBRecordEnvelopeAdapter.decode($0);return contextRecord(envelope.object,type:envelope.type,caller:caller)}
            result["has_more_records"] = rows.count > 50
            result["next_history_cursor"] = try cursor(db,caller:caller,scope:scope,sequence:page.last.map {$0["position"] as Int} ?? after)
        }
        return result
    }

    func recordDirectionCheckpoint(_ db: Database, params: JSON, attempt: JSON, progress: String, caller: Caller) throws -> JSON {
        let pid = attempt["project_id"] as! String, task = try scoped(db,attempt["task_id"] as! String,pid,type:"task")
        let ids = strings(params,"direction_ids")
        if !ids.isEmpty {
            guard let token = params["direction_cursor"] as? String else { throw CoreError("DIRECTION_CURSOR_REQUIRED","Read current directions before binding a checkpoint to them.") }
            _ = try cursorSequence(db,["cursor":token],caller:caller,scope:directionCursorScope(db,task:task,caller:caller,attempt:attempt))
            for id in ids { let message = try scoped(db,id,pid,type:"message"); guard message["task_id"] as? String == task["id"] as? String,bool(message,"requires_action"),message["origin"] as? String == "human_ui" else { throw CoreError("INVALID_INPUT","Checkpoints can address only actual owner directions on this ticket.") } }
        }
        let checkpoint: JSON = ["id":uuid(),"project_id":pid,"task_id":task["id"]!,"attempt_id":attempt["id"]!,"session_id":caller.sessionID ?? "human","principal":caller.principal,"progress":progress,"direction_ids":ids,"revision":1,"created_at":now()]
        try save(db,checkpoint,type:"checkpoint")
        try event(db,caller:caller,project:pid,entity:task["id"] as? String,kind:"checkpoint_recorded",data:["checkpoint_id":checkpoint["id"]!,"direction_ids":ids])
        return checkpoint
    }
}
