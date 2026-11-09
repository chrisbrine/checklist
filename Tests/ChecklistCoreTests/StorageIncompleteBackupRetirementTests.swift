import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageIncompleteBackupRetirementTests: XCTestCase {
    private func invoke(_ f: StorageFixture,_ method: String,_ params: JSON = [:],caller: Caller? = nil,command: String = uuid(),observe: (String) throws -> Void = {_ in}) throws -> JSON {
        var input = params
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = command}
        return try f.router!.executeStorageBackupPruning(method:method,params:input,caller:caller ?? f.owner,trashRoot:f.workspace,observe:observe)
    }
    private func folder(_ f: StorageFixture,_ name: String,manifest: Bool = false) throws -> URL {
        let path = f.root.appendingPathComponent("backups/" + name,isDirectory:true)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        try Data([1,2,3]).write(to:path.appendingPathComponent(manifest ? "manifest.json" : "partial.bin"))
        return path
    }
    private func worker(_ f: StorageFixture,_ project: JSON) throws -> Caller {
        let session = try f.call("session_register",["project_id":project["id"]!,"label":"Incomplete backup fixture","provider":"codex","role":"worker","installation":"incomplete-retirement","workspace":f.workspace.path])["data"] as! JSON
        return Caller(role:"worker",installation:"incomplete-retirement",projectIDs:[project["id"] as! String],sessionID:session["id"] as? String,workspace:f.workspace.path)
    }
    private func plan(_ f: StorageFixture,caller: Caller? = nil,project: String? = nil) throws -> JSON {
        try invoke(f,"backup_incomplete_preview",project.map {["project_id":$0]} ?? [:],caller:caller)["data"] as! JSON
    }
    private func retire(_ f: StorageFixture,_ preview: JSON,caller: Caller? = nil,project: String? = nil,command: String = uuid(),observe: (String) throws -> Void = {_ in}) throws -> JSON {
        var params: JSON = ["preview_sha256":preview["preview_sha256"]!]
        params["project_id"] = project
        return try invoke(f,"backup_incomplete_retire",params,caller:caller,command:command,observe:observe)
    }

    func testWorkerRetiresManifestAndPreManifestFoldersWithoutOwnerConfirmationAndReportsEveryFolder() throws {
        let f = try StorageFixture(),project = try f.project(),caller = try worker(f,project),pid = project["id"] as! String
        let complete = try f.call("backup_create",["project_id":pid],caller:caller)["data"] as! JSON
        let partial = try folder(f,"snapshot-" + uuid(),manifest:true),stage = try folder(f,".snapshot-staging-" + uuid())
        let preview = try plan(f,caller:caller,project:pid),entries = preview["snapshots"] as! [JSON]
        XCTAssertEqual(preview["owner_confirmed"] as? Bool,false)
        XCTAssertEqual(preview["complete_count"] as? Int,1);XCTAssertEqual(preview["incomplete_count"] as? Int,2)
        for path in [partial.path,stage.path] {XCTAssertEqual(entries.first {$0["path"] as? String == path}?["state"] as? String,"incomplete")}
        let command = uuid(),result = try retire(f,preview,caller:caller,project:pid,command:command)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,2)
        let outcomes = result["folders"] as! [JSON]
        XCTAssertEqual(outcomes.count,3)
        XCTAssertEqual(outcomes.first {$0["path"] as? String == complete["path"] as? String}?["action"] as? String,"kept")
        XCTAssertTrue((outcomes.first {$0["path"] as? String == complete["path"] as? String}?["keep_reasons"] as? [String] ?? []).contains("complete_receipt"))
        for item in result["moved_to_trash"] as! [JSON] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:item["path"] as! String))
            XCTAssertTrue(FileManager.default.fileExists(atPath:item["trash_path"] as! String))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:complete["path"] as! String))
        XCTAssertEqual(try retire(f,preview,caller:caller,project:pid,command:command)["replayed"] as? Bool,true)
        XCTAssertEqual(try plan(f,caller:caller,project:pid)["incomplete_count"] as? Int,0)
    }

    func testRestorePreviewNamesValidManifestWithoutCompletedReceiptIncomplete() throws {
        let f = try StorageFixture(),outside = f.base.appendingPathComponent("detached-backup")
        _ = try f.call("backup_create",["path":outside.path])
        let local = f.root.appendingPathComponent("backups/snapshot-" + uuid())
        try FileManager.default.createDirectory(at:local.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:outside,to:local)
        XCTAssertThrowsError(try f.call("restore_preview",["path":local.path])) {error in
            XCTAssertEqual((error as? CoreError)?.code,"BACKUP_INCOMPLETE")
            XCTAssertEqual((error as? CoreError)?.details["state"] as? String,"incomplete")
            XCTAssertEqual((error as? CoreError)?.details["reason"] as? String,"no_complete_receipt")
        }
        let entries = try plan(f)["snapshots"] as! [JSON]
        XCTAssertEqual(entries.first {$0["path"] as? String == local.path}?["state"] as? String,"incomplete")
    }

    func testPreManifestCrashAfterMoveReconcilesExactOriginalCommand() throws {
        let f = try StorageFixture(),stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f),command = uuid()
        XCTAssertThrowsError(try retire(f,preview,command:command,observe:{if $0 == "prune_snapshot_moved" {throw StorageSnapshotFailure.canceled}})) {XCTAssertEqual(($0 as? CoreError)?.code,"OUTCOME_UNKNOWN")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
        try f.reopen()
        let result = try retire(f,preview,command:command)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,1)
        XCTAssertEqual(try retire(f,preview,command:command)["replayed"] as? Bool,true)
    }

    func testProtectedUpgradeReceiptStillNamesCompletedBackupAndAllowsRestore() throws {
        let f = try StorageFixture(),outside = f.base.appendingPathComponent("upgrade-copy")
        let result = try f.call("backup_create",["path":outside.path])["data"] as! JSON,operation = result["operation_id"] as! String
        let local = f.root.appendingPathComponent("backups/snapshot-" + operation)
        try FileManager.default.createDirectory(at:local.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:outside,to:local)
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":local.path,"operation_id":operation,"manifest_sha256":result["manifest_sha256"]!,"source_fingerprint":String(repeating:"a",count:64),"protected":true])])
        }
        XCTAssertEqual((try f.call("restore_preview",["path":local.path])["data"] as? JSON)?["state"] as? String,"complete")
        let entry = try XCTUnwrap((try plan(f)["snapshots"] as! [JSON]).first {$0["path"] as? String == local.path})
        XCTAssertEqual(entry["state"] as? String,"complete");XCTAssertFalse(bool(entry,"prune"))
        XCTAssertTrue((entry["keep_reasons"] as! [String]).contains("protected_upgrade"))
    }

    func testRelocatedCompactReceiptNamesLocalCompletedBackupAndAllowsRestore() throws {
        let f = try StorageFixture(),command = uuid(),local = f.root.appendingPathComponent("backups/snapshot-" + command)
        try FileManager.default.createDirectory(at:local.deletingLastPathComponent(),withIntermediateDirectories:true)
        let result = try f.call("backup_create",["path":local.path],command:command)["data"] as! JSON
        try f.router!.dbQueue.write {db in
            let key = "backup-generation:" + (result["operation_id"] as! String)
            var receipt = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]))),summary = receipt["summary"] as! JSON
            XCTAssertEqual(receipt["format"] as? Int,2)
            summary["source_root"] = f.base.appendingPathComponent("prior-root").path
            summary["path"] = f.base.appendingPathComponent("prior-root/backups/" + local.lastPathComponent).path;receipt["summary"] = summary
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(receipt),key])
        }
        XCTAssertEqual((try f.call("restore_preview",["path":local.path])["data"] as? JSON)?["state"] as? String,"complete")
        let entries = try plan(f)["snapshots"] as! [JSON]
        XCTAssertEqual(entries.first {$0["path"] as? String == local.path}?["state"] as? String,"complete")
        XCTAssertEqual(entries.filter {$0["state"] as? String == "incomplete"}.count,0)
    }

    func testInterruptedIntentRechecksUpgradeProtectionAndDirectoryReplacement() throws {
        for replacement in [false,true] {
            let f = try StorageFixture(),stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f),command = uuid()
            XCTAssertThrowsError(try retire(f,preview,command:command,observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}}))
            if replacement {
                try FileManager.default.moveItem(at:stage,to:f.workspace.appendingPathComponent("original-stage"))
                try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true)
            } else {try f.router!.dbQueue.write {db in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(["path":stage.path,"protected":true])])
            }}
            let result = try retire(f,preview,command:command)["data"] as! JSON
            XCTAssertEqual(result["moved_count"] as? Int,0)
            let kept = try XCTUnwrap((result["retained_snapshots"] as? [JSON])?.first)
            XCTAssertEqual(kept["reason"] as? String,replacement ? "source_changed" : "current_retention_protection")
            XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path))
        }
    }

    func testCaptureAndDirectoryUseLeaseRetainPreManifestFolder() throws {
        let f = try StorageFixture(),stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f)
        try StorageSnapshotRetention.withCapture(root:f.root) {_ in
            XCTAssertThrowsError(try retire(f,preview)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_CAPTURE_ACTIVE")}
        }
        let files = try StorageObjectFiles(root:stage)
        XCTAssertEqual(flock(files.descriptor,LOCK_SH | LOCK_NB),0)
        let result = try retire(f,preview)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,0)
        XCTAssertEqual((result["retained_in_use"] as? [JSON])?.count,1)
        XCTAssertEqual(flock(files.descriptor,LOCK_UN),0)
        XCTAssertEqual((try retire(f,plan(f))["data"] as! JSON)["moved_count"] as? Int,1)
    }

    func testInterruptedIntentRetainsSameDirectoryWhenItsContentsChange() throws {
        let f = try StorageFixture(),stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f),command = uuid()
        XCTAssertThrowsError(try retire(f,preview,command:command,observe:{if $0 == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}}))
        try Data([4,5,6]).write(to:stage.appendingPathComponent("later.bin"))
        let result = try retire(f,preview,command:command)["data"] as! JSON
        XCTAssertEqual(result["moved_count"] as? Int,0)
        XCTAssertEqual((result["retained_snapshots"] as? [JSON])?.first?["reason"] as? String,"source_changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path))
    }

    func testPreviewChangeUnsafePathsAndWorkerPolicyRefuseWithoutMoving() throws {
        let f = try StorageFixture(),project = try f.project(),caller = try worker(f,project),pid = project["id"] as! String
        let stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f,caller:caller,project:pid)
        _ = try folder(f,"snapshot-" + uuid())
        XCTAssertThrowsError(try retire(f,preview,caller:caller,project:pid)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_PRUNE_PREVIEW_CHANGED")}
        let outside = f.workspace.appendingPathComponent("snapshot-outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let alias = f.root.appendingPathComponent("backups/.snapshot-staging-link")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:outside)
        XCTAssertFalse((try plan(f)["snapshots"] as! [JSON]).contains {$0["path"] as? String == alias.path})
        try f.router!.dbQueue.write {db in
            var current = try f.router!.record(db,pid,type:"project"),policy = current["policy"] as! JSON
            policy["agent_rule_changes"] = "owner_only";current["policy"] = policy;try f.router!.save(db,current,type:"project")
        }
        XCTAssertThrowsError(try plan(f,caller:caller,project:pid)) {XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")}
        XCTAssertThrowsError(try plan(f,caller:Caller(role:"assistant",installation:"assistant",projectIDs:[pid]),project:pid))
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path));XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }

    func testCatalogRequiresScopedWorkerPreviewAndExactDigestForRetirement() throws {
        let f = try StorageFixture(),project = try f.project(),caller = try worker(f,project),tools = f.router!.toolCatalog(caller)
        for name in CommandRouter.storageIncompleteBackupMethods {
            let schema = try XCTUnwrap(tools.first {$0["name"] as? String == name}?["inputSchema"] as? JSON)
            XCTAssertTrue((schema["required"] as! [String]).contains("project_id"))
            XCTAssertNil((schema["properties"] as! JSON)["path"])
            if name == "backup_incomplete_retire" {XCTAssertTrue((schema["required"] as! [String]).contains("preview_sha256"))}
        }
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[])
        XCTAssertFalse(f.router!.toolCatalog(assistant).contains {CommandRouter.storageIncompleteBackupMethods.contains($0["name"] as? String ?? "")})
    }

    func testInterruptedWorkerIntentRejectsAnotherAuthorizationGenerationWithoutMoving() throws {
        let f = try StorageFixture(),project = try f.project(),caller = try worker(f,project),pid = project["id"] as! String
        let stage = try folder(f,".snapshot-staging-" + uuid()),preview = try plan(f,caller:caller,project:pid),command = uuid()
        let originalGeneration = try f.router!.dbQueue.read {db in try f.router!.callerSessionGeneration(db,caller,project:pid)}
        XCTAssertThrowsError(try retire(f,preview,caller:caller,project:pid,command:command,observe:{event in
            if event == "prune_intent_committed" {throw StorageSnapshotFailure.canceled}
        })) {XCTAssertEqual(($0 as? CoreError)?.code,"OUTCOME_UNKNOWN")}
        // The interrupted command released its object gate. A later qualified
        // session generation must not resume that original filesystem intent.
        try ArchiveStorageGate.withExclusive(root:f.root) {_ in
            try f.router!.dbQueue.write {db in
                var session = try f.router!.record(db,caller.sessionID!,type:"session")
                session["authorization_generation"] = uuid();try f.router!.save(db,session,type:"session")
            }
        }
        XCTAssertThrowsError(try retire(f,preview,caller:caller,project:pid,command:command)) {error in
            XCTAssertEqual((error as? CoreError)?.code,"OUTCOME_UNKNOWN")
            XCTAssertEqual((error as? CoreError)?.details["underlying_error"] as? String,"CONNECTION_REVOKED")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path))
        try f.router!.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]))
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-prune-intent:" + ChecklistCore.hash(Data((caller.principal + command).utf8))]))
            XCTAssertEqual(jsonObject(raw)["authorization_generation"] as? String,originalGeneration)
            let pending = try f.router!.pendingStorageCommandKey(principal:caller.principal,command:command)
            XCTAssertNotNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[pending]))
        }
    }
}
