import XCTest
import GRDB
@testable import ChecklistCore

final class StartupImportSweepTests: XCTestCase {
    func testSweepDoesNotDecodeUnrelatedCleanupHistory() throws {
        let f = try ReadPerformanceFixture("CL-400-startup"),r = f.router
        try f.save([
            ("storage_job",["id":"cleanup","project_id":"project","revision":1,"kind":"ticket_object_delete","objects":[["history":String(repeating:"x",count:1_048_576)]]]),
            ("storage_job",["id":"import","project_id":"project","revision":1,"kind":"attachment_import","state":"settled"])
        ])
        try r.dbQueue.writeWithoutTransaction {db in
            // A valid unrelated payload with an invalid envelope revision proves
            // that the import sweep never canonically decodes cleanup history.
            try db.execute(sql:"UPDATE records SET data=json_set(data,'$.revision',2) WHERE id='cleanup'")
            let before = try Data.fetchOne(db,sql:"SELECT CAST(data AS BLOB) FROM records WHERE id='cleanup'")
            XCTAssertNoThrow(try r.sweepAbandonedManagedImports(db))
            XCTAssertEqual(try Data.fetchOne(db,sql:"SELECT CAST(data AS BLOB) FROM records WHERE id='cleanup'"),before)
            XCTAssertEqual(try r.record(db,"import",type:"storage_job")["state"] as? String,"settled")
        }
    }

    func testMalformedJSONAndSelectedImportStillRefuseCanonicalDecode() throws {
        let f = try ReadPerformanceFixture("CL-400-invalid-import"),r = f.router
        try f.save([("storage_job",["id":"import","project_id":"project","revision":1,"kind":"attachment_import","state":"settled"])])
        try r.dbQueue.writeWithoutTransaction {db in
            try db.execute(sql:"UPDATE records SET data=json_set(data,'$.revision',2) WHERE id='import'")
            XCTAssertThrowsError(try r.sweepAbandonedManagedImports(db)) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")}
            try db.execute(sql:"UPDATE records SET data='{' WHERE id='import'")
            XCTAssertThrowsError(try r.sweepAbandonedManagedImports(db)) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")}
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT data FROM records WHERE id='import'"),"{")
        }
    }
    func testEveryMutatingImportIsVisitedOnceIncludingCanceledCleanup() throws {
        let f = try ReadPerformanceFixture("CL-400-multiple-imports"),r = f.router
        var jobs: [(String,JSON)] = (0..<3).map {index in
            ("storage_job",["id":"abandoned-\(index)","project_id":"project","revision":1,"kind":"attachment_import","state":"finalized",
                "created_at":"2020-01-01T00:00:00Z","parent_principal":"missing","parent_command_id":UUID().uuidString,
                "intent_digest":"missing","attachment_id":"missing-\(index)","objects":[JSON]()])
        }
        jobs.insert(("storage_job",["id":"canceled","project_id":"project","revision":1,"kind":"attachment_import","state":"settled",
            "settled_reason":"canceled_media_staging","cancellation_cleanup_complete":false]),at:1)
        try f.save(jobs)
        try r.dbQueue.writeWithoutTransaction {db in
            try r.sweepAbandonedManagedImports(db)
            for index in 0..<3 {
                let job = try r.record(db,"abandoned-\(index)",type:"storage_job")
                XCTAssertEqual(job["state"] as? String,"settled")
                XCTAssertEqual(job["settled_reason"] as? String,"abandoned_without_receipt")
                XCTAssertEqual(job["revision"] as? Int,2)
            }
            let canceled = try r.record(db,"canceled",type:"storage_job")
            XCTAssertEqual(canceled["cancellation_cleanup_complete"] as? Bool,true)
            XCTAssertEqual(canceled["revision"] as? Int,2)
            try r.sweepAbandonedManagedImports(db)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job' AND revision=2"),4)
        }
    }

}
