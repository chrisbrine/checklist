import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

final class StorageAutomaticBackupRetentionTests: XCTestCase {
    private func fixture() throws -> StorageFixture {
        let f = try StorageFixture(open:false);try reopen(f);return f
    }
    private func reopen(_ f: StorageFixture) throws {
        try f.close()
        let lease = try StorageServiceLease(root:f.root)
        let router = try CommandRouter(root:f.root,serviceLease:lease,automaticBackupRetentionTrashRoot:f.workspace)
        f.lease = lease;f.router = router
    }
    private func invoke(_ f: StorageFixture,_ method: String,_ params: JSON = [:],command: String = UUID().uuidString.lowercased()) throws -> JSON {
        var input = params
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = command}
        return try f.router!.executeStorageBackupPruning(method:method,params:input,caller:f.owner,trashRoot:f.workspace)
    }
    private func snapshot(_ f: StorageFixture,_ name: String) throws -> JSON {
        let destination = f.root.appendingPathComponent("backups/snapshot-" + name)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        return try f.call("backup_create",["path":destination.path])["data"] as! JSON
    }
    private func age(_ f: StorageFixture,_ snapshot: JSON,_ date: String = "2000-01-01T00:00:00Z") throws {
        try f.router!.dbQueue.write {db in
            let key = "backup-generation:" + (snapshot["operation_id"] as! String)
            var receipt = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])))
            var summary = receipt["summary"] as! JSON;summary["captured_at"] = date;receipt["summary"] = summary
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(receipt),key])
        }
    }
    private func configure(_ f: StorageFixture,_ newest: Int = 1,_ days: Int = 0) throws -> JSON {
        try invoke(f,"backup_retention_set",["newest_count":newest,"daily_days":days])["data"] as! JSON
    }
    private func exists(_ snapshot: JSON) -> Bool {FileManager.default.fileExists(atPath:snapshot["path"] as! String)}
    private func last(_ f: StorageFixture) throws -> JSON {
        let settings = try invoke(f,"backup_retention_get")["data"] as! JSON
        return settings["last_automatic_prune"] as? JSON ?? [:]
    }
    func testUnconfirmedAndLegacyManualRulesNeverRemoveSnapshots() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        _ = try snapshot(f,"new")
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:old["operation_id"] as? String)["status"] as? String,"unconfirmed")
        XCTAssertTrue(exists(old))
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-retention-settings',?)",arguments:[try jsonString(["newest_count":1,"daily_days":0,"owner_confirmed":true,"automatic_prune":false,"pins":[] as [JSON]])])
        }
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:old["operation_id"] as? String)["status"] as? String,"unconfirmed")
        XCTAssertTrue(exists(old));XCTAssertTrue(try last(f).isEmpty)
    }
    func testTrustedConfirmationIsBoundConfigurableAndSaveMovesNothing() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        _ = try snapshot(f,"new")
        let settings = try configure(f,3,3),confirmation = try XCTUnwrap(settings["owner_confirmation"] as? JSON)
        XCTAssertEqual(settings["newest_count"] as? Int,3);XCTAssertEqual(settings["daily_days"] as? Int,3)
        XCTAssertEqual(settings["automatic_prune"] as? Bool,true);XCTAssertTrue(exists(old))
        XCTAssertEqual(confirmation["principal"] as? String,f.owner.principal)
        XCTAssertEqual(confirmation["source"] as? String,"authenticated_app")
        XCTAssertEqual(confirmation["source_root"] as? String,f.root.path)
        XCTAssertEqual(confirmation["incarnation"] as? String,f.router!.incarnation)
        XCTAssertTrue(try StorageAutomaticBackupRetention.isConfirmed(settings,root:f.root,incarnation:f.router!.incarnation))
        XCTAssertFalse(try StorageAutomaticBackupRetention.isConfirmed(settings,root:f.workspace,incarnation:f.router!.incarnation))
        XCTAssertFalse(try StorageAutomaticBackupRetention.isConfirmed(settings,root:f.root,incarnation:"restored-generation"))
        let worker = Caller(role:"worker",installation:"untrusted",projectIDs:[])
        XCTAssertThrowsError(try f.router!.handle(method:"backup_retention_set",params:["command_id":UUID().uuidString,"newest_count":1,"daily_days":0,"owner_confirmed":true],caller:worker))
    }
    func testCompletedBackupAutomaticallyPrunesWithHistoryAndStableReplay() throws {
        let f = try fixture(),project = try f.project(),old = try snapshot(f,"old");try age(f,old)
        _ = try configure(f)
        let latest = try snapshot(f,"new"),result = try last(f)
        XCTAssertEqual(latest["status"] as? String,"complete");XCTAssertTrue(exists(latest));XCTAssertFalse(exists(old))
        XCTAssertEqual(result["status"] as? String,"complete");XCTAssertEqual(result["moved_count"] as? Int,1)
        XCTAssertEqual(result["origin"] as? String,"automatic_backup_retention")
        XCTAssertEqual(result["trigger_operation_id"] as? String,latest["operation_id"] as? String)
        let entry = try XCTUnwrap((result["moved_to_trash"] as? [JSON])?.first)
        XCTAssertTrue((entry["trash_path"] as? String)?.hasPrefix(f.workspace.path + "/") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:entry["trash_path"] as! String))
        let settings = try invoke(f,"backup_retention_get")["data"] as! JSON
        XCTAssertEqual((settings["automatic_prune_history"] as? [JSON])?.count,1)
        try f.router!.dbQueue.read {db in
            let history = try Row.fetchAll(db,sql:"SELECT actor,data FROM events WHERE kind='backup_pruned'")
            XCTAssertEqual(history.count,1);XCTAssertEqual(history.first?["actor"] as String?,CommandRouter.automaticBackupRetentionCaller.principal)
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-generation:" + (old["operation_id"] as! String)]))
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["storage-copy-usage:backup:" + (old["operation_id"] as! String)]))
        }
        let replay = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual(try last(f)["command_id"] as? String,result["command_id"] as? String)
        // Installation-wide retention history remains owner-only; project backup
        // history retains its existing captured-project visibility boundary.
        let backupHistory = try f.call("history_list",["project_id":project["id"]!,"entity":"backup"])["data"] as! JSON
        XCTAssertTrue((backupHistory["events"] as! [JSON]).allSatisfy {$0["kind"] as? String == "backup_created"})
    }
    func testAutomaticPruneKeepsPinsUpgradeInUseAndIncompleteSnapshots() throws {
        let f = try fixture(),pinned = try snapshot(f,"pinned"),protected = try snapshot(f,"protected"),used = try snapshot(f,"used"),removable = try snapshot(f,"removable")
        for entry in [pinned,protected,used,removable] {try age(f,entry)}
        _ = try invoke(f,"backup_pin",["path":pinned["path"]!,"pinned":true])
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":protected["path"]!,"protected":true])])
        }
        let incomplete = f.root.appendingPathComponent("backups/.snapshot-failed-fixture")
        try FileManager.default.createDirectory(at:incomplete,withIntermediateDirectories:true)
        try Data("incomplete".utf8).write(to:incomplete.appendingPathComponent("manifest.json"))
        var lease: StorageBackupUseLease? = try StorageBackupUseLease(root:URL(fileURLWithPath:used["path"] as! String))
        _ = try configure(f);_ = try snapshot(f,"latest")
        XCTAssertTrue(exists(pinned));XCTAssertTrue(exists(protected));XCTAssertTrue(exists(used));XCTAssertFalse(exists(removable))
        XCTAssertTrue(FileManager.default.fileExists(atPath:incomplete.path))
        XCTAssertEqual((try last(f)["retained_in_use"] as? [JSON])?.count,1)
        withExtendedLifetime(lease) {};lease = nil
        _ = try snapshot(f,"later")
        XCTAssertFalse(exists(used));XCTAssertTrue(exists(pinned));XCTAssertTrue(exists(protected))
    }
    func testInterruptedAutomaticIntentRechecksPinThenReconcilesOriginalUUID() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest");_ = try configure(f)
        let deferred = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String,observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}})
        XCTAssertEqual(deferred["status"] as? String,"deferred");XCTAssertTrue(exists(old))
        let command = StorageAutomaticBackupRetention.command(root:f.root,incarnation:f.router!.incarnation,trigger:latest["operation_id"] as! String)
        _ = try invoke(f,"backup_pin",["path":old["path"]!,"pinned":true])
        try reopen(f)
        let result = f.router!.applyAutomaticBackupRetention()
        XCTAssertTrue(["complete","idle"].contains(result["status"] as? String ?? ""));XCTAssertTrue(exists(old))
        try f.router!.dbQueue.read {db in
            XCTAssertNotNil(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[CommandRouter.automaticBackupRetentionCaller.principal,command]))
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-pending'"))
        }
        XCTAssertEqual(try last(f)["command_id"] as? String,command)
    }
    func testInterruptedAutomaticMoveReconcilesWithoutSecondTrashMove() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest");_ = try configure(f)
        let deferred = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}})
        XCTAssertEqual(deferred["status"] as? String,"deferred");XCTAssertFalse(exists(old))
        let firstTrash = try FileManager.default.contentsOfDirectory(atPath:f.workspace.path).sorted()
        try reopen(f)
        _ = f.router!.applyAutomaticBackupRetention()
        XCTAssertEqual(try last(f)["moved_count"] as? Int,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.workspace.path).sorted(),firstTrash)
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String)["replayed"] as? Bool,true)
    }
    func testCopiedOrMalformedConfirmationNeverAuthorizesAutomaticPrune() throws {
        for malformed in [false,true] {
            let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
            let latest = try snapshot(f,"latest");var settings = try configure(f)
            var receipt = settings["owner_confirmation"] as! JSON
            if malformed {receipt.removeValue(forKey:"command_id")} else {receipt["source_root"] = f.workspace.path}
            settings["owner_confirmation"] = receipt
            try f.router!.dbQueue.write {db in
                try db.execute(sql:"UPDATE metadata SET value=? WHERE key='backup-retention-settings'",arguments:[try jsonString(settings)])
                try CommandRouter.enqueueAutomaticBackupRetention(db,root:f.root,incarnation:f.router!.incarnation,operation:latest["operation_id"] as! String)
                XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))
            }
            let result = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String)
            XCTAssertEqual(result["status"] as? String,malformed ? "deferred" : "unconfirmed");XCTAssertTrue(exists(old))
        }
    }
    func testAutomaticRetentionHistoryIsBoundedAndNewestFirst() throws {
        let f = try fixture()
        try f.router!.dbQueue.write {db in
            for index in 0..<25 {
                try f.router!.event(db,caller:CommandRouter.automaticBackupRetentionCaller,project:nil,entity:nil,kind:"backup_pruned",data:["status":"complete","origin":"automatic_backup_retention","moved_count":index])
            }
        }
        let settings = try invoke(f,"backup_retention_get")["data"] as! JSON,history = try XCTUnwrap(settings["automatic_prune_history"] as? [JSON])
        XCTAssertEqual(history.count,20);XCTAssertEqual(history.first?["moved_count"] as? Int,24);XCTAssertEqual(history.last?["moved_count"] as? Int,5)
    }
    func testNewTrustedConfirmationFencesForeignPendingWithoutCompletingItsJournal() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest"),trigger = latest["operation_id"] as! String
        let foreignRoot = f.workspace.appendingPathComponent("foreign-store"),foreignIncarnation = UUID().uuidString.lowercased()
        let command = StorageAutomaticBackupRetention.command(root:foreignRoot,incarnation:foreignIncarnation,trigger:trigger)
        let params: JSON = ["command_id":command,"preview_sha256":String(repeating:"a",count:64),"include_unrecorded":false]
        let pending: JSON = ["source_root":foreignRoot.path,"incarnation":foreignIncarnation,"trigger_operation_id":trigger,"params":params,"created_at":now()]
        let raw = try jsonString(pending),journalKey = "backup-prune-intent:" + ChecklistCore.hash(Data((CommandRouter.automaticBackupRetentionCaller.principal + command).utf8))
        let journal = try jsonString(["digest":"preserve-unknown-intent","entries":[] as [JSON]])
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-automatic-prune-pending',?)",arguments:[raw])
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:[journalKey,journal])
        }
        _ = try configure(f)
        XCTAssertTrue(exists(old))
        try f.router!.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-pending'"))
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[journalKey]),journal)
            let saved = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-automatic-prune-fenced:" + ChecklistCore.hash(Data(("backup-automatic-prune-pending\n" + raw).utf8))])))
            XCTAssertEqual(saved["reason"] as? String,"installation_binding_changed")
            XCTAssertEqual(try jsonString(saved["original_intent"] as! JSON),raw)
        }
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:trigger)["status"] as? String,"complete")
        XCTAssertFalse(exists(old))
    }

    func testDurablyDueBackupPrunesOnRestartWithOwnedTrashDestination() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest"),trigger = latest["operation_id"] as! String
        // No owner rule means the exact transaction hook queues no authority.
        try f.router!.dbQueue.write {db in
            try CommandRouter.enqueueAutomaticBackupRetention(db,root:f.root,incarnation:f.router!.incarnation,operation:trigger)
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))
        }
        _ = try configure(f)
        try f.router!.dbQueue.write {db in
            try CommandRouter.enqueueAutomaticBackupRetention(db,root:f.root,incarnation:f.router!.incarnation,operation:trigger)
            XCTAssertNotNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))
        }
        // Simulates termination after receipt/due commit and before post-commit
        // apply: the constructor receives owned Trash before startup recovery.
        try reopen(f)
        XCTAssertFalse(exists(old));XCTAssertTrue(exists(latest))
        let result = try last(f)
        XCTAssertEqual(result["trigger_operation_id"] as? String,trigger)
        XCTAssertEqual(result["moved_count"] as? Int,1)
        let moved = try XCTUnwrap((result["moved_to_trash"] as? [JSON])?.first)
        XCTAssertTrue((moved["trash_path"] as? String)?.hasPrefix(f.workspace.path + "/") == true)
        try f.router!.dbQueue.read {db in XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))}
    }
    /// macOS privacy refuses open(2) and listing of the real ~/.Trash for a process
    /// with no grant, while it allows a path-based mkdir, rename and child open.
    /// Mode 0300 gives the same refusal on a fixture, so any open of the root fails.
    private func refusingTrash(_ f: StorageFixture) throws -> URL {
        let trash = f.workspace.appendingPathComponent("Refusing Trash",isDirectory:true)
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        XCTAssertEqual(chmod(trash.path,0o300),0)
        addTeardownBlock {_ = chmod(trash.path,0o700)}
        XCTAssertEqual(Darwin.open(trash.path,O_RDONLY | O_DIRECTORY),-1,"The fixture must refuse open as the real Trash does.")
        f.router!.automaticBackupRetentionTrashRoot = trash
        return trash
    }
    func testPruneReachesATrashWhoseRootRefusesOpen() throws {
        let f = try fixture(),trash = try refusingTrash(f),old = try snapshot(f,"old");try age(f,old)
        _ = try configure(f)
        let latest = try snapshot(f,"latest"),result = try last(f)
        XCTAssertEqual(result["status"] as? String,"complete",String(describing:result))
        XCTAssertEqual(result["moved_count"] as? Int,1);XCTAssertTrue(exists(latest));XCTAssertFalse(exists(old))
        let moved = try XCTUnwrap((result["moved_to_trash"] as? [JSON])?.first?["trash_path"] as? String)
        XCTAssertTrue(moved.hasPrefix(trash.path + "/Checklist-backups-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:moved + "/manifest.json"),"The snapshot stays whole in the Trash.")
        let owner = URL(fileURLWithPath:moved).deletingLastPathComponent().appendingPathComponent("prune-owner.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath:owner))
    }
    func testInterruptedMoveReconcilesExactInodeWhenTrashRootRefusesOpen() throws {
        let f = try fixture(),trash = try refusingTrash(f),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest");_ = try configure(f)
        let deferred = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}})
        XCTAssertEqual(deferred["status"] as? String,"deferred");XCTAssertFalse(exists(old))
        try reopen(f);f.router!.automaticBackupRetentionTrashRoot = trash
        _ = f.router!.applyAutomaticBackupRetention()
        XCTAssertEqual(try last(f)["status"] as? String,"complete");XCTAssertEqual(try last(f)["moved_count"] as? Int,1)
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String)["replayed"] as? Bool,true)
    }
    func testReconciliationRefusesAReplacedSnapshotInTrash() throws {
        let f = try fixture(),trash = try refusingTrash(f),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest");_ = try configure(f)
        _ = f.router!.applyAutomaticBackupRetention(after:latest["operation_id"] as? String,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}})
        let raw = try f.router!.dbQueue.read {try XCTUnwrap(String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key GLOB 'backup-prune-intent:*'"))}
        let moved = try XCTUnwrap((jsonObject(raw)["entries"] as? [JSON])?.first?["trash_path"] as? String)
        let aside = moved + "-aside"
        XCTAssertEqual(rename(moved,aside),0)
        try FileManager.default.createDirectory(atPath:moved,withIntermediateDirectories:false)
        try Data("{}".utf8).write(to:URL(fileURLWithPath:moved + "/manifest.json"))
        try reopen(f);f.router!.automaticBackupRetentionTrashRoot = trash
        let result = f.router!.applyAutomaticBackupRetention()
        XCTAssertEqual(result["status"] as? String,"deferred",String(describing:result))
        XCTAssertEqual(result["underlying_error"] as? String,"BACKUP_PRUNE_SOURCE_CHANGED")
    }
    /// Proof run only, with CHECKLIST_P360D_REAL_TRASH=1: production Trash lookup and
    /// a fixture store, so only this fixture's small snapshots reach the real Trash.
    func testRealTrashProofRunOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHECKLIST_P360D_REAL_TRASH"] == "1","Proof run only.")
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        f.router!.automaticBackupRetentionTrashRoot = nil
        let trash = try FileManager.default.url(for:.trashDirectory,in:.userDomainMask,appropriateFor:f.root,create:true)
        let probe = Darwin.open(trash.path,O_RDONLY | O_DIRECTORY);let refusal = errno
        if probe >= 0 {Darwin.close(probe)}
        print("P360D trash_root=\(trash.path) open_fd=\(probe) errno=\(refusal)")
        _ = try configure(f)
        _ = try snapshot(f,"new")
        let result = try last(f)
        print("P360D result=\(try jsonString(result))")
        XCTAssertEqual(result["status"] as? String,"complete");XCTAssertFalse(exists(old))
        let moved = try XCTUnwrap((result["moved_to_trash"] as? [JSON])?.first?["trash_path"] as? String)
        XCTAssertTrue(moved.hasPrefix(trash.path + "/Checklist-backups-"));XCTAssertTrue(FileManager.default.fileExists(atPath:moved + "/manifest.json"))
    }
    func testDeferredAutomaticPruneKeepsDurableDueUntilRecoveryCompletes() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest"),trigger = latest["operation_id"] as! String
        _ = try configure(f)
        try f.router!.dbQueue.write {db in try CommandRouter.enqueueAutomaticBackupRetention(db,root:f.root,incarnation:f.router!.incarnation,operation:trigger)}
        let result = f.router!.applyAutomaticBackupRetention(observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}})
        XCTAssertEqual(result["status"] as? String,"deferred");XCTAssertTrue(exists(old))
        try f.router!.dbQueue.read {db in XCTAssertNotNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))}
        try reopen(f)
        XCTAssertFalse(exists(old))
        try f.router!.dbQueue.read {db in XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))}
    }

    func testCompletingOlderTriggerCannotConsumeNewerDurableDueTrigger() throws {
        let f = try fixture(),old = try snapshot(f,"old");try age(f,old)
        let latest = try snapshot(f,"latest"),trigger = latest["operation_id"] as! String
        _ = try configure(f)
        try f.router!.dbQueue.write {db in try CommandRouter.enqueueAutomaticBackupRetention(db,root:f.root,incarnation:f.router!.incarnation,operation:trigger)}
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention(after:old["operation_id"] as? String)["status"] as? String,"complete")
        try f.router!.dbQueue.read {db in
            let due = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'")))
            XCTAssertEqual(due["trigger_operation_id"] as? String,trigger)
        }
        XCTAssertEqual(f.router!.applyAutomaticBackupRetention()["trigger_operation_id"] as? String,trigger)
        XCTAssertFalse(exists(old))
        try f.router!.dbQueue.read {db in XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'"))}
    }

}
