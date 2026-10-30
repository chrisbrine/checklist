import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class StorageBackupPruningTests: XCTestCase {
    private func invoke(_ f: StorageFixture,_ method: String,_ params: JSON = [:],command: String = UUID().uuidString.lowercased(),observe: (String) throws -> Void = {_ in}) throws -> JSON {
        var input = params
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = command}
        return try f.router!.executeStorageBackupPruning(method:method,params:input,caller:f.owner,trashRoot:f.workspace,observe:observe)
    }
    private func snapshot(_ f: StorageFixture,_ name: String,time: String = "2020-01-01T00:00:00Z") throws -> JSON {
        let destination = f.root.appendingPathComponent("backups/snapshot-" + name)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let result = try f.call("backup_create",["path":destination.path])["data"] as! JSON
        try f.router!.dbQueue.write {db in
            let key = "backup-generation:" + (result["operation_id"] as! String)
            var value = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])!)
            var summary = value["summary"] as! JSON;summary["captured_at"] = time;value["summary"] = summary
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(value),key])
        }
        return result
    }
    private func preview(_ f: StorageFixture,_ params: JSON = [:]) throws -> JSON {try invoke(f,"backup_prune_preview",params)["data"] as! JSON}
    private func configure(_ f: StorageFixture) throws {_ = try invoke(f,"backup_retention_set",["newest_count":1,"daily_days":0])}
    private func apply(_ f: StorageFixture,_ preview: JSON,command: String = UUID().uuidString.lowercased(),observe: (String) throws -> Void = {_ in}) throws -> JSON {
        try invoke(f,"backup_prune",["preview_sha256":preview["preview_sha256"]!,"include_unrecorded":preview["include_unrecorded"]!],command:command,observe:observe)
    }
    func testProposedRetentionHasNoAutomaticPruneAndNeedsOwnerConfirmation() throws {
        let f = try StorageFixture()
        let settings = try f.call("backup_retention_get")["data"] as! JSON
        XCTAssertEqual(settings["newest_count"] as? Int,5);XCTAssertEqual(settings["daily_days"] as? Int,7)
        XCTAssertEqual(settings["owner_confirmed"] as? Bool,false);XCTAssertEqual(settings["automatic_prune"] as? Bool,false)
        XCTAssertThrowsError(try apply(f,preview(f))) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_RETENTION_UNCONFIRMED")}
        let worker = Caller(role:"worker",installation:"retention-worker",projectIDs:[])
        XCTAssertThrowsError(try f.router!.handle(method:"backup_retention_set",params:["command_id":UUID().uuidString,"newest_count":1],caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        let invalid: [JSON] = [["newest_count":0],["newest_count":true],["newest_count":1.5],["daily_days":367]]
        for bad in invalid {XCTAssertThrowsError(try invoke(f,"backup_retention_set",bad))}
    }
    func testNewestAndOnePerUTCDateAndUnknownTimestampsStay() throws {
        let date = ISO8601DateFormatter().date(from:"2026-10-30T14:00:00Z")!
        let input = [("a","2026-10-30T10:00:00Z"),("b","2026-10-30T09:00:00Z"),("c","2026-10-29T23:00:00Z"),("d","2026-10-28T01:00:00Z"),("old","2026-10-27T01:00:00Z"),("bad","unknown")]
        let reasons = StorageBackupRetentionPolicy(newestCount:2,dailyDays:3).reasons(input,at:date)
        XCTAssertEqual(reasons["a"],["newest","daily"]);XCTAssertEqual(reasons["b"],["newest"])
        XCTAssertEqual(reasons["c"],["daily"]);XCTAssertEqual(reasons["d"],["daily"])
        XCTAssertNil(reasons["old"]);XCTAssertTrue(reasons["bad"]!.contains("unknown_capture_time"))
    }
    func testPruneMovesToOwnedTrashAndRetiresReceiptUsageTogetherWithReplay() throws {
        let f = try StorageFixture();_ = try f.project()
        let old = try snapshot(f,"old"),new = try snapshot(f,"new",time:"2020-01-02T00:00:00Z")
        try configure(f)
        let plan = try preview(f);XCTAssertEqual(plan["prune_count"] as? Int,1)
        let command = UUID().uuidString.lowercased(),result = try apply(f,plan,command:command)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,1)
        let moved = (result["moved_to_trash"] as! [JSON])[0],trash = moved["trash_path"] as! String
        XCTAssertFalse(FileManager.default.fileExists(atPath:old["path"] as! String));XCTAssertTrue(FileManager.default.fileExists(atPath:trash))
        let digest = old["manifest_sha256"] as! String
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups/.indexes/" + digest + ".keys").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:URL(fileURLWithPath:trash).deletingLastPathComponent().appendingPathComponent(digest + ".keys").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:new["path"] as! String))
        try f.router!.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-generation:" + (old["operation_id"] as! String)]))
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["storage-copy-usage:backup:" + (old["operation_id"] as! String)]))
            XCTAssertNotNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-pruned:" + command]))
        }
        XCTAssertEqual(try apply(f,plan,command:command)["replayed"] as? Bool,true)
    }
    func testOwnerPinsAndProtectedUpgradeHistorySurviveRetention() throws {
        let f = try StorageFixture(),pinned = try snapshot(f,"pin"),protected = try snapshot(f,"upgrade",time:"2020-01-02T00:00:00Z"),history = try snapshot(f,"historical",time:"2020-01-03T00:00:00Z")
        _ = try snapshot(f,"new",time:"2020-01-04T00:00:00Z");try configure(f)
        _ = try invoke(f,"backup_pin",["path":pinned["path"]!,"pinned":true])
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":protected["path"]!,"protected":true])])
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-protected-history',?)",arguments:[try jsonString([["path":history["path"]!,"protected":true]])])
        }
        let plan = try preview(f);XCTAssertEqual(plan["prune_count"] as? Int,0)
        _ = try invoke(f,"backup_pin",["path":pinned["path"]!,"pinned":false])
        XCTAssertEqual(try preview(f)["prune_count"] as? Int,1)
    }
    func testActiveUseLeaseCannotBePrunedAndLaterUseResumes() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f)
        var use: StorageBackupUseLease? = try StorageBackupUseLease(root:URL(fileURLWithPath:old["path"] as! String))
        XCTAssertThrowsError(try StorageBackupUseLease(root:use!.files.root,exclusive:true)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_IN_USE")}
        let result = try apply(f,plan)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,0);XCTAssertEqual((result["retained_in_use"] as? [JSON])?.count,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:old["path"] as! String))
        use = nil
        XCTAssertEqual((try apply(f,preview(f))["data"] as! JSON)["moved_count"] as? Int,1)
    }
    func testCrashAfterMoveReconcilesOriginalIntentWithoutReofferingCompleteSnapshot() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f),command = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try apply(f,plan,command:command,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}})) {error in
            XCTAssertEqual((error as? CoreError)?.code,"OUTCOME_UNKNOWN")
            XCTAssertEqual((error as? CoreError)?.details["command_id"] as? String,command)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:old["path"] as! String))
        try f.reopen()
        let result = try apply(f,plan,command:command)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,1)
        XCTAssertEqual(try preview(f)["snapshot_count"] as? Int,1)
    }
    func testCrashAfterIntentRetainsSourceAndRetryUsesSamePlan() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f),command = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try apply(f,plan,command:command,observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}}))
        XCTAssertTrue(FileManager.default.fileExists(atPath:old["path"] as! String));try f.reopen()
        XCTAssertEqual((try apply(f,plan,command:command)["data"] as! JSON)["moved_count"] as? Int,1)
    }
    func testUnrecordedFailedPublicationIsCountedNeverOfferedCompleteAndExplicitlyRemovable() throws {
        let f = try StorageFixture();_ = try snapshot(f,"new");try configure(f)
        let failed = f.root.appendingPathComponent("backups/.snapshot-failed-fixture")
        try FileManager.default.createDirectory(at:failed,withIntermediateDirectories:true)
        try Data("failed manifest".utf8).write(to:failed.appendingPathComponent("manifest.json"))
        let plan = try preview(f),entries = plan["snapshots"] as! [JSON],entry = entries.first {$0["path"] as? String == failed.path}!
        XCTAssertEqual(plan["snapshot_count"] as? Int,2);XCTAssertEqual(entry["state"] as? String,"unrecorded_or_incomplete");XCTAssertFalse(bool(entry,"prune"))
        let explicit = try preview(f,["include_unrecorded":true]);XCTAssertEqual(explicit["prune_count"] as? Int,1)
        XCTAssertEqual((try apply(f,explicit)["data"] as! JSON)["moved_count"] as? Int,1)
    }
    func testPreviewChangeAndBackupCaptureRefuseWithoutMoving() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f);_ = try invoke(f,"backup_pin",["path":old["path"]!,"pinned":true])
        XCTAssertThrowsError(try apply(f,plan)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_PRUNE_PREVIEW_CHANGED")}
        let current = try preview(f)
        try StorageSnapshotRetention.withCapture(root:f.root) {_ in
            XCTAssertThrowsError(try apply(f,current)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:old["path"] as! String))
    }
    func testCleanupManifestProofUsesExistingDescriptorAndPreventsPrune() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f),path = URL(fileURLWithPath:old["path"] as! String)
        var proof = try TicketObjectRemovalVerification(root:path,relative:"manifest.json",sha256:old["manifest_sha256"] as? String,backupUse:true)
        XCTAssertNotNil(proof)
        XCTAssertThrowsError(try StorageBackupUseLease(root:path,exclusive:true)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_IN_USE")}
        XCTAssertEqual((try apply(f,plan)["data"] as! JSON)["moved_count"] as? Int,0)
        proof = nil
        XCTAssertEqual((try apply(f,preview(f))["data"] as! JSON)["moved_count"] as? Int,1)
    }
    func testActualRestoreHoldsSourceLeaseThroughCandidatePublication() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old"),source = URL(fileURLWithPath:old["path"] as! String)
        var budget = StorageSnapshotBudget.production(),observed = false
        budget.observe = {event in
            guard event == "restore_before_publish" else {return}
            observed = true
            XCTAssertThrowsError(try StorageBackupUseLease(root:source,exclusive:true)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_IN_USE")}
        }
        let result = try f.router!.executeStorageRestore(method:"restore_create",params:["command_id":UUID().uuidString,"path":source.path,"manifest_sha256":old["manifest_sha256"]!],caller:f.owner,budget:budget)["data"] as! JSON
        XCTAssertTrue(observed);XCTAssertEqual(result["status"] as? String,"complete")
        XCTAssertNoThrow(try StorageBackupUseLease(root:source,exclusive:true))
    }

    func testInterruptedIntentRechecksNewOwnerPinsAndUpgradeProtection() throws {
        for protection in ["pin","upgrade","policy"] {
            let f = try StorageFixture(),old = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
            let plan = try preview(f),command = UUID().uuidString.lowercased()
            XCTAssertThrowsError(try apply(f,plan,command:command,observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}}))
            if protection == "pin" {_ = try invoke(f,"backup_pin",["path":old["path"]!,"pinned":true])}
            else if protection == "policy" {_ = try invoke(f,"backup_retention_set",["newest_count":2,"daily_days":0])}
            else {try f.router!.dbQueue.write {db in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":old["path"]!,"protected":true])])
            }}
            let result = try apply(f,plan,command:command)["data"] as! JSON
            XCTAssertEqual(result["moved_count"] as? Int,0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:old["path"] as! String))
        }
    }

    func testMissingSnapshotCanBeUnpinnedAndOnlyHistoricalProtectionRetired() throws {
        let f = try StorageFixture(),old = try snapshot(f,"old"),path = old["path"] as! String
        _ = try invoke(f,"backup_pin",["path":path,"pinned":true])
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-protected-history',?)",arguments:[try jsonString([["path":path,"protected":true]])])
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":path,"protected":true])])
        }
        XCTAssertThrowsError(try invoke(f,"backup_pin",["path":path,"pinned":true,"retire_upgrade_protection":true]))
        try FileManager.default.moveItem(at:URL(fileURLWithPath:path),to:f.workspace.appendingPathComponent("moved-snapshot"))
        _ = try invoke(f,"backup_pin",["path":path,"pinned":false,"retire_upgrade_protection":true])
        let settings = try f.call("backup_retention_get")["data"] as! JSON
        XCTAssertEqual((settings["pins"] as? [JSON])?.count,0)
        try f.router!.dbQueue.read {db in
            let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-protected-history'")!
            XCTAssertEqual((try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [JSON])?.count,0)
            XCTAssertEqual(jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")))["path"] as? String,path)
        }
    }

    func testInterruptedPruneReservesOriginalUUIDAgainstOtherCommands() throws {
        let f = try StorageFixture();_ = try snapshot(f,"old");_ = try snapshot(f,"new",time:"2020-01-02T00:00:00Z");try configure(f)
        let plan = try preview(f),command = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try apply(f,plan,command:command,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}}))
        XCTAssertThrowsError(try invoke(f,"backup_retention_set",["newest_count":7],command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        XCTAssertEqual((try apply(f,plan,command:command)["data"] as! JSON)["moved_count"] as? Int,1)
        try f.router!.dbQueue.read {db in
            let key = try f.router!.pendingStorageCommandKey(principal:f.owner.principal,command:command)
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]))
        }
    }

    func testMalformedProtectionAndPinsFailClosed() throws {
        for key in ["backup-protected-history","backup-retention-settings","preupgrade_snapshot"] {
            let f = try StorageFixture()
            let raw = key == "backup-retention-settings" ? "{\"newest_count\":1,\"daily_days\":0,\"owner_confirmed\":true,\"pins\":[{}]}" : "[]"
            try f.router!.dbQueue.write {db in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,raw])
            }
            if key == "backup-protected-history" {
                try f.router!.dbQueue.write {db in try db.execute(sql:"UPDATE metadata SET value='{}' WHERE key=?",arguments:[key])}
            }
            XCTAssertThrowsError(try preview(f)) {XCTAssertEqual(($0 as? CoreError)?.code,"RECOVERY_REQUIRED")}
        }
    }

    func testOwnerCatalogUsesTypedInstallationInputsWithoutProjectRequirement() throws {
        let f = try StorageFixture(),tools = f.router!.toolCatalog(f.owner)
        for name in CommandRouter.storageBackupPruningMethods {
            let tool = try XCTUnwrap(tools.first {$0["name"] as? String == name}),schema = tool["inputSchema"] as! JSON,properties = schema["properties"] as! JSON
            XCTAssertNil(properties["project_id"]);XCTAssertNil(properties["expected_revision"])
            XCTAssertFalse((schema["required"] as? [String] ?? []).contains("project_id"))
            if name == "backup_retention_set" {XCTAssertEqual((properties["newest_count"] as? JSON)?["type"] as? String,"integer")}
            if name == "backup_pin" {XCTAssertEqual((properties["pinned"] as? JSON)?["type"] as? String,"boolean")}
        }
    }

}
