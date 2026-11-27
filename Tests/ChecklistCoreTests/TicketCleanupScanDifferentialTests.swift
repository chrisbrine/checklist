import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testCL516OldAndNewCleanupSelectSameOwnedAndReferencedRows() throws {
        for count in [32, 128, 512] {
            let (project,task,attachment) = try independentFixture(backed:false)
            let pid = project["id"] as! String,tid = task["id"] as! String
            let other = try call("task_create",["project_id":pid,"title":"Unrelated synthetic ticket"])
            let otherID = other["id"] as! String,attachmentID = attachment["id"] as! String
            let parent = uuid(),child = uuid(),capture = uuid(),accounting = uuid(),hold = uuid()
            let prefix = "source-captures/" + pid + "/" + capture + "/source"
            let rows = (0..<count).map {_ in uuid()}
            let generatedIDs = Set((rows + [parent,child,capture,accounting,hold,attachmentID]).map {Data($0.utf8)})
            var generatedOwned = Set([Data(parent.utf8),Data(child.utf8),Data(capture.utf8),Data(attachmentID.utf8)])
            var generatedReferences = Set([Data(hold.utf8)])
            try write {db in
                func save(_ i: String,_ type: String,_ fields: JSON) throws {
                    var value = fields;value["id"] = i;value["project_id"] = pid;value["revision"] = 1
                    try self.router.save(db,value,type:type)
                }
                // The scan has to discover this child after the parent appears.
                try save(child,"message",["message_id":parent])
                try save(parent,"message",["task_id":tid])
                try save(capture,"source_capture",["task_id":tid,"snapshot_path":prefix,"files":[]])
                try save(accounting,"storage_job",["kind":"ticket_object_delete","task_id":tid,"state":"completed","objects":[["owner_ids":[attachmentID]]]])
                try save(hold,"storage_hold",["kind":"reader","state":"active","body":[attachment["sha256"] as! String:"exact digest"]])
                for (index,id) in rows.enumerated() {
                    let padding = index.isMultiple(of:5) ? String(repeating:"payload-",count:2400) : "short synthetic payload"
                    switch index % 7 {
                    case 0:
                        generatedOwned.insert(Data(id.utf8))
                        try save(id,"message",["task_id":tid,"body":padding])
                    case 1:
                        generatedOwned.insert(Data(id.utf8))
                        try save(id,"message",["message_id":child,"body":padding])
                    case 2:
                        generatedReferences.insert(Data(id.utf8))
                        try save(id,"message",["task_id":otherID,"body":[attachmentID:padding]])
                    case 3:
                        generatedReferences.insert(Data(id.utf8))
                        try save(id,"message",["task_id":otherID,"body":[prefix + "/retained.txt",padding]])
                    case 4:
                        generatedReferences.insert(Data(id.utf8))
                        try save(id,"message",["task_id":otherID,"message_id":parent,"body":padding])
                    default:
                        try save(id,"message",["task_id":otherID,"body":[prefix + "-unrelated/retained.txt",padding]])
                    }
                }
            }
            try XCTUnwrap(router.readers).read {db in
                let old = try self.router.legacyCleanupInventory(db,task:task)
                let new = try self.router.ticketCleanupInventory(db,task:task)
                let ownedOld = self.router.ticketPurgeOwnedKeys(all:old.rows,pid:pid,tid:tid)
                let ownedNew = self.router.ticketPurgeOwnedKeys(all:new.rows,pid:pid,tid:tid)
                let refsOld = Set(old.rows.map(\.key)).subtracting(ownedOld)
                let refsNew = Set(new.rows.map(\.key)).subtracting(ownedNew)
                XCTAssertEqual(ownedNew,ownedOld,"Generated row count: \(count)")
                XCTAssertEqual(refsNew,refsOld,"Generated row count: \(count)")
                XCTAssertEqual(ownedNew.intersection(generatedIDs),generatedOwned)
                XCTAssertTrue(generatedReferences.isSubset(of:refsNew))
                XCTAssertFalse(refsNew.contains(Data(accounting.utf8)))
                for (index,id) in rows.enumerated() where index % 7 >= 5 {
                    XCTAssertFalse(refsNew.contains(Data(id.utf8)))
                }
                XCTAssertEqual(new.tokens,old.tokens)
                XCTAssertEqual(new.retainedBytes,old.retainedBytes)
            }
        }
    }

    func testCL516ManualPurgeMatchesFullGraphForLegacyInheritedOwnership() throws {
        let (project,task,_) = try fixture(backed:false)
        let pid = project["id"] as! String,tid = task["id"] as! String
        let foreign = try call("task_create",["project_id":pid,"title":"Foreign synthetic ticket"])
        let foreignID = foreign["id"] as! String
        let parent = uuid(),nullChild = uuid(),numericChild = uuid(),foreignNote = uuid()
        try write {db in
            try self.router.save(db,["id":nullChild,"project_id":pid,"revision":1,"task_id":NSNull(),
                "message_id":parent,"body":String(repeating:"long synthetic body ",count:1000)],type:"message")
            try self.router.save(db,["id":numericChild,"project_id":pid,"revision":1,"task_id":7,"message_id":nullChild],type:"message")
            try self.router.save(db,["id":parent,"project_id":pid,"revision":1,"task_id":tid],type:"message")
            try self.router.save(db,["id":foreignNote,"project_id":pid,"revision":1,"task_id":foreignID,
                "body":[numericChild:"References only the inherited child"]],type:"message")
        }
        try XCTUnwrap(router.readers).read {db in
            // The manual purge used the complete physical-row graph before
            // switching to the selected inventory on its read lane.
            let legacyRows = try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid LIMIT 100001")
            XCTAssertLessThanOrEqual(legacyRows.count,100_000)
            var legacyInventory = TicketCleanupInventory()
            legacyInventory.rows = try legacyRows.map {row in
                let envelope = try GRDBRecordEnvelopeAdapter.decode(row)
                return PurgeRow(id:envelope.id,type:envelope.type,project:envelope.projectID,value:envelope.object)
            }
            let legacy = try self.router.ticketPurgeReferenceGraph(task:task,inventory:legacyInventory)
            let current = try self.router.ticketPurgePlan(db,task:task)
            XCTAssertEqual(Set(current.owned.map(\.key)),legacy.owned)
            XCTAssertEqual(Set(current.shared.map(\.key)),Set(legacy.shared.map(\.key)))
            XCTAssertEqual(Set(current.removed.map(\.key)),Set(legacy.removed.map(\.key)))
            XCTAssertTrue(Set([parent,nullChild,numericChild]).isSubset(of:Set(current.shared.map(\.id))))
        }
    }
}

