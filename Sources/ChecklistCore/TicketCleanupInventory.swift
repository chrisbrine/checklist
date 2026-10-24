import Foundation
import GRDB

/// Read-lane, ticket-specific inventory. The corpus is streamed, never cached.
/// Every envelope is decoded/validated; only ownership and exact relevant
/// references survive the observation. Limits fail closed before any admission.
struct TicketCleanupInventory {
    static let byteLimit = 16 * 1024 * 1024
    static let rowByteLimit = 4 * 1024 * 1024
    static let projectionByteLimit = 16 * 1024
    var rows: [PurgeRow] = []
    var tokens: [Data:Set<Data>] = [:]
    var needles = Set<Data>()
    var holdDigests = Set<Data>()
    var prefixes = Set<String>()
    var retainedBytes = 0

    static func strings(_ value: Any,_ visit: (String) -> Void,depth: Int = 0,budget: inout Int) throws {
        budget -= 1
        guard depth <= 64,budget >= 0 else {throw CoreError("REFERENCE_GRAPH_LIMIT","Cleanup reference traversal exceeded its bound; bytes retained.")}
        if let s = value as? String {visit(s)}
        else if let a = value as? [Any] {for v in a {try strings(v,visit,depth:depth+1,budget:&budget)}}
        else if let d = value as? JSON {for (k,v) in d {visit(k);try strings(v,visit,depth:depth+1,budget:&budget)}}
    }
    func mentions(_ value: Any,includeDigests: Bool = false) throws -> Bool {
        var matched = false,budget = 2000000
        try Self.strings(value,{s in
            if needles.contains(Data(s.utf8)) || includeDigests && holdDigests.contains(Data(s.utf8)) || prefixes.contains(where: {s.hasPrefix($0 + "/")}) {matched = true}
        },budget:&budget)
        return matched
    }
    mutating func add(_ row: PurgeRow,bytes: Int,load: () throws -> JSON) throws {
        guard !rows.contains(where: {$0.key == row.key}) else {return}
        guard bytes <= Self.rowByteLimit,retainedBytes + bytes <= Self.byteLimit,rows.count < 4096 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected ticket exceeds the bounded cleanup inventory; bytes retained.")}
        // Only admitted rows cross the full canonical decoding boundary. The
        // snapshot and the original inventory budgets still bind that load.
        let row = bytes > Self.projectionByteLimit ? PurgeRow(id:row.id,type:row.type,project:row.project,value:try load()) : row
        retainedBytes += bytes;rows.append(row)
        var found = Set<Data>(),budget = 2000000
        try Self.strings(row.value,{found.insert(Data($0.utf8))},budget:&budget)
        tokens[row.key] = found
    }
    mutating func path(_ path: String,root: URL,prefix: Bool = false) {
        let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
        needles.formUnion([Data(path.utf8),Data(relative.utf8),Data(root.appendingPathComponent(relative).path.utf8)])
        if prefix {prefixes.formUnion([relative,root.appendingPathComponent(relative).path])}
    }
    mutating func objects(_ objects: [JSON],root: URL) {
        for object in objects {
            needles.formUnion(((object["owner_ids"] as? [String]) ?? []).map {Data($0.utf8)})
            if let sha = object["sha256"] as? String {holdDigests.insert(Data(sha.utf8))}
            for field in ["stored_path","relative_path","capture_path","cache_path"] {
                if let p = object[field] as? String {path(p,root:root,prefix:["capture_path","cache_path"].contains(field))}
            }
        }
    }
}

