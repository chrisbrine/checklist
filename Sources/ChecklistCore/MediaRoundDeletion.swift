import Foundation
import GRDB

/// Removal owns structural children, never the dependencies of a predecessor,
/// adopted example, shared type, project instruction or linked ticket.
private struct MediaRoundDeletionPlan {
    let version: Int64
    let project: String
    let round: String
    let records: [PurgeRow]
    let events: [String]
    let commands: [(String,String)]
    let bytes: TicketObjectDeletionPlan
    let audit: JSON
    let keptAttachments: [JSON]
    let fence: MediaRoundDeletionFence
}

extension CommandRouter {
    /// Existing reader expiry wakes maintenance. A released/expired lease can
    /// resume this receipt once; active leases keep it out of the ready queue.
    /// New leases are checked too, rather than trusting a saved deadline.
    static let mediaRoundDeletionReaderObjectReadySQL = """
        json_extract(object.value,'$.state')='retained'
        AND EXISTS(SELECT 1 FROM json_each(object.value,'$.reasons') reason WHERE reason.value='reader_lease')
        AND NOT EXISTS(SELECT 1 FROM json_each(object.value,'$.reasons') reason WHERE reason.type!='text' OR (reason.value NOT IN ('reader_lease','backup_authority','remaining_record','backup_required','backup_copy_unavailable','backup_authority_unavailable') AND reason.value NOT GLOB 'backup_index_error:*' AND reason.value NOT GLOB 'backup_copy_unverified:*'))
        AND json_type(object.value,'$.reader_hold_ids')='array'
        AND NOT EXISTS(SELECT 1 FROM records h INDEXED BY records_scope
            WHERE h.type='storage_hold' AND h.id IN (SELECT value FROM json_each(object.value,'$.reader_hold_ids'))
            AND json_extract(h.data,'$.state')='active'
            AND (COALESCE(json_type(h.data,'$.expires_at'),'missing') NOT IN ('integer','real')
                OR json_extract(h.data,'$.expires_at')>(julianday('now')-2440587.5)*86400.0))
        """
    static let mediaRoundDeletionReaderReadySQL = """
        json_extract(records.data,'$.cause')='media_round_delete'
        AND json_extract(records.data,'$.state')='completed'
        AND EXISTS(SELECT 1 FROM json_each(records.data,'$.objects') object WHERE \(mediaRoundDeletionReaderObjectReadySQL))
        """

    func mediaRoundDeletionReaderHoldIDs(_ db: Database,object: JSON) throws -> [String] {
        guard let relative = object["relative_path"] as? String else {return []}
        var needles = Set(strings(object,"owner_ids").map {Data($0.utf8)})
        for path in [relative,root.appendingPathComponent(relative).path,object["stored_path"] as? String ?? "",object["sha256"] as? String ?? ""] where !path.isEmpty {needles.insert(Data(path.utf8))}
        let values = try jsonString(needles.map {String(decoding:$0,as:UTF8.self)})
        return try String.fetchAll(db,sql:"SELECT h.id FROM records h INDEXED BY records_scope WHERE h.type='storage_hold' AND json_extract(h.data,'$.state')='active' AND COALESCE(json_extract(h.data,'$.kind'),'') NOT IN ('media_reference','backup') AND (COALESCE(json_type(h.data,'$.expires_at'),'missing') NOT IN ('integer','real') OR json_extract(h.data,'$.expires_at')>?) AND EXISTS(SELECT 1 FROM json_tree(h.data) token WHERE (token.type='text' AND CAST(token.atom AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))) OR (typeof(token.key)='text' AND CAST(token.key AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)))) ORDER BY CAST(h.id AS BLOB)",arguments:[Date().timeIntervalSince1970,values,values])
    }

