import Foundation
import CoreFoundation
import GRDB

/// Lifecycle policy only. CL-24 owns record removal; CL-154 owns every unlink.
/// All state uses project JSON, metadata and existing ticket_object_delete jobs.
extension CommandRouter {
    // Return a fresh schema value; no shared Any payload crosses concurrent reads.
    static var ticketCleanupSchema: JSON { ["type":"object","additionalProperties":false,
        "required":["done_evidence_enabled","closed_purge_enabled","closed_days"],
        "properties":["done_evidence_enabled":["type":"boolean"],"closed_purge_enabled":["type":"boolean"],"closed_days":["type":"integer","minimum":1,"maximum":36500]]] }

    func ticketCleanupSettings(_ project: JSON) -> JSON {
        guard let raw = project["ticket_cleanup"] else {return ["done_evidence_enabled":true,"closed_purge_enabled":true,"closed_days":15]}
        // Unknown persisted policy cannot grant deletion authority.
        return (try? validateTicketCleanupSettings(raw)) ?? ["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]
    }
    func validateTicketCleanupSettings(_ raw: Any) throws -> JSON {
        guard let value = raw as? JSON,Set(value.keys) == ["done_evidence_enabled","closed_purge_enabled","closed_days"],
              let done = value["done_evidence_enabled"] as? NSNumber,CFGetTypeID(done) == CFBooleanGetTypeID(),
              let purge = value["closed_purge_enabled"] as? NSNumber,CFGetTypeID(purge) == CFBooleanGetTypeID(),
              let days = value["closed_days"] as? NSNumber,CFGetTypeID(days) != CFBooleanGetTypeID(),
              days.doubleValue.rounded() == days.doubleValue,(1...36500).contains(days.intValue) else {
            throw CoreError("INVALID_INPUT","Ticket cleanup needs two Boolean switches and closed_days from 1 through 36500.")
        }
        return ["done_evidence_enabled":done.boolValue,"closed_purge_enabled":purge.boolValue,"closed_days":days.intValue]
    }

    func ticketCleanupRead(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c)
        var result = try ticketCleanupReceiptPage(db,p,c,pid)
        result["maintenance"] = try ticketCleanupMaintenanceProjection(db,project:pid)
        return result
    }

