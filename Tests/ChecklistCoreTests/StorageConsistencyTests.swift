import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// Actual current router graph and owned disposable files. No live root redirect.
final class StorageFixture {
    let id = UUID()
    let base: URL
    let root: URL
    let workspace: URL
    let owner = Caller(role:"owner",installation:"storage-fixture",projectIDs:[])
    var lease: StorageServiceLease?
    var router: CommandRouter?
    init(open: Bool = true) throws {
        // Keep the real storage no-follow walk intact. Foundation maps the
        // system temporary-directory alias back to /var on this macOS host;
        // qualification fixtures use the owner's physical Library/Caches root.
        let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let parent = caches.resolvingSymlinksInPath().appendingPathComponent("ChecklistQualification/CL-19",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        base = parent.appendingPathComponent("CL19-storage-" + id.uuidString.lowercased(),isDirectory:true)
        root = base.appendingPathComponent("store",isDirectory:true);workspace = base.appendingPathComponent("workspace",isDirectory:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["fixture_id":id.uuidString.lowercased(),"purpose":"CL19-storage-failure"],options:.sortedKeys).write(to:base.appendingPathComponent("ownership.json"))
        if open { try reopen() }
    }
    func close() throws { if let router {try router.closeStore()};router = nil;lease = nil }
    func reopen() throws {
        if router != nil || lease != nil { try close() }
        let freshLease = try StorageServiceLease(root:root)
        let freshRouter = try CommandRouter(root:root,serviceLease:freshLease)
        lease = freshLease;router = freshRouter
    }
    deinit { try? close();try? FileManager.default.removeItem(at:base) }
    @discardableResult func call(_ method: String,_ params: JSON = [:],command: String = UUID().uuidString.lowercased(),caller: Caller? = nil) throws -> JSON {
        var p = params;if !CommandRouter.readMethods.contains(method) {p["command_id"] = command}
        return try router!.handle(method:method,params:p,caller:caller ?? owner)
    }
    func project() throws -> JSON {try call("project_create",["name":"Storage fixture","key_prefix":"SF","root_path":workspace.path])["data"] as! JSON}
    func task(_ project: JSON) throws -> JSON {try call("task_create",["project_id":project["id"]!,"title":"Storage invariant"])["data"] as! JSON}
    func writeCommand(_ params: JSON) throws {try JSONSerialization.data(withJSONObject:params,options:.sortedKeys).write(to:base.appendingPathComponent("command.json"))}
    func spawn(_ mode: String,command: String = UUID().uuidString.lowercased()) throws -> Process {
        let exe = try XCTUnwrap(ProcessInfo.processInfo.environment["CHECKLIST_STORAGE_PROBE"])
        let p = Process();p.executableURL = URL(fileURLWithPath:exe);p.arguments = [base.path,id.uuidString.lowercased(),mode,command]
        p.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":base.path,"TMPDIR":base.path]
        p.standardOutput = FileHandle.nullDevice;p.standardError = FileHandle.nullDevice;try p.run();return p
    }
    func finish(_ p: Process, seconds: TimeInterval = 15) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while p.isRunning,ProcessInfo.processInfo.systemUptime < end {usleep(10_000)}
        if p.isRunning {_ = Darwin.kill(p.processIdentifier,SIGKILL)}
        let cleanup = ProcessInfo.processInfo.systemUptime + 3
        while p.isRunning,ProcessInfo.processInfo.systemUptime < cleanup {usleep(10_000)}
        XCTAssertFalse(p.isRunning,"Owned probe did not exit within finite bounds")
        if !p.isRunning {p.waitUntilExit()}
    }
    func seedReleased() throws -> JSON {
        try writeCommand(["name":"Released storage","key_prefix":"OLD","root_path":workspace.path])
        let p = try spawn("released-create");try finish(p);XCTAssertEqual(p.terminationStatus,0)
        return (try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("legacy-result.json"))) as! JSON)["data"] as! JSON
    }
}

