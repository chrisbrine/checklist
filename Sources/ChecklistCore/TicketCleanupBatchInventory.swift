import Foundation
import GRDB

/// One observation shared by a bounded lifecycle selection. A large selected
/// ticket is refused individually; it cannot discard other tickets' inventories.
struct TicketCleanupBatchInventory {
    static let byteLimit = 64 * 1024 * 1024
    var inventories: [String:TicketCleanupInventory] = [:]
    var errors: [String:CoreError] = [:]
}

private struct CleanupOwnershipHeader {
    let id: String
    let type: String
    let project: String?
    let task: Data?
    let bytes: Int
}

private struct CleanupOwnershipGraph {
    // Headers/edges are discarded before payload inventories are loaded. The
    // conservative charge includes dictionary, array and Data entry overhead.
    static let byteLimit = 32 * 1024 * 1024
    var nodes: [Data:CleanupOwnershipHeader] = [:]
    var children: [Data:[Data]] = [:]
    var seeds: [String:Set<Data>] = [:]
    var retainedBytes = 0
    var overflowed = false

    mutating func add(_ row: PurgeRow,bytes: Int,tasks: Set<String>) {
        guard !overflowed else {return}
        let containers: Set<String> = ["project","session","profile","status","tag","policy_revision","project_context_revision","taxonomy_revision","group","batch","batch_claim","relation","task"]
        let direct = row.type == "relation" && (row.value["source_task_id"] as? String).map {tasks.contains($0)} == true
        let eligible = !containers.contains(row.type) && row.type != "storage_hold" && !(row.type == "storage_job" && row.value["kind"] as? String == CommandRouter.ticketObjectDeletionKind)
        let task = row.value["task_id"] as? String
        let local = row.value["task_id"] == nil || task.map {tasks.contains($0)} == true
        let parents = ["message_id","attempt_id","parent_attempt_id","request_id","review_request_id","manifest_id","membership_id","delegation_id","conversation_id","source_capture_id"].compactMap {row.value[$0] as? String}
        guard direct || eligible && local && (task != nil || !parents.isEmpty) else {return}
        let charge = row.id.utf8.count + row.type.utf8.count + (row.project?.utf8.count ?? 0) + (task?.utf8.count ?? 0) + 256 + parents.reduce(0) {$0 + $1.utf8.count + 128}
        guard retainedBytes + charge <= Self.byteLimit else {
            overflowed = true;nodes.removeAll();children.removeAll();seeds.removeAll();return
        }
        retainedBytes += charge
        nodes[row.key] = CleanupOwnershipHeader(id:row.id,type:row.type,project:row.project,task:task.map {Data($0.utf8)},bytes:bytes)
        if direct,let tid = row.value["source_task_id"] as? String {seeds[tid,default:[]].insert(row.key)}
        if eligible && local {
            if let task {seeds[task,default:[]].insert(row.key)}
            for parent in parents {children[Data(parent.utf8),default:[]].append(row.key)}
        }
    }

    func ownership(task: String,project: String) throws -> [CleanupOwnershipHeader] {
        let tid = Data(task.utf8)
        var found = seeds[task] ?? [],level = Array(found),bytes = 0
        func check(_ key: Data) throws {
            guard let node = nodes[key],node.bytes <= TicketCleanupInventory.rowByteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A selected cleanup row exceeds its bound; bytes retained.")}
            bytes += node.bytes
            guard found.count <= 4096,bytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected ticket exceeds the bounded cleanup inventory; bytes retained.")}
        }
        for key in level {try check(key)}
        var depth = 0
        while !level.isEmpty {
            var next: [Data] = []
            for parent in level {
                for child in children[parent] ?? [] {
                    guard let node = nodes[child],node.project == project,node.task == nil || node.task == tid,!found.contains(child) else {continue}
                    guard depth < 64 else {throw CoreError("PURGE_LIMIT","Cleanup ownership depth exceeds its bound; bytes retained.")}
                    found.insert(child);try check(child);next.append(child)
                }
            }
            level = next;depth += 1
        }
        return found.compactMap {nodes[$0]}.sorted {$0.id < $1.id}
    }
}

