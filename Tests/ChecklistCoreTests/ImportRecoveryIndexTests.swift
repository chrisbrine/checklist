import XCTest
import GRDB
@testable import ChecklistCore

final class ImportRecoveryIndexTests: XCTestCase {
    func testRecoverySelectionMatchesOriginalPredicateAcrossWritesReplaceDeleteAndRollback() throws {
        let f = try ReadPerformanceFixture("CL-251-recovery-index"),r = f.router
        try f.save((0..<80).map {("storage_job",["id":"job-\($0)","project_id":"project","revision":1,"kind":"attachment_import","state":$0 % 3 == 0 ? "committed":"settled"] as JSON)})
        try r.dbQueue.writeWithoutTransaction {db in
            try r.ensureManagedImportRecoveryIndex(db)
            func compare(file: StaticString = #filePath,line: UInt = #line) throws {
                let expected = try Int64.fetchAll(db,sql:"SELECT rowid FROM records WHERE type='storage_job' AND CASE WHEN json_valid(data) THEN CASE WHEN json_type(data)='object' THEN json_extract(data,'$.state') IN ('committed','repair_required') ELSE 1 END ELSE 1 END ORDER BY rowid")
                let actual = try Int64.fetchAll(db,sql:"SELECT record_rowid FROM temp.checklist_import_recovery ORDER BY record_rowid")
                XCTAssertEqual(actual,expected,file:file,line:line)
            }
            try compare()
            try db.execute(sql:"UPDATE records SET data=json_set(data,'$.state','repair_required') WHERE id='job-1'")
            try compare()
            try db.inSavepoint {
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.state','settled') WHERE id='job-0'")
                try compare();return .rollback
            }
            try compare()
            try db.execute(sql:"UPDATE records SET data='{' WHERE id='job-2'")
            try compare()
            let previous = try Row.fetchOne(db,sql:"SELECT id,project_id,type,revision,data FROM records WHERE id='job-3'")!
            try db.execute(sql:"INSERT OR REPLACE INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:[previous["id"] as String,previous["project_id"] as String,previous["type"] as String,previous["revision"] as Int64,previous["data"] as String])
            try compare()
            try db.execute(sql:"DELETE FROM records WHERE id='job-0'")
            try compare()
            try db.execute(sql:"UPDATE records SET type='message' WHERE id='job-1'")
            try compare()
            let tables = try String.fetchAll(db,sql:"SELECT name FROM main.sqlite_master WHERE name LIKE 'checklist_import_recovery%'")
            XCTAssertTrue(tables.isEmpty,"The selection is never durable schema")
        }
    }

    func testEmptyStoreDefersTemporarySchemaUntilFirstJob() throws {
        let f = try ReadPerformanceFixture("CL-251-recovery-lazy"),r = f.router
        try r.dbQueue.writeWithoutTransaction {db in
            XCTAssertFalse(try r.ensureManagedImportRecoveryIndex(db))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM temp.sqlite_master WHERE name='checklist_import_recovery'"),0)
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('first','project','storage_job',1,'{')")
            XCTAssertEqual(try r.reconcileManagedAttachmentImports(db),.retryPending)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM temp.checklist_import_recovery"),1)
        }
    }

    func testIndexCreationRollbackCanRebuildAndMalformedCandidatesStillWarn() throws {
        let f = try ReadPerformanceFixture("CL-251-recovery-rollback"),r = f.router
        try f.save([("storage_job",["id":"settled","project_id":"project","revision":1,"kind":"attachment_import","state":"settled"])])
        try r.dbQueue.writeWithoutTransaction {db in
            try r.ensureManagedImportRecoveryIndex(db)
            for action in ["insert","update","delete"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.checklist_import_recovery_" + action)}
            try db.execute(sql:"DROP TABLE temp.checklist_import_recovery")
            try db.inSavepoint {try r.ensureManagedImportRecoveryIndex(db);return .rollback}
            try r.ensureManagedImportRecoveryIndex(db)
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('broken','project','storage_job',1,'{')")
            XCTAssertEqual(try r.reconcileManagedAttachmentImports(db),.retryPending)
            XCTAssertEqual(try r.reconcileManagedAttachmentImports(db),.suspended)
        }
    }
}
