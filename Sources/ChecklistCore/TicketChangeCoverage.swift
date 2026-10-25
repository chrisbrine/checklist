import Foundation
import GRDB

extension CommandRouter {
    func ownerChangeCoverageRequested(_ p: JSON, _ c: Caller) throws -> Bool {
        guard let value = p["include_coverage"] else { return false }
        try owner(c)
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CoreError("INVALID_INPUT", "include_coverage must be a boolean.")
        }
        return number.boolValue
    }
    /// Bounded affected-projection coverage. Unknown kinds/removed entities dirty
    /// their whole project; incomplete catch-up resets all. No event is skipped
    /// because its kind was new, and no message body/private sequence is exposed.
    func ticketChangeCoverage(_ db: Database, after: Int, through: Int) throws -> JSON {
        let rows = try Row.fetchAll(db,sql:"SELECT CAST(project_id AS BLOB) AS project_bytes,CAST(entity_id AS BLOB) AS entity_bytes,kind FROM events WHERE seq>? AND seq<=? ORDER BY seq LIMIT 1001",arguments:[after,through])
        struct Coverage {let project:String;var families=Set<String>();var tasks:[String]=[];var seen=Set<SnapshotRecordIdentity>();var allTasks=false}
        var projects:[SnapshotRecordIdentity:Coverage]=[:],order:[SnapshotRecordIdentity]=[]
        var reset = after == 0 || rows.count > 1000 || through < after
        for row in rows.prefix(1000) {
            guard let bytes=row["project_bytes"] as Data?,let project=String(data:bytes,encoding:.utf8) else { reset = true; continue }
            let key=SnapshotRecordIdentity(project)
            if projects[key] == nil {projects[key]=Coverage(project:project);order.append(key)}
            var coverage=projects[key]!
            let kind=row["kind"] as String
            let family:Set<String>
            if ["work_checkpoint","checkpoint_recorded","work_scopes_adjusted","review_evidence_added"].contains(kind) {family=["work"]}
            else if kind.hasPrefix("message_") || kind.hasPrefix("delivery_") || kind=="native_reply_received" {family=["messages"]}
            else if kind.hasPrefix("human_request_") || kind.hasPrefix("human_approval_") {family=["requests","work","tasks"]}
            else if kind.hasPrefix("attachment_") || kind.hasPrefix("source_execution_") {family=["attachments","work"]}
            else if kind.hasPrefix("task_") || kind.hasPrefix("work_") || kind.hasPrefix("review_") || kind=="claim_revoked" {family=["tasks","work","groups"]}
            else if kind.hasPrefix("relation") || kind.hasPrefix("epic_") || kind.hasPrefix("triage_") || kind.hasPrefix("group_") || kind=="duplicate_reopened" {family=["tasks","groups","work"];coverage.allTasks=true}
            else {family=["all"];coverage.allTasks=true}
            coverage.families.formUnion(family)
            if let raw=row["entity_bytes"] as Data?,let entity=String(data:raw,encoding:.utf8),
               let recordRow=try Row.fetchOne(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT)",arguments:[raw,bytes]) {
                let record=try GRDBRecordEnvelopeAdapter.decode(recordRow)
                let tid=record.type=="task" ? entity : record.object["task_id"] as? String
                if let tid {
                    if coverage.seen.insert(SnapshotRecordIdentity(tid)).inserted {coverage.tasks.append(tid)}
                    if family.contains("tasks") {
                        // A prerequisite change affects its dependent rows even
                        // when the dependent task's own revision did not change.
                        let dependents=try Row.fetchAll(db,sql:"SELECT CAST(json_extract(data,'$.source_task_id') AS BLOB) AS source FROM records WHERE type='relation' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.target_task_id')=CAST(? AS TEXT) COLLATE BINARY AND COALESCE(json_extract(data,'$.state'),'')<>'removed'",arguments:[bytes,Data(tid.utf8)])
                        for row in dependents {if let data=row["source"] as Data?,let id=String(data:data,encoding:.utf8),coverage.seen.insert(SnapshotRecordIdentity(id)).inserted {coverage.tasks.append(id)}}
                    }
                } else {coverage.allTasks=true}
            } else {coverage.allTasks=true}
            projects[key]=coverage
        }
        let changes:[JSON]=order.compactMap {key in guard let value=projects[key] else{return nil};return ["project_id":value.project,"families":value.families.sorted(),"task_ids":value.tasks,"all_tasks":value.allTasks]}
        var result: JSON = ["schema_version":2,"complete":true,"reset":reset,"project_ids":reset ? [] : changes.map {$0["project_id"]!},"changes":reset ? [] : changes]
        // A bounded status-only projection shares this read transaction and its
        // authority with coverage. No task text/history or global sequence escapes.
        let affected = changes.filter { !Set($0["families"] as? [String] ?? []).isDisjoint(with:["tasks","all"]) && !($0["task_ids"] as? [String] ?? []).isEmpty }
        let count = affected.reduce(0) {$0 + ($1["task_ids"] as? [String] ?? []).count}
        if !reset, count <= 100 {
            var updates: [JSON] = []
            var membershipLinks = 0
            for change in affected {
                let project = change["project_id"] as! String
                let tasks = change["task_ids"] as? [String] ?? []
                let projects = try jsonString([project])
                let arguments: StatementArguments = ["projects":projects,"ids":try jsonString(tasks),
                    "quietBefore":Date().timeIntervalSince1970 - Self.quietCheckpointSeconds,
                    "todayStart":Calendar.current.startOfDay(for:Date()).timeIntervalSince1970]
                var membership: [SnapshotRecordIdentity:[String]] = [:]
                for surface in Self.needSurfaces {
                    let matches = try String.fetchAll(db,sql:"SELECT r.id FROM records r WHERE r.project_id IN (SELECT value FROM json_each(:projects)) AND r.id IN (SELECT value FROM json_each(:ids)) AND " + Self.needFilter(surface),arguments:arguments)
                    for id in matches {membership[SnapshotRecordIdentity(id),default:[]].append(surface)}
                }
                // Same current-membership expression as the bounded Tickets read.
                // Project-scoped SQL reads identities/counts only, not rich group history.
                let memberArray = "CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END"
                let memberID = "CASE WHEN j.type='object' THEN json_extract(j.value,'$.task_id') ELSE j.value END"
                let memberCountID = "CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END"
                let links = try Row.fetchAll(db,sql:"""
                    SELECT DISTINCT CAST(g.id AS BLOB) group_bytes,g.revision,
                      CAST(\(memberID) AS BLOB) task_bytes,
                      (SELECT COUNT(DISTINCT CAST(\(memberCountID) AS BLOB)) FROM json_each(\(memberArray)) m) member_count
                    FROM records g,json_each(\(memberArray)) j
                    WHERE g.type='group' AND g.project_id=CAST(:project AS TEXT)
                      AND json_extract(g.data,'$.kind')='triage'
                      AND (\(memberID)) COLLATE BINARY IN (SELECT value FROM json_each(:ids))
                    LIMIT 101
                    """,arguments:["project":Data(project.utf8),"ids":try jsonString(tasks)])
                var triages: [SnapshotRecordIdentity:[JSON]] = [:]
                for link in links {
                    guard let groupBytes = link["group_bytes"] as Data?,let group = String(data:groupBytes,encoding:.utf8),
                          let taskBytes = link["task_bytes"] as Data?,let task = String(data:taskBytes,encoding:.utf8) else {continue}
                    triages[SnapshotRecordIdentity(task),default:[]].append(["id":group,"revision":link["revision"] as Int,"member_count":link["member_count"] as Int])
                }
                membershipLinks += links.count
                for id in tasks {
                    guard let task = try? scoped(db,id,project,type:"task"),
                          let statusID = task["status_id"] as? String,
                          let status = try? scoped(db,statusID,project,type:"status") else {continue}
                    let value: JSON = ["id":id,"project_id":project,"revision":task["revision"] ?? 1,
                        "status_id":statusID,"status_name":status["name"] ?? status["label"] ?? "",
                        "status_category":status["category"] ?? "",
                        "archived":bool(task,"archived"),"trashed":bool(task,"trashed")]
                    updates.append(["task":value,"surfaces":membership[SnapshotRecordIdentity(id)] ?? [],"triages":triages[SnapshotRecordIdentity(id)] ?? []])
                }
            }
            // Large fan-out keeps task status delivery but falls back to page
            // reads for headers rather than publishing incomplete membership.
            if membershipLinks > 100 {updates = updates.map {$0.filter {$0.key != "triages"}}}
            result["store_incarnation"] = incarnation
            result["status_updates"] = updates
        }
        return result
    }
}
