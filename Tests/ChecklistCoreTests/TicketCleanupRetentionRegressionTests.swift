import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// A completed-backup template for deletion-engine tests. Its managed payloads
/// are independent immutable entries, so the real no-follow verifier still
/// checks every selected byte. Full snapshot/restore uses the real route below.
func ticketCleanupBackupTemplate(_ router: CommandRouter,objects: [JSON]) throws {
    let directory = router.root.appendingPathComponent("backups/template-" + uuid())
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let source = try StorageObjectFiles(root:router.root),copy = try StorageObjectFiles(root:directory)
    var entries: [JSON] = []
    for object in objects {
        guard let path = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value,(try? source.regularOrLinkExists(path)) == true else {continue}
        if let target = object["link_target"] as? String {try copy.writeLink("managed/" + path,target:target)}
        else {try copy.writeNew("managed/" + path,bytes:source.read(path,maximum:StorageSnapshotBudget.manifestByteLimit))}
        entries.append(["path":path,"sha256":sha,"size":size])
    }
    let manifestBytes = Data("completed-backup-template".utf8),manifest = ChecklistCore.hash(manifestBytes)
    try copy.writeNew("manifest.json",bytes:manifestBytes)
    let generation: JSON = ["state":"complete","objects":entries,"manifest_sha256":manifest,"summary":["path":directory.path,"manifest_sha256":manifest,"verification":"manifest_database_managed_files"]]
    try router.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + uuid(),try jsonString(generation)])}
}

extension PurgeByteDeletionTests {
    func testP321PurgedLiveOnlyBytesResumeAfterBackupWhileKeepOriginalStays() throws {
        for keep in [false,true] {
            let (project,task,attachment,_) = try fixture()
            if keep {_ = try call("attachment_update",["project_id":project["id"]!,"attachment_id":attachment["id"]!,"expected_revision":attachment["revision"]!,"action":"keep_original"])}
            let trashed = try trash(project,task)
            let preview = try call("task_purge_preview",params(project,trashed))
            var input = params(project,trashed);input["preview_digest"] = preview["digest"]!
            let result = try call("task_purge",input)
            XCTAssertNil((result["byte_deletion"] as? JSON)?["cleanup_backup_generation_row"])
            XCTAssertFalse(try jsonString(result).contains("cleanup_backup_generation_row"))
            XCTAssertEqual(try receipt(result)["state"] as? String,"completed")
            XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
            XCTAssertNil(try router.readers!.read {try router.prepareTicketObjectDeletion($0)})
            _ = try call("backup_create",["path":directory.appendingPathComponent("p321-purged-" + uuid()).path])
            try pumpByteDeletion()
            let completed = try finish(result)
            XCTAssertNil(completed["cleanup_backup_generation_row"])
            XCTAssertEqual(FileManager.default.fileExists(atPath:attachment["path"] as! String),keep)
            XCTAssertEqual((completed["summary"] as! JSON)["removed_count"] as? Int,keep ? 0 : 1)
            XCTAssertNil(try router.readers!.read {try router.prepareTicketObjectDeletion($0)})
        }
    }

