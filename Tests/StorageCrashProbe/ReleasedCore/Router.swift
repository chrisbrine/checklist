import Foundation
import GRDB

extension CommandRouter {
    func dispatch(_ db: Database, method: String, p: JSON, c: Caller) throws -> JSON {
        switch method {
        case "service_info": return ["session_id":c.sessionID ?? "","caller":["session_id":c.sessionID ?? "","role":c.role,"installation":c.installation],"name":"Checklist","version":"0.1.0","store_incarnation":incarnation,"role":c.role,"project_ids":c.projectIDs,"capabilities":["durable_store","project_isolation","pickup_inbox","named_contacts","human_requests","managed_attachments","scope_reservations","captured_source_review","triage_batches","phase_triages","triage_orchestration","typed_relations","policy_reconciliation","request_revisions"],"native_push":false,"native_push_status":"Pickup via authenticated MCP is available. Native idle-client push is not qualified.","unsupported":["automatic_model_launch","native_idle_push","restore","MCP_events"]]
        case "tool_catalog": return ["tools":toolCatalog(c)]
        case "changes_wait":
            let scope = try authorizationScope(db,c)
            let old = try cursorSequence(db,p,caller:c,scope:scope)
            let latest: Int
            if c.isOwner { latest = try Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events") ?? 0 }
            else if c.projectIDs.isEmpty { latest = 0 }
            else { latest = try Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events WHERE project_id IN (" + c.projectIDs.map {_ in "?"}.joined(separator:",") + ")",arguments:StatementArguments(c.projectIDs)) ?? 0 }
            return ["changed":old != latest,"event_cursor":old == latest ? (p["cursor"] as? String ?? "") : try cursor(db,caller:c,scope:scope)]
        case "delivery_pending", "delivery_record", "native_reply_record": return try bridge(db,p,c,method)
        case "delivery_host_status": return try deliveryHostStatus(db,p,c)
        case "snapshot": try owner(c); return try snapshot(db,c:c)
        case "diagnostics_summary": return try diagnosticsSummary(db,c)
        case "storage_status": try owner(c); return ["database_path":root.appendingPathComponent("checklist.sqlite").path,"managed_bytes":try records(db,type:"attachment").filter {$0["mode"] as? String == "managed" && $0["availability"] as? String == "available"}.reduce(0) {$0+int($1,"size")},"cleanup_enabled":true,"restore_supported":false]
        case "project_list", "assistant_projects": return ["projects":try projects(db,c)]
        case "project_resolve":
            let path = canonical(try text(p,"workspace_path")); let available = try projects(db,c)
            let matches = available.filter { if let root = $0["root_path"] as? String, !root.isEmpty { return containsPath(root,path) }; return false }
            guard c.isOwner || c.workspace.map({ canonical($0) == path }) == true else { throw CoreError("ROOT_MISMATCH","The requested path is not the connection's actual workspace.") }
            return ["state":matches.count == 1 ? "registered" : (matches.isEmpty ? "unregistered" : "ambiguous"),"projects":matches]
        case "project_icon_import", "project_icon_clear": return try projectIcon(db,p,c,method)
        case "project_create": return try projectCreate(db,p,c)
        case "project_settings_save": return try projectSettingsSave(db,p,c)
        case "project_edit", "project_archive": return try projectEdit(db,p,c,method)
        case "project_settings_get", "policy_get", "taxonomy_get":
            let pid = try scope(db,p,c); let project = try record(db,pid,type:"project")
            if method == "policy_get",p["revision"] != nil { return ["policy":try policyAtRevision(db,projectID:pid,revision:int(p,"revision")),"revision":int(p,"revision")] }
            if method == "taxonomy_get" {
                if p["revision"] != nil,int(p,"revision") != int(project,"taxonomy_revision",default:1) {
                    guard let snapshot = try records(db,type:"taxonomy_revision",project:pid).first(where:{int($0,"taxonomy_revision") == int(p,"revision")}) else { throw CoreError("NOT_FOUND","This taxonomy revision is unavailable.") };return snapshot
                }
                return ["revision":project["taxonomy_revision"] ?? 1,"statuses":try records(db,type:"status",project:pid),"tags":try records(db,type:"tag",project:pid)]
            }
            if method == "policy_get" {
                let kind = p["task_id"] != nil ? try task(db,p,pid)["kind"] as? String ?? "work" : ""
                return ["policy":effectivePolicy(project["policy"] as? JSON ?? [:],kind:kind),"revision":project["policy_revision"] ?? 1]
            }
            return projectProjection(project,caller:c)
        case "policy_preview", "policy_propose", "policy_apply", "policy_acknowledge": return try policyCommand(db,p,c,method)
        case "status_create", "status_edit", "tag_create", "tag_edit", "status_retire", "tag_retire": return try taxonomyWrite(db,p,c,method)
        case "task_create": return try taskCreate(db,p,c)
        case "task_edit": return try taskEdit(db,p,c)
        case "task_get", "task_context":
            let completionRequested = method == "task_get" ? try ownerCompletionEligibilityRequested(p,caller:c) : false
            let pid = try scope(db,p,c); let t = try task(db,p,pid)
            if method == "task_get" {
                var projected = try taskProjection(db,t)
                if completionRequested { projected["completion_eligibility"] = try completionPreview(db,task:t,caller:c) }
                return projected
            }
            return try taskContext(db,p,c)
        case "task_list":
            let pid = try scope(db,p,c); var tasks = try records(db,type:"task",project:pid)
            tasks = tasks.filter { bool($0,"archived") == bool(p,"archived") && !bool($0,"trashed") }
            if let query = p["text"] as? String, !query.isEmpty { tasks = tasks.filter { (($0["title"] as? String ?? "") + " " + ($0["brief"] as? String ?? "") + " " + ($0["key"] as? String ?? "")).localizedCaseInsensitiveContains(query) } }
            if !strings(p,"status_ids").isEmpty { tasks = tasks.filter { strings(p,"status_ids").contains($0["status_id"] as? String ?? "") } }
            return ["tasks":try tasks.prefix(min(max(int(p,"limit",default:200),1),200)).map { try taskProjection(db,$0) },"total":tasks.count]
        case "task_transition": return try taskTransition(db,p,c)
        case "review_prepare": return try prepareAgentReview(db,p,c)
        case "review_context": return try agentReviewContext(db,p,c)
        case "review_evidence_add": return try addAgentReviewEvidence(db,p,c)
        case "source_execution_get": return try sourceExecutionGet(db,p,c)
        case "batch_prepare": return try batchPrepare(db,p,c)
        case "batch_claim": return try batchClaim(db,p,c)
        case "batch_get", "batch_list": return try batchRead(db,p,c,method)
        case "batch_submit", "batch_review_record": return try batchWork(db,p,c,method)
        case "batch_complete_passing": return try batchCompletePassing(db,p,c)
        case "batch_retriage_remaining": return try batchRetriageRemaining(db,p,c)
        case "triage_orchestrate": return try triageOrchestrate(db,p,c)
        case "triage_transition": return try triageTransition(db,p,c)
        case "task_archive": return try taskArchive(db,p,c)
        case "session_register", "session_update": return try sessionWrite(db,p,c,method)
        case "session_attach_task": return try attachSessionToTask(db,p,c)
        case "session_list": return try taskSessionList(db,p,c)
        case "review_request": return try reviewRequest(db,p,c)
        case "finding_waive": return try findingWaive(db,p,c)
        case "work_scope_adjust", "work_delegate", "work_child_accept", "work_handoff_offer", "work_handoff_accept": return try workAuthority(db,p,c,method)
        case "source_review_execute": return try sourceReviewExecute(db,p,c)
        case "task_link": return try taskLink(db,p,c)
        case "relation_list": return try relationRead(db,p,c)
        case "relation_import": return try relationImport(db,p,c)
        case "work_claim", "work_checkpoint", "work_release", "work_submit", "review_record", "task_complete", "work_recover": return try work(db,p,c,method)
        case "direction_waive": return try directionWaive(db,p,c)
        case "message_send", "agent_message_send", "message_ack": return try messageWrite(db,p,c,method)
        case "session_inbox", "assistant_inbox": return try inbox(db,p,c)
        case "history_list": return try history(db,p,c)
        case "profile_create", "profile_edit", "profile_archive": return try profileWrite(db,p,c,method)
        case "agent_resolve": return try resolve(db,p,c)
        case "human_request_create", "human_request_answer", "human_request_cancel", "human_request_revise", "human_request_snooze": return try requestWrite(db,p,c,method)
        case "epic_create", "triage_create", "epic_edit", "triage_edit", "group_edit", "group_membership": return try groupWrite(db,p,c,method)
        case "epic_list", "triage_list": let pid = try scope(db,p,c); return ["groups":try records(db,type:"group",project:pid).filter { ($0["kind"] as? String) == (method == "epic_list" ? "epic" : "triage") }.map {try groupProjection(db,$0)}]
        case "attachment_read_release": return try releaseAttachmentRead(db,p,c)
        case "attachment_add", "attachment_update": return try attachmentWrite(db,p,c,method)
        case "attachment_list", "attachment_read", "attachment_cleanup_preview": return try attachmentRead(db,p,c,method)
        case "export_project": return try exportProject(db,p,c)
        case "backup_create": return try backup(db,p,c)
        default: throw CoreError("UNSUPPORTED_METHOD","\(method) is not implemented in this build. No action was performed.")
        }
    }
    func projects(_ db: Database, _ c: Caller) throws -> [JSON] { try records(db,type:"project").filter { c.isOwner || (c.projectIDs.contains($0["id"] as? String ?? "") && (c.role != "assistant" || c.assistantGrants[$0["id"] as? String ?? ""]?["read"] == true)) }.map {projectProjection($0,caller:c)} }
    func snapshot(_ db: Database,c: Caller) throws -> JSON {
        var result: JSON = [:]
        let taskRows = try records(db,type:"task")
        let projection = try SnapshotReadProjection(router:self,database:db,tasks:taskRows)
        var pp = try projects(db,c)
        for i in pp.indices {
            let id = pp[i]["id"] as! String
            pp[i]["statuses"] = (projection.collections["status"] ?? []).filter { row in guard let pid = row["project_id"] as? String else { return false }; return SnapshotRecordIdentity(pid) == SnapshotRecordIdentity(id) }
            pp[i]["tags"] = (projection.collections["tag"] ?? []).filter { row in guard let pid = row["project_id"] as? String else { return false }; return SnapshotRecordIdentity(pid) == SnapshotRecordIdentity(id) }
        }
        result["projects"] = pp
        result["tasks"] = try taskRows.map {try projection.project(self,task:$0)}
        for (name,type) in [("statuses","status"),("tags","tag"),("profiles","profile"),("sessions","session"),("requests","request"),("groups","group"),("attachments","attachment"),("attempts","attempt"),("reviews","review"),("findings","finding"),("finding_resolutions","finding_resolution"),("review_requests","review_request"),("manifests","manifest"),("relations","relation"),("task_aliases","task_alias"),("source_executions","source_execution"),("batches","batch")] { result[name] = try (projection.collections[type] ?? records(db,type:type)).map { row -> JSON in var row = row; row.removeValue(forKey:"token_hash"); row.removeValue(forKey:"incarnation"); return row } }
        result["task_sessions"] = try records(db,type:"task_session").map {try taskSessionProjection(db,$0)}
        result["connections"] = result["sessions"]
        let groups = try (result["groups"] as? [JSON] ?? []).map {try groupProjection(db,$0)};result["groups"] = groups
        result["triages"] = groups.filter { $0["kind"] as? String == "triage" }; result["epics"] = groups.filter { $0["kind"] as? String == "epic" }
        result["messages"] = try SnapshotMessageProjection.hydrate(records(db,type:"message"), loadDeliveries: { try records(db,type:"delivery") })
        result["events"] = try Row.fetchAll(db,sql:"SELECT id,project_id,entity_id,actor,kind,occurred_at,data FROM events ORDER BY seq DESC LIMIT 200").map { row -> JSON in ["id":row["id"] as String,"project_id":row["project_id"] as String? ?? "","entity_id":row["entity_id"] as String? ?? "","actor":row["actor"] as String,"kind":row["kind"] as String,"occurred_at":row["occurred_at"] as String,"data":jsonObject(row["data"])] }
        result["service"] = try dispatch(db,method:"service_info",p:[:],c:c)
        return result
    }
    func taskProjection(_ db: Database,_ task: JSON) throws -> JSON {
        let status = try? record(db,task["status_id"] as? String ?? "",type:"status")
        let tags = try records(db,type:"tag",project:task["project_id"] as? String).filter {strings(task,"tag_ids").contains($0["id"] as? String ?? "")}
        return assembledTaskProjection(task,status:status,activeAttention:try taskActiveAttention(db,task),tags:tags,relation:try relationTaskProjection(db,task:task))
    }
    func assembledTaskProjection(_ task: JSON, status: JSON?, activeAttention: Bool, tags: [JSON], relation: JSON) -> JSON {
        var t = task
        if let status {t["status_name"] = status["name"];t["status_category"] = status["category"];t["status"] = status["name"]}
        t["active_attention"] = activeAttention;t["body"] = t["brief"];t["assignee"] = t["planned_assignee"];t["tags"] = tags
        for (key,value) in relation {t[key] = value}
        return t
    }

    func projectCreate(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c)
        let name = try text(p,"name",max:200); let prefix = (p["key_prefix"] as? String ?? "TASK").uppercased()
        guard prefix.range(of:"^[A-Z][A-Z0-9]{0,11}$",options:.regularExpression) != nil else { throw CoreError("INVALID_INPUT","Use a short letter/number ticket prefix.") }
        let path = (p["root_path"] as? String).map(canonical) ?? ""
        if !path.isEmpty {
            var isDirectory: ObjCBool = false; guard FileManager.default.fileExists(atPath:path,isDirectory:&isDirectory), isDirectory.boolValue else { throw CoreError("FILE_ACCESS_REQUIRED","Choose an existing project directory.") }
            for project in try records(db,type:"project") { if let old = project["root_path"] as? String,!old.isEmpty,(containsPath(old,path) || containsPath(path,old)) { throw CoreError("ROOT_OVERLAP","This directory overlaps an enrolled writable project.") } }
        }
        let id = uuid(); let time = now()
        let value: JSON = ["id":id,"project_id":id,"name":name,"key_prefix":prefix,"root_path":path,"icon":p["icon"] ?? "checklist","accent":p["accent"] ?? "blue","revision":1,"policy_revision":1,"policy":try normalizedPolicy([:]),"settings_revision":1,"context_revision":1,"taxonomy_revision":1,"capture_defaults":defaultCaptureSettings(),"default_view":["group_by":"status","order_by":"manual"],"alert_override":"inherit","next_number":1,"archived":false,"created_at":time,"updated_at":time]
        try save(db,value,type:"project"); _ = try retainPolicy(db,project:value)
        for (index,item) in [("Queued","queued","gray"),("In progress","active","blue"),("Review","review","purple"),("Blocked","blocked","orange"),("Parked","parked","gray"),("Done","done","green"),("Canceled","canceled","gray")].enumerated() {
            try save(db,["id":uuid(),"project_id":id,"name":item.0,"category":item.1,"color":item.2,"sort_order":index,"revision":1,"retired":false],type:"status")
        }
        try event(db,caller:c,project:id,entity:id,kind:"project_created",data:["name":name]); return value
    }
    func projectEdit(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c); var r = try record(db,pid,type:"project"); try revision(p,r); let previous = r
        try validateProjectSettingsPatch(p,project:&r)
        if let new = p["root_path"] as? String {
            let path = canonical(new); var dir: ObjCBool = false; guard FileManager.default.fileExists(atPath:path,isDirectory:&dir),dir.boolValue else { throw CoreError("FILE_ACCESS_REQUIRED","Choose an existing directory.") }
            for project in try records(db,type:"project") where project["id"] as? String != pid { if let old = project["root_path"] as? String,!old.isEmpty,(containsPath(old,path)||containsPath(path,old)) { throw CoreError("ROOT_OVERLAP","The writable project root overlaps another project.") } }
            r["root_path"] = path
        }
        if method == "project_archive" { r["archived"] = bool(p,"archived",default:true) }
        r = try prepareProjectContextChange(db,old:previous,updated:r,caller:c); r = revised(r); try save(db,r,type:"project"); try propagateProjectContextChange(db,old:previous,updated:r,caller:c); try event(db,caller:c,project:pid,entity:pid,kind:"project_updated"); return r
    }
    func taxonomyWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c,write:true); let type = method.hasPrefix("status") ? "status" : "tag"; var r: JSON
        if method.hasSuffix("create") { r = ["id":uuid(),"project_id":pid,"revision":1,"retired":false,"sort_order":int(p,"sort_order")] }
        else { r = try scoped(db,try text(p,type+"_id"),pid,type:type); try revision(p,r); r = revised(r) }
        if method.hasSuffix("retire") {
            if type == "status",let replacementID = p["remap_target_status_id"] as? String {
                let target = try scoped(db,replacementID,pid,type:"status")
                guard target["id"] as? String != r["id"] as? String,!bool(target,"retired"),target["category"] as? String == r["category"] as? String else { throw CoreError("INVALID_TRANSITION","Retirement requires a current replacement with the same behavior.") }
                let affected = try records(db,type:"task",project:pid).filter {$0["status_id"] as? String == r["id"] as? String}
                let revisions = p["expected_task_revisions"] as? JSON ?? [:]
                guard Set(revisions.keys) == Set(affected.compactMap {$0["id"] as? String}) else { throw CoreError("REVISION_CONFLICT","Preview every affected ticket revision before retiring and remapping a status.") }
                for var task in affected {
                    try revision(["expected_revision":revisions[task["id"] as! String] ?? NSNull()],task)
                    guard task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","A status retirement cannot move active work.") }
                    task["status_id"] = target["id"]; task = revised(task); try save(db,task,type:"task")
                    try recordTicketStatusAction(db,task:task,caller:c)
                    try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"status_remapped",data:["from_status_id":r["id"]!,"to_status_id":target["id"]!])
                }
            }
            if type == "status",["queued","active","review","blocked","done"].contains(r["category"] as? String ?? ""),try records(db,type:"status",project:pid).filter({$0["category"] as? String == r["category"] as? String && !bool($0,"retired")}).count <= 1 { throw CoreError("STATUS_REQUIRED","Keep at least one status for this protected behavior.") }
            if type == "status",try records(db,type:"task",project:pid).contains(where: {$0["status_id"] as? String == r["id"] as? String}) { throw CoreError("STATUS_IN_USE","Move the affected tasks before retiring this status.") }
            r["retired"] = true
        } else {
            if p["name"] != nil || method.hasSuffix("create") { r["name"] = try text(p,"name",max:100) }; if let color = p["color"] { r["color"] = color }; if r["color"] == nil { r["color"] = "gray" }; if let order = p["sort_order"] { r["sort_order"] = order }
            if type == "status" { let category = p["category"] as? String ?? r["category"] as? String ?? "parked"; guard ["queued","active","review","blocked","parked","done","canceled"].contains(category) else { throw CoreError("INVALID_INPUT","Choose a supported status behavior.") }; if r["category"] != nil && r["category"] as? String != category { throw CoreError("POLICY_DENIED","Create a new behavior and move tasks explicitly.") }; r["category"] = category }
        }
        try save(db,r,type:type)
        var project = try record(db,pid,type:"project");project["taxonomy_revision"] = int(project,"taxonomy_revision",default:1)+1;project = revised(project);try save(db,project,type:"project")
        let snapshot: JSON = ["id":uuid(),"project_id":pid,"taxonomy_revision":project["taxonomy_revision"]!,"statuses":try records(db,type:"status",project:pid),"tags":try records(db,type:"tag",project:pid),"revision":1,"created_at":now()];try save(db,snapshot,type:"taxonomy_revision")
        try event(db,caller:c,project:pid,entity:r["id"] as? String,kind:type+"_updated"); return r
    }
    func taskCreate(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c,write:true); var project = try record(db,pid,type:"project")
        if c.role == "assistant",p["planned_assignee"] != nil || p["key"] != nil || p["epic_id"] != nil { throw CoreError("FORBIDDEN","Assistants capture Drafts without work assignment.") }
        try assistantPermission(c,pid,"create_drafts_on_request")
        let title = try text(p,"title",max:2000); let kind = p["kind"] as? String ?? "work"
        guard ["work","bug","asset","playtest","question"].contains(kind) else { throw CoreError("INVALID_INPUT","Unsupported task kind.") }
        let status = try self.status(db,pid,"queued")
        let number = int(project,"next_number",default:1); let key = p["key"] as? String ?? "\(project["key_prefix"] as? String ?? "TASK")-\(number)"
        guard !(try records(db,type:"task",project:pid).contains { $0["key"] as? String == key }) else { throw CoreError("KEY_CONFLICT","This ticket key is already in this project.") }
        let time = now(); var task: JSON = ["id":uuid(),"project_id":pid,"key":key,"title":title,"brief":try text(p,"brief",required:false),"acceptance":p["acceptance"] ?? [],"acceptance_revision":1,"kind":kind,"readiness":"draft","status_id":status["id"]!,"priority":p["priority"] ?? "normal","tag_ids":strings(p,"tag_ids"),"revision":1,"archived":false,"trashed":false,"created_at":time,"updated_at":time]
        if let assignment = p["planned_assignee"] { try validateAssignment(assignment); task["planned_assignee"] = assignment }
        if let epic = p["epic_id"] as? String { let group = try scoped(db,epic,pid,type:"group");guard group["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","Only an Epic can be a persistent subproject.") };task["epic_id"] = epic }
        for tag in strings(task,"tag_ids") { _ = try scoped(db,tag,pid,type:"tag") }
        try validateTaskPolicyAssignment(db,project:project,task:&task,input:p,caller:c)
        task["created_by"] = c.principal; task["origin"] = c.isOwner ? "human_ui" : c.role
        project["next_number"] = number+1; try save(db,project,type:"project"); try save(db,task,type:"task");if let epic = task["epic_id"] as? String { _ = try syncEpic(db,try scoped(db,epic,pid,type:"group")) }; try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"task_created",data:["key":key]); return try taskProjection(db,task)
    }
    func validateAssignment(_ a: Any) throws {
        if let s = a as? String { guard ["human","unassigned"].contains(s) else { throw CoreError("INVALID_INPUT","Choose human or an eligible worker connection.") }; return }
        guard let a = a as? JSON,let kind = a["kind"] as? String,["human","agent","unassigned"].contains(kind),a["access_mode"] as? String != "observer_messenger" else { throw CoreError("FORBIDDEN","Assistant profiles cannot be work assignees.") }
    }
    func taskEdit(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db,p,c,write:true); var r = try task(db,p,pid); try revision(p,r)
        let patch = p["patch"] as? JSON ?? p
        let choices = ["kind":["work","bug","asset","playtest","question"],"readiness":["draft","ready"],"priority":["urgent","high","normal","low","none"]]
        for (field,allowed) in choices where patch[field] != nil {
            guard let value = patch[field] as? String,allowed.contains(value) else { throw CoreError("INVALID_INPUT","Unsupported ticket \(field).") }
        }
        if let kind = patch["kind"] as? String,kind != r["kind"] as? String,r["active_attempt_id"] != nil || r["active_verification_request_id"] != nil {
            throw CoreError("CLAIM_CONFLICT","Release the active work before changing the ticket kind.")
        }
        for key in ["title","brief","kind","priority","order","planned_assignee","assignment_reason","epic_id","tag_ids","acceptance","readiness"] {
            guard let value = patch[key] else { continue }
            if key == "planned_assignee" { try validateAssignment(value); if let a = value as? JSON,let sid = a["session_id"] as? String { let s = try scoped(db,sid,pid,type:"session"); guard s["role"] as? String != "assistant" else { throw CoreError("FORBIDDEN","An assistant cannot be assigned work.") } } }
            if key == "title" { _ = try text(patch,key,max:2000) }
            if key == "brief" { _ = try text(patch,key,required:false) }
            if key == "tag_ids" { for id in strings(patch,key) { _ = try scoped(db,id,pid,type:"tag") } }
            if key == "epic_id" { try editTaskEpic(db,task:&r,value:value);continue }
            if ["acceptance","brief"].contains(key) { r["acceptance_revision"] = int(r,"acceptance_revision",default:1)+1; r.removeValue(forKey:"current_manifest_id") }
            r[key] = value
        }
        if r["readiness"] as? String == "ready" { guard !(r["brief"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CoreError("NOT_READY","Add the intended outcome before making this task Ready.") } }
        let project = try record(db,pid,type:"project")
        try validateTaskPolicyAssignment(db,project:project,task:&r,input:patch,caller:c)
        if patch["readiness"] as? String == "ready" { try requirePrerequisitesSatisfied(db,task:r) }
        r = revised(r); try save(db,r,type:"task"); try event(db,caller:c,project:pid,entity:r["id"] as? String,kind:"task_edited"); return try taskProjection(db,r)
    }
    func status(_ db: Database,_ pid: String,_ category: String) throws -> JSON { guard let s = try records(db,type:"status",project:pid).first(where: {$0["category"] as? String == category && !bool($0,"retired")}) else { throw CoreError("INVALID_TRANSITION","This project has no available \(category) status.") }; return s }
    func taskTransition(_ db: Database,_ p: JSON,_ c: Caller,operation: TicketStatusOperation = .individual) throws -> JSON {
        try worker(c); let pid = try scope(db,p,c,write:true); var r = try task(db,p,pid); try revision(p,r)
        let target: JSON
        if let sid = p["target_status_id"] as? String ?? p["status_id"] as? String { target = try scoped(db,sid,pid,type:"status") }
        else { let action = p["action"] as? String ?? "queue"; let map = ["queue":"queued","reopen":"queued","defer":"parked","block":"blocked","cancel":"canceled"]; guard let category = map[action] else { throw CoreError("INVALID_TRANSITION","Use claim, submit and completion handlers for protected work states.") }; target = try status(db,pid,category) }
        guard !bool(target,"retired"),!["active","review","done"].contains(target["category"] as? String ?? "") else { throw CoreError("INVALID_TRANSITION","This status requires a real work claim, review submission or completion gate.") }
        guard r["active_attempt_id"] == nil,r["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","Release or recover the active session before changing this state.") }
        if p["action"] as? String == "reopen" { try reopenRelationDisposition(db,task:&r,caller:c) }
        if target["category"] as? String == "queued" { try requireQueueEligibility(db,task:r) }
        r["status_id"] = target["id"]; r = revised(r); try save(db,r,type:"task"); try recordTicketStatusAction(db,task:r,caller:c,operation:operation); try event(db,caller:c,project:pid,entity:r["id"] as? String,kind:"task_transitioned",data:["status":target["name"]!]); return try taskProjection(db,r)
    }
    func taskArchive(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c,write:true); var r = try task(db,p,pid); try revision(p,r); guard r["active_attempt_id"] == nil,r["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","Resolve active work before archiving.") }
        let action = p["action"] as? String ?? "archive"
        guard ["archive","unarchive","trash","restore"].contains(action) else { throw CoreError("INVALID_INPUT","Unsupported archive action.") }
        if action == "archive" { if bool(p,"cleanup") { try queueCleanup(db,task:r,previewID:p["cleanup_preview_id"] as? String) }; r["archived"] = true; r["archived_at"] = now() }
        if action == "unarchive" { r["archived"] = false }
        if action == "trash" { r["trashed"] = true }
        if action == "restore" { r["trashed"] = false }
        r = revised(r); try save(db,r,type:"task"); try event(db,caller:c,project:pid,entity:r["id"] as? String,kind:"task_"+action)
        return try taskProjection(db,r)
    }
}
