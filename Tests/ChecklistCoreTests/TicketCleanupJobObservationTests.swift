import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    private func selectedJobTicket(_ id: String = uuid(),project: String) -> JSON {
        ["id":id,"project_id":project]
    }

    private func cleanupObservedJob(_ task: JSON,state: String = "completed",objects: [JSON] = [],cause: String = "done_evidence",kind: String = "ticket_object_delete") -> JSON {
        ["id":uuid(),"project_id":task["project_id"]!,"task_id":task["id"]!,"revision":1,"kind":kind,"cause":cause,"state":state,"objects":objects]
    }

    private func saveObservedJobs(_ jobs: [JSON]) throws {
        try write {db in for job in jobs {try self.router.save(db,job,type:"storage_job")}}
    }

    private func jobObservation(_ tasks: [JSON],limits: TicketCleanupJobObservation.Limits = .init()) throws -> TicketCleanupJobObservation {
        try router.readers!.read {try self.router.ticketCleanupJobObservation($0,tasks:tasks,limits:limits)}
    }

    private func observedEntry(_ observation: TicketCleanupJobObservation,_ task: JSON) throws -> TicketCleanupJobObservation.Entry {
        try observation.entry(task:task["id"] as! String,project:task["project_id"] as! String)
    }

    private func assertJobObservationRefused(_ observation: TicketCleanupJobObservation,_ task: JSON,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try observedEntry(observation,task),file:file,line:line) {
            XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT",file:file,line:line)
        }
    }

    func testJobObservationStreamsSelectedProjectPayloadsOnceAndRefreshesNextPass() throws {
        let first = selectedJobTicket(project:uuid()),second = selectedJobTicket(project:first["project_id"] as! String),other = selectedJobTicket(project:uuid())
        let retained: JSON = ["stored_path":"objects/retained","sha256":"sha","reasons":["backup_required"],"state":"retained"]
        let pending = cleanupObservedJob(second,state:"pending")
        try saveObservedJobs([cleanupObservedJob(first,objects:[retained]),pending,cleanupObservedJob(other)])
        var streams = 0
        let observation = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("records_scope"),statement.sql.contains("storage_job") {streams += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupJobObservation(db,tasks:[first,second,other])
        }
        XCTAssertEqual(streams,2,"Each selected project has one payload stream, independent of its selected ticket count")
        XCTAssertTrue(try observedEntry(observation,first).retains(retained))
        XCTAssertTrue(try observedEntry(observation,second).pending)
        XCTAssertFalse(try observedEntry(observation,other).pending)
        try write {db in
            var changed = pending;changed["state"] = "completed"
            try self.router.save(db,self.router.revised(changed),type:"storage_job")
        }
        XCTAssertFalse(try observedEntry(jobObservation([second]),second).pending,"A pass-local observation cannot conceal the next pass's job changes")
        XCTAssertTrue(try observedEntry(observation,second).pending,"An earlier observation remains a value from its own snapshot")
    }

    func testPendingJobObservationSuppressesDonePlanningAndCorpusTraversal() throws {
        let (project,task,_) = try fixture()
        try saveObservedJobs([cleanupObservedJob(task,state:"pending")])
        var corpusStreams = 0,jobStreams = 0
        let prepared = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0 {
                if statement.sql.contains("FROM records ORDER BY rowid") {corpusStreams += 1}
                if statement.sql.contains("records_scope"),statement.sql.contains("storage_job") {jobStreams += 1}
            }}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        XCTAssertTrue(prepared.plans.isEmpty)
        let item = try XCTUnwrap((prepared.selection["items"] as? [JSON])?.first {$0["task_id"] as? String == task["id"] as? String})
        XCTAssertEqual(item["action"] as? String,"keep");XCTAssertEqual(item["reason"] as? String,"deletion_pending")
        XCTAssertEqual(jobStreams,1);XCTAssertEqual(corpusStreams,0,"A pending durable byte job needs no fresh deletion plan")
    }

    func testOversizedJobObservationDefersActualDoneSelectionAndSchedulesRetry() throws {
        let (project,task,attachment) = try fixture(),tid = task["id"] as! String
        var oversized = cleanupObservedJob(task)
        oversized["body"] = String(repeating:"x",count:4 * 1024 * 1024 + 1)
        try saveObservedJobs([oversized])
        let before = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job'")}
        let prepared = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:project)}
        let item = try XCTUnwrap((prepared.selection["items"] as? [JSON])?.first {$0["task_id"] as? String == tid})
        XCTAssertEqual(item["action"] as? String,"keep");XCTAssertEqual(item["reason"] as? String,"CLEANUP_INVENTORY_LIMIT")
        XCTAssertTrue(strings(prepared.selection,"retry_task_ids").contains(tid))
        XCTAssertNil(prepared.plans[tid],"An unreadable bounded job history cannot prove that a new byte job is needed")
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job'")},before)
    }

    func testAgedPurgeSkipsDoneJobObservationWithOversizedAccountingHistory() throws {
        let (project,task,_) = try fixture(age:20),tid = task["id"] as! String
        var unrelated = cleanupObservedJob(selectedJobTicket(project:project["id"] as! String))
        unrelated["body"] = String(repeating:"x",count:4 * 1024 * 1024 + 1)
        try saveObservedJobs([unrelated])
        var jobStreams = 0
        let prepared = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("records_scope"),statement.sql.contains("storage_job") {jobStreams += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        let item = try XCTUnwrap((prepared.selection["items"] as? [JSON])?.first {$0["task_id"] as? String == tid})
        XCTAssertEqual(jobStreams,0,"An already due purge does not need Done-evidence dedup history")
        XCTAssertEqual(item["action"] as? String,"purge");XCTAssertEqual(item["reason"] as? String,"closed_unchanged")
        XCTAssertNotNil(prepared.plans[tid]);XCTAssertFalse(strings(prepared.selection,"retry_task_ids").contains(tid))
    }

    func testRetainedJobObservationSuppressesDuplicateDoneReceipt() throws {
        let (project,task,_) = try fixture(backed:false)
        let first = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:project)}
        let objects = try XCTUnwrap(first.plans[task["id"] as! String]?.byteDeletion.objects)
        XCTAssertFalse(objects.isEmpty);XCTAssertTrue(objects.allSatisfy {$0["state"] as? String == "retained"})
        try saveObservedJobs([cleanupObservedJob(task,objects:objects)])
        let second = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:project)}
        XCTAssertTrue(second.plans.isEmpty)
        let item = try XCTUnwrap((second.selection["items"] as? [JSON])?.first {$0["task_id"] as? String == task["id"] as? String})
        XCTAssertEqual(item["action"] as? String,"keep");XCTAssertEqual(item["reason"] as? String,"no_new_eligible_bytes")
    }

    func testJobObservationPreservesOptionalStringsOrderedReasonsAndRetainedState() throws {
        let task = selectedJobTicket(project:uuid())
        let retained: JSON = ["stored_path":"objects/caf\u{e9}","sha256":"sha","reasons":["first","second"],"state":"retained"]
        let missingStrings: JSON = ["stored_path":NSNull(),"sha256":12,"reasons":[12],"state":"retained"]
        let unretained: JSON = ["stored_path":"objects/pending","sha256":"sha","reasons":[],"state":"pending"]
        let wrongCause: JSON = ["stored_path":"objects/purge","sha256":"sha","reasons":[],"state":"retained"]
        try saveObservedJobs([cleanupObservedJob(task,objects:[retained,missingStrings,unretained],kind:"historical_kind"),cleanupObservedJob(task,objects:[wrongCause],cause:"task_purge")])
        let entry = try observedEntry(jobObservation([task]),task)
        XCTAssertFalse(entry.pending)
        XCTAssertTrue(entry.retains(retained))
        var changed = retained;changed["stored_path"] = "objects/cafe\u{301}"
        XCTAssertTrue(entry.retains(changed),"Retained descriptor String equality keeps the original planner's Unicode semantics")
        changed = retained;changed["reasons"] = ["second","first"];XCTAssertFalse(entry.retains(changed))
        changed = retained;changed["sha256"] = "different";XCTAssertFalse(entry.retains(changed))
        changed = retained;changed["stored_path"] = "objects/different";XCTAssertFalse(entry.retains(changed))
        XCTAssertTrue(entry.retains(["reasons":[],"state":"retained"]),"Non-String optionals and invalid reasons preserve the old as? String / strings comparison")
        XCTAssertFalse(entry.retains(unretained));XCTAssertFalse(entry.retains(wrongCause))
    }

    func testJobObservationUsesExactProjectAndTaskUTF8Identities() throws {
        let composedProject = "project-caf\u{e9}",decomposedProject = "project-cafe\u{301}"
        let composedTask = "task-caf\u{e9}",decomposedTask = "task-cafe\u{301}"
        let first = selectedJobTicket(composedTask,project:composedProject),sameProject = selectedJobTicket(decomposedTask,project:composedProject)
        let otherProject = selectedJobTicket("other-task",project:decomposedProject),caseTask = selectedJobTicket(composedTask.uppercased(),project:composedProject)
        let foreignSameTask = selectedJobTicket(composedTask,project:decomposedProject)
        let retained: JSON = ["stored_path":"objects/exact","sha256":"sha","reasons":[],"state":"retained"]
        try saveObservedJobs([cleanupObservedJob(first,objects:[retained]),cleanupObservedJob(sameProject,state:"pending"),cleanupObservedJob(otherProject),cleanupObservedJob(foreignSameTask,state:"pending")])
        let observation = try jobObservation([first,sameProject,otherProject,caseTask])
        XCTAssertFalse(try observedEntry(observation,first).pending);XCTAssertTrue(try observedEntry(observation,first).retains(retained))
        XCTAssertTrue(try observedEntry(observation,sameProject).pending);XCTAssertFalse(try observedEntry(observation,sameProject).retains(retained))
        XCTAssertFalse(try observedEntry(observation,otherProject).pending);XCTAssertFalse(try observedEntry(observation,otherProject).retains(retained))
        XCTAssertFalse(try observedEntry(observation,caseTask).pending)
        XCTAssertThrowsError(try observation.entry(task:composedTask,project:composedProject.uppercased()))
    }

    func testJobObservationValidatesEveryInScopeCanonicalEnvelopeIncludingUnselectedJobs() throws {
        let task = selectedJobTicket(project:uuid()),pid = task["project_id"] as! String,id = uuid()
        let malformed = [
            Data("{\"id\":\"different\",\"project_id\":\"\(pid)\",\"revision\":1}".utf8),
            Data("{\"id\":\"\(id)\",\"project_id\":\"different\",\"revision\":1}".utf8),
            Data("{\"id\":\"\(id)\",\"project_id\":\"\(pid)\",\"revision\":2}".utf8),
            Data("{\"id\":\"\(id)\",\"project_id\":\"\(pid)\",\"revision\":1,\"body\":\"\\ud800\"}".utf8),
            Data([0xff])
        ]
        for bytes in malformed {
            try write {db in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',1,CAST(? AS TEXT))",arguments:[id,pid,bytes])}
            XCTAssertThrowsError(try jobObservation([task])) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")}
            try write {db in try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
        }
        // The exact scoped index stream must not decode a malformed foreign row.
        try write {db in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',1,'invalid-json')",arguments:[id,uuid()])}
        XCTAssertFalse(try observedEntry(jobObservation([task]),task).pending)
    }

    func testJobObservationNeverInfersMissingHistoryForUnknownOrOversizedSelection() throws {
        let pid = uuid(),task = selectedJobTicket(project:pid),unknown = selectedJobTicket(project:pid)
        let observation = try jobObservation([task])
        assertJobObservationRefused(observation,unknown)
        XCTAssertThrowsError(try jobObservation((0..<33).map {_ in selectedJobTicket(project:pid)})) {
            XCTAssertEqual(($0 as? CoreError)?.code,"PURGE_LIMIT")
        }
    }

    func testJobObservationBoundsSelectedIdentityMemoryBeforeReadingJobPayloads() throws {
        let task = selectedJobTicket(String(repeating:"ticket-",count:128),project:String(repeating:"project-",count:128))
        for aggregate in [false,true] {
            var limits = TicketCleanupJobObservation.Limits()
            if aggregate {limits.totalBytes = 512} else {limits.ticketBytes = 512}
            var streams = 0
            let observation = try router.readers!.read {db in
                db.trace {if case .statement(let statement) = $0,statement.sql.contains("records_scope"),statement.sql.contains("storage_job") {streams += 1}}
                defer {db.trace(nil)}
                return try self.router.ticketCleanupJobObservation(db,tasks:[task],limits:limits)
            }
            assertJobObservationRefused(observation,task)
            XCTAssertEqual(streams,0,"The selected identity itself exceeds the memory bound before any job payload is read")
        }
    }

    func testJobObservationCompressesDuplicateRetainedSignaturesWithoutTruncatingHistory() throws {
        let task = selectedJobTicket(project:uuid())
        let retained: JSON = ["stored_path":"objects/repeated","sha256":"sha","reasons":["backup_required"],"state":"retained"]
        try saveObservedJobs((0..<20).map {_ in cleanupObservedJob(task,objects:Array(repeating:retained,count:20))})
        var limits = TicketCleanupJobObservation.Limits();limits.ticketObjects = 1;limits.totalObjects = 1;limits.ticketBytes = 1024;limits.totalBytes = 1024
        let entry = try observedEntry(jobObservation([task],limits:limits),task)
        XCTAssertFalse(entry.pending);XCTAssertTrue(entry.retains(retained))
    }

    func testJobObservationTicketJobCountOverflowRefusesOnlyAffectedTicket() throws {
        let first = selectedJobTicket(project:uuid()),second = selectedJobTicket(project:first["project_id"] as! String)
        // Matching jobs count even when they retain no signature; a later pending
        // row cannot turn an already refused history into an admissible snapshot.
        try saveObservedJobs([cleanupObservedJob(first),cleanupObservedJob(first,state:"pending"),cleanupObservedJob(second)])
        var limits = TicketCleanupJobObservation.Limits();limits.ticketJobs = 1
        let observation = try jobObservation([first,second],limits:limits)
        assertJobObservationRefused(observation,first);XCTAssertFalse(try observedEntry(observation,second).pending)
    }

    func testJobObservationTicketSignatureCountAndBytesRefuseWithoutPartialHistory() throws {
        for bytesLimit in [false,true] {
            let first = selectedJobTicket(project:uuid()),second = selectedJobTicket(project:first["project_id"] as! String)
            let small: JSON = ["stored_path":"objects/small","sha256":"sha","reasons":[],"state":"retained"]
            let large: JSON = ["stored_path":"objects/" + String(repeating:"x",count:2048),"sha256":"sha","reasons":[],"state":"retained"]
            try saveObservedJobs([cleanupObservedJob(first,objects:[small,large]),cleanupObservedJob(second,objects:[small])])
            var limits = TicketCleanupJobObservation.Limits()
            if bytesLimit {limits.ticketBytes = 1024} else {limits.ticketObjects = 1}
            let observation = try jobObservation([first,second],limits:limits)
            assertJobObservationRefused(observation,first);XCTAssertTrue(try observedEntry(observation,second).retains(small))
        }
    }

    func testJobObservationAggregateOverflowReleasesFailedTicketForLaterAdmission() throws {
        for bytesLimit in [false,true] {
            let pid = uuid(),first = selectedJobTicket(project:pid),overflow = selectedJobTicket(project:pid),later = selectedJobTicket(project:pid)
            let small: JSON = ["stored_path":"objects/first","sha256":"sha","reasons":[],"state":"retained"]
            let overflowFirst: JSON = ["stored_path":"objects/overflow-first","sha256":"sha","reasons":[],"state":"retained"]
            let laterObject: JSON = ["stored_path":"objects/later","sha256":"sha","reasons":[],"state":"retained"]
            let second: JSON = ["stored_path":"objects/second","sha256":"sha","reasons":[],"state":"retained"]
            let large: JSON = ["stored_path":"objects/" + String(repeating:"x",count:2048),"sha256":"sha","reasons":[],"state":"retained"]
            // In physical row order: accept first, partially admit overflow,
            // refuse overflow, then reuse the released admission for later.
            try saveObservedJobs([cleanupObservedJob(first,objects:[small]),cleanupObservedJob(overflow,objects:[overflowFirst]),cleanupObservedJob(overflow,objects:[bytesLimit ? large : second]),cleanupObservedJob(later,objects:[laterObject])])
            var limits = TicketCleanupJobObservation.Limits()
            if bytesLimit {limits.totalBytes = 1536} else {limits.totalObjects = 2}
            let observation = try jobObservation([first,overflow,later],limits:limits)
            XCTAssertTrue(try observedEntry(observation,first).retains(small));assertJobObservationRefused(observation,overflow)
            XCTAssertTrue(try observedEntry(observation,later).retains(laterObject),"A refused ticket must release all of its aggregate signature charge")
        }
    }

    func testJobObservationScopedRowCountAndByteOverflowFailClosedForEverySelectedTicket() throws {
        for bytesLimit in [false,true] {
            let first = selectedJobTicket(project:uuid()),second = selectedJobTicket(project:first["project_id"] as! String),unrelated = selectedJobTicket(project:first["project_id"] as! String)
            var oversized = cleanupObservedJob(unrelated);oversized["body"] = String(repeating:"x",count:2048)
            try saveObservedJobs([cleanupObservedJob(first),oversized,cleanupObservedJob(second,state:"pending")])
            var limits = TicketCleanupJobObservation.Limits()
            if bytesLimit {limits.rowBytes = 1024} else {limits.rowCount = 1}
            let observation = try jobObservation([first,second],limits:limits)
            assertJobObservationRefused(observation,first);assertJobObservationRefused(observation,second)
        }
    }
}
