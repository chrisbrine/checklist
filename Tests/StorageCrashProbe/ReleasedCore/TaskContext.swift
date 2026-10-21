import Foundation
import GRDB

extension CommandRouter {
    private var contextRecordTypes: [String] { ["message","request","attachment","attempt","review_request","review","finding","finding_resolution","manifest","checkpoint","direction_disposition","source_capture","source_execution"] }

    func contextRecord(_ source: JSON, type: String, caller: Caller) -> JSON {
        var value = source
        for key in ["token_hash","claim_token","incarnation"] { value.removeValue(forKey:key) }
        if !caller.isOwner { for key in ["path","execution_domain"] { value.removeValue(forKey:key) } }
        value["record_type"] = type
        return value
    }

    func contextPreview(_ source: JSON) -> JSON {
        var value = source
        for key in ["body","description","progress"] {
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
        try records(db,type:"message",project:task["project_id"] as? String).filter { $0["task_id"] as? String == task["id"] as? String && $0["origin"] as? String == "human_ui" && bool($0,"requires_action") }
    }

    func directionCursorScope(_ db: Database, task: JSON, caller: Caller, attempt: JSON? = nil) throws -> String {
        let pid = task["project_id"] as! String, project = try record(db,pid,type:"project")
        let directions = try ownerDirections(db,task:task).map { ["id":$0["id"]!,"revision":int($0,"revision"),"addressed":bool($0,"addressed")] as JSON }
        let relevant: JSON = ["brief":project["brief"] ?? "","brief_revision":project["brief_revision"] ?? 0,"decisions":applicableDecisions(project,task:task),"directions":directions]
        let callerAttempt = try records(db,type:"attempt",project:pid).last {$0["task_id"] as? String == task["id"] as? String && $0["state"] as? String == "active" && $0["principal"] as? String == caller.principal}
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
        try deliverSavedNotesToHandler(db,task:task,caller:caller)
        let directions = try ownerDirections(db,task:task).filter {!bool($0,"addressed")}
        let findings = try records(db,type:"finding",project:pid).filter {$0["task_id"] as? String == tid && $0["state"] as? String == "open"}
        let requests = try records(db,type:"request",project:pid).filter {$0["task_id"] as? String == tid && $0["state"] as? String == "pending"}
        let reviews = try records(db,type:"review_request",project:pid).filter {$0["task_id"] as? String == tid && ["queued","active","blocked"].contains($0["state"] as? String ?? "")}
        let attempts = try records(db,type:"attempt",project:pid).filter {$0["task_id"] as? String == tid}
        let active = attempts.first {$0["id"] as? String == task["active_attempt_id"] as? String}
        let messages = chronologicalMessages(try records(db,type:"message",project:pid).filter {$0["task_id"] as? String == tid})
        let directionIDs = Set(directions.compactMap {$0["id"] as? String})
        let deliveries = try records(db,type:"delivery",project:pid).filter {directionIDs.contains($0["message_id"] as? String ?? "")}
        let next: String
        if !directions.isEmpty { next = "address_owner_directions" }
        else if requests.contains(where: {bool($0,"blocking")}) { next = "await_human_answer" }
        else if let active { next = active["phase"] as? String == "review" ? "review_exact_target" : "continue_implementation" }
        else if !findings.isEmpty { next = "fix_unresolved_findings" }
        else if !reviews.isEmpty { next = "claim_pending_review" }
        else if task["current_manifest_id"] != nil { next = "check_completion_gates" }
        else { next = task["readiness"] as? String == "ready" ? "claim_work" : "prepare_ready_task" }
        let source: JSON = ["project_revision":int(project,"revision"),"context_revision":int(project,"context_revision",default:1),"brief_revision":int(project,"brief_revision"),"decisions_revision":int(project,"decisions_revision"),"policy_revision":int(project,"policy_revision",default:1),"task_revision":int(task,"revision"),"acceptance_revision":int(task,"acceptance_revision",default:1),"manifest_id":task["current_manifest_id"] ?? NSNull(),"attempt_id":task["active_attempt_id"] ?? NSNull()]
        let limit = 25
        var result: JSON = ["context_version":1,"source_revisions":source,"next_action":next]
        result["task"] = try taskProjection(db,task)
        let common: JSON = ["id":pid,"name":project["name"] ?? "","brief":project["brief"] ?? "","brief_revision":int(project,"brief_revision"),"pinned_decisions":applicableDecisions(project,task:task),"decisions_revision":int(project,"decisions_revision"),"previous_context_revision_id":project["previous_context_revision_id"] ?? NSNull()]
        result["project"] = common
        result["review_requirements"] = try reviewRequirementState(db,task:task)
        result["direction_cursor"] = try cursor(db,caller:caller,scope:directionCursorScope(db,task:task,caller:caller))
        result["unresolved_directions"] = directions.prefix(limit).map(contextPreview)
        result["review_requests"] = Array(reviews.prefix(limit))
        result["recent_messages"] = messages.suffix(10).map(contextPreview)
        result["direction_deliveries"] = Array(deliveries.suffix(50))
        result["counts"] = ["unresolved_directions":directions.count,"unresolved_findings":findings.count,"pending_requests":requests.count,"pending_reviews":reviews.count,"messages":messages.count,"attempts":attempts.count,"direction_deliveries":deliveries.count]
        let truncatedSections: [Bool] = [directions.count > limit,findings.count > limit,requests.count > limit,reviews.count > limit,messages.count > 10,deliveries.count > 50]
        result["truncated"] = truncatedSections.contains(true)
        result["history_ref"] = ["method":"history_list","project_id":pid,"task_id":tid]
        result["records_ref"] = ["method":"task_context","project_id":pid,"task_id":tid,"detail_level":"full"]
        result["epic"] = try taskEpicContext(db,task)
        result["triages"] = try taskTriages(db,task)
        if let active { result["handler"] = contextRecord(active,type:"attempt",caller:caller) }
        else { result["handler"] = NSNull() }
        result["prior_handler"] = attempts.last(where: {$0["id"] as? String != task["active_attempt_id"] as? String}).map {contextRecord($0,type:"attempt",caller:caller)} ?? NSNull()
        result["handler_recipients"] = try relevantHandlerRecipients(db,task:task)
        result["relation_context"] = try relationContext(db,task:task)
        let batches = try records(db,type:"batch",project:pid).filter {($0["members"] as? [JSON] ?? []).contains {$0["task_id"] as? String == tid}}
        result["batches"] = try batches.suffix(10).map {try batchProjection(db,$0)}
        result["batch_count"] = batches.count
        result["batches_ref"] = ["method":"batch_list","project_id":pid]
        if batches.count > 10 { result["truncated"] = true }
        result["task_sessions"] = try records(db,type:"task_session",project:pid).filter {$0["task_id"] as? String == tid}.suffix(25).map {try taskSessionProjection(db,$0)}
        result["unresolved_findings"] = findings.prefix(limit).map(contextPreview)
        result["pending_requests"] = Array(requests.prefix(limit))
        // Compatibility sections are bounded; records_ref retrieves every omitted record.
        for (key,type) in [("findings","finding"),("finding_resolutions","finding_resolution"),("requests","request"),("reviews","review"),("attachments","attachment"),("attempts","attempt"),("manifests","manifest")] {
            let values = try records(db,type:type,project:pid).filter {$0["task_id"] as? String == tid}
            result[key] = values.suffix(limit).map {contextPreview(contextRecord($0,type:type,caller:caller))}
            if values.count > limit { result["truncated"] = true }
        }
        result["messages"] = result["recent_messages"]
        return result
    }

    func taskContext(_ db: Database,_ params: JSON,_ caller: Caller) throws -> JSON {
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
            let values: [DatabaseValueConvertible] = [pid,task["id"] as! String,after] + contextRecordTypes.map {$0 as DatabaseValueConvertible}
            let rows = try Row.fetchAll(db,sql:"SELECT rowid AS position,type,data FROM records WHERE project_id=? AND json_extract(data,'$.task_id')=? AND rowid>? AND type IN ("+placeholders+") ORDER BY rowid LIMIT 51",arguments:StatementArguments(values))
            let page = Array(rows.prefix(50))
            result["records"] = page.map {contextRecord(jsonObject($0["data"]),type:$0["type"],caller:caller)}
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
