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
    /// One bounded traversal supplies matching and admission. Data preserves
    /// byte-exact IDs; path strings retain the conservative canonical-prefix
    /// behavior of String.hasPrefix without decoding every token per ticket.
    struct TokenObservation {
        let tokens: Set<Data>
        let paths: [String]

        init(tokens: Set<Data>) {
            self.tokens = tokens
            paths = tokens.compactMap {token in
                guard token.contains(47) else {return nil}
                return String(decoding:token,as:UTF8.self)
            }
        }
        init(_ value: Any) throws {
            var found = Set<Data>(),budget = 2000000
            try TicketCleanupInventory.strings(value,{found.insert(Data($0.utf8))},budget:&budget)
            self.init(tokens:found)
        }
    }
    func mentions(_ observation: TokenObservation,includeDigests: Bool = false) -> Bool {
        !needles.isDisjoint(with:observation.tokens) ||
            includeDigests && !holdDigests.isDisjoint(with:observation.tokens) ||
            !prefixes.isEmpty && observation.paths.contains {path in prefixes.contains {path.hasPrefix($0 + "/")}}
    }
    func mentions(_ value: Any,includeDigests: Bool = false) throws -> Bool {
        try mentions(TokenObservation(value),includeDigests:includeDigests)
    }
    mutating func add(_ row: PurgeRow,bytes: Int,load: () throws -> JSON) throws {
        guard tokens[row.key] == nil else {return}
        try checkAdmission(bytes:bytes)
        // Only admitted rows cross the full canonical decoding boundary. The
        // snapshot and the original inventory budgets still bind that load.
        let complete = bytes > Self.projectionByteLimit ? PurgeRow(id:row.id,type:row.type,project:row.project,value:try load()) : row
        try add(complete,bytes:bytes,observation:TokenObservation(complete.value))
    }
    /// The batch supplies a fully decoded row and its same-snapshot observation.
    /// Never pass projection-only tokens for a row admitted above 16 KiB.
    mutating func add(_ row: PurgeRow,bytes: Int,observation: TokenObservation) throws {
        guard tokens[row.key] == nil else {return}
        try checkAdmission(bytes:bytes)
        retainedBytes += bytes;rows.append(row);tokens[row.key] = observation.tokens
    }
    private func checkAdmission(bytes: Int) throws {
        guard bytes <= Self.rowByteLimit,retainedBytes + bytes <= Self.byteLimit,rows.count < 4096 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected ticket exceeds the bounded cleanup inventory; bytes retained.")}
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
    func streamTicketCleanupRows(_ db: Database,needles: Set<Data> = [],holdDigests: Set<Data> = [],prefixes: Set<String> = [],fullPayloads: Bool = false,_ body: (PurgeRow,Int) throws -> Void) throws {
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
                CASE WHEN \(!needles.isEmpty || !prefixes.isEmpty || !holdDigests.isEmpty ? 1 : 0) AND length(CAST(records.data AS BLOB))>\(fullPayloads ? TicketCleanupInventory.rowByteLimit : TicketCleanupInventory.projectionByteLimit) AND json_valid(records.data) THEN
                CASE WHEN records.type='storage_job' AND json_extract(records.data,'$.kind')='ticket_object_delete' THEN 0 ELSE EXISTS(
                    SELECT 1 FROM json_tree(records.data) j WHERE
                    (j.type='text' AND \(matches("j.atom")))
                    OR (typeof(j.key)='text' AND \(matches("j.key")))
                ) END ELSE 0 END AS large_match FROM records ORDER BY rowid
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
                    if size <= TicketCleanupInventory.rowByteLimit {
                        // Foundation already requires the complete bounded row.
                        // Read it once: repeated substr(CAST(data AS BLOB),...) loads
                        // and copies the whole SQLite value for every 64 KiB slice.
                        guard let bytes = try Data.fetchOne(db,sql:"SELECT CAST(data AS BLOB) FROM records WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)]),
                              bytes.count == size,String(data:bytes,encoding:.utf8) != nil else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                        do {
                            guard let decoded = try JSONSerialization.jsonObject(with:bytes) as? JSON else {throw EnvelopeFailure(.jsonObject)}
                            if fullPayloads {
                                // The projected envelope has already checked raw
                                // revision/duplicate headers and SQL ownership.
                                // Bind the returned Foundation object to it too.
                                guard let id = decoded["id"] as? String,EnvelopeStorageIdentity.equal(id,envelope.id),
                                      EnvelopeStorageIdentity.equal(decoded["project_id"] as? String,envelope.projectID),
                                      let revision = decoded["revision"] as? NSNumber,
                                      try EnvelopeInteger.positiveExact(revision.stringValue) == envelope.revision else {throw EnvelopeFailure(.identityMismatch)}
                                value = decoded
                            }
                        } catch let error as EnvelopeFailure {throw GRDBRecordEnvelopeAdapter.failure(error)}
                        catch {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.jsonObject))}
                    } else {
                        // Oversized rows retain the bounded UTF-8 stream and exact
                        // SQL reference matcher; they can never cross admission.
                        var tail = Data(),offset = 1
                        while offset <= size {
                            guard let chunk = try Data.fetchOne(db,sql:"SELECT substr(CAST(data AS BLOB),?,65536) FROM records WHERE id=CAST(? AS TEXT)",arguments:[offset,Data(id.utf8)]),!chunk.isEmpty else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
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
                    }
                    if !fullPayloads || size > TicketCleanupInventory.rowByteLimit {value["_cleanup_large_match"] = raw["large_match"] as Bool}
                }
                try body(PurgeRow(id:envelope.id,type:envelope.type,project:envelope.projectID,value:value),size)
            }
        }
    }
    /// A pathological unrelated payload cannot refuse every ticket. On a token
    /// bound, the original exact SQL matcher decides whether this inventory is
    /// affected; affected bytes still retain the traversal-limit refusal.
    private func ticketCleanupReferenceObservation(_ db: Database,row: PurgeRow,inventory: TicketCleanupInventory) throws -> TicketCleanupInventory.TokenObservation? {
        do {return try inventory.tokens[row.key].map {TicketCleanupInventory.TokenObservation(tokens:$0)} ?? TicketCleanupInventory.TokenObservation(row.value)}
        catch let error as CoreError where error.code == "REFERENCE_GRAPH_LIMIT" {
            if try row.type == "project" || ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory) {throw error}
            return nil
        }
    }

    func ticketCleanupInventory(_ db: Database,task: JSON) throws -> TicketCleanupInventory {
        let tid = (try StoredRecord(task, family: "task").string("id")), pid = (try StoredRecord(task, family: "task").string("project_id"))
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
        result.holdDigests = digests
        try streamTicketCleanupRows(db,needles:result.needles,holdDigests:digests,prefixes:result.prefixes,fullPayloads:true) {row,size in
            // Deletion receipts are accounting, never reference authority. The
            // stream still validates their complete canonical payload first.
            guard !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) else {return}
            guard let observation = try ticketCleanupReferenceObservation(db,row:row,inventory:result) else {return}
            if row.type == "project" || row.key == Data(tid.utf8) || bool(row.value,"_cleanup_large_match") || result.mentions(observation,includeDigests:row.type == "storage_hold") {
                try result.add(row,bytes:size,observation:observation)
            }
        }
        result.holdDigests = digests
        return result
    }
    func ticketCleanupInventory(_ db: Database,receipt: JSON) throws -> TicketCleanupInventory {
        var result = TicketCleanupInventory()
        result.objects(receipt["objects"] as? [JSON] ?? [],root:root)
        result.needles.formUnion((receipt["owned_record_fingerprints"] as? [String:String] ?? [:]).keys.map {Data($0.utf8)})
        if let tid = receipt["task_id"] as? String {result.needles.insert(Data(tid.utf8))}
        try streamTicketCleanupRows(db,needles:result.needles,holdDigests:result.holdDigests,prefixes:result.prefixes,fullPayloads:true) {row,size in
            guard !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) else {return}
            guard let observation = try ticketCleanupReferenceObservation(db,row:row,inventory:result) else {return}
            if row.type == "project" || bool(row.value,"_cleanup_large_match") || result.mentions(observation,includeDigests:row.type == "storage_hold") {try result.add(row,bytes:size,observation:observation)}
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
        // Known deletion receipts are accounting, never media roots. Their
        // complete canonical payload was already validated by the corpus stream;
        // a large receipt must not make every unrelated media observation fail.
        let cursor = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type IN (" + placeholders + ") AND NOT (type='storage_job' AND json_valid(data) AND COALESCE(json_extract(data,'$.kind')='ticket_object_delete',0)) ORDER BY rowid",arguments:StatementArguments(types))
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

/// A snapshot-local observation. Selected plans share it; no descriptor or file
/// verification survives into another pass. The deletion fence binds every
/// backup-generation metadata row and final unlink rechecks its manifest/payload.
struct TicketCleanupBackupObservation {
    let index: StorageBackupRetentionIndex?
    var summaries: [JSON] = []
}

extension CommandRouter {
    /// Validate every generation entry, but only materialize wanted SHA/size
    /// pairs in Swift. Path normalization and descriptor keys are then charged
    /// only once for candidates of the complete selected batch.
    func ticketCleanupBackupRetentionIndex(_ db: Database,objects: [JSON],observeCandidate: ((String) -> Void)? = nil) throws -> StorageBackupRetentionIndex {
        struct Content: Hashable {let sha: Data;let size: Int64}
        var wanted = Set<Data>(),wantedPaths = Set<Data>(),contents = Set<Content>(),needles: [JSON] = [],wantedBytes = 0
        let limit = TicketCleanupBatchInventory.byteLimit
        for object in objects {
            guard let path = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {continue}
            let key = StorageBackupRetentionIndex.key(path:path,sha:sha,size:size)
            if wanted.insert(key).inserted {wantedBytes += key.count + 128}
            // ManagedPaths.relative preserves the relative spelling and strips
            // only this exact standardized-root prefix from an absolute path.
            // Other spellings cannot produce a wanted key, even for common SHA.
            for candidate in [path,root.standardizedFileURL.path + "/" + path] {
                let bytes = Data(candidate.utf8)
                if wantedPaths.insert(bytes).inserted {wantedBytes += bytes.count + 96}
            }
            if contents.insert(Content(sha:Data(sha.utf8),size:size)).inserted {needles.append(["sha":sha,"size":size]);wantedBytes += sha.utf8.count + 128}
            guard wantedBytes <= limit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup candidates exceed the cleanup memory bound; bytes retained.")}
        }
        let headers = try Row.fetchCursor(db,sql:"SELECT key,length(CAST(value AS BLOB)) AS bytes,CASE WHEN json_valid(value) THEN json_extract(value,'$.state')='complete' AND json_type(value,'$.objects')='array' ELSE 0 END AS valid,json_array_length(value,'$.objects') AS count,json_extract(value,'$.summary.path') AS path,json_extract(value,'$.summary.verification') AS verification,json_extract(value,'$.manifest_sha256') AS manifest,json_extract(value,'$.summary.manifest_sha256') AS summary_manifest FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")
        let wantedJSON = try jsonString(needles),pathJSON = try jsonString(wantedPaths.map {String(decoding:$0,as:UTF8.self)})
        var retained = Set<Data>(),copies: [Data:[URL]] = [:],manifests: [String:String] = [:],retainedBytes = wantedBytes,generationCount = 0,totalBytes: Int64 = 0,descriptorCount: Int64 = 0
        while let header = try headers.next() {
            generationCount += 1;totalBytes += header["bytes"] as Int64;descriptorCount += header["count"] as Int64? ?? 0
            guard generationCount <= 1024,totalBytes <= 2 * 1024 * 1024 * 1024,descriptorCount <= 10_000_000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup generation observation exceeds its bound; bytes retained.")}
            guard header["valid"] as Bool? == true else {throw StoreRecovery.required("backup_receipt_index_invalid")}
            let backupPath: String? = header["path"],manifest: String? = header["manifest"]
            let independent = backupPath?.hasPrefix("/") == true && header["verification"] as String? == "manifest_database_managed_files" && manifest?.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil && manifest == header["summary_manifest"] as String?
            if independent,let backupPath,let manifest {manifests[backupPath] = manifest;retainedBytes += backupPath.utf8.count + 256}
            guard retainedBytes <= limit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup descriptors exceed the cleanup memory bound; bytes retained.")}
            // Invalid entries are returned regardless of wanted content. Unwanted
            // well-formed entries never cross the expensive path normalization.
            let entries = try Row.fetchCursor(db,sql:"""
                WITH wanted AS MATERIALIZED (SELECT CAST(json_extract(value,'$.sha') AS BLOB) sha,json_extract(value,'$.size') size FROM json_each(?)),
                wanted_paths AS MATERIALIZED (SELECT CAST(value AS BLOB) path FROM json_each(?)),
                entries AS (SELECT j.type,json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.path') path,
                    json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.sha256') sha,
                    json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.size') size
                    FROM metadata m,json_each(m.value,'$.objects') j WHERE m.key=?)
                SELECT type,path,sha,size,COALESCE(type='object' AND typeof(path)='text' AND typeof(sha)='text' AND typeof(size) IN ('integer','real') AND size>=0,0) AS valid FROM entries WHERE
                    NOT COALESCE(type='object' AND typeof(path)='text' AND typeof(sha)='text' AND typeof(size) IN ('integer','real') AND size>=0,0)
                    OR (CAST(sha AS BLOB) IN (SELECT sha FROM wanted) AND size IN (SELECT size FROM wanted) AND CAST(path AS BLOB) IN (SELECT path FROM wanted_paths))
                """,arguments:[wantedJSON,pathJSON,header["key"] as String])
            while let entry = try entries.next() {
                try autoreleasepool {
                    guard entry["valid"] as Bool,entry["type"] as String == "object",let path: String = entry["path"],let sha: String = entry["sha"],let size: Int64 = entry["size"],size >= 0 else {throw StoreRecovery.required("backup_receipt_index_invalid")}
                    guard wantedPaths.contains(Data(path.utf8)),contents.contains(Content(sha:Data(sha.utf8),size:size)) else {return}
                    observeCandidate?(path)
                    if let relative = try? ManagedPaths.relative(path,family:path.contains("source-captures/") ? "source-captures" : path.contains("source-build-cache/") ? "source-build-cache" : "objects",root:root) {
                        let key = StorageBackupRetentionIndex.key(path:relative,sha:sha,size:size)
                        if wanted.contains(key) {
                            if retained.insert(key).inserted {retainedBytes += key.count + 128}
                            if independent,let backupPath {copies[key,default:[]].append(URL(fileURLWithPath:backupPath,isDirectory:true));retainedBytes += 128}
                            guard retainedBytes <= limit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup descriptors exceed the cleanup memory bound; bytes retained.")}
                        }
                    }
                }
            }
        }
        return .init(originals:retained,root:root,copyPaths:copies,copyManifests:manifests)
    }
}
