import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension MediaRoundDeletionTests {
    private func addMatchedHistoryCommands(_ f: Fixture, round: String) throws {
        try f.router.dbQueue.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?)
                INSERT INTO commands(principal,command_id,digest,result)
                SELECT 'fixture-media-history',printf('00000000-0000-0000-0000-%012d',i),'fixture-digest',json_object('round_id',?) FROM n
                """, arguments:[MediaRoundDeletionHistory.entryLimit+1,round])
        }
    }

    private func historyProgress(_ f: Fixture, round: String) throws -> String? {
        let key = try MediaRoundDeletionHistory.progressKey(project: f.project, round: round)
        return try f.router.dbQueue.read { try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) }
    }

    private func exactHistoryResult(_ f: Fixture, principal: String, command: String) throws -> String? {
        try f.router.dbQueue.read { try String.fetchOne($0,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[principal,command]) }
    }

    func testOversizedHistoryReopensAfterBoundedPassWithImportReceiptAndEventReferences() throws {
        let f = try Fixture(), round = try cancel(f,imageRound(f,"history-import-recovery.png"))
        let rid = try XCTUnwrap(round["id"] as? String), event = uuid(), retained = uuid(), late = uuid()
        let job = try XCTUnwrap(f.rows("storage_job").first { $0["kind"] as? String == "attachment_import" })
        let jobID = try XCTUnwrap(job["id"] as? String)
        let principal = try XCTUnwrap(job["parent_principal"] as? String), command = try XCTUnwrap(job["parent_command_id"] as? String)
        let receipt = try XCTUnwrap(exactHistoryResult(f,principal:principal,command:command))
        let attachment = try XCTUnwrap(job["attachment_id"] as? String)
        XCTAssertTrue(receipt.contains(attachment),"The real semantic journal contains the owned attachment identity")
        XCTAssertEqual(job["state"] as? String,"committed","The fixture must exercise live import recovery")
        try f.router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,?,'fixture','media_item_created',?,?)",
                           arguments:[event,f.project,rid,now(),try jsonString(["text":"Private event body"])])
            try f.router.save(db,["id":retained,"project_id":f.project,"revision":1,"event_id":event],type:"checkpoint")
        }
        try addMatchedHistoryCommands(f,round:rid)
        let params = try input(f,round), interrupted = uuid()
        f.router.mediaRoundDeletionPreparationProbe = {
            guard try self.historyProgress(f,round:rid) != nil else { return }
            XCTAssertEqual(try self.historyProgress(f,round:rid),"1")
            XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
            XCTAssertEqual(try f.record(retained,"checkpoint")["event_id"] as? String,event)
            XCTAssertEqual(try self.exactHistoryResult(f,principal:principal,command:command),receipt)
            XCTAssertEqual(try f.record(jobID,"storage_job")["state"] as? String,"committed")
            self.checks.checkError("NOT_FOUND") {try self.deletion(f,round)}
            try f.router.dbQueue.read { db in
                let count = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal='fixture-media-history' AND result=?",arguments:[CommandRouter.prunedResult]) ?? 0
                XCTAssertGreaterThan(count,0)
                XCTAssertLessThanOrEqual(count,MediaRoundDeletionHistory.passLimit)
                let identity = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT project_id,entity_id,kind,data FROM events WHERE id=?",arguments:[event]))
                XCTAssertEqual(identity["project_id"] as String?,f.project)
                XCTAssertNil(identity["entity_id"] as String?)
                XCTAssertEqual(identity["kind"] as String,MediaRoundDeletionHistory.redactedEventKind)
                XCTAssertEqual(identity["data"] as String,"{}")
            }
            throw CoreError("TEST_INTERRUPT","Interrupted after the first committed pass.")
        }
        checks.checkError("TEST_INTERRUPT") {try self.worker(f,"media_round_delete",params,command:interrupted)}
        f.router.mediaRoundDeletionPreparationProbe = nil
        try f.reopen()
        XCTAssertEqual(try historyProgress(f,round:rid),"1")
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),receipt)
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db),"Recovery can still consume the exact persisted receipt")
            try f.router.withValidatedDomainTransaction(db) {
                try f.router.save(db,["id":late,"project_id":f.project,"revision":1,"event_id":event],type:"checkpoint")
                return .commit
            }
        }
        XCTAssertEqual(try f.record(jobID,"storage_job")["state"] as? String,"settled")
        let resumed = uuid(), result = try worker(f,"media_round_delete",params,command:resumed)
        XCTAssertEqual(result["deleted"] as? Bool,true)
        XCTAssertNil(try historyProgress(f,round:rid))
        checks.checkError("NOT_FOUND") {try f.get(round)}
        checks.checkError("NOT_FOUND") {try f.record(jobID,"storage_job")}
        let retired = try XCTUnwrap(exactHistoryResult(f,principal:principal,command:command))
        XCTAssertTrue(CommandRouter.isPrunedResult(jsonObject(retired)))
        XCTAssertFalse(retired.contains(attachment))
        XCTAssertEqual(try f.record(late,"checkpoint")["event_id"] as? String,event)
        XCTAssertEqual(try f.record(retained,"checkpoint")["event_id"] as? String,event)
        try f.router.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE id=? AND kind=?",arguments:[event,MediaRoundDeletionHistory.redactedEventKind]),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal='fixture-media-history' AND digest='fixture-digest' AND result=?",arguments:[CommandRouter.prunedResult]),MediaRoundDeletionHistory.entryLimit+1)
        }
        XCTAssertEqual(try worker(f,"media_round_delete",params,command:resumed)["replayed"] as? Bool,true)
        let page = try XCTUnwrap(f.router.handle(method:"workspace_page",params:["project_id":f.project,"surface":"activity","text":MediaRoundDeletionHistory.redactedEventKind],caller:f.owner)["data"] as? JSON)
        XCTAssertEqual((page["rows"] as? [JSON])?.count,0)
        let snapshot = try XCTUnwrap(f.router.handle(method:"snapshot",params:[:],caller:f.owner)["data"] as? JSON)
        XCTAssertFalse((snapshot["events"] as? [JSON] ?? []).contains { $0["id"] as? String == event })
    }

    func testSettledImportHistoryOverflowKeepsJournalAndGraphAcrossReopen() throws {
        let f = try Fixture(), (round,_,_) = try ticketCapture(f,category:"done")
        let rid = try XCTUnwrap(round["id"] as? String)
        let original = try XCTUnwrap(f.rows("storage_job").first { $0["kind"] as? String == "attachment_import" })
        let originalID = try XCTUnwrap(original["id"] as? String)
        let ownerID = try XCTUnwrap(original["attachment_owner_id"] as? String)
        let actualPrincipal = try XCTUnwrap(original["parent_principal"] as? String)
        let actualCommand = try XCTUnwrap(original["parent_command_id"] as? String)
        let actualAttachment = try XCTUnwrap(original["attachment_id"] as? String)
        let principal = "fixture-settled-media-import"
        let digest = String(repeating:"a",count:64)
        let namespace = "objects/project-" + ChecklistCore.hash(Data(f.project.utf8)) + "/"
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db))
            try db.inTransaction {
                for _ in 0..<MediaRoundDeletionHistory.passLimit {
                    let command = uuid(), attachment = uuid()
                    let job = try f.router.managedImportKey(principal:principal,command:command)
                    try f.router.save(db,["id":job,"project_id":f.project,"kind":"attachment_import","state":"settled",
                        "attachment_owner_id":ownerID,"attachment_id":attachment,"object_relative_path":namespace + attachment,
                        "parent_principal":principal,"parent_command_id":command,"intent_digest":digest,"revision":1],type:"storage_job")
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(?,?,?,?)",
                        arguments:[principal,command,digest,try jsonString(["data":["round_id":rid,"id":attachment,"title":"Private capture"]])])
                }
                return .commit
            }
        }
        try addMatchedHistoryCommands(f,round:rid)
        XCTAssertEqual(try f.record(originalID,"storage_job")["state"] as? String,"settled")
        let stable = try exactRecords(f,["media_round","storage_job"])
        func observedJournal() throws -> (matched: Int, pruned: Int) {
            try f.router.dbQueue.read { db in
                let row = try XCTUnwrap(Row.fetchOne(db,sql:"""
                    SELECT count(*) matched,sum(json_extract(result,'$.pruned')=1) pruned FROM commands c JOIN records r ON r.type='storage_job'
                    AND json_extract(r.data,'$.parent_principal')=c.principal AND json_extract(r.data,'$.parent_command_id')=c.command_id
                    AND json_extract(r.data,'$.intent_digest')=c.digest WHERE c.principal=?
                    """,arguments:[principal]))
                return (row["matched"],row["pruned"])
            }
        }
        f.router.mediaRoundDeletionPreparationProbe = {
            guard try self.historyProgress(f,round:rid) != nil else {return}
            throw CoreError("TEST_INTERRUPT","Interrupted after a committed settled-import history pass.")
        }
        let params = try input(f,round)
        checks.checkError("TEST_INTERRUPT") {try self.worker(f,"media_round_delete",params)}
        f.router.mediaRoundDeletionPreparationProbe = nil
        let before = try observedJournal()
        XCTAssertEqual(before.matched,MediaRoundDeletionHistory.passLimit)
        XCTAssertGreaterThan(before.pruned,0)
        XCTAssertLessThan(before.pruned,before.matched)
        XCTAssertEqual(try historyProgress(f,round:rid),"1")
        XCTAssertEqual(try exactRecords(f,["media_round","storage_job"]),stable)
        try f.reopen()
        XCTAssertEqual(try observedJournal().pruned,before.pruned)
        XCTAssertEqual(try exactRecords(f,["media_round","storage_job"]),stable)
        let tombstone = try XCTUnwrap(exactHistoryResult(f,principal:actualPrincipal,command:actualCommand))
        XCTAssertFalse(tombstone.contains(actualAttachment))
        XCTAssertTrue(MediaRoundDeletionImportRecovery.provesSettlement(jsonObject(tombstone),job:originalID,attachment:actualAttachment))
        XCTAssertFalse(MediaRoundDeletionImportRecovery.provesSettlement(jsonObject(tombstone),job:originalID,attachment:uuid()))
        let originalFile = f.router.root.appendingPathComponent(try XCTUnwrap(original["object_relative_path"] as? String))
        let heldFile = f.base.appendingPathComponent("retired-receipt-original")
        try FileManager.default.moveItem(at:originalFile,to:heldFile)
        checks.checkError("MANAGED_FILE_UNAVAILABLE") {
            try f.router.handle(method:"attachment_read",params:["project_id":f.project,
                "attachment_id":actualAttachment,"representation":"original"],caller:f.owner)
        }
        XCTAssertEqual(try f.record(originalID,"storage_job")["state"] as? String,"repair_required")
        try FileManager.default.moveItem(at:heldFile,to:originalFile)
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db),"Late repair uses the exact, content-free settlement proof")
        }
        XCTAssertEqual(try f.record(originalID,"storage_job")["state"] as? String,"settled")
        XCTAssertEqual(try worker(f,"media_round_delete",params)["deleted"] as? Bool,true)
        XCTAssertNil(try historyProgress(f,round:rid))
        checks.checkError("NOT_FOUND") {try f.get(round)}
        XCTAssertTrue(try f.rows("storage_job").allSatisfy { $0["kind"] as? String != "attachment_import" })
        XCTAssertEqual(try f.router.dbQueue.read { db in
            try Int.fetchOne(db,sql:"SELECT count(*) FROM commands WHERE principal=? AND digest=? AND json_extract(result,'$.pruned')=1",
                arguments:[principal,digest])
        },MediaRoundDeletionHistory.passLimit)
    }

    func testContinuedHistoryWaitsForLiveRepairAndResumesTheSameOperation() throws {
        let f = try Fixture(), round = try cancel(f,imageRound(f,"pending-history.png"))
        let rid = try XCTUnwrap(round["id"] as? String)
        let job = try XCTUnwrap(f.rows("storage_job").first { $0["kind"] as? String == "attachment_import" })
        let jobID = try XCTUnwrap(job["id"] as? String), principal = try XCTUnwrap(job["parent_principal"] as? String)
        let importCommand = try XCTUnwrap(job["parent_command_id"] as? String)
        let receipt = try XCTUnwrap(exactHistoryResult(f,principal:principal,command:importCommand))
        let registration = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:try XCTUnwrap(registration["installation"] as? String),
                            projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let original = f.router.root.appendingPathComponent(try XCTUnwrap(job["object_relative_path"] as? String))
        let held = f.base.appendingPathComponent("held-original")
        try FileManager.default.moveItem(at:original,to:held)
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertEqual(try f.router.reconcileManagedAttachmentImports(db),.retryPending)
        }
        XCTAssertEqual(try f.record(jobID,"storage_job")["state"] as? String,"repair_required")
        try addMatchedHistoryCommands(f,round:rid)

        let lane = DispatchQueue(label:"test-media-history-recovery"), parked = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
        f.router.configureCommandOperations(on:lane) { _, terminal in
            if terminal {finished.signal()} else {parked.signal()}
        }
        let command = uuid(), params = try input(f,round)
        let accepted = try worker(f,"media_round_delete",params,as:caller,command:command)
        let operation = try XCTUnwrap(accepted["operation_id"] as? String)
        func readStatus() throws -> JSON {
            let reply = try f.router.handle(method:"operation_get",params:["operation_id":operation,"project_id":f.project],caller:caller)
            return try XCTUnwrap(reply["data"] as? JSON)
        }
        guard parked.wait(timeout:.now() + 20) == .success else {return XCTFail("Deletion did not park for import recovery")}
        let status = try readStatus()
        XCTAssertEqual(status["state"] as? String,"running")
        XCTAssertEqual(status["waiting_reason"] as? String,"media_import_recovery")
        XCTAssertNil(status["error"])
        XCTAssertNotNil(try historyProgress(f,round:rid))
        XCTAssertEqual(try f.get(round)["revision"] as? Int,round["revision"] as? Int)
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:importCommand),receipt)
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertEqual(try f.router.reconcileManagedAttachmentImports(db),.suspended)
        }
        XCTAssertFalse(f.router.commandOperations.mediaImportWaits.needsTurn,"An unavailable file stops automatic recovery turns")
        try FileManager.default.moveItem(at:held,to:original)
        let replay = try worker(f,"media_round_delete",params,as:caller,command:command)
        XCTAssertEqual(replay["operation_id"] as? String,operation)
        XCTAssertEqual(replay["waiting_reason"] as? String,"media_import_recovery")
        XCTAssertTrue(f.router.commandOperations.mediaImportWaits.needsTurn,"Exact replay rearms a suspended import")
        try f.router.dbQueue.writeWithoutTransaction { db in
            XCTAssertNil(try f.router.reconcileManagedAttachmentImports(db),"Repair consumes the original persisted payload")
        }
        guard finished.wait(timeout:.now() + 20) == .success else {return XCTFail("The accepted deletion did not resume after repair")}
        let completed = try readStatus()
        XCTAssertEqual(completed["state"] as? String,"succeeded")
        XCTAssertNil(completed["waiting_reason"])
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:importCommand),CommandRouter.prunedResult)
        checks.checkError("NOT_FOUND") {try f.get(round)}
    }

    func testLiveImportReceiptOverflowDoesNotConsumeFinalBatchCapacity() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String), principal = "fixture-live-import-history"
        let count = MediaRoundDeletionHistory.passLimit + 1
        var owned = Set([Data(rid.utf8)])
        try addMatchedHistoryCommands(f,round:rid)
        try f.router.dbQueue.write { db in
            let result = try jsonString(["data":["id":rid]])
            for state in ["committed","repair_required"] {
                for _ in 0..<count {
                    let command = uuid(), job = try f.router.managedImportKey(principal:principal,command:command)
                    owned.insert(Data(job.utf8))
                    try f.router.save(db,["id":job,"project_id":f.project,"kind":"attachment_import","state":state,
                        "parent_principal":principal,"parent_command_id":command,"revision":1],type:"storage_job")
                    try db.execute(sql:"INSERT INTO commands VALUES (?,?,'fixture-digest',?)",arguments:[principal,command,result])
                }
            }
            let progress = try MediaRoundDeletionHistory.progressKey(project:f.project,round:rid)
            var passes = 0
            repeat {
                let pass = try MediaRoundDeletionHistory.select(db,project:f.project,owned:owned,progressKey:progress,continuing:passes != 0)
                XCTAssertFalse(pass.commands.contains { $0.0 == principal })
                XCTAssertLessThanOrEqual(pass.events.count + pass.commands.count,MediaRoundDeletionHistory.passLimit)
                if pass.more {XCTAssertFalse(pass.commands.isEmpty && pass.events.isEmpty)}
                try pass.apply(db)
                passes += 1
                if !pass.more {break}
            } while passes < 10
            XCTAssertEqual(passes,5)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM commands WHERE principal=? AND result=?",arguments:[principal,result]),count * 2)
        }
    }

    func testOversizedHistoryContinuesAcrossSixteenMiBOfSelectedIdentities() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String), prefix = "fixture-media-history-bytes-"
        try f.router.dbQueue.write { db in
            let result = try jsonString(["round_id":rid])
            for index in 0..<17 {
                let principal = prefix + String(index) + String(repeating:"x",count:1024*1024)
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(?,?,'fixture',?)",arguments:[principal,uuid(),result])
            }
        }
        var observedCommittedPage = false
        f.router.mediaRoundDeletionPreparationProbe = {
            if try self.historyProgress(f,round:rid) != nil {
                observedCommittedPage = true
                XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
            }
        }
        defer { f.router.mediaRoundDeletionPreparationProbe = nil }
        let result = try worker(f,"media_round_delete",input(f,round))
        XCTAssertEqual(result["deleted"] as? Bool,true)
        XCTAssertTrue(observedCommittedPage)
        XCTAssertEqual(try f.router.dbQueue.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE principal GLOB ? AND result=?",arguments:[prefix+"*",CommandRouter.prunedResult]) },17)
    }

    func testOversizedHistoryFencesAResultDependentCreatedAfterPreparation() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String), jobID = uuid()
        let principal = "fixture-media-history", command = "00000000-0000-0000-0000-000000000001"
        try addMatchedHistoryCommands(f,round:rid)
        let original = try exactHistoryResult(f,principal:principal,command:command)
        f.router.mediaRoundDeletionPreparationProbe = {
            try f.router.dbQueue.write { db in
                try f.router.save(db,["id":jobID,"project_id":f.project,"kind":"ticket_object_delete","state":"completed","revision":1,"parent_principal":principal,"parent_command_id":command],type:"storage_job")
            }
        }
        let params = try input(f,round)
        XCTAssertThrowsError(try worker(f,"media_round_delete",params)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual((error as? CoreError)?.details["check"] as? String,"history_result_dependent")
        }
        f.router.mediaRoundDeletionPreparationProbe = nil
        XCTAssertNil(try historyProgress(f,round:rid))
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),original)
        checks.checkError("MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",params)}
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),original)
        XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
    }

    func testFinalHistoryPassFencesRelocatedOwnedRecordWithIdenticalContent() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String)
        try addMatchedHistoryCommands(f,round:rid)
        let params = try input(f,round)
        f.router.mediaRoundDeletionPreparationProbe = {
            guard try self.historyProgress(f,round:rid) == "4" else {return}
            try f.router.dbQueue.write { db in
                try db.execute(sql:"UPDATE records SET rowid=(SELECT MAX(rowid)+1 FROM records) WHERE id=?",arguments:[rid])
            }
        }
        XCTAssertThrowsError(try worker(f,"media_round_delete",params)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual((error as? CoreError)?.details["check"] as? String,"planned_record_changed")
            XCTAssertEqual((error as? CoreError)?.details["record_id"] as? String,rid)
        }
        f.router.mediaRoundDeletionPreparationProbe = nil
        XCTAssertEqual(try historyProgress(f,round:rid),"4")
        XCTAssertEqual(try f.get(round)["revision"] as? Int,round["revision"] as? Int)
        XCTAssertEqual(try worker(f,"media_round_delete",params)["deleted"] as? Bool,true)
    }

    func testContinuedHistoryPreservesTerminalDeletionAndPreviewAcrossReopen() throws {
        let f = try Fixture(), round = try f.round(f.type(checks.schema()))
        let rid = try XCTUnwrap(round["id"] as? String)
        let registration = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:try XCTUnwrap(registration["installation"] as? String),
                            projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let lane = DispatchQueue(label:"test-media-history-terminal-operations")
        f.router.configureCommandOperations(on:lane)
        defer { f.router?.mediaRoundDeletionPreparationProbe = nil }
        func drain() throws {
            let finished = DispatchSemaphore(value:0)
            lane.async {finished.signal()}
            guard finished.wait(timeout:.now()+30) == .success else {
                throw CoreError("TEST_TIMEOUT","The operation lane did not finish.")
            }
        }
        func read(_ accepted: JSON) throws -> JSON {
            let id = try XCTUnwrap(accepted["operation_id"] as? String)
            let reply = try f.router.handle(method:"operation_get",params:["project_id":f.project,"operation_id":id],caller:caller)
            return try XCTUnwrap(reply["data"] as? JSON)
        }

        let previewCommand = uuid()
        let preview = try worker(f,"media_intake_preview",["round_id":rid,"text":"Private fixture preview\n"],as:caller,command:previewCommand)
        try drain()
        let previewID = try XCTUnwrap(preview["operation_id"] as? String)
        let previewResult = try XCTUnwrap(exactHistoryResult(f,principal:caller.principal,command:previewCommand))
        XCTAssertEqual(jsonObject(previewResult)["round_id"] as? String,rid)
        XCTAssertEqual(try f.router.dbQueue.read {try f.router.operationRecord($0,id:previewID)?["state"] as? String},"succeeded")

        let canceled = try cancel(f,round)
        let originalInput = try input(f,canceled), originalCommand = uuid()
        let canceledRevision = try XCTUnwrap(canceled["revision"] as? Int)
        f.router.mediaRoundDeletionPreparationProbe = { [router = f.router!, project = f.project, owner = f.owner] in
            _ = try router.executeMediaCommand(method:"media_round_archive",params:["project_id":project,"round_id":rid,
                "expected_revision":canceledRevision,"command_id":uuid()],caller:owner)
        }
        let original = try worker(f,"media_round_delete",originalInput,as:caller,command:originalCommand)
        try drain()
        f.router.mediaRoundDeletionPreparationProbe = nil
        let first = try read(original), firstError = try XCTUnwrap(first["error"] as? JSON)
        XCTAssertEqual(first["state"] as? String,"failed")
        XCTAssertEqual(firstError["code"] as? String,"MEDIA_CONTEXT_CHANGED")
        XCTAssertEqual((firstError["details"] as? JSON)?["record_id"] as? String,rid)
        let originalID = try XCTUnwrap(original["operation_id"] as? String)
        let stored = try f.router.dbQueue.read {try f.router.operationRecord($0,id:originalID)}
        XCTAssertEqual(stored?["recoverable"] as? Bool,false)
        let errorCommand = try XCTUnwrap(stored?["error_result_command_id"] as? String)
        let errorResult = try XCTUnwrap(exactHistoryResult(f,principal:caller.principal,command:errorCommand))
        let archived = try f.get(round), currentInput = try input(f,archived)
        XCTAssertEqual(archived["state"] as? String,"archived")

        // Insert the filler after the two receipts so the old selector reaches
        // both receipts in a nonfinal command pass, with more history remaining.
        try addMatchedHistoryCommands(f,round:rid)
        let progressKey = try MediaRoundDeletionHistory.progressKey(project:f.project,round:rid)
        f.router.mediaRoundDeletionPreparationProbe = { [router = f.router!] in
            let progress = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[progressKey])}
            if progress != nil {
                throw CoreError("TEST_INTERRUPT","Interrupted after a nonfinal history pass.")
            }
        }
        let interrupted = try worker(f,"media_round_delete",currentInput,as:caller)
        try drain()
        f.router.mediaRoundDeletionPreparationProbe = nil
        XCTAssertEqual((try read(interrupted)["error"] as? JSON)?["code"] as? String,"TEST_INTERRUPT")

        func verifyBoundary(file: StaticString = #filePath,line: UInt = #line) {
            XCTAssertEqual(try historyProgress(f,round:rid),"1",file:file,line:line)
            XCTAssertEqual(try f.get(round)["revision"] as? Int,archived["revision"] as? Int,file:file,line:line)
            XCTAssertEqual(try exactHistoryResult(f,principal:caller.principal,command:errorCommand),errorResult,file:file,line:line)
            XCTAssertEqual(try jsonString(read(original)),try jsonString(first),file:file,line:line)
            XCTAssertEqual(try jsonString(worker(f,"media_round_delete",originalInput,as:caller,command:originalCommand)),try jsonString(first),file:file,line:line)
            XCTAssertTrue(try exactHistoryResult(f,principal:caller.principal,command:previewCommand) == previewResult,"The preview journal changed",file:file,line:line)
            var previewStatus: JSON?
            XCTAssertNoThrow(previewStatus = try read(preview),file:file,line:line)
            XCTAssertEqual(previewStatus?["state"] as? String,"succeeded",file:file,line:line)
            let result = previewStatus?["result"] as? JSON
            XCTAssertEqual(result?["command_id"] as? String,previewCommand,file:file,line:line)
            XCTAssertTrue(try jsonString(result?["data"] as? JSON ?? [:]) == previewResult,"The preview result changed",file:file,line:line)
        }
        verifyBoundary()
        try f.reopen()
        f.router.configureCommandOperations(on:lane)
        verifyBoundary()

        let resumed = try worker(f,"media_round_delete",currentInput,as:caller)
        try drain()
        XCTAssertEqual(try read(resumed)["state"] as? String,"succeeded")
        XCTAssertNil(try historyProgress(f,round:rid))
        checks.checkError("NOT_FOUND") {try f.get(round)}
        XCTAssertEqual(try exactHistoryResult(f,principal:caller.principal,command:errorCommand),CommandRouter.prunedResult)
        XCTAssertEqual(try exactHistoryResult(f,principal:caller.principal,command:previewCommand),CommandRouter.prunedResult)
        checks.checkError("COMMAND_RESULT_EXPIRED") {try read(original)}
        checks.checkError("COMMAND_RESULT_EXPIRED") {try read(preview)}
        checks.checkError("COMMAND_RESULT_EXPIRED") {try self.worker(f,"media_round_delete",originalInput,as:caller,command:originalCommand)}
    }

    func testContinuedHistoryKeepsPayloadsUsedByOtherCommandConsumers() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String)
        let shapes: [JSON] = [
            ["data":["policy":["required_gates":[]]]],
            ["_connection_registration":["binding_id":uuid()]],
            ["data":["kind":"task_bulk_edit","preview":false]],
            ["data":["takeover_notices":[["message_id":uuid()]]]],
            ["data":["handoff_notices":[["message_id":uuid()]]]],
            ["data":["origin":"automatic_backup_retention"]],
            ["data":["operation_id":uuid(),"manifest_sha256":String(repeating:"a",count:64)]],
        ]
        try f.router.dbQueue.writeWithoutTransaction { db in
            for var result in shapes {
                result["round_id"] = rid
                try db.inSavepoint {
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES('fixture-protected',?,'fixture',?)",
                                   arguments:[uuid(),try jsonString(result)])
                    self.checks.checkError("MEDIA_ROUND_REFERENCED") {
                        try MediaRoundDeletionHistory.select(db,project:f.project,owned:[Data(rid.utf8)],
                            progressKey:MediaRoundDeletionHistory.progressKey(project:f.project,round:rid),continuing:true)
                    }
                    return .rollback
                }
            }
        }
    }

    func testTerminalHistoryOverflowProjectsOutcomesAcrossPassesAndReopen() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String), revision = try XCTUnwrap(round["revision"] as? Int)
        let project = f.project, command = uuid(), failedCommand = uuid()
        let privateText = "Private fixture content removed with the original reply"
        let registration = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:try XCTUnwrap(registration["installation"] as? String),
                            projectIDs:[project],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let success = CommandRouter.commandOperationID(principal:caller.principal,command:command)
        let failure = CommandRouter.commandOperationID(principal:caller.principal,command:failedCommand)
        let errorCommand = CommandRouter.commandOperationID(principal:caller.principal,command:"error:" + failure)
        let progressKey = try MediaRoundDeletionHistory.progressKey(project:project,round:rid)
        let terminalCount = MediaRoundDeletionHistory.passLimit + 2
        let historyEvents = MediaRoundDeletionHistory.entryLimit + 1 - terminalCount
        let lastCommand = uuid()
        let last = CommandRouter.commandOperationID(principal:caller.principal,command:lastCommand)

        @Sendable func previewParams(_ id: String) -> JSON {
            ["round_id":rid,"text":privateText,"project_id":project,"command_id":id]
        }
        @Sendable func deletionParams(_ id: String) -> JSON {
            ["round_id":rid,"expected_revision":revision,"reason":"Synthetic earlier deletion",
             "project_id":project,"command_id":id]
        }
        func seed(_ db: Database, method: String, params: JSON, failureCode: String? = nil) throws {
            let id = try XCTUnwrap(params["command_id"] as? String)
            let operation = CommandRouter.commandOperationID(principal:caller.principal,command:id)
            let digest = ChecklistCore.hash(Data((method + (try jsonString(params))).utf8))
            let generation = try f.router.backupWriteAuthorization(db,params:params,caller:caller)
            var data: JSON = ["operation_id":operation,"principal":caller.principal,"command_id":id,
                "method":method,"project_id":project,"digest":digest,"incarnation":f.router.incarnation,
                "state":failureCode == nil ? "succeeded" : "failed",
                "created_at":now(),"updated_at":now(),"started_at":now(),"finished_at":now()]
            data["authorization_generation"] = generation
            var result: JSON = ["round_id":rid,"text":privateText]
            var receiptID = id, receiptDigest = digest
            if let failureCode {
                receiptID = errorCommand
                receiptDigest = ChecklistCore.hash(Data(("operation-error:" + digest).utf8))
                result = ["command_id":id,"error":["code":failureCode,"message":privateText,
                    "retryable":false,"details":["record_id":rid,"private":privateText]]]
                data["error_result_command_id"] = errorCommand
            }
            try f.router.saveOperation(db,data)
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",
                           arguments:[caller.principal,receiptID,receiptDigest,try jsonString(result)])
        }
        try f.router.dbQueue.write { db in
            try seed(db,method:"media_intake_preview",params:previewParams(command))
            try seed(db,method:"media_round_delete",params:deletionParams(failedCommand),failureCode:"MEDIA_CONTEXT_CHANGED")
            for index in 2..<terminalCount {
                try seed(db,method:"media_intake_preview",params:previewParams(index == terminalCount - 1 ? lastCommand : uuid()))
            }
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?)
                INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
                SELECT printf('00000000-0000-0000-0000-%012d',i),?,?,'fixture','media_history_fixture',?,json_object('text',?) FROM n
                """,arguments:[historyEvents,project,rid,now(),privateText])
        }

        @Sendable func read(_ router: CommandRouter, _ id: String) throws -> JSON {
            let reply = try router.handle(method:"operation_get",params:["project_id":project,"operation_id":id],caller:caller)
            return try XCTUnwrap(reply["data"] as? JSON)
        }
        @Sendable func verifyBoundary(_ router: CommandRouter) throws -> Bool {
            let state = try router.dbQueue.read { db in
                try Row.fetchOne(db,sql:"SELECT revision FROM records WHERE id=? AND type='media_round'",arguments:[rid])
            }
            XCTAssertEqual(state?["revision"] as Int?,revision)
            let succeeded = try read(router,success), failed = try read(router,failure)
            let lastStatus = try read(router,last)
            XCTAssertEqual(lastStatus["state"] as? String,"succeeded")
            let succeededResult = (succeeded["result"] as? JSON)?["data"] as? JSON
            let projected = succeededResult?["result_redacted"] as? Bool == true
            XCTAssertEqual(succeeded["state"] as? String,"succeeded")
            XCTAssertEqual(failed["state"] as? String,"failed")
            XCTAssertEqual((failed["error"] as? JSON)?["code"] as? String,"MEDIA_CONTEXT_CHANGED")
            for (method, params, expected) in [("media_intake_preview",previewParams(command),succeeded),
                                               ("media_round_delete",deletionParams(failedCommand),failed)] {
                let reply = try router.handle(method:method,params:params,caller:caller)
                let data = try XCTUnwrap(reply["data"] as? JSON)
                XCTAssertEqual(data["operation_id"] as? String,expected["operation_id"] as? String)
                XCTAssertEqual(data["state"] as? String,expected["state"] as? String)
                XCTAssertEqual(data["finished_at"] as? String,expected["finished_at"] as? String)
                if method == "media_round_delete" { XCTAssertEqual(try jsonString(data),try jsonString(expected)) }
            }
            if projected {
                XCTAssertEqual(try jsonString(succeededResult ?? [:]),"{\"result_redacted\":true}")
                XCTAssertFalse(try jsonString(succeeded).contains(privateText))
                XCTAssertFalse(try jsonString(failed).contains(privateText))
                XCTAssertEqual(((failed["error"] as? JSON)?["details"] as? JSON)?["result_redacted"] as? Bool,true)
                try router.dbQueue.read { db in
                    for id in [command,errorCommand] {
                        let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",
                                                              arguments:[caller.principal,id]))
                        XCTAssertFalse(raw.contains(privateText))
                        let receipt = jsonObject(raw)
                        XCTAssertTrue(CommandRouter.isPrunedResult(receipt))
                        XCTAssertEqual(receipt[MediaRoundDeletionHistory.projectionProgressField] as? String,progressKey)
                    }
                }
            } else {
                XCTAssertEqual(succeededResult?["text"] as? String,privateText)
                XCTAssertEqual((failed["error"] as? JSON)?["message"] as? String,privateText)
            }
            return projected
        }

        @Sendable func verifyFromClient(_ router: CommandRouter) throws -> Bool {
            let result = LockedTestState<Result<Bool, Error>?>(nil)
            let done = DispatchSemaphore(value:0)
            // A separate client thread enters the public admission path. The
            // deletion worker's own thread bypasses that path for execution.
            DispatchQueue.global().async {
                let observed = Result {try verifyBoundary(router)}
                result.withLock {$0 = observed}
                done.signal()
            }
            guard done.wait(timeout:.now() + 10) == .success else {throw CoreError("TEST_TIMEOUT","The boundary client did not finish.")}
            return try XCTUnwrap(result.withLock {$0}).get()
        }

        let lane = DispatchQueue(label:"test-media-history-projection-operations")
        func drain() throws {
            let done = DispatchSemaphore(value:0)
            lane.async {done.signal()}
            guard done.wait(timeout:.now() + 30) == .success else {throw CoreError("TEST_TIMEOUT","Operation lane did not finish.")}
        }
        f.router.configureCommandOperations(on:lane)
        f.router.mediaRoundDeletionPreparationProbe = { [router = f.router!] in
            if try verifyFromClient(router) { throw CoreError("TEST_INTERRUPT","Interrupted after the projection committed.") }
        }
        defer { f.router?.mediaRoundDeletionPreparationProbe = nil }
        let interrupted = try worker(f,"media_round_delete",input(f,round),as:caller)
        try drain()
        f.router.mediaRoundDeletionPreparationProbe = nil
        XCTAssertEqual((try read(f.router,XCTUnwrap(interrupted["operation_id"] as? String))["error"] as? JSON)?["code"] as? String,"TEST_INTERRUPT")
        let committed = try historyProgress(f,round:rid)
        XCTAssertNotNil(committed)
        XCTAssertTrue(try verifyBoundary(f.router))
        try f.reopen()
        f.router.configureCommandOperations(on:lane)
        XCTAssertEqual(try historyProgress(f,round:rid),committed)
        XCTAssertTrue(try verifyBoundary(f.router))

        func eligibleToPrune(_ command: String) throws -> Bool {
            try f.router.dbQueue.read { db in
                try Bool.fetchOne(db,sql:"SELECT rowid IN (\(CommandRouter.prunableCommandResultsSQL)) FROM commands WHERE principal=? AND command_id=?",
                    arguments:[Int64.max,CommandRouter.prunedResult,caller.principal,command]) == true
            }
        }
        XCTAssertFalse(try eligibleToPrune(command))
        XCTAssertFalse(try eligibleToPrune(errorCommand))
        f.router.mediaRoundDeletionPreparationProbe = { [router = f.router!] in XCTAssertTrue(try verifyFromClient(router)) }
        let resumed = try worker(f,"media_round_delete",input(f,round),as:caller)
        try drain()
        XCTAssertEqual(try read(f.router,XCTUnwrap(resumed["operation_id"] as? String))["state"] as? String,"succeeded")
        XCTAssertNil(try historyProgress(f,round:rid))
        checks.checkError("NOT_FOUND") {try f.get(round)}
        for id in [success,failure,last] {
            checks.checkError("COMMAND_RESULT_EXPIRED") {try read(f.router,id)}
        }
        checks.checkError("COMMAND_RESULT_EXPIRED") {
            try f.router.handle(method:"media_round_delete",params:deletionParams(failedCommand),caller:caller)
        }
        let replay = try worker(f,"media_intake_preview",["round_id":rid,"text":privateText],as:caller,command:command)
        XCTAssertEqual(replay["operation_id"] as? String,success)
        XCTAssertEqual(replay["state"] as? String,"succeeded")
        var changed = previewParams(command)
        changed["text"] = "Another intent"
        checks.checkError("IDEMPOTENCY_CONFLICT") {
            try f.router.handle(method:"media_intake_preview",params:changed,caller:caller)
        }
        XCTAssertTrue(try eligibleToPrune(command))
        XCTAssertTrue(try eligibleToPrune(errorCommand))
        XCTAssertEqual(try f.rows("media_intake").count,0)
    }

    func testSuccessfulOperationReceiptsAloneCanOverflowTheFinalPass() throws {
        try assertTerminalReceiptOverflow(failed:false)
    }

    func testFailedOperationReceiptsAloneCanOverflowTheFinalPass() throws {
        try assertTerminalReceiptOverflow(failed:true)
    }

    private func assertTerminalReceiptOverflow(failed: Bool) throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String), principal = "fixture-terminal-history"
        let count = MediaRoundDeletionHistory.passLimit + 1
        let result = try jsonString(failed
            ? ["error":["code":"MEDIA_CONTEXT_CHANGED","retryable":false,"details":["record_id":rid,"private":"hidden"]]]
            : ["round_id":rid,"private":"hidden"])
        try f.router.dbQueue.write { db in
            for _ in 0..<count {
                let command = uuid(), id = CommandRouter.commandOperationID(principal:principal,command:command)
                let errorCommand = CommandRouter.commandOperationID(principal:principal,command:"error:" + id)
                var operation: JSON = ["operation_id":id,"principal":principal,"command_id":command,
                    "method":failed ? "media_round_delete" : "media_intake_preview","project_id":f.project,
                    "digest":"fixture-digest","incarnation":f.router.incarnation,"state":failed ? "failed" : "succeeded"]
                if failed {operation["error_result_command_id"] = errorCommand}
                try f.router.saveOperation(db,operation)
                try db.execute(sql:"INSERT INTO commands VALUES (?,?,'fixture-digest',?)",arguments:[principal,failed ? errorCommand : command,result])
            }
        }
        try addMatchedHistoryCommands(f,round:rid)
        let projected = LockedTestState(false)
        f.router.mediaRoundDeletionPreparationProbe = {
            let sample = try f.router.dbQueue.read { db in
                try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND json_extract(result,'$.pruned')=1 LIMIT 1",arguments:[principal])
            }
            if let sample {
                XCTAssertFalse(sample.contains("hidden"))
                XCTAssertEqual(jsonObject(sample)["_media_history_error_code"] as? String,failed ? "MEDIA_CONTEXT_CHANGED" : nil)
                projected.withLock { $0 = true }
            }
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        XCTAssertEqual(try worker(f,"media_round_delete",input(f,round))["deleted"] as? Bool,true)
        XCTAssertTrue(projected.withLock { $0 })
        XCTAssertEqual(try f.router.dbQueue.read { db in
            try Int.fetchOne(db,sql:"SELECT count(*) FROM commands WHERE principal=? AND digest='fixture-digest' AND json_extract(result,'$.pruned')=1",arguments:[principal])
        },count)
    }

    func testNonfinalHistoryFencesNewTerminalOperationDependent() throws {
        let f = try Fixture(), round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String)
        let principal = "fixture-media-history", command = "00000000-0000-0000-0000-000000000001"
        let operation = CommandRouter.commandOperationID(principal:principal,command:command)
        try addMatchedHistoryCommands(f,round:rid)
        let original = try XCTUnwrap(exactHistoryResult(f,principal:principal,command:command))
        f.router.mediaRoundDeletionPreparationProbe = { [router = f.router!, project = f.project] in
            try router.dbQueue.write { db in
                try router.saveOperation(db,["operation_id":operation,"principal":principal,"command_id":command,
                    "method":"media_intake_preview","project_id":project,"digest":"fixture-digest",
                    "incarnation":router.incarnation,"state":"succeeded"])
            }
        }
        defer { f.router.mediaRoundDeletionPreparationProbe = nil }
        let params = try input(f,round)
        XCTAssertThrowsError(try worker(f,"media_round_delete",params)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual((error as? CoreError)?.details["check"] as? String,"history_result_dependent")
            XCTAssertEqual((error as? CoreError)?.details["record_id"] as? String,CommandRouter.commandOperationKey(operation))
        }
        f.router.mediaRoundDeletionPreparationProbe = nil
        XCTAssertNil(try historyProgress(f,round:rid))
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),original)
        XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
        XCTAssertEqual(try worker(f,"media_round_delete",params)["deleted"] as? Bool,true)
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),CommandRouter.prunedResult)
    }
}
