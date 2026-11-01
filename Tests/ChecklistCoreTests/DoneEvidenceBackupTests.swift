import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-393: Done files that wait for a backup get one, within a bound.
extension TicketLifecycleCleanupTests {
    private func confirmRetention() throws {
        try router.dbQueue.write {db in
            var settings = try self.router.backupRetentionSettings(db)
            settings["automatic_prune"] = true;settings["owner_confirmed"] = true
            settings["owner_confirmation"] = ["source":"authenticated_app","principal":self.owner.principal,"command_id":uuid(),"confirmed_at":ISO8601DateFormatter().string(from:Date()),"source_root":self.router.root.path,"incarnation":self.router.incarnation] as JSON
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('backup-retention-settings',?)",arguments:[try jsonString(settings)])
        }
    }
    private func deadline() throws -> Date? {try router.dbQueue.read {try self.router.doneEvidenceBackupDeadline($0)}}
    private func waitingFile() throws -> (JSON,JSON,JSON) {
        let values = try fixture(backed:false)
        _ = try configure(values.0);try router.runTicketLifecycleCleanup();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:values.2["path"] as! String))
        return values
    }
    private func serviceBackupCount() throws -> Int {
        try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM events WHERE kind='backup_created' AND json_extract(data,'$.origin')='service'") ?? 0}
    }

    func testCL393NoBackupWithoutOwnerConfirmedRetention() throws {
        _ = try waitingFile()
        XCTAssertNil(try deadline())
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:Date().addingTimeInterval(86400)))
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL393NoBackupWhenNoFileWaits() throws {
        try confirmRetention()
        _ = try fixture()
        XCTAssertNil(try deadline())
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:Date().addingTimeInterval(86400)))
    }

    func testCL393WaitingFileGetsOneBackupThenLeavesWithoutASweep() throws {
        try confirmRetention()
        let (_,task,file) = try waitingFile()
        let due = try XCTUnwrap(try deadline())
        XCTAssertGreaterThanOrEqual(due.timeIntervalSinceNow,CommandRouter.doneEvidenceBackupSettle - 120,"The wait settles first")
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(-1)))
        XCTAssertEqual(try serviceBackupCount(),0)
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        XCTAssertEqual(try serviceBackupCount(),1)
        // The completed backup covers the file: nothing waits, and the ticket is woken.
        XCTAssertNil(try deadline())
        let pid = try XCTUnwrap(try read(task)["project_id"] as? String)
        XCTAssertNotNil(try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[task["id"] as! String]})
        router.ticketCleanupYieldAt = nil
        try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(1));try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
    }

    func testCL393RecentBackupAndFailedAttemptEachHoldTheNextOneForTheInterval() throws {
        try confirmRetention()
        _ = try fixture()
        _ = try call("backup_create",["path":directory.appendingPathComponent("cl393-recent").path])
        let backupTime = Date()
        Thread.sleep(forTimeInterval:1.1)
        _ = try waitingFile()
        let due = try XCTUnwrap(try deadline())
        XCTAssertEqual(due.timeIntervalSince(backupTime),CommandRouter.doneEvidenceBackupInterval,accuracy:60)
        // An active capture holds the start without spending the attempt.
        try StorageSnapshotRetention.withCapture(root:router.root) {_ in
            XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        }
        XCTAssertEqual(try serviceBackupCount(),0)
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        XCTAssertEqual(try serviceBackupCount(),1)
    }

    func testCL393AttemptTimeMovesTheDeadline() throws {
        try confirmRetention()
        _ = try waitingFile()
        let time = Date().addingTimeInterval(3600)
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-attempt',?)",arguments:[ISO8601DateFormatter().string(from:time)])}
        XCTAssertEqual(try XCTUnwrap(try deadline()).timeIntervalSince(time),CommandRouter.doneEvidenceBackupInterval,accuracy:1)
    }

    func testCL393OwnerBackupKeepsItsOrigin() throws {
        let (_,_,_) = try fixture()
        _ = try call("backup_create",["path":directory.appendingPathComponent("cl393-owner").path])
        XCTAssertEqual(try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT json_extract(data,'$.origin') FROM events WHERE kind='backup_created' ORDER BY seq DESC LIMIT 1")},"human_ui")
    }
}
