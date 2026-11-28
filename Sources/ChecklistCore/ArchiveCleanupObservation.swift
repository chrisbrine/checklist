import Foundation
import GRDB

/// Charge only retained reference work. Unrelated record payloads are streamed
/// and discarded after canonical validation, with a separate per-payload bound.
struct ArchiveCleanupObservationBudget {
    static let payloadByteLimit = 128 * 1024 * 1024
    static let edgeLimit = 2_000_000
    let deadline: CleanupObservationDeadline
    let byteLimit: Int
    private var retainedBytes = 0

    init(seconds: TimeInterval = CleanupObservationDeadline.preparedSeconds, byteLimit: Int = ArchiveCleanupObservationBudget.payloadByteLimit) {
        deadline = CleanupObservationDeadline(seconds:seconds,failure:CoreError(
            "REFERENCE_GRAPH_LIMIT","Archive reference observation exceeded its time budget; originals retained.",
            details:["limit":"observation_seconds","maximum":seconds]))
        self.byteLimit = byteLimit
    }

    static func payloadLimit() -> CoreError {
        CoreError("REFERENCE_GRAPH_LIMIT","An archive reference payload exceeds its byte budget; originals retained.",
                  details:["limit":"payload_bytes","maximum":payloadByteLimit])
    }

    mutating func retain(_ bytes: Int) throws {
        guard bytes <= byteLimit - retainedBytes else {
            throw CoreError("REFERENCE_GRAPH_LIMIT","The retained archive reference graph exceeds its byte budget; originals retained.",
                            details:["limit":"retained_bytes","maximum":byteLimit])
        }
        retainedBytes += bytes
    }
}

extension CommandRouter {
    /// Validate every envelope, but decode full payloads only along the reverse
    /// references reachable from these originals. All queries share the caller's
    /// SQL observation, including foreign projects. Nothing is cached across it.
    func archiveCleanupRelevantReferenceRows(_ db: Database, attachments: [JSON], budget: ArchiveCleanupObservationBudget = .init()) throws -> [JSON] {
        try archiveCleanupRelevantReferenceGraph(db,attachments:attachments,budget:budget).index.graph
    }
    /// The complete identity tokens of these originals: ids, stored paths and object paths.
    func archiveCleanupTokens(_ attachments: [JSON]) throws -> Set<Data> {
        var tokens = Set<Data>()
        for a in attachments {
            tokens.insert(Data(((try StoredRecord(a, family: "a").string("id"))).utf8))
            if let path = a["path"] as? String,!path.isEmpty {
                tokens.insert(Data(path.utf8))
                if let relative = try? ManagedPaths.relative(path,family:"objects",root:root) {
                    tokens.insert(Data(relative.utf8))
                    tokens.insert(Data(root.appendingPathComponent(relative).path.utf8))
                }
            }
        }
        return tokens
    }
    /// The relevant rows and the identities selected along reverse references (CL-344 fences them).
    func archiveCleanupRelevantReferenceGraph(_ db: Database, attachments: [JSON], budget initialBudget: ArchiveCleanupObservationBudget = .init()) throws -> (index: ArchiveCleanupReferenceIndex, selected: Set<Data>) {
        var budget = initialBudget
        return try initialBudget.deadline.observing(db) {
            try self.observeArchiveCleanupReferenceGraph(db,attachments:attachments,budget:&budget)
        }
    }