// Frozen CL-516 baseline. Keep the original corpus cap and selectors here so
// the comparison exercises the implementation that was deployed before CL-516.
private extension CommandRouter {
    func legacyStreamTicketCleanupRows(_ db: Database,needles: Set<Data> = [],holdDigests: Set<Data> = [],prefixes: Set<String> = [],fullPayloads: Bool = false,_ body: (PurgeRow,Int) throws -> Void) throws {
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
    private func legacyCleanupReferenceObservation(_ db: Database,row: PurgeRow,inventory: TicketCleanupInventory) throws -> TicketCleanupInventory.TokenObservation? {
        do {return try inventory.tokens[row.key].map {TicketCleanupInventory.TokenObservation(tokens:$0)} ?? TicketCleanupInventory.TokenObservation(row.value)}
        catch let error as CoreError where error.code == "REFERENCE_GRAPH_LIMIT" {
            if try row.type == "project" || ticketCleanupBatchLargeMatch(db,row:row,inventory:inventory) {throw error}
            return nil
        }
    }

    func legacyCleanupInventory(_ db: Database,task: JSON) throws -> TicketCleanupInventory {
        let tid = (try StoredRecord(task, family: "task").string("id")), pid = (try StoredRecord(task, family: "task").string("project_id"))
        let containers: Set<String> = ["project","session","profile","status","tag","policy_revision","project_context_revision","taxonomy_revision","group","batch","batch_claim","relation","task"]
        let parents = ["message_id","attempt_id","parent_attempt_id","request_id","review_request_id","manifest_id","membership_id","delegation_id","conversation_id","source_capture_id"]
        var result = TicketCleanupInventory(),owned = Set<Data>()
        // Ownership is transitive. A finite number of streaming rounds discovers
        // children even when a child precedes its parent in physical order.
        for depth in 0..<65 {
            let before = owned.count
            try legacyStreamTicketCleanupRows(db) {row,size in
                guard row.project == pid else {return}
                let direct = row.type == "relation" && row.value["source_task_id"] as? String == tid
                let eligible = !containers.contains(row.type) && !MediaRecordRegistry.families.contains(row.type) && row.type != "storage_hold" && !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind)
                let local = row.value["task_id"] == nil || row.value["task_id"] as? String == tid
                let child = local && parents.contains {field in (row.value[field] as? String).map {owned.contains(Data($0.utf8))} ?? false}
                if direct || eligible && (row.value["task_id"] as? String == tid || child) {
                    owned.insert(row.key);try result.add(row,bytes:size) {try self.record(db,row.id,type:row.type)}
                }
            }
            if before == owned.count {break}
            guard depth < 64 else {throw CoreError("PURGE_LIMIT","Cleanup ownership depth exceeds its bound; bytes retained.")}
        }
        for row in try mediaDoneCleanupHistory(db,task:task) {try result.add(row,bytes:jsonString(row.value).utf8.count) {row.value}}
        result.needles = Set(result.rows.map(\.key)).union([Data(tid.utf8)])
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
        try legacyStreamTicketCleanupRows(db,needles:result.needles,holdDigests:digests,prefixes:result.prefixes,fullPayloads:true) {row,size in
            // Deletion receipts are accounting, never reference authority. The
            // stream still validates their complete canonical payload first.
            guard !(row.type == "storage_job" && row.value["kind"] as? String == Self.ticketObjectDeletionKind) else {return}
            guard let observation = try legacyCleanupReferenceObservation(db,row:row,inventory:result) else {return}
            if row.type == "project" || row.key == Data(tid.utf8) || bool(row.value,"_cleanup_large_match") || result.mentions(observation,includeDigests:row.type == "storage_hold") {
                try result.add(row,bytes:size,observation:observation)
            }
        }
        result.holdDigests = digests
        return result
    }
}
