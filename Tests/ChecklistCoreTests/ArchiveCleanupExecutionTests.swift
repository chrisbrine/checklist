import XCTest
import Foundation
import GRDB
import SQLite3
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ChecklistCore

/// Product Core/service entry points against owned copies, never the live store.
final class ArchiveCleanupExecutionTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"archive-executor-tests",projectIDs:[])
    override func setUpWithError() throws {
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .resolvingSymlinksInPath().appendingPathComponent("ChecklistQualification/CL-150")
        directory = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        router = try CommandRouter(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:directory) }
    func call(_ method: String,_ input: JSON,command: String = UUID().uuidString) throws -> JSON {
        var p = input;if !CommandRouter.readMethods.contains(method) {p["command_id"] = command}
        let reply = try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:owner)
        return try XCTUnwrap(reply["data"] as? JSON)
    }
    func transaction(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {try body(db);return .commit} }
    }
    func record(_ id: String,_ type: String) throws -> JSON { try router.dbQueue.read {try router.record($0,id,type:type)} }
    func fixture(count: Int = 1,size: Int = 64,threshold: Int64 = 1,budget: Int64 = 0) throws -> (project: JSON,task: JSON,files: [JSON]) {
        var p = try call("project_create",["name":"Owned cleanup fixture","key_prefix":"GC"])
        // These cases isolate Archive cleanup's deadline and SQL failure seam.
        // The independent daily ticket lifecycle must not add a deadline/event.
        p = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"ticket_cleanup":["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]])
        p = try call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":p["revision"]!,"settings_revision":p["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":threshold,"retained_budget_bytes":budget]])
        let t = try call("task_create",["project_id":p["id"]!,"title":"Owned originals"])
        var files: [JSON] = []
        for i in 0..<count {
            let source = directory.appendingPathComponent("source-\(i).bin");try Data(repeating:UInt8(i % 255),count:size).write(to:source)
            files.append(try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]))
        }
        return (p,t,files)
    }
    func archive(_ f: (project: JSON,task: JSON,files: [JSON])) throws -> JSON {
        let p = try call("attachment_cleanup_preview",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        _ = try call("task_archive",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"expected_revision":f.task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":p["cleanup_preview_id"]!])
        return try router.dbQueue.read {try XCTUnwrap(router.records($0,type:"cleanup_job",project:f.project["id"] as? String).last)}
    }
    /// Advance only this disposable fixture's durable clock, no public time override.
    func makeDue(_ job: JSON) throws {
        try transaction {db in
            var j = try router.record(db,job["id"] as! String,type:"cleanup_job")
            j["enqueued_at_ms"] = Int64(1);j["not_before_ms"] = Int64(2)
            j["revision"] = try router.nextCleanupJobRevision(j)
            _ = try ArchiveCleanupJob(record:j)
            try router.save(db,j,type:"cleanup_job")
            _ = try ArchiveCleanupJob(record:router.record(db,job["id"] as! String,type:"cleanup_job"))
        }
    }
    func exists(_ file: JSON) -> Bool { FileManager.default.fileExists(atPath:file["path"] as! String) }

    func testBackupCaptureDefersCleanupWithoutFailuresAndProtectsManagedUnlinks() throws {
        let f = try fixture(),job = try archive(f)
        try makeDue(job)
        let before = try record(job["id"] as! String,"cleanup_job")
        var observed = false,budget = StorageSnapshotBudget.production()
        budget.observe = {event in
            guard event == "copying_objects" else {return}
            observed = true
            try self.router.runStorageMaintenance()
            XCTAssertGreaterThan(try XCTUnwrap(self.router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,50)
            XCTAssertEqual(try jsonString(self.record(job["id"] as! String,"cleanup_job")),try jsonString(before))
            try ArchiveStorageGate.withExclusive(root:self.router.root) { _ in
                let files = try StorageObjectFiles(root:self.router.root)
                XCTAssertThrowsError(try self.router.removeManagedFile(files,relative:self.router.managedRelative(f.files[0]["path"] as! String,family:"objects"))) {
                    XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")
                }
                let capture = "source-captures/fixture/capture"
                try files.writeNew(capture + "/source/a",bytes:Data("protected".utf8))
                XCTAssertThrowsError(try self.router.removeManagedTree(files,relative:capture)) {
                    XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")
                }
            }
            let holds = try self.router.dbQueue.read {db in
                try self.router.completeArchiveCleanupHolds(db,attachment:f.files[0],task:self.router.record(db,f.task["id"] as! String,type:"task"))
            }
            XCTAssertTrue(holds.contains(.backupCapture))
            XCTAssertTrue(self.exists(f.files[0]))
        }
        _ = try router.executeStorageBackup(params:["command_id":UUID().uuidString,"path":directory.appendingPathComponent("protected-backup").path],caller:owner,budget:budget)
        XCTAssertTrue(observed)
        try router.runStorageMaintenance()
        XCTAssertFalse(exists(f.files[0]))
    }

    func testCanonicalSettingsAggregateSelectionGraceCancelAndUnarchiveKeepBytes() throws {
        let f = try fixture(count:3,size:10,threshold:100,budget:15),pid = f.project["id"]!,tid = f.task["id"]!
        let preview = try call("attachment_cleanup_preview",["project_id":pid,"task_id":tid])
        XCTAssertEqual((preview["attachment_ids"] as? [String])?.count,2);XCTAssertEqual(try ArchiveCleanupJob.integer(preview["clean_bytes"]),20)
        let job = try archive(f);try router.runStorageMaintenance()
        XCTAssertTrue(f.files.allSatisfy(exists));XCTAssertNotNil(try router.nextArchiveCleanupDeadline())
        let canceled = try call("cleanup_job_cancel",["project_id":pid,"cleanup_job_id":job["id"]!,"expected_revision":job["revision"]!])
        XCTAssertEqual(canceled["state"] as? String,"canceled")
        let task = try record(tid as! String,"task")
        _ = try call("task_archive",["project_id":pid,"task_id":tid,"expected_revision":task["revision"]!,"action":"unarchive","cleanup":false])
        XCTAssertTrue(f.files.allSatisfy(exists));XCTAssertFalse(bool(try record(tid as! String,"task"),"archived"))
    }
    func testUnreadableHistoricalAccountingCannotPreventProtectiveCancelOrClaimZero() throws {
        let f = try fixture(),job = try archive(f)
        try router.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:owned-invalid-accounting","{}"])
        }
        let canceled = try call("cleanup_job_cancel",["project_id":f.project["id"]!,"cleanup_job_id":job["id"]!,"expected_revision":job["revision"]!])
        XCTAssertEqual(canceled["state"] as? String,"canceled")
        XCTAssertTrue(canceled["known_backup_retained_logical_original_bytes"] is NSNull)
        XCTAssertEqual(canceled["backup_retention_observation"] as? String,"unavailable")
        XCTAssertTrue(f.files.allSatisfy(exists))
    }
    func testActualImagePreviewSurvivesOriginalCleanupAndRemainsReadableAsPreviewOnly() throws {
        let f = try fixture()
        let context = try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.6,blue:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:32,height:32))
        let bytes = NSMutableData(),image = try XCTUnwrap(context.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(encoder,image,nil);XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let source = directory.appendingPathComponent("owned-image.png");try (bytes as Data).write(to:source)
        let a = try call("attachment_add",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"path":source.path])
        let previewPath = try XCTUnwrap(a["preview_path"] as? String),previewBefore = try Data(contentsOf:URL(fileURLWithPath:previewPath))
        let job = try archive(f);try makeDue(job)
        // Exactly two selected originals, at most one actual unlink per pump.
        try router.runStorageMaintenance();try router.runStorageMaintenance()
        XCTAssertFalse(exists(a));XCTAssertEqual(try Data(contentsOf:source),bytes as Data)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:previewPath)),previewBefore)
        XCTAssertEqual(try record(a["id"] as! String,"attachment")["availability"] as? String,"original_cleaned")
        let preview = try call("attachment_read",["project_id":f.project["id"]!,"attachment_id":a["id"]!,"representation":"preview"])
        XCTAssertEqual(preview["url"] as? String,previewPath)
        XCTAssertThrowsError(try call("attachment_read",["project_id":f.project["id"]!,"attachment_id":a["id"]!,"representation":"original"]))
    }
    func testLateReaderHoldBlocksFinalDeleteAndReleaseResumesCurrentJob() throws {
        let f = try fixture(),job = try archive(f),a = f.files[0],pid = f.project["id"]!
        let read = try call("attachment_read",["project_id":pid,"attachment_id":a["id"]!,"representation":"original"])
        try makeDue(job);try router.runStorageMaintenance()
        XCTAssertTrue(exists(a));let held = try record(job["id"] as! String,"cleanup_job")
        XCTAssertTrue(((held["items"] as? [JSON])?.first?["holds"] as? [String] ?? []).contains("activeReader"))
        _ = try call("attachment_read_release",["project_id":pid,"read_hold_id":read["read_hold_id"]!])
        XCTAssertFalse(exists(a));XCTAssertEqual(try record(a["id"] as! String,"attachment")["availability"] as? String,"original_cleaned")
        XCTAssertThrowsError(try call("attachment_read",["project_id":pid,"attachment_id":a["id"]!,"representation":"original"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("source-0.bin").path))
    }
    func testSharedReferenceAndTransitiveActiveBuildStayHeldUntilBothConsumersEnd() throws {
        let f = try fixture(),a = f.files[0],job = try archive(f)
        let other = try call("project_create",["name":"Other scope","key_prefix":"OTH"]),t = try call("task_create",["project_id":other["id"]!,"title":"Consumer"])
        let shared = try call("attachment_add",["project_id":other["id"]!,"task_id":t["id"]!,"path":a["path"]!,"mode":"reference"])
        let manifestID = UUID().uuidString,executionID = UUID().uuidString
        try transaction {db in
            try router.save(db,["id":manifestID,"project_id":other["id"]!,"task_id":t["id"]!,"revision":1,"acceptance_revision":f.task["acceptance_revision"] ?? 1,"evidence":["artifact_refs":[["artifact_id":a["id"]!,"sha256":a["sha256"]!]]]],type:"manifest")
            try router.save(db,["id":executionID,"project_id":other["id"]!,"task_id":t["id"]!,"revision":1,"state":"running","manifest_id":manifestID],type:"source_execution")
        }
        try makeDue(job);try router.runStorageMaintenance();XCTAssertTrue(exists(a))
        _ = try call("attachment_update",["project_id":other["id"]!,"attachment_id":shared["id"]!,"expected_revision":shared["revision"]!,"action":"unlink"])
        XCTAssertTrue(exists(a));let held = try record(job["id"] as! String,"cleanup_job")
        XCTAssertTrue(((held["items"] as? [JSON])?.first?["holds"] as? [String] ?? []).contains("activeBuild"))
        try transaction {db in var execution = try router.record(db,executionID,type:"source_execution");execution["state"] = "completed";try router.save(db,router.revised(execution),type:"source_execution")}
        _ = try call("task_archive",["project_id":other["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","cleanup":false])
        XCTAssertFalse(exists(a))
    }
    func testHardlinkAndRealBackupSurviveWithNoInventedPhysicalReclaimCount() throws {
        let f = try fixture(),a = f.files[0],path = a["path"] as! String
        let retained = directory.appendingPathComponent("retained-hardlink.bin")
        XCTAssertEqual(link(path,retained.path),0)
        let backup = directory.appendingPathComponent("owned-backup")
        let receipt = try call("backup_create",["path":backup.path]);XCTAssertEqual(receipt["status"] as? String,"complete")
        let job = try archive(f);try makeDue(job);try router.runStorageMaintenance()
        XCTAssertFalse(exists(a));XCTAssertEqual(try Data(contentsOf:retained),Data(repeating:0,count:64))
        let relative = String(path.dropFirst(router.root.path.count + 1))
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("managed").appendingPathComponent(relative)),Data(repeating:0,count:64))
        let projection = try call("cleanup_job_get",["project_id":f.project["id"]!,"cleanup_job_id":job["id"]!])
        XCTAssertEqual(try ArchiveCleanupJob.integer(projection["removed_logical_original_bytes"]),64)
        XCTAssertEqual(try ArchiveCleanupJob.integer(projection["known_backup_retained_logical_original_bytes"]),64)
        XCTAssertEqual(projection["physical_reclamation"] as? String,"unmeasured");XCTAssertTrue(projection["backup_retained_physical_bytes"] is NSNull)
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("source-0.bin")),Data(repeating:0,count:64))
    }
    func testPostUnlinkSQLFailureReopensAndReconcilesMarkedIntentAsAlreadyAbsent() throws {
        let f = try fixture(),job = try archive(f),a = f.files[0];try makeDue(job)
        router.dbQueue.writeWithoutTransaction { db in
            XCTAssertEqual(sqlite3_set_authorizer(db.sqliteConnection,{_,action,table,_,_,_ in
                if action == SQLITE_INSERT,let table,String(cString:table) == "events" {return SQLITE_DENY};return SQLITE_OK
            },nil),SQLITE_OK)
        }
        try router.runStorageMaintenance();XCTAssertFalse(exists(a))
        XCTAssertEqual(try record(a["id"] as! String,"attachment")["availability"] as? String,"available")
        router.dbQueue.writeWithoutTransaction { _ = sqlite3_set_authorizer($0.sqliteConnection,nil,nil) }
        router = nil;router = try CommandRouter(root:directory.appendingPathComponent("store"))
        let recovered = try call("cleanup_job_get",["project_id":f.project["id"]!,"cleanup_job_id":job["id"]!])
        XCTAssertEqual(recovered["state"] as? String,"completed")
        XCTAssertEqual(try ArchiveCleanupJob.integer(recovered["already_missing_logical_original_bytes"]),64)
        XCTAssertEqual(try ArchiveCleanupJob.integer(recovered["removed_logical_original_bytes"]),0)
        XCTAssertEqual(try record(a["id"] as! String,"attachment")["availability"] as? String,"original_missing")
        let backup = directory.appendingPathComponent("missing-original-backup")
        let receipt = try call("backup_create",["path":backup.path])
        XCTAssertEqual(receipt["status"] as? String,"complete")
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:backup.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.unavailable.contains { $0.authority == "attachment:" + (a["id"] as! String) && $0.reason == "original_missing" })
        let originalRelative = String((a["path"] as! String).dropFirst(router.root.path.count + 1))
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.relativePath == originalRelative})
    }
    func testPermanentLateHoldsExhaustBoundedCursorAndDoNotPollForever() throws {
        let f = try fixture(count:9),job = try archive(f)
        for a in f.files { _ = try call("attachment_update",["project_id":f.project["id"]!,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":"keep_original"]) }
        try makeDue(job);try router.runStorageMaintenance()
        let first = try ArchiveCleanupJob(record:record(job["id"] as! String,"cleanup_job"))
        XCTAssertEqual(first.state,.held);XCTAssertEqual(first.items.filter {$0.state == .waiting}.count,1)
        XCTAssertEqual(first.items.filter {$0.state == .held}.count,8)
        XCTAssertEqual(router.storageMaintenanceFallbackFailures,0)
        XCTAssertNotNil(try router.nextArchiveCleanupDeadline())
        try router.runStorageMaintenance()
        let final = try ArchiveCleanupJob(record:record(job["id"] as! String,"cleanup_job"))
        XCTAssertEqual(final.state,.held);XCTAssertTrue(final.items.allSatisfy {$0.state == .held && $0.holds.contains(.keepOriginal)})
        XCTAssertEqual(router.storageMaintenanceFallbackFailures,0)
        XCTAssertNil(try router.nextArchiveCleanupDeadline());XCTAssertTrue(f.files.allSatisfy(exists))
    }
    func testChangedBytesSuspendAfterTwoSameFailuresAndExplicitRetryAddsUndoWindow() throws {
        let f = try fixture(),job = try archive(f),a = f.files[0]
        try Data(repeating:1,count:64).write(to:URL(fileURLWithPath:a["path"] as! String))
        try makeDue(job);try router.runStorageMaintenance();try router.runStorageMaintenance()
        let suspended = try record(job["id"] as! String,"cleanup_job");XCTAssertEqual(suspended["state"] as? String,"suspended");XCTAssertTrue(exists(a))
        let retried = try call("cleanup_job_retry",["project_id":f.project["id"]!,"cleanup_job_id":job["id"]!,"expected_revision":suspended["revision"]!])
        XCTAssertEqual(retried["state"] as? String,"queued");XCTAssertGreaterThan(try ArchiveCleanupJob.integer(retried["not_before_ms"]),router.archiveCleanupNowMS())
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:a["path"] as! String)),Data(repeating:1,count:64))
    }
    func testLateHumanReviewBackupAndReceiptlessImportReferencesRetainQueuedOriginal() throws {
        let f = try fixture(),a = f.files[0],job = try archive(f)
        let requestID = UUID().uuidString,manifestID = UUID().uuidString,reviewID = UUID().uuidString,holdID = UUID().uuidString
        let originalImport = try record(a["storage_job_id"] as! String,"storage_job")
        // Owned record fixtures exercise real graph families, not a claimed
        // native owner answer, launched build or independent review receipt.
        try transaction { db in
            try router.save(db,["id":requestID,"project_id":f.project["id"]!,"task_id":f.task["id"]!,"revision":1,"state":"pending","target_attachment_id":a["id"]!],type:"request")
            try router.save(db,["id":manifestID,"project_id":f.project["id"]!,"task_id":f.task["id"]!,"revision":1,"acceptance_revision":f.task["acceptance_revision"] ?? 1,"evidence":["artifact_refs":[["artifact_id":a["id"]!,"sha256":a["sha256"]!]]]],type:"manifest")
            try router.save(db,["id":reviewID,"project_id":f.project["id"]!,"task_id":f.task["id"]!,"revision":1,"state":"queued","manifest_id":manifestID],type:"review_request")
            try router.save(db,["id":holdID,"revision":1,"kind":"backup","state":"active","attachment_ids":[a["id"]!]],type:"storage_hold")
            var pending = originalImport;pending["parent_command_id"] = UUID().uuidString
            try router.save(db,router.revised(pending),type:"storage_job")
        }
        try makeDue(job);try router.runStorageMaintenance()
        XCTAssertTrue(exists(a))
        let held = try record(job["id"] as! String,"cleanup_job")
        let reasons = Set((held["items"] as? [JSON])?.first?["holds"] as? [String] ?? [])
        XCTAssertTrue(reasons.isSuperset(of:["pendingHumanInspection","currentReview","backupCapture","pendingImport"]))
        try transaction { db in
            for (id,type,state) in [(requestID,"request","answered"),(reviewID,"review_request","pass"),(holdID,"storage_hold","released")] {
                var value = try router.record(db,id,type:type);value["state"] = state;try router.save(db,router.revised(value),type:type)
            }
            var committed = originalImport;committed["revision"] = try ArchiveCleanupJob.integer(router.record(db,originalImport["id"] as! String,type:"storage_job")["revision"]) + 1
            try router.save(db,committed,type:"storage_job")
        }
        try router.runStorageMaintenance();XCTAssertFalse(exists(a))
        // Exact-original verification rejects the retained metadata/preview.
        XCTAssertThrowsError(try router.dbQueue.read { db in
            var task = try router.record(db,f.task["id"] as! String,type:"task");task["current_manifest_id"] = manifestID
            return try router.validateManifestTarget(db,task:task,manifestID:manifestID)
        }) { error in
            XCTAssertEqual((error as? CoreError)?.code,"EVIDENCE_STALE")
            XCTAssertTrue((error as? CoreError)?.message.contains("original is missing, cleaned or changed") == true)
        }
    }
}
