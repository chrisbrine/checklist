import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-393: Done files that wait for a backup get one, within a bound.
extension TicketLifecycleCleanupTests {
    private func confirmRetention() throws {
        try router.dbQueue.write {db in
            var settings = try self.router.backupRetentionSettings(db)
            settings["automatic_prune"] = true;settings["owner_confirmed"] = true
            settings["owner_confirmation"] = ["source":"authenticated_app","principal":self.owner.principal,"command_id":uuid(),"confirmed_at":ISO8601DateFormatter().string(from:Date()),"source_root":self.router.root.path,"incarnation":self.router.incarnation] as JSON
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('backup-retention-settings',?)",arguments:[try jsonString(settings)])
        }
    }
    private func deadline() throws -> Date? {try router.dbQueue.read {try self.router.doneEvidenceBackupDeadline($0)}}
    private func waitingFile() throws -> (JSON,JSON,JSON) {
        let values = try fixture(backed:false)
        _ = try configure(values.0);try router.runTicketLifecycleCleanup();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:values.2["path"] as! String))
        return values
    }
    private func serviceBackupCount() throws -> Int {
        try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM events WHERE kind='backup_created' AND json_extract(data,'$.origin')='service'") ?? 0}
    }

    func testCL393NoBackupWithoutOwnerConfirmedRetention() throws {
        _ = try waitingFile()
        XCTAssertNil(try deadline())
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:Date().addingTimeInterval(86400)))
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL393NoBackupWhenNoFileWaits() throws {
        try confirmRetention()
        _ = try fixture()
        XCTAssertNil(try deadline())
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:Date().addingTimeInterval(86400)))
    }

    func testCL393WaitingFileGetsOneBackupThenLeavesWithoutASweep() throws {
        try confirmRetention()
        let (_,task,file) = try waitingFile()
        let due = try XCTUnwrap(try deadline())
        XCTAssertGreaterThanOrEqual(due.timeIntervalSinceNow,CommandRouter.doneEvidenceBackupSettle - 120,"The wait settles first")
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(-1)))
        XCTAssertEqual(try serviceBackupCount(),0)
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        XCTAssertEqual(try serviceBackupCount(),1)
        // The project read names it, with the real origin.
        let history = try call("history_list",["project_id":try read(task)["project_id"]!,"entity":"backup"])
        let rows = (history["events"] as? [JSON] ?? []).filter {($0["data"] as? JSON)?["origin"] as? String == "service"}
        XCTAssertEqual(rows.count,1);XCTAssertNotNil((rows.first?["data"] as? JSON)?["captured_at"] as? String)
        // The completed backup covers the file: nothing waits, and the ticket is woken.
        XCTAssertNil(try deadline())
        let pid = try XCTUnwrap(try read(task)["project_id"] as? String)
        XCTAssertNotNil(try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[task["id"] as! String]})
        router.ticketCleanupYieldAt = nil
        try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(1));try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
    }

    func testCL393RecentBackupAndFailedAttemptEachHoldTheNextOneForTheInterval() throws {
        try confirmRetention()
        _ = try fixture()
        _ = try call("backup_create",["path":directory.appendingPathComponent("cl393-recent").path])
        let backupTime = Date()
        Thread.sleep(forTimeInterval:1.1)
        _ = try waitingFile()
        let due = try XCTUnwrap(try deadline())
        XCTAssertEqual(due.timeIntervalSince(backupTime),CommandRouter.doneEvidenceBackupInterval,accuracy:60)
        // An active capture holds the start without spending the attempt.
        try StorageSnapshotRetention.withCapture(root:router.root) {_ in
            XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        }
        XCTAssertEqual(try serviceBackupCount(),0)
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        XCTAssertEqual(try serviceBackupCount(),1)
    }

    func testCL393AttemptTimeMovesTheDeadline() throws {
        try confirmRetention()
        _ = try waitingFile()
        let time = Date().addingTimeInterval(3600)
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-attempt',?)",arguments:[ISO8601DateFormatter().string(from:time)])}
        XCTAssertEqual(try XCTUnwrap(try deadline()).timeIntervalSince(time),CommandRouter.doneEvidenceBackupInterval,accuracy:1)
    }

    func testCL393WakePlanSkipsTheJobScanWhileTheIntervalHolds() throws {
        try confirmRetention()
        _ = try waitingFile()
        let time = Date().addingTimeInterval(3600)
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-attempt',?)",arguments:[ISO8601DateFormatter().string(from:time)])}
        try router.dbQueue.read {db in
            var scans = 0
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("ticket_object_delete") {scans += 1}}
            let wake = try self.router.doneEvidenceBackupWake(db)
            db.trace(nil)
            XCTAssertEqual(scans,0)
            XCTAssertEqual(try XCTUnwrap(wake).timeIntervalSince(time),CommandRouter.doneEvidenceBackupInterval,accuracy:1)
        }
    }

    func testCL393FileAddedDuringACaptureStillWaits() throws {
        try confirmRetention()
        _ = try waitingFile()
        // The newest backup completed after this job, but its capture started before it.
        let job = Date().addingTimeInterval(-60),format = ISO8601DateFormatter()
        try router.dbQueue.write {db in
            let generation: JSON = ["state":"complete","known_at":format.string(from:Date().addingTimeInterval(60)),"summary":["captured_at":format.string(from:job.addingTimeInterval(-300))] as JSON]
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + uuid(),try jsonString(generation)])
        }
        XCTAssertNotNil(try deadline())
    }

    func testCL393MalformedRetryEntryCannotFailAFinishedBackup() throws {
        try confirmRetention()
        let (project,_,_) = try waitingFile()
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-retries:" + (project["id"] as! String),"{\"bad\":{}}"])}
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("cl393-malformed").path]))
    }

    func testCL393StartRunsThroughTheOperationQueue() throws {
        try confirmRetention()
        _ = try waitingFile()
        let lane = DispatchQueue(label:"cl393-operation")
        router.configureCommandOperations(on:lane)
        let due = try XCTUnwrap(try deadline())
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        let finished = expectation(description:"service backup")
        DispatchQueue.global().async {
            for _ in 0..<120 {
                if (try? self.serviceBackupCount()) == 1 {finished.fulfill();return}
                Thread.sleep(forTimeInterval:0.25)
            }
        }
        wait(for:[finished],timeout:40)
        lane.sync {}
    }

    func testCL393OwnerBackupKeepsItsOrigin() throws {
        let (_,_,_) = try fixture()
        _ = try call("backup_create",["path":directory.appendingPathComponent("cl393-owner").path])
        XCTAssertEqual(try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT json_extract(data,'$.origin') FROM events WHERE kind='backup_created' ORDER BY seq DESC LIMIT 1")},"human_ui")
    }

    /// One file is retained for a backup while its backed sibling is pending.
    /// This is the mixed state that the old completed-only query missed.
    private func pendingWaitingFiles() throws -> (JSON,JSON,JSON) {
        let (project,task,first) = try fixture(backed:false)
        let source = directory.appendingPathComponent("pending-backed-evidence.txt")
        try Data("a backed sibling".utf8).write(to:source)
        let second = try call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":source.path,"mode":"managed_copy"])
        let relative = try XCTUnwrap(ManagedPaths.relative(second["path"] as! String,family:"objects",root:router.root))
        try ticketCleanupBackupTemplate(router,objects:[["relative_path":relative,"sha256":second["sha256"]!,"size":second["size"]!,"kind":"file"]])
        _ = try configure(project);try router.runTicketLifecycleCleanup()
        let job = try router.dbQueue.read {db in
            try XCTUnwrap(self.router.records(db,type:"storage_job").first {$0["kind"] as? String == "ticket_object_delete" && $0["task_id"] as? String == task["id"] as? String})
        }
        XCTAssertEqual(job["state"] as? String,"pending")
        XCTAssertTrue((job["objects"] as? [JSON] ?? []).contains {($0["reasons"] as? [String] ?? []).contains("backup_required")})
        return (project,job,first)
    }
    private func evidenceBackupMaintenance(_ project: JSON) throws -> JSON {
        let read = try call("ticket_cleanup_receipts",["project_id":project["id"]!])
        return try XCTUnwrap((read["maintenance"] as? JSON)?["evidence_backup"] as? JSON)
    }
    private func blockServiceBackupFolder() throws {
        let backups = router.root.appendingPathComponent("backups")
        if FileManager.default.fileExists(atPath:backups.path) {
            try FileManager.default.moveItem(at:backups,to:directory.appendingPathComponent("preserved-backups"))
        }
        try Data("not a directory".utf8).write(to:backups)
    }

    func testCL394PendingJobHasABackupDeadline() throws {
        try confirmRetention()
        _ = try pendingWaitingFiles()
        XCTAssertNotNil(try deadline())
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL394ProgressingPendingJobKeepsItsBackupSettleDeadline() throws {
        try confirmRetention()
        let (_,job,_) = try pendingWaitingFiles()
        let original = try XCTUnwrap(try deadline())
        try router.dbQueue.write {db in
            var progress = job
            progress["updated_at"] = ISO8601DateFormatter().string(from:original.addingTimeInterval(3600))
            progress["revision"] = int(progress,"revision") + 1
            try self.router.save(db,progress,type:"storage_job")
        }
        XCTAssertEqual(try deadline(),original,"Byte progress must not postpone a pending job's stable admission-based settle clock")
    }

    func testCL394InterruptedServiceBackupAttemptHasUnknownOutcome() throws {
        let (project,_,_) = try fixture()
        let attempted = ISO8601DateFormatter().string(from:Date()),command = uuid()
        try router.dbQueue.write {db in
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?),(?,?)",arguments:["done-evidence-backup-attempt",attempted,"done-evidence-backup-status",try jsonString(["state":"starting","attempted_at":attempted,"command_id":command])])
        }
        let status = try evidenceBackupMaintenance(project)
        XCTAssertEqual(status["state"] as? String,"unknown")
        XCTAssertEqual(status["reason"] as? String,"attempt_outcome_not_recorded")
        XCTAssertEqual(status["command_id"] as? String,command)
        XCTAssertNotNil(status["retry_not_before"] as? String)
    }

    func testCL394PendingJobUsesNewBackupWithoutASecondBackupOrSweep() throws {
        try confirmRetention()
        let (_,job,file) = try pendingWaitingFiles()
        let due = try XCTUnwrap(try deadline())
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        XCTAssertEqual(try serviceBackupCount(),1)
        // Finish only the existing byte job. Do not run lifecycle selection.
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        let result = try router.dbQueue.read {try self.router.record($0,job["id"] as! String,type:"storage_job")}
        XCTAssertEqual(result["state"] as? String,"completed")
        XCTAssertEqual((result["summary"] as? JSON)?["removed_count"] as? Int,2)
        XCTAssertEqual(try serviceBackupCount(),1)
        XCTAssertNil(try deadline())
    }

    func testCL394PendingJobUsesAnAlreadyCompletedBackup() throws {
        let (_,job,file) = try pendingWaitingFiles()
        let relative = try XCTUnwrap(ManagedPaths.relative(file["path"] as! String,family:"objects",root:router.root))
        // The completed copy exists before the pending job's next turn. There
        // is no completion callback or lifecycle wake in this fixture seam.
        try ticketCleanupBackupTemplate(router,objects:[["relative_path":relative,"sha256":file["sha256"]!,"size":file["size"]!,"kind":"file"]])
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        let result = try router.dbQueue.read {try self.router.record($0,job["id"] as! String,type:"storage_job")}
        XCTAssertEqual(result["state"] as? String,"completed")
        XCTAssertEqual((result["summary"] as? JSON)?["removed_count"] as? Int,2)
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL394LegacyPendingDoneJobKeepsEarlierRetainedOutcomes() throws {
        let (_,job,_) = try pendingWaitingFiles()
        var legacy = job;legacy.removeValue(forKey:"cleanup_policy_version")
        let before = try jsonString(legacy["objects"]!)
        try router.readers!.read {try self.router.rearmTicketObjectCopyFailures($0,receipt:&legacy,backupGenerationRow:Int64.max)}
        XCTAssertEqual(try jsonString(legacy["objects"]!),before,"Legacy settlement may retire pending descriptors only; earlier outcomes stay unchanged")
    }

    func testCL394RefusedServiceBackupIsVisibleInMaintenance() throws {
        try confirmRetention()
        let (project,_,_) = try waitingFile()
        XCTAssertTrue(try evidenceBackupMaintenance(project).isEmpty)
        try blockServiceBackupFolder()
        let due = try XCTUnwrap(try deadline())
        XCTAssertFalse(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        let status = try evidenceBackupMaintenance(project)
        XCTAssertEqual(status["state"] as? String,"failed")
        XCTAssertEqual(status["error_code"] as? String,"STORAGE_OBJECT_UNAVAILABLE")
        XCTAssertNotNil(status["command_id"] as? String)
        let floor = try XCTUnwrap(ISO8601DateFormatter().date(from:try XCTUnwrap(status["retry_not_before"] as? String)))
        XCTAssertEqual(floor.timeIntervalSince(due.addingTimeInterval(1)),CommandRouter.doneEvidenceBackupInterval,accuracy:1)
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL394AsynchronousBackupFailureIsVisibleInMaintenance() throws {
        try confirmRetention()
        let (project,_,_) = try waitingFile()
        try blockServiceBackupFolder()
        let lane = DispatchQueue(label:"cl394-backup-failure")
        lane.suspend();var suspended = true
        defer {if suspended {lane.resume()}}
        router.configureCommandOperations(on:lane)
        let due = try XCTUnwrap(try deadline())
        XCTAssertTrue(router.startDoneEvidenceBackupIfDue(at:due.addingTimeInterval(1)))
        let accepted = try evidenceBackupMaintenance(project)
        XCTAssertEqual(accepted["state"] as? String,"queued")
        XCTAssertNotNil(accepted["operation_id"] as? String)
        lane.resume();suspended = false;lane.sync {}
        let status = try evidenceBackupMaintenance(project)
        XCTAssertEqual(status["state"] as? String,"failed")
        XCTAssertEqual(status["error_code"] as? String,"STORAGE_OBJECT_UNAVAILABLE")
        XCTAssertEqual(status["operation_id"] as? String,accepted["operation_id"] as? String)
        XCTAssertNotNil(status["finished_at"] as? String)
        XCTAssertEqual(try serviceBackupCount(),0)
    }

    func testCL403LegacySuccessfulAttemptReadsItsCommittedServiceBackup() throws {
        let (project,_,_) = try fixture()
        let attempted = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-1)),command = uuid()
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-attempt',?)",arguments:[attempted])}
        _ = try router.handle(method:"backup_create",params:["command_id":command,"path":directory.appendingPathComponent("cl403-service").path],caller:Caller(role:"owner",installation:CommandRouter.doneEvidenceBackupInstallation,projectIDs:[]))
        let status = try evidenceBackupMaintenance(project)
        XCTAssertEqual(status["state"] as? String,"complete")
        XCTAssertEqual(status["command_id"] as? String,command)
        XCTAssertEqual(status["outcome_source"] as? String,"backup_receipt")
        XCTAssertNil(status["reason"])
    }

    func testCL403OtherBackupCannotCompleteAnUnknownServiceAttempt() throws {
        let (project,_,_) = try fixture()
        let attempted = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-1))
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-attempt',?)",arguments:[attempted])}
        _ = try call("backup_create",["path":directory.appendingPathComponent("cl403-owner").path])
        XCTAssertEqual(try evidenceBackupMaintenance(project)["state"] as? String,"unknown")
        // Even another service success cannot replace an exact failed command.
        _ = try router.handle(method:"backup_create",params:["command_id":uuid(),"path":directory.appendingPathComponent("cl403-other-service").path],caller:Caller(role:"owner",installation:CommandRouter.doneEvidenceBackupInstallation,projectIDs:[]))
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-status',?)",arguments:[try jsonString(["state":"starting","attempted_at":attempted,"command_id":uuid()])])}
        XCTAssertEqual(try evidenceBackupMaintenance(project)["state"] as? String,"unknown")
    }

    func testCL403SuccessfulServiceReceiptCommitsAttemptOutcome() throws {
        let (project,_,_) = try fixture(),command = uuid()
        let attempted = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-1))
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('done-evidence-backup-status',?)",arguments:[try jsonString(["state":"starting","attempted_at":attempted,"command_id":command])])}
        _ = try router.handle(method:"backup_create",params:["command_id":command,"path":directory.appendingPathComponent("cl403-atomic-status").path],caller:Caller(role:"owner",installation:CommandRouter.doneEvidenceBackupInstallation,projectIDs:[]))
        let stored = try router.dbQueue.read {jsonObject(try XCTUnwrap(String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key='done-evidence-backup-status'")))}
        XCTAssertEqual(stored["state"] as? String,"complete")
        XCTAssertEqual(stored["outcome_source"] as? String,"backup_receipt")
        XCTAssertEqual(try evidenceBackupMaintenance(project)["state"] as? String,"complete")
    }

    func testCL403PendingJobRecheckKeepsBytesWithoutACompleteBackup() throws {
        let (_,job,file) = try pendingWaitingFiles()
        let path = file["path"] as! String,before = try Data(contentsOf:URL(fileURLWithPath:path))
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),before)
        let result = try router.dbQueue.read {try self.router.record($0,job["id"] as! String,type:"storage_job")}
        let relative = try ManagedPaths.relative(path,family:"objects",root:router.root)
        let held = try XCTUnwrap((result["objects"] as? [JSON])?.first {$0["relative_path"] as? String == relative})
        XCTAssertEqual(held["state"] as? String,"retained")
        XCTAssertTrue(strings(held,"reasons").contains("backup_required"))
        XCTAssertEqual((result["summary"] as? JSON)?["removed_count"] as? Int,1,"Only the backed sibling may leave")
    }

    func testCL403PendingJobRecheckDoesNotRearmANonRetryableReason() throws {
        let (_,job,_) = try pendingWaitingFiles()
        var held = job,objects = job["objects"] as! [JSON]
        let index = try XCTUnwrap(objects.firstIndex {$0["state"] as? String == "retained"})
        objects[index]["reasons"] = ["backup_required","active_reader"]
        held["objects"] = objects
        try router.readers!.read {try self.router.rearmTicketObjectCopyFailures($0,receipt:&held,backupGenerationRow:Int64.max)}
        XCTAssertEqual(try jsonString(held["objects"]!),try jsonString(objects),"A new complete generation must not rearm a non-retryable hold")
    }

}
