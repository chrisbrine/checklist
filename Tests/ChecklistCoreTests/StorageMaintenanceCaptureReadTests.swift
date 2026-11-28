import XCTest
import GRDB
import ChecklistTestSupport
@testable import ChecklistCore

/// CL-363: one storage maintenance pass reads the backup capture hold once. Its cleanup pass
/// accepts that read, because no hold can start while the object gate is held
/// (`StorageBackupConcurrencyTests.testCaptureAdmissionWaitsForAnAlreadyAdmittedObjectOperation`).
/// Every other caller of the cleanup pass keeps its own read.
final class StorageMaintenanceCaptureReadTests: XCTestCase {
    func testAMaintenancePassStopsAtTheCaptureHoldAndADirectCleanupPassKeepsItsOwnRead() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CL363-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try TestStore.router(root: root, durable: false)
        defer { try? router.closeStore() }
        // A due cleanup job that cannot be decoded: a cleanup pass that reaches its jobs throws.
        try router.dbQueue.write {
            try $0.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES ('capture-read-job','capture-read-project','cleanup_job',1,'{\"state\":\"queued\",\"not_before_ms\":0}')")
        }
        func underGate(_ body: (Database, ArchiveStoragePermit) throws -> Void) throws {
            try ArchiveStorageGate.withExclusive(root: router.root) { permit in
                try router.dbQueue.writeWithoutTransaction { try body($0, permit) }
            }
        }
        try StorageSnapshotRetention.withCapture(root: router.root) { _ in
            XCTAssertNoThrow(try router.runStorageMaintenance())
            XCTAssertEqual(router.currentStorageMaintenanceWarning(), .backupCapture)
            try underGate { db, permit in
                // A direct cleanup pass reads the hold by itself and returns before its jobs.
                XCTAssertNoThrow(try router.processArchiveCleanupJobs(db, permit: permit, nowMS: .max))
            }
        }
        try underGate { db, permit in
            // No capture: the direct pass reaches the malformed job.
            XCTAssertThrowsError(try router.processArchiveCleanupJobs(db, permit: permit, nowMS: .max))
        }
        XCTAssertThrowsError(try router.runStorageMaintenance())
        XCTAssertEqual(router.currentStorageMaintenanceWarning(), .retryPending)
    }
}
