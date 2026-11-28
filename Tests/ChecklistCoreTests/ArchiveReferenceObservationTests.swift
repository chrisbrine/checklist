import XCTest
import GRDB
@testable import ChecklistCore

final class ArchiveReferenceObservationTests: XCTestCase {
    func testRelevantObservationEqualsCompleteGraphWithEscapedAndTransitiveForeignReferences() throws {
        let f = try ReadPerformanceFixture("CL-150"),r = f.router
        let project = try f.call("project_create",["name":"Reference observation","key_prefix":"RO"])
        let created = try f.call("task_create",["project_id":project["id"]!,"title":"Reference fixture"])
        let foreignProject = try f.call("project_create",["name":"Foreign references","key_prefix":"FR"])
        let other = try f.call("task_create",["project_id":foreignProject["id"]!,"title":"Other fixture"])
        let unrelatedTask = try f.call("task_create",["project_id":foreignProject["id"]!,"title":"Unrelated fixture"])
        let unrelatedTaskID = try XCTUnwrap(unrelatedTask["id"] as? String)
        var task = created;task["archived"] = false
        var archived = other;archived["archived"] = true
        let path = r.root.appendingPathComponent("objects/original-é").path
        var attachment: JSON = ["id":"original\0é","project_id":"p","task_id":"task","revision":1,"path":path,"sha256":String(repeating:"a",count:64),"size":42,"mode":"managed","availability":"available"]
        let pid = project["id"] as! String,tid = created["id"] as! String,otherID = other["id"] as! String
        func scoped(_ value: JSON) -> JSON {
            var value = value
            if value["project_id"] as? String == "p" { value["project_id"] = pid }
            if value["project_id"] as? String == "foreign" { value["project_id"] = foreignProject["id"]! }
            if value["task_id"] as? String == "task" { value["task_id"] = tid }
            if value["task_id"] as? String == "other" { value["task_id"] = otherID }
            return value
        }
        attachment = scoped(attachment)
        try f.save([
            ("task",task),("task",archived),
            ("attachment",attachment),
            ("attachment",["id":"obs-shared","project_id":"foreign","task_id":"other","revision":1,"path":path,"availability":"available"]),
            ("source_capture",["id":"capture\0é","project_id":"p","task_id":"task","revision":1,"files":[["nested":["original\0é"]]]]),
            ("manifest",["id":"obs-manifest","project_id":"p","task_id":"task","revision":1,"capture":"capture\0é"]),
            ("review_request",["id":"obs-review","project_id":"p","task_id":"task","revision":1,"manifest_id":"obs-manifest","state":"active"]),
            ("source_execution",["id":"obs-build","project_id":"foreign","task_id":"other","revision":1,"manifest":"obs-manifest","state":"running"]),
            ("request",["id":"obs-request","project_id":"foreign","task_id":"other","revision":1,"path":String(path.dropFirst((r.root.path + "/").count)),"state":"pending"]),
            ("storage_job",["id":"import","project_id":"p","revision":1,"kind":"attachment_import","original":"original\0é","parent_principal":"missing","parent_command_id":"missing","intent_digest":"missing"]),
            ("storage_hold",["id":"obs-reader","project_id":"p","revision":1,"kind":"reader","attachment_id":"original\0é","state":"active"]),
            ("storage_hold",["id":"obs-expired","revision":1,"kind":"backup","attachment_id":"original\0é","state":"active","expires_at":1]),
            ("message",["id":"unrelated","project_id":"foreign","revision":1,"body":String(repeating:"Unrelated data ",count:10000)])
        ].map { ($0.0,scoped($0.1)) })
        // JSON spelling must not affect reachability, including escaped NUL and non-ASCII.
        try r.dbQueue.write { db in
            try db.execute(sql:"UPDATE records SET data=replace(data,'é','\\u00e9')")
        }
        try r.dbQueue.writeWithoutTransaction { db in
            let full = try legacyArchiveCleanupReferenceRows(db)
            let relevant = try r.archiveCleanupRelevantReferenceRows(db,attachments:[attachment])
            XCTAssertFalse(relevant.contains { $0["id"] as? String == "unrelated" })
            for archiving in [false,true] {
                let before = try r.completeArchiveCleanupHolds(db,attachment:attachment,task:task,considerArchiving:archiving,currentGraph:full)
                let after = try r.completeArchiveCleanupHolds(db,attachment:attachment,task:task,considerArchiving:archiving,currentGraph:relevant)
                XCTAssertEqual(before,after)
                XCTAssertTrue(after.isSuperset(of:[.sharedLiveReference,.currentReview,.activeBuild,.pendingHumanInspection,.pendingImport,.activeReader]))
                XCTAssertFalse(after.contains(.backupCapture))
            }
            // Vary direct/indirect references independently. The writer's
            // reduced executor graph must give the same holds as the full graph.
            let optionalRows = ["obs-shared","obs-review","obs-build","import","obs-reader","obs-request"]
            for bits in 0..<(1 << optionalRows.count) {
                try db.inSavepoint {
                    for (position, id) in optionalRows.enumerated() where bits & (1 << position) == 0 {
                        try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])
                    }
                    let full = try legacyArchiveCleanupReferenceRows(db)
                    let prepared = try r.scanArchiveCleanupSnapshot(db,taskID:tid,attachments:[attachment],generation:nil)
                    XCTAssertNil(prepared.failure)
                    let relevant = try XCTUnwrap(prepared.index)
                    XCTAssertFalse(relevant.graph.contains { $0["id"] as? String == "unrelated" })
                    XCTAssertFalse(relevant.graph.contains { $0["id"] as? String == unrelatedTaskID })
                    let before = try r.completeArchiveCleanupHolds(db,attachment:attachment,task:task,currentGraph:full)
                    let after = try r.completeArchiveCleanupHolds(db,attachment:attachment,task:task,currentIndex:relevant)
                    XCTAssertEqual(before,after,"reference combination \(bits)")
                    return .rollback
                }
            }
        }
    }

    func testProjectionPreservesCanonicalRefusalsEvenForUnrelatedRows() throws {
        let f = try ReadPerformanceFixture("CL-150"),r = f.router
        try f.save([("message",["id":"unrelated","project_id":"p","revision":1])])
        let cases: [(String,String,String)] = [
            ("message",#"{"id":"unrelated","id":"unrelated","project_id":"p","revision":1}"#,"duplicateEnvelopeField"),
            ("message",#"{}"#,"jsonIdentity"),
            ("message",#"{"id":"different","project_id":"p","revision":1}"#,"identityMismatch"),
            ("message",#"{"id":"unrelated","project_id":"p","revision":1.00000000000000001}"#,"jsonRevision"),
            ("message",#"{"id":"unrelated","project_id":"p","revision":1,"nested":[}"#,"jsonObject"),
            ("message",#"{"id":"unrelated","project_id":"p","revision":1,"nested":["\ud800"]}"#,"jsonObject"),
            ("unknown",#"{"id":"unrelated","project_id":"p","revision":1}"#,"unsupportedFamily"),
            ("session",#"{"id":"unrelated","project_id":"p","revision":1,"project_ids":[1]}"#,"ownershipShape"),
            ("storage_hold",#"{"id":"unrelated","project_id":"p","revision":1,"kind":"media_reference","owner_id":"owner","owner_kind":"media_target","attachment_id":"a","expires_at":0}"#,"ownershipShape")
        ]
        try r.dbQueue.write { db in
            for (type,data,reason) in cases {
                try db.execute(sql:"UPDATE records SET type=?,data=? WHERE id='unrelated'",arguments:[type,data])
                var fullError: CoreError?,limitedError: CoreError?
                do { _ = try legacyArchiveCleanupReferenceRows(db) } catch { fullError = error as? CoreError }
                do { _ = try r.archiveCleanupRelevantReferenceRows(db,attachments:[]) } catch { limitedError = error as? CoreError }
                XCTAssertEqual(fullError?.code,"CANONICAL_RECORD_INVALID",reason)
                XCTAssertEqual(limitedError?.code,fullError?.code,reason)
                XCTAssertEqual(limitedError?.details["reason"] as? String,fullError?.details["reason"] as? String,reason)
            }
            try db.execute(sql:"UPDATE records SET type='message',data=CAST(? AS BLOB) WHERE id='unrelated'",arguments:[Data(#"{"id":"unrelated","project_id":"p","revision":1}"#.utf8)])
            XCTAssertThrowsError(try r.archiveCleanupRelevantReferenceRows(db,attachments:[])) { XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"sqlData") }
            try db.execute(sql:"UPDATE records SET data=CAST(? AS TEXT) WHERE id='unrelated'",arguments:[Data([0xff])])
            XCTAssertThrowsError(try r.archiveCleanupRelevantReferenceRows(db,attachments:[])) { XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"sqlData") }

        }
    }

    func testObservationRefusesExpiredAndOverBudgetProofsWithoutPoisoningReader() throws {
        let f = try ReadPerformanceFixture("CL-150"),r = f.router
        let project = try f.call("project_create",["name":"Archive proof limits","key_prefix":"AP"])
        _ = try f.call("task_create",["project_id":project["id"]!,"title":"Retained task projection"])
        try r.dbQueue.read {db in
            let attachment: JSON = ["id":"original"]
            func assertLimit(_ budget: ArchiveCleanupObservationBudget,_ limit: String) {
                XCTAssertThrowsError(try r.archiveCleanupRelevantReferenceRows(db,attachments:[attachment],budget:budget)) {error in
                    XCTAssertEqual((error as? CoreError)?.code,"REFERENCE_GRAPH_LIMIT")
                    XCTAssertEqual((error as? CoreError)?.details["limit"] as? String,limit)
                }
            }
            assertLimit(.init(seconds:0),"observation_seconds")
            assertLimit(.init(byteLimit:1),"retained_bytes")
            XCTAssertNoThrow(try r.archiveCleanupRelevantReferenceRows(db,attachments:[attachment]))
        }
    }
}

/// The complete pre-CL-514 reader used as a differential oracle.
func legacyArchiveCleanupReferenceRows(_ db: Database) throws -> [JSON] {
    var graph: [JSON] = []
    let cursor = try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid")
    while let row = try cursor.next() {
        guard graph.count < 250_000 else {throw CoreError("REFERENCE_GRAPH_LIMIT","The current reference graph exceeds the cleanup safety bound; originals are retained.")}
        let decoded = try GRDBRecordEnvelopeAdapter.decode(row)
        var value = decoded.object
        value["record_type"] = decoded.type
        graph.append(value)
    }
    return graph
}
