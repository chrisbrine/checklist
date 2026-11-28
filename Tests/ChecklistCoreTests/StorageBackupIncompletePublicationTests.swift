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
        budget.observe = {event in if event == "published_before_parent_flush" {flushing = true}}
        XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":uuid(),"path":destination.path],caller:f.owner,budget:budget)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_DEADLINE_EXCEEDED")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let failed = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:destination.deletingLastPathComponent(),includingPropertiesForKeys:nil).first {$0.lastPathComponent.hasPrefix(".snapshot-failed-")})
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:failed.appendingPathComponent(".backup-failed.json"))) as? JSON
        XCTAssertEqual(marker?["state"] as? String,"failed")
        XCTAssertThrowsError(try f.router!.handle(method:"restore_preview",params:["path":failed.path],caller:f.owner))
        let preview = try f.router!.backupPrunePreview()
        XCTAssertTrue((preview["snapshots"] as? [JSON] ?? []).contains {$0["path"] as? String == failed.path && $0["state"] as? String == "incomplete"})
    }

    func testDefiniteCanceledPublicationQuarantinesWhileArchiveGateAndWriterAreHeld() throws {
        let f = try StorageFixture()
        let router = try XCTUnwrap(f.router)
        let command = uuid()
        let destination = f.root.appendingPathComponent("backups/snapshot-" + command.lowercased())
        let published = DispatchSemaphore(value:0), resourcesHeld = DispatchSemaphore(value:0)
        let backupFinished = DispatchSemaphore(value:0), holderFinished = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            defer {holderFinished.signal()}
            guard published.wait(timeout:.now() + 30) == .success else {
                return XCTFail("The backup did not reach the publication fence.")
            }
            do {
                try ArchiveStorageGate.withExclusive(root:router.root) { _ in
                    try router.dbQueue.write { _ in
                        resourcesHeld.signal()
                        XCTAssertEqual(backupFinished.wait(timeout:.now() + 10),.success)
                    }
                }
            } catch {XCTFail("Could not hold the archive gate and SQLite writer: \(error)")}
        }

        var budget = StorageSnapshotBudget.production()
        budget.observe = {event in
            guard event == "publication_fence_checked" else {return}
            published.signal()
            XCTAssertEqual(resourcesHeld.wait(timeout:.now() + 10),.success)
            throw StorageSnapshotFailure.canceled
        }
        XCTAssertThrowsError(try router.executeStorageBackup(params:["command_id":command],caller:f.owner,budget:budget)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CANCELED")
        }
        backupFinished.signal()
        XCTAssertEqual(holderFinished.wait(timeout:.now() + 30),.success)

        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let failed = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:destination.deletingLastPathComponent(),includingPropertiesForKeys:nil).first {$0.lastPathComponent.hasPrefix(".snapshot-failed-")})
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:failed.appendingPathComponent(".backup-failed.json"))) as? JSON
        XCTAssertEqual(marker?["manifest_sha256"] as? String,ChecklistCore.hash(try Data(contentsOf:failed.appendingPathComponent("manifest.json"))))
    }
}
