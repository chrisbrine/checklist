import Foundation
import GRDB

extension CommandRouter {
    func epicDelete(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c)
        let pid = try scope(db,p,c,write:true)
        try requireAgentEditAuthority(db,project:record(db,pid,type:"project"),caller:c)
        let gid = try text(p,"epic_id"),group = try scoped(db,gid,pid,type:"group")
        guard group["kind"] as? String == "epic" else { throw CoreError("INVALID_INPUT","Only an Epic can be deleted with epic_delete.") }
        try revision(p,group)
        let arguments: StatementArguments = [Data(gid.utf8)]
        let current = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE type='task' AND json_extract(data,'$.epic_id')=CAST(? AS TEXT) COLLATE BINARY)",arguments:arguments) ?? false
        guard !current,strings(group,"task_ids").isEmpty,(group["members"] as? [JSON] ?? []).isEmpty else {
            throw CoreError("EPIC_HAS_TICKETS","This Epic currently holds tickets. Archive it instead; deleting a previously used Epic is not allowed.")
        }
        let events = try Row.fetchAll(db,sql:"SELECT kind,data FROM events WHERE entity_id=CAST(? AS TEXT) ORDER BY seq LIMIT 10001",arguments:arguments)
        guard events.count <= 10000 else { throw CoreError("EPIC_HISTORY_UNPROVEN","The Epic's history exceeds the safe deletion limit. Nothing was removed.") }
        guard !bool(group,"has_held_ticket"),!events.contains(where: { ($0["kind"] as String).hasPrefix("epic_member_") || $0["kind"] as String == "epic_task_moved_out" }) else {
            throw CoreError("EPIC_HELD_TICKETS","This Epic previously held a ticket. Its membership history must be retained; archive it instead.")
        }
        // Older task_create/task_edit paths incremented the Epic revision without
        // a membership event. Never infer 'never used' from an empty current list
        // or expiring command receipts. Unexplained legacy revisions fail closed.
        let kinds = events.map { $0["kind"] as String }
        guard kinds.filter({$0 == "epic_created"}).count == 1,
              kinds.allSatisfy({["epic_created","group_edited"].contains($0)}),
              int(group,"revision") == 1 + kinds.filter({$0 == "group_edited"}).count else {
            throw CoreError("EPIC_HISTORY_UNPROVEN","Retained history cannot prove this Epic never held a ticket. Nothing was removed; archive it instead.")
        }
        // References to either the Epic or an event being removed must survive.
        // Search structural IDs (including dictionary keys), never prose matches.
        // Command receipts are retry/audit snapshots, not domain references, and
        // remain byte-for-byte unchanged under ordinary receipt retention.
        let targets = "WITH targets(id) AS (SELECT CAST(? AS TEXT) UNION SELECT id FROM events WHERE entity_id=CAST(? AS TEXT)) "
        let referenceArguments: StatementArguments = [Data(gid.utf8),Data(gid.utf8),Data(gid.utf8)]
        for (table,exclusion) in [("records","r.id != CAST(? AS TEXT)"),("events","r.entity_id IS NULL OR r.entity_id != CAST(? AS TEXT)")] {
            let entityReference = table == "events" ? "r.entity_id IN (SELECT id FROM targets) OR " : ""
            let referenced = try Bool.fetchOne(db,sql:targets + "SELECT EXISTS(SELECT 1 FROM " + table + " r WHERE (" + exclusion + ") AND (" + entityReference + "EXISTS(SELECT 1 FROM json_tree(r.data) j JOIN targets t ON (j.type='text' AND j.value=t.id COLLATE BINARY) OR j.key=t.id COLLATE BINARY)))",arguments:referenceArguments) ?? false
            guard !referenced else { throw CoreError("EPIC_REFERENCED","Another record or history entry references this Epic or its events. Nothing was removed; retain the Epic.") }
        }
        let result: JSON = ["deleted":true,"epic_id":gid,"key":group["key"] ?? "","name":group["name"] ?? "","expected_revision":int(group,"revision"),"origin":c.isOwner ? "human_ui" : "agent","actor":c.principal,"actor_display":author(db,c)]
        try db.execute(sql:"DELETE FROM events WHERE entity_id=CAST(? AS TEXT)",arguments:arguments)
        try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND type='group'",arguments:arguments)
        try event(db,caller:c,project:pid,entity:pid,kind:"epic_deleted",data:result)
        return result
    }
}
