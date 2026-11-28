import ChecklistTestSupport
import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testMediaReceiptWithoutObjectsNeedsNoBackupGeneration() throws {
        let workspace = directory.appendingPathComponent("empty-media-receipt")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Empty media receipt fixture","key_prefix":"EM","root_path":workspace.path])
        let projectID = try XCTUnwrap(project["id"] as? String)
        var id = ""
        try write {db in
            var backupQueries = 0
            db.trace {event in
                if case .statement(let statement) = event,statement.sql.contains("backup-generation:*") {backupQueries += 1}
            }
            defer {db.trace(nil)}
            let receipt = try self.router.enqueueTicketObjectDeletion(db,project:projectID,task:uuid(),cause:"media_round_delete",plan:TicketObjectDeletionPlan(objects:[]))
            id = try XCTUnwrap(receipt["id"] as? String)
            XCTAssertEqual(receipt["state"] as? String,"completed")
            XCTAssertEqual((receipt["objects"] as? [JSON])?.count,0)
            XCTAssertEqual((receipt["summary"] as? JSON)?["pending_count"] as? Int,0)
            XCTAssertEqual(backupQueries,0)
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-backup-seen:" + id]))
        }
        try router.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT id FROM records WHERE id=? AND (" + CommandRouter.ticketObjectDeletionReadySQL + ")",arguments:[id]))
        }
    }

    func testSmallByteReceiptEnqueueMatchesLegacyProjectionAndBackupMarker() throws {
        let workspace = directory.appendingPathComponent("small-byte-legacy")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Byte receipt comparison fixture","key_prefix":"BR","root_path":workspace.path])
        let projectID = try XCTUnwrap(project["id"] as? String)

        func legacyEnqueue(_ db: Database,task: String,cause: String,plan: TicketObjectDeletionPlan) throws -> JSON {
            let id = uuid()
            let generation = try router.ticketCleanupBackupGenerationRow(db)
            let receipt: JSON = ["id":id,"project_id":projectID,"task_id":task,"kind":CommandRouter.ticketObjectDeletionKind,"cause":cause,"state":plan.objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed","revision":1,"created_at":now(),"objects":plan.objects,"summary":plan.summary,"cleanup_policy_version":2]
            try router.save(db,receipt,type:"storage_job")
            if ["task_purge","done_evidence","media_round_delete"].contains(cause) {
                try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-backup-seen:" + id,String(generation)])
            }
            return receipt
        }

        try write {db in
            for cause in ["task_purge","done_evidence","media_round_delete"] {
                for count in (cause == "media_round_delete" ? 1...5 : 0...5) {
                    for mixed in [false,true] {
                        let task = uuid()
                        let objects: [JSON] = (0..<count).map {index in
                            let retained = mixed && index % 2 == 0
                            var object: JSON = ["relative_path":"objects/item-\(index)","kind":"file","representation":"original","size":index + 1,"state":retained ? "retained" : "pending"]
                            if retained {object["reasons"] = ["keep_original"]}
                            return object
                        }
                        let plan = TicketObjectDeletionPlan(objects:objects)
                        let expected = try legacyEnqueue(db,task:task,cause:cause,plan:plan)
                        let actual = try self.router.enqueueTicketObjectDeletion(db,project:projectID,task:task,cause:cause,plan:plan)
                        func comparison(_ receipt: JSON) throws -> (String,String?) {
                            let id = try XCTUnwrap(receipt["id"] as? String)
                            var value = receipt
                            value.removeValue(forKey:"id");value.removeValue(forKey:"created_at")
                            let marker = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-backup-seen:" + id])
                            return (try jsonString(value),marker)
                        }
                        let before = try comparison(expected),after = try comparison(actual)
                        XCTAssertEqual(before.0,after.0)
                        XCTAssertEqual(before.1,after.1)
                        if cause == "media_round_delete" {
                            let id = uuid()
                            let prepared = CommandRouter.ticketObjectDeletionReceipt(project:projectID,task:task,cause:cause,plan:plan,id:id,additionalFields:[:])
                            try self.router.commitPreparedTicketObjectDeletionReceipt(db,PreparedTicketObjectDeletionReceipt(prepared))
                            try self.router.markTicketObjectDeletionBackupGeneration(db,receipt:id,generation:self.router.ticketCleanupBackupGenerationRow(db))
                            let stored = try comparison(self.router.record(db,id,type:"storage_job"))
                            XCTAssertEqual(before.0,stored.0)
                            XCTAssertEqual(before.1,stored.1)
                        }
                    }
                }
            }
        }
    }

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

    func testExpiredTicketCleanupPermitPreservesPendingReceiptAndBytes() throws {
        let receipt = try XCTUnwrap(deletionCohortFixture([1]).first)
        let original = try XCTUnwrap((receipt["objects"] as? [JSON])?.first?["relative_path"] as? String)
        let path = router.root.appendingPathComponent(original).path
        var observedExpiry = false
        try router.withTicketCleanupPreparation({try self.router.prepareTicketObjectDeletionCohort($0)}) {db,permit,cohort in
            let prepared = try XCTUnwrap(cohort.current)
            // Model elapsed gate time before the final object check.
            Thread.sleep(forTimeInterval:0.21)
            XCTAssertThrowsError(try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)) {error in
                XCTAssertTrue(error is MaintenanceStepDeferred)
                observedExpiry = true
            }
        }
        XCTAssertTrue(observedExpiry)
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        let pending = try deletionCohortReceipt(receipt)
        XCTAssertEqual(pending["state"] as? String,"pending")
        XCTAssertNil((pending["objects"] as? [JSON])?.first?["failures"])
        try router.runTicketObjectDeletionCohort()
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
    }

    func testTicketDeletionSummaryMatchesPriorGroupingAcrossMixedObjects() throws {
        let states = ["pending","removed","already_missing","retained"]
        func prior(_ objects: [JSON]) -> JSON {
            var result: JSON = ["physical_reclamation":"unmeasured"]
            for state in states {
                let selected = objects.filter { $0["state"] as? String == state }
                result[state + "_count"] = selected.count
                result[state + "_bytes"] = selected.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
            }
            var reasons: [String:(count: Int, bytes: Int64)] = [:]
            for object in objects where object["state"] as? String == "retained" {
                for reason in object["reasons"] as? [String] ?? [] {
                    let previous = reasons[reason] ?? (0,0)
                    reasons[reason] = (previous.count + 1,previous.bytes + ((object["size"] as? NSNumber)?.int64Value ?? 0))
                }
            }
            result["retained_reasons"] = reasons.mapValues { ["count":$0.count,"bytes":$0.bytes] as JSON }
            return result
        }
        for length in 0...64 {
            let objects: [JSON] = (0..<length).map { index in
                let state = (states + ["unrecognized"])[(index + length) % 5]
                var object: JSON = ["state":state,"reasons":index.isMultiple(of:3) ? ["hold","hold"] : ["hold","backup"]]
                if index.isMultiple(of:2) {object["size"] = index * 11}
                return object
            }
            XCTAssertEqual(try jsonString(CommandRouter.ticketObjectDeletionSummary(objects)),try jsonString(prior(objects)))
        }
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
        try QualificationSuite.requireEnabled()
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
        try QualificationSuite.requireEnabled()
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
        XCTAssertTrue((objects[0]["reasons"] as? [String] ?? []).contains("backup_copy_unverified:sourceChanged"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:objects[0]["stored_path"] as! String))
        try ticketCleanupBackupTemplate(router,objects:objects)
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual((try deletionCohortReceipt(receipt)["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:objects[0]["stored_path"] as! String))
    }

    func testDeletionCohortOversizedFirstReceiptDoesNotStarveBoundedSibling() throws {
        try QualificationSuite.requireEnabled()
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
            XCTAssertTrue(backup.originals.isEmpty,"Candidate keys are evaluated on demand without an aggregate wanted set");XCTAssertLessThanOrEqual(backup.cleanupRetainedBytes,TicketCleanupBatchInventory.byteLimit)
            XCTAssertEqual(cohort.entries[0].fence.inventory.holdDigests.count,2,"Retained descriptors still participate in the independent authority fence")
        }))
        XCTAssertEqual(cohort.turns,1)
        let result = try deletionCohortReceipt(receipt),summary = result["summary"] as! JSON
        XCTAssertEqual(summary["removed_count"] as? Int,1);XCTAssertEqual(summary["retained_count"] as? Int,1)
        XCTAssertEqual((result["objects"] as! [JSON])[1]["reasons"] as? [String],["keep_original"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:objects[1]["stored_path"] as! String))
    }

}

