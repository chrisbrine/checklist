import Foundation
import GRDB

extension CommandRouter {
    /// Validate every envelope, but decode full payloads only along the reverse
    /// references reachable from these originals. All queries share the caller's
    /// SQL observation, including foreign projects. Nothing is cached across it.
    func archiveCleanupRelevantReferenceRows(_ db: Database, attachments: [JSON]) throws -> [JSON] {
        // Keep the original JSON tokens (not json_extract's coerced numbers),
        // duplicate envelope keys, and every field used by canonical ownership
        // validation. SQLite validates the complete JSON; the adapter validates
        // the complete original UTF-8 before the canonical projected decode.
        let keys = "'id','project_id','revision','kind','project_ids','owner_id','owner_kind','attachment_id','expires_at','archived','trashed','active_attempt_id','active_verification_request_id','state','manifest_id','task_id'"
        // The adapter needs the physical header witnesses, but not a second
        // GRDB String conversion of the large original payload. Supply an inert
        // data field to its input adapter only; canonical decoding below always
        // receives the real projection after the original's type/UTF-8 check.
        let header = "id,project_id,type,revision,'{}' AS data," + ["id","project_id","type"].map { "CAST(" + $0 + " AS BLOB) AS _envelope_" + $0 + "_bytes" }.joined(separator:",") + ",CAST('{}' AS BLOB) AS _envelope_data_bytes"
        let sql = """
            SELECT \(header),typeof(records.data) AS original_data_type,CAST(records.data AS BLOB) AS original_data_bytes,
            CASE WHEN json_valid(records.data) THEN CASE WHEN json_type(records.data)='object' THEN
                (SELECT '{'||COALESCE(group_concat(json_quote(key)||':'||
                    CASE WHEN key='revision' THEN records.data -> fullkey
                         WHEN type='true' THEN 'true' WHEN type='false' THEN 'false'
                         ELSE json_quote(value) END),'')||'}'
                 FROM json_each(records.data) WHERE key IN (\(keys)))
            END END AS envelope_projection FROM records ORDER BY rowid
            """
        let cursor = try Row.fetchCursor(db,sql:sql)
        var graph: [Data:JSON] = [:],count = 0
        while let row = try cursor.next() {
            count += 1
            guard count <= 250_000 else { throw CoreError("REFERENCE_GRAPH_LIMIT", "The current reference graph exceeds the cleanup safety bound; originals retained.") }
            let original = try GRDBRecordEnvelopeAdapter.input(row)
            let originalBytes: Data = row["original_data_bytes"]
            guard row["original_data_type"] as String == "text",String(data:originalBytes,encoding:.utf8) != nil else { throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData)) }
            guard let projection: String = row["envelope_projection"] else { throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.jsonObject)) }
            let projected = try EnvelopeRow(columns:["id":original.id,"project_id":original.project,"type":original.type,"revision":original.revision,"data":.text(projection)])
            let decoded: DecodedEnvelope
            do { decoded = try CanonicalEnvelope.decode(projected) }
            catch let error as EnvelopeFailure { throw GRDBRecordEnvelopeAdapter.failure(error) }
            if decoded.type == "task" || decoded.type == "review_request" {
                var value = decoded.object;value["record_type"] = decoded.type
                graph[Data(decoded.id.utf8)] = value
            }
        }
        var pending = Set<Data>()
        for a in attachments {
            pending.insert(Data((a["id"] as! String).utf8))
            if let path = a["path"] as? String,!path.isEmpty {
                pending.insert(Data(path.utf8))
                if let relative = try? ManagedPaths.relative(path,family:"objects",root:root) {
                    pending.insert(Data(relative.utf8))
                    pending.insert(Data(root.appendingPathComponent(relative).path.utf8))
                }
            }
        }
        let tokenJSON = try jsonString(["tokens":pending.map { String(decoding:$0,as:UTF8.self) }])
        let excluded = ArchiveCleanupReferenceIndex.bookkeeping.sorted().map { "'" + $0 + "'" }.joined(separator:",")
        // Materialize the finite identity vocabulary once. Blob membership uses
        // complete UTF-8 bytes, and avoids a Swift callback for every captured
        // filename/hash. Irrelevant scalar strings never enter the reverse map.
        let edges = try Row.fetchCursor(db,sql:"""
            WITH tokens AS MATERIALIZED (
                SELECT CAST(id AS BLOB) token FROM records
                UNION SELECT CAST(value AS BLOB) FROM json_each(?,'$.tokens')
            )
            SELECT CAST(r.id AS BLOB) source,CAST(ref.atom AS BLOB) target,
                   CASE WHEN r.type='storage_job' AND json_extract(r.data,'$.kind') IN ('attachment_import','archive_cleanup_delete','archive_cleanup_cursor','ticket_object_delete') THEN 0 ELSE 1 END transitive
            FROM records r,json_tree(r.data) ref
            WHERE r.type NOT IN (\(excluded)) AND ref.type='text'
                AND CAST(ref.atom AS BLOB) IN (SELECT token FROM tokens)
            UNION ALL
            SELECT CAST(id AS BLOB),CAST(type AS BLOB),1 FROM records
            WHERE type NOT IN (\(excluded)) AND CAST(type AS BLOB) IN (SELECT token FROM tokens)
            LIMIT 2000001
            """,arguments:[tokenJSON])
        var reverse: [Data:[(Data,Bool)]] = [:],edgeCount = 0
        while let row = try edges.next() {
            edgeCount += 1
            guard edgeCount <= 2_000_000 else { throw CoreError("REFERENCE_GRAPH_LIMIT", "The current reference graph exceeds the cleanup safety bound; originals retained.") }
            reverse[row["target"] as Data,default:[]].append((row["source"] as Data,(row["transitive"] as Int) == 1))
        }
        var seen = Set<Data>(),selected = Set<Data>()
        while let token = pending.popFirst() {
            guard seen.insert(token).inserted else { continue }
            for (id,transitive) in reverse[token] ?? [] {
                if selected.insert(id).inserted && transitive { pending.insert(id) }
            }
        }
        // Fetch selected identities through the primary index, without decoding
        // any unrelated captured-file lists, notes or evidence payloads.
        for id in selected {
            guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT)",arguments:[id]) else { throw CoreError("REFERENCE_GRAPH_LIMIT", "A current reference could not be resolved; originals retained.") }
            let decoded = try GRDBRecordEnvelopeAdapter.decode(row)
            var value = decoded.object;value["record_type"] = decoded.type;graph[id] = value
        }
        return Array(graph.values)
    }
}
