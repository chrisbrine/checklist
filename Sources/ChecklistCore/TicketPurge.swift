import Foundation
import GRDB

struct PurgeRow {
    let id: String
    let type: String
    let project: String?
    let value: JSON
    var key: Data {Data(id.utf8)}
}
struct TicketPurgePlan {
    let removed: [PurgeRow]
    let shared: [PurgeRow]
    let groups: [PurgeRow]
    let events: [Row]
    let byteDeletion: TicketObjectDeletionPlan
    let impact: JSON
    let digest: String
}

extension CommandRouter {
    func requirePurgeSafe(_ db: Database, task: JSON, automatic: Bool = false) throws {
        guard !bool(task,"purged") else {throw CoreError("TICKET_PURGED","This ticket was already permanently removed.")}
        guard let key = task["key"] as? String,!key.isEmpty else {throw CoreError("PURGE_REFERENCE_REQUIRED","A stable ticket key is required before permanent removal.")}
        try requireRetirementSafe(db,task:task)
        guard automatic || bool(task,"trashed") else {throw CoreError("TRASH_REQUIRED","Move this ticket to Trash before permanently removing it.")}
        let pending = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE type='request' AND project_id=? AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.state')='pending')",arguments:[task["project_id"] as! String,task["id"] as! String]) ?? false
        guard !pending else {throw CoreError("OWNER_REQUEST_PENDING","Answer or cancel this ticket's pending owner request before permanently removing it.")}
    }