extension CommandRouter {
    /// Unrelated payloads above 16 KiB use canonical/ownership headers. Preserve
    /// full Foundation JSON validation through 4 MiB; larger payloads retain the
    /// existing 64 KiB UTF-8 streaming path. SQLite matches complete references.
    private func streamTicketCleanupRows(_ db: Database,needles: Set<Data> = [],holdDigests: Set<Data> = [],prefixes: Set<String> = [],_ body: (PurgeRow,Int) throws -> Void) throws {
        let keys = "'id','project_id','revision','kind','project_ids','owner_id','owner_kind','attachment_id','expires_at','task_id','source_task_id','message_id','attempt_id','parent_attempt_id','request_id','review_request_id','manifest_id','membership_id','delegation_id','conversation_id','source_capture_id'"
        let projection = "(SELECT '{'||COALESCE(group_concat(json_quote(key)||':'||CASE WHEN key='project_ids' THEN CASE WHEN type='array' AND NOT EXISTS(SELECT 1 FROM json_each(CASE WHEN type='array' THEN value ELSE '[]' END) grant_value WHERE grant_value.type!='text' OR length(CAST(grant_value.value AS BLOB))=0) THEN '[]' ELSE 'null' END WHEN length(CAST(records.data -> fullkey AS BLOB))>65536 THEN 'null' WHEN key='revision' THEN records.data -> fullkey WHEN type='true' THEN 'true' WHEN type='false' THEN 'false' ELSE json_quote(value) END),'')||'}' FROM json_each(records.data) WHERE key IN (" + keys + "))"
        let bounded = "CASE WHEN length(CAST(records.data AS BLOB))<=\(TicketCleanupInventory.projectionByteLimit) THEN records.data WHEN json_valid(records.data) AND json_type(records.data)='object' THEN " + projection + " ELSE '{}' END"
        // Keep each lookup's array separate and build prefix bounds once. Empty
        // ownership scans need no reference traversal; a prefix match requires
        // the slash separator in the complete value or key.
        let tokens = try jsonString(needles.map {String(decoding:$0,as:UTF8.self)})
        let paths = try jsonString(Array(prefixes))
        let digests = try jsonString(holdDigests.map {String(decoding:$0,as:UTF8.self)})
        func matches(_ field: String) -> String {
            "(CAST(\(field) AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) OR (instr(\(field),'/')>0 AND EXISTS(SELECT 1 FROM cleanup_prefixes p WHERE CAST(\(field) AS BLOB)>=p.lo AND CAST(\(field) AS BLOB)<p.hi)) OR (records.type='storage_hold' AND CAST(\(field) AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))))"
        }
        let sql = """
            WITH cleanup_prefixes AS MATERIALIZED (SELECT CAST(value||'/' AS BLOB) lo,CAST(value||'0' AS BLOB) hi FROM json_each(?))
            SELECT CASE WHEN length(CAST(id AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN id END AS id,
                CASE WHEN length(CAST(project_id AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN project_id END AS project_id,
                CASE WHEN length(CAST(type AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN type END AS type,revision,\(bounded) AS data,
                CASE WHEN length(CAST(id AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN CAST(id AS BLOB) END AS _envelope_id_bytes,
                CASE WHEN length(CAST(project_id AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN CAST(project_id AS BLOB) END AS _envelope_project_id_bytes,
                CASE WHEN length(CAST(type AS BLOB))<=\(TicketCleanupInventory.rowByteLimit) THEN CAST(type AS BLOB) END AS _envelope_type_bytes,CAST(\(bounded) AS BLOB) AS _envelope_data_bytes,
                length(CAST(records.data AS BLOB)) AS original_size,typeof(records.data) AS original_type,json_valid(records.data) AS valid_json,
                CASE WHEN \(!needles.isEmpty || !prefixes.isEmpty || !holdDigests.isEmpty ? 1 : 0) AND length(CAST(records.data AS BLOB))>\(TicketCleanupInventory.projectionByteLimit) AND json_valid(records.data) THEN EXISTS(
                    SELECT 1 FROM json_tree(records.data) j WHERE
                    (j.type='text' AND \(matches("j.atom")))
                    OR (typeof(j.key)='text' AND \(matches("j.key")))
                ) ELSE 0 END AS large_match FROM records ORDER BY rowid
            """
        let cursor = try Row.fetchCursor(db,sql:sql,arguments:[paths,tokens,digests,tokens,digests])
        var count = 0
        while let raw = try cursor.next() {
            count += 1
            guard count <= 100000 else {throw CoreError("PURGE_LIMIT","Cleanup inventory exceeds its record bound; bytes retained.")}
            try autoreleasepool {
                let size: Int = raw["original_size"]
                guard raw["original_type"] as String == "text",raw["valid_json"] as Bool else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                let envelope = try GRDBRecordEnvelopeAdapter.decode(raw)
                var value = envelope.object
                if size > TicketCleanupInventory.projectionByteLimit {
                    let id = envelope.id
                    // Retain at most the original row limit for Foundation's strict
                    // JSON/Unicode check, without lexically scanning its body.
                    var validationBytes: Data? = size <= TicketCleanupInventory.rowByteLimit ? Data() : nil
                    var tail = Data(),offset = 1
                    while offset <= size {
                        let chunk = try Data.fetchOne(db,sql:"SELECT substr(CAST(data AS BLOB),?,65536) FROM records WHERE id=CAST(? AS TEXT)",arguments:[offset,Data(id.utf8)])!
                        validationBytes?.append(chunk)
                        tail.append(chunk);offset += chunk.count
                        var split = tail.count
                        if offset <= size {
                            var start = tail.count-1
                            while start > 0,tail[start] & 0xc0 == 0x80 {start -= 1}
                            let first = tail[start],width = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4
                            if tail.count-start < width {split = start}
                        }
                        guard String(data:tail.prefix(split),encoding:.utf8) != nil else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                        tail = Data(tail.dropFirst(split))
                    }
                    guard tail.isEmpty else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                    if let bytes = validationBytes {
                        do {
                            guard try JSONSerialization.jsonObject(with:bytes) is JSON else {throw EnvelopeFailure(.jsonObject)}
                        } catch {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.jsonObject))}
                    }
                    value["_cleanup_large_match"] = raw["large_match"] as Bool
                }
                try body(PurgeRow(id:envelope.id,type:envelope.type,project:envelope.projectID,value:value),size)
            }
        }
    }
    func ticketCleanupInventory(_ db: Database,task: JSON) throws -> TicketCleanupInventory {
        let tid = task["id"] as! String,pid = task["project_id"] as! String
        let containers: Set<String> = ["project","session","profile","status","tag","policy_revision","project_context_revision","taxonomy_revision","group","batch","batch_claim","relation","task"]
        let parents = ["message_id","attempt_id","parent_attempt_id","request_id","review_request_id","manifest_id","membership_id","delegation_id","conversation_id","source_capture_id"]
        var result = TicketCleanupInventory(),owned = Set<Data>()
        // Ownership is transitive. A finite number of streaming rounds discovers
        // children even when a child precedes its parent in physical order.
        for depth in 0..<65 {
            let before = owned.count
            try streamTicketCleanupRows(db) {row,size in
                guard row.project == pid else {return}
                let direct = row.type == "relation" && row.value["source_task_id"] as? String == tid
                let eligible = !containers.contains(row.type) && row.type != "storage_hold" && !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind)
                let local = row.value["task_id"] == nil || row.value["task_id"] as? String == tid
                let child = local && parents.contains {field in (row.value[field] as? String).map {owned.contains(Data($0.utf8))} ?? false}
                if direct || eligible && (row.value["task_id"] as? String == tid || child) {
                    owned.insert(row.key);try result.add(row,bytes:size) {try self.record(db,row.id,type:row.type)}
                }
            }
            if before == owned.count {break}
            guard depth < 64 else {throw CoreError("PURGE_LIMIT","Cleanup ownership depth exceeds its bound; bytes retained.")}
        }
        result.needles = owned.union([Data(tid.utf8)])
        for row in result.rows {
            if row.type == "attachment" {
                for key in ["path","preview_path"] {if let p = row.value[key] as? String {result.path(p,root:root)}}
            }
            var captures: [JSON] = row.type == "source_capture" ? [row.value] : []
            if row.type == "manifest",let evidence = row.value["evidence"] as? JSON,let capture = evidence["source_capture"] as? JSON {captures.append(capture)}
            for capture in captures {
                if let p = capture["snapshot_path"] as? String {
                    result.path(p,root:root,prefix:true)
                    result.path(String(p.dropLast("/source".count)) + "/manifest.json",root:root)
                }
                if let cid = capture["id"] as? String {result.needles.insert(Data(cid.utf8))}
            }
            if row.type == "source_execution",let path = try sourceBuildCachePath(db,execution:row.value) {result.path(path,root:root,prefix:true)}
        }
        // Digest-only typed holds also protect the selected bytes.
        var digests = Set<Data>()
        for row in result.rows {
            var budget = 2000000
            try TicketCleanupInventory.strings(row.value,{s in if s.utf8.count == 64 {digests.insert(Data(s.utf8))}},budget:&budget)
        }
        try streamTicketCleanupRows(db,needles:result.needles,holdDigests:digests,prefixes:result.prefixes) {row,size in
            var relevant = try row.type == "project" || row.key == Data(tid.utf8) || bool(row.value,"_cleanup_large_match") || result.mentions(row.value)
            if row.type == "storage_hold",!relevant {
                var budget = 2000000
                try TicketCleanupInventory.strings(row.value,{s in if digests.contains(Data(s.utf8)) {relevant = true}},budget:&budget)
            }
            if relevant {try result.add(row,bytes:size) {try self.record(db,row.id,type:row.type)}}
        }
        result.holdDigests = digests
        return result
    }
    func ticketCleanupInventory(_ db: Database,receipt: JSON) throws -> TicketCleanupInventory {
        var result = TicketCleanupInventory()
        result.objects(receipt["objects"] as? [JSON] ?? [],root:root)
        if let tid = receipt["task_id"] as? String {result.needles.insert(Data(tid.utf8))}
        try streamTicketCleanupRows(db,needles:result.needles,holdDigests:result.holdDigests,prefixes:result.prefixes) {row,size in
            if try row.type == "project" || bool(row.value,"_cleanup_large_match") || result.mentions(row.value,includeDigests:row.type == "storage_hold") {try result.add(row,bytes:size) {try self.record(db,row.id,type:row.type)}}
        }
        return result
    }
}

