import ChecklistTestSupport
import Darwin
import GRDB
import XCTest
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    private func descriptorRetryReceipt(cause: String,state: String,reasons: [String],mixedPermanent: Bool = false) throws -> JSON {
        let project: JSON,taskID: String,taskRevision: Int
        if cause == "done_evidence" {
            let (actualProject,task,_) = try fixture(backed:false)
            _ = try configure(actualProject)
            project = actualProject;taskID = task["id"] as! String;taskRevision = int(task,"revision")
        } else {
            project = try router.dbQueue.read {try XCTUnwrap(self.router.records($0,type:"project").first)}
            taskID = uuid();taskRevision = 1
        }
        let files = try StorageObjectFiles(root:router.root)
        var objects: [JSON] = []
        for item in 0..<(mixedPermanent ? 2 : 1) {
            let bytes = Data("descriptor retry payload \(uuid())".utf8),path = "objects/" + uuid() + ".txt"
            try files.writeNew(path,bytes:bytes)
            objects.append(["relative_path":path,"stored_path":router.root.appendingPathComponent(path).path,
                            "kind":"file","representation":"original","owner_ids":[uuid()],
                            "sha256":ChecklistCore.hash(bytes),"size":Int64(bytes.count),"state":"retained",
                            "reasons":item == 0 ? reasons : reasons + ["keep_original"]])
        }
        let receipt: JSON = ["id":uuid(),"project_id":project["id"]!,"task_id":taskID,"task_revision":taskRevision,"kind":"ticket_object_delete",
                             "cause":cause,"state":state,"revision":1,"created_at":now(),"cleanup_policy_version":2,
                             "owned_record_fingerprints":[:] as [String:String],"objects":objects,
                             "summary":CommandRouter.ticketObjectDeletionSummary(objects)]
        try write {db in try self.router.save(db,receipt,type:"storage_job")}
        return receipt
    }

    private func descriptorRetryRead(_ receipt: JSON) throws -> JSON {
        try router.dbQueue.read {try self.router.record($0,receipt["id"] as! String,type:"storage_job")}
    }

    private func descriptorRetryReady(_ receipt: JSON) throws -> Bool {
        try router.dbQueue.read {db in
            try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE id=? AND (" + CommandRouter.ticketObjectDeletionReadySQL + "))",arguments:[receipt["id"] as! String]) ?? false
        }
    }

    /// Explicitly record the current generation so these fixtures cannot pass
    /// through the older new-backup retry condition by accident.
    private func descriptorRetryMarkCurrentGeneration(_ receipts: [JSON],copyRetrySeen: Bool = false) throws -> Int64 {
        try write {db in
            let generation = try self.router.ticketCleanupBackupGenerationRow(db)
            for receipt in receipts {
                let id = receipt["id"] as! String
                try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-backup-seen:" + id,String(generation)])
                if copyRetrySeen {try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?, '1')",arguments:["ticket-cleanup-copy-retry-seen:" + id])}
            }
        }
        return try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)}
    }

    func testP321DescriptorTransientVerifyPreservesCauseAndRetriesSameIndex() throws {
        let backup = directory.appendingPathComponent("descriptor-retry-backup")
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
        let files = try StorageObjectFiles(root:backup),manifest = Data("descriptor retry manifest".utf8),bytes = Data("descriptor retry payload".utf8)
        try files.writeNew("manifest.json",bytes:manifest)
        try files.writeNew("managed/objects/payload.txt",bytes:bytes)
        let sha = ChecklistCore.hash(bytes),size = Int64(bytes.count)
        let object: JSON = ["relative_path":"objects/payload.txt","kind":"file","sha256":sha,"size":size]
        let key = StorageBackupRetentionIndex.key(path:"objects/payload.txt",sha:sha,size:size)
        for code in [EMFILE,ENFILE,EINTR] {
            var index = StorageBackupRetentionIndex(originals:[key],root:router.root,copyPaths:[key:[backup]],copyManifests:[backup.path:ChecklistCore.hash(manifest)])
            var failures = 0
            index.verifyCopy(for:object,check:{
                failures += 1
                throw CoreError("CLEANUP_OBJECT_UNAVAILABLE","Synthetic resource failure.",details:["posix_errno":code])
            })
            XCTAssertGreaterThan(failures,0)
            XCTAssertNil(index.verifiedCopies[key])
            XCTAssertEqual(index.copyFailures[key],"backup_copy_unverified:POSIX_" + String(code))
            XCTAssertTrue(index.unavailableManifests.isEmpty,"A transient manifest read must remain retryable on this index")
            XCTAssertTrue(index.manifestFailures.isEmpty)
            index.verifyCopy(for:object)
            XCTAssertEqual(index.verifiedCopies[key]?.isCurrent(),true)
            XCTAssertNil(index.copyFailures[key],"Success clears the failed-copy observation")
            XCTAssertTrue(index.unavailableManifests.isEmpty)
        }
    }

    func testP321LegacyCopyHoldsRearmPendingAndCompletedReceiptsWithoutNewBackup() throws {
        var receipts: [JSON] = []
        for cause in ["task_purge","done_evidence"] {
            for state in ["pending","completed"] {
                receipts.append(try descriptorRetryReceipt(cause:cause,state:state,reasons:["backup_copy_unavailable"],mixedPermanent:true))
            }
        }
        try ticketCleanupBackupTemplate(router,objects:receipts.flatMap {$0["objects"] as! [JSON]})
        let generation = try descriptorRetryMarkCurrentGeneration(receipts)
        for receipt in receipts {XCTAssertTrue(try descriptorRetryReady(receipt))}
        // A byte cohort is project-scoped; each real Done fixture may own a
        // separate project, so admit each of this bounded fixture's projects.
        for _ in receipts {if try !router.runTicketObjectDeletionCohort() {break}}
        for receipt in receipts {
            let actual = try descriptorRetryRead(receipt),objects = actual["objects"] as! [JSON]
            XCTAssertEqual(actual["state"] as? String,"completed")
            XCTAssertEqual((actual["summary"] as? JSON)?["removed_count"] as? Int,1)
            XCTAssertEqual(objects[0]["state"] as? String,"removed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:objects[0]["stored_path"] as! String))
            XCTAssertEqual(objects[1]["state"] as? String,"retained")
            XCTAssertEqual(objects[1]["reasons"] as? [String],["backup_copy_unavailable","keep_original"],"Mixed permanent holds must stay unchanged")
            XCTAssertTrue(FileManager.default.fileExists(atPath:objects[1]["stored_path"] as! String))
            XCTAssertFalse(try descriptorRetryReady(actual))
            let seen = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-copy-retry-seen:" + (receipt["id"] as! String)])}
            XCTAssertEqual(seen,"1")
        }
        XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)},generation)
        XCTAssertFalse(try router.runTicketObjectDeletionCohort(),"The compatibility retry is one-shot without another cause")
    }

    func testP321CompletedTransientCopyHoldsAreReadyWithoutNewGenerationAndRemove() throws {
        let receipts = try [EMFILE,ENFILE,EINTR].enumerated().map { index,code in
            try descriptorRetryReceipt(cause:index == 1 ? "done_evidence" : "task_purge",state:"completed",reasons:["backup_copy_unverified:POSIX_" + String(code)])
        }
        try ticketCleanupBackupTemplate(router,objects:receipts.flatMap {$0["objects"] as! [JSON]})
        let generation = try descriptorRetryMarkCurrentGeneration(receipts,copyRetrySeen:true)
        for receipt in receipts {XCTAssertTrue(try descriptorRetryReady(receipt),"Transient errors ignore the already-seen backup generation")}
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        for receipt in receipts {
            let actual = try descriptorRetryRead(receipt)
            XCTAssertEqual((actual["summary"] as? JSON)?["removed_count"] as? Int,1)
            XCTAssertFalse(FileManager.default.fileExists(atPath:(actual["objects"] as! [JSON])[0]["stored_path"] as! String))
            XCTAssertFalse(try descriptorRetryReady(actual))
        }
        XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)},generation)
        XCTAssertFalse(try router.runTicketObjectDeletionCohort())
    }

    func testP321PersistentCopyFailureConsumesLegacyRetryWithoutReadinessSpin() throws {
        let receipt = try descriptorRetryReceipt(cause:"done_evidence",state:"completed",reasons:["backup_copy_unavailable"])
        let objects = receipt["objects"] as! [JSON]
        try ticketCleanupBackupTemplate(router,objects:objects)
        let generation = try descriptorRetryMarkCurrentGeneration([receipt])
        let object = objects[0],relative = object["relative_path"] as! String
        let key = StorageBackupRetentionIndex.key(path:relative,sha:object["sha256"] as! String,size:(object["size"] as! NSNumber).int64Value)
        let index = try cleanupLookup(objects).index
        let backup = try XCTUnwrap(index.cleanupLookup?.copies(for:key).first(where:{_ in true}))
        try Data("permanently corrupted copy".utf8).write(to:backup.appendingPathComponent("managed/" + relative),options:.atomic)
        XCTAssertTrue(try descriptorRetryReady(receipt))
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let actual = try descriptorRetryRead(receipt),retained = (actual["objects"] as! [JSON])[0]
        XCTAssertEqual(retained["state"] as? String,"retained")
        let reasons = retained["reasons"] as? [String] ?? []
        XCTAssertTrue(reasons.contains {$0.hasPrefix("backup_copy_unverified:")})
        XCTAssertFalse(reasons.contains(where:TicketCleanupCopyFailure.isTransient))
        XCTAssertFalse(reasons.contains("backup_copy_unavailable"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:object["stored_path"] as! String))
        XCTAssertFalse(try descriptorRetryReady(actual),"A persistent copy error must wait for new backup authority")
        XCTAssertFalse(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)},generation)
    }

    func testP321CopyRetryReadinessRequiresTriggerAndAllRetryableReasonsOnSameObject() throws {
        for (trigger,seen) in [("backup_copy_unverified:POSIX_24",true),("backup_copy_unavailable",false)] {
            var receipt = try descriptorRetryReceipt(cause:"task_purge",state:"completed",reasons:[trigger],mixedPermanent:true)
            var objects = receipt["objects"] as! [JSON]
            objects[0]["reasons"] = [trigger,"keep_original"]
            objects[1]["reasons"] = ["backup_required"]
            receipt["objects"] = objects
            receipt["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
            try write {db in try self.router.save(db,self.router.revised(receipt),type:"storage_job")}
            let generation = try descriptorRetryMarkCurrentGeneration([receipt],copyRetrySeen:seen)
            XCTAssertFalse(try descriptorRetryReady(receipt),"A retryable sibling cannot supply permission for the permanently held trigger object")
            XCTAssertFalse(try router.runTicketObjectDeletionCohort(),"Neither mixed holds nor a sibling awaiting a new backup may reactivate this completed receipt")
            let actual = try descriptorRetryRead(receipt),retained = actual["objects"] as! [JSON]
            XCTAssertEqual(retained[0]["reasons"] as? [String],[trigger,"keep_original"])
            XCTAssertEqual(retained[1]["reasons"] as? [String],["backup_required"])
            for object in retained {XCTAssertTrue(FileManager.default.fileExists(atPath:object["stored_path"] as! String))}
            XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)},generation)
        }
    }

    func testP321TransientCopyRetryPreservesSiblingAwaitingNewBackupGeneration() throws {
        var receipt = try descriptorRetryReceipt(cause:"task_purge",state:"completed",reasons:["backup_copy_unverified:POSIX_24"],mixedPermanent:true)
        var objects = receipt["objects"] as! [JSON]
        objects[1]["reasons"] = ["backup_required"]
        receipt["objects"] = objects
        receipt["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
        try write {db in try self.router.save(db,self.router.revised(receipt),type:"storage_job")}
        // Both independent copies already exist. Only the transient object's
        // reason permits another attempt at this already-observed generation.
        try ticketCleanupBackupTemplate(router,objects:objects)
        let generation = try descriptorRetryMarkCurrentGeneration([receipt],copyRetrySeen:true)
        XCTAssertTrue(try descriptorRetryReady(receipt))
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let actual = try descriptorRetryRead(receipt),outcomes = actual["objects"] as! [JSON]
        XCTAssertEqual(actual["state"] as? String,"completed")
        XCTAssertEqual(outcomes[0]["state"] as? String,"removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:outcomes[0]["stored_path"] as! String))
        XCTAssertEqual(outcomes[1]["state"] as? String,"retained")
        XCTAssertEqual(outcomes[1]["reasons"] as? [String],["backup_required"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:outcomes[1]["stored_path"] as! String))
        XCTAssertEqual((actual["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertEqual((actual["summary"] as? JSON)?["retained_count"] as? Int,1)
        XCTAssertFalse(try descriptorRetryReady(actual))
        XCTAssertFalse(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupBackupGenerationRow($0)},generation)
    }
}