    func mediaRoundDeletionReaderCanResume(_ db: Database,receipt: String,object: JSON) throws -> Bool {
        guard let path = object["relative_path"] as? String else {return false}
        return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records,json_each(records.data,'$.objects') object WHERE records.id=CAST(? AS TEXT) AND json_extract(object.value,'$.relative_path')=CAST(? AS TEXT) AND " + Self.mediaRoundDeletionReaderObjectReadySQL + ")",arguments:[Data(receipt.utf8),Data(path.utf8)]) == true
    }

    func mediaRoundDeletionView(_ receipt: JSON) throws -> JSON {
        guard receipt["cause"] as? String == "media_round_delete",var result = receipt["deletion"] as? JSON else {
            throw CoreError("NOT_FOUND","No media round deletion receipt exists in this project.")
        }
        result["byte_deletion_receipt_id"] = receipt["id"]
        result["cleanup_state"] = receipt["state"]
        // Earlier CL-446 receipts predate ticket-preserving deletion. Their
        // empty kept set is known; no unrecorded timing is invented.
        if result["kept_attachments"] == nil {result["kept_attachments"] = [JSON]()}
        result["files"] = (receipt["objects"] as? [JSON] ?? []).map { object -> JSON in
            let state = object["state"] as? String ?? "retained"
            var reasons = strings(object,"reasons"),status = "kept"
            if state == "removed",bool(object,"moved_to_trash") {status = "moved";reasons = ["moved_to_trash"]}
            else if state == "pending" {status = "held";reasons = [object["last_failure"] as? String ?? "pending_cleanup"]}
            else if state == "already_missing" {reasons = ["already_missing"]}
            else if reasons.contains(where:{Self.ticketObjectDeletionRetryReasons.contains($0) || $0.hasPrefix("backup_") || ["reader_lease","media_owner"].contains($0)}) {status = "held"}
            if reasons.isEmpty {reasons = ["identity_unavailable"]}
            var file: JSON = ["status":status,"reason":reasons[0],"reasons":reasons,"representation":object["representation"] ?? "original"]
            file["relative_path"] = object["relative_path"]
            return file
        }
        return result
    }

    func mediaRoundDeletionGet(_ db: Database,_ p: JSON,project: String) throws -> JSON {
        let rid = try text(p,"round_id")
        guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='storage_job' AND json_extract(data,'$.cause')='media_round_delete' AND json_extract(data,'$.round_id')=CAST(? AS TEXT) ORDER BY rowid DESC LIMIT 1",arguments:[Data(project.utf8),Data(rid.utf8)]) else {
            throw CoreError("NOT_FOUND","No media round deletion receipt exists in this project.")
        }
        return try mediaRoundDeletionView(GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job").object)
    }

    /// All graph work and preview hashing happen on a separate read-only
    /// snapshot. A narrow changed-row fence preserves unrelated service writes,
    /// including eventless/same-revision edits outside the deletion graph.
    func executeMediaRoundDelete(_ p: JSON,_ c: Caller,command: String,digest: String) throws -> JSON {
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let observer = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? observer.close()}
        let changes = MediaRoundDeletionChanges()
        let (writerVersion,preparationProject) = try dbQueue.writeWithoutTransaction {db in
            let project = try self.mediaAccess(db,p,c,write:true)
            let version = try changes.install(db),key = Data(project.utf8)
            self.mediaRoundDeletionPreparations[key,default:[]].insert(changes.name)
            return (version,key)
        }
        defer {
            try? dbQueue.writeWithoutTransaction {db in
                self.mediaRoundDeletionPreparations[preparationProject]?.remove(changes.name)
                if self.mediaRoundDeletionPreparations[preparationProject]?.isEmpty == true {self.mediaRoundDeletionPreparations.removeValue(forKey:preparationProject)}
                try changes.remove(db)
            }
        }
        var plan: MediaRoundDeletionPlan?,replay: JSON?
        try observer.read {db in
            let project = try self.mediaAccess(db,p,c,write:true)
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
            if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID has a different intent.")}
                var result = jsonObject(row["result"])
                if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                result["replayed"] = true;replay = result;return
            }
            try self.requireAgentEditAuthority(db,project:self.record(db,project,type:"project"),caller:c)
            plan = try self.prepareMediaRoundDeletion(db,p,c,project:project)
            try self.mediaRoundDeletionPreparationProbe?()
        }
        if let replay {return replay}
        guard let plan else {throw MediaRoundDeletionFence.changed("plan_unavailable",type:"media_round",id:Data((try text(p,"round_id")).utf8))}
        do {return try ArchiveStorageGate.withExclusive(root:root) {_ in
            try dbQueue.writeWithoutTransaction {db in
                var result: JSON = [:]
                try self.withValidatedDomainTransaction(db) {
                    let project = try self.mediaAccess(db,p,c,write:true)
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                        guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID has a different intent.")}
                        result = jsonObject(row["result"])
                        if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                        result["replayed"] = true;return .commit
                    }
                    try self.requireAgentEditAuthority(db,project:self.record(db,project,type:"project"),caller:c)
                    guard EnvelopeStorageIdentity.equal(project,plan.project) else {throw MediaRoundDeletionFence.changed("project_scope",type:"project",id:Data(plan.project.utf8))}
                    if try observer.read({try Int64.fetchOne($0,sql:"PRAGMA data_version")!}) != plan.version {
                        try plan.fence.validate(db,changes:changes,writerVersion:writerVersion)
                    }
                    var receipt = try self.enqueueTicketObjectDeletion(db,project:project,task:plan.round,cause:"media_round_delete",plan:plan.bytes)
                    receipt["round_id"] = plan.round;receipt["deletion"] = plan.audit
                    // The content-free first outcome remains replayable while
                    // this durable receipt exists, under ordinary pruning rules.
                    receipt["parent_principal"] = c.principal;receipt["parent_command_id"] = command;receipt["intent_digest"] = digest
                    try self.save(db,receipt,type:"storage_job")
                    for attachment in plan.keptAttachments {try self.save(db,attachment,type:"attachment")}
                    for row in plan.records {
                        try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)",arguments:[Data(row.id.utf8),Data(project.utf8),Data(row.type.utf8)])
                        guard db.changesCount == 1 else {throw MediaRoundDeletionFence.changed("owned_record_delete",type:row.type,id:Data(row.id.utf8))}
                    }
                    for id in plan.events {try db.execute(sql:"DELETE FROM events WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)])}
                    for (principal,id) in plan.commands {
                        try db.execute(sql:"UPDATE commands SET result=? WHERE principal=? AND command_id=?",arguments:[Self.prunedResult,principal,id])
                    }
                    try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('command-operation-purge-epoch',?)",arguments:[uuid()])
                    try self.event(db,caller:c,project:project,entity:plan.round,kind:"media_round_deleted",data:plan.audit)
                    result = try self.mediaRoundDeletionView(receipt)
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,command,digest,try jsonString(result)])
                    return .commit
                }
                return result
            }
        }} catch let error as CoreError where error.code == "MEDIA_CONTEXT_CHANGED" {
            var details = error.details
            details["preparation_seconds"] = plan.audit["preparation_seconds"]
            details["preparation_timings"] = plan.audit["preparation_timings"]
            throw CoreError(error.code,error.message,details:details)
        }
    }

    private func prepareMediaRoundDeletion(_ db: Database,_ p: JSON,_ c: Caller,project: String) throws -> MediaRoundDeletionPlan {
        let started = ProcessInfo.processInfo.systemUptime
        let version = try Int64.fetchOne(db,sql:"PRAGMA data_version")!
        let rid = try text(p,"round_id"),round = try scoped(db,rid,project,type:"media_round")
        try mediaRevision(p,round)
        let reason = try text(p,"reason",max:4000)
        guard ["closed","canceled","archived"].contains(round["state"] as? String ?? "") else {
            throw CoreError("MEDIA_ROUND_NOT_CLOSED","Finish or cancel the round before deleting it. Draft and Open rounds cannot be deleted.")
        }
        // Retain only the selected structural graph. The existing corpus stream
        // validates unrelated envelopes without retaining their private payloads.
        var selected: [Data:PurgeRow] = [:],selectedBytes = 0
        func add(_ value: JSON,type: String) throws {
            let id = try StoredRecord(value,family:type).string("id")
            guard selected[Data(id.utf8)] == nil else {return}
            let size = try jsonString(value).utf8.count
            selectedBytes += size
            guard size <= TicketCleanupInventory.rowByteLimit,selectedBytes <= TicketCleanupInventory.byteLimit,selected.count < 100_000 else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected media graph exceeds its safe bound; nothing was removed.")
            }
            guard EnvelopeStorageIdentity.equal(value["project_id"] as? String,project) else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A round-owned record has foreign scope.")}
            selected[Data(id.utf8)] = .init(id:id,type:type,project:project,value:value)
        }
        _ = try mediaRoundOwnedHistory(db,round:round) { original in
            var value = original
            let type = try StoredRecord(value,family:"media history").string("record_type")
            value.removeValue(forKey:"record_type");try add(value,type:type)
        }
        let mediaIDs = Set(selected.keys),itemIDs = Set(selected.values.filter {$0.type == "media_item"}.map(\.key))
        let scopedSources = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_review_context' AND json_type(data,'$.round_id') IS NULL AND EXISTS(SELECT 1 FROM json_each(records.data,'$.item_ids') i WHERE i.value IN (SELECT value FROM json_each(?)))",arguments:[Data(project.utf8),try jsonString(itemIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}).map {String(decoding:$0,as:UTF8.self)})])
        while let raw = try scopedSources.next() {
            let source = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"media_review_context")
            if Set(strings(source.object,"item_ids").map {Data($0.utf8)}).isSubset(of:itemIDs) {try add(source.object,type:source.type)}
        }
        func tokens(_ value: Any) throws -> Set<Data> {try TicketCleanupInventory.TokenObservation(value).tokens}
        var ownerIDs = Set<Data>(),attachmentIDs = Set<Data>()
        for row in selected.values {
            if let id = row.value["attachment_owner_id"] as? String {ownerIDs.insert(Data(id.utf8))}
            if row.type == "media_candidate" {
                for ref in row.value["record_references"] as? [JSON] ?? [] where ref["type"] as? String == "attachment" {
                    if let id = ref["id"] as? String {attachmentIDs.insert(Data(id.utf8))}
                }
            }
        }
        // Published successors get new anchors for borrowed candidates. Only
        // anchors exclusive to this structural graph belong to its removal;
        // shared predecessor anchors and their attachments stay independent.
        let mediaKeys = try jsonString(mediaIDs.map {String(decoding:$0,as:UTF8.self)})
        let ownerKeys = try jsonString(ownerIDs.map {String(decoding:$0,as:UTF8.self)})
        let borrowed = try Data.fetchAll(db,sql:"SELECT DISTINCT CAST(json_extract(data,'$.attachment_owner_id') AS BLOB) FROM records WHERE project_id=CAST(? AS TEXT) AND type IN ('media_intake','media_item_target') AND id NOT IN (SELECT value FROM json_each(?)) AND json_extract(data,'$.attachment_owner_id') IN (SELECT value FROM json_each(?))",arguments:[Data(project.utf8),mediaKeys,ownerKeys])
        ownerIDs.subtract(borrowed)
        for rawID in ownerIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            let id = String(decoding:rawID,as:UTF8.self)
            let value = try scoped(db,id,project,type:"storage_job")
            guard value["kind"] as? String == "media_attachment_owner" else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A round capture owner is unavailable.")}
            try add(value,type:"storage_job")
        }
        let anchors = try jsonString(ownerIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}).map {String(decoding:$0,as:UTF8.self)})
        let storage = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND ((type='storage_hold' AND json_extract(data,'$.kind')='media_reference' AND json_extract(data,'$.owner_id') IN (SELECT value FROM json_each(?))) OR (type='storage_job' AND json_extract(data,'$.kind')='attachment_import' AND json_extract(data,'$.attachment_owner_id') IN (SELECT value FROM json_each(?))))",arguments:[Data(project.utf8),anchors,anchors])
        while let raw = try storage.next() {
            let e = try GRDBRecordEnvelopeAdapter.decode(raw);try add(e.object,type:e.type)
            if e.type == "storage_job",let id = e.object["attachment_id"] as? String,
               try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE id=CAST(? AS TEXT) AND type='attachment')",arguments:[Data(id.utf8)]) == true {attachmentIDs.insert(Data(id.utf8))}
        }
        var keptAttachments: [JSON] = [],keptAudit: [JSON] = [],observedIDs = Set<Data>()
        for rawID in attachmentIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            let id = String(decoding:rawID,as:UTF8.self)
            let attachment = try scoped(db,id,project,type:"attachment")
            if attachment["task_id"] != nil {
                guard let taskID = attachment["task_id"] as? String,!taskID.isEmpty else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A captured attachment has malformed ticket ownership; nothing was removed.")}
                let task = try scoped(db,taskID,project,type:"task")
                let status = try scoped(db,try StoredRecord(task,family:"task").string("status_id"),project,type:"status")
                guard ["done","canceled"].contains(status["category"] as? String ?? "") else {
                    throw CoreError("MEDIA_ROUND_REFERENCED","An open ticket still owns a captured attachment; nothing was removed.",details:["record_id":id,"record_type":"attachment","task_id":taskID])
                }
                observedIDs.formUnion([rawID,Data(taskID.utf8),Data((try StoredRecord(status,family:"status").string("id")).utf8)])
                keptAttachments.append(attachment)
                keptAudit.append(["attachment_id":id,"task_id":taskID,"task_key":try StoredRecord(task,family:"task").string("key"),"status":"kept","reason":"kept_with_ticket"])
                continue
            }
            try add(attachment,type:"attachment")
        }
        let removed = selected.values.sorted {$0.key.lexicographicallyPrecedes($1.key)},owned = Set(selected.keys)
        // Active capture anchors/import jobs leave with the round. Preserve
        // their IDs as explicitly historical provenance on the ticket attachment,
        // rather than keeping dangling live ownership references.
        for index in keptAttachments.indices {
            var attachment = keptAttachments[index]
            var history: JSON = ["format":1,"state":"round_deleted","round_id":rid]
            var detached = false,captureDetached = false
            for (field,historical) in [("attachment_owner_id","owner_id"),("storage_job_id","import_job_id"),("media_cleanup_round_id","round_id")] {
                guard let id = attachment[field] as? String,owned.contains(Data(id.utf8)) else {continue}
                detached = true;history[historical] = id;attachment.removeValue(forKey:field)
                if field != "media_cleanup_round_id" {captureDetached = true}
                if field == "attachment_owner_id",let owner = selected[Data(id.utf8)] {history["owner_kind"] = owner.value["owner_kind"]}
            }
            // A later adopting round must not overwrite the original capture's
            // already detached provenance with its own use of that attachment.
            let needsHistory = attachment["media_capture_history"] == nil
            if captureDetached || needsHistory {attachment["media_capture_history"] = history}
            if detached || needsHistory {attachment = revised(attachment)}
            keptAttachments[index] = attachment
        }
        let keys = owned
        var tasks = Set(removed.filter {$0.type == "media_item"}.compactMap {$0.value["task_id"] as? String}.map {Data($0.utf8)})
        if let task = round["task_id"] as? String {tasks.insert(Data(task.utf8))}
        tasks.formUnion(keptAttachments.compactMap {$0["task_id"] as? String}.map {Data($0.utf8)})
        let attachments = removed.filter {$0.type == "attachment"}.map {row -> (String,JSON) in
            var value = row.value;value["media_cleanup_round_id"] = rid;return (row.type,value)
        }
        let keptObjects = try ticketObjectDeletionObjects(db,owned:keptAttachments.map {("attachment",$0)})
        let keptPaths = Set(keptObjects.compactMap {$0["relative_path"] as? String}.map {Data($0.utf8)})
        let importObjects = try mediaRoundDeletionImportObjects(db,jobs:removed.filter {$0.type == "storage_job" && $0.value["kind"] as? String == "attachment_import"}.map(\.value)).filter {object in
            guard let path = object["relative_path"] as? String else {return true}
            return !keptPaths.contains(Data(path.utf8))
        }
        var objects = try ticketObjectDeletionObjects(db,owned:attachments).filter {object in
            guard let path = object["relative_path"] as? String else {return true}
            return !keptPaths.contains(Data(path.utf8))
        }
        var positions: [Data:Int] = [:]
        for (index,object) in objects.enumerated() {if let path = object["relative_path"] as? String {positions[Data(path.utf8)] = index}}
        for object in importObjects {
            if let path = object["relative_path"] as? String,let index = positions[Data(path.utf8)] {
                var merged = objects[index]
                merged["owner_ids"] = Array(Set(strings(merged,"owner_ids") + strings(object,"owner_ids"))).sorted()
                var reasons = Set(strings(merged,"reasons") + strings(object,"reasons"))
                if merged["sha256"] as? String != object["sha256"] as? String || (merged["size"] as? NSNumber) != (object["size"] as? NSNumber) {reasons.insert("ambiguous_identity")}
                if !reasons.isEmpty {merged["state"] = "retained";merged["reasons"] = reasons.sorted()}
                objects[index] = merged
            } else {
                if let path = object["relative_path"] as? String {positions[Data(path.utf8)] = objects.count}
                objects.append(object)
            }
        }
        let paths = Set(objects.flatMap {[$0["relative_path"] as? String,$0["stored_path"] as? String,($0["relative_path"] as? String).map {root.appendingPathComponent($0).path}].compactMap {$0}}.map {Data($0.utf8)})
        let needles = keys.union(paths)
        let holdDigests = Set(objects.compactMap {$0["sha256"] as? String}.map {Data($0.utf8)})
        let graphFinished = ProcessInfo.processInfo.systemUptime
        var remaining = keptAttachments.map {attachment -> JSON in var value = attachment;value["record_type"] = "attachment";return value},remainingBytes = 0
        // The shared stream validates complete unrelated envelopes but returns
        // only headers above 16 KiB. Exact SQL matching admits relevant payloads
        // below the same safe bound; unrelated prose needs no second traversal.
        try streamTicketCleanupRows(db,needles:needles.union(tasks),holdDigests:holdDigests) {projected,size in
            var row = projected
            if size > TicketCleanupInventory.projectionByteLimit,(row.type == "project" || bool(row.value,"_cleanup_large_match")) {
                guard size <= TicketCleanupInventory.rowByteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A selected deletion reference exceeds its safe bound; nothing was removed.")}
                row = .init(id:row.id,type:row.type,project:row.project,value:try self.record(db,row.id,type:row.type))
            }
            if owned.contains(row.key) {return}
            if keptAttachments.contains(where:{Data(($0["id"] as? String ?? "").utf8) == row.key}) {return}
            let refs = try tokens(row.value),large = bool(row.value,"_cleanup_large_match")
            if row.type == "request",row.value["state"] as? String == "pending",
               tasks.contains(Data((row.value["task_id"] as? String ?? "").utf8)) || !refs.isDisjoint(with:keys) || large {
                throw CoreError("MEDIA_OWNER_REQUEST_PENDING","Answer or cancel the unresolved owner request before deleting this round.")
            }
            let accounting = ["cleanup_job","cleanup_preview"].contains(row.type) || row.type == "storage_job" && [Self.ticketObjectDeletionKind,"archive_cleanup_delete","archive_cleanup_cursor"].contains(row.value["kind"] as? String ?? "")
            if accounting {return}
            let matches = large || !refs.isDisjoint(with:needles)
            if row.type != "storage_hold",matches {
                throw CoreError("MEDIA_ROUND_REFERENCED","Another retained round, ticket or record still uses this round's records or files; nothing was removed.",details:["record_id":row.id,"record_type":row.type])
            }
            if row.type == "project" || row.type == "storage_hold" && (matches || !refs.isDisjoint(with:holdDigests)) {
                remainingBytes += size
                guard size <= TicketCleanupInventory.rowByteLimit,remainingBytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected deletion holds exceed their safe bound; nothing was removed.")}
                var value = row.value;value["record_type"] = row.type;remaining.append(value)
                if row.type != "project" {observedIDs.insert(row.key)}
            }
        }
        let referencesFinished = ProcessInfo.processInfo.systemUptime
        var cleanup = try ticketObjectDeletionPlan(db,owned:attachments,remaining:remaining,candidateObjects:objects)
        for index in cleanup.objects.indices where strings(cleanup.objects[index],"reasons").contains("reader_lease") {
            cleanup.objects[index]["reader_hold_ids"] = try mediaRoundDeletionReaderHoldIDs(db,object:cleanup.objects[index])
        }
        let cleanupFinished = ProcessInfo.processInfo.systemUptime
        var events: [String] = [],commands: [(String,String)] = []
        let historyTokens = try jsonString(keys.map {String(decoding:$0,as:UTF8.self)})
        // History needs exact text atoms and dictionary keys, not a Foundation
        // object graph for every unrelated receipt. SQLite streams the complete
        // JSON; only matching identities cross this read-lane boundary.
        func historyMatch(_ payload: String) -> String {
            "EXISTS(SELECT 1 FROM json_tree(CASE WHEN json_valid(\(payload)) THEN CASE WHEN json_type(\(payload))='object' THEN \(payload) ELSE '{}' END ELSE '{}' END) j WHERE (j.type='text' AND CAST(j.atom AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))) OR (typeof(j.key)='text' AND CAST(j.key AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))))"
        }
        let history = try Row.fetchCursor(db,sql:"SELECT id,entity_id,CASE WHEN kind GLOB 'media_*' THEN " + historyMatch("data") + " ELSE 0 END AS media_reference FROM events WHERE project_id=CAST(? AS TEXT)",arguments:[historyTokens,historyTokens,Data(project.utf8)])
        var historyCount = 0
        while let row = try history.next() {
            historyCount += 1;guard historyCount <= 100_000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The deletion history exceeds its safe bound.")}
            if owned.contains(Data((row["entity_id"] as String? ?? "").utf8)) || row["media_reference"] as Bool {events.append(row["id"])}
        }
        let receipts = try Row.fetchCursor(db,sql:"SELECT principal,command_id," + historyMatch("result") + " AS media_reference FROM commands",arguments:[historyTokens,historyTokens])
        var receiptCount = 0
        while let row = try receipts.next() {
            receiptCount += 1;guard receiptCount <= 100_000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The deletion command history exceeds its safe bound.")}
            if row["media_reference"] as Bool {commands.append((row["principal"],row["command_id"]))}
        }
        let counts = removed.reduce(into:[String:Int]()) {$0[$1.type,default:0] += 1}
        observedIDs.formUnion(owned)
        let fence = try MediaRoundDeletionFence(db,ids:observedIDs,events:events,commands:commands,needles:needles,pendingRequestTasks:tasks,holdDigests:holdDigests,filePaths:objects.compactMap {($0["relative_path"] as? String).map {root.appendingPathComponent($0).path}})
        let historyFinished = ProcessInfo.processInfo.systemUptime
        let audit: JSON = ["deleted":true,"round_id":rid,"project_id":project,"actor":c.principal,"actor_kind":c.isOwner ? "owner" : "agent","reason":reason,"counts":counts,"kept_attachments":keptAudit,
            "preparation_seconds":historyFinished-started,"preparation_timings":["graph_seconds":graphFinished-started,"references_seconds":referencesFinished-graphFinished,"cleanup_seconds":cleanupFinished-referencesFinished,"history_seconds":historyFinished-cleanupFinished]]
        return .init(version:version,project:project,round:rid,records:removed,events:events,commands:commands,bytes:cleanup,audit:audit,keptAttachments:keptAttachments,fence:fence)
    }
}