extension CommandRouter {
    /// Validate the complete corpus twice per batch, rather than once per
    /// ownership depth and ticket. Only bounded ownership headers survive the
    /// first stream; only exact owned/referencing rows survive the second.
    func ticketCleanupInventories(_ db: Database,tasks: [JSON]) throws -> TicketCleanupBatchInventory {
        guard tasks.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 tickets per observation.")}
        var result = TicketCleanupBatchInventory(),selected: [String:JSON] = [:],scopes: [String:Set<String>] = [:]
        for task in tasks {
            let stored = try StoredRecord(task,family:"task"),tid = try stored.string("id"),pid = try stored.string("project_id")
            selected[tid] = task;scopes[pid,default:[]].insert(tid)
        }
        guard !selected.isEmpty else {return result}
        var graph = CleanupOwnershipGraph()
        try streamTicketCleanupRows(db) {row,size in
            if let pid = row.project,let ids = scopes[pid] {graph.add(row,bytes:size,tasks:ids)}
        }
        // A pathological global header graph uses the established one-ticket
        // path. Its limits still isolate a large ticket and bound retained bytes.
        if graph.overflowed {
            var bytes = 0
            for tid in selected.keys.sorted() {
                do {
                    let inventory = try ticketCleanupInventory(db,task:selected[tid]!)
                    guard bytes + inventory.retainedBytes <= TicketCleanupBatchInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The cleanup batch exceeds its memory bound; this ticket is deferred.")}
                    bytes += inventory.retainedBytes;result.inventories[tid] = inventory
                } catch let error as CoreError {result.errors[tid] = error}
            }
            return result
        }
        var owned: [String:[CleanupOwnershipHeader]] = [:]
        for tid in selected.keys.sorted() {
            do {owned[tid] = try graph.ownership(task:tid,project:try StoredRecord(selected[tid]!,family:"task").string("project_id"))}
            catch let error as CoreError {result.errors[tid] = error}
        }
        graph = CleanupOwnershipGraph()
        var retainedBytes = 0
        for tid in selected.keys.sorted() where result.errors[tid] == nil {
            do {
                var inventory = TicketCleanupInventory()
                for header in owned[tid] ?? [] {
                    let row = PurgeRow(id:header.id,type:header.type,project:selected[tid]?["project_id"] as? String,value:try record(db,header.id,type:header.type))
                    try inventory.add(row,bytes:header.bytes) {row.value}
                }
                inventory.needles = Set((owned[tid] ?? []).map {Data($0.id.utf8)}).union([Data(tid.utf8)])
                try ticketCleanupBatchOwnershipPaths(db,inventory:&inventory)
                guard retainedBytes + inventory.retainedBytes <= TicketCleanupBatchInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The cleanup batch exceeds its memory bound; this ticket is deferred.")}
                retainedBytes += inventory.retainedBytes;result.inventories[tid] = inventory
            } catch let error as CoreError {result.errors[tid] = error}
        }
        owned.removeAll()
        guard !result.inventories.isEmpty else {return result}
        let needles = result.inventories.values.reduce(into:Set<Data>()) {$0.formUnion($1.needles)}
        let digests = result.inventories.values.reduce(into:Set<Data>()) {$0.formUnion($1.holdDigests)}
        let prefixes = result.inventories.values.reduce(into:Set<String>()) {$0.formUnion($1.prefixes)}
        var union = TicketCleanupInventory();union.needles = needles;union.holdDigests = digests;union.prefixes = prefixes
        let tickets = result.inventories.keys.sorted()
        try streamTicketCleanupRows(db,needles:needles,holdDigests:digests,prefixes:prefixes,fullPayloads:true) {row,size in
            guard !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) else {return}
            // This stream supplies full canonical payloads through the row
            // limit. Owned rows already have exact same-snapshot tokens; every
            // other payload is tokenized once for matching and all admissions.
            var observed: TicketCleanupInventory.TokenObservation?
            for tid in tickets {
                if let tokens = result.inventories[tid]?.tokens[row.key] {
                    observed = TicketCleanupInventory.TokenObservation(tokens:tokens)
                    break
                }
            }
            let observation: TicketCleanupInventory.TokenObservation
            do {observation = try observed ?? TicketCleanupInventory.TokenObservation(row.value)}
            catch let error as CoreError where error.code == "REFERENCE_GRAPH_LIMIT" {
                // Full-payload streaming must not turn an unrelated deep row
                // into a global refusal. SQL identifies only the inventories
                // whose exact references would require that bounded traversal.
                for tid in tickets {
                    guard let inventory = result.inventories[tid] else {continue}
                    if try row.type == "project" || row.key == Data(tid.utf8) || self.ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory) {
                        retainedBytes -= inventory.retainedBytes
                        result.inventories.removeValue(forKey:tid);result.errors[tid] = error
                    }
                }
                return
            }
            guard row.type == "project" || bool(row.value,"_cleanup_large_match") || union.mentions(observation,includeDigests:row.type == "storage_hold") else {return}
            for tid in tickets {
                guard var inventory = result.inventories.removeValue(forKey:tid) else {continue}
                retainedBytes -= inventory.retainedBytes
                do {
                    let relevant = try row.type == "project" || row.key == Data(tid.utf8) || inventory.mentions(observation,includeDigests:row.type == "storage_hold") ||
                        (size > TicketCleanupInventory.rowByteLimit && bool(row.value,"_cleanup_large_match") && self.ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory))
                    if relevant {
                        guard retainedBytes + inventory.retainedBytes + (inventory.tokens[row.key] == nil ? size : 0) <= TicketCleanupBatchInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The cleanup batch exceeds its memory bound; this ticket is deferred.")}
                        try inventory.add(row,bytes:size,observation:observation)
                    }
                    retainedBytes += inventory.retainedBytes;result.inventories[tid] = inventory
                } catch let error as CoreError {result.errors[tid] = error}
            }
        }
        return result
    }

    /// Receipt-specific byte deletion inventories share one complete validated
    /// stream. Receipt identity remains the key: separate jobs for one ticket
    /// can protect different objects and must keep independent refusals.
    func ticketCleanupDeletionInventories(_ db: Database,receipts: [JSON]) throws -> TicketCleanupBatchInventory {
        guard receipts.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 deletion receipts per observation.")}
        var result = TicketCleanupBatchInventory(),union = TicketCleanupInventory()
        for receipt in receipts {
            let id = try StoredRecord(receipt,family:"storage_job").string("id")
            var inventory = TicketCleanupInventory()
            inventory.objects(receipt["objects"] as? [JSON] ?? [],root:root)
            inventory.needles.formUnion((receipt["owned_record_fingerprints"] as? [String:String] ?? [:]).keys.map {Data($0.utf8)})
            if let tid = receipt["task_id"] as? String {inventory.needles.insert(Data(tid.utf8))}
            result.inventories[id] = inventory
            union.needles.formUnion(inventory.needles);union.holdDigests.formUnion(inventory.holdDigests);union.prefixes.formUnion(inventory.prefixes)
        }
        guard !result.inventories.isEmpty else {return result}
        let ids = result.inventories.keys.sorted()
        var retainedBytes = 0
        try streamTicketCleanupRows(db,needles:union.needles,holdDigests:union.holdDigests,prefixes:union.prefixes,fullPayloads:true) {row,size in
            // Accounting remains fully validated by the stream, but is never
            // reference authority for another deletion receipt.
            guard !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) else {return}
            let observation: TicketCleanupInventory.TokenObservation
            do {observation = try TicketCleanupInventory.TokenObservation(row.value)}
            catch let error as CoreError where error.code == "REFERENCE_GRAPH_LIMIT" {
                for id in ids {
                    guard let inventory = result.inventories[id] else {continue}
                    if try row.type == "project" || self.ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory) {
                        retainedBytes -= inventory.retainedBytes
                        result.inventories.removeValue(forKey:id);result.errors[id] = error
                    }
                }
                return
            }
            guard row.type == "project" || bool(row.value,"_cleanup_large_match") || union.mentions(observation,includeDigests:row.type == "storage_hold") else {return}
            for id in ids {
                guard var inventory = result.inventories.removeValue(forKey:id) else {continue}
                retainedBytes -= inventory.retainedBytes
                do {
                    let relevant = try row.type == "project" || inventory.mentions(observation,includeDigests:row.type == "storage_hold") ||
                        (size > TicketCleanupInventory.rowByteLimit && bool(row.value,"_cleanup_large_match") && self.ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory))
                    if relevant {
                        guard retainedBytes + inventory.retainedBytes + (inventory.tokens[row.key] == nil ? size : 0) <= TicketCleanupBatchInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The cleanup batch exceeds its memory bound; this receipt is deferred.")}
                        try inventory.add(row,bytes:size,observation:observation)
                    }
                    retainedBytes += inventory.retainedBytes;result.inventories[id] = inventory
                } catch let error as CoreError {result.errors[id] = error}
            }
        }
        return result
    }

    private func ticketCleanupBatchOwnershipPaths(_ db: Database,inventory: inout TicketCleanupInventory) throws {
        for row in inventory.rows {
            if row.type == "attachment" {for field in ["path","preview_path"] {if let path = row.value[field] as? String {inventory.path(path,root:root)}}}
            var captures: [JSON] = row.type == "source_capture" ? [row.value] : []
            if row.type == "manifest",let evidence = row.value["evidence"] as? JSON,let capture = evidence["source_capture"] as? JSON {captures.append(capture)}
            for capture in captures {
                if let path = capture["snapshot_path"] as? String {
                    inventory.path(path,root:root,prefix:true)
                    inventory.path(String(path.dropLast("/source".count)) + "/manifest.json",root:root)
                }
                if let id = capture["id"] as? String {inventory.needles.insert(Data(id.utf8))}
            }
            if row.type == "source_execution",let path = try sourceBuildCachePath(db,execution:row.value) {inventory.path(path,root:root,prefix:true)}
            inventory.holdDigests.formUnion((inventory.tokens[row.key] ?? []).filter {$0.count == 64})
        }
    }

    /// A row beyond Swift's byte/traversal bound refuses only exact targets.
    /// SQLite traverses the already validated payload without loading it in Swift.
    func ticketCleanupBatchLargeMatch(_ db: Database,row: PurgeRow,inventory: TicketCleanupInventory) throws -> Bool {
        let tokens = try jsonString(inventory.needles.map {String(decoding:$0,as:UTF8.self)})
        let digests = try jsonString(inventory.holdDigests.map {String(decoding:$0,as:UTF8.self)})
        let prefixes = try jsonString(Array(inventory.prefixes))
        return try Bool.fetchOne(db,sql:"""
            WITH targets AS (SELECT CAST(value AS BLOB) value FROM json_each(?) UNION SELECT CAST(value AS BLOB) FROM json_each(?) WHERE ?='storage_hold'),
            prefixes AS (SELECT CAST(value||'/' AS BLOB) lo,CAST(value||'0' AS BLOB) hi FROM json_each(?))
            SELECT EXISTS(SELECT 1 FROM records r,json_tree(r.data) j WHERE r.id=CAST(? AS TEXT) AND (
                (j.type='text' AND (CAST(j.atom AS BLOB) IN targets OR EXISTS(SELECT 1 FROM prefixes p WHERE CAST(j.atom AS BLOB)>=p.lo AND CAST(j.atom AS BLOB)<p.hi))) OR
                (typeof(j.key)='text' AND (CAST(j.key AS BLOB) IN targets OR EXISTS(SELECT 1 FROM prefixes p WHERE CAST(j.key AS BLOB)>=p.lo AND CAST(j.key AS BLOB)<p.hi)))))
            """,arguments:[tokens,digests,row.type,prefixes,Data(row.id.utf8)]) ?? false
    }
}