extension CommandRouter {
    /// Validate media roots and their declared dependencies by indexed lookup,
    /// rather than retaining every ordinary note/attachment in the store.
    func ticketCleanupValidateMediaAuthority(_ db: Database) throws {
        let types = (MediaRecordRegistry.families.union(["storage_job","storage_hold"])).sorted()
        let placeholders = types.map {_ in "?"}.joined(separator:",")
        let cursor = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type IN (" + placeholders + ") ORDER BY rowid",arguments:StatementArguments(types))
        while let root = try cursor.next() {
            try autoreleasepool {
                var selected: [Data:DecodedEnvelope] = [:],pending: [String] = [],bytes = 0
                func add(_ raw: Row) throws {
                    let rawBytes: Data = raw["_envelope_data_bytes"]
                    bytes += rawBytes.count
                    guard rawBytes.count <= TicketCleanupInventory.rowByteLimit,bytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Media authority exceeds the cleanup memory bound.")}
                    let envelope = try GRDBRecordEnvelopeAdapter.decode(raw),key = Data(envelope.id.utf8)
                    guard selected[key] == nil else {return}
                    selected[key] = envelope
                    pending += (envelope.object["record_references"] as? [JSON] ?? []).compactMap {$0["id"] as? String}
                    if envelope.type == "storage_hold",envelope.object["kind"] as? String == "media_reference" {
                        pending += [envelope.object["owner_id"] as? String,envelope.object["attachment_id"] as? String].compactMap {$0}
                    }
                    if envelope.type == "storage_job",let id = envelope.object["attachment_owner_id"] as? String {pending.append(id)}
                }
                try add(root)
                while let id = pending.popLast() {
                    if selected[Data(id.utf8)] != nil {continue}
                    guard let raw = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)]) else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A required media dependency is unavailable.")}
                    try add(raw)
                }
                try MediaRecordRegistry.validate(Array(selected.values))
            }
        }
    }
}

