import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

/// The archive scan's writer-side change observation must remain bounded even
/// when maintenance publishes a large, otherwise valid legacy deletion receipt.
final class ArchiveCleanupJournalBudgetTests: XCTestCase {
    private let byteLimit = 8 * 1024 * 1024

    private func fixture(_ body: (Database) throws -> Void) throws {
        let queue = try DatabaseQueue()
        try queue.writeWithoutTransaction { db in
            try db.execute(sql:"CREATE TABLE records(id TEXT PRIMARY KEY,project_id TEXT,type TEXT,revision INTEGER,data TEXT)")
            try db.execute(sql:"INSERT INTO records VALUES('legacy-receipt','project','storage_job',1,'{}')")
            try ArchiveCleanupScanJournal.install(db)
            try body(db)
        }
    }

    private func payload(_ value: [String:Any]) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self)
    }

    private func scan(_ db: Database) throws -> PreparedArchiveCleanupScan {
        .init(taskID:"selected-ticket",tokens:[],fenceIDs:[Data("selected-ticket".utf8)],targets:[],rows:[],failure:nil,generation:try Int.fetchOne(db,sql:"PRAGMA data_version"))
    }

    private func unknown(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NULL)") == true
    }

    func testOversizeLegacyReceiptRecordsIdentityAndRefusesWithoutIndexingItsPayload() throws {
        // A legacy settlement updates all descriptors in one receipt. Its data
        // is valid JSON but exceeds the changed-payload parsing budget.
        let objects = (0..<12_000).map { index in
            ["relative_path":"source-captures/legacy/recorded-source/files/" + String(repeating:"segment-",count:8) + "\(index).swift",
             "state":"retained","reasons":["legacy_replan_required"]] as [String:Any]
        }
        let data = try payload(["id":"legacy-receipt","kind":"ticket_object_delete","cause":"done_evidence","objects":objects])
        XCTAssertGreaterThan(data.utf8.count,1_048_576)
        try fixture { db in
            let prepared = try scan(db)
            try db.execute(sql:"UPDATE records SET revision=2,data=? WHERE id='legacy-receipt'",arguments:[data])
            XCTAssertTrue(try unknown(db),"An unparsed changed payload must fail the archive fence closed")
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NOT NULL"),0,"Oversize payload strings must never enter the TEMP indexes")
            XCTAssertGreaterThan(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes WHERE id=CAST('legacy-receipt' AS BLOB)") ?? 0,0)
            XCTAssertThrowsError(try prepared.validate(db,tokens:[])) { error in
                XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
            }
        }
    }

    func testChangedAtomBytesAreBoundedAndExhaustionRefuses() throws {
        try fixture { db in
            let prepared = try scan(db)
            // Each update is individually small enough to parse. Different long
            // strings exercise retained bytes independently of a row-count cap.
            for index in 0..<24 {
                let data = try payload(["value":"\(index):" + String(repeating:"x",count:512 * 1024)])
                try db.execute(sql:"UPDATE records SET revision=revision+1,data=? WHERE id='legacy-receipt'",arguments:[data])
            }
            let bytes = try Int.fetchOne(db,sql:"SELECT COALESCE(SUM(COALESCE(length(id),0)+COALESCE(length(atom),0)),0) FROM archive_cleanup_scan_changes") ?? 0
            XCTAssertLessThanOrEqual(bytes,byteLimit)
            XCTAssertTrue(try unknown(db))
            XCTAssertThrowsError(try prepared.validate(db,tokens:[])) { error in
                XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
            }
        }
    }

    func testRolledBackOversizeWriteLeavesNoUnknownOrIdentity() throws {
        let data = try payload(["value":String(repeating:"x",count:1_048_577)])
        try fixture { db in
            let prepared = try scan(db)
            try db.inTransaction {
                try db.execute(sql:"UPDATE records SET revision=2,data=? WHERE id='legacy-receipt'",arguments:[data])
                return .rollback
            }
            XCTAssertFalse(try unknown(db))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes"),0)
            XCTAssertNoThrow(try prepared.validate(db,tokens:[]))
        }
    }

    func testDuplicateAtomDoesNotHideALaterNewReference() throws {
        try fixture { db in
            let prepared = PreparedArchiveCleanupScan(taskID:"selected-ticket",tokens:[],fenceIDs:[],targets:[Data("selected-original".utf8)],rows:[],failure:nil,generation:try Int.fetchOne(db,sql:"PRAGMA data_version"))
            let data = try payload(["atoms":["repeated","repeated","selected-original"]])
            try db.execute(sql:"UPDATE records SET revision=2,data=? WHERE id='legacy-receipt'",arguments:[data])
            XCTAssertFalse(try unknown(db))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom=CAST('repeated' AS BLOB)"),1)
            XCTAssertThrowsError(try prepared.validate(db,tokens:[])) { error in
                XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
                XCTAssertEqual((error as? CoreError)?.details["reason"] as? String,"fenced by concurrent write to a reference to the ticket's originals")
            }
        }
    }

    func testCanonicalUpsertDeduplicatesIdentitiesAndPreservesLaterNewReference() throws {
        try fixture { db in
            let prepared = PreparedArchiveCleanupScan(taskID:"selected-ticket",tokens:[],fenceIDs:[],targets:[Data("selected-original".utf8)],rows:[],failure:nil,generation:try Int.fetchOne(db,sql:"PRAGMA data_version"))
            let data = try payload(["atoms":["repeated","repeated","selected-original"]])
            // Match the canonical save's outer UPSERT. Its conflict policy must
            // not turn an already observed OLD/NEW identity into a SQL failure.
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('legacy-receipt','project','storage_job',2,?) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,type=excluded.type,revision=excluded.revision,data=excluded.data",arguments:[data])
            XCTAssertFalse(try unknown(db))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes WHERE id=CAST('legacy-receipt' AS BLOB)"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom=CAST('repeated' AS BLOB)"),1)
            XCTAssertThrowsError(try prepared.validate(db,tokens:[])) { error in
                XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
                XCTAssertEqual((error as? CoreError)?.details["reason"] as? String,"fenced by concurrent write to a reference to the ticket's originals")
            }
        }
    }
}