final class StorageConsistencyTests: XCTestCase {
    func testActualImportReceiptBackupAndSelfContainedObjects() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let source = f.workspace.appendingPathComponent("original.bin"),bytes = Data(repeating:73,count:32768)
        try bytes.write(to:source)
        let cmd = UUID().uuidString.lowercased(),input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]
        let first = try f.call("attachment_add",input,command:cmd),a = first["data"] as! JSON
        XCTAssertEqual(a["availability"] as? String,"available");XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:a["path"] as! String)),bytes)
        try FileManager.default.removeItem(at:source)
        XCTAssertEqual((try f.call("attachment_add",input,command:cmd)["data"] as! JSON)["id"] as? String,a["id"] as? String)
        let backup = f.base.appendingPathComponent("backup"),bc = UUID().uuidString.lowercased()
        let result = try f.call("backup_create",["path":backup.path],command:bc),data = result["data"] as! JSON
        XCTAssertEqual(data["status"] as? String,"complete")
        let retained = try f.router!.dbQueue.read {db in try f.router!.storageBackupRetentionIndex(db).knownRetainedLogicalBytes(for:a)}
        XCTAssertEqual(retained,Int64(bytes.count))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:backup.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":original")})
        let relative = manifest.objects.first {$0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":original")}!.descriptor.relativePath
        try FileManager.default.removeItem(at:URL(fileURLWithPath:a["path"] as! String))
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("managed/" + relative)),bytes)
        let replay = try f.call("backup_create",["path":backup.path],command:bc)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual((replay["data"] as! JSON)["manifest_sha256"] as? String,data["manifest_sha256"] as? String)
        try f.close()
        // Read-only restore-materialization check: the source database/object
        // generation is absent at its original path. No live authority is
        // promoted or reset here; full owner restore remains CL6.
        try FileManager.default.moveItem(at:f.root,to:f.base.appendingPathComponent("original-store-preserved"))
        let restored = try StorageSnapshot.reconcile(parent:backup.deletingLastPathComponent(),operation:UUID(uuidString:data["operation_id"] as! String)!,publicationName:backup.lastPathComponent,budget:.init(deadlineUptime:ProcessInfo.processInfo.systemUptime + 10,canceled:{false}))
        XCTAssertEqual(restored.manifestSHA256,data["manifest_sha256"] as? String)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("managed/" + relative)),bytes)
    }
    func testLateDomainFailureRollsBackCounterEventCursorAndReceipt() throws {
        let f = try StorageFixture(),p = try f.project(),pid = p["id"] as! String
        let before = try f.router!.dbQueue.read {db in (try f.router!.record(db,pid,type:"project"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM cursors"))}
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER storage_late_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned late receipt failure');END")
        }
        let command = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try f.call("task_create",["project_id":pid,"title":"Late refused"],command:command))
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try jsonString(f.router!.record(db,pid,type:"project")),try jsonString(before.0))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),before.1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events"),before.2)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands"),before.3)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM cursors"),before.4)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
        }
    }
    func testOriginalPrincipalUUIDPendingOwnershipAcrossMethods() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),cmd = UUID().uuidString.lowercased()
        let source = f.workspace.appendingPathComponent("gone.bin")
        XCTAssertThrowsError(try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path],command:cmd))
        XCTAssertThrowsError(try f.call("backup_create",["path":f.base.appendingPathComponent("not-a-backup").path],command:cmd)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("not-a-backup").path))
    }
    func testOpaqueCursorAndAmbiguousDisplayKeysKeepAuthorityExact() throws {
        let f = try StorageFixture(),p = try f.project(),a = try f.task(p),b = try f.task(p)
        try f.router!.dbQueue.writeWithoutTransaction {db in
            try f.router!.withValidatedDomainTransaction(db) {
                var duplicate = try f.router!.record(db,b["id"] as! String,type:"task")
                duplicate["key"] = a["key"];try f.router!.save(db,duplicate,type:"task");return .commit
            }
        }
        XCTAssertThrowsError(try f.call("task_get",["project_id":p["id"]!,"key":a["key"]!])) {XCTAssertEqual(($0 as? CoreError)?.code,"AMBIGUOUS_TASK")}
        XCTAssertEqual((try f.call("task_get",["project_id":p["id"]!,"task_id":b["id"]!])["data"] as! JSON)["id"] as? String,b["id"] as? String)
        let first = Caller(role:"owner",installation:"\u{00e9}",projectIDs:[]),other = Caller(role:"owner",installation:"e\u{0301}",projectIDs:[])
        try f.router!.dbQueue.write {db in
            let scope = "scope\0suffix",token = try f.router!.cursor(db,caller:first,scope:scope)
            XCTAssertGreaterThanOrEqual(try f.router!.cursorSequence(db,["cursor":token],caller:first,scope:scope),0)
            XCTAssertThrowsError(try f.router!.cursorSequence(db,["cursor":token],caller:other,scope:scope)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
            XCTAssertThrowsError(try f.router!.cursorSequence(db,["cursor":token + "\0alias"],caller:first,scope:scope)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        }
    }

    func testReconciledMissingOriginalIsExplicitlyAbsentInBackup() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let source = f.workspace.appendingPathComponent("missing-original.bin")
        try Data(repeating:9,count:4096).write(to:source)
        var a = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        try FileManager.default.removeItem(at:URL(fileURLWithPath:a["path"] as! String))
        // Persisted input fixture for the exact legitimate executor outcome;
        // this checks backup authority mapping, not cleanup execution itself.
        a["availability"] = "original_missing"
        try f.router!.dbQueue.writeWithoutTransaction {db in try f.router!.withValidatedDomainTransaction(db) {try f.router!.save(db,f.router!.revised(a),type:"attachment");return .commit}}
        let destination = f.base.appendingPathComponent("missing-backup")
        XCTAssertEqual((try f.call("backup_create",["path":destination.path])["data"] as! JSON)["status"] as? String,"complete")
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.unavailable.contains {$0.authority == "attachment:" + (a["id"] as! String) && $0.reason == "original_missing"})
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":original")})
    }

    func testPublishedBackupFinalReceiptRollbackRetriesSameVerifiedGeneration() throws {
        let f = try StorageFixture();_ = try f.project()
        let command = UUID().uuidString.lowercased(),destination = f.base.appendingPathComponent("receipt-failed-backup")
        let input: JSON = ["path":destination.path]
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER backup_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned backup receipt failure');END")
        }
        XCTAssertThrowsError(try f.call("backup_create",input,command:command)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"OUTCOME_UNKNOWN")
            XCTAssertEqual(($0 as? CoreError)?.details["command_id"] as? String,command)
        }
        let manifest = try Data(contentsOf:destination.appendingPathComponent("manifest.json")),manifestSHA = ChecklistCore.hash(manifest)
        let recovery = try JSONSerialization.jsonObject(with:Data(contentsOf:f.root.appendingPathComponent("checklist-storage.recovery.json"))) as! JSON
        XCTAssertEqual(recovery["state"] as? String,"recovery_required");XCTAssertEqual(recovery["code"] as? String,"OUTCOME_UNKNOWN")
        try f.router!.dbQueue.write {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'"),0)
            try db.execute(sql:"DROP TRIGGER temp.backup_receipt_failure")
        }
        let retried = try f.call("backup_create",input,command:command),data = retried["data"] as! JSON
        XCTAssertEqual(data["status"] as? String,"complete");XCTAssertEqual(data["manifest_sha256"] as? String,manifestSHA)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("manifest.json")),manifest)
        XCTAssertEqual(try f.call("backup_create",input,command:command)["replayed"] as? Bool,true)
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'"),1)
        }
    }

    func testExistingForeignStoreGenerationCannotBecomeCurrentBackupReceipt() throws {
        let a = try StorageFixture(),b = try StorageFixture();_ = try a.project();_ = try b.project()
        let command = UUID().uuidString.lowercased(),destination = a.base.appendingPathComponent("store-a-backup")
        let first = try a.call("backup_create",["path":destination.path],command:command)
        XCTAssertEqual((first["data"] as! JSON)["status"] as? String,"complete")
        XCTAssertThrowsError(try b.call("backup_create",["path":destination.path],command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"BACKUP_TARGET_MISMATCH")}
        try b.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'"),0)
        }
        XCTAssertEqual(try a.call("backup_create",["path":destination.path],command:command)["replayed"] as? Bool,true)
    }

}
