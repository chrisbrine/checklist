import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testBackupIndexLimitHasExplicitCodeInsteadOfSilentUnavailableHold() throws {
        let (_,_,attachment) = try fixture(backed:false)
        try write {db in
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1025)
                INSERT INTO metadata(key,value) SELECT 'backup-generation:limit-'||i,'{"state":"complete","objects":[]}' FROM n
                """)
        }
        let object: JSON = ["relative_path":try ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root),"sha256":attachment["sha256"]!,"size":attachment["size"]!]
        try router.readers!.read {db in
            let backup = self.router.observeTicketCleanupBackupRetentionIndex(db,objects:[object])
            let reason = "backup_index_error:CLEANUP_INVENTORY_LIMIT"
            XCTAssertEqual(backup.cleanupFailureReason,reason)
            let holds = try self.router.ticketObjectDeletionHolds(db,object:object,references:TicketObjectDeletionReferenceIndex([]),backup:backup,mediaAuthorityComplete:true)
            XCTAssertEqual(holds,[reason])
            XCTAssertTrue(CommandRouter.ticketObjectDeletionReasonsRetryable(holds))
            XCTAssertFalse(CommandRouter.ticketObjectDeletionReasonsRetryable([reason,"keep_original"]))
        }
    }
}

extension TicketLifecycleCleanupTests {
    func testBackupIndexSQLiteFailurePreservesEngineCode() throws {
        let missingMetadata = try DatabaseQueue()
        try missingMetadata.read {db in
            let index = self.router.observeTicketCleanupBackupRetentionIndex(db,objects:[])
            XCTAssertEqual(index.cleanupFailureReason,"backup_index_error:SQLITE_1")
        }
    }
}
