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
}