    func testP321LegacyCompletedPurgeGetsOneFreshOwnershipCheck() throws {
        let (project,task,attachment,_) = try fixture()
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-legacy-purge").path])
        let trashed = try trash(project,task),preview = try call("task_purge_preview",params(project,trashed))
        var input = params(project,trashed);input["preview_digest"] = preview["digest"]!
        var result: JSON = [:]
        try write {db in
            result = try self.router.taskPurge(db,input,self.owner)
            var job = try self.router.record(db,result["byte_deletion_receipt_id"] as! String,type:"storage_job")
            var objects = job["objects"] as! [JSON]
            for index in objects.indices {objects[index]["state"] = "retained";objects[index]["reasons"] = ["backup_authority","remaining_record"]}
            job["objects"] = objects;job["state"] = "completed";job["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
            job.removeValue(forKey:"cleanup_policy_version");job.removeValue(forKey:"cleanup_backup_generation_row")
            try self.router.save(db,self.router.revised(job),type:"storage_job")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertNotNil(try router.nextArchiveCleanupDeadline())
        try pumpByteDeletion();let completed = try finish(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertEqual((completed["summary"] as! JSON)["removed_count"] as? Int,1)
        XCTAssertEqual(completed["cleanup_policy_version"] as? Int,2)
        XCTAssertNil(completed["cleanup_backup_generation_row"])
        XCTAssertNil(try router.readers!.read {try router.prepareTicketObjectDeletion($0)})
    }
}

extension TicketLifecycleCleanupTests {
    func testP321FailedManifestIsCachedPerBatchWithoutPoisoningGoodPayloads() throws {
        let backup = directory.appendingPathComponent("p321-manifest-cache")
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
        let files = try StorageObjectFiles(root:backup),manifest = Data("fixture manifest".utf8),bytes = Data("payload".utf8)
        try files.writeNew("manifest.json",bytes:manifest);try files.writeNew("managed/objects/good.txt",bytes:bytes)
        let sha = ChecklistCore.hash(bytes),size = Int64(bytes.count)
        let missing: JSON = ["relative_path":"objects/missing.txt","kind":"file","sha256":sha,"size":size]
        let good: JSON = ["relative_path":"objects/good.txt","kind":"file","sha256":sha,"size":size]
        let missingKey = StorageBackupRetentionIndex.key(path:"objects/missing.txt",sha:sha,size:size),goodKey = StorageBackupRetentionIndex.key(path:"objects/good.txt",sha:sha,size:size)
        let paths = [missingKey:[backup],goodKey:[backup]]
        var bad = StorageBackupRetentionIndex(originals:[],root:router.root,copyPaths:paths,copyManifests:[backup.path:ChecklistCore.hash(Data("wrong manifest".utf8))])
        var reads = 0
        bad.verifyCopy(for:missing,check:{reads += 1})
        let firstReads = reads
        XCTAssertGreaterThan(firstReads,0)
        bad.verifyCopy(for:good,check:{reads += 1})
        XCTAssertEqual(reads,firstReads);XCTAssertEqual(bad.unavailableManifests,[backup.path]);XCTAssertTrue(bad.verifiedCopies.isEmpty)
        var valid = StorageBackupRetentionIndex(originals:[],root:router.root,copyPaths:paths,copyManifests:[backup.path:ChecklistCore.hash(manifest)])
        valid.verifyCopy(for:missing)
        XCTAssertTrue(valid.unavailableManifests.isEmpty)
        valid.verifyCopy(for:good)
        XCTAssertEqual(valid.verifiedCopies[goodKey]?.isCurrent(),true)
    }

    func testP321CompletedBackupReleasesLiveBytesAndRestoresExactly() throws {
        let (project,task,attachment) = try fixture()
        let original = URL(fileURLWithPath:attachment["path"] as! String)
        let bytes = try Data(contentsOf:original)
        let backup = directory.appendingPathComponent("p321-backup")
        _ = try call("backup_create",["path":backup.path])
        let manifest = try Data(contentsOf:backup.appendingPathComponent("manifest.json"))
        _ = try configure(project);try pass();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
        XCTAssertFalse(bool(try read(task),"purged"))
        let saved = try router.dbQueue.read {try router.record($0,attachment["id"] as! String,type:"attachment")}
        XCTAssertEqual(saved["availability"] as? String,"original_cleaned")
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("manifest.json")),manifest)
        let preview = try call("restore_preview",["path":backup.path])
        let restored = try call("restore_create",["path":backup.path,"manifest_sha256":preview["manifest_sha256"]!])
        let restoredRoot = URL(fileURLWithPath:restored["path"] as! String)
        let relative = try XCTUnwrap(ManagedPaths.relative(original.path,family:"objects",root:router.root))
        XCTAssertEqual(try Data(contentsOf:restoredRoot.appendingPathComponent(relative)),bytes)
        XCTAssertEqual((try receipts(project).first?["summary"] as? JSON)?["removed_count"] as? Int,1)
    }

    func testP321LiveOnlyBytesWaitForACompletedBackup() throws {
        let (project,_,attachment) = try fixture(backed:false)
        _ = try configure(project);try router.runTicketLifecycleCleanup();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
        XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["backup_required"])
        XCTAssertEqual(summary["removed_count"] as? Int,0)
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-later-backup").path])
        try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(86401));try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:attachment["path"] as! String))
    }

    func testP321OtherLiveRecordStillRetainsBackedBytes() throws {
        let (project,_,attachment) = try fixture()
        let (otherProject,other,_) = try fixture(category:"queued")
        try write {db in
            var shared = try self.router.record(db,attachment["id"] as! String,type:"attachment")
            shared["id"] = uuid();shared["task_id"] = other["id"]!;shared["project_id"] = otherProject["id"]!
            try self.router.save(db,shared,type:"attachment")
        }
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-shared-backup").path])
        _ = try configure(project);try pass();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
        XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["remaining_record"])
        XCTAssertEqual(summary["removed_count"] as? Int,0)
    }

    func testP321MissingAndChangedBackupPayloadsRetainTheLiveOriginal() throws {
        for failure in ["payload_missing","payload_changed","manifest_missing","manifest_changed"] {
            let (project,_,attachment) = try fixture(backed:false)
            let backup = directory.appendingPathComponent("p321-unavailable-" + uuid())
            _ = try call("backup_create",["path":backup.path])
            _ = try configure(project);try router.runTicketLifecycleCleanup()
            let relative = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
            let retained = backup.appendingPathComponent(failure.hasPrefix("manifest") ? "manifest.json" : "managed/" + relative)
            if failure.hasSuffix("changed") {try Data("wrong evidence".utf8).write(to:retained)}
            else {try FileManager.default.removeItem(at:retained)}
            try finish()
            XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
            let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
            XCTAssertEqual(summary["removed_count"] as? Int,0)
            XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["backup_copy_unavailable"])
        }
    }

    func testP321BackupHardLinkSurvivesLiveUnlinkWithExactBytes() throws {
        let (project,_,attachment) = try fixture(backed:false)
        let original = URL(fileURLWithPath:attachment["path"] as! String),bytes = try Data(contentsOf:original)
        let backup = directory.appendingPathComponent("p321-hardlink")
        _ = try call("backup_create",["path":backup.path])
        let relative = try XCTUnwrap(ManagedPaths.relative(original.path,family:"objects",root:router.root))
        let retained = backup.appendingPathComponent("managed/" + relative)
        try FileManager.default.removeItem(at:retained)
        try FileManager.default.linkItem(at:original,to:retained)
        _ = try configure(project);try router.runTicketLifecycleCleanup();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
        XCTAssertEqual(try Data(contentsOf:retained),bytes)
        XCTAssertNoThrow(try call("restore_preview",["path":backup.path]))
    }

    func testP321BackupReplacementAfterVerificationFailsClosedAtUnlink() throws {
        let (project,_,attachment) = try fixture(backed:false)
        let backup = directory.appendingPathComponent("p321-replaced")
        _ = try call("backup_create",["path":backup.path])
        _ = try configure(project);try router.runTicketLifecycleCleanup()
        let relative = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let retained = backup.appendingPathComponent("managed/" + relative)
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try FileManager.default.removeItem(at:retained)
            try Data("replaced bytes".utf8).write(to:retained)
            return prepared
        }) {db,permit,prepared in try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
        XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["backup_copy_unavailable"])
        XCTAssertEqual(summary["removed_count"] as? Int,0)
    }

    func testP321DeletionPreparationAmortizesSixteenObjectsInOneObservation() throws {
        let (project,task,attachment) = try fixture(backed:false),files = try StorageObjectFiles(root:router.root)
        try write {db in
            for index in 0..<15 {
                let bytes = Data("batch object \(index)".utf8),id = uuid(),path = "objects/" + id + ".txt"
                try files.writeNew(path,bytes:bytes)
                var value = attachment
                value["id"] = id;value["artifact_id"] = id;value["path"] = path;value["sha256"] = ChecklistCore.hash(bytes);value["size"] = bytes.count
                try self.router.save(db,value,type:"attachment")
            }
        }
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-batch").path])
        _ = try configure(project);try router.runTicketLifecycleCleanup()
        let prepared = try XCTUnwrap(router.readers!.read {try router.prepareTicketObjectDeletion($0)})
        XCTAssertEqual(prepared.candidatePaths.count,16)
        XCTAssertEqual(prepared.verifications.count,16)
        XCTAssertFalse(bool(try read(task),"purged"))
        try finish()
        let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
        XCTAssertEqual(summary["removed_count"] as? Int,16)
    }

    func testP321OwnHistoricalBatchPointersDoNotHoldDoneEvidence() throws {
        let (project,task,attachment) = try fixture(backed:false),manifest = uuid()
        try write {db in
            try self.router.save(db,["id":manifest,"project_id":project["id"]!,"task_id":task["id"]!,"revision":1,"artifact_id":attachment["id"]!],type:"manifest")
            try self.router.save(db,["id":uuid(),"project_id":project["id"]!,"revision":1,"batch_id":uuid(),"attempt_ids":[manifest]],type:"batch_claim")
        }
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-historical").path])
        _ = try configure(project);try router.runTicketLifecycleCleanup();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertNoThrow(try router.dbQueue.read {try router.record($0,manifest,type:"manifest")})
    }

    func testP321ForeignTransitiveUseBeforeOrAfterAdmissionRetainsEvidence() throws {
        for late in [false,true] {
            let (project,task,attachment) = try fixture(backed:false),manifest = uuid()
            let other = try call("task_create",["project_id":project["id"]!,"title":"Independent live byte consumer"])
            try write {db in try self.router.save(db,["id":manifest,"project_id":project["id"]!,"task_id":task["id"]!,"revision":1,"artifact_id":attachment["id"]!],type:"manifest")}
            func addForeignReference() throws {
                try write {db in try self.router.save(db,["id":uuid(),"project_id":project["id"]!,"task_id":other["id"]!,"revision":1,"manifest_id":manifest],type:"manifest")}
            }
            if !late {try addForeignReference()}
            _ = try call("backup_create",["path":directory.appendingPathComponent("p321-transitive-" + uuid()).path])
            _ = try configure(project);try router.runTicketLifecycleCleanup()
            if late {try addForeignReference()}
            try finish()
            XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
            let summary = try XCTUnwrap(receipts(project).first?["summary"] as? JSON)
            XCTAssertEqual(summary["removed_count"] as? Int,0)
            XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["remaining_record"])
        }
    }

    func testP321LegacyPendingJobSettlesThenImmediatelyReadmitsAFreshPlan() throws {
        let (project,_,attachment) = try fixture(backed:false)
        _ = try call("backup_create",["path":directory.appendingPathComponent("p321-legacy").path])
        _ = try configure(project);try router.runTicketLifecycleCleanup()
        try write {db in
            var job = try XCTUnwrap(self.router.records(db,type:"storage_job").first {$0["cause"] as? String == "done_evidence" && $0["task_id"] as? String == attachment["task_id"] as? String})
            job["owned_record_fingerprints"] = [:] as [String:String];job.removeValue(forKey:"cleanup_policy_version")
            try self.router.save(db,self.router.revised(job),type:"storage_job")
        }
        try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        let next = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + (project["id"] as! String)])}
        XCTAssertLessThanOrEqual(try XCTUnwrap(next.flatMap(Double.init)),Date().timeIntervalSince1970)
        let retries = try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:project["id"] as! String)}
        XCTAssertEqual(Set(retries.keys),[attachment["task_id"] as! String])
        try router.runTicketLifecycleCleanup();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertTrue(try receipts(project).contains {($0["summary"] as? JSON)?["removed_count"] as? Int == 1})
    }
}
