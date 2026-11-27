import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension MediaRoundDeletionTests {
    private func graphFixture(_ f: Fixture) throws -> (round: JSON, attachment: String) {
        let round = try cancel(f,imageRound(f,"bounded-graph.png"))
        let rid = try XCTUnwrap(round["id"] as? String)
        let first = try XCTUnwrap(f.rows("attachment").first)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let firstJob = try XCTUnwrap(f.rows("storage_job").first {$0["kind"] as? String == "attachment_import"})
        let firstPath = try XCTUnwrap(first["path"] as? String)
        let original = firstPath.hasPrefix("/") ? URL(fileURLWithPath:firstPath) : f.router.root.appendingPathComponent(firstPath)
        let originalBytes = try Data(contentsOf:original)
        let parent = original.deletingLastPathComponent()
        let principal = "fixture-graph-import"
        let digest = try XCTUnwrap(firstJob["intent_digest"] as? String)

        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db))
            try db.inTransaction {
                for _ in 1..<1025 {
                    let id = uuid(), command = uuid()
                    let job = try f.router.managedImportKey(principal:principal,command:command)
                    let file = parent.appendingPathComponent(id + ".png")
                    let relative = try f.router.managedRelative(file.path,family:"objects")
                    try originalBytes.write(to:file)
                    var attachment = first
                    attachment["id"] = id
                    attachment["path"] = relative
                    attachment["storage_job_id"] = job
                    attachment.removeValue(forKey:"preview_path")
                    try f.router.save(db,attachment,type:"attachment")
                    var imported = firstJob
                    imported["id"] = job
                    imported["attachment_id"] = id
                    imported["object_relative_path"] = relative
                    imported["state"] = "settled"
                    imported["parent_principal"] = principal
                    imported["parent_command_id"] = command
                    imported["objects"] = [["representation":"original","final":relative,
                        "stage":"staging/attachment-imports/" + job + "/original","sha256":imported["sha256"]!,
                        "size":originalBytes.count]]
                    _ = try f.router.managedImportObjects(imported)
                    try f.router.save(db,imported,type:"storage_job")
                    try db.execute(sql:"INSERT INTO commands VALUES(?,?,?,?)",
                        arguments:[principal,command,digest,try jsonString(["data":["id":id,"round_id":rid,"private":"Original journal content"]])])
                }
                try db.execute(sql:"""
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3100)
                    INSERT INTO commands(principal,command_id,digest,result)
                    SELECT 'fixture-graph-history',printf('00000000-0000-0000-0000-%012d',i),'fixture',json_object('round_id',?) FROM n
                    """,arguments:[rid])
                return .commit
            }
        }
        return (round,firstID)
    }

    func testLargeGraphHidesAndResumesBetweenBoundedWriterPasses() throws {
        let f = try Fixture()
        let fixture = try graphFixture(f)
        let rid = try XCTUnwrap(fixture.round["id"] as? String)
        let params = try input(f,fixture.round)
        let timings = LockedTestState([(String,TimeInterval,Bool)]())
        let interrupt = LockedTestState(false)
        let visibility = LockedTestState(false)
        func installTiming() {
            f.router.mediaRoundDeletionWriterProbe = {phase,hold,committed in
                timings.withLock {$0.append((phase,hold,committed))}
            }
        }
        installTiming()
        f.router.mediaRoundDeletionGraphProbe = {
            let progress = try self.deletion(f,fixture.round)
            XCTAssertEqual(progress["deletion_state"] as? String,"deleting")
            XCTAssertEqual(progress["deleted"] as? Bool,false)
            XCTAssertEqual(progress["expected_revision"] as? Int,params["expected_revision"] as? Int)
            let removed = try XCTUnwrap(progress["removed_records"] as? Int)
            let total = try XCTUnwrap(progress["total_records"] as? Int)
            XCTAssertGreaterThan(total,2050)
            let firstView = visibility.withLock { seen in
                defer {seen = true}
                return !seen
            }
            if firstView {
                XCTAssertEqual(removed,0)
                self.checks.checkError("NOT_FOUND") {try f.get(fixture.round)}
            }
            guard removed > 0 && removed < total else {return}
            self.checks.checkError("NOT_FOUND") {try f.get(fixture.round)}
            self.checks.checkError("NOT_FOUND") {
                try self.worker(f,"media_round_get",["round_id":rid,"limit":1])
            }
            self.checks.checkError("NOT_FOUND") {
                try f.router.handle(method:"attachment_read",params:["project_id":f.project,
                    "attachment_id":fixture.attachment,"representation":"original"],caller:f.owner)
            }
            let list = try self.worker(f,"media_round_list",["state":["canceled"],"limit":10])
            XCTAssertFalse((list["rows"] as? [JSON] ?? []).contains {$0["id"] as? String == rid})
            try f.router.dbQueue.read { db in
                let envelopes = try MediaRecordRegistry.envelopes(db)
                try MediaRecordRegistry.validate(envelopes)
                XCTAssertTrue(envelopes.contains {$0.id == rid},"The physical root remains between passes")
                let dangling = try Int.fetchOne(db,sql:"""
                    SELECT count(*) FROM records owner JOIN json_each(owner.data,'$.storage_job_id') edge
                    WHERE owner.type='attachment' AND NOT EXISTS(SELECT 1 FROM records WHERE id=edge.value)
                    """)
                XCTAssertEqual(dangling,0)
                let export = try f.router.projectExportRecords(db,pid:f.project)
                XCTAssertTrue((export["media_round"] as? [JSON] ?? []).isEmpty)
                XCTAssertTrue((export["attachment"] as? [JSON] ?? []).isEmpty)
                let byteState = try String.fetchOne(db,sql:"""
                    SELECT json_extract(data,'$.state') FROM records
                    WHERE type='storage_job' AND json_extract(data,'$.cause')='media_round_delete'
                    """)
                XCTAssertEqual(byteState,"deleting")
            }
            interrupt.withLock {$0 = true}
            throw CoreError("TEST_INTERRUPT","Stopped between committed graph passes.")
        }
        let interrupted = uuid()
        checks.checkError("TEST_INTERRUPT") {try self.worker(f,"media_round_delete",params,command:interrupted)}
        XCTAssertTrue(interrupt.withLock {$0})
        let before = try deletion(f,fixture.round)
        f.router.mediaRoundDeletionGraphProbe = nil
        try f.reopen()
        installTiming()
        XCTAssertEqual(try jsonString(deletion(f,fixture.round)),try jsonString(before))
        checks.checkError("NOT_FOUND") {try f.get(fixture.round)}
        checks.checkError("REVISION_CONFLICT") {
            var wrong = params
            wrong["expected_revision"] = 1
            return try self.worker(f,"media_round_delete",wrong)
        }

        let late = uuid()
        try f.router.dbQueue.write { db in
            try f.router.save(db,["id":late,"project_id":f.project,"revision":1,"retained_round":rid],type:"checkpoint")
        }
        self.checks.checkError("MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",params)}
        XCTAssertEqual(try jsonString(deletion(f,fixture.round)),try jsonString(before))
        try f.router.dbQueue.write { db in
            try f.router.save(db,["id":late,"project_id":f.project,"revision":2,"retained_round":"other"],type:"checkpoint")
        }

        let event = uuid(), lateCommand = uuid(), latePrincipal = "fixture-late-graph-history"
        try f.router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,?,'fixture','media_item_created',?,?)",
                           arguments:[event,f.project,rid,now(),try jsonString(["text":"Late original history"])])
            try db.execute(sql:"INSERT INTO commands VALUES(?,?,'fixture',?)",
                           arguments:[latePrincipal,lateCommand,try jsonString(["round_id":rid,"private":"Late original reply"])])
        }
        let command = uuid()
        let first = try worker(f,"media_round_delete",params,command:command)
        XCTAssertEqual(first["deleted"] as? Bool,true)
        XCTAssertEqual((first["counts"] as? [String:Int])?["attachment"],1025)
        XCTAssertEqual((first["counts"] as? [String:Int])?["storage_job"],1027)
        XCTAssertEqual((first["files"] as? [JSON])?.filter {$0["representation"] as? String == "original"}.count,1025)
        try f.router.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT kind FROM events WHERE id=?",arguments:[event]),MediaRoundDeletionHistory.redactedEventKind)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[latePrincipal,lateCommand]),CommandRouter.prunedResult)
        }
        let later = try deletion(f,fixture.round)
        XCTAssertEqual(later["byte_deletion_receipt_id"] as? String,first["byte_deletion_receipt_id"] as? String)
        var replay = try worker(f,"media_round_delete",params,command:command)
        XCTAssertEqual(replay.removeValue(forKey:"replayed") as? Bool,true)
        XCTAssertEqual(try jsonString(replay),try jsonString(first))
        let holds = timings.withLock {$0}
        XCTAssertGreaterThan(holds.filter {$0.0 == "media_round_graph_erase" && $0.2}.count,2)
        XCTAssertTrue(holds.contains {$0.0 == "media_round_history_pass" && $0.2})
        XCTAssertEqual(holds.filter {$0.0 == "media_round_graph_publish" && $0.2}.count,1)
        for (phase,seconds,_) in holds {XCTAssertLessThan(seconds,1,"\(phase) held the writer for \(seconds)s")}
    }

    func testRetainedMediaHoldPreventsDanglingGraphReference() throws {
        let f = try Fixture(), round = try cancel(f,imageRound(f,"retained-media-hold.png"))
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let anchor = uuid(), hold = uuid()
        try f.router.dbQueue.write { db in
            try f.router.save(db,["id":anchor,"project_id":f.project,"kind":"media_attachment_owner",
                "owner_kind":MediaAttachmentOwnerKind.intake.rawValue,"state":"active","revision":1],type:"storage_job")
            try f.router.save(db,["id":hold,"project_id":f.project,"kind":"media_reference","owner_id":anchor,
                "owner_kind":MediaAttachmentOwnerKind.intake.rawValue,"attachment_id":attachment["id"]!,"sha256":attachment["sha256"]!,
                "size":attachment["size"]!,"state":"released","revision":1],type:"storage_hold")
            try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db))
        }
        let params = try input(f,round)
        try assertRefusal(f,"MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",params)}
    }

    func testGraphReceiptKeepsCompletedTicketCaptureAndItsReplay() throws {
        let f = try Fixture()
        let (round,task,attachment) = try ticketCapture(f,category:"done")
        let rid = try XCTUnwrap(round["id"] as? String)
        let aid = try XCTUnwrap(attachment["id"] as? String)
        let path = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let original = try Data(contentsOf:URL(fileURLWithPath:path))
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db))
            try db.inTransaction {
                for _ in 0..<MediaRoundDeletionGraph.rowLimit {
                    try f.router.save(db,["id":uuid(),"project_id":f.project,"revision":1,"round_id":rid,
                        "record_references":[["type":"media_round","id":rid]]],type:"media_intake_row")
                }
                return .commit
            }
        }

        let command = uuid(),params = try input(f,round)
        let first = try worker(f,"media_round_delete",params,command:command)
        XCTAssertEqual((first["kept_attachments"] as? [JSON])?.first?["attachment_id"] as? String,aid)
        XCTAssertEqual((first["kept_attachments"] as? [JSON])?.first?["task_id"] as? String,task["id"] as? String)
        XCTAssertEqual((first["files"] as? [JSON])?.count,0)
        let retained = try f.record(aid,"attachment")
        XCTAssertNil(retained["storage_job_id"])
        XCTAssertNil(retained["attachment_owner_id"])
        XCTAssertEqual((retained["media_capture_history"] as? JSON)?["round_id"] as? String,rid)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),original)
        XCTAssertEqual(try jsonString(deletion(f,round)["kept_attachments"]!),try jsonString(first["kept_attachments"]!))
        var replay = try worker(f,"media_round_delete",params,command:command)
        XCTAssertEqual(replay.removeValue(forKey:"replayed") as? Bool,true)
        XCTAssertEqual(try jsonString(replay),try jsonString(first))
    }

    func testScheduledGraphInterruptionKeepsItsErrorAfterVisibilityEpoch() throws {
        let f = try Fixture(), draft = try f.round(f.type(checks.schema()))
        for _ in 0..<32 {_ = try f.item(draft)}
        let round = try cancel(f,draft)
        let registration = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:try XCTUnwrap(registration["installation"] as? String),
                            projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let lane = DispatchQueue(label:"test-media-graph-interruption")
        let erased = LockedTestState(false)
        f.router.configureCommandOperations(on:lane)
        f.router.mediaRoundDeletionWriterProbe = {phase,_,committed in
            if phase == "media_round_graph_erase" && committed {erased.withLock {$0 = true}}
        }
        f.router.mediaRoundDeletionGraphProbe = {
            if erased.withLock({$0}) {throw CoreError("TEST_INTERRUPT","Stopped after a committed erase pass.")}
        }
        let params = try input(f,round)
        let accepted = try worker(f,"media_round_delete",params,as:caller)
        XCTAssertEqual(accepted["state"] as? String,"queued")
        let ready = DispatchSemaphore(value:0)
        lane.async {ready.signal()}
        XCTAssertEqual(ready.wait(timeout:.now() + 30),.success)
        let firstID = try XCTUnwrap(accepted["operation_id"] as? String)
        func status(_ id: String) throws -> JSON {
            let reply = try f.router.handle(method:"operation_get",params:["project_id":f.project,"operation_id":id],caller:caller)
            return try XCTUnwrap(reply["data"] as? JSON)
        }
        let operation = try status(firstID)
        XCTAssertEqual(operation["operation_id"] as? String,firstID)
        XCTAssertEqual(operation["state"] as? String,"failed")
        XCTAssertEqual((operation["error"] as? JSON)?["code"] as? String,"TEST_INTERRUPT")
        XCTAssertEqual((operation["error"] as? JSON)?["message"] as? String,"Stopped after a committed erase pass.")
        let partial = try deletion(f,round)
        XCTAssertEqual(partial["deletion_state"] as? String,"deleting")
        XCTAssertGreaterThan(int(partial,"removed_records"),0)
        XCTAssertLessThan(int(partial,"removed_records"),int(partial,"total_records"))
        let key = try MediaRoundDeletionGraph.key(MediaRoundDeletionHistory.progressKey(project:f.project,round:round["id"] as! String))
        let provisional = try f.router.dbQueue.read {try XCTUnwrap(MediaRoundDeletionGraph.load($0,key,as:MediaRoundDeletionGraph.Progress.self)).receipt}

        try f.reopen()
        XCTAssertEqual(try jsonString(deletion(f,round)),try jsonString(partial))
        let finished = DispatchSemaphore(value:0)
        f.router.configureCommandOperations(on:lane) {_, terminal in if terminal {finished.signal()}}
        let original = try worker(f,"media_round_delete",params,as:caller,command:try XCTUnwrap(accepted["command_id"] as? String))
        XCTAssertEqual(original["operation_id"] as? String,firstID)
        XCTAssertEqual(original["state"] as? String,"failed")
        var retry = params
        retry["expected_revision"] = partial["expected_revision"]
        let fresh = try worker(f,"media_round_delete",retry,as:caller)
        let freshID = try XCTUnwrap(fresh["operation_id"] as? String)
        XCTAssertNotEqual(freshID,firstID)
        XCTAssertEqual(finished.wait(timeout:.now() + 30),.success)
        let resumed = try status(freshID)
        let diagnostic = try jsonString(resumed)
        XCTAssertEqual(resumed["state"] as? String,"succeeded",diagnostic)
        XCTAssertEqual(try deletion(f,round)["byte_deletion_receipt_id"] as? String,provisional)
    }

    func testSmallRoundMatchesEarlierAtomicGraphAndHistoryWrites() throws {
        for size in [0,1,4,12] {
            let f = try Fixture(), draft = try f.round(f.type(checks.schema()))
            for _ in 0..<size {_ = try f.item(draft)}
            let round = try cancel(f,draft), rid = try XCTUnwrap(round["id"] as? String), params = try input(f,round)
            let principal = "fixture-small-atomic"
            let matched = uuid(), retained = uuid()
            try f.router.dbQueue.write { db in
                try db.execute(sql:"INSERT INTO commands VALUES(?,?,?,?),(?,?,?,?)",arguments:[
                    principal,matched,"fixture",try jsonString(["nested":[rid:"private"]]),
                    principal,retained,"fixture",try jsonString(["round":"independent"])])
            }

            func state(_ db: Database) throws -> [String] {
                try String.fetchAll(db,sql:"""
                    SELECT type||':'||id FROM records WHERE project_id=? AND type LIKE 'media_%'
                    UNION ALL SELECT 'event:'||id FROM events WHERE project_id=? AND kind<>'media_round_deleted'
                    UNION ALL SELECT 'command:'||command_id||':'||result FROM commands WHERE principal=?
                    ORDER BY 1
                    """,arguments:[f.project,f.project,principal])
            }
            let baseline = try f.router.dbQueue.writeWithoutTransaction { db -> ([String],Int) in
                let ids = try f.router.mediaRoundOwnedHistory(db,round:round).compactMap {$0["id"] as? String}
                let history = try MediaRoundDeletionHistory.select(db,project:f.project,owned:Set(ids.map {Data($0.utf8)}),
                    progressKey:MediaRoundDeletionHistory.progressKey(project:f.project,round:rid))
                XCTAssertFalse(history.continuing)
                var expected: [String] = []
                try db.inSavepoint {
                    for id in ids {try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
                    for id in history.events {try db.execute(sql:"DELETE FROM events WHERE id=?",arguments:[id])}
                    for (actor,id) in history.commands {
                        try db.execute(sql:"UPDATE commands SET result=? WHERE principal=? AND command_id=?",
                            arguments:[CommandRouter.prunedResult,actor,id])
                    }
                    expected = try state(db)
                    return .rollback
                }
                return (expected,ids.count)
            }

            let holds = LockedTestState([(String,TimeInterval,Bool)]())
            f.router.mediaRoundDeletionWriterProbe = {phase,hold,committed in
                holds.withLock {$0.append((phase,hold,committed))}
            }
            let result = try worker(f,"media_round_delete",params)
            XCTAssertEqual((result["counts"] as? [String:Int])?.values.reduce(0,+),baseline.1)
            XCTAssertEqual(try f.router.dbQueue.read(state),baseline.0)
            let writer = holds.withLock {$0}
            XCTAssertEqual(writer.map(\.0),["media_round_deletion_commit"])
            XCTAssertEqual(writer.map(\.2),[true])
            XCTAssertLessThan(try XCTUnwrap(writer.first?.1),1)
        }
    }
}
