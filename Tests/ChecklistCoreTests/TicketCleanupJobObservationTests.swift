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
        try QualificationSuite.requireEnabled()
        let (project,task,attachment) = try fixture(),tid = task["id"] as! String
        let sibling = try call("task_create",["project_id":project["id"]!,"title":"Synthetic sibling"])
        let siblingID = sibling["id"] as! String
        let source = URL(fileURLWithPath:project["root_path"] as! String).appendingPathComponent("sibling.txt")
        try Data("sibling evidence".utf8).write(to:source)
        _ = try call("attachment_add",["project_id":project["id"]!,"task_id":siblingID,"path":source.path,"mode":"managed_copy"])
        try mark(project,sibling,category:"done")
        var oversized = cleanupObservedJob(task)
        oversized["body"] = String(repeating:"x",count:4 * 1024 * 1024 + 1)
        try saveObservedJobs([oversized])
        let before = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job'")}
        let prepared = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:project)}
        let item = try XCTUnwrap((prepared.selection["items"] as? [JSON])?.first {$0["task_id"] as? String == tid})
        XCTAssertEqual(item["action"] as? String,"keep");XCTAssertEqual(item["reason"] as? String,"CLEANUP_INVENTORY_LIMIT")
        XCTAssertEqual(strings(prepared.selection,"retry_task_ids"),[tid])
        XCTAssertNil(prepared.plans[tid],"An unreadable bounded job history cannot prove that a new byte job is needed")
        XCTAssertNotNil(prepared.plans[siblingID])
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job'")},before)
    }

    func testAgedPurgeSkipsDoneJobObservationWithOversizedAccountingHistory() throws {
        try QualificationSuite.requireEnabled()
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

    func testJobObservationScopedPayloadOverflowOnlyRefusesItsOwner() throws {
        let first = selectedJobTicket(project:uuid()),second = selectedJobTicket(project:first["project_id"] as! String),unrelated = selectedJobTicket(project:first["project_id"] as! String)
        var oversized = cleanupObservedJob(unrelated,objects:[["body":String(repeating:"é🪁",count:23_000),"task_id":first["id"]!]])
        oversized["summary"] = ["values":[1,2.5,true,NSNull(),["another_task_id":second["id"]!]] as [Any]]
        try saveObservedJobs([cleanupObservedJob(first),oversized,cleanupObservedJob(second,state:"pending")])
        var limits = TicketCleanupJobObservation.Limits();limits.rowBytes = 1024
        let observation = try jobObservation([first,second],limits:limits)
        XCTAssertFalse(try observedEntry(observation,first).pending)
        XCTAssertTrue(try observedEntry(observation,second).pending)
        let includingOwner = try jobObservation([first,second,unrelated],limits:limits)
        assertJobObservationRefused(includingOwner,unrelated)
        XCTAssertFalse(try observedEntry(includingOwner,first).pending)
        XCTAssertTrue(try observedEntry(includingOwner,second).pending)
    }

    func testJobObservationOversizedOwnerDecodesEscapesAndMatchesExactUTF8() throws {
        let pid = uuid(), id = uuid()
        let first = selectedJobTicket("task-caf\u{e9}",project:pid), second = selectedJobTicket("task-cafe\u{301}",project:pid)
        let prefix = "{\"id\":\"\(id)\",\"project_id\":\"\(pid)\",\"revision\":1.0,\"body\":\""
        let padding = String(repeating:"x",count:65534 - prefix.utf8.count)
        let raw = prefix + padding + "\\ud83d\\ude80\",\"task_\\u0069d\":\"task-cafe\\u0301\"}"
        try write {db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',1,?)",arguments:[id,pid,raw])
        }
        var limits = TicketCleanupJobObservation.Limits();limits.rowBytes = 1024
        let observation = try jobObservation([first,second],limits:limits)
        XCTAssertFalse(try observedEntry(observation,first).pending)
        XCTAssertThrowsError(try observedEntry(observation,second)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")
            XCTAssertTrue((error as? CoreError)?.message.contains("1024-byte payload bound") == true)
        }
    }

    func testJobObservationUnattributablePayloadOverflowDefersOnlyItsProject() throws {
        let foreign = selectedJobTicket(project:uuid())
        try saveObservedJobs([cleanupObservedJob(foreign,state:"pending")])
        var limits = TicketCleanupJobObservation.Limits();limits.rowBytes = 1024
        let padding = String(repeating:"x",count:2048)
        for scenario in ["missing", "nonstring", "duplicate", "id", "project", "revision", "badUnicode", "badUTF8", "largeKey", "blob"] {
            let pid = uuid(), id = uuid()
            let first = selectedJobTicket(project:pid), second = selectedJobTicket(project:pid)
            let tid = first["id"] as! String
            let identity = "\"id\":\"\(scenario == "id" ? uuid() : id)\",\"project_id\":\"\(scenario == "project" ? uuid() : pid)\",\"revision\":\(scenario == "revision" ? 2 : 1)"
            var job = "{\(identity),\"padding\":\"\(padding)\""
            switch scenario {
            case "missing": break
            case "nonstring": job += ",\"task_id\":[]"
            case "duplicate": job += ",\"task_id\":\"\(tid)\",\"task_\\u0069d\":\"\(uuid())\""
            case "badUnicode": job += ",\"task_id\":\"\(tid)\",\"body\":\"\\ud800\""
            case "largeKey": job += ",\"task_id\":\"\(tid)\",\"\(String(repeating:"k",count:65536))\":null"
            default: job += ",\"task_id\":\"\(tid)\""
            }
            var bytes = Data(job.utf8)
            if scenario == "badUTF8" {bytes.append(contentsOf:[44,34,255,34,58,48])}
            bytes.append(125)
            try write {db in
                let payload = scenario == "blob" ? "?" : "CAST(? AS TEXT)"
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',1,\(payload))",arguments:[id,pid,bytes])
            }
            let observation = try jobObservation([first,second,foreign],limits:limits)
            assertJobObservationRefused(observation,first)
            assertJobObservationRefused(observation,second)
            XCTAssertTrue(try observedEntry(observation,foreign).pending,scenario)
        }
    }

    func testJobObservationMatchesFrozenSmallJobPath() throws {
        for count in [0,32,128,384] {
            let project = uuid(), otherProject = uuid()
            let tasks = [selectedJobTicket("task-caf\u{e9}",project:project),
                         selectedJobTicket("task-cafe\u{301}",project:project),
                         selectedJobTicket(project:project),selectedJobTicket(project:otherProject)]
            let owners = tasks + [selectedJobTicket(project:project),selectedJobTicket(project:uuid()),
                                  selectedJobTicket(tasks[0]["id"] as! String,project:otherProject)]
            let states = ["retained","pending","removed"]
            let objects: [JSON] = (0..<23).map { index in
                ["stored_path":index.isMultiple(of:5) ? NSNull() : "objects/\(index % 7)",
                 "sha256":index.isMultiple(of:7) ? index : "sha-\(index % 3)",
                 "reasons":index.isMultiple(of:3) ? ["a","b"] : ["b","a"],
                 "state":states[index % states.count]]
            }
            var seed: UInt64 = 516
            func draw(_ limit: Int) -> Int {
                seed = 6364136223846793005 &* seed &+ 1
                return Int((seed >> 32) % UInt64(limit))
            }
            let jobs = (0..<count).map { _ in
                cleanupObservedJob(owners[draw(owners.count)],state:draw(6) == 0 ? "pending" : "completed",
                                   objects:(0..<draw(6)).map {_ in objects[draw(objects.count)]},
                                   cause:draw(4) == 0 ? "task_purge" : "done_evidence",
                                   kind:draw(3) == 0 ? "historical_kind" : "ticket_object_delete")
            }
            try saveObservedJobs(jobs)
            let (old,new) = try router.readers!.read { db in
                (try self.router.legacyTicketCleanupJobObservation(db,tasks:tasks),
                 try self.router.ticketCleanupJobObservation(db,tasks:tasks))
            }
            for task in tasks {
                let prior = try old.entry(task:task["id"] as! String,project:task["project_id"] as! String)
                let current = try observedEntry(new,task)
                XCTAssertEqual(prior.pending,current.pending,"\(count) generated jobs")
                for object in objects {
                    XCTAssertEqual(prior.retains(object),current.retains(object),"\(count) generated jobs")
                }
            }
        }
    }
}

