import Foundation
import GRDB

/// CL-427: ticket completion closes linked review records in the same transaction,
/// before Done removes their Triage membership. Bytes remain on the existing
/// backup-protected ticket cleanup path; this file performs no file operations.
extension CommandRouter {
    func mediaTaskDoneActor(_ taskID: String) -> JSON {
        ["actor":"system","actor_kind":"system","origin":"system","at":now(),"reason":taskID,"task_id":taskID]
    }

    /// Explicit links include unpublished items and the round fallback even when
    /// every published item overrides it. Nothing releases originals early.
    func mediaNamedTaskIDs(_ db: Database,round: JSON) throws -> Set<String> {
        var ids = Set(try mediaItems(db,round:round).compactMap {$0["task_id"] as? String})
        if let id = round["task_id"] as? String {ids.insert(id)}
        return ids
    }

    func mediaAllNamedTasksDone(_ db: Database,round: JSON) throws -> Bool {
        let pid = try StoredRecord(round,family:"media_round").string("project_id")
        let ids = try mediaNamedTaskIDs(db,round:round)
        return try !ids.isEmpty && ids.allSatisfy {id in
            let task = try scoped(db,id,pid,type:"task")
            guard let statusID = task["status_id"] as? String else {return false}
            return try scoped(db,statusID,pid,type:"status")["category"] as? String == "done"
        }
    }

