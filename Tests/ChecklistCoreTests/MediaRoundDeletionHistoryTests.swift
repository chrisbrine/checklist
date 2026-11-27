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
        XCTAssertEqual(try exactHistoryResult(f,principal:principal,command:command),CommandRouter.prunedResult)
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
                        try MediaRoundDeletionHistory.select(db,project:f.project,owned:[Data(rid.utf8)],continuing:true)
                    }
                    return .rollback
                }
            }
        }
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
