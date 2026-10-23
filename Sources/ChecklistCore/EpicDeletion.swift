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
        try epicReferenceIndex.requireReady(db,router:self)
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        return try EpicReferenceIndex.withBudget(db,seconds:0.25) {
            let arguments: StatementArguments = [Data(pid.utf8),Data(gid.utf8)]
            let current = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_members WHERE project=? AND epic=?)",arguments:arguments) ?? false
            guard !current,strings(group,"task_ids").isEmpty,(group["members"] as? [JSON] ?? []).isEmpty else {
                throw CoreError("EPIC_HAS_TICKETS","This Epic currently holds tickets. Archive it instead; deleting a previously used Epic is not allowed.")
            }
            let events = try Row.fetchAll(db,sql:"SELECT id,kind FROM events WHERE project_id=CAST(? AS TEXT) AND entity_id=CAST(? AS TEXT) ORDER BY seq LIMIT 10001",arguments:arguments)
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
            // Each target lookup uses the reverse-reference index. Scope the own
            // history through events_scope; retain incoming links even from foreign
            // projects and ticketless/global records (the r1 safety contract).
            for target in [gid] + events.map({$0["id"] as String}) {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {throw EpicReferenceIndex.budgetFailure()}
                let referenced = try Bool.fetchOne(db,sql:"""
                    SELECT EXISTS(SELECT 1 FROM epic_guard_refs INDEXED BY epic_guard_incoming
                    WHERE target=? AND NOT (
                      (source_kind=0 AND source_id=?) OR
                      (source_kind=1 AND EXISTS (
                        SELECT 1 FROM events e WHERE e.id=CAST(epic_guard_refs.source_id AS TEXT)
                        AND e.project_id=CAST(? AS TEXT) AND e.entity_id=CAST(? AS TEXT)))))
                    """,arguments:[Data(target.utf8),Data(gid.utf8),Data(pid.utf8),Data(gid.utf8)]) ?? true
                guard !referenced else { throw CoreError("EPIC_REFERENCED","Another record or history entry references this Epic or its events. Nothing was removed; retain the Epic.") }
            }
            let result: JSON = ["deleted":true,"epic_id":gid,"key":group["key"] ?? "","name":group["name"] ?? "","expected_revision":int(group,"revision"),"origin":c.isOwner ? "human_ui" : "agent","actor":c.principal,"actor_display":author(db,c)]
            try db.execute(sql:"DELETE FROM events WHERE project_id=CAST(? AS TEXT) AND entity_id=CAST(? AS TEXT)",arguments:arguments)
            try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND type='group'",arguments:[Data(gid.utf8)])
            try event(db,caller:c,project:pid,entity:pid,kind:"epic_deleted",data:result)
            return result
        }
    }
}
