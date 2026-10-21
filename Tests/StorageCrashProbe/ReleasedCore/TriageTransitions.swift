import Foundation
import GRDB

/// Only trusted atomic group/batch code can choose group scope. No tool input can retain an individual ticket's memberships.
enum TicketStatusOperation { case individual, triage }

extension CommandRouter {
    func ensureTriageMembershipInterval(_ db: Database,group: JSON,member: JSON,caller: Caller,joiningRevision: Int? = nil) throws -> JSON {
        let pid = group["project_id"] as! String
        if let id = member["membership_id"] as? String,let existing = try? scoped(db,id,pid,type:"triage_membership_interval") { return existing }
        // Earlier stores had joined_at but no interval ID. Preserve that observation without inventing an old revision.
        var interval: JSON = ["id":uuid(),"project_id":pid,"triage_id":group["id"]!,"task_id":member["task_id"]!,"joined_at":member["joined_at"] ?? now(),"membership_snapshot":member,"actor":caller.principal,"revision":1,"created_at":now()]
        if let joiningRevision = joiningRevision { interval["originating_triage_revision"] = joiningRevision }
        else { interval["originating_triage_revision"] = NSNull();interval["history_source"] = "legacy_membership_observation" }
        try save(db,interval,type:"triage_membership_interval");return interval
    }
    func closeTriageMembership(_ db: Database,group: JSON,member: JSON,caller: Caller,reason: String,extra: JSON = [:]) throws -> JSON {
        let interval = try ensureTriageMembershipInterval(db,group:group,member:member,caller:caller),pid = group["project_id"] as! String
        if let existing = try records(db,type:"triage_membership_exit",project:pid).first(where: {$0["membership_id"] as? String == interval["id"] as? String}) { return existing }
        var exit: JSON = ["id":uuid(),"project_id":pid,"triage_id":group["id"]!,"membership_id":interval["id"]!,"task_id":member["task_id"]!,"exited_at":now(),"reason":reason,"triage_revision":int(group,"revision")+1,"actor":caller.principal,"previous_membership":member,"revision":1]
        for (key,value) in extra { exit[key] = value };try save(db,exit,type:"triage_membership_exit")
        try event(db,caller:caller,project:pid,entity:group["id"] as? String,kind:"triage_member_exited",data:exit)
        try event(db,caller:caller,project:pid,entity:member["task_id"] as? String,kind:"task_left_triage",data:["triage_id":group["id"]!,"membership_id":interval["id"]!,"reason":reason,"label":exit["label"] ?? reason]);return exit
    }
    func triageMemberIDs(_ group: JSON) -> [String] {
        let members = (group["members"] as? [JSON] ?? []).compactMap {$0["task_id"] as? String}
        var seen = Set<String>()
        return (members.isEmpty ? strings(group,"task_ids") : members).filter {seen.insert($0).inserted}
    }
    func recordTicketStatusAction(_ db: Database,task: JSON,caller: Caller,operation: TicketStatusOperation = .individual) throws {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        let category = try taskProjection(db,task)["status_category"] as? String ?? ""
        guard operation == .individual || category == "done" else { return }
        let reason = category == "done" ? "completed" : "individual_status_action"
        for var group in try records(db,type:"group",project:pid) where group["kind"] as? String == "triage" && triageMemberIDs(group).contains(tid) {
            let previous = (group["members"] as? [JSON] ?? []).first {$0["task_id"] as? String == tid} ?? ["task_id":tid]
            var extra: JSON = ["status_id":task["status_id"] ?? NSNull()]
            if category == "done",let mid = task["current_manifest_id"] as? String,let manifest = try? scoped(db,mid,pid,type:"manifest") {
                extra["target_manifest_id"] = mid;extra["label"] = try manifestGates(db,manifest).isEmpty ? "No review required" : "Completed after required gates"
                if try records(db,type:"finding_resolution",project:pid).contains(where: {$0["task_id"] as? String == tid && $0["disposition"] as? String == "waived"}) { extra["label"] = "Completed with owner-waived findings" }
            }
            _ = try closeTriageMembership(db,group:group,member:previous,caller:caller,reason:reason,extra:extra)
            group["members"] = (group["members"] as? [JSON] ?? []).filter {$0["task_id"] as? String != tid}
            group["task_ids"] = triageMemberIDs(group).filter {$0 != tid};group = revised(group);try save(db,group,type:"group")
        }
    }
    func triageTransition(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        guard (p["triage_id"] != nil) != (p["group_id"] != nil) else { throw CoreError("INVALID_INPUT","Select exactly one Triage using triage_id or group_id.") }
        guard (p["target_status_id"] != nil) != (p["action"] != nil) else { throw CoreError("INVALID_INPUT","Choose exactly one target_status_id or action.") }
        let gid = try text(p,p["triage_id"] != nil ? "triage_id" : "group_id");let group = try scoped(db,gid,pid,type:"group")
        guard group["kind"] as? String == "triage" else { throw CoreError("INVALID_INPUT","Only a Triage can change the statuses of its current handling group. Epics remain persistent subprojects.") }
        try revision(p,group)
        let ids = triageMemberIDs(group)
        if !ids.isEmpty,triagePhase(group) == nil { throw CoreError("TRIAGE_PHASE_REQUIRED","Choose this legacy Triage's handling phase before applying a group workflow. Existing memberships are preserved.") }
        guard ids.count <= 1000 else { throw CoreError("CAPACITY_EXCEEDED","This atomic status action supports at most 1,000 Triage members. No tickets changed.") }
        guard let rawRevisions = p["expected_member_revisions"] as? JSON else { throw CoreError("REVISION_REQUIRED","Include the expected revision of every current Triage ticket.") }
        guard Set(rawRevisions.keys) == Set(ids) else { throw CoreError("REVISION_CONFLICT","Triage membership changed or the ticket revision map is incomplete. Reload all \(ids.count) current members before retrying; no tickets changed.",details:["current_member_ids":ids,"missing_member_ids":Array(Set(ids).subtracting(rawRevisions.keys)),"unexpected_member_ids":Array(Set(rawRevisions.keys).subtracting(ids))]) }
        var tasks: [JSON] = [],conflicts: [JSON] = []
        for id in ids {
            let task = try scoped(db,id,pid,type:"task");tasks.append(task)
            guard let number = rawRevisions[id] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.rounded() == number.doubleValue,number.intValue >= 1 else { throw CoreError("INVALID_INPUT","Each expected member revision must be a positive integer.") }
            if number.intValue != int(task,"revision") { conflicts.append(["task_id":id,"key":task["key"] ?? id,"expected_revision":number.intValue,"current_revision":task["revision"]!]) }
        }
        if !conflicts.isEmpty { throw CoreError("REVISION_CONFLICT","Tickets changed before this Triage action: \(conflicts.map {$0["key"] as? String ?? "ticket"}.joined(separator:", ")). Reload them before retrying; no tickets changed.",details:["blockers":conflicts]) }
        let target: JSON
        if let sid = p["target_status_id"] as? String { target = try scoped(db,sid,pid,type:"status") }
        else {
            let actions = ["queue":"queued","reopen":"queued","defer":"parked","block":"blocked","cancel":"canceled","complete":"done"]
            guard let category = actions[try text(p,"action")] else { throw CoreError("INVALID_TRANSITION","Use queue, reopen, defer, block, cancel or complete. Work and review require actual per-ticket workflows; no tickets changed.") }
            target = try status(db,pid,category)
        }
        guard !bool(target,"retired") else { throw CoreError("INVALID_TRANSITION","This status is retired. Choose a current project status; no tickets changed.") }
        let category = target["category"] as? String ?? ""
        guard !["active","review"].contains(category) else { throw CoreError("INVALID_TRANSITION","\(target["name"] as? String ?? "This status") requires actual work claims or review submissions for each ticket. A bulk status selection cannot create those workflows; no tickets changed.") }
        let snapshot: [JSON] = tasks.map {["task_id":$0["id"]!,"key":$0["key"]!,"revision":$0["revision"]!,"status_id":$0["status_id"]!]}
        if tasks.isEmpty { return ["triage":try groupProjection(db,group),"member_snapshot":snapshot,"changed_task_ids":[],"unchanged_task_ids":[],"completed_task_ids":[],"no_op":true,"reason":"empty_triage"] }
        let directionCursors = p["expected_direction_cursors"] as? [String:String] ?? [:]
        if category == "done",Set(directionCursors.keys) != Set(ids) { throw CoreError("DIRECTION_CURSOR_REQUIRED","Read current task context for every member and provide its observed direction cursor before group completion.") }
        func apply(_ task: JSON) throws -> JSON {
            var input: JSON = ["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"target_status_id":target["id"]!,"reason":p["reason"] ?? "Triage status action"]
            if category == "done" {
                if let mid = task["current_manifest_id"] { input["current_manifest_id"] = mid }
                input["direction_cursor"] = directionCursors[task["id"] as! String]!
                return try work(db,input,c,"task_complete",operation:.triage)
            }
            // Returning review work to implementation/parking or canceling a phase departs its handling groups.
            let operation: TicketStatusOperation = triagePhase(group) == "review" || category == "canceled" ? .individual : .triage
            return try taskTransition(db,input,c,operation:operation)
        }
        // Evaluate every existing guard in rollback-only savepoints, so the user sees all blockers before any change is retained.
        var blockers: [JSON] = []
        for task in tasks {
            do { try db.inSavepoint { _ = try apply(task);return .rollback } }
            catch let error as CoreError { blockers.append(["task_id":task["id"]!,"key":task["key"]!,"code":error.code,"message":error.message,"details":error.details]) }
        }
        if !blockers.isEmpty {
            let summary = blockers.prefix(10).map {"\($0["key"] as? String ?? "Ticket"): \($0["message"] as? String ?? "Blocked")"}.joined(separator:"; ")
            throw CoreError("TRIAGE_TRANSITION_BLOCKED","\(summary)\(blockers.count > 10 ? "; and \(blockers.count-10) more blocked tickets" : ""). No tickets changed.",details:["blockers":blockers,"target_status_id":target["id"]!,"member_snapshot":snapshot])
        }
        var changed: [String] = [],unchanged: [String] = [],completed: [String] = []
        for task in tasks {
            let id = task["id"] as! String
            if category != "done",task["status_id"] as? String == target["id"] as? String { unchanged.append(id);continue }
            _ = try apply(task);changed.append(id);if category == "done" { completed.append(id) }
        }
        var current = try scoped(db,gid,pid,type:"group")
        if !changed.isEmpty {
            if category != "done" { current = revised(current);try save(db,current,type:"group") }
            try event(db,caller:c,project:pid,entity:gid,kind:"triage_status_applied",data:["target_status_id":target["id"]!,"member_snapshot":snapshot,"changed_task_ids":changed,"completed_task_ids":completed])
        }
        return ["triage":try groupProjection(db,current),"member_snapshot":snapshot,"changed_task_ids":changed,"unchanged_task_ids":unchanged,"completed_task_ids":completed,"no_op":changed.isEmpty,"reason":changed.isEmpty ? "already_at_target" : "applied"]
    }
}
