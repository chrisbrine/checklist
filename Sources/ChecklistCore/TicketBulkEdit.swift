import Foundation
import CoreFoundation
import GRDB

extension CommandRouter {
    /// Receipts live in the existing idempotent command journal, including its retention limit.
    func taskBulkEdit(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c)
        let pid = try scope(db,p,c,write:true), tasks = try bulkTasks(p)
        let changes = try bulkChanges(p)
        return try performBulk(db,p,c,project:pid,tasks:tasks,kind:"task_bulk_edit") { input in
            try self.applyBulkChange(db,input,c,changes:changes)
        }
    }

    private func bulkTasks(_ p: JSON) throws -> [JSON] {
        guard let tasks = p["tasks"] as? [JSON], !tasks.isEmpty, tasks.count <= 200 else { throw CoreError("INVALID_INPUT","Select between 1 and 200 tickets.") }
        var ids = Set<SnapshotRecordIdentity>()
        for row in tasks {
            guard Set(row.keys) == Set(["task_id","expected_revision"]),let id = row["task_id"] as? String,!id.isEmpty,
                  let n = row["expected_revision"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.rounded() == n.doubleValue,n.intValue > 0,
                  ids.insert(SnapshotRecordIdentity(id)).inserted else { throw CoreError("INVALID_INPUT","Include each ticket once, with its current revision.") }
        }
        if let value = p["preview"], !(value is NSNumber && CFGetTypeID(value as! NSNumber) == CFBooleanGetTypeID()) { throw CoreError("INVALID_INPUT","Preview must be true or false.") }
        return tasks
    }

    private func bulkChanges(_ p: JSON) throws -> JSON {
        guard let changes = p["changes"] as? JSON,let kind = changes["kind"] as? String else { throw CoreError("INVALID_INPUT","Choose one bulk change.") }
        let keys: [String:Set<String>] = ["status":["kind","action","reason"],"tags":["kind","add","remove"],"assignee":["kind","planned_assignee","assignment_reason"],"epic":["kind","epic_id"],"triage":["kind","triage_id","action"],"archive":["kind","action"]]
        guard let allowed = keys[kind],Set(changes.keys).isSubset(of:allowed) else { throw CoreError("INVALID_INPUT","Choose one supported bulk change.") }
        switch kind {
        case "status":
            let action = changes["action"] as? String ?? ""
            guard ["queue","defer","block","cancel","reopen"].contains(action) else { throw CoreError("INVALID_INPUT","Use queue, defer, block, cancel or reopen.") }
            let requiresReason = ["cancel","reopen"].contains(action)
            if requiresReason,changes["reason"] == nil { throw CoreError("INVALID_INPUT","Add a reason to cancel or reopen tickets.") }
            _ = try text(changes,"reason",max:4000,required:requiresReason)
        case "tags":
            for key in ["add","remove"] where changes[key] != nil { guard let values = changes[key] as? [String],values.count <= 200 else { throw CoreError("INVALID_INPUT","Choose up to 200 tag IDs.") } }
            guard !strings(changes,"add").isEmpty || !strings(changes,"remove").isEmpty,Set(strings(changes,"add").map(SnapshotRecordIdentity.init)).isDisjoint(with:strings(changes,"remove").map(SnapshotRecordIdentity.init)) else { throw CoreError("INVALID_INPUT","Choose tags to add or remove, without overlap.") }
        case "assignee": guard let value = changes["planned_assignee"] else { throw CoreError("INVALID_INPUT","Choose a planned assignee.") };try validateAssignment(value)
        case "epic": _ = try requiredEpicID(changes["epic_id"])
        case "triage": _ = try text(changes,"triage_id");guard ["add","remove"].contains(changes["action"] as? String ?? "") else { throw CoreError("INVALID_INPUT","Add or remove Triage membership.") }
        case "archive": guard ["archive","unarchive","trash","restore"].contains(changes["action"] as? String ?? "") else { throw CoreError("INVALID_INPUT","Choose archive, unarchive, trash or restore.") }
        default: break
        }
        return changes
    }

    private func applyBulkChange(_ db: Database,_ input: JSON,_ c: Caller,changes: JSON) throws {
        let pid = input["project_id"] as! String,tid = input["task_id"] as! String
        let task = try scoped(db,tid,pid,type:"task");try revision(input,task)
        guard task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","This ticket has active work or review. Release it first.") }
        switch changes["kind"] as! String {
        case "status": var p = input;p["action"] = changes["action"];p["reason"] = changes["reason"];_ = try taskTransition(db,p,c)
        case "archive": var p = input;p["action"] = changes["action"];p["cleanup"] = false;_ = try taskArchive(db,p,c)
        case "tags":
            let add = strings(changes,"add"),removed = strings(changes,"remove"),remove = Set(removed.map(SnapshotRecordIdentity.init))
            for id in add + removed { _ = try scoped(db,id,pid,type:"tag") }
            var tags = strings(task,"tag_ids").filter {!remove.contains(SnapshotRecordIdentity($0))}
            for id in add where !tags.contains(where:{SnapshotRecordIdentity($0) == SnapshotRecordIdentity(id)}) { tags.append(id) }
            var p = input;p["patch"] = ["tag_ids":tags];_ = try taskEdit(db,p,c)
        case "assignee":
            var p = input
            var patch: JSON = ["planned_assignee":changes["planned_assignee"]!]
            patch["assignment_reason"] = changes["assignment_reason"]
            p["patch"] = patch
            _ = try taskEdit(db,p,c)
        case "epic":
            if let destination = changes["epic_id"] as? String {
                let target = try scoped(db,destination,pid,type:"group")
                guard target["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","Choose an Epic.") }
                var p = input;p["group_id"] = destination;p["expected_revision"] = target["revision"];p["expected_task_revision"] = task["revision"];p["action"] = "move"
                if let old = task["epic_id"] as? String { p["from_epic_id"] = old;p["from_epic_revision"] = try scoped(db,old,pid,type:"group")["revision"] }
                _ = try groupWrite(db,p,c,"group_membership")
            } else { var p = input;p["patch"] = ["epic_id":NSNull()];_ = try taskEdit(db,p,c) }
        case "triage":
            let gid = changes["triage_id"] as! String,group = try scoped(db,gid,pid,type:"group")
            guard group["kind"] as? String == "triage" else { throw CoreError("INVALID_INPUT","Choose a Triage.") }
            var p = input;p["group_id"] = gid;p["expected_revision"] = group["revision"];p["expected_task_revision"] = task["revision"];p["action"] = changes["action"]
            for field in ["exit_milestone","handling_phase"] { p[field] = changes[field] }
            _ = try groupWrite(db,p,c,"group_membership")
            // Membership is part of the ticket's revision-checked bulk surface.
            try save(db,revised(task),type:"task")
        default: throw CoreError("INVALID_INPUT","Unsupported bulk change.")
        }
    }

    private func bulkProgress(_ db: Database,task: JSON) throws -> String {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        var values: JSON = [:]
        for key in ["current_manifest_id","acceptance_revision","active_attempt_id","active_verification_request_id"] { values[key] = task[key] ?? NSNull() }
        for type in ["attempt","review_request","review","request"] {
            values[type] = try Row.fetchAll(db,sql:"SELECT id,revision FROM records WHERE project_id=? AND type=? AND json_extract(data,'$.task_id')=? ORDER BY id",arguments:[pid,type,tid]).map { ["id":$0["id"] as String,"revision":$0["revision"] as Int] as JSON }
        }
        return hash(Data(try jsonString(values).utf8))
    }

    private func bulkMemberships(_ db: Database,task: JSON) throws -> [JSON] {
        try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE project_id=? AND type='group' AND json_extract(data,'$.kind')='triage' AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(data,'$.members'))>0 THEN json_extract(data,'$.members') ELSE json_extract(data,'$.task_ids') END) m WHERE CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END=?) ORDER BY id",arguments:[task["project_id"] as! String,task["id"] as! String]).map { try GRDBRecordEnvelopeAdapter.decode($0).object }
    }

    private func performBulk(_ db: Database,_ p: JSON,_ c: Caller,project: String,tasks: [JSON],kind: String,apply: (JSON) throws -> Void) throws -> JSON {
        var rows: [JSON] = []
        for row in tasks {
            var result: JSON = ["task_id":row["task_id"]!,"eligible":false]
            do {
                let before = try scoped(db,row["task_id"] as! String,project,type:"task");result["key"] = before["key"] ?? "Ticket";result["current_revision"] = before["revision"]
                var input = row;input["project_id"] = project
                try withValidatedDomainTransaction(db) { try apply(input);return .rollback }
                result["eligible"] = true
            } catch let error as CoreError { result["reason"] = error.message;result["code"] = error.code }
            rows.append(result)
        }
        let eligible = rows.filter {bool($0,"eligible")}.count,preview = bool(p,"preview",default:true)
        if !preview,eligible != rows.count { throw CoreError("BULK_CONFLICT","Some tickets cannot change. No tickets changed.",details:["rows":rows,"affected_count":eligible]) }
        if !preview {
            for index in tasks.indices {
                let row = tasks[index],before = try scoped(db,row["task_id"] as! String,project,type:"task"),memberships = try bulkMemberships(db,task:before)
                var input = row;input["project_id"] = project;try apply(input)
                let after = try scoped(db,row["task_id"] as! String,project,type:"task")
                rows[index]["before"] = before;rows[index]["after"] = after;rows[index]["after_revision"] = after["revision"]
                rows[index]["before_triages"] = memberships;rows[index]["after_triages"] = try bulkMemberships(db,task:after)
                rows[index]["progress"] = try bulkProgress(db,task:after)
                try event(db,caller:c,project:project,entity:after["id"] as? String,kind:kind == "task_bulk_undo" ? "task_bulk_undone" : "task_bulk_changed",data:["command_id":p["command_id"]!,"change":p["changes"] ?? [:]])
            }
            try event(db,caller:c,project:project,entity:nil,kind:kind,data:["command_id":p["command_id"]!,"affected_count":eligible])
        }
        return ["kind":kind,"project_id":project,"command_id":p["command_id"]!,"preview":preview,"affected_count":eligible,"rows":rows,"changes":p["changes"] ?? [:],"files_notice":"Unarchiving does not restore cleaned files."]
    }

    func taskBulkUndo(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c)
        let pid = try scope(db,p,c,write:true),tasks = try bulkTasks(p),original = try text(p,"original_command_id")
        guard let raw = try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,original]),let receipt = jsonObject(raw)["data"] as? JSON,
              receipt["kind"] as? String == "task_bulk_edit",!bool(receipt,"preview"),SnapshotRecordIdentity(receipt["project_id"] as? String ?? "") == SnapshotRecordIdentity(pid),let rows = receipt["rows"] as? [JSON],let change = receipt["changes"] as? JSON else { throw CoreError("UNDO_UNAVAILABLE","The original bulk receipt is unavailable for this connection and project, or has expired.") }
        let byID = Dictionary(uniqueKeysWithValues:rows.map {(SnapshotRecordIdentity($0["task_id"] as! String),$0)})
        let explanation = try text(p,"reason",max:4000,required:false).trimmingCharacters(in:.whitespacesAndNewlines)
        let reason = "Undo of bulk change \(original)" + (explanation.isEmpty ? "" : ": " + explanation)
        _ = try text(["reason":reason],"reason",max:4000)
        return try performBulk(db,p,c,project:pid,tasks:tasks,kind:"task_bulk_undo") { input in
            guard let row = byID[SnapshotRecordIdentity(input["task_id"] as! String)],let before = row["before"] as? JSON,let after = row["after"] as? JSON else { throw CoreError("UNDO_UNAVAILABLE","This ticket is not in the original bulk receipt.") }
            let current = try self.scoped(db,input["task_id"] as! String,pid,type:"task");try self.revision(input,current)
            guard current["active_attempt_id"] == nil,current["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","This ticket has active work or review. Undo cannot apply.") }
            guard try self.bulkProgress(db,task:current) == row["progress"] as? String else { throw CoreError("UNDO_UNAVAILABLE","Ownership or review advanced after this change. Undo cannot apply.") }
            var compensation = input;compensation["reason"] = reason
            try self.applyBulkUndo(db,compensation,c,before:before,after:after,current:current,change:change,row:row)
        }
    }

    private func bulkEqual(_ a: Any?,_ b: Any?) -> Bool { (try? jsonString(["value":a ?? NSNull()])) == (try? jsonString(["value":b ?? NSNull()])) }

    private func applyBulkUndo(_ db: Database,_ input: JSON,_ c: Caller,before: JSON,after: JSON,current: JSON,change: JSON,row: JSON) throws {
        let kind = change["kind"] as! String,pid = current["project_id"] as! String
        if kind == "triage" {
            let gid = change["triage_id"] as! String,group = try scoped(db,gid,pid,type:"group")
            let prior = (row["before_triages"] as? [JSON] ?? []).first {$0["id"] as? String == gid}
            let later = (row["after_triages"] as? [JSON] ?? []).first {$0["id"] as? String == gid}
            let tid = current["id"] as! String
            let member = (group["members"] as? [JSON] ?? []).first {$0["task_id"] as? String == tid}
            let expectedMember = (later?["members"] as? [JSON] ?? []).first {$0["task_id"] as? String == tid}
            guard bulkEqual(member,expectedMember) else { throw CoreError("UNDO_CONFLICT","This ticket's Triage membership changed after the bulk edit.") }
            let wasMember = prior.map {triageMemberIDs($0).contains(tid)} ?? false
            let priorMember = (prior?["members"] as? [JSON] ?? []).first {$0["task_id"] as? String == tid}
            var compensation: JSON = ["kind":"triage","triage_id":gid,"action":wasMember ? "add" : "remove"]
            for field in ["exit_milestone","handling_phase"] { compensation[field] = priorMember?[field] }
            try applyBulkChange(db,input,c,changes:compensation)
            return
        }
        if kind == "tags" {
            let old = strings(before,"tag_ids"),new = strings(after,"tag_ids")
            let oldIDs = Set(old.map(SnapshotRecordIdentity.init)),newIDs = Set(new.map(SnapshotRecordIdentity.init))
            var tags = strings(current,"tag_ids");tags.removeAll {newIDs.contains(SnapshotRecordIdentity($0)) && !oldIDs.contains(SnapshotRecordIdentity($0))}
            for id in old where !newIDs.contains(SnapshotRecordIdentity(id)) && !tags.contains(where:{SnapshotRecordIdentity($0) == SnapshotRecordIdentity(id)}) {tags.append(id)}
            var p = input;p["patch"] = ["tag_ids":tags];_ = try taskEdit(db,p,c);return
        }
        let fields: [String:[String]] = ["status":["status_id"],"assignee":["planned_assignee"],"epic":["epic_id"],"archive":change["action"] as? String == "trash" || change["action"] as? String == "restore" ? ["trashed"] : ["archived"]]
        guard let selected = fields[kind] else {throw CoreError("UNDO_UNAVAILABLE","This change cannot be undone.")}
        guard selected.allSatisfy({bulkEqual(current[$0],after[$0])}) else {throw CoreError("UNDO_CONFLICT","The changed field was edited again. Undo preserves that newer value.")}
        if kind == "status" {
            guard bulkEqual(before["disposition"],after["disposition"]),bulkEqual(before["duplicate_of_task_id"],after["duplicate_of_task_id"]) else { throw CoreError("UNDO_UNAVAILABLE","Reopening changed this ticket's duplicate links. Restore those links explicitly; bulk Undo cannot recreate them.") }
            var p = input;p["target_status_id"] = before["status_id"]
            _ = try taskTransition(db,p,c);return // An individual status action still departs all current Triages.
        }
        if kind == "epic" { try applyBulkChange(db,input,c,changes:["kind":"epic","epic_id":before["epic_id"] ?? NSNull()]);return }
        if kind == "archive" {
            let trash = selected.contains("trashed"),field = trash ? "trashed" : "archived"
            try applyBulkChange(db,input,c,changes:["kind":"archive","action":trash ? (bool(before,field) ? "trash" : "restore") : (bool(before,field) ? "archive" : "unarchive")])
            if !trash {
                var restored = try scoped(db,current["id"] as! String,pid,type:"task")
                // The timestamp is independent: retain a newer timestamp even while
                // compensating an unchanged archive flag.
                restored["archived_at"] = bulkEqual(current["archived_at"],after["archived_at"]) ? before["archived_at"] : current["archived_at"]
                try save(db,restored,type:"task")
            }
            return
        }
        // Validate present-day assignee eligibility; provenance of the compensation is new.
        let reason = bulkEqual(current["assignment_reason"],after["assignment_reason"]) ? before["assignment_reason"] : current["assignment_reason"]
        try applyBulkChange(db,input,c,changes:["kind":"assignee","planned_assignee":before["planned_assignee"] ?? "unassigned","assignment_reason":reason ?? "Undo bulk assignment"])
        if reason == nil,(before["planned_assignee"] as? JSON)?["kind"] as? String != "agent" {
            var restored = try scoped(db,current["id"] as! String,pid,type:"task")
            restored.removeValue(forKey:"assignment_reason");try save(db,restored,type:"task")
        }
    }
}
