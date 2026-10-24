import Foundation
import CoreFoundation
import GRDB

/// Lifecycle policy only. CL-24 owns record removal; CL-154 owns every unlink.
/// All state uses project JSON, metadata and existing ticket_object_delete jobs.
extension CommandRouter {
    static let ticketCleanupSchema: JSON = ["type":"object","additionalProperties":false,
        "required":["done_evidence_enabled","closed_purge_enabled","closed_days"],
        "properties":["done_evidence_enabled":["type":"boolean"],"closed_purge_enabled":["type":"boolean"],"closed_days":["type":"integer","minimum":1,"maximum":36500]]]

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

    /// Read-snapshot preparation only: 32 tickets, at most one semantic action.
    /// The maintenance lane yields the writer and service queue between chunks.
    func ticketCleanupSelection(_ db: Database,project: JSON,at time: Date = Date()) throws -> TicketCleanupPreparedPass {
        let pid = project["id"] as! String,settings = ticketCleanupSettings(project),cursor = try ticketCleanupCursor(db,pid)
        let rows = try Row.fetchAll(db,sql:"SELECT rowid AS cleanup_row," + Self.canonicalRecordColumns + " FROM records WHERE type='task' AND project_id=? AND rowid>? ORDER BY rowid LIMIT 32",arguments:[pid,cursor])
        var items: [JSON] = [],plans: [String:TicketPurgePlan] = [:],expired: [String:[Row]] = [:],admitted = 0
        var inventory: TicketCleanupInventory?,planningAttempted = false
        func plan(_ task: JSON) throws -> TicketPurgePlan {
            planningAttempted = true
            if inventory == nil {inventory = try ticketCleanupInventory(db,task:task)}
            return try ticketPurgePlan(db,task:task,inventory:inventory)
        }
        for row in rows {
            let task = try GRDBRecordEnvelopeAdapter.decode(row).object,tid = task["id"] as! String
            var item: JSON = ["task_id":tid,"key":task["key"] ?? "","task_revision":task["revision"]!,"action":"keep","reason":"open_ticket"]
            let category = (try? record(db,task["status_id"] as? String ?? "",type:"status"))?["category"] as? String ?? "unknown"
            if bool(task,"purged") {item["reason"] = "already_purged"}
            else if ["done","canceled"].contains(category) {
                do {
                    try requirePurgeSafe(db,task:task,automatic:true)
                    let eventTime = try String.fetchOne(db,sql:"SELECT MAX(occurred_at) FROM events WHERE project_id=? AND entity_id=? AND kind NOT IN ('attachment_original_cleaned','attachment_original_missing')",arguments:[pid,tid])
                    let clockStrings = [task["updated_at"] as? String,eventTime].compactMap {$0}
                    let clocks = clockStrings.compactMap {ISO8601DateFormatter().date(from:$0)}
                    let changed = clocks.count == clockStrings.count && task["updated_at"] is String ? clocks.max() : nil
                    let due = changed?.addingTimeInterval(Double(int(settings,"closed_days")) * 86400)
                    if bool(settings,"closed_purge_enabled"),let due,due <= time {
                        item["action"] = "purge";item["reason"] = "closed_unchanged";item["due_at"] = ISO8601DateFormatter().string(from:due)
                    } else if category == "done",bool(settings,"done_evidence_enabled") {
                        let jobs = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='storage_job' AND project_id=? AND json_extract(data,'$.cause')='done_evidence' AND json_extract(data,'$.task_id')=?",arguments:[pid,tid]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
                        if jobs.contains(where: {$0["task_id"] as? String == tid && $0["state"] as? String == "pending"}) {item["reason"] = "deletion_pending"}
                        else {
                            let plan = try plan(task)
                            let objects = plan.byteDeletion.objects
                            let previous = jobs.filter {$0["task_id"] as? String == tid}.flatMap {$0["objects"] as? [JSON] ?? []}
                            let outstanding = objects.filter {object in
                                guard object["state"] as? String != "already_missing" else {return false}
                                if object["state"] as? String == "pending" {return true}
                                return !previous.contains {prior in
                                    prior["stored_path"] as? String == object["stored_path"] as? String && prior["sha256"] as? String == object["sha256"] as? String && strings(prior,"reasons") == strings(object,"reasons") && prior["state"] as? String == "retained"
                                }
                            }
                            if !outstanding.isEmpty {plans[tid] = plan;item["action"] = "done_evidence";item["reason"] = "done";item["plan_digest"] = plan.digest;item["objects"] = objects;item["summary"] = plan.byteDeletion.summary}
                            else {item["reason"] = "no_new_eligible_bytes"}
                        }
                    } else {item["reason"] = bool(settings,"closed_purge_enabled") ? (due == nil ? "unknown_change_time" : "retention_age") : "rule_disabled"}
                    if item["action"] as? String == "purge" {let plan = try plan(task);plans[tid] = plan;expired[tid] = try ticketPurgeExpiringCommands(db,task:task,plan:plan);item["objects"] = plan.byteDeletion.objects;item["summary"] = plan.byteDeletion.summary;item["record_impact"] = plan.impact.filter {!["known_backup_count","known_backup_observed_times","known_backup_creation_times"].contains($0.key)};item["purge_digest"] = plan.digest}
                } catch let error as CoreError {
                    if ["CLEANUP_INVENTORY_LIMIT","REFERENCE_GRAPH_LIMIT","PURGE_LIMIT","CANONICAL_RECORD_INVALID"].contains(error.code) {try recordTicketCleanupPreparationRefusal(project:pid,reason:error.code)}
                    item["action"] = "keep";item["reason"] = error.code
                }
            }
            if item["action"] as? String != "keep" {
                if admitted == 1 {break}
                admitted += 1
            }
            item["scan_row"] = row["cleanup_row"] as Int64;items.append(item)
            if admitted == 1 || planningAttempted {break}
        }
        let end = (items.last?["scan_row"] as? Int64) ?? cursor
        let more = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE type='task' AND project_id=? AND rowid>?)",arguments:[pid,end]) ?? false
        let selection: JSON = ["project_id":pid,"settings":settings,"items":items,"next_cursor":more ? end : 0,"more":more,
            "selected_bytes":items.reduce(Int64(0)) {$0 + (((($1["summary"] as? JSON)?["pending_bytes"]) as? NSNumber)?.int64Value ?? 0)},"physical_reclamation":"unmeasured","source_build_cache":try sourceBuildCacheRetainedEntries(db,project:pid)]
        var observation = inventory ?? TicketCleanupInventory()
        for plan in plans.values {observation.objects(plan.byteDeletion.objects,root:root)}
        let ids = [pid] + items.flatMap {item -> [String] in
            let tid = item["task_id"] as! String
            let task = try? record(db,tid,type:"task")
            return [tid,task?["status_id"] as? String ?? ""]
        }
        let fence = try TicketCleanupFence(db,inventory:observation,project:pid,ids:ids,events:plans.values.flatMap(\.events),commands:expired.values.flatMap {$0})
        return TicketCleanupPreparedPass(fence:fence,project:project,selection:selection,plans:plans,expiredCommands:expired)
    }

    func prepareTicketLifecycleCleanup(_ db: Database,at time: Date = Date()) throws -> TicketCleanupPreparedPass? {
        for project in try records(db,type:"project") {
            let settings = ticketCleanupSettings(project)
            guard bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled") else {continue}
            let next = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + (project["id"] as! String)]) ?? "0") ?? 0
            if let retry = try ticketCleanupProjectRetry(db,project:project["id"] as! String),retry > time {continue}
            if time.timeIntervalSince1970 >= next {
                try beginTicketCleanupPreparation(project:project["id"] as! String)
                return try ticketCleanupSelection(db,project:project,at:time)
            }
        }
        return nil
    }

    /// Only fresh preparation reaches this short semantic transaction. The pass
    /// receipt, cursor, purge and byte intents commit together before any unlink.
    func commitTicketLifecycleCleanup(_ db: Database,prepared: TicketCleanupPreparedPass,at time: Date) throws {
        let project = prepared.project,pid = project["id"] as! String,selection = prepared.selection,settings = ticketCleanupSettings(project)
        try withValidatedDomainTransaction(db) {
            var items = selection["items"] as! [JSON]
            for index in items.indices {
                let action = items[index]["action"] as? String ?? "keep"
                guard action != "keep" else {continue}
                let tid = items[index]["task_id"] as! String,task = try self.record(db,tid,type:"task"),plan = prepared.plans[tid]!
                let deletion: JSON
                if action == "purge" {
                    let result = try self.taskPurge(db,["project_id":pid,"task_id":tid,"expected_revision":task["revision"]!,"preview_digest":plan.digest],Caller(role:"owner",installation:"storage",projectIDs:[]),automatic:true,prepared:plan,expiredCommands:prepared.expiredCommands[tid])
                    deletion = result["byte_deletion"] as! JSON
                } else {
                    var receipt = try self.enqueueTicketObjectDeletion(db,project:pid,task:tid,cause:"done_evidence",plan:plan.byteDeletion)
                    receipt["owned_record_fingerprints"] = Dictionary(uniqueKeysWithValues:try plan.removed.map {($0.id,try self.ticketCleanupOwnerFingerprint($0.value,type:$0.type))})
                    receipt["task_revision"] = task["revision"]!
                    try self.save(db,receipt,type:"storage_job");deletion = receipt
                }
                items[index]["byte_deletion_receipt_id"] = deletion["id"]!
            }
            let id = uuid()
            let receipt: JSON = ["id":id,"project_id":pid,"kind":Self.ticketObjectDeletionKind,"cause":"ticket_cleanup_pass","origin":"automatic_cleanup","state":"completed","revision":1,"created_at":now(),"selected_bytes":selection["selected_bytes"]!,"settings":settings,"items":items.map {item -> JSON in
                var item = item
                for field in ["scan_row","objects","plan_digest","purge_digest","record_impact"] {item.removeValue(forKey:field)}
                return item
            },"objects":[],"summary":Self.ticketObjectDeletionSummary([]),"source_build_cache":selection["source_build_cache"] ?? []]
            try self.save(db,receipt,type:"storage_job")
            try self.event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:pid,entity:pid,kind:"ticket_cleanup_pass",data:["origin":"automatic_cleanup","receipt_id":id,"admitted_count":items.filter {$0["action"] as? String != "keep"}.count])
            try db.execute(sql:"INSERT OR IGNORE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-first:" + pid,id])
            let cursor = (selection["next_cursor"] as? Int64) ?? 0
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-cursor:" + pid,String(cursor)])
            let deadline = time.addingTimeInterval(bool(selection,"more") ? 0.05 : 86400).timeIntervalSince1970
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(deadline)])
            return .commit
        }
    }

    func nextTicketCleanupDeadline(_ db: Database) throws -> Date? {
        var dates: [Date] = []
        for project in try records(db,type:"project") {
            let settings = ticketCleanupSettings(project)
            guard bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled") else {continue}
            let next = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + (project["id"] as! String)]) ?? "0") ?? 0
            dates.append(max(Date(timeIntervalSince1970:next),try ticketCleanupProjectRetry(db,project:project["id"] as! String) ?? .distantPast))
        }
        return dates.min()
    }

    func ticketCleanupPassProjection(_ db: Database,receipt: JSON) throws -> JSON {
        var value = receipt,items = receipt["items"] as? [JSON] ?? [],objects: [JSON] = []
        for index in items.indices {
            if let id = items[index]["byte_deletion_receipt_id"] as? String {
                let deletion = try scoped(db,id,receipt["project_id"] as! String,type:"storage_job")
                items[index]["byte_deletion"] = deletion;objects += deletion["objects"] as? [JSON] ?? []
            }
        }
        value["items"] = items;value["summary"] = Self.ticketObjectDeletionSummary(objects)
        value["bytes_state"] = objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed"
        return value
    }

    func ticketCleanupDeletionBlocker(_ db: Database,receipt: JSON) throws -> String? {
        guard receipt["cause"] as? String == "done_evidence" else {return nil}
        let task = try record(db,receipt["task_id"] as! String,type:"task"),project = try record(db,receipt["project_id"] as! String,type:"project")
        guard bool(ticketCleanupSettings(project),"done_evidence_enabled") else {return "rule_disabled"}
        guard !bool(task,"purged"),(try? record(db,task["status_id"] as? String ?? "",type:"status"))?["category"] as? String == "done",int(task,"revision") == int(receipt,"task_revision") else {return "ticket_changed"}
        do {try requirePurgeSafe(db,task:task,automatic:true)} catch let error as CoreError {return error.code}
        return nil
    }

    func ticketCleanupDeletionReferences(_ db: Database,receipt: JSON,inventory: TicketCleanupInventory? = nil) throws -> [JSON] {
        let graph = try inventory.map {$0.rows.map {row -> JSON in var value = row.value;value["record_type"] = row.type;return value}} ?? archiveCleanupReferenceRows(db)
        guard receipt["cause"] as? String == "done_evidence" else {return graph}
        let fingerprints = receipt["owned_record_fingerprints"] as? [String:String] ?? [:]
        return try graph.filter {value in
            // Retained historical owners do not keep their own bytes alive. Holds
            // and every newly admitted/foreign reference still win at final unlink.
            let type = value["record_type"] as? String ?? "",id = value["id"] as? String ?? ""
            if type == "storage_hold" {return true}
            if id == receipt["task_id"] as? String {return false}
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
        try event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:receipt["project_id"] as? String,entity:receipt["project_id"] as? String,kind:"ticket_evidence_cleanup_outcome",data:["origin":"automatic_cleanup","task_id":receipt["task_id"]!,"receipt_id":receipt["id"]!,"state":object["state"]!,"removed_bytes":object["state"] as? String == "removed" ? object["size"] ?? 0 : 0])
        guard object["representation"] as? String == "original" else {return}
        for id in strings(object,"owner_ids") {
            if var attachment = try? record(db,id,type:"attachment"),attachment["sha256"] as? String == object["sha256"] as? String {
                attachment["availability"] = object["state"] as? String == "removed" ? "original_cleaned" : "original_missing"
                attachment["cleanup_receipt_id"] = receipt["id"]!
                try save(db,revised(attachment),type:"attachment")
            }
        }
    }
}