    func mediaLinkedTaskCompleted(_ db: Database,task: JSON) throws {
        let tid = try StoredRecord(task,family:"task").string("id"),pid = try StoredRecord(task,family:"task").string("project_id")
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='media_round' AND project_id=CAST(? AS TEXT) AND (json_extract(records.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY OR records.id IN (SELECT json_extract(i.data,'$.round_id') FROM records i WHERE i.type='media_item' AND i.project_id=CAST(? AS TEXT) AND json_extract(i.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY)) ORDER BY id COLLATE BINARY",arguments:[Data(pid.utf8),Data(tid.utf8),Data(pid.utf8),Data(tid.utf8)])
        let system = Caller(role:"owner",installation:"storage",projectIDs:[])
        for row in rows {
            var round = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"media_round").object
            if let cleanup = round["done_task_cleanup"] as? JSON,cleanup["state"] as? String != "deferred" {continue}
            let state = round["state"] as? String ?? ""
            if state == "open" || state == "draft" {
                var dispositions = try mediaRoundDispositionIndex(db,round:round)
                if state == "open",let manifestID = round["manifest_id"] as? String {
                    let manifest = try scoped(db,manifestID,pid,type:"media_round_manifest")
                    let published = Set(try StoredRecord(manifest,family:"media_round_manifest").objects("items").compactMap {$0["item_id"] as? String})
                    dispositions = dispositions.filter {published.contains($0["id"] as? String ?? "")}
                }
                let unresolved = dispositions.filter {!["accepted","excluded","changes_requested","needs_look"].contains($0["disposition"] as? String ?? "")}.count
                if unresolved > 0 {
                    var warnings = round["done_task_warnings"] as? [JSON] ?? (round["done_task_warning"].map {[$0 as? JSON ?? [:]]} ?? [])
                    var changed = false
                    let warned = Set(warnings.compactMap {$0["task_id"] as? String})
                    for taskID in try mediaNamedTaskIDs(db,round:round).subtracting(warned).sorted() {
                        let body = "\(round["title"] as? String ?? "Media round") has \(unresolved) undecided items; it stays open"
                        var input: JSON = ["project_id":pid,"task_id":taskID,"body":body]
                        let namedTask = try scoped(db,taskID,pid,type:"task")
                        if let group = try ticketOrchestratedTriage(db,task:namedTask),triageOrchestratorRecipient(db,group:group) != nil {input["audience"] = "orchestrator"}
                        let note = try messageWrite(db,input,system,"message_send",purpose:.systemNote,literalBody:true)
                        warnings.append(["task_id":taskID,"message_id":note["id"] ?? NSNull(),"at":now(),"undecided_count":unresolved])
                        changed = true
                    }
                    if changed {
                        round["done_task_warnings"] = warnings
                        round["done_task_warning"] = warnings.first
                        round = revised(round);try mediaWrite(db,round,type:"media_round")
                    }
                    continue
                }
                guard try mediaAllNamedTasksDone(db,round:round) else {continue}
                if state == "draft" {
                    // A truly empty Draft has no published manifest to finish.
                    round = try mediaCancelRound(db,round:round,reason:"Linked task \(tid) is Done; empty Draft has no published manifest.",actor:mediaTaskDoneActor(tid))
                } else {
                    let manifest = try scoped(db,try StoredRecord(round,family:"media_round").string("manifest_id"),pid,type:"media_round_manifest")
                    try mediaRecordTaskDoneFollowUps(db,round:round,manifest:manifest,taskID:tid,caller:system)
                    round = try mediaFinishRound(db,["round_id":round["id"]!],system,project:pid,systemTaskID:tid)
                }
            }
            guard try mediaAllNamedTasksDone(db,round:round) else {continue}
            if ["closed","canceled"].contains(round["state"] as? String ?? "") {
                round = try mediaArchiveRound(db,round:round,actor:mediaTaskDoneActor(tid))
            }
            if round["state"] as? String == "archived" {
                do {try mediaHandOffDoneOriginals(db,round:round,taskID:tid)}
                catch let error as CoreError where error.code == "CLEANUP_INVENTORY_LIMIT" {
                    // Cleanup bounds retain bytes; they never reverse ticket
                    // completion or discard the already archived review.
                    round["done_task_cleanup"] = ["task_id":tid,"state":"deferred","reason":error.code,"at":now()]
                    try mediaWrite(db,revised(round),type:"media_round")
                }
            }
        }
    }

    /// The linked ticket's completion is an explicit system reason, never a
    /// fabricated worker decision. Existing exact follow-ups retain precedence.
    private func mediaRecordTaskDoneFollowUps(_ db: Database,round: JSON,manifest: JSON,taskID: String,caller: Caller) throws {
        let pid = try StoredRecord(round,family:"media_round").string("project_id")
        let index = mediaFollowUpIndex(try mediaReworkLinks(db,round:round))
        for member in try StoredRecord(manifest,family:"media_round_manifest").objects("items") {
            let item = try scoped(db,try StoredRecord(member,family:"media_manifest_member").string("item_id"),pid,type:"media_item")
            guard let decisionID = item["last_decision_id"] as? String else {continue}
            let decision = try scoped(db,decisionID,pid,type:"media_owner_decision")
            guard decision["disposition"] as? String == "changes_requested",mediaFollowUpResolution(db,decision:decision,index:index,project:pid) == nil else {continue}
            let linkedTaskID = item["task_id"] as? String ?? round["task_id"] as? String ?? taskID
            var link = mediaRecord(["round_id":round["id"]!,"item_id":item["id"]!,"decision_id":decisionID,
                "target_id":member["target_id"]!,"review_basis_signature":member["review_basis_signature"]!,"manifest_id":manifest["id"]!,
                "state":"worker_reason","follow_up_reason":"Linked task \(linkedTaskID) is Done.","system_task_id":linkedTaskID],project:pid,caller:caller,
                references:[try mediaRef("media_round",round),try mediaRef("media_item",item),try mediaRef("media_owner_decision",decision),
                    ["type":"media_item_target","id":member["target_id"]!,"revision":1],try mediaRef("media_round_manifest",manifest),["type":"task","id":linkedTaskID]])
            link["origin"] = "system";link["author"] = "system";link["author_session_id"] = "system";link["actor"] = mediaTaskDoneActor(linkedTaskID)
            try mediaWrite(db,link,type:"media_rework_link")
        }
    }

    /// Structural ownership only. References to a predecessor, approved example
    /// or another round do not bring that independent history into this handoff.
    private func mediaRoundOwnedHistory(_ db: Database,round: JSON) throws -> [JSON] {
        let pid = try StoredRecord(round,family:"media_round").string("project_id"),rid = try StoredRecord(round,family:"media_round").string("id")
        let families = MediaRecordRegistry.families.sorted().map {"'" + $0 + "'"}.joined(separator:",")
        // Materialize structural edges once; a large round must not rescan the
        // project's record corpus for each item in the recursive walk.
        let sql = "WITH RECURSIVE edges(parent,child) AS MATERIALIZED (SELECT CAST(j.value AS TEXT),r.id FROM records r,json_each(json_array(json_extract(r.data,'$.round_id'),json_extract(r.data,'$.item_id'),json_extract(r.data,'$.intake_id'),json_extract(r.data,'$.operation_id'))) j WHERE r.type IN (" + families + ") AND r.project_id=CAST(? AS TEXT) AND j.type='text'),media_history(id) AS (SELECT CAST(? AS TEXT) UNION SELECT e.child FROM media_history p JOIN edges e ON e.parent=p.id COLLATE BINARY) SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id IN (SELECT id FROM media_history) ORDER BY id COLLATE BINARY LIMIT 100001"
        let rows = try Row.fetchAll(db,sql:sql,arguments:[Data(pid.utf8),Data(rid.utf8)])
        guard rows.count <= 100000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The media handoff exceeds its bounded history inventory; originals retained.")}
        return try rows.map {var value = try GRDBRecordEnvelopeAdapter.decode($0).object;value["record_type"] = $0["type"] as String;return value}
    }

    private func mediaHandOffDoneOriginals(_ db: Database,round original: JSON,taskID: String) throws {
        var round = original
        let pid = try StoredRecord(round,family:"media_round").string("project_id"),history = try mediaRoundOwnedHistory(db,round:round)
        var historyRecords = Dictionary(uniqueKeysWithValues:history.compactMap {value -> (String,JSON)? in (value["id"] as? String).map {($0,value)}})
        let itemIDs = Set(history.filter {$0["record_type"] as? String == "media_item"}.compactMap {$0["id"] as? String})
        var ownerIDs = Set(history.compactMap {$0["attachment_owner_id"] as? String}),attachmentIDs = Set<String>()
        for value in history {
            for ref in value["record_references"] as? [JSON] ?? [] {
                guard let id = ref["id"] as? String,let type = ref["type"] as? String else {continue}
                if type == "attachment" {attachmentIDs.insert(id)}
                if type == "storage_job" || type == "storage_hold" {
                    var stored = try scoped(db,id,pid,type:type);stored["record_type"] = type;historyRecords[id] = stored
                    if stored["kind"] as? String == "media_attachment_owner" {ownerIDs.insert(id)}
                    if let ownerID = stored["attachment_owner_id"] as? String {ownerIDs.insert(ownerID)}
                }
            }
        }
        // A successor Draft can share its predecessor's exact published owner.
        // Its independent reference wins even before that successor publishes.
        let foreignOwners = Set(try String.fetchAll(db,sql:"SELECT DISTINCT json_extract(t.data,'$.attachment_owner_id') FROM records t JOIN records i ON i.id=json_extract(t.data,'$.item_id') AND i.type='media_item' AND i.project_id=t.project_id JOIN records r ON r.id=json_extract(i.data,'$.round_id') AND r.type='media_round' AND r.project_id=i.project_id WHERE t.type='media_item_target' AND t.project_id=CAST(? AS TEXT) AND json_extract(t.data,'$.attachment_owner_id') IN (SELECT value FROM json_each(?)) AND json_extract(t.data,'$.item_id') NOT IN (SELECT value FROM json_each(?)) AND NOT (json_extract(r.data,'$.state')='archived' AND COALESCE(json_extract(r.data,'$.done_task_cleanup.state'),'')='handed_off')",arguments:[Data(pid.utf8),try jsonString(ownerIDs.sorted()),try jsonString(itemIDs.sorted())]))
        for ownerID in ownerIDs {
            var anchor = try scoped(db,ownerID,pid,type:"storage_job");anchor["record_type"] = "storage_job";historyRecords[ownerID] = anchor
            let references = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='storage_hold' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.kind')='media_reference' AND json_extract(data,'$.owner_id')=CAST(? AS TEXT) COLLATE BINARY",arguments:[Data(pid.utf8),Data(ownerID.utf8)])
            for raw in references {
                var reference = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"storage_hold").object
                let id = try StoredRecord(reference,family:"media_reference").string("id")
                if let aid = reference["attachment_id"] as? String {attachmentIDs.insert(aid)}
                if reference["state"] as? String == "active",!foreignOwners.contains(ownerID) {
                    reference["state"] = "released";reference["released_by"] = mediaTaskDoneActor(taskID)
                    reference = revised(reference);try save(db,reference,type:"storage_hold")
                }
                reference["record_type"] = "storage_hold";historyRecords[id] = reference
            }
        }
        var handed: [String] = [],managed: [String] = [],cleanupTasks = Set<String>()
        for id in attachmentIDs.sorted() {
            var attachment = try scoped(db,id,pid,type:"attachment")
            guard attachment["mode"] as? String == "managed" else {continue}
            managed.append(id)
            // An adopted ticket attachment keeps its independent source ticket.
            // Taskless captures join the ordinary Done-ticket ownership path.
            let needsTask = attachment["task_id"] == nil,needsMarker = attachment["media_cleanup_round_id"] == nil
            if needsTask || needsMarker {
                if needsTask {attachment["task_id"] = taskID}
                if needsMarker {attachment["media_cleanup_round_id"] = round["id"]}
                try save(db,revised(attachment),type:"attachment")
            }
            if attachment["task_id"] as? String == taskID {handed.append(id)}
            if let ownerTask = attachment["task_id"] as? String {cleanupTasks.insert(ownerTask)}
        }
        round["done_task_cleanup"] = ["task_id":taskID,"state":"handed_off","at":now(),"record_ids":historyRecords.keys.sorted(),"attachment_ids":handed,"managed_attachment_ids":managed]
        try mediaWrite(db,revised(round),type:"media_round")
        // Releasing a shared media owner can make a different Done ticket's
        // original eligible. Wake that ticket's existing cleanup planner once.
        let clock = Date();var retries = try ticketCleanupRetryEntries(db,project:pid)
        for ownerTask in cleanupTasks {
            let value = try scoped(db,ownerTask,pid,type:"task")
            if (try scoped(db,try StoredRecord(value,family:"task").string("status_id"),pid,type:"status"))["category"] as? String == "done" {retries[ownerTask] = TicketCleanupRetry(at:clock)}
        }
        try saveTicketCleanupRetries(db,project:pid,entries:retries)
        let prior = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + pid]) ?? "0") ?? 0
        try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(min(prior,clock.timeIntervalSince1970))])
        try event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:pid,entity:round["id"] as? String,kind:"media_round_task_done",data:["actor":"system","reason":taskID,"task_id":taskID,"attachment_ids":handed])
    }

    /// Only the archived round's exact retained handoff records are historical
    /// byte owners. They never become ticket-purge record-removal ownership.
    func mediaDoneCleanupHistory(_ db: Database,task: JSON) throws -> [PurgeRow] {
        let tid = try StoredRecord(task,family:"task").string("id"),pid = try StoredRecord(task,family:"task").string("project_id")
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='media_round' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.state')='archived' AND (json_extract(data,'$.done_task_cleanup.task_id')=CAST(? AS TEXT) COLLATE BINARY OR EXISTS (SELECT 1 FROM json_each(records.data,'$.done_task_cleanup.managed_attachment_ids') a JOIN records f ON f.id=a.value AND f.type='attachment' AND f.project_id=records.project_id WHERE json_extract(f.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY))",arguments:[Data(pid.utf8),Data(tid.utf8),Data(tid.utf8)])
        var ids = Set<String>()
        for row in rows {
            let round = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"media_round").object,cleanup = round["done_task_cleanup"] as? JSON ?? [:]
            if cleanup["state"] as? String == "deferred" {throw CoreError("CLEANUP_INVENTORY_LIMIT","The media handoff is deferred; originals retained.")}
            ids.formUnion(strings(cleanup,"record_ids"))
        }
        guard ids.count <= 4096 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The media handoff exceeds the cleanup inventory; bytes retained.")}
        return try ids.sorted().map {id in
            let value = try record(db,id),type = try String.fetchOne(db,sql:"SELECT type FROM records WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)]) ?? ""
            guard value["project_id"] as? String == pid,MediaRecordRegistry.families.contains(type) || ["storage_job","storage_hold"].contains(type) else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A media cleanup history record is unavailable.")}
            return PurgeRow(id:id,type:type,project:pid,value:value)
        }
    }
}