// Frozen from 57a4f70 for the small-job differential test.
/// Selected-ticket accounting only, built and consumed in one read snapshot.
/// Full job payloads are validated once and discarded; no history is truncated
/// to infer that a ticket has no pending or previously retained objects.
private struct LegacyTicketCleanupJobObservation {
    struct Limits {
        var rowBytes = TicketCleanupInventory.rowByteLimit
        var ticketJobs = 4096
        var ticketObjects = 100000
        var ticketBytes = TicketCleanupInventory.byteLimit
        var totalObjects = 200000
        var totalBytes = TicketCleanupBatchInventory.byteLimit
    }
    fileprivate struct Signature: Hashable {
        let path: String?
        let sha: String?
        let reasons: [String]
        init(_ object: JSON) {
            path = object["stored_path"] as? String
            sha = object["sha256"] as? String
            reasons = strings(object,"reasons")
        }
        var charge: Int {
            (path?.utf8.count ?? 0) + (sha?.utf8.count ?? 0) + reasons.reduce(0) {$0 + $1.utf8.count + 32} + 256
        }
    }
    struct Entry {
        fileprivate let project: Data
        fileprivate var retained = Set<Signature>()
        fileprivate var jobs = 0
        fileprivate var bytes = 0
        fileprivate(set) var pending = false
        func retains(_ object: JSON) -> Bool {retained.contains(Signature(object))}
    }
    private var entries: [Data:Entry] = [:]
    private var selectionError: CoreError?
    private var errors: [Data:CoreError] = [:]
    private var retainedObjects = 0
    private var retainedBytes = 0