extension CommandRouter {
    /// The retained backup authority may describe the whole managed store. Stream
    /// its descriptors and retain keys only for this ticket's candidate objects.
    func ticketCleanupBackupRetentionIndex(_ db: Database,objects: [JSON]) throws -> StorageBackupRetentionIndex {
        let wanted = Set(objects.compactMap {object -> Data? in
            guard let path = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {return nil}
            return StorageBackupRetentionIndex.key(path:path,sha:sha,size:size)
        })
        let headers = try Row.fetchCursor(db,sql:"SELECT key,CASE WHEN json_valid(value) THEN json_extract(value,'$.state')='complete' AND json_type(value,'$.objects')='array' ELSE 0 END AS valid FROM metadata WHERE key GLOB 'backup-generation:*'")
        var retained = Set<Data>()
        while let header = try headers.next() {
            guard header["valid"] as Bool? == true else {throw StoreRecovery.required("backup_receipt_index_invalid")}
            let entries = try Row.fetchCursor(db,sql:"SELECT j.type,json_extract(j.value,'$.path') AS path,json_extract(j.value,'$.sha256') AS sha,json_extract(j.value,'$.size') AS size FROM metadata m,json_each(m.value,'$.objects') j WHERE m.key=?",arguments:[header["key"] as String])
            while let entry = try entries.next() {
                try autoreleasepool {
                    guard entry["type"] as String == "object",let path: String = entry["path"],let sha: String = entry["sha"],let size: Int64 = entry["size"],size >= 0 else {throw StoreRecovery.required("backup_receipt_index_invalid")}
                    if let relative = try? ManagedPaths.relative(path,family:path.contains("source-captures/") ? "source-captures" : path.contains("source-build-cache/") ? "source-build-cache" : "objects",root:root) {
                        let key = StorageBackupRetentionIndex.key(path:relative,sha:sha,size:size)
                        if wanted.contains(key) {retained.insert(key)}
                    }
                }
            }
        }
        return .init(originals:retained,root:root)
    }
}
