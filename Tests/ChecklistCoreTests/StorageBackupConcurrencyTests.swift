import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

final class StorageBackupConcurrencyTests: XCTestCase {
    func testInventoryRunsAfterWriterAndObjectGateReleaseWithRetentionStillActive() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),router = f.router!
        let source = f.workspace.appendingPathComponent("inventory.bin"),bytes = Data(repeating:9,count:4096)
        try bytes.write(to:source)
        let original = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        let destination = f.base.appendingPathComponent("inventory-backup")
        var budget = StorageSnapshotBudget.production(),events: [String] = []
        budget.observe = {event in
            events.append(event)
            guard event == "inventory_started" else {return}
            XCTAssertTrue(events.contains("writer_lease_released"))
            XCTAssertTrue(events.contains("capture_released"))
            XCTAssertTrue(try StorageSnapshotRetention.isActive(root:f.root))
            let started = ProcessInfo.processInfo.systemUptime
            _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Written before inventory","kind":"note"])
            _ = try f.call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"title":"Edited before inventory"])
            _ = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])
            print("CL320 inventory-boundary writes_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
            try ArchiveStorageGate.withExclusive(root:f.root) {_ in
                XCTAssertThrowsError(try StorageSnapshotRetention.requireNoCapture(root:f.root)) {
                    XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")
                }
            }
        }
        _ = try router.executeStorageBackup(params:["command_id":UUID().uuidString,"path":destination.path],caller:f.owner,budget:budget)
        XCTAssertTrue(events.contains("inventory_finished"))
        XCTAssertGreaterThan(budget.measurement.writerLeaseSeconds,0)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (original["id"] as! String) + ":original")})
        XCTAssertEqual(manifest.objects.filter {$0.descriptor.authorities.contains {$0.hasPrefix("attachment:") && $0.hasSuffix(":original")}}.count,1)
        var configuration = Configuration();configuration.readonly = true;configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:configuration)
        defer {try? copy.close()}
        try copy.read {db in
            XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            XCTAssertEqual(try router.record(db,t["id"] as! String,type:"task")["title"] as? String,"Storage invariant")
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND json_extract(data,'$.body')='Written before inventory'"),0)
        }
        _ = try StorageSnapshot.reconcile(parent:f.base,operation:UUID(uuidString:manifest.operationID)!,publicationName:destination.lastPathComponent,budget:.production())
        print("CL320 template writer_lease_seconds=\(budget.measurement.writerLeaseSeconds)")
    }

    func testNotesEditsAndNewImportsFinishWhileCopyAndVerificationArePaused() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),router = f.router!
        let source = f.workspace.appendingPathComponent("original.bin")
        try Data(repeating:7,count:128 * 1024).write(to:source)
        let a = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        let destination = f.base.appendingPathComponent("concurrent-backup"),command = UUID().uuidString
        let copying = DispatchSemaphore(value:0),verifying = DispatchSemaphore(value:0),resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"backup finishes")
        XCTAssertTrue(CommandRouter.runsOutsideSerialQueue("backup_create"))
        let owner = f.owner
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            var budget = StorageSnapshotBudget.production()
            budget.observe = { event in
                if event == "copying_objects" || event == "manifest_written" {
                    (event == "copying_objects" ? copying : verifying).signal()
                    guard resume.wait(timeout:.now()+15) == .success else {throw StorageSnapshotFailure.canceled}
                }
            }
            do {
                let reply = try router.executeStorageBackup(params:["command_id":command,"path":destination.path],caller:owner,budget:budget)
                XCTAssertEqual((reply["data"] as? JSON)?["status"] as? String,"complete")
            } catch {XCTFail("Backup: \(error)")}
        }
        defer {resume.signal();resume.signal()}
        XCTAssertEqual(copying.wait(timeout:.now()+15),.success)
        let started = ProcessInfo.processInfo.systemUptime
        _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Written during managed copy","kind":"note"])
        _ = try f.call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"title":"Edited during managed copy"])
        let added = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        let copyWriteSeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(copyWriteSeconds,2,"Writes waited for the paused backup")
        XCTAssertThrowsError(try f.call("backup_create",["path":f.base.appendingPathComponent("second").path])) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_IN_PROGRESS")
        }
        resume.signal()
        XCTAssertEqual(verifying.wait(timeout:.now()+15),.success)
        let verifyingStarted = ProcessInfo.processInfo.systemUptime
        _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Written during verification","kind":"note"])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - verifyingStarted,2)
        resume.signal()
        wait(for:[finished],timeout:30)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":original")})
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (added["id"] as! String) + ":original")})
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copied = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:config)
        defer {try? copied.close()}
        try copied.read { db in
            XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            XCTAssertEqual(try router.record(db,t["id"] as! String,type:"task")["title"] as? String,"Storage invariant")
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM records WHERE type='message' AND json_extract(data,'$.body') LIKE 'Written during%'"),0)
        }
        _ = try StorageSnapshot.reconcile(parent:f.base,operation:UUID(uuidString:manifest.operationID)!,publicationName:destination.lastPathComponent,budget:.production())
        print("CL172 concurrent note/edit/import seconds=\(copyWriteSeconds)")
    }

    func testPendingImportStageSurvivesCommitAndCleanupDuringBackup() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),router = f.router!
        let source = f.workspace.appendingPathComponent("pending.bin"),bytes = Data(repeating:3,count:32768)
        try bytes.write(to:source)
        let command = UUID().uuidString,input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"command_id":command]
        let prepared = try XCTUnwrap(router.prepareManagedAttachmentImport(method:"attachment_add",params:input,caller:f.owner,access:router.managedImportAccessOutsideWriter()))
        let objects = try router.managedImportObjects(prepared.job),stage = try XCTUnwrap(objects.first?["stage"] as? String)
        let destination = f.base.appendingPathComponent("pending-import-backup")
        var budget = StorageSnapshotBudget.production(),observed = false
        budget.observe = {event in
            guard event == "copying_objects" else {return};observed = true
            let result = try f.call("attachment_add",input,command:command)["data"] as! JSON
            XCTAssertEqual(result["availability"] as? String,"available")
            let warning = (result["_checklist"] as? JSON)?["storage_maintenance"] as? JSON
            XCTAssertEqual(warning?["reason"] as? String,"backup_capture")
            for _ in 0..<3 {try router.runStorageMaintenance()}
            XCTAssertTrue(try StorageObjectFiles(root:f.root).regularOrLinkExists(stage))
            try ArchiveStorageGate.withExclusive(root:f.root) { _ in
                try router.dbQueue.writeWithoutTransaction {db in
                    XCTAssertThrowsError(try router.removeManagedImportStage(db,files:StorageObjectFiles(root:f.root),path:stage)) {
                        XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")
                    }
                }
            }
        }
        _ = try router.executeStorageBackup(params:["command_id":UUID().uuidString,"path":destination.path],caller:f.owner,budget:budget)
        XCTAssertTrue(observed)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.relativePath == stage})
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("managed/" + stage)),bytes)
        try router.runStorageMaintenance()
        XCTAssertFalse(try StorageObjectFiles(root:f.root).regularOrLinkExists(stage))
        XCTAssertEqual(try router.dbQueue.read {try router.record($0,prepared.job["id"] as! String,type:"storage_job")["state"] as? String},"settled")
        _ = try StorageSnapshot.reconcile(parent:f.base,operation:UUID(uuidString:manifest.operationID)!,publicationName:destination.lastPathComponent,budget:.production())
    }

    func testCanceledCopyRetainsEarlierBackupAndRetriesOriginalStage() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let source = f.workspace.appendingPathComponent("retained.bin"),bytes = Data(repeating:4,count:8192)
        try bytes.write(to:source)
        let attachment = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        let earlier = f.base.appendingPathComponent("earlier")
        _ = try f.call("backup_create",["path":earlier.path])
        let earlierBytes = try Data(contentsOf:earlier.appendingPathComponent("manifest.json"))
        let destination = f.base.appendingPathComponent("canceled"),command = UUID().uuidString
        var budget = StorageSnapshotBudget.production()
        budget.observe = {event in if event == "copying_objects" {throw StorageSnapshotFailure.canceled}}
        XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":command,"path":destination.path],caller:f.owner,budget:budget)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CANCELED")
        }
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try Data(contentsOf:earlier.appendingPathComponent("manifest.json")),earlierBytes)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:attachment["path"] as! String)),bytes)
        let stages = try FileManager.default.contentsOfDirectory(atPath:f.base.path).filter {$0.hasPrefix(".snapshot-staging-")}
        XCTAssertEqual(stages.count,1)
        let stage = f.base.appendingPathComponent(stages[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.appendingPathComponent("database.sqlite").path))
        try f.close();try f.reopen()
        XCTAssertEqual((try f.call("backup_create",["path":destination.path],command:command)["data"] as? JSON)?["status"] as? String,"complete")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.base.path).filter {$0.hasPrefix(".snapshot-incomplete-")}.count,1)
        XCTAssertEqual(try Data(contentsOf:earlier.appendingPathComponent("manifest.json")),earlierBytes)
        XCTAssertEqual(try f.call("backup_create",["path":destination.path],command:command)["replayed"] as? Bool,true)
    }

    func testCaptureAdmissionWaitsForAnAlreadyAdmittedObjectOperation() throws {
        let f = try StorageFixture(),attempted = DispatchSemaphore(value:0),captured = DispatchSemaphore(value:0)
        let finished = expectation(description:"capture admission finishes")
        let root = f.root // Fixture teardown follows the worker join.
        try ArchiveStorageGate.withExclusive(root:root) { _ in
            DispatchQueue.global().async {
                defer {finished.fulfill()}
                attempted.signal()
                do {_ = try StorageSnapshotRetention.withCapture(root:root) {_ in captured.signal()}}
                catch {XCTFail("Capture admission: \(error)")}
            }
            XCTAssertEqual(attempted.wait(timeout:.now()+5),.success)
            XCTAssertEqual(captured.wait(timeout:.now()+0.05),.timedOut)
            XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
            XCTAssertNoThrow(try StorageSnapshotRetention.requireNoCapture(root:f.root))
        }
        XCTAssertEqual(captured.wait(timeout:.now()+5),.success)
        wait(for:[finished],timeout:5)
    }

    func testKilledCaptureReleasesKernelRetentionWithoutTouchingStaging() throws {
        let f = try StorageFixture()
        let stage = f.root.appendingPathComponent("staging/retained-recovery")
        try FileManager.default.createDirectory(at:stage.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("unchanged recovery".utf8).write(to:stage)
        let child = try f.spawn("backup-retention-held")
        defer {if child.isRunning {_ = kill(child.processIdentifier,SIGKILL)}}
        let until = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath:f.base.appendingPathComponent("ready").path),child.isRunning,ProcessInfo.processInfo.systemUptime < until {usleep(10_000)}
        XCTAssertTrue(try StorageSnapshotRetention.isActive(root:f.root))
        XCTAssertEqual(kill(child.processIdentifier,SIGKILL),0)
        try f.finish(child)
        XCTAssertEqual(child.terminationStatus,SIGKILL)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        XCTAssertEqual(try Data(contentsOf:stage),Data("unchanged recovery".utf8))
    }

    func testRetentionLockRejectsUnsafeSubstitutionAndExpiredLease() throws {
        let f = try StorageFixture(),other = try StorageFixture()
        var expired: StorageSnapshotRetention?
        try StorageSnapshotRetention.withCapture(root:f.root) {hold in
            expired = hold
            XCTAssertThrowsError(try hold.requireRoot(other.root))
            XCTAssertTrue(try StorageSnapshotRetention.isActive(root:f.root))
            XCTAssertThrowsError(try StorageSnapshotRetention.requireNoCapture(root:f.root)) {
                XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")
            }
        }
        XCTAssertThrowsError(try expired?.requireRoot(f.root))
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        let lock = f.root.appendingPathComponent(".snapshot-retention.lock"),outside = f.base.appendingPathComponent("outside")
        try FileManager.default.moveItem(at:lock,to:outside)
        try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:outside)
        XCTAssertThrowsError(try StorageSnapshotRetention.withCapture(root:f.root) {_ in XCTFail("Unsafe lock accepted")})
        XCTAssertThrowsError(try StorageSnapshotRetention.requireNoCapture(root:f.root))
    }
}