    /// One bounded reference inventory per command, never a full-table scan per row.
    /// Unknown references conservatively retain a shared record; they never grant unlink authority.
    func ticketPurgePlan(_ db: Database, task: JSON, inventory: TicketCleanupInventory? = nil) throws -> TicketPurgePlan {
        let pid = task["project_id"] as! String,tid = task["id"] as! String,taskKey = Data(tid.utf8)
        let rows = try inventory == nil ? Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records ORDER BY rowid LIMIT 100001") : []
        guard rows.count <= 100000 else {throw CoreError("PURGE_LIMIT","The reference inventory exceeds the safe purge limit. No content was removed.")}
        let all = try inventory?.rows ?? rows.map {row -> PurgeRow in let e = try GRDBRecordEnvelopeAdapter.decode(row);return PurgeRow(id:e.id,type:e.type,project:e.projectID,value:e.object)}
        func equals(_ value: Any?, _ id: String) -> Bool {(value as? String).map {Data($0.utf8) == Data(id.utf8)} ?? false}
        let containers: Set<String> = ["project","session","profile","status","tag","policy_revision","project_context_revision","taxonomy_revision","group","batch","batch_claim","relation","task"]
        var owned = Set(all.filter {$0.project == pid && !containers.contains($0.type) && $0.type != "storage_hold" && !($0.type == "storage_job" && $0.value["kind"] as? String == Self.ticketObjectDeletionKind) && equals($0.value["task_id"],tid)}.map(\.key))
        owned.formUnion(all.filter {$0.project == pid && $0.type == "relation" && equals($0.value["source_task_id"],tid)}.map(\.key))
        let ownerFields = ["message_id","attempt_id","parent_attempt_id","request_id","review_request_id","manifest_id","membership_id","delegation_id","conversation_id","source_capture_id"]
        // Index parent ownership once, then walk each child at most once.
        var children: [Data:[Data]] = [:]
        for row in all where row.project == pid && !containers.contains(row.type) && row.type != "storage_hold" && !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) {
            if let other = row.value["task_id"] as? String,Data(other.utf8) != taskKey {continue}
            for field in ownerFields {if let parent = row.value[field] as? String {children[Data(parent.utf8),default:[]].append(row.key)}}
        }
        var work = Array(owned)
        while let parent = work.popLast() {for child in children[parent] ?? [] where owned.insert(child).inserted {work.append(child)}}
        var edgeBudget = 0
        func tokens(_ value: Any, depth: Int = 0) throws -> Set<Data> {
            guard depth <= 64,edgeBudget < 2000000 else {throw CoreError("PURGE_LIMIT","The reference inventory exceeds the safe purge limit. No content was removed.")}
            edgeBudget += 1
            if let s = value as? String {return [Data(s.utf8)]}
            if let a = value as? [Any] {return try a.reduce(into:Set<Data>()) {$0.formUnion(try tokens($1,depth:depth+1))}}
            if let d = value as? JSON {return try d.reduce(into:Set<Data>()) {result,entry in result.insert(Data(entry.key.utf8));result.formUnion(try tokens(entry.value,depth:depth+1))}}
            return []
        }
        // Remove current grouping entries, including task-specific frozen batch
        // entries. Other tickets' entries and the container itself survive.
        func withoutMember(_ value: Any) -> Any? {
            if let s = value as? String {return Data(s.utf8) == taskKey ? nil : s}
            if let a = value as? [Any] {return a.compactMap {withoutMember($0)}}
            if let d = value as? JSON {
                if equals(d["task_id"],tid) {return nil}
                return d.reduce(into:JSON()) {result,entry in
                    if Data(entry.key.utf8) != taskKey,let v = withoutMember(entry.value) {result[entry.key] = v}
                }
            }
            return value
        }
        var groups: [PurgeRow] = []
        for row in all where row.project == pid && ["group","batch","batch_claim"].contains(row.type) {
            guard try tokens(row.value).contains(taskKey) else {continue}
            var value = row.value
            for field in ["members","task_ids","tasks","claims","results","submissions","verdicts"] where value[field] != nil {value[field] = withoutMember(value[field]!) ?? []}
            groups.append(PurgeRow(id:row.id,type:row.type,project:row.project,value:value))
        }
        let groupValues = Dictionary(uniqueKeysWithValues:groups.map {($0.key,$0.value)})
        var references: [Data:Set<Data>] = [:],relevant = Set<Data>()
        for row in all {
            let bookkeeping = row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind
            let refs = try bookkeeping ? Set<Data>() : (groupValues[row.key] != nil ? tokens(groupValues[row.key]!) : inventory?.tokens[row.key] ?? tokens(row.value))
            references[row.key] = refs
            if refs.contains(taskKey) || !refs.isDisjoint(with:owned) {relevant.insert(row.key)}
        }
        // Incoming ticket relations always resolve to the ticket tombstone. They
        // do not keep the purged ticket's private content. Other true references
        // retain their shared target and its transitive dependencies.
        var protected = Set<Data>()
        for row in all where row.key != taskKey && !owned.contains(row.key) {protected.formUnion((references[row.key] ?? []).intersection(owned))}
        var pending = Array(protected)
        while let key = pending.popLast() {
            for target in (references[key] ?? []).intersection(owned) where protected.insert(target).inserted {pending.append(target)}
        }
        let removed = all.filter {owned.contains($0.key) && !protected.contains($0.key)}
        let shared = all.filter {protected.contains($0.key)}
        let removedKeys = Set(removed.map(\.key))
        let eventRows = try Row.fetchCursor(db,sql:"SELECT seq,id,entity_id,data FROM events WHERE project_id=? ORDER BY seq LIMIT 100001",arguments:[pid])
        var events: [Row] = [],eventCount = 0,historyBytes = 0
        while let row = try eventRows.next() {
            eventCount += 1
            guard eventCount <= 100000 else {throw CoreError("PURGE_LIMIT","The ticket history exceeds the safe purge limit.")}
            guard (row["data"] as String).utf8.count <= TicketCleanupInventory.rowByteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A history row exceeds the memory bound.")}
            let entity = (row["entity_id"] as String?).map {Data($0.utf8)}
            let matched = try autoreleasepool {try entity == taskKey || entity.map({removedKeys.contains($0)}) == true || !tokens(jsonObject(row["data"])).isDisjoint(with:removedKeys.union([taskKey]))}
            if matched {
                historyBytes += (row["data"] as String).utf8.count
                guard historyBytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected ticket history exceeds the memory bound.")}
                events.append(row.copy())
            }
        }
        let counts = removed.reduce(into:[String:Int]()) {$0[$1.type,default:0] += 1}
        let managed = all.filter {owned.contains($0.key) && $0.type == "attachment" && $0.value["mode"] as? String == "managed"}
        let backups = try Row.fetchAll(db,sql:"SELECT json_object('known_at',json_extract(value,'$.known_at'),'created_at',json_extract(value,'$.created_at')) AS value FROM metadata WHERE key LIKE 'backup-generation:%' ORDER BY key").map {jsonObject($0["value"])}
        let relationCount = all.filter {$0.project == pid && $0.type == "relation" && equals($0.value["target_task_id"],tid) && !equals($0.value["source_task_id"],tid)}.count
        let remaining = all.filter {!removedKeys.contains($0.key) && $0.key != taskKey}.map {row -> JSON in var value = groupValues[row.key] ?? row.value;value["record_type"] = row.type;return value}
        let byteDeletion = try ticketObjectDeletionPlan(db,owned:all.filter {owned.contains($0.key)}.map {($0.type,$0.value)},remaining:remaining,referenceTokens:inventory.map {_ in references})
        let impact: JSON = ["task_id":tid,"project_id":pid,"expected_revision":task["revision"]!,"record_counts":counts,"removed_record_count":removed.count,"shared_record_count":shared.count,"history_events":events.count,"preserved_relation_count":relationCount,
            "managed_attachment_count":managed.count,"managed_attachment_logical_bytes":managed.reduce(0){$0+int($1.value,"size")},"managed_bytes_deleted":0,"managed_bytes_action":"post_commit_deletion","byte_deletion":byteDeletion.summary,"byte_deletion_objects":byteDeletion.objects,
            "known_backup_count":backups.count,"known_backup_observed_times":backups.compactMap {$0["known_at"] as? String},"known_backup_creation_times":backups.compactMap {$0["created_at"] as? String}]
        let digestBasis: JSON = ["incarnation":incarnation,"task":task,"impact":impact,
            "owned":all.filter {owned.contains($0.key)}.map(\.value),"references":all.filter {relevant.contains($0.key) && !owned.contains($0.key) && $0.key != taskKey}.map(\.value),
            "groups":groups.map(\.value),"events":events.map {["id":$0["id"] as String,"data":jsonObject($0["data"])] as JSON}]
        return TicketPurgePlan(removed:removed,shared:shared,groups:groups,events:events,byteDeletion:byteDeletion,impact:impact,digest:hash(Data(try jsonString(digestBasis).utf8)))
    }

    func taskPurgePreview(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c);let pid = try scope(db,p,c),task = try self.task(db,p,pid)
        try revision(p,task);try requirePurgeSafe(db,task:task)
        let plan = try ticketPurgePlan(db,task:task)
        return ["preview_id":plan.digest,"digest":plan.digest,"impact":plan.impact,"can_purge":true,"blockers":[],
            "removes":"Permanently removes this ticket's private content and exclusively owned notes, work, requests, reviews and file records. Earlier history rows keep their place with their content cleared. Earlier cached command results are expired.",
            "preserves":"A minimal Purged ticket reference, incoming relations, shared records and other tickets remain. Exclusively owned managed originals, previews and captured-source bytes are queued for verified deletion after commit. Shared, reader-held and backup-referenced bytes remain. External originals and workspace files are never deleted. This is not secure erasure.",
            "backup_warning":"Backups and exports made before this purge may contain this ticket. Checklist does not change existing backups or exports; delete those copies yourself if needed. Recorded backup observation times are not guaranteed creation times."]
    }

    func ticketPurgeExpiringCommands(_ db: Database,task: JSON,plan: TicketPurgePlan) throws -> [Row] {
        let removedIDs = Set(plan.removed.map(\.key)).union([Data((task["id"] as! String).utf8)])
        let receipts = try Row.fetchCursor(db,sql:"SELECT rowid AS cleanup_row,principal,command_id,CAST(principal AS BLOB) AS cleanup_principal,CAST(command_id AS BLOB) AS cleanup_command_id,result FROM commands LIMIT 100001")
        func containsRemoved(_ value: Any) -> Bool {
            if let s = value as? String {return removedIDs.contains(Data(s.utf8))}
            if let a = value as? [Any] {return a.contains {containsRemoved($0)}}
            if let d = value as? JSON {return d.contains {removedIDs.contains(Data($0.key.utf8)) || containsRemoved($0.value)}}
            return false
        }
        var selected: [Row] = [],count = 0,bytes = 0
        while let row = try receipts.next() {
            count += 1
            guard count <= 100000 else {throw CoreError("PURGE_LIMIT","The command history exceeds the safe purge limit.")}
            guard (row["result"] as String).utf8.count <= TicketCleanupInventory.rowByteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A command history row exceeds the memory bound.")}
            if autoreleasepool(invoking:{containsRemoved(jsonObject(row["result"]))}) {
                bytes += (row["result"] as String).utf8.count
                guard bytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected command history exceeds the memory bound.")}
                selected.append(row.copy())
            }
        }
        return selected
    }

    func taskPurge(_ db: Database,_ p: JSON,_ c: Caller, automatic: Bool = false, prepared: TicketPurgePlan? = nil, expiredCommands: [Row]? = nil) throws -> JSON {
        try owner(c);let pid = try scope(db,p,c,write:!automatic),task = try self.task(db,p,pid)
        try revision(p,task);try requirePurgeSafe(db,task:task,automatic:automatic)
        let plan = try prepared ?? ticketPurgePlan(db,task:task)
        guard try text(p,"preview_digest") == plan.digest else {throw CoreError("PURGE_PREVIEW_STALE","This ticket or its references changed. Read a new permanent-removal preview before confirming.")}
        let tid = task["id"] as! String
        // Expiring receipts keeps idempotency ownership/digests but prevents a
        // retry of an earlier create/note/read-modify command returning purged text.
        let receipts = try expiredCommands ?? ticketPurgeExpiringCommands(db,task:task,plan:plan)
        for receipt in receipts {
            try db.execute(sql:"UPDATE commands SET result=? WHERE principal=CAST(? AS TEXT) AND command_id=CAST(? AS TEXT)",arguments:[Self.prunedResult,receipt["cleanup_principal"] as Data,receipt["cleanup_command_id"] as Data])
        }
        let expired = receipts.count
        let deletion = try enqueueTicketObjectDeletion(db,project:pid,task:tid,cause:"task_purge",plan:plan.byteDeletion)
        for row in plan.removed {try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)",arguments:[Data(row.id.utf8),Data(pid.utf8),Data(row.type.utf8)])}
        for group in plan.groups {try save(db,revised(group.value),type:group.type)}
        let tombstone: JSON = ["id":tid,"project_id":pid,"key":task["key"]!,"title":"Purged ticket","revision":int(task,"revision")+1,"purged":true,"purged_at":now(),"purged_by":automatic ? "system:ticket_cleanup" : c.principal,"trashed":true,"archived":true]
        try save(db,tombstone,type:"task")
        for row in plan.events {try db.execute(sql:"UPDATE events SET data='{}' WHERE seq=? AND project_id=CAST(? AS TEXT)",arguments:[row["seq"] as Int64,Data(pid.utf8)])}
        var counts: JSON = ["removed_records":plan.removed.count,"retained_shared_records":plan.shared.count,"scrubbed_history_events":plan.events.count,"expired_command_results":expired,"managed_bytes_deleted":0]
        if automatic {counts["origin"] = "automatic_cleanup"}
        try event(db,caller:c,project:pid,entity:tid,kind:"task_purged",data:counts)
        return ["task":tombstone,"counts":counts,"byte_deletion_receipt_id":deletion["id"]!,"byte_deletion":deletion,"managed_bytes_action":"pending","warning":"Exclusive managed bytes are deleted after commit through the durable byte receipt. Shared, held and backup-referenced bytes, existing backups and exports remain. External originals and workspace files are never deleted."]
    }
}
