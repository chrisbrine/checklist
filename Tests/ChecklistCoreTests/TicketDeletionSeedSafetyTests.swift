import ChecklistTestSupport
import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    /// A copied pending receipt keeps the original stored_path as history. The
    /// actual byte turn must use only its instance-local relative descriptor.
    private func seededDeletionSafety(missing: Bool = false,symlink: Bool = false,trash: Bool = false) throws {
        let source = directory.appendingPathComponent("source-root")
        let relative = "objects/seeded-receipt/payload.txt",bytes = Data("local copied payload".utf8)
        let foreignBytes = Data("foreign original must never supply verification bytes".utf8)
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let sourceFiles = try StorageObjectFiles(root:source)
        try sourceFiles.writeNew(relative,bytes:foreignBytes)
        let original = source.appendingPathComponent(relative)
        var before = stat();XCTAssertEqual(lstat(original.path,&before),0)
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(relative,bytes:bytes)
        let object: JSON = ["stored_path":original.path,"relative_path":relative,"kind":"file",
            "representation":"original","owner_ids":[uuid()],"sha256":ChecklistCore.hash(bytes),"size":Int64(bytes.count),"state":"pending"]
        // Independent backup bytes authorize a real deletion, rather than a hold
        // that could hide accidental use of the foreign absolute descriptor.
        try ticketCleanupBackupTemplate(router,objects:[object])
        if missing {
            try FileManager.default.moveItem(at:router.root.appendingPathComponent(relative),to:router.root.appendingPathComponent("held-local-payload"))
        }
        if symlink {
            try FileManager.default.moveItem(at:router.root.appendingPathComponent("objects/seeded-receipt"),to:router.root.appendingPathComponent("held-local-directory"))
            try FileManager.default.createSymbolicLink(at:router.root.appendingPathComponent("objects/seeded-receipt"),withDestinationURL:source.appendingPathComponent("objects/seeded-receipt"))
        }
        var candidate = object
        if trash {
            let localTrash = router.root.appendingPathComponent("fixture-trash")
            try FileManager.default.createDirectory(at:localTrash,withIntermediateDirectories:true)
            router.ticketCleanupTrashRoot = localTrash;candidate["disposal"] = "trash"
        }
        let project = try router.dbQueue.read {try XCTUnwrap(self.router.records($0,type:"project").first)}
        let id = uuid()
        let receipt: JSON = ["id":id,"project_id":project["id"]!,"task_id":uuid(),"kind":"ticket_object_delete",
            "cause":"task_purge","state":"pending","revision":1,"created_at":now(),"cleanup_policy_version":2,
            "objects":[candidate],"summary":CommandRouter.ticketObjectDeletionSummary([candidate])]
        try write {db in try self.router.save(db,receipt,type:"storage_job")}
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let actual = try router.dbQueue.read {try self.router.record($0,id,type:"storage_job")}
        let outcome = try XCTUnwrap((actual["objects"] as? [JSON])?.first)
        XCTAssertEqual(outcome["stored_path"] as? String,original.path,"No rewrite is needed to make provenance inert")
        if symlink {XCTAssertNotEqual(outcome["state"] as? String,"removed")}
        else if missing {XCTAssertEqual(outcome["state"] as? String,"already_missing")}
        else {
            XCTAssertEqual(outcome["state"] as? String,"removed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:router.root.appendingPathComponent(relative).path))
            if trash {
                let target = try XCTUnwrap(outcome["trash_path"] as? String)
                XCTAssertTrue(target.hasPrefix(router.root.path + "/fixture-trash/"))
                XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:target)),bytes)
            }
        }
        var after = stat();XCTAssertEqual(lstat(original.path,&after),0)
        XCTAssertEqual(before.st_dev,after.st_dev);XCTAssertEqual(before.st_ino,after.st_ino)
        XCTAssertEqual(before.st_mtimespec.tv_sec,after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec,after.st_mtimespec.tv_nsec)
        XCTAssertEqual(before.st_ctimespec.tv_sec,after.st_ctimespec.tv_sec)
        XCTAssertEqual(before.st_ctimespec.tv_nsec,after.st_ctimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf:original),foreignBytes)
    }

    private func copiedTrashSafety(binding: String?,missing: Bool = false,tampered: Bool = false) throws {
        let foreign = directory.appendingPathComponent("foreign-trash-store")
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
        let id = uuid(),relative = "objects/foreign-trash/payload.txt",bytes = Data("instance-local bytes".utf8)
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(relative,bytes:bytes)
        var object: JSON = ["relative_path":relative,"stored_path":foreign.appendingPathComponent(relative).path,
            "kind":"file","representation":"original","owner_ids":[uuid()],"disposal":"trash",
            "sha256":ChecklistCore.hash(bytes),"size":Int64(bytes.count),"state":"pending"]
        try ticketCleanupBackupTemplate(router,objects:[object])
        if missing {try FileManager.default.moveItem(at:router.root.appendingPathComponent(relative),to:router.root.appendingPathComponent("held-local-payload"))}
        let folder = foreign.appendingPathComponent("Checklist-media-" + ChecklistCore.hash(Data((router.incarnation + ":" + id).utf8)))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target = folder.appendingPathComponent(ChecklistCore.hash(Data(relative.utf8)) + "-payload.txt")
        let foreignBytes = Data("foreign Trash sentinel with different bytes".utf8)
        try foreignBytes.write(to:target)
        let marker = folder.appendingPathComponent("cleanup-owner.json")
        let markerBytes = Data((try jsonString(["receipt_id":id,"source_root":foreign.path,"incarnation":router.incarnation])).utf8)
        try markerBytes.write(to:marker)
        var before = stat();XCTAssertEqual(lstat(target.path,&before),0)
        object["trash_path"] = tampered ? foreign.appendingPathComponent("different-target.txt").path : target.path
        let project = try router.dbQueue.read {try XCTUnwrap(self.router.records($0,type:"project").first)}
        var receipt: JSON = ["id":id,"project_id":project["id"]!,"task_id":uuid(),"kind":"ticket_object_delete",
            "cause":"task_purge","state":"pending","revision":1,"cleanup_policy_version":2,
            "media_trash_directory":folder.path,"objects":[object],"summary":CommandRouter.ticketObjectDeletionSummary([object])]
        if let binding {receipt["media_trash_source_root"] = binding == "current" ? router.root.path : foreign.path}
        try write {db in try self.router.save(db,receipt,type:"storage_job")}
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let actual = try router.dbQueue.read {try self.router.record($0,id,type:"storage_job")}
        let result = try XCTUnwrap((actual["objects"] as? [JSON])?.first)
        XCTAssertEqual(actual["state"] as? String,"completed")
        XCTAssertEqual(result["state"] as? String,"retained")
        XCTAssertEqual(strings(result,"reasons"),[tampered ? "trash_intent_invalid" : "trash_source_root_unproven"])
        XCTAssertNil(result["last_failure"],"No outside verification was attempted before the authority hold")
        XCTAssertEqual(FileManager.default.fileExists(atPath:router.root.appendingPathComponent(relative).path),!missing)
        var after = stat();XCTAssertEqual(lstat(target.path,&after),0)
        XCTAssertEqual(before.st_ino,after.st_ino);XCTAssertEqual(before.st_mtimespec.tv_sec,after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec,after.st_mtimespec.tv_nsec)
        XCTAssertEqual(before.st_ctimespec.tv_sec,after.st_ctimespec.tv_sec);XCTAssertEqual(before.st_ctimespec.tv_nsec,after.st_ctimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf:target),foreignBytes);XCTAssertEqual(try Data(contentsOf:marker),markerBytes)
    }

    func testSeededPendingReceiptDeletesOnlyInstanceLocalRelativePath() throws {try seededDeletionSafety()}
    func testSeededPendingTrashReceiptMovesOnlyInstanceLocalRelativePath() throws {try seededDeletionSafety(trash:true)}
    func testSeededPendingReceiptNeverFallsBackToOriginalWhenLocalFileIsMissing() throws {try seededDeletionSafety(missing:true)}
    func testSeededPendingReceiptNeverFollowsLocalSymlinkToOriginal() throws {try seededDeletionSafety(symlink:true)}
    func testSeededLegacyTrashReceiptSettlesWithoutOpeningOldDestination() throws {try copiedTrashSafety(binding:nil)}
    func testSeededForeignTrashReceiptSettlesBeforeMissingLocalFallback() throws {try copiedTrashSafety(binding:"foreign",missing:true)}
    func testBoundTrashReceiptValidatesExactTargetBeforeMissingLocalFallback() throws {try copiedTrashSafety(binding:"current",missing:true,tampered:true)}
}