extension TicketLifecycleCleanupTests {
    func testP321MaintenanceSkipsInventoryRefusedHeadAndRunsLaterReceipt() throws {
        try QualificationSuite.requireEnabled()
        let jobs = try deletionCohortFixture([1,1]),head = jobs[0],sibling = jobs[1]
        let path = (head["objects"] as! [JSON])[0]["relative_path"] as! String
        try write {db in
            // The individually bounded head fills the cohort before its reference
            // inventory is found to exceed the unchanged 4 MiB row bound.
            var value = head;value["padding"] = String(repeating:"x",count:TicketCleanupDeletionCohort.descriptorByteLimit-1200)
            try self.router.save(db,self.router.revised(value),type:"storage_job")
            try self.router.save(db,["id":uuid(),"project_id":head["project_id"]!,"revision":1,"path":path,"padding":String(repeating:"x",count:TicketCleanupInventory.rowByteLimit+1)],type:"message")
        }
        router.ticketCleanupLifecycleTurn = false
        XCTAssertThrowsError(try router.runStorageMaintenance())
        try expireCleanupBackoff() // Advance only the synthetic fixture's retry.
        router.ticketCleanupLifecycleTurn = false
        try router.runStorageMaintenance()
        XCTAssertTrue(router.ticketCleanupLifecycleTurn)
        XCTAssertEqual(try deletionCohortReceipt(head)["state"] as? String,"pending")
        XCTAssertEqual((try deletionCohortReceipt(sibling)["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:router.root.appendingPathComponent(path).path))
    }

    func testCL403InventoryRefusedNewestWindowRunsTheOlderQueueWithoutRetry() throws {
        try QualificationSuite.requireEnabled()
        let jobs = try deletionCohortFixture([1,1]),queued = jobs[0],newest = jobs[1]
        let pid = queued["project_id"] as! String
        let held = (newest["objects"] as! [JSON])[0]
        var refused = [newest]
        try write {db in
            // The queue receipt fills one descriptor window, while the newest
            // 32 individually bounded receipts all share an oversized reference.
            var value = self.router.revised(queued);value["padding"] = ""
            value["padding"] = String(repeating:"x",count:TicketCleanupDeletionCohort.descriptorByteLimit - (try jsonString(value).utf8.count))
            try self.router.save(db,value,type:"storage_job")
            for _ in 1..<TicketCleanupDeletionCohort.receiptLimit {
                var copy = newest;copy["id"] = uuid();copy["task_id"] = uuid()
                try self.router.save(db,copy,type:"storage_job");refused.append(copy)
            }
            try self.router.save(db,["id":uuid(),"project_id":pid,"revision":1,"path":held["relative_path"]!,"padding":String(repeating:"x",count:TicketCleanupInventory.rowByteLimit+1)],type:"message")
        }
        router.ticketCleanupByteNewestTurns[pid] = true
        var newestRefusals: [String:String] = [:],selected: [[String]] = []
        XCTAssertTrue(try router.runTicketObjectDeletionCohort {value in
            if value["phase"] as? String == "newest_refused" {newestRefusals = value["refused"] as? [String:String] ?? [:]}
            if value["phase"] as? String == "selected" {selected.append((value["receipts"] as? [JSON] ?? []).compactMap {$0["id"] as? String})}
        })
        XCTAssertEqual(newestRefusals.count,TicketCleanupDeletionCohort.receiptLimit)
        XCTAssertTrue(newestRefusals.values.allSatisfy {$0 == "CLEANUP_INVENTORY_LIMIT"})
        XCTAssertEqual(selected.count,2)
        XCTAssertEqual(selected.first?.count,TicketCleanupDeletionCohort.receiptLimit)
        XCTAssertEqual(selected.last,[queued["id"] as! String])
        XCTAssertNil(router.ticketCleanupRetryAt,"A refused newest window must not arm the global retry ahead of the queue")
        XCTAssertNil(try router.dbQueue.read {try self.router.ticketCleanupProjectRetry($0,project:pid)},"A successful queue fallback needs no project retry")
        XCTAssertEqual((try deletionCohortReceipt(queued)["summary"] as? JSON)?["removed_count"] as? Int,1)
        for receipt in refused {XCTAssertEqual(try deletionCohortReceipt(receipt)["state"] as? String,"pending")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:held["stored_path"] as! String),"Inventory refusals retain the original bytes")
    }

    func testP321PreparationUnavailableStillYieldsToLifecycleTurn() throws {
        try QualificationSuite.requireEnabled()
        let jobs = try deletionCohortFixture([1]),head = jobs[0]
        try write {db in
            // Canonical but outside the per-receipt descriptor bound. A byte
            // preparation must refuse, retain bytes, and yield the next turn.
            var value = head;value["padding"] = String(repeating:"x",count:TicketCleanupDeletionCohort.descriptorByteLimit+1)
            try self.router.save(db,self.router.revised(value),type:"storage_job")
        }
        router.ticketCleanupLifecycleTurn = false
        XCTAssertThrowsError(try router.runStorageMaintenance())
        XCTAssertTrue(router.ticketCleanupLifecycleTurn,"A failed byte preparation cannot monopolize every future maintenance turn")
        XCTAssertEqual(try deletionCohortReceipt(head)["state"] as? String,"pending")
    }
}

extension TicketLifecycleCleanupTests {
    func testP321MaintenanceRetiresLegacyHeadWithoutUnlinkAndDeletesCurrentSibling() throws {
        let (project,task,attachment) = try fixture(),pid = project["id"] as! String
        _ = try configure(project);try router.runTicketLifecycleCleanup()
        let legacy = try router.dbQueue.read {db in
            try XCTUnwrap(self.router.records(db,type:"storage_job").first {$0["cause"] as? String == "done_evidence" && $0["task_id"] as? String == task["id"] as? String})
        }
        let modern = try deletionCohortFixture([1])[0]
        try write {db in
            var old = legacy;old.removeValue(forKey:"cleanup_policy_version")
            old["owned_record_fingerprints"] = [:] as [String:String]
            var objects = old["objects"] as! [JSON]
            var retained = objects[0];retained["state"] = "retained";retained["reasons"] = ["remaining_record"]
            // Keep an earlier retained descriptor/outcome byte-for-byte while
            // retiring the still-pending original to a new exact-ticket plan.
            retained["relative_path"] = "objects/prior-retained.txt";retained["stored_path"] = "objects/prior-retained.txt"
            objects.append(retained);old["objects"] = objects;old["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
            try self.router.save(db,self.router.revised(old),type:"storage_job")
            var current = modern;current["project_id"] = pid
            try self.router.save(db,self.router.revised(current),type:"storage_job")
        }
        router.ticketCleanupLifecycleTurn = false
        try router.runStorageMaintenance()
        let retired = try deletionCohortReceipt(legacy),objects = retired["objects"] as! [JSON]
        XCTAssertEqual(retired["state"] as? String,"completed")
        XCTAssertEqual(objects[0]["reasons"] as? [String],["legacy_replan_required"])
        XCTAssertEqual(objects[1]["reasons"] as? [String],["remaining_record"])
        XCTAssertEqual((retired["summary"] as? JSON)?["removed_count"] as? Int,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertEqual((try deletionCohortReceipt(modern)["summary"] as? JSON)?["removed_count"] as? Int,1)
        XCTAssertNotNil(try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[task["id"] as! String]})
    }
}


extension TicketLifecycleCleanupTests {
    /// The XCTest invocation is an isolated process; restore its original limit
    /// before teardown. Match launchd's soft limit and the measured service idle
    /// baseline, then exercise the real byte-turn preparation and unlink path.
    func testDeletionCohort256CandidatesAtLaunchdDescriptorLimit() throws {
        try QualificationSuite.requireEnabled()
        let receipts = try deletionCohortFixture([256])
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&original),0)
        var limited = original;limited.rlim_cur = 256
        var padding: [Int32] = []
        defer {
            _ = setrlimit(RLIMIT_NOFILE,&original)
            for fd in padding {Darwin.close(fd)}
        }
        func openCount() -> Int {(0..<256).filter {fcntl(Int32($0),F_GETFD) >= 0}.count}
        while openCount() < 98 {
            let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd,0);guard fd >= 0 else {return}
            padding.append(fd)
        }
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE,&limited),0)
        print("P321i descriptor fixture: soft=256 baseline=\(openCount()) candidates=256")
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let actual = try deletionCohortReceipt(receipts[0]),summary = actual["summary"] as? JSON ?? [:]
        print("P321i descriptor result: \(try jsonString(summary))")
        XCTAssertEqual(summary["removed_count"] as? Int,256)
        XCTAssertEqual(summary["retained_count"] as? Int,0)
        XCTAssertEqual(actual["state"] as? String,"completed")
        for object in receipts[0]["objects"] as! [JSON] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:object["stored_path"] as! String))
        }
    }
}

