import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class MediaBackupTests: XCTestCase {
    func captured() throws -> MediaFrozenIntakeTests.Fixture {
        let helper = MediaFrozenIntakeTests(),f = try MediaFrozenIntakeTests.Fixture()
        let round = try f.round(f.type(helper.imageSchema()))
        let intake = try helper.confirm(f,helper.preview(f,round,[helper.source(f,"backup.png")]))
        _ = try helper.capture(f,intake);_ = try f.publish(round)
        try f.reopen() // Import reconciliation changes committed jobs to settled.
        XCTAssertEqual(try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"}.map {$0["state"] as? String},["settled"])
        return f
    }
    func testSettledMediaBackupCapturesCanonicalFamiliesAndOriginals() throws {
        let f = try captured(),destination = f.base.appendingPathComponent("media-backup")
        let result = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":destination.path],caller:f.owner)
        XCTAssertEqual((result["data"] as? JSON)?["status"] as? String,"complete")
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.objects.count,2)
        XCTAssertFalse(manifest.objects.flatMap {$0.descriptor.authorities}.contains {$0.contains("uncommitted_recovery")})
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(manifest.objects.first {$0.descriptor.relativePath == attachment["path"] as? String})
        let bytes = try Data(contentsOf:destination.appendingPathComponent("managed/" + original.descriptor.relativePath))
        XCTAssertEqual(ChecklistCore.hash(bytes),attachment["sha256"] as? String)
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:configuration)
        defer {try? copy.close()}
        try f.router.dbQueue.read {source in try copy.read {db in
            let sql = "SELECT id,type,revision,data FROM records WHERE type LIKE 'media_%' OR type IN ('storage_job','storage_hold','attachment') ORDER BY id"
            XCTAssertEqual(try Row.fetchAll(source,sql:sql),try Row.fetchAll(db,sql:sql))
        }}
        let reconciled = try StorageSnapshot.reconcile(parent:destination.deletingLastPathComponent(),operation:UUID(uuidString:(result["data"] as! JSON)["operation_id"] as! String)!,publicationName:destination.lastPathComponent,budget:.production())
        XCTAssertEqual(reconciled.manifestSHA256,(result["data"] as! JSON)["manifest_sha256"] as? String)
    }
    func testMissingRequiredSettledMediaOriginalFailsVisiblyWithoutBackupReceipt() throws {
        let f = try captured(),destination = f.base.appendingPathComponent("missing-backup"),command = uuid()
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        try FileManager.default.removeItem(at:f.router.managedURL(attachment["path"] as! String,family:"objects"))
        XCTAssertThrowsError(try f.router.handle(method:"backup_create",params:["command_id":command,"path":destination.path],caller:f.owner)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_IO_ERROR","\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try f.router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command])},0)
        XCTAssertEqual(try Data(contentsOf:f.router.managedURL(attachment["preview_path"] as! String,family:"objects")).count > 0,true)
    }
    func testCanceledFinalizedMediaRemainsRecoveryOnlyInBackup() throws {
        let f = try MediaHistoryCaptureTests.Fixture(),anchor = try f.anchor()
        let bytes = Data("retained canceled original".utf8),pending = try f.prepare(anchor,"canceled.txt",bytes)
        _ = try f.router.cancelMediaAttachmentImport(project:f.project,owner:anchor,commandID:pending.command,caller:f.owner)
        let (destination,manifest) = try f.backup()
        let original = try XCTUnwrap(manifest.objects.first {$0.descriptor.authorities.contains("storage_job:" + (pending.job["id"] as! String) + ":uncommitted_recovery:original")})
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("managed/" + original.descriptor.relativePath)),bytes)
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.relativePath.hasPrefix("staging/")})
        XCTAssertTrue(manifest.unavailable.contains {$0.reason == "uncommitted_media_capture_staging_excluded"})
        XCTAssertFalse(try f.readCopy(destination).contains {$0.type == "attachment"})
    }

}
