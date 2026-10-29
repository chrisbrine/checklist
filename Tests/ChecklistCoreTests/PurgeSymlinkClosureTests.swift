import ChecklistTestSupport
import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

extension PurgeByteDeletionTests {
    func linkChainFixture() throws -> (JSON,JSON,JSON,String) {
        let (p,t,a,_) = try fixture(),cid = uuid(),pid = p["id"] as! String
        let path = "source-captures/" + pid + "/" + cid + "/source",bytes = Data("chain payload".utf8)
        // Lexical order puts the inner link first. That is unsafe if the outer
        // link remains pending, gains a hold or fails its unlink.
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":t["id"]!,"revision":1,"snapshot_path":path,"files":[
            ["path":"target.txt","kind":"file","sha256":ChecklistCore.hash(bytes),"size":bytes.count],
            ["path":"a-inner.txt","kind":"symlink","target":"target.txt","sha256":ChecklistCore.hash(Data("target.txt".utf8))],
            ["path":"z-links/alias.txt","kind":"symlink","target":"../a-inner.txt","sha256":ChecklistCore.hash(Data("../a-inner.txt".utf8))]]]
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/target.txt",bytes:bytes)
        try files.writeLink(path + "/a-inner.txt",target:"target.txt")
        try files.writeLink(path + "/z-links/alias.txt",target:"../a-inner.txt")
        try files.writeNew(String(path.dropLast("/source".count)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8))
        try write {try self.router.save($0,capture,type:"source_capture")}
        return (p,t,a,path)
    }
    func assertLinkChain(_ path: String,file: StaticString = #filePath,line: UInt = #line) throws {
        let files = try StorageObjectFiles(root:router.root)
        for name in ["z-links/alias.txt","a-inner.txt","target.txt"] {XCTAssertTrue(try files.regularOrLinkExists(path + "/" + name),name,file:file,line:line)}
        XCTAssertEqual(try Data(contentsOf:router.root.appendingPathComponent(path + "/z-links/alias.txt")),Data("chain payload".utf8),file:file,line:line)
    }
    func testRetainedLinkChainProtectsEveryHopAndPreviewTotals() throws {
        let (p,t,_,path) = try linkChainFixture()
        _ = try call("task_create",["project_id":p["id"]!,"title":"Other chain consumer","brief":path + "/z-links/alias.txt"])
        let trashed = try trash(p,t),impact = try preview(p,trashed)["impact"] as! JSON,summary = impact["byte_deletion"] as! JSON
        XCTAssertEqual(summary["retained_count"] as? Int,3);XCTAssertEqual(summary["pending_count"] as? Int,2)
        XCTAssertEqual((summary["retained_bytes"] as? NSNumber)?.int64Value,Int64("target.txt".utf8.count + "../a-inner.txt".utf8.count + "chain payload".utf8.count))
        let done = try finish(purge(p,trashed)),objects = done["objects"] as! [JSON]
        try assertLinkChain(path)
        XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,2)
        for name in ["a-inner.txt","target.txt"] {XCTAssertEqual(objects.first {$0["relative_path"] as? String == path + "/" + name}?["reasons"] as? [String],["retained_link_target"])}
        XCTAssertEqual(try call("backup_create",["path":directory.appendingPathComponent("shared-chain-backup").path])["status"] as? String,"complete")
    }
    func testPendingLinkChainDeletesInDependencyOrderAndLeavesValidInventoryAtEveryStep() throws {
        let (p,t,_,path) = try linkChainFixture(),trashed = try trash(p,t),v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        var result: JSON = [:];try write {result = try self.router.taskPurge($0,input,self.owner)}
        let files = try StorageObjectFiles(root:router.root),initial = try receipt(result)["summary"] as! JSON
        for step in 0..<8 {
            if try receipt(result)["state"] as? String == "completed" {break}
            // Inspect each actual writer chunk. A production cohort can now
            // perform several such chunks in one maintenance call.
            try router.withTicketCleanupPreparation({try self.router.prepareTicketObjectDeletion($0)}) {db,permit,prepared in
                try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)
            }
            if step == 0 {
                XCTAssertFalse(try files.regularOrLinkExists(path + "/z-links/alias.txt"))
                XCTAssertTrue(try files.regularOrLinkExists(path + "/a-inner.txt"))
            }
            XCTAssertNoThrow(try router.dbQueue.read {try StorageSnapshotAuthority.inventory($0,root:self.router.root,budget:.production(),retainedExists:files.regularOrLinkExists)})
        }
        let done = try receipt(result),summary = done["summary"] as! JSON
        XCTAssertEqual(done["state"] as? String,"completed");XCTAssertEqual(summary["removed_count"] as? Int,5)
        XCTAssertEqual(summary["removed_bytes"] as? Int,initial["pending_bytes"] as? Int)
        XCTAssertFalse(try files.regularOrLinkExists(path + "/target.txt"))
        XCTAssertEqual(try call("backup_create",["path":directory.appendingPathComponent("exclusive-chain-backup").path])["status"] as? String,"complete")
    }
    func testRestartAfterFirstLinkUnlinkFailureRetainsWholeChainAndBackupSucceeds() throws {
        let (p,t,_,path) = try linkChainFixture(),trashed = try trash(p,t),v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        var result: JSON = [:];try write {result = try self.router.taskPurge($0,input,self.owner)}
        let linkDirectory = router.root.appendingPathComponent(path + "/z-links")
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:linkDirectory.path)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:linkDirectory.path)}
        try pumpByteDeletion()
        let first = try XCTUnwrap((receipt(result)["objects"] as! [JSON]).first {$0["relative_path"] as? String == path + "/z-links/alias.txt"})
        XCTAssertEqual(first["failures"] as? Int,1);XCTAssertEqual(first["state"] as? String,"pending");try assertLinkChain(path)
        let root = router.root;try router.closeStore();router = nil;router = try TestStore.router(root:root)
        let done = try finish(result),summary = done["summary"] as! JSON,objects = done["objects"] as! [JSON]
        try assertLinkChain(path)
        XCTAssertEqual(summary["retained_count"] as? Int,3);XCTAssertEqual(summary["removed_count"] as? Int,2)
        let link = try XCTUnwrap(objects.first {$0["relative_path"] as? String == path + "/z-links/alias.txt"})
        XCTAssertEqual(link["failures"] as? Int,2);XCTAssertEqual(link["reasons"] as? [String],["CLEANUP_IO"])
        XCTAssertEqual(try call("backup_create",["path":directory.appendingPathComponent("resumed-chain-backup").path])["status"] as? String,"complete")
    }
    func testLateTypedLinkHoldsWinRecoveryBeforeAnyTargetUnlink() throws {
        for (kind,reason) in [("reader","reader_lease"),("media_reference","media_owner"),("backup","backup_authority")] {
            let (p,t,a,path) = try linkChainFixture()
            let other = try call("task_create",["project_id":p["id"]!,"title":"Late typed owner"])
            var shared = try router.dbQueue.read {try self.router.record($0,a["id"] as! String,type:"attachment")}
            shared["id"] = uuid();shared["task_id"] = other["id"]!
            let trashed = try trash(p,t),v = try preview(p,trashed)
            var input = params(p,trashed);input["preview_digest"] = v["digest"]!
            var result: JSON = [:];try write {result = try self.router.taskPurge($0,input,self.owner)}
            // Admit a new canonical owner and link-specific hold after the intent
            // commits but before the first recovery unlink.
            try write {db in
                try self.router.save(db,shared,type:"attachment")
                var hold: JSON = ["id":uuid(),"project_id":p["id"]!,"kind":kind,"state":"active","attachment_id":shared["id"]!,"sha256":shared["sha256"]!,"size":shared["size"]!,"path":path + "/z-links/alias.txt","revision":1]
                if kind == "media_reference" {
                    let anchor = uuid();try self.router.save(db,["id":anchor,"project_id":p["id"]!,"kind":"media_attachment_owner","owner_kind":"media_intake","state":"active","revision":1],type:"storage_job")
                    hold["owner_id"] = anchor;hold["owner_kind"] = "media_intake"
                } else {hold["expires_at"] = Date().addingTimeInterval(300).timeIntervalSince1970}
                if kind == "backup" {hold.removeValue(forKey:"project_id")}
                try self.router.save(db,hold,type:"storage_hold")
            }
            let root = router.root;try router.closeStore();router = nil;router = try TestStore.router(root:root)
            let done = try finish(result),objects = done["objects"] as! [JSON]
            try assertLinkChain(path)
            XCTAssertTrue((objects.first {$0["relative_path"] as? String == path + "/z-links/alias.txt"}?["reasons"] as? [String] ?? []).contains(reason))
            XCTAssertEqual(try call("backup_create",["path":directory.appendingPathComponent("late-" + kind + "-backup").path])["status"] as? String,"complete")
        }
    }
    func testEveryRetainedReasonProtectsTheLinkClosureAndAmbiguityRetainsCapture() throws {
        let path = "source-captures/project/capture/source"
        let file: JSON = ["relative_path":path + "/target.txt","kind":"file","sha256":ChecklistCore.hash(Data("bytes".utf8)),"size":5,"state":"pending"]
        let inner: JSON = ["relative_path":path + "/inner.txt","kind":"symlink","link_target":"target.txt","sha256":ChecklistCore.hash(Data("target.txt".utf8)),"size":10,"state":"pending"]
        let link: JSON = ["relative_path":path + "/outer.txt","kind":"symlink","link_target":"inner.txt","sha256":ChecklistCore.hash(Data("inner.txt".utf8)),"size":9,"state":"retained"]
        for reason in ["remaining_record","reader_lease","media_owner","keep_original","backup_authority","backup_authority_unavailable","ambiguous_identity","CLEANUP_IO","identity_unavailable"] {
            var seed = link;seed["reasons"] = [reason]
            var objects = [file,inner,seed]
            XCTAssertTrue(CommandRouter.retainTicketObjectDeletionLinkTargets(&objects).isEmpty,reason)
            XCTAssertTrue(objects.allSatisfy {$0["state"] as? String == "retained"},reason)
        }
        var unknown = link;unknown["link_target"] = "../../outside";unknown["sha256"] = ChecklistCore.hash(Data("../../outside".utf8))
        var objects = [file,inner,unknown,["relative_path":"objects/exclusive.txt","kind":"file","state":"pending"]]
        _ = CommandRouter.retainTicketObjectDeletionLinkTargets(&objects)
        XCTAssertEqual(objects[0]["reasons"] as? [String],["link_closure_unavailable"])
        XCTAssertEqual(objects[1]["state"] as? String,"retained");XCTAssertEqual(objects[3]["state"] as? String,"pending")
    }

    func testReviewerPartialLinkDeletionFailureKeepsBackupUsable() throws {
        let (p,t,_,_) = try fixture(), cid = uuid(), pid = p["id"] as! String
        let path = "source-captures/" + pid + "/" + cid + "/source"
        let bytes = Data("target payload".utf8), target = "../target.txt"
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":t["id"]!,"revision":1,"snapshot_path":path,"files":[
            ["path":"target.txt","kind":"file","sha256":ChecklistCore.hash(bytes),"size":bytes.count],
            ["path":"links/alias.txt","kind":"symlink","target":target,"sha256":ChecklistCore.hash(Data(target.utf8))]]]
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/target.txt",bytes:bytes)
        try files.writeLink(path + "/links/alias.txt",target:target)
        try files.writeNew(String(path.dropLast("/source".count)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8))
        try write {try self.router.save($0,capture,type:"source_capture")}
        XCTAssertNoThrow(try router.dbQueue.read {db in
            try StorageSnapshotAuthority.inventory(db,root:self.router.root,budget:StorageSnapshotBudget.production(),retainedExists:files.regularOrLinkExists)
        },"The complete capture must be backup-compatible before purge")
        let linkDirectory = router.root.appendingPathComponent(path + "/links")
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:linkDirectory.path)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:linkDirectory.path)}
        let done = try finish(purge(p,trash(p,t)))
        print("REVIEW_PARTIAL_RECEIPT " + (try jsonString(done)))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/links/alias.txt"))
        print("REVIEW_TARGET_EXISTS \(try files.regularOrLinkExists(path + "/target.txt"))")
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("post-partial-purge-backup").path]))
    }
    func testReviewerReferencedCapturedLinkKeepsItsTarget() throws {
        let (p,t,_,_) = try fixture(), cid = uuid(), pid = p["id"] as! String
        let path = "source-captures/" + pid + "/" + cid + "/source"
        let bytes = Data("shared via link".utf8), target = "target.txt"
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":t["id"]!,"revision":1,"snapshot_path":path,"files":[
            ["path":"target.txt","kind":"file","sha256":ChecklistCore.hash(bytes),"size":bytes.count],
            ["path":"alias.txt","kind":"symlink","target":target,"sha256":ChecklistCore.hash(Data(target.utf8))]]]
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/target.txt",bytes:bytes);try files.writeLink(path + "/alias.txt",target:target)
        try files.writeNew(String(path.dropLast("/source".count)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8))
        try write {try self.router.save($0,capture,type:"source_capture")}
        XCTAssertNoThrow(try router.dbQueue.read {db in
            try StorageSnapshotAuthority.inventory(db,root:self.router.root,budget:StorageSnapshotBudget.production(),retainedExists:files.regularOrLinkExists)
        },"The complete capture must be backup-compatible before purge")
        _ = try call("task_create",["project_id":pid,"title":"Other link consumer","brief":path + "/alias.txt"])
        let done = try finish(purge(p,trash(p,t)))
        print("REVIEW_SHARED_LINK_RECEIPT " + (try jsonString(done)))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/alias.txt"))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/target.txt"),"A remaining record's captured link still needs its target")
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("post-shared-link-backup").path]))
    }
    func testReviewerSymlinkedParentNeverDeletesOutsideObject() throws {
        let (p,t,a,_) = try fixture()
        let external = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
        let bytes = Data("outside protected bytes".utf8), original = external.appendingPathComponent("victim.txt")
        try bytes.write(to:original)
        let relative = "objects/escape-" + uuid()
        try FileManager.default.createSymbolicLink(at:router.root.appendingPathComponent(relative),withDestinationURL:external)
        try write {db in
            var value = try self.router.record(db,a["id"] as! String,type:"attachment")
            value["path"] = relative + "/victim.txt";value["sha256"] = ChecklistCore.hash(bytes);value["size"] = bytes.count
            try self.router.save(db,self.router.revised(value),type:"attachment")
        }
        let done = try finish(purge(p,trash(p,t)))
        XCTAssertEqual(try Data(contentsOf:original),bytes)
        XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,0)
    }
    func testReviewerChangedOriginalIsRetainedAndReported() throws {
        let (p,t,a,_) = try fixture(), trashed = try trash(p,t), v = try preview(p,trashed)
        var input = params(p,trashed);input["preview_digest"] = v["digest"]!
        var result: JSON = [:];try write {db in result = try self.router.taskPurge(db,input,self.owner)}
        let changed = Data("changed original bytes".utf8)
        try changed.write(to:URL(fileURLWithPath:a["path"] as! String))
        let done = try finish(result)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:a["path"] as! String)),changed)
        XCTAssertEqual((done["summary"] as! JSON)["removed_count"] as? Int,0)
        XCTAssertTrue(((done["objects"] as! [JSON])[0]["reasons"] as? [String] ?? []).contains("CLEANUP_IDENTITY_CHANGED"))
    }
}
