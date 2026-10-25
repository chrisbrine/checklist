import XCTest
import ChecklistIPC

final class BackupCapacityErrorTests: XCTestCase {
    func testCLIErrorDescriptionPreservesBackupReasonAndCommandID() {
        let id = UUID().uuidString
        for reason in ["snapshot_manifest_capacity", "snapshot_object_capacity", "snapshot_object_bytes", "snapshot_capacity"] {
            let error = ChecklistError("BACKUP_CAPACITY_EXCEEDED","Preserve the existing store.",details:["reason":reason,"command_id":id])
            XCTAssertTrue(error.localizedDescription.contains("Reason: " + reason + "."))
            XCTAssertTrue(error.localizedDescription.contains("Command ID: " + id))
        }
        XCTAssertTrue(ChecklistError("BACKUP_DEADLINE_EXCEEDED","Time budget",details:["reason":"snapshot_deadline"]).localizedDescription.contains("snapshot_deadline"))
        XCTAssertEqual(ChecklistError("FORBIDDEN","No.",details:["reason":"private context"]).localizedDescription,"FORBIDDEN: No.")
    }
}
