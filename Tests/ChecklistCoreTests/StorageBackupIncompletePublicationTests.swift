import XCTest
import Foundation
@testable import ChecklistCore

final class StorageBackupIncompletePublicationTests: XCTestCase {
    func testDefinitePostPublicationDeadlineIsMarkedQuarantinedAndNotRestorable() throws {
        let f = try StorageFixture();_ = try f.project()
        let destination = f.root.appendingPathComponent("backups/snapshot-deadline")
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        var checksAfterFlush = 0,flushing = false
        var budget = StorageSnapshotBudget(deadlineUptime:1,canceled:{false})
        budget.uptime = {
            if flushing {checksAfterFlush += 1;return checksAfterFlush > 1 ? 2 : 0}
            return 0
        }
        budget.observe = {event in if event == "reconcile_before_parent_flush" {flushing = true}}
        XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":uuid(),"path":destination.path],caller:f.owner,budget:budget)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_DEADLINE_EXCEEDED")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let failed = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:destination.deletingLastPathComponent(),includingPropertiesForKeys:nil).first {$0.lastPathComponent.hasPrefix(".snapshot-failed-")})
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:failed.appendingPathComponent(".backup-failed.json"))) as? JSON
        XCTAssertEqual(marker?["state"] as? String,"failed")
        XCTAssertThrowsError(try f.router!.handle(method:"restore_preview",params:["path":failed.path],caller:f.owner))
        let preview = try f.router!.backupPrunePreview()
        XCTAssertTrue((preview["snapshots"] as? [JSON] ?? []).contains {$0["path"] as? String == failed.path && $0["state"] as? String == "unrecorded_or_incomplete"})
    }
}