    private func observeArchiveCleanupReferenceGraph(_ db: Database, attachments: [JSON], budget: inout ArchiveCleanupObservationBudget) throws -> (index: ArchiveCleanupReferenceIndex, selected: Set<Data>) {
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
        let payloadFits = "octet_length(records.data)<=\(ArchiveCleanupObservationBudget.payloadByteLimit)"
        let sql = """
            SELECT \(header),typeof(records.data) AS original_data_type,
            CASE WHEN \(payloadFits) THEN CAST(records.data AS BLOB) END AS original_data_bytes,
            CASE WHEN \(payloadFits) THEN CASE WHEN json_valid(records.data) THEN CASE WHEN json_type(records.data)='object' THEN
                (SELECT '{'||COALESCE(group_concat(json_quote(key)||':'||
                    CASE WHEN key='revision' THEN records.data -> fullkey
                         WHEN type='true' THEN 'true' WHEN type='false' THEN 'false'
                         ELSE json_quote(value) END),'')||'}'
                 FROM json_each(records.data) WHERE key IN (\(keys)))
            END END END AS envelope_projection FROM records ORDER BY rowid
            """
        let cursor = try Row.fetchCursor(db,sql:sql)
        var graph: [Data:JSON] = [:]
        let deadline = budget.deadline
        while let row = try cursor.next() {
            try autoreleasepool {
                try deadline.check()
                let original = try GRDBRecordEnvelopeAdapter.input(row)
                guard row["original_data_type"] as String == "text" else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                guard let originalBytes: Data = row["original_data_bytes"] else {throw ArchiveCleanupObservationBudget.payloadLimit()}
                guard let raw = String(data:originalBytes,encoding:.utf8) else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                guard let projection: String = row["envelope_projection"] else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.jsonObject))}
                let projected = try EnvelopeRow(columns:["id":original.id,"project_id":original.project,"type":original.type,"revision":original.revision,"data":.text(projection)])
                let decoded: DecodedEnvelope
                do {
                    // SQLite's JSON parser accepts isolated escaped surrogates.
                    // Check escaped Unicode with the canonical full decoder before
                    // relying on a projection from which that value was omitted.
                    if raw.range(of:"\\u",options:.literal) != nil {
                        let full = try EnvelopeRow(columns:["id":original.id,"project_id":original.project,"type":original.type,"revision":original.revision,"data":.text(raw)])
                        _ = try CanonicalEnvelope.decode(full)
                    }
                    decoded = try CanonicalEnvelope.decode(projected)
                } catch let error as EnvelopeFailure {throw GRDBRecordEnvelopeAdapter.failure(error)}
                if decoded.type == "task" || decoded.type == "review_request" {
                    let id = Data(decoded.id.utf8)
                    try budget.retain(projection.utf8.count + id.count + 256)
                    var value = decoded.object;value["record_type"] = decoded.type
                    graph[id] = value
                }
            }
        }
        var pending = try archiveCleanupTokens(attachments)
        for token in pending {try budget.retain(token.count + 64)}
        let tokenJSON = try jsonString(["tokens":pending.map { String(decoding:$0,as:UTF8.self) }])
        let excluded = ArchiveCleanupReferenceIndex.bookkeeping.sorted().map { "'" + $0 + "'" }.joined(separator:",")
        // Materialize the finite identity vocabulary once. Blob membership uses
        // complete UTF-8 bytes, and avoids a Swift callback for every captured
        // filename/hash. An identity pointing to itself cannot extend the walk,
        // but a seed can name a row directly.
        let edges = try Row.fetchCursor(db,sql:"""
            WITH originals AS MATERIALIZED (
                SELECT CAST(value AS BLOB) token FROM json_each(?,'$.tokens')
            ), tokens AS MATERIALIZED (
                SELECT CAST(id AS BLOB) token FROM records
                UNION SELECT token FROM originals
            )
            SELECT CAST(r.id AS BLOB) source,CAST(ref.atom AS BLOB) target
            FROM records r,json_tree(r.data) ref
            WHERE r.type NOT IN (\(excluded)) AND ref.type='text'
                AND CAST(ref.atom AS BLOB) IN (SELECT token FROM tokens)
                AND (CAST(ref.atom AS BLOB)<>CAST(r.id AS BLOB) OR CAST(ref.atom AS BLOB) IN (SELECT token FROM originals))
            UNION ALL
            SELECT CAST(id AS BLOB),CAST(type AS BLOB) FROM records
            WHERE type NOT IN (\(excluded)) AND CAST(type AS BLOB) IN (SELECT token FROM tokens)
            LIMIT \(ArchiveCleanupObservationBudget.edgeLimit + 1)
            """,arguments:[tokenJSON])
        var reverse: [Data:[Data]] = [:],edgeCount = 0
        while let row = try edges.next() {
            edgeCount += 1
            guard edgeCount <= ArchiveCleanupObservationBudget.edgeLimit else {throw CoreError("REFERENCE_GRAPH_LIMIT","The current reference graph exceeds the cleanup safety bound; originals retained.")}
            let source: Data = row["source"],target: Data = row["target"]
            try budget.retain(source.count + target.count + 96)
            reverse[target,default:[]].append(source)
        }
        var seen = Set<Data>(),selected = Set<Data>()
        while let token = pending.popFirst() {
            try deadline.check()
            guard seen.insert(token).inserted else { continue }
            for id in reverse[token] ?? [] {
                if selected.insert(id).inserted {
                    try budget.retain(id.count + 128)
                    pending.insert(id)
                }
            }
        }
        reverse.removeAll()
        // Fetch selected identities through the primary index, without decoding
        // any unrelated captured-file lists, notes or evidence payloads.
        let selectedRow = try db.makeStatement(sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT)")
        for id in selected {
            try autoreleasepool {
                try deadline.check()
                guard let row = try Row.fetchOne(selectedRow,arguments:[id]) else {throw CoreError("REFERENCE_GRAPH_LIMIT","A current reference could not be resolved; originals retained.")}
                let bytes: Data = row["_envelope_data_bytes"]
                try budget.retain(bytes.count + id.count + 256)
                let decoded = try GRDBRecordEnvelopeAdapter.decode(row)
                var value = decoded.object;value["record_type"] = decoded.type;graph[id] = value
            }
        }
        // Only the canonical index decides which storage job kinds can carry
        // a transitive hold. SQL's first duplicate key must not prune reachability.
        let index = try ArchiveCleanupReferenceIndex(Array(graph.values),check:deadline.check,charge:{try budget.retain($0)})
        return (index,selected)
    }
}
