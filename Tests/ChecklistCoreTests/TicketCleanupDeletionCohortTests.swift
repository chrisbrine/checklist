import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    private func deletionCohortFixture(_ counts: [Int]) throws -> [JSON] {
        let workspace = directory.appendingPathComponent("cohort-workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Deletion cohort template","key_prefix":"DC","root_path":workspace.path])
        let files = try StorageObjectFiles(root:router.root)
        var receipts: [JSON] = [],all: [JSON] = []
        for (job,count) in counts.enumerated() {
            var objects: [JSON] = []
            for item in 0..<count {
                let bytes = Data("cohort payload \(job):\(item)".utf8),path = "objects/" + uuid() + ".txt"
                try files.writeNew(path,bytes:bytes)
                objects.append(["relative_path":path,"stored_path":router.root.appendingPathComponent(path).path,"kind":"file","representation":"original","owner_ids":[uuid()],"sha256":ChecklistCore.hash(bytes),"size":Int64(bytes.count),"state":"pending"])
            }
            let receipt: JSON = ["id":uuid(),"project_id":project["id"]!,"task_id":uuid(),"kind":"ticket_object_delete","cause":"task_purge","state":"pending","revision":1,"created_at":now(),"cleanup_policy_version":2,"objects":objects,"summary":CommandRouter.ticketObjectDeletionSummary(objects)]
            receipts.append(receipt);all += objects
        }
        try write {db in for receipt in receipts {try self.router.save(db,receipt,type:"storage_job")}}
        try ticketCleanupBackupTemplate(router,objects:all)
        return receipts
    }

    private func deletionCohortReceipt(_ receipt: JSON) throws -> JSON {
        try router.dbQueue.read {try self.router.record($0,receipt["id"] as! String,type:"storage_job")}
    }

    /// Exercise the real preparation, journal, continuation and byte executor,
    /// with deterministic injection points between their public boundaries.
    private func deletionCohortPass(afterPreparation: ((TicketCleanupDeletionCohort) throws -> Void)? = nil,afterCommit: ((Database,TicketCleanupDeletionCohort) throws -> Void)? = nil,observeSQL: ((String) -> Void)? = nil) throws -> TicketCleanupDeletionCohort? {
        var observed: TicketCleanupDeletionCohort?
        try router.withTicketCleanupPreparation({db in
            if let observeSQL {db.trace {if case .statement(let statement) = $0 {observeSQL(statement.sql)}}}
            defer {db.trace(nil)}
            let cohort = try self.router.prepareTicketObjectDeletionCohort(db)
            observed = cohort
            if let cohort {try afterPreparation?(cohort)}
            return cohort
        },continuing:{db,cohort in
            if let observeSQL {db.trace {if case .statement(let statement) = $0 {observeSQL(statement.sql)}}}
            defer {db.trace(nil)}
            return try self.router.continueTicketObjectDeletionCohort(db,cohort:cohort)
        }) {db,permit,cohort in
            guard let prepared = cohort.current else {return}
            guard cohort.turns < 64 else {throw CoreError("FIXTURE_LIMIT","The synthetic byte cohort did not make bounded progress.")}
            let outcome = try TicketCleanupChanges.deletionAccounting(db) {
                try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)
            }
            cohort.turns += 1
            if (outcome["objects"] as? [JSON] ?? []).contains(where: {$0["state"] as? String == "pending"}) {
                cohort.entries[cohort.index] = .init(fence:prepared.fence,receipt:outcome,reactivated:false,backupGenerationRow:prepared.backupGenerationRow,references:prepared.references,backup:nil,mediaAuthorityComplete:prepared.mediaAuthorityComplete,candidatePaths:[],verifications:[:],verificationFailures:[:])
            } else {cohort.index += 1;cohort.current = nil}
            try afterCommit?(db,cohort)
        }
        return observed
    }

    func testDeletionCohortProductionCallDrainsMultipleIndependentJobs() throws {
        let receipts = try deletionCohortFixture([1,2,1])
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        for receipt in receipts {
            let actual = try deletionCohortReceipt(receipt)
            XCTAssertEqual(actual["state"] as? String,"completed")
            XCTAssertEqual((actual["summary"] as? JSON)?["removed_count"] as? Int,(receipt["objects"] as! [JSON]).count)
            for object in receipt["objects"] as! [JSON] {XCTAssertFalse(FileManager.default.fileExists(atPath:object["stored_path"] as! String))}
        }
        XCTAssertFalse(try router.runTicketObjectDeletionCohort(),"Settled jobs do not create another observation")
    }

    func testDeletionCohortSharesObservationAndManifestAcrossMoreThan256Descriptors() throws {
        let receipts = try deletionCohortFixture([257])
        var corpus = 0,media = 0,generations = 0,manifests = Set<ObjectIdentifier>(),peakPinned = 0
        let cohort = try XCTUnwrap(deletionCohortPass(afterCommit:{_,cohort in
            peakPinned = max(peakPinned,cohort.backup?.verifiedCopies.count ?? 0)
            for manifest in cohort.backup?.verifiedManifests.values ?? Dictionary<String,TicketObjectRemovalVerification>().values {manifests.insert(ObjectIdentifier(manifest))}
        },observeSQL:{sql in
            if sql.contains("FROM records ORDER BY rowid") {corpus += 1}
            if sql.contains("FROM records WHERE type IN (") {media += 1}
            if sql.contains("octet_length(value) AS bytes") {generations += 1}
        }))
        XCTAssertGreaterThan(cohort.turns,2,"Writer chunks and the second candidate admission reuse the initial observation")
        XCTAssertEqual(corpus,1);XCTAssertEqual(media,1);XCTAssertEqual(generations,1)
        XCTAssertEqual(manifests.count,1,"A single pinned manifest survives candidate continuations without a new hash")
        XCTAssertLessThanOrEqual(peakPinned,256)
        let actual = try deletionCohortReceipt(receipts[0])
        XCTAssertEqual(actual["state"] as? String,"completed");XCTAssertEqual((actual["summary"] as? JSON)?["removed_count"] as? Int,257)
    }

    func testDeletionCohortLateReferenceRefusesOnlyItsReceiptAndContinuesSibling() throws {
        let receipts = try deletionCohortFixture([1,1]),first = receipts[0],second = receipts[1]
        let path = (first["objects"] as! [JSON])[0]["relative_path"] as! String
        let cohort = try XCTUnwrap(deletionCohortPass(afterPreparation:{_ in
            try self.write {db in try self.router.save(db,["id":uuid(),"project_id":first["project_id"]!,"revision":1,"body":"Late foreign byte reference","path":path],type:"message")}
        }))
        XCTAssertNotNil(cohort.refused[first["id"] as! String]);XCTAssertNil(cohort.refused[second["id"] as! String])
        XCTAssertEqual(try deletionCohortReceipt(first)["state"] as? String,"pending")
        XCTAssertEqual((try deletionCohortReceipt(second)["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:router.root.appendingPathComponent(path).path))
    }

    func testDeletionCohortGenerationMutationFencesRemainingContinuationAndFreshPassRebuilds() throws {
        let receipts = try deletionCohortFixture([257]),receipt = receipts[0]
        var mutated = false
        let cohort = try XCTUnwrap(deletionCohortPass(afterCommit:{db,_ in
            guard !mutated else {return};mutated = true
            try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.fixture_change',1) WHERE key GLOB 'backup-generation:*'")
        }))
        XCTAssertTrue(mutated);XCTAssertTrue(cohort.refused[receipt["id"] as! String]?.contains("storage metadata") == true)
        let partial = try deletionCohortReceipt(receipt),summary = partial["summary"] as! JSON
        XCTAssertGreaterThan(summary["removed_count"] as? Int ?? 0,0)
        XCTAssertGreaterThan(summary["pending_count"] as? Int ?? 0,0)
        try expireCleanupBackoff()
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual((try deletionCohortReceipt(receipt)["summary"] as? JSON)?["removed_count"] as? Int,257)
    }

    func testDeletionCohortManifestReplacementWinsAtUnlinkAndNewPassUsesFreshBackup() throws {
        let receipt = try deletionCohortFixture([1])[0]
        _ = try deletionCohortPass(afterPreparation:{cohort in
            let path = try XCTUnwrap(cohort.backup?.copyManifests.keys.first)
            try Data("replaced backup manifest".utf8).write(to:URL(fileURLWithPath:path).appendingPathComponent("manifest.json"),options:.atomic)
        })
        let retained = try deletionCohortReceipt(receipt),objects = retained["objects"] as! [JSON]
        XCTAssertEqual(objects[0]["state"] as? String,"retained")
        XCTAssertTrue((objects[0]["reasons"] as? [String] ?? []).contains("backup_copy_unavailable"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:objects[0]["stored_path"] as! String))
        try ticketCleanupBackupTemplate(router,objects:objects)
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual((try deletionCohortReceipt(receipt)["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:objects[0]["stored_path"] as! String))
    }

    func testDeletionCohortOversizedFirstReceiptDoesNotStarveBoundedSibling() throws {
        let receipts = try deletionCohortFixture([1,1]),large = receipts[0],small = receipts[1]
        try write {db in
            var value = large;value["padding"] = String(repeating:"x",count:TicketCleanupDeletionCohort.descriptorByteLimit+1)
            try self.router.save(db,self.router.revised(value),type:"storage_job")
        }
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual(try deletionCohortReceipt(large)["state"] as? String,"pending")
        XCTAssertEqual((try deletionCohortReceipt(small)["summary"] as? JSON)?["removed_count"] as? Int,1)
    }

    func testDeletionCohortFailedOutcomeStopsOneReceiptUntilNextCallWhileSiblingProgresses() throws {
        let receipts = try deletionCohortFixture([1,1]),first = receipts[0],sibling = receipts[1]
        let id = first["id"] as! String,path = (first["objects"] as! [JSON])[0]["stored_path"] as! String
        try router.dbQueue.write {db in
            try db.execute(sql:"CREATE TRIGGER cohort_outcome_failure BEFORE UPDATE ON records WHEN NEW.id='\(id)' AND json_extract(NEW.data,'$.state')='completed' BEGIN SELECT RAISE(ABORT,'synthetic cohort outcome boundary'); END")
        }
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let failed = try deletionCohortReceipt(first),objects = failed["objects"] as! [JSON]
        XCTAssertFalse(FileManager.default.fileExists(atPath:path),"The first unlink committed at the filesystem boundary")
        XCTAssertEqual(failed["state"] as? String,"pending")
        XCTAssertEqual(objects[0]["failures"] as? Int,1,"A failed outcome gets one attempt per production call")
        XCTAssertEqual(objects[0]["state"] as? String,"pending")
        XCTAssertEqual((try deletionCohortReceipt(sibling)["summary"] as? JSON)?["removed_count"] as? Int,1,"The failed receipt does not stall a valid sibling")
        try router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cohort_outcome_failure")}
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let resumed = try deletionCohortReceipt(first),summary = resumed["summary"] as! JSON
        XCTAssertEqual(resumed["state"] as? String,"completed")
        XCTAssertEqual(summary["already_missing_count"] as? Int,1)
        XCTAssertEqual(summary["removed_count"] as? Int,0,"The rolled-back outcome never invents a committed removal receipt")
        XCTAssertEqual((resumed["objects"] as! [JSON])[0]["failures"] as? Int,1)
    }
    func testDeletionCohortBackupProofExcludesAlreadyRetainedDescriptors() throws {
        let receipt = try deletionCohortFixture([2])[0]
        var objects = receipt["objects"] as! [JSON]
        objects[1]["state"] = "retained";objects[1]["reasons"] = ["keep_original"]
        try write {db in
            var updated = receipt;updated["objects"] = objects
            updated["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
            try self.router.save(db,self.router.revised(updated),type:"storage_job")
        }
        let cohort = try XCTUnwrap(deletionCohortPass(afterPreparation:{cohort in
            let backup = try XCTUnwrap(cohort.backup)
            XCTAssertEqual(backup.originals.count,1,"Only still-pending objects consume the cohort backup proof budget")
            XCTAssertEqual(cohort.entries[0].fence.inventory.holdDigests.count,2,"Retained descriptors still participate in the independent authority fence")
        }))
        XCTAssertEqual(cohort.turns,1)
        let result = try deletionCohortReceipt(receipt),summary = result["summary"] as! JSON
        XCTAssertEqual(summary["removed_count"] as? Int,1);XCTAssertEqual(summary["retained_count"] as? Int,1)
        XCTAssertEqual((result["objects"] as! [JSON])[1]["reasons"] as? [String],["keep_original"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:objects[1]["stored_path"] as! String))
    }

}