    private func ticketCleanupMaintenanceProjection(_ db: Database,project: String) throws -> JSON {
        var value = try ticketCleanupSchedulingProjection(db,project:project)
        var preparation = try ticketCleanupPreparationState(db,project:project)
        preparation.removeValue(forKey:"attempt_refused");value["preparation"] = preparation
        return value
    }
    private func ticketCleanupSchedulingProjection(_ db: Database,project: String) throws -> JSON {
        let format = ISO8601DateFormatter(),settings = ticketCleanupSettings(try record(db,project,type:"project"))
        if !bool(settings,"done_evidence_enabled") && !bool(settings,"closed_purge_enabled") {return ["state":"disabled","next_check_at":NSNull()]}
        if try StorageSnapshotRetention.isActive(root:root) {
            return ["state":"paused","reason":"snapshot_retention","resume_condition":"snapshot_retention_released",
                    "resume_at":NSNull(),"next_check_at":format.string(from:Date().addingTimeInterval(60))]
        }
        if let retry = try ticketCleanupProjectRetry(db,project:project),retry > Date() {
            return ["state":"deferred","reason":try ticketCleanupPreparationState(db,project:project)["last_failure_reason"] ?? "cleanup_preparation_unavailable","next_check_at":format.string(from:retry)]
        }
        if let retry = ticketCleanupRetryAt,retry > Date() {
            return ["state":"deferred","reason":ticketCleanupFailure ?? "cleanup_preparation_unavailable","next_check_at":format.string(from:retry)]
        }
        if let resume = ticketCleanupYieldAt,resume > Date() {
            return ["state":"scheduled","reason":"maintenance_yield","next_check_at":format.string(from:resume)]
        }
        let next = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + project]) ?? "0") ?? 0
        return ["state":next <= Date().timeIntervalSince1970 ? "due" : "scheduled","next_check_at":format.string(from:Date(timeIntervalSince1970:max(next,Date().timeIntervalSince1970)))]
    }

    private func ticketCleanupCursor(_ db: Database,_ pid: String) throws -> Int64 {
        Int64(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:" + pid]) ?? "0") ?? 0
    }

    /// Read-snapshot preparation only: up to 32 tickets with independent fences.
    /// The maintenance lane yields the writer and service queue between chunks.
    func ticketCleanupSelection(_ db: Database,project: JSON,at time: Date = Date(),observePhase: ((String) -> Void)? = nil) throws -> TicketCleanupPreparedPass {
        let pid = (try StoredRecord(project, family: "project").string("id")), settings = ticketCleanupSettings(project), cursor = try ticketCleanupCursor(db, pid)
        let retryEntries = try ticketCleanupRetryEntries(db,project:pid),retryState = retryEntries.mapValues(\.deadline)
        let scheduled = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + pid]) ?? "0") ?? 0
        let sweepDeadline = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-sweep-next:" + pid]) ?? "0") ?? 0
        let sweepDue = cursor > 0 || scheduled == 0 || sweepDeadline <= time.timeIntervalSince1970
        // A stream of Done wakes must not consume every ordinary scan slot.
        let dueRetries = retryState.filter {$0.value <= time.timeIntervalSince1970}.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        }.prefix(sweepDue ? 16 : 32).map(\.key)
        var retryRows: [Row] = []
        for id in dueRetries {
            if let row = try Row.fetchOne(db,sql:"SELECT rowid AS cleanup_row," + Self.canonicalRecordColumns + " FROM records WHERE type='task' AND project_id=? AND id=CAST(? AS TEXT)",arguments:[pid,Data(id.utf8)]) {retryRows.append(row)}
        }
        let retryOnly = !dueRetries.isEmpty && !sweepDue
        let scanRows = retryOnly ? [] : try Row.fetchAll(db,sql:"SELECT rowid AS cleanup_row," + Self.canonicalRecordColumns + " FROM records WHERE type='task' AND project_id=? AND rowid>? ORDER BY rowid LIMIT ?",arguments:[pid,cursor,32-retryRows.count])
        let retryIDs = Set(dueRetries)
        let rows = retryRows + scanRows.filter { !retryIDs.contains($0["id"] as String) }
        let tasks = try rows.map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        observePhase?("selected_tickets")
        // Retain clocks only for the selected closed tickets, never every event
        // entity in the project. Empty/open chunks need no history observation.
        let clockIDs = tasks.compactMap {task -> String? in
            guard !bool(task,"purged"),let tid = task["id"] as? String,let statusID = task["status_id"] as? String,
                  let category = (try? record(db,statusID,type:"status"))?["category"] as? String,["done","canceled"].contains(category) else {return nil}
            return tid
        }
        let clockRows = clockIDs.isEmpty ? [] : try Row.fetchAll(db,sql:"SELECT entity_id,MAX(occurred_at) AS changed FROM events WHERE project_id=? AND CAST(entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) AND kind NOT IN ('attachment_original_cleaned','attachment_original_missing') GROUP BY CAST(entity_id AS BLOB)",arguments:[pid,try jsonString(clockIDs)])
        let eventTimes = Dictionary(uniqueKeysWithValues:clockRows.compactMap {row -> (Data,String)? in
            guard let entity: String = row["entity_id"],let changed: String = row["changed"] else {return nil}
            return (Data(entity.utf8),changed)
        })
        observePhase?("closed_clocks")
        let jobTasks = bool(settings,"done_evidence_enabled") ? tasks.filter {task in
            guard !bool(task,"purged"),retryState[task["id"] as? String ?? ""].map({$0 <= time.timeIntervalSince1970}) ?? true,
                  (try? record(db,task["status_id"] as? String ?? "",type:"status"))?["category"] as? String == "done" else {return false}
            let clocks = [task["updated_at"] as? String,eventTimes[Data((task["id"] as? String ?? "").utf8)]].compactMap {$0}
            let dates = clocks.compactMap {ISO8601DateFormatter().date(from:$0)}
            if bool(settings,"closed_purge_enabled"),task["updated_at"] is String,dates.count == clocks.count,
               let changed = dates.max(),changed.addingTimeInterval(Double(int(settings,"closed_days")) * 86400) <= time {return false}
            return true
        } : []
        let jobObservation = try ticketCleanupJobObservation(db,tasks:jobTasks)
        observePhase?("selected_jobs")
        let candidates = tasks.filter {task in
            guard retryState[task["id"] as? String ?? ""].map({$0 <= time.timeIntervalSince1970}) ?? true,!bool(task,"purged"),let statusID = task["status_id"] as? String else {return false}
            let category = (try? record(db,statusID,type:"status"))?["category"] as? String
            guard ["done","canceled"].contains(category ?? "") else {return false}
            let clocks = [task["updated_at"] as? String,eventTimes[Data((task["id"] as? String ?? "").utf8)]].compactMap {$0}
            let dates = clocks.compactMap {ISO8601DateFormatter().date(from:$0)}
            if bool(settings,"closed_purge_enabled"),task["updated_at"] is String,dates.count == clocks.count,
               let changed = dates.max(),changed.addingTimeInterval(Double(int(settings,"closed_days")) * 86400) <= time {return true}
            guard category == "done",bool(settings,"done_evidence_enabled") else {return false}
            // Existing pending byte jobs already carry their durable objects;
            // they need a continuation, not another full planning observation.
            return (try? jobObservation.entry(task:task["id"] as? String ?? "",project:pid).pending) == false
        }
        var batch = try ticketCleanupInventories(db,tasks:candidates)
        observePhase?("inventories")
        var candidateObjects: [String:[JSON]] = [:],referenceGraphs: [String:TicketPurgeReferenceGraph] = [:],candidateBytes = 0
        for task in candidates {
            let tid = try StoredRecord(task,family:"task").string("id")
            guard let inventory = batch.inventories[tid] else {continue}
            do {
                let graph = try ticketPurgeReferenceGraph(task:task,inventory:inventory)
                let objects = try ticketObjectDeletionObjects(db,owned:inventory.rows.filter {graph.owned.contains($0.key)}.map {($0.type,$0.value)})
                let bytes = try jsonString(objects).utf8.count
                guard candidateBytes + bytes <= TicketCleanupBatchInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected cleanup descriptors exceed their memory bound; this ticket is deferred.")}
                candidateBytes += bytes;candidateObjects[tid] = objects;referenceGraphs[tid] = graph
            } catch let error as CoreError {batch.errors[tid] = error}
        }
        observePhase?("candidate_objects")
        let summaries = candidateObjects.isEmpty ? [] : try Row.fetchAll(db,sql:"SELECT json_object('known_at',json_extract(value,'$.known_at'),'created_at',json_extract(value,'$.created_at')) AS value FROM metadata WHERE key LIKE 'backup-generation:%' ORDER BY key").map {jsonObject($0["value"])}
        let backupObservation = TicketCleanupBackupObservation(index:candidateObjects.isEmpty ? nil : observeTicketCleanupBackupRetentionIndex(db,objects:candidateObjects.values.flatMap {$0}),summaries:summaries)
        let mediaAuthorityComplete = !candidateObjects.isEmpty && (try? ticketCleanupValidateMediaAuthority(db)) != nil
        observePhase?("backup_media")
        let historyObservation = try ticketCleanupEventObservation(db,tasks:candidates.filter {batch.errors[$0["id"] as? String ?? ""] == nil},inventories:batch.inventories,referenceGraphs:referenceGraphs)
        observePhase?("events")
        var items: [JSON] = [],plans: [String:TicketPurgePlan] = [:],expired: [String:[Row]] = [:],itemFences: [String:TicketCleanupFence] = [:]
        var inventory: TicketCleanupInventory?,planningRetries: [String] = []
        func plan(_ task: JSON,doneEvidence: Bool = false) throws -> TicketPurgePlan {
            let tid = try StoredRecord(task,family:"task").string("id")
            if let error = batch.errors[tid] {throw error}
            if inventory == nil {inventory = try ticketCleanupInventory(db,task:task)}
            return try ticketPurgePlan(db,task:task,inventory:inventory,doneEvidence:doneEvidence,historyObservation:historyObservation,backupObservation:backupObservation,candidateObjects:candidateObjects[tid],mediaAuthorityComplete:mediaAuthorityComplete,referenceGraph:referenceGraphs[tid])
        }
        for row in rows {
            let task = try GRDBRecordEnvelopeAdapter.decode(row).object, tid = (try StoredRecord(task, family: "task").string("id"))
            inventory = batch.inventories[tid]
            var item: JSON = [
                "task_id": tid, "key": task["key"] ?? "", "task_revision": (try StoredRecord(task, family: "task").requiredValue("revision")), "action": "keep",
                "reason": "open_ticket",
            ]
            let category = (try? record(db,task["status_id"] as? String ?? "",type:"status"))?["category"] as? String ?? "unknown"
            if let retry = retryState[tid],retry > time.timeIntervalSince1970 {item["reason"] = "ticket_retry_deferred"}
            else if bool(task,"purged") {item["reason"] = "already_purged"}
            else if ["done","canceled"].contains(category) {
                do {
                    try requirePurgeSafe(db,task:task,automatic:true)
                    let eventTime = eventTimes[Data(tid.utf8)]
                    let clockStrings = [task["updated_at"] as? String,eventTime].compactMap {$0}
                    let clocks = clockStrings.compactMap {ISO8601DateFormatter().date(from:$0)}
                    let changed = clocks.count == clockStrings.count && task["updated_at"] is String ? clocks.max() : nil
                    let due = changed?.addingTimeInterval(Double(int(settings,"closed_days")) * 86400)
                    if bool(settings,"closed_purge_enabled"),let due,due <= time {
                        item["action"] = "purge";item["reason"] = "closed_unchanged";item["due_at"] = ISO8601DateFormatter().string(from:due)
                    } else if category == "done",bool(settings,"done_evidence_enabled") {
                        let jobs = try jobObservation.entry(task:tid,project:pid)
                        if jobs.pending {item["reason"] = "deletion_pending"}
                        else {
                            let plan = try plan(task,doneEvidence:true)
                            let objects = plan.byteDeletion.objects
                            let outstanding = objects.filter {object in
                                guard object["state"] as? String != "already_missing" else {return false}
                                if object["state"] as? String == "pending" {return true}
                                return !jobs.retains(object)
                            }
                            if !outstanding.isEmpty {plans[tid] = plan;item["action"] = "done_evidence";item["reason"] = "done";item["plan_digest"] = plan.digest;item["objects"] = objects;item["summary"] = plan.byteDeletion.summary}
                            else {item["reason"] = "no_new_eligible_bytes"}
                        }
                    } else {item["reason"] = bool(settings,"closed_purge_enabled") ? (due == nil ? "unknown_change_time" : "retention_age") : "rule_disabled"}
                    if item["action"] as? String == "purge" {let plan = try plan(task);plans[tid] = plan;item["objects"] = plan.byteDeletion.objects;item["summary"] = plan.byteDeletion.summary;item["record_impact"] = plan.impact.filter {!["known_backup_count","known_backup_observed_times","known_backup_creation_times"].contains($0.key)};item["purge_digest"] = plan.digest}
                } catch let error as CoreError {
                    if ["CLEANUP_INVENTORY_LIMIT","REFERENCE_GRAPH_LIMIT","PURGE_LIMIT"].contains(error.code) {planningRetries.append(tid)}
                    item["action"] = "keep";item["reason"] = error.code
                }
            }
            item["retry"] = retryIDs.contains(tid)
            item["scan_row"] = row["cleanup_row"] as Int64;items.append(item)
        }
        observePhase?("plans")
        let purgeTasks = tasks.filter {task in items.contains {$0["task_id"] as? String == task["id"] as? String && $0["action"] as? String == "purge"}}
        let commands = try ticketPurgeExpiringCommands(db,tasks:purgeTasks,plans:plans)
        expired = commands.commands
        observePhase?("commands")
        for index in items.indices {
            let tid = try StoredRecord(items[index],family:"cleanup_selection_item").string("task_id")
            if let error = commands.errors[tid] {
                items[index]["action"] = "keep";items[index]["reason"] = error.code
                planningRetries.append(tid);plans[tid] = nil
                continue
            }
            guard let plan = plans[tid],items[index]["action"] as? String != "keep",let task = tasks.first(where:{$0["id"] as? String == tid}) else {continue}
            var observation = batch.inventories[tid] ?? TicketCleanupInventory()
            observation.objects(plan.byteDeletion.objects,root:root)
            itemFences[tid] = try TicketCleanupFence(db,inventory:observation,project:pid,ids:[tid,task["status_id"] as? String ?? ""],events:plan.events,commands:expired[tid] ?? [],fencesScanMetadata:false)
        }
        observePhase?("fences")
        let end = (scanRows.last?["cleanup_row"] as Int64?) ?? cursor
        let more = retryOnly ? false : try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE type='task' AND project_id=? AND rowid>?)",arguments:[pid,end]) ?? false
        let selection: JSON = ["project_id":pid,"settings":settings,"items":items,"next_cursor":more ? end : 0,"scan_cursor":cursor,"more":more,"attempted_retry_ids":Array(dueRetries),"retry_task_ids":planningRetries,"observed_retry_tokens":retryEntries.mapValues(\.token),"retry_only":retryOnly,"sweep_deadline":sweepDeadline,
            "selected_bytes":items.reduce(Int64(0)) {$0 + (((($1["summary"] as? JSON)?["pending_bytes"]) as? NSNumber)?.int64Value ?? 0)},"physical_reclamation":"unmeasured","source_build_cache":try sourceBuildCacheRetainedEntries(db,project:pid)]
        // Scan resets are scheduling, not deletion authority. Each selected
        // ticket fences its own records/references before any action commits.
        let fence = try TicketCleanupFence(db,inventory:TicketCleanupInventory(),project:pid,ids:[pid],fencesScanMetadata:false)
        observePhase?("final_projection")
        return TicketCleanupPreparedPass(fence:fence,project:project,selection:selection,plans:plans,expiredCommands:expired,itemFences:itemFences)
    }

    func prepareTicketLifecycleCleanup(_ db: Database,at time: Date = Date()) throws -> TicketCleanupPreparedPass? {
        for project in try records(db,type:"project") {
            let settings = ticketCleanupSettings(project)
            guard bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled") else {continue}
            let next =
                Double(
                    try String.fetchOne(
                        db, sql: "SELECT value FROM metadata WHERE key=?", arguments: ["ticket-cleanup-next:" + ((try StoredRecord(project, family: "project").string("id")))])
                        ?? "0") ?? 0
            if let retry = try ticketCleanupProjectRetry(db, project: (try StoredRecord(project, family: "project").string("id"))), retry > time { continue }
            if time.timeIntervalSince1970 >= next {
                try beginTicketCleanupPreparation(project: (try StoredRecord(project, family: "project").string("id")))
                return try ticketCleanupSelection(db,project:project,at:time)
            }
        }
        return nil
    }

    /// Only fresh preparation reaches this short semantic transaction. The pass
    /// receipt, cursor, purge and byte intents commit together before any unlink.
    func commitTicketLifecycleCleanup(_ db: Database,prepared: TicketCleanupPreparedPass,at time: Date) throws {
        let project = prepared.project, pid = (try StoredRecord(project, family: "project").string("id")), selection = prepared.selection, settings = ticketCleanupSettings(project)
        try withValidatedDomainTransaction(db) {
            var items = try StoredRecord(selection, family: "cleanup_selection").objects("items")
            for index in items.indices {
                let action = items[index]["action"] as? String ?? "keep"
                guard action != "keep" else {continue}
                let tid = try StoredRecord(items[index], family: "cleanup_selection_item").string("task_id"), task = try self.record(db, tid, type: "task"),
                    plan = prepared.plans[tid]
                guard let plan else {
                    throw CoreError("CANONICAL_RECORD_INVALID", "A stored record is malformed.")
                }
                let deletion: JSON
                if action == "purge" {
                    let result = try self.taskPurge(
                        db,
                        [
                            "project_id": pid, "task_id": tid, "expected_revision": (try StoredRecord(task, family: "task").requiredValue("revision")),
                            "preview_digest": plan.digest,
                        ], Caller(role: "owner", installation: "storage", projectIDs: []), automatic: true, prepared: plan, expiredCommands: prepared.expiredCommands[tid])
                    deletion = try StoredRecord(result, family: "purge_result").object("byte_deletion")
                } else {
                    var receipt = try self.enqueueTicketObjectDeletion(db,project:pid,task:tid,cause:"done_evidence",plan:plan.byteDeletion)
                    receipt["owned_record_fingerprints"] = Dictionary(uniqueKeysWithValues:try plan.byteCleanupOwners.map {($0.id,try self.ticketCleanupOwnerFingerprint($0.value,type:$0.type))})
                    receipt["task_revision"] = (try StoredRecord(task, family: "task").requiredValue("revision"))
                    receipt["cleanup_policy_version"] = 2
                    try self.save(db,receipt,type:"storage_job");deletion = receipt
                }
                items[index]["byte_deletion_receipt_id"] = (try StoredRecord(deletion, family: "deletion").requiredValue("id"))
            }
            let id = uuid()
            let receipt: JSON = [
                "id": id, "project_id": pid, "kind": Self.ticketObjectDeletionKind, "cause": "ticket_cleanup_pass", "origin": "automatic_cleanup", "state": "completed",
                "revision": 1, "created_at": now(), "selected_bytes": (try StoredRecord(selection, family: "selection").requiredValue("selected_bytes")), "settings": settings,
                "items": ticketCleanupPassItems(items), "objects": [], "summary": Self.ticketObjectDeletionSummary([]), "source_build_cache": selection["source_build_cache"] ?? [],
            ]
            try self.save(db,receipt,type:"storage_job")
            try self.event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:pid,entity:pid,kind:"ticket_cleanup_pass",data:["origin":"automatic_cleanup","receipt_id":id,"admitted_count":items.filter {$0["action"] as? String != "keep"}.count])
            try db.execute(sql:"INSERT OR IGNORE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-first:" + pid,id])
            var retries = try ticketCleanupRetryEntries(db,project:pid)
            let observedTokens = selection["observed_retry_tokens"] as? [String:String] ?? [:]
            for id in selection["attempted_retry_ids"] as? [String] ?? [] where retries[id]?.token == observedTokens[id] {retries.removeValue(forKey:id)}
            for id in selection["retry_task_ids"] as? [String] ?? [] {retries[id] = TicketCleanupRetry(at:time.addingTimeInterval(60))}
            try saveTicketCleanupRetries(db,project:pid,entries:retries)
            let reset = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE kind=3 AND id=CAST(? AS BLOB))",arguments:["ticket-cleanup-cursor:" + pid]) ?? false
            let cursor = reset ? 0 : ((selection["next_cursor"] as? Int64) ?? 0)
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-cursor:" + pid,String(cursor)])
            let ordinaryDeadline = bool(selection,"retry_only") && !reset ? (selection["sweep_deadline"] as? Double ?? time.addingTimeInterval(86400).timeIntervalSince1970) : time.addingTimeInterval(bool(selection,"more") || reset ? 0.05 : 86400).timeIntervalSince1970
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-sweep-next:" + pid,String(ordinaryDeadline)])
            let deadline = min(ordinaryDeadline,retries.values.map(\.deadline).min() ?? ordinaryDeadline)
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(deadline)])
            return .commit
        }
    }

    private func ticketCleanupPassItems(_ items: [JSON]) -> [JSON] {
        items.map { item in
            var item = item
            for field in ["scan_row", "retry", "objects", "plan_digest", "purge_digest", "record_impact"] {
                item.removeValue(forKey: field)
            }
            return item
        }
    }

    func nextTicketCleanupDeadline(_ db: Database) throws -> Date? {
        var dates: [Date] = []
        for project in try records(db,type:"project") {
            let settings = ticketCleanupSettings(project)
            guard bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled") else {continue}
            let next =
                Double(
                    try String.fetchOne(
                        db, sql: "SELECT value FROM metadata WHERE key=?", arguments: ["ticket-cleanup-next:" + ((try StoredRecord(project, family: "project").string("id")))])
                        ?? "0") ?? 0
            dates.append(
                max(Date(timeIntervalSince1970: next), try ticketCleanupProjectRetry(db, project: (try StoredRecord(project, family: "project").string("id"))) ?? .distantPast))
        }
        return dates.min()
    }

    func ticketCleanupPassProjection(_ db: Database,receipt: JSON) throws -> JSON {
        var value = receipt,items = receipt["items"] as? [JSON] ?? [],objects: [JSON] = []
        for index in items.indices {
            if let id = items[index]["byte_deletion_receipt_id"] as? String {
                let deletion = try scoped(db, id, (try StoredRecord(receipt, family: "receipt").string("project_id")), type: "storage_job")
                items[index]["byte_deletion"] = deletion;objects += deletion["objects"] as? [JSON] ?? []
            }
        }
        value["items"] = items;value["summary"] = Self.ticketObjectDeletionSummary(objects)
        value["bytes_state"] = objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed"
        return value
    }

    func ticketCleanupDeletionBlocker(_ db: Database,receipt: JSON) throws -> String? {
        guard receipt["cause"] as? String == "done_evidence" else {return nil}
        let task = try record(db, (try StoredRecord(receipt, family: "receipt").string("task_id")), type: "task"),
            project = try record(db, (try StoredRecord(receipt, family: "receipt").string("project_id")), type: "project")
        guard bool(ticketCleanupSettings(project),"done_evidence_enabled") else {return "rule_disabled"}
        guard !bool(task,"purged"),(try? record(db,task["status_id"] as? String ?? "",type:"status"))?["category"] as? String == "done",int(task,"revision") == int(receipt,"task_revision") else {return "ticket_changed"}
        do {try requirePurgeSafe(db,task:task,automatic:true)} catch let error as CoreError {return error.code}
        return nil
    }

    func ticketCleanupDeletionReferences(_ db: Database,receipt: JSON,inventory: TicketCleanupInventory? = nil) throws -> [JSON] {
        let graph = try inventory.map {$0.rows.map {row -> JSON in var value = row.value;value["record_type"] = row.type;return value}} ?? archiveCleanupReferenceRows(db)
        guard receipt["cause"] as? String == "done_evidence" else {return graph}
        let fingerprints = receipt["owned_record_fingerprints"] as? [String:String] ?? [:]
        let owners = Set(fingerprints.keys.map {Data($0.utf8)})
        let protected = try ticketCleanupProtectedOwners(graph.filter {$0["id"] as? String != receipt["task_id"] as? String},owners:owners,tokens:inventory?.tokens)
        return try graph.filter {value in
            // Retained historical owners do not keep their own bytes alive. Holds
            // and every newly admitted/foreign reference still win at final unlink.
            let type = value["record_type"] as? String ?? "",id = value["id"] as? String ?? ""
            if type == "storage_hold" {return true}
            if id == receipt["task_id"] as? String {return false}
            if protected.contains(Data(id.utf8)) {return true}
            guard let expected = fingerprints[id] else {return true}
            return try expected != ticketCleanupOwnerFingerprint(value,type:type)
        }
    }

    private func ticketCleanupOwnerFingerprint(_ value: JSON,type: String) throws -> String {
        var value = value;value.removeValue(forKey:"record_type")
        if type == "attachment" {
            for key in ["revision","updated_at","availability","cleanup_receipt_id"] {value.removeValue(forKey:key)}
        }
        return hash(Data(try jsonString(value).utf8))
    }

    func recordTicketCleanupAvailability(_ db: Database,receipt: JSON,object: JSON) throws {
        guard receipt["cause"] as? String == "done_evidence",["removed","already_missing"].contains(object["state"] as? String ?? "") else {return}
        try event(
            db, caller: Caller(role: "owner", installation: "storage", projectIDs: []), project: receipt["project_id"] as? String, entity: receipt["project_id"] as? String,
            kind: "ticket_evidence_cleanup_outcome",
            data: [
                "origin": "automatic_cleanup", "task_id": (try StoredRecord(receipt, family: "receipt").requiredValue("task_id")),
                "receipt_id": (try StoredRecord(receipt, family: "receipt").requiredValue("id")), "state": (try StoredRecord(object, family: "object").requiredValue("state")),
                "removed_bytes": object["state"] as? String == "removed" ? object["size"] ?? 0 : 0,
            ])
        guard object["representation"] as? String == "original" else {return}
        for id in strings(object,"owner_ids") {
            if var attachment = try? record(db,id,type:"attachment"),attachment["sha256"] as? String == object["sha256"] as? String {
                attachment["availability"] = object["state"] as? String == "removed" ? "original_cleaned" : "original_missing"
                attachment["cleanup_receipt_id"] = (try StoredRecord(receipt, family: "receipt").requiredValue("id"))
                try save(db,revised(attachment),type:"attachment")
            }
        }
    }
}
