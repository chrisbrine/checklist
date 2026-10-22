import XCTest
import GRDB
@testable import ChecklistCore

final class PurgeByteDeletionTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"purge-bytes-tests",projectIDs:[])
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".purge-byte-fixtures/" + uuid())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        router = try CommandRouter(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws {try router?.closeStore();router = nil;try? FileManager.default.removeItem(at:directory)}
    func call(_ method: String,_ input: JSON) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = uuid()}
        return try router.handle(method:method,params:input,caller:owner)["data"] as! JSON
    }
    func write(_ body: (Database) throws -> Void) throws {
        try ArchiveStorageGate.withExclusive(root:router.root) {_ in try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {try body(db);return .commit}}}
    }
    func fixture() throws -> (JSON,JSON,JSON,URL) {
        let workspace = directory.appendingPathComponent("workspace-" + uuid());try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Purge bytes","key_prefix":"PB","root_path":workspace.path])
        let task = try call("task_create",["project_id":project["id"]!,"title":"Synthetic byte owner"])
        let source = workspace.appendingPathComponent("original.txt");try Data("exclusive bytes".utf8).write(to:source)
        let attachment = try call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":source.path,"mode":"managed_copy"])
        return (project,task,attachment,source)
    }
    func params(_ project: JSON,_ task: JSON) -> JSON {["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]}
    func trash(_ project: JSON,_ task: JSON) throws -> JSON {var p = params(project,task);p["action"] = "trash";return try call("task_archive",p)}
    func preview(_ project: JSON,_ task: JSON) throws -> JSON {try call("task_purge_preview",params(project,task))}
    func purge(_ project: JSON,_ task: JSON) throws -> JSON {let v = try preview(project,task);var p = params(project,task);p["preview_digest"] = v["digest"]!;return try call("task_purge",p)}
    func receipt(_ result: JSON) throws -> JSON {try router.dbQueue.read {try router.record($0,result["byte_deletion_receipt_id"] as! String,type:"storage_job")}}
    func finish(_ result: JSON) throws -> JSON {
        for _ in 0..<30 {if try receipt(result)["state"] as? String == "completed" {return try receipt(result)};try router.runStorageMaintenance()}
        XCTFail("Deletion did not settle within the bounded fixture");return try receipt(result)
    }
    func testExclusiveOriginalPreviewAndCaptureBytesDeleteAfterCommitWithExactReceipt() throws {
        let (p,t,a,source) = try fixture(),tid = t["id"] as! String,pid = p["id"] as! String
        let previewPath = "objects/" + uuid() + ".preview.png",cid = uuid(),capturePath = "source-captures/" + pid + "/" + cid + "/source"
        let bytes = Data("captured".utf8),image = Data("preview".utf8)
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":tid,"revision":1,"snapshot_path":capturePath,"files":[["path":"a.txt","kind":"file","sha256":ChecklistCore.hash(bytes),"size":bytes.count],["path":"alias.txt","kind":"symlink","target":"a.txt","sha256":ChecklistCore.hash(Data("a.txt".utf8))]]]
        let manifest = Data(try jsonString(capture).utf8)
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(previewPath,bytes:image);try files.writeNew(capturePath + "/a.txt",bytes:bytes);try files.writeLink(capturePath + "/alias.txt",target:"a.txt")
        let sidecar = String(capturePath.dropLast("/source".count)) + "/manifest.json";try files.writeNew(sidecar,bytes:manifest)
        try write {db in var value = try self.router.record(db,a["id"] as! String,type:"attachment");value["preview_path"] = previewPath;try self.router.save(db,self.router.revised(value),type:"attachment");try self.router.save(db,capture,type:"source_capture")}
        let trashed = try trash(p,t),v = try preview(p,trashed),summary = (v["impact"] as! JSON)["byte_deletion"] as! JSON
        let expected = Int64("exclusive bytes".utf8.count + image.count + bytes.count + manifest.count + "a.txt".utf8.count)
        XCTAssertEqual(summary["pending_count"] as? Int,5);XCTAssertEqual((summary["pending_bytes"] as? NSNumber)?.int64Value,expected)
        let result = try purge(p,trashed),done = try finish(result)
        XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,5)
        XCTAssertEqual(((done["summary"] as! JSON)["removed_bytes"] as? NSNumber)?.int64Value,expected)
        for path in [a["path"] as! String,router.root.appendingPathComponent(previewPath).path,router.root.appendingPathComponent(capturePath + "/a.txt").path,router.root.appendingPathComponent(sidecar).path] {XCTAssertFalse(FileManager.default.fileExists(atPath:path))}
        XCTAssertFalse(try files.regularOrLinkExists(capturePath + "/alias.txt"));XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }
    func testSharedRecordAndCrossProjectPathKeepBytes() throws {
        let (p,t,a,_) = try fixture()
        let other = try call("project_create",["name":"Other","key_prefix":"OP"])
        let otherTask = try call("task_create",["project_id":other["id"]!,"title":"Shared owner"])
        try write {db in var copy = try self.router.record(db,a["id"] as! String,type:"attachment");copy["id"] = uuid();copy["project_id"] = other["id"]!;copy["task_id"] = otherTask["id"]!;try self.router.save(db,copy,type:"attachment")}
        let done = try finish(purge(p,trash(p,t)))
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertEqual((done["summary"] as! JSON)["retained_count"] as? Int,1)
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("remaining_record"))
    }
    func testExternalAndWorkspaceOriginalsStay() throws {
        let (p,t,a,source) = try fixture()
        _ = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"mode":"reference"])
        // Even a legacy/bad binding overlapping managed storage cannot grant unlink.
        try write {db in var project = try self.router.record(db,p["id"] as! String,type:"project");project["root_path"] = self.router.root.appendingPathComponent("objects").path;try self.router.save(db,self.router.revised(project),type:"project")}
        let done = try finish(purge(p,trash(p,t))),objects = done["objects"] as! [JSON]
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path));XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertTrue(objects.contains {($0["reasons"] as? [String] ?? []).contains("external_original")})
        XCTAssertTrue(objects.contains {($0["reasons"] as? [String] ?? []).contains("workspace_file")})
        XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,0)
    }
    func testReaderMediaAndBackupHoldsKeepTheirBytesAndReportReasons() throws {
        for (kind,reason) in [("reader","reader_lease"),("media_reference","media_owner"),("backup","backup_authority")] {
            let (p,t,a,_) = try fixture()
            try write {db in
                var hold: JSON = ["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"kind":kind,"state":"active","attachment_id":a["id"]!,"sha256":a["sha256"]!,"size":a["size"]!,"expires_at":Date().addingTimeInterval(300).timeIntervalSince1970,"revision":1]
                if kind == "media_reference" {
                    let anchor = uuid();try self.router.save(db,["id":anchor,"project_id":p["id"]!,"kind":"media_attachment_owner","owner_kind":"media_intake","state":"active","revision":1],type:"storage_job")
                    hold["owner_id"] = anchor;hold["owner_kind"] = "media_intake";hold.removeValue(forKey:"expires_at")
                }
                if kind == "backup" {hold.removeValue(forKey:"project_id")}
                try self.router.save(db,hold,type:"storage_hold")
            }
            let done = try finish(purge(p,trash(p,t)))
            XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
            XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains(reason))
        }
    }
    func testRetainedBackupAuthorityKeepsOriginalAndLeavesBackupUnchanged() throws {
        let (p,t,a,_) = try fixture(),backup = directory.appendingPathComponent("backup")
        _ = try call("backup_create",["path":backup.path])
        let before = try Data(contentsOf:backup.appendingPathComponent("manifest.json"))
        let done = try finish(purge(p,trash(p,t)))
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("backup_authority"))
        XCTAssertEqual(before,try Data(contentsOf:backup.appendingPathComponent("manifest.json")))
    }
    func testCrashAfterSemanticCommitResumesWithFreshSharedOwnershipCheck() throws {
        let (p,t,a,_) = try fixture(),trashed = try trash(p,t),v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        var result: JSON = [:]
        // Commit only the actual semantic transaction, then discard the router
        // before its post-commit maintenance tail, as in archive restart fixtures.
        try write {db in result = try self.router.taskPurge(db,input,self.owner)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertEqual(try receipt(result)["state"] as? String,"pending")
        let root = router.root
        // A new owner admitted before recovery must win the final all-record check.
        try write {db in let foreign: JSON = ["id":uuid(),"project_id":p["id"]!,"revision":1,"path":a["path"]!];try self.router.save(db,foreign,type:"manifest")}
        try router.closeStore();router = nil;router = try CommandRouter(root:root)
        let done = try finish(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,0)
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("remaining_record"))
    }
    func testCrashAfterCommitDeletesExclusiveBytesOnRestartAndRollbackNeverUnlinks() throws {
        let (p,t,a,_) = try fixture(),trashed = try trash(p,t),v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        enum Stop: Error {case rollback}
        XCTAssertThrowsError(try write {db in _ = try self.router.taskPurge(db,input,self.owner);throw Stop.rollback})
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"storage_job").filter {$0["kind"] as? String == CommandRouter.ticketObjectDeletionKind}.count},0)
        var result: JSON = [:];try write {db in result = try self.router.taskPurge(db,input,self.owner)}
        let root = router.root;try router.closeStore();router = nil;router = try CommandRouter(root:root)
        XCTAssertEqual((try finish(result)["summary"] as! JSON)["removed_count"] as? Int,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testBackupCanCapturePendingIntentAndItsOrphanedBytesBeforeRecovery() throws {
        let (p,t,a,_) = try fixture(),trashed = try trash(p,t),v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        var result: JSON = [:];try write {db in result = try self.router.taskPurge(db,input,self.owner)}
        let backup = directory.appendingPathComponent("pending-backup")
        XCTAssertNoThrow(try call("backup_create",["path":backup.path]))
        let done = try finish(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("backup_authority"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("manifest.json").path))
    }

    func testCrashAfterUnlinkReportsAlreadyMissingAndReceiptRetryObservesOutcome() throws {
        let (p,t,a,_) = try fixture(),trashed = try trash(p,t),v = try preview(p,trashed),command = uuid()
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!;input["command_id"] = command
        try router.dbQueue.write {db in try db.execute(sql:"CREATE TRIGGER purge_outcome_failure BEFORE UPDATE ON records WHEN NEW.type='storage_job' AND json_extract(NEW.data,'$.kind')='ticket_object_delete' AND json_extract(NEW.data,'$.state')='completed' BEGIN SELECT RAISE(ABORT,'synthetic receipt boundary');END")}
        let result = try router.handle(method:"task_purge",params:input,caller:owner)["data"] as! JSON
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertEqual(try receipt(result)["state"] as? String,"pending")
        try router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER purge_outcome_failure")}
        let root = router.root;try router.closeStore();router = nil;router = try CommandRouter(root:root)
        let replay = try router.handle(method:"task_purge",params:input,caller:owner)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        let data = replay["data"] as! JSON,summary = (data["byte_deletion"] as! JSON)["summary"] as! JSON
        XCTAssertEqual(summary["already_missing_count"] as? Int,1);XCTAssertEqual(summary["removed_bytes"] as? Int,0)
        XCTAssertEqual((data["counts"] as! JSON)["managed_bytes_deleted"] as? Int,0)
    }

    func testPinAndInvalidBackupAuthorityRetainBytesWithoutBlockingRecordPurge() throws {
        let (p,t,a,_) = try fixture()
        _ = try call("attachment_update",["project_id":p["id"]!,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":"keep_original"])
        let done = try finish(purge(p,trash(p,t)))
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("keep_original"))
        let (p2,t2,a2,_) = try fixture()
        try router.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-generation:invalid','{}')")}
        let done2 = try finish(purge(p2,trash(p2,t2)))
        XCTAssertTrue(FileManager.default.fileExists(atPath:a2["path"] as! String))
        XCTAssertTrue(((done2["objects"] as! [JSON])[0]["reasons"] as! [String]).contains("backup_authority_unavailable"))
    }

    func testBackupReferencesProtectCapturedSourceAndLinksWhileExclusiveSidecarDeletes() throws {
        let (p,t,_,_) = try fixture(),cid = uuid(),pid = p["id"] as! String
        let path = "source-captures/" + pid + "/" + cid + "/source",bytes = Data("source".utf8)
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":t["id"]!,"revision":1,"snapshot_path":path,"files":[["path":"file.txt","kind":"file","sha256":ChecklistCore.hash(bytes),"size":bytes.count,"executable":true],["path":"link.txt","kind":"symlink","target":"file.txt","sha256":ChecklistCore.hash(Data("file.txt".utf8))]]]
        let files = try StorageObjectFiles(root:router.root),sidecar = String(path.dropLast("/source".count)) + "/manifest.json"
        try files.writeNew(path + "/file.txt",bytes:bytes,permissions:0o555);try files.writeLink(path + "/link.txt",target:"file.txt");try files.writeNew(sidecar,bytes:Data(try jsonString(capture).utf8))
        try write {try self.router.save($0,capture,type:"source_capture")}
        _ = try call("backup_create",["path":directory.appendingPathComponent("capture-backup").path])
        let done = try finish(purge(p,trash(p,t))),objects = done["objects"] as! [JSON]
        XCTAssertTrue(try files.regularOrLinkExists(path + "/file.txt"));XCTAssertTrue(try files.regularOrLinkExists(path + "/link.txt"))
        XCTAssertFalse(try files.regularOrLinkExists(sidecar))
        for name in [path + "/file.txt",path + "/link.txt"] {XCTAssertTrue((objects.first {$0["relative_path"] as? String == name}?["reasons"] as? [String] ?? []).contains("backup_authority"))}
        // Retained descriptor authority remains snapshot-compatible after the
        // canonical capture and the exclusive sidecar have gone.
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("retained-capture-backup").path]))
    }

}