    func entry(task: String,project: String) throws -> Entry {
        if let selectionError {throw selectionError}
        let key = Data(task.utf8)
        if let error = errors[key] {throw error}
        guard let entry = entries[key],entry.project == Data(project.utf8) else {
            throw Self.limit("A same-snapshot, exact-ticket job observation is required.")
        }
        return entry
    }
    private static func limit(_ message: String) -> CoreError {CoreError("CLEANUP_INVENTORY_LIMIT",message)}
    fileprivate mutating func fail(_ tasks: Set<Data>) {
        for task in tasks where errors[task] == nil {
            errors[task] = Self.limit("Selected cleanup job history exceeds its bound; this ticket is deferred.")
            if let entry = entries.removeValue(forKey:task) {
                retainedObjects -= entry.retained.count;retainedBytes -= entry.bytes
            }
        }
    }
    fileprivate mutating func observe(_ job: JSON,project: Data,limits: Limits) {
        guard job["cause"] as? String == "done_evidence",let task = job["task_id"] as? String else {return}
        let key = Data(task.utf8)
        guard var entry = entries[key],entry.project == project else {return}
        entry.jobs += 1
        guard entry.jobs <= limits.ticketJobs else {fail([key]);return}
        entry.pending = entry.pending || job["state"] as? String == "pending"
        for object in job["objects"] as? [JSON] ?? [] where object["state"] as? String == "retained" {
            let signature = Signature(object)
            guard !entry.retained.contains(signature) else {continue}
            let charge = signature.charge
            guard entry.retained.count < limits.ticketObjects,entry.bytes + charge <= limits.ticketBytes,
                  retainedObjects < limits.totalObjects,retainedBytes + charge <= limits.totalBytes else {
                // Publish the locally accumulated charges before releasing this
                // ticket, so aggregate admission remains exact after refusal.
                entries[key] = entry;fail([key]);return
            }
            entry.retained.insert(signature);entry.bytes += charge
            retainedObjects += 1;retainedBytes += charge
        }
        entries[key] = entry
    }

    fileprivate init(tasks: [JSON],limits: Limits) throws {
        guard tasks.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 tickets per observation.")}
        for task in tasks {
            let stored = StoredRecord(task,family:"task"),tid = Data(try stored.string("id").utf8),pid = Data(try stored.string("project_id").utf8)
            if let previous = entries[tid] {
                guard previous.project == pid else {throw Self.limit("A selected ticket has inconsistent job scope.")}
                continue
            }
            let charge = tid.count + pid.count + 192
            guard charge <= limits.ticketBytes,charge <= limits.rowBytes,retainedBytes + charge <= limits.totalBytes else {
                selectionError = Self.limit("Selected cleanup job identities exceed their memory bound; this selection is deferred.")
                entries.removeAll();retainedBytes = 0;break
            }
            entries[tid] = Entry(project:pid,bytes:charge);retainedBytes += charge
        }
    }
    fileprivate var scopes: [Data:Set<Data>] {
        entries.reduce(into:[:]) {$0[$1.value.project,default:[]].insert($1.key)}
    }
}

extension CommandRouter {
    fileprivate func legacyTicketCleanupJobObservation(_ db: Database,tasks: [JSON],limits: LegacyTicketCleanupJobObservation.Limits = .init()) throws -> LegacyTicketCleanupJobObservation {
        var result = try LegacyTicketCleanupJobObservation(tasks:tasks,limits:limits)
        let scopes = result.scopes
        for project in scopes.keys.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            // Bound the payload before it crosses GRDB. Oversized rows cannot
            // safely supply canonical task ownership, so defer this whole scope.
            let bounded = "CASE WHEN length(CAST(data AS BLOB))<=\(limits.rowBytes) THEN data END"
            let columns = "id,project_id,type,revision,\(bounded) AS data,CAST(id AS BLOB) AS _envelope_id_bytes,CAST(project_id AS BLOB) AS _envelope_project_id_bytes,CAST(type AS BLOB) AS _envelope_type_bytes,CAST(\(bounded) AS BLOB) AS _envelope_data_bytes"
            let cursor = try Row.fetchCursor(db,sql:"SELECT " + columns + ",length(CAST(data AS BLOB)) AS original_size,typeof(data) AS original_type FROM records INDEXED BY records_scope WHERE project_id=CAST(? AS TEXT) AND type='storage_job' ORDER BY rowid",arguments:[project])
            while let row = try cursor.next() {
                try autoreleasepool {
                    guard row["original_type"] as String == "text" else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                    guard let size: Int = row["original_size"],size <= limits.rowBytes else {result.fail(scopes[project] ?? []);return}
                    let envelope = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job")
                    guard envelope.projectID.map({Data($0.utf8)}) == project else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.identityMismatch))}
                    result.observe(envelope.object,project:project,limits:limits)
                }
            }
        }
        return result
    }
}
