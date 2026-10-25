import Foundation
import GRDB

extension CommandRouter {
    func triagePhase(_ group: JSON) -> String? {
        if let phase = group["phase"] as? String,["implementation","review"].contains(phase) { return phase }
        let phases = Set((group["members"] as? [JSON] ?? []).compactMap {$0["handling_phase"] as? String})
        return phases.count == 1 && phases.isSubset(of:["implementation","review"]) ? phases.first : nil
    }
    func validateTriageTaskPhase(_ db: Database,task: JSON,phase: String) throws {
        let category: String
        if let sid = task["status_id"] as? String { category = try scoped(db,sid,task["project_id"] as! String,type:"status")["category"] as? String ?? "queued" } else { category = "queued" }
        if phase == "review" {
            guard category == "review",task["current_manifest_id"] != nil else { throw CoreError("TRIAGE_PHASE_CONFLICT","A review Triage accepts only tickets currently in review with a submitted exact target. Create a separate implementation Triage for further fixes.") }
        } else { guard !["review","done","canceled"].contains(category) else { throw CoreError("TRIAGE_PHASE_CONFLICT","An implementation Triage accepts implementation work, including In Progress tickets. Submitted targets go into a separate review Triage; completed tickets remain outside active handling.") } }
    }
    /// Legacy advisory handling signal: orchestration and member attempts count here.
    /// It is not the Active section predicate; that uses each ticket's status category.
    func triageActiveAttention(_ db: Database,_ group: JSON) throws -> Bool {
        let pid = group["project_id"] as! String
        return try projectedTriageAttention(group,taskLookup:{try self.scoped(db,$0,pid,type:"task")},statusLookup:{try self.scoped(db,$0,pid,type:"status")})
    }
    func projectedTriageAttention(_ group: JSON, memberIDs: [String]? = nil, taskLookup: (String) throws -> JSON, statusLookup: (String) throws -> JSON) throws -> Bool {
        if (group["orchestration"] as? JSON)?["state"] as? String == "active" { return true }
        for id in memberIDs ?? triageMemberIDs(group) {
            let task = try taskLookup(id)
            if task["active_attempt_id"] != nil { return true }
            if let sid = task["status_id"] as? String,try statusLookup(sid)["category"] as? String == "active" { return true }
        }
        return false
    }
    /// Kept for agent compatibility and work health, including unclaimed Triage members.
    func taskActiveAttention(_ db: Database,_ task: JSON) throws -> Bool {
        let pid = task["project_id"] as! String
        return try projectedTaskAttention(task,statusLookup:{try self.scoped(db,$0,pid,type:"status")}) {
            for group in try self.records(db,type:"group",project:pid) where group["kind"] as? String == "triage" && !bool(group,"archived") && self.triageMemberIDs(group).contains(task["id"] as! String) {
                if try self.triageActiveAttention(db,group) { return true }
            }
            return false
        }
    }
    func projectedTaskAttention(_ task: JSON, statusLookup: (String) throws -> JSON, groupAttention: () throws -> Bool) throws -> Bool {
        if task["active_attempt_id"] != nil { return true }
        if let sid = task["status_id"] as? String,try statusLookup(sid)["category"] as? String == "active" { return true }
        return try groupAttention()
    }
    func eligibleTriageCoordinator(_ db: Database,_ c: Caller,_ pid: String) throws -> JSON {
        guard let sid = c.sessionID,let domain = c.executionDomain else { throw CoreError("ACTUAL_SESSION_REQUIRED","Use the actual connected Codex or Claude session; a name or manually chosen identity is insufficient.") }
        let session = try eligibleWorkSession(db,id:sid,project:pid)
        guard session["execution_domain"] as? String == domain,session["installation"] as? String == c.installation else { throw CoreError("FORBIDDEN","The orchestration session must match this authenticated host connection.") }
        let project = try record(db,pid,type:"project"),policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:"")
        let rule = (policy["roles"] as? JSON)?["coordinator"] as? JSON ?? [:]
        guard strings(rule,"providers").contains(session["provider"] as? String ?? "") else { throw CoreError("POLICY_DENIED","This actual provider is not eligible to coordinate the project's Triages.") }
        return session
    }
    // CL-139: only a service-verified resumption of this exact native conversation
    // can close its old generation. It never revives checkpoint/work authority.
    func resumedTriageClosure(_ db: Database,_ orchestration: JSON,_ session: JSON,_ pid: String) throws -> String? {
        guard orchestration["session_id"] as? String == session["id"] as? String else { return nil }
        for id in strings(session,"prior_native_closure_refs") {
            let closure = try scoped(db,id,pid,type:"native_closure")
            guard closure["state"] as? String == "released",
                  closure["session_id"] as? String == orchestration["session_id"] as? String,
                  closure["provider"] as? String == orchestration["provider"] as? String,
                  closure["execution_domain"] as? String == orchestration["execution_domain"] as? String,
                  closure["old_authorization_generation"] as? String == orchestration["session_authorization_generation"] as? String,
                  let installation = closure["installation"] as? String,
                  orchestration["principal"] as? String == installation + ":" + (session["id"] as! String) else { continue }
            return id
        }
        return nil
    }
    // A Triage notice is independent of member tickets (including an empty Triage).
    // Retain history when the earlier session cannot receive; never reroute to members.
    func triageTakeoverNotice(_ db: Database,group: JSON,old: JSON,new: JSON,reason: String,caller: Caller) throws -> JSON {
        let pid = group["project_id"] as! String,gid = group["id"] as! String
        let sid = old["session_id"] as? String ?? ""
        let target = try? scoped(db,sid,pid,type:"session")
        let recipients: [JSON] = target.map {canReceive($0,project:pid) ? [["session_id":sid,"recipient_role":"prior_orchestrator"]] : []} ?? []
        let message: JSON = ["id":uuid(),"project_id":pid,"triage_id":gid,"kind":"note","origin":"agent",
            "author":caller.principal,"author_display":author(db,caller),"author_session_id":caller.sessionID!,
            "requires_action":false,"addressed":false,"revision":1,"created_at":now(),
            "from_orchestration_id":old["id"]!,"to_orchestration_id":new["id"]!,
            "prior_orchestrator_session_id":sid,"orchestrator_session_id":caller.sessionID!,
            "body":"Triage metadata: \(try agentReference(db,group)). \(AgentReference.quoted(author(db,caller))) (session \(caller.sessionID!)) took over orchestration. Reason: \(reason)\nYour orchestration record ended. Member ticket claims and Triage memberships are unchanged."]
        try save(db,message,type:"message")
        let deliveries = try queueDirectionDeliveries(db,message:message,recipients:recipients)
        try event(db,caller:caller,project:pid,entity:gid,kind:"message_saved",data:["message_id":message["id"]!,"origin":"agent"])
        return ["message_id":message["id"]!,"recipient_session_id":sid,"deliveries":deliveries,"delivery_status":recipients.isEmpty ? "saved_for_pickup" : "queued","native_push":false]
    }
    func triageOrchestrate(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),gid = try text(p,"triage_id")
        var group = try scoped(db,gid,pid,type:"group");try revision(p,group)
        guard group["kind"] as? String == "triage",!bool(group,"archived"),triagePhase(group) != nil else { throw CoreError("TRIAGE_PHASE_REQUIRED","Use an active Triage with an established implementation or review phase.") }
        let action = try text(p,"action");var orchestration = group["orchestration"] as? JSON ?? [:]
        guard ["start","checkpoint","finish","takeover"].contains(action) else { throw CoreError("INVALID_INPUT","Use start, checkpoint, finish or takeover for the actual orchestration session.") }
        var notice: JSON?
        if action == "start" || action == "takeover" {
            let session = try eligibleTriageCoordinator(db,c,pid)
            let previous = orchestration
            var reason: String?
            if action == "takeover" {
                reason = try text(p,"reason",max:4000)
                guard previous["state"] as? String == "active" else { throw CoreError("INVALID_TRANSITION","This Triage has no active orchestration to take over. Use start.") }
                guard previous["session_id"] as? String != c.sessionID else { throw CoreError("INVALID_INPUT","This conversation already records the orchestration. Finish it before starting again; a verified resumed conversation can finish with a reason.") }
            } else if previous["state"] as? String == "active" { throw CoreError("CLAIM_CONFLICT","This Triage already records an active orchestration. Checkpoint, explicitly finish or take over that recorded coordination with a reason.") }
            orchestration = ["id":uuid(),"session_id":c.sessionID!,"principal":c.principal,"session_authorization_generation":sessionGeneration(session),"execution_domain":c.executionDomain!,"provider":session["provider"]!,"actor_display":author(db,c),"state":"active","started_at":now(),"revision":1]
            if let previousID = previous["id"] { orchestration["previous_orchestration_id"] = previousID }
            if let reason {
                var ended = revised(previous);ended["state"] = "taken_over";ended["finished_at"] = now()
                ended["takeover_reason"] = reason;ended["taken_over_by_orchestration_id"] = orchestration["id"]
                ended["taken_over_by_session_id"] = c.sessionID!
                orchestration["takeover_from_orchestration_id"] = previous["id"]!;orchestration["takeover_reason"] = reason
                if let progress = previous["progress"] { orchestration["takeover_context"] = progress }
                try event(db,caller:c,project:pid,entity:gid,kind:"triage_orchestration_taken_over",data:["orchestration":ended,"member_claims_unchanged":true,"memberships_unchanged":true])
                notice = try triageTakeoverNotice(db,group:group,old:ended,new:orchestration,reason:reason,caller:c)
                orchestration["takeover_notice"] = notice!
            }
        } else {
            guard orchestration["state"] as? String == "active" else { throw CoreError("INVALID_TRANSITION","This Triage has no recorded active orchestration.") }
            if c.isOwner,action == "finish" { orchestration["owner_finish_reason"] = try text(p,"reason") }
            else {
                guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","Only the recorded actual session can checkpoint or finish.") }
                let session = try eligibleWorkSession(db,id:sid,project:pid)
                guard session["installation"] as? String == c.installation,session["execution_domain"] as? String == c.executionDomain else { throw CoreError("FORBIDDEN","Use the authenticated current session connection.") }
                let current = orchestration["principal"] as? String == c.principal && orchestration["session_id"] as? String == c.sessionID && orchestration["execution_domain"] as? String == c.executionDomain && orchestration["session_authorization_generation"] as? String == sessionGeneration(session)
                if !current {
                    guard action == "finish",let closure = try resumedTriageClosure(db,orchestration,session,pid) else { throw CoreError("FORBIDDEN","Only the recorded current session can checkpoint or finish. A verified resumed conversation can finish its earlier record with a reason; an eligible different coordinator can explicitly take over.") }
                    orchestration["recovery_finish_reason"] = try text(p,"reason",max:4000)
                    orchestration["native_closure_ref"] = closure;orchestration["finished_by_principal"] = c.principal
                    orchestration["finished_by_authorization_generation"] = sessionGeneration(session)
                }
            }
            orchestration = revised(orchestration)
        }
        if p["progress"] != nil { let progress = try text(p,"progress"); recordHealthProgress(&orchestration,progress:progress); orchestration["progress"] = progress }
        orchestration["last_checkpoint"] = now()
        if action == "finish" { orchestration["state"] = "finished";orchestration["finished_at"] = now() }
        group["orchestration"] = orchestration;group = revised(group);try save(db,group,type:"group")
        try event(db,caller:c,project:pid,entity:gid,kind:"triage_orchestration_"+action,data:["orchestration":orchestration,"member_claims_unchanged":true,"memberships_unchanged":true])
        var result = try groupProjection(db,group)
        if let notice { result["takeover_notice"] = notice }
        return result
    }
    func taskEpicContext(_ db: Database,_ task: JSON) throws -> Any {
        guard let id = task["epic_id"] as? String,let source = try? scoped(db,id,task["project_id"] as! String,type:"group"),source["kind"] as? String == "epic" else { return NSNull() }
        return try groupProjection(db,source)
    }
    func taskTriages(_ db: Database,_ task: JSON) throws -> [JSON] {
        try records(db,type:"group",project:task["project_id"] as? String).filter {$0["kind"] as? String == "triage" && triageMemberIDs($0).contains(task["id"] as! String)}.map {try groupProjection(db,$0)}
    }
    /// Empty fields retains the full legacy projection. List summaries avoid loading
    /// histories and lifecycle records that would be discarded by listProjection.
    func groupProjection(_ db: Database,_ source: JSON,fields: Set<String> = []) throws -> JSON {
        var group = source
        if source["kind"] as? String == "triage" {
            let ids = triageMemberIDs(source)
            let tasks = try ids.map {try scoped(db,$0,source["project_id"] as! String,type:"task")}
            let statuses = Set(tasks.compactMap {$0["status_id"] as? String})
            let state = tasks.isEmpty ? "empty" : (statuses.count == 1 ? "uniform" : "mixed")
            let uniformStatus = try statuses.count == 1 ? record(db,statuses.first!,type:"status") : nil
            let label = uniformStatus?["name"] as? String ?? (state == "empty" ? "Empty" : "Mixed")
            group["task_ids"] = ids;group["member_count"] = ids.count;group["status_state"] = state
            group["phase"] = triagePhase(source) ?? NSNull();group["phase_requires_selection"] = triagePhase(source) == nil
            group["phase_source"] = source["phase"] == nil ? "legacy_membership" : "explicit"
            group["status_id"] = uniformStatus?["id"] ?? NSNull();group["status_name"] = label;group["status_category"] = uniformStatus?["category"] ?? state
            group["derived_status"] = ["kind":state,"label":label,"status_id":uniformStatus?["id"] ?? NSNull(),"member_count":ids.count]
            if fields.isEmpty || fields.contains("active_attention") { group["active_attention"] = try triageActiveAttention(db,source) }
            // CL-43: the coordinator sees each member's repeated-cause warning.
            if fields.isEmpty || fields.contains("member_warnings") { group["member_warnings"] = try tasks.flatMap { try reviewWarnings(db,task:$0) } }
            group["active_navigation"] = !bool(source,"archived") && !ids.isEmpty
            if fields.isEmpty || fields.contains("orchestration_connection"),let orchestration = source["orchestration"] as? JSON,orchestration["state"] as? String == "active" {
                let session = try? scoped(db,orchestration["session_id"] as? String ?? "",source["project_id"] as! String,type:"session")
                let current = session.map {canReceive($0,project:source["project_id"] as! String) && sessionGeneration($0) == orchestration["session_authorization_generation"] as? String} ?? false
                group["orchestration_connection"] = current ? "current" : "recovery_required"
            }
            if fields.isEmpty || fields.contains("membership_history") {
                let exits = try groupRelatedRecords(db,source,type:"triage_membership_exit",field:"triage_id")
                group["membership_history"] = try groupRelatedRecords(db,source,type:"triage_membership_interval",field:"triage_id").map { interval -> JSON in
                    var interval = interval;interval["exit"] = exits.first {$0["membership_id"] as? String == interval["id"] as? String} ?? NSNull();return interval
                }
            }
            if fields.isEmpty || fields.contains("batches") {
                group["batches"] = try groupRelatedRecords(db,source,type:"batch",field:"triage_id").map { batch -> JSON in
                    var summary: JSON = ["id":batch["id"]!,"phase":batch["phase"]!,"created_at":batch["created_at"]!,"triage_revision":batch["triage_revision"]!,"member_count":(batch["members"] as? [JSON] ?? []).count,"digest":batch["digest"]!]
                    summary.merge(try batchLifecycle(db,batch)) { _,new in new };return summary
                }
            }
            return group
        }
        guard source["kind"] as? String == "epic" else { return group }
        let assigned = try groupRelatedRecords(db,source,type:"task",field:"epic_id")
        let previous = source["members"] as? [JSON] ?? []
        group["members"] = assigned.map { task -> JSON in ["task_id":task["id"]!,"joined_at":previous.first(where: {$0["task_id"] as? String == task["id"] as? String})?["joined_at"] ?? task["updated_at"] ?? task["created_at"] ?? ""] }
        group["task_ids"] = assigned.compactMap {$0["id"] as? String}
        group["brief"] = source["brief"] ?? source["description"] ?? source["purpose"] ?? ""
        group["description"] = group["brief"]
        return group
    }
    /// Existing scope index selects the record family; unrelated rich histories
    /// never cross the canonical decoding boundary for each individual group.
    private func groupRelatedRecords(_ db: Database,_ group: JSON,type: String,field: String) throws -> [JSON] {
        let pid = group["project_id"] as! String,gid = group["id"] as! String
        return try readSnapshotCache.records(db,key:["group-related",pid,gid,type,field]) {
            try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND json_extract(data,'$."+field+"')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid",arguments:[Data(type.utf8),Data(pid.utf8),Data(gid.utf8)])
        }
    }
    func syncEpic(_ db: Database,_ source: JSON,taskOverride: JSON? = nil) throws -> JSON {
        guard source["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","Persistent membership synchronization applies only to Epics.") }
        let pid = source["project_id"] as! String,gid = source["id"] as! String
        var group = source;let previous = source["members"] as? [JSON] ?? []
        var tasks = try records(db,type:"task",project:pid)
        if let override = taskOverride { tasks.removeAll {$0["id"] as? String == override["id"] as? String};tasks.append(override) }
        let assigned = tasks.filter {$0["epic_id"] as? String == gid}
        // Retain membership evidence even after removal, ticket purge or receipt expiry.
        if !assigned.isEmpty || !previous.isEmpty { group["has_held_ticket"] = true }
        group["members"] = assigned.map { task -> JSON in ["task_id":task["id"]!,"joined_at":previous.first(where: {$0["task_id"] as? String == task["id"] as? String})?["joined_at"] ?? now()] }
        group["task_ids"] = assigned.compactMap {$0["id"] as? String};group = revised(group);try save(db,group,type:"group");return group
    }
    func editTaskEpic(_ db: Database,task: inout JSON,value: Any) throws {
        let pid = task["project_id"] as! String,old = task["epic_id"] as? String
        let destination = try requiredEpicID(value)
        let epic = try scoped(db,destination,pid,type:"group");guard epic["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","An Epic must be a persistent subproject, not a Triage.") }
        guard old == destination || !bool(epic,"archived") else { throw CoreError("INVALID_INPUT","Restore this Epic before adding tickets.") }
        guard old == nil || old == destination else { throw CoreError("EPIC_MOVE_REQUIRED","Use an explicit Epic move so the source and destination are reviewed together.",details:["from_epic_id":old!,"task_revision":task["revision"]!]) }
        task["epic_id"] = destination;_ = try syncEpic(db,epic,taskOverride:task)
    }
    func groupList(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c), kind = method == "epic_list" ? "epic" : "triage"
        let fields = method == "triage_list" ? try listFields(db,p,projects:[pid],type:"group",kind:"triage",known:Self.triageListFields) : []
        let selected = method == "triage_list" ? try listGroup(db,p,key:"triage_id",projects:[pid],kind:"triage") : nil
        var groups = try records(db,type:"group",project:pid).filter {$0["kind"] as? String == kind && (selected == nil || $0["id"] as? String == selected?["id"] as? String)}
        if p["key"] != nil {
            let key = try text(p,"key")
            groups = groups.filter {($0["key"] as? String ?? "").caseInsensitiveCompare(key) == .orderedSame}
            guard groups.count <= 1 else { throw CoreError("AMBIGUOUS_GROUP","More than one \(kind) uses display key \(AgentReference.quoted(key)). Select its stable internal ID.",details:["matches":groups.map {["id":$0["id"]!,"key":$0["key"]!,"title":$0["name"] ?? ""]}]) }
        }
        return ["groups":listProjection(try groups.map {try groupProjection(db,$0,fields:fields)},fields:fields)]
    }
    func groupWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        if method.hasSuffix("create") {
            let kind = method == "epic_create" ? "epic" : "triage",brief = p["brief"] as? String ?? p["description"] as? String ?? p["purpose"] as? String ?? ""
            var project = try record(db,pid,type:"project")
            let number = try GroupKeys.next(project,groups:records(db,type:"group",project:pid),kind:kind)
            project[GroupKeys.counter(kind)] = number + 1
            try save(db,project,type:"project")
            var group: JSON = ["key":"\(project["key_prefix"] as? String ?? "TASK")-\(GroupKeys.marker(kind))\(number)","id":uuid(),"project_id":pid,"kind":kind,"name":try text(p,"name",max:200),"revision":1,"members":[],"task_ids":[],"archived":false,"created_at":now(),"updated_at":now()]
            if kind == "epic" { group["brief"] = brief;group["description"] = brief }
            else {
                let phase = p["phase"] as? String ?? "implementation"
                guard ["implementation","review"].contains(phase) else { throw CoreError("INVALID_INPUT","Choose an implementation or review Triage.") }
                group["phase"] = phase;group["purpose"] = p["purpose"] ?? brief
            }
            try save(db,group,type:"group");try event(db,caller:c,project:pid,entity:group["id"] as? String,kind:kind+"_created");return try groupProjection(db,group)
        }
        let gid = p["group_id"] as? String ?? p["triage_id"] as? String ?? p["epic_id"] as? String ?? ""
        var group = try scoped(db,gid,pid,type:"group");try revision(p,group)
        if method == "group_edit" || method == "epic_edit" || method == "triage_edit" {
            if p["name"] != nil { group["name"] = try text(p,"name",max:200) }
            if group["kind"] as? String == "epic" { if let brief = p["brief"] ?? p["description"] ?? p["purpose"] { guard let text = brief as? String,text.utf8.count <= 65536 else { throw CoreError("INVALID_INPUT","The Epic brief must be text up to 64 KiB.") };group["brief"] = text;group["description"] = text } }
            else if let purpose = p["purpose"] ?? p["brief"] { guard let text = purpose as? String,text.utf8.count <= 65536 else { throw CoreError("INVALID_INPUT","The Triage purpose must be text up to 64 KiB.") };group["purpose"] = text }
            if group["kind"] as? String == "triage",let phase = p["phase"] as? String {
                guard ["implementation","review"].contains(phase) else { throw CoreError("INVALID_INPUT","Choose implementation or review handling.") }
                guard triageMemberIDs(group).isEmpty || triagePhase(group) == nil || triagePhase(group) == phase else { throw CoreError("TRIAGE_PHASE_CONFLICT","Use a separate Triage for the next phase. Only an empty Triage can change its established phase.") }
                for memberID in triageMemberIDs(group) { try validateTriageTaskPhase(db,task:scoped(db,memberID,pid,type:"task"),phase:phase) }
                group["phase"] = phase
            }
            if p["archived"] != nil {
                if bool(p,"archived"),group["kind"] as? String == "epic" {
                    let live = try String.fetchOne(db,sql:"SELECT id FROM records WHERE type='task' AND project_id=? AND json_extract(data,'$.epic_id')=? AND COALESCE(json_extract(data,'$.archived'),0)=0 AND COALESCE(json_extract(data,'$.trashed'),0)=0 AND COALESCE(json_extract(data,'$.purged'),0)=0 LIMIT 1",arguments:[pid,gid])
                    guard live == nil else {throw CoreError("EPIC_IN_USE","Move this Epic's live tickets to another Epic before archiving it.")}
                }
                group["archived"] = bool(p,"archived")
            }
            group = revised(group);try save(db,group,type:"group");try event(db,caller:c,project:pid,entity:gid,kind:"group_edited");return try groupProjection(db,group)
        }
        let tid = try text(p,"task_id");var task = try scoped(db,tid,pid,type:"task")
        if p["expected_task_revision"] != nil { try revision(["expected_revision":p["expected_task_revision"]!],task) }
        let action = p["action"] as? String ?? "add"
        if group["kind"] as? String == "epic" {
            guard ["add","remove","move"].contains(action) else { throw CoreError("INVALID_INPUT","Epic membership supports add, remove or explicit move.") }
            let old = task["epic_id"] as? String
            if action == "remove" {
                if old == gid { throw CoreError("EPIC_REQUIRED","Every ticket needs a primary Epic. Move it to another Epic instead.") }
            } else {
                guard old == gid || !bool(group,"archived") else { throw CoreError("INVALID_INPUT","Restore this Epic before adding tickets.") }
                if let old = old,old != gid {
                    guard action == "move",p["expected_task_revision"] != nil,p["from_epic_id"] as? String == old else { throw CoreError("EPIC_MOVE_REQUIRED","This task already belongs to another Epic. Confirm an explicit move.",details:["from_epic_id":old,"task_revision":task["revision"]!]) }
                    let source = try scoped(db,old,pid,type:"group");guard source["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","The source Epic link requires repair.") };guard p["from_epic_revision"] != nil else { throw CoreError("REVISION_REQUIRED","Read the source Epic before moving this task.") };try revision(["expected_revision":p["from_epic_revision"]!],source)
                    task["epic_id"] = gid;task = revised(task);try save(db,task,type:"task");_ = try syncEpic(db,source,taskOverride:task)
                    try event(db,caller:c,project:pid,entity:old,kind:"epic_task_moved_out",data:["task_id":tid,"to_epic_id":gid])
                } else if old != gid { task["epic_id"] = gid;task = revised(task);try save(db,task,type:"task") }
            }
            group = try syncEpic(db,group,taskOverride:task)
            try event(db,caller:c,project:pid,entity:gid,kind:"epic_member_"+action,data:["task_id":tid,"from_epic_id":old ?? NSNull()]);return group
        }
        guard ["add","update","remove"].contains(action) else { throw CoreError("INVALID_INPUT","Triage membership supports add, update or remove.") }
        guard !bool(group,"archived") || action == "remove" else { throw CoreError("INVALID_TRANSITION","Restore this Triage before adding or updating its handling set.") }
        var members = group["members"] as? [JSON] ?? [];let prior = members.first {$0["task_id"] as? String == tid};members.removeAll {$0["task_id"] as? String == tid}
        if action != "remove" {
            if action == "update",prior == nil { throw CoreError("NOT_FOUND","This task is not a Triage member.") }
            guard let groupPhase = triagePhase(group) else { throw CoreError("TRIAGE_PHASE_REQUIRED","Choose this legacy Triage's implementation or review phase before handling new work. Existing memberships are preserved.") }
            try validateTriageTaskPhase(db,task:task,phase:groupPhase)
            if let requested = p["handling_phase"] as? String,requested != groupPhase { throw CoreError("TRIAGE_PHASE_CONFLICT","A member's handling phase must match its Triage.") }
            let milestone = p["exit_milestone"] as? String ?? prior?["exit_milestone"] as? String ?? (groupPhase == "review" ? "review_accepted" : "implementation_submitted")
            guard ["manual","implementation_submitted","review_accepted"].contains(milestone) else { throw CoreError("INVALID_INPUT","Choose implementation submission, accepted review or manual removal.") }
            let phase = groupPhase
            guard ["implementation","review"].contains(phase) else { throw CoreError("INVALID_INPUT","Choose implementation or review handling.") }
            var member: JSON = ["task_id":tid,"exit_milestone":milestone,"handling_phase":phase,"joined_at":prior?["joined_at"] ?? now(),"updated_at":now()]
            if let prior = prior { member["membership_id"] = try ensureTriageMembershipInterval(db,group:group,member:prior,caller:c)["id"] }
            else { member["membership_id"] = try ensureTriageMembershipInterval(db,group:group,member:member,caller:c,joiningRevision:int(group,"revision")+1)["id"] }
            members.append(member)
        } else if let prior = prior {
            _ = try closeTriageMembership(db,group:group,member:prior,caller:c,reason:"manual",extra:["label":c.isOwner ? "Owner removed from Triage" : "Manually removed from Triage"])
        }
        group["members"] = members;group["task_ids"] = members.compactMap {$0["task_id"] as? String};group = revised(group);try save(db,group,type:"group")
        try event(db,caller:c,project:pid,entity:gid,kind:action == "remove" ? "triage_member_removed" : (prior == nil ? "triage_member_added" : "triage_member_updated"),data:["task_id":tid]);return try groupProjection(db,group)
    }
}