extension TicketLifecycleCleanupTests {
    func testByteReceiptAbove16MiBResumesAcrossPagesAndPreservesTrashAndLinks() throws {
        let original = try deletionCohortFixture([3])[0]
        let id = try XCTUnwrap(original["id"] as? String),project = try XCTUnwrap(original["project_id"] as? String)
        let root = router.root,trash = directory.appendingPathComponent("owned-page-trash")
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        router.ticketCleanupTrashRoot = trash
        let capture = "source-captures/" + project + "/" + uuid() + "/source"
        let filename = "target.txt",target = capture + "/" + filename,linkPath = capture + "/link.txt"
        let bytes = Data("cross-page retained target".utf8)
        let files = try StorageObjectFiles(root:root)
        try files.writeNew(target,bytes:bytes)
        try files.writeLink(linkPath,target:filename)
        let targetObject: JSON = ["relative_path":target,"kind":"file","size":bytes.count,"sha256":ChecklistCore.hash(bytes),"representation":"source_capture","state":"pending"]
        let link: JSON = ["relative_path":linkPath,"kind":"symlink","size":filename.utf8.count,"sha256":ChecklistCore.hash(Data(filename.utf8)),"link_target":filename,"representation":"source_capture","state":"retained","reasons":["keep_original"]]
        let originals = (original["objects"] as! [JSON]).map { value -> JSON in
            var object = value;object["disposal"] = "trash";return object
        }
        let filler: JSON = ["representation":"staging","state":"retained","size":0,"reasons":["staging_requires_import_recovery"],"synthetic_padding":String(repeating:"p",count:500_000)]
        var objects = [targetObject,originals[0]]
        objects += Array(repeating:filler,count:18)
        objects += [originals[1]]
        objects += Array(repeating:filler,count:17)
        objects += [originals[2],link]
        var receipt = original
        receipt["cause"] = "media_round_delete";receipt["objects"] = objects
        receipt["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
        XCTAssertGreaterThan(try jsonString(receipt).utf8.count,16 * 1024 * 1024)
        try write {db in try self.router.save(db,self.router.revised(receipt),type:"storage_job")}

        // Commit just one staging pass through the production fence and reopen.
        try router.withTicketCleanupPreparation({try self.router.prepareTicketObjectDeletionCohort($0)}) {db,_,cohort in
            let conversion = try XCTUnwrap(cohort.paged?.conversion)
            try TicketCleanupChanges.deletionAccounting(db) {try self.router.commitTicketBytePageConversion(db,work:conversion,index:0)}
        }
        let staged = try router.dbQueue.read {db -> JSON in
            let pageID = try XCTUnwrap(String.fetchOne(db,sql:"SELECT id FROM records WHERE type='storage_job' AND json_extract(data,'$.page_parent')=?",arguments:[id]))
            return try self.router.record(db,pageID,type:"storage_job")
        }
        var crossedFence = false
        try router.withTicketCleanupPreparation({db in
            let work = try self.router.prepareTicketObjectDeletionCohort(db)
            XCTAssertNotNil(work?.paged?.conversion)
            // Rewrite a previously staged page without a revision change.
            // It cannot be accepted by the reader's otherwise complete plan.
            try self.write {writer in
                var changed = staged
                changed["fixture_changed"] = true
                try self.router.save(writer,changed,type:"storage_job")
            }
            return work
        }) {_,_,_ in crossedFence = true}
        XCTAssertFalse(crossedFence)
        try write {try self.router.save($0,staged,type:"storage_job")}
        try expireCleanupBackoff()
        let before = try deletionCohortReceipt(receipt)
        XCTAssertNil(before["descriptor_page_generation"])
        XCTAssertEqual((before["objects"] as? [JSON])?.count,objects.count)
        XCTAssertNoThrow(try router.dbQueue.read {db in
            try StorageSnapshotAuthority.inventory(db,root:root,budget:.production(),retainedExists:files.regularOrLinkExists)
        })
        try router.closeStore();router = try TestStore.router(root:root)
        router.ticketCleanupTrashRoot = trash

        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let activated = try deletionCohortReceipt(receipt)
        XCTAssertNotNil(activated["descriptor_page_generation"])
        XCTAssertEqual((activated["objects"] as? [JSON])?.count,0)
        XCTAssertEqual(activated["state"] as? String,"pending")
        XCTAssertNoThrow(try router.dbQueue.read {db in
            try StorageSnapshotAuthority.inventory(db,root:root,budget:.production(),retainedExists:files.regularOrLinkExists)
        })

        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let first = try deletionCohortReceipt(receipt)
        XCTAssertEqual(first["state"] as? String,"pending")
        XCTAssertEqual(int(first["summary"] as? JSON ?? [:],"removed_count"),1)
        try router.closeStore();router = try TestStore.router(root:root)
        router.ticketCleanupTrashRoot = trash
        for _ in 0..<5 {
            if try deletionCohortReceipt(receipt)["state"] as? String == "completed" {break}
            XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        }
        let settled = try router.dbQueue.read {db in
            try self.router.ticketObjectDeletionReceiptWithObjects(db,receipt:self.router.record(db,id,type:"storage_job"))
        }
        XCTAssertEqual(settled["id"] as? String,id)
        XCTAssertEqual(settled["state"] as? String,"completed")
        let outcomes = try XCTUnwrap(settled["objects"] as? [JSON])
        XCTAssertEqual(outcomes.count,objects.count)
        XCTAssertEqual(try jsonString(settled["summary"] as? JSON ?? [:]),try jsonString(CommandRouter.ticketObjectDeletionSummary(outcomes)))
        XCTAssertEqual(strings(outcomes[0],"reasons"),["retained_link_target"])
        XCTAssertEqual(try files.read(target,maximum:1000),bytes)
        XCTAssertEqual(try files.linkTarget(linkPath),filename)
        let trashPaths = try outcomes.filter {bool($0,"moved_to_trash")}.map {try XCTUnwrap($0["trash_path"] as? String)}
        XCTAssertEqual(trashPaths.count,3)
        XCTAssertEqual(Set(trashPaths.map {URL(fileURLWithPath:$0).deletingLastPathComponent().path}).count,1)
        for (index,path) in trashPaths.enumerated() {
            let bytes = try Data(contentsOf:URL(fileURLWithPath:path))
            XCTAssertEqual(ChecklistCore.hash(bytes),originals[index]["sha256"] as? String)
        }
        XCTAssertFalse(try router.runTicketObjectDeletionCohort())
    }

    func testByteReceiptAboveCohortObjectLimitActivatesBoundedPages() throws {
        let original = try deletionCohortFixture([1])[0]
        let pending = (original["objects"] as! [JSON])[0]
        let filler: JSON = ["state":"retained","reasons":["keep_original"],"size":0]
        let objects = [pending] + Array(repeating:filler,count:TicketCleanupDeletionCohort.objectLimit)
        var receipt = original
        receipt["objects"] = objects;receipt["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
        XCTAssertLessThan(try jsonString(receipt).utf8.count,TicketCleanupDeletionCohort.descriptorByteLimit)
        try write {db in try self.router.save(db,self.router.revised(receipt),type:"storage_job")}
        for _ in 0..<8 {
            if try deletionCohortReceipt(receipt)["state"] as? String == "completed" {break}
            XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        }
        let settled = try deletionCohortReceipt(receipt)
        XCTAssertEqual(settled["state"] as? String,"completed")
        XCTAssertEqual(int(settled,"descriptor_count"),objects.count)
        XCTAssertEqual(int(settled["summary"] as? JSON ?? [:],"removed_count"),1)
        let pageCount = try router.dbQueue.read {db in try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job' AND json_extract(data,'$.page_parent')=?",arguments:[original["id"] as? String])}
        XCTAssertEqual(pageCount,(objects.count + TicketCleanupDescriptorPages.countLimit - 1) / TicketCleanupDescriptorPages.countLimit)
    }
}

extension TicketLifecycleCleanupTests {
    func testPagedByteCleanupRechecksAllPagesAfterLinkIdentityChanges() throws {
        let seed = try deletionCohortFixture([1])[0],project = seed["project_id"] as! String
        let root = router.root,files = try StorageObjectFiles(root:root)
        let capture = "source-captures/" + project + "/" + uuid() + "/source"
        let oldName = "old.txt",newName = "new.txt",linkPath = capture + "/alias.txt"
        let filesToProtect = try [oldName,newName].map {name -> JSON in
            let path = capture + "/" + name,bytes = Data(name.utf8)
            try files.writeNew(path,bytes:bytes)
            return ["relative_path":path,"kind":"file","size":bytes.count,"sha256":ChecklistCore.hash(bytes),"representation":"source_capture","state":"pending"]
        }
        try files.writeLink(linkPath,target:oldName)
        let link: JSON = ["relative_path":linkPath,"kind":"symlink","size":oldName.utf8.count,"sha256":ChecklistCore.hash(Data(oldName.utf8)),"link_target":oldName,"representation":"source_capture","state":"pending"]
        let filler: JSON = ["state":"retained","reasons":["keep_original"],"size":0,"synthetic_padding":String(repeating:"p",count:510_000)]
        let original = (seed["objects"] as! [JSON])[0]
        let objects = filesToProtect + [filler] + Array(repeating:filler,count:33) + [link,original]
        try ticketCleanupBackupTemplate(router,objects:filesToProtect + [link,original])
        var receipt = seed
        receipt["objects"] = objects;receipt["summary"] = CommandRouter.ticketObjectDeletionSummary(objects)
        try write {try self.router.save($0,self.router.revised(receipt),type:"storage_job")}
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let linkURL = root.appendingPathComponent(linkPath)
        try FileManager.default.moveItem(at:linkURL,to:linkURL.appendingPathExtension("before-fixture-change"))
        try files.writeLink(linkPath,target:newName)

        // The pending link is stored after both objects. Check it first:
        // its now-unknown target makes the whole cross-page capture uncertain.
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        let id = seed["id"] as! String
        let first = try router.dbQueue.read {db in
            try self.router.ticketObjectDeletionReceiptWithObjects(db,receipt:self.router.record(db,id,type:"storage_job"))
        }
        let firstObjects = first["objects"] as! [JSON]
        XCTAssertEqual(firstObjects[objects.count-2]["last_failure"] as? String,"CLEANUP_IDENTITY_CHANGED")
        XCTAssertEqual(firstObjects[0]["state"] as? String,"pending")
        XCTAssertEqual(firstObjects[1]["state"] as? String,"pending")
        try router.closeStore();router = try TestStore.router(root:root)
        for _ in 0..<4 {
            if try deletionCohortReceipt(receipt)["state"] as? String == "completed" {break}
            XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        }
        let settled = try router.dbQueue.read {db in
            try self.router.ticketObjectDeletionReceiptWithObjects(db,receipt:self.router.record(db,id,type:"storage_job"))
        }
        XCTAssertEqual(settled["state"] as? String,"completed")
        let outcomes = settled["objects"] as! [JSON]
        for outcome in outcomes.prefix(2) {XCTAssertEqual(strings(outcome,"reasons"),["link_closure_unavailable"])}
        XCTAssertEqual(try files.linkTarget(linkPath),newName)
        for object in filesToProtect {XCTAssertTrue(try files.regularOrLinkExists(object["relative_path"] as! String))}
        XCTAssertEqual(outcomes.last?["state"] as? String,"removed")
    }
}
