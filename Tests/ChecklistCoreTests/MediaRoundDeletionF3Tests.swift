import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension MediaRoundDeletionTests {
    private func f3LinkedRound(_ f: Fixture,itemTicket: Bool) throws -> (JSON,JSON) {
        let task = try results.task(f),round = try f.round(f.type(checks.schema()))
        if itemTicket {
            let item = try f.item(round)
            _ = try f.call("media_item_link_task",["round_id":round["id"]!,"item_id":item["id"]!,"expected_revision":item["revision"]!,"task_id":task["id"]!])
        } else {_ = try results.link(f,round,task)}
        return (try cancel(f,round),task)
    }

    /// The same ordinary message, event and receipt must be admissible on both
    /// sides of the preparation boundary. The ticket bytes never change.
    private func f3PlainNote(itemTicket: Bool,during: Bool) throws {
        let f = try Fixture(),(round,task) = try f3LinkedRound(f,itemTicket:itemTicket)
        let writer = try results.session(f,"f3-linked-note-writer")
        let before = try jsonString(f.record(task["id"] as! String,"task"))
        var message: JSON = [:],history: [Data] = [],receipts: [Data] = []
        let send = {
            message = try self.results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":"Ordinary ticket progress, no media reference"],as:writer)
            message = try f.record(message["id"] as! String,"message")
            XCTAssertEqual(try jsonString(f.record(task["id"] as! String,"task")),before)
            (history,receipts) = try f.router.dbQueue.read {db in
                (try Data.fetchAll(db,sql:"SELECT CAST(json_array(id,project_id,entity_id,kind,data) AS BLOB) FROM events WHERE entity_id=? ORDER BY id",arguments:[task["id"] as! String]),
                 try Data.fetchAll(db,sql:"SELECT CAST(json_array(command_id,digest,result) AS BLOB) FROM commands WHERE principal=? ORDER BY command_id",arguments:[writer.principal]))
            }
            XCTAssertFalse(history.isEmpty);XCTAssertFalse(receipts.isEmpty)
        }
        if during {f.router.mediaRoundDeletionPreparationProbe = send} else {try send()}
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        XCTAssertEqual(try worker(f,"media_round_delete",input(f,round))["deleted"] as? Bool,true)
        XCTAssertEqual(try jsonString(f.record(task["id"] as! String,"task")),before)
        XCTAssertEqual(try jsonString(f.record(message["id"] as! String,"message")),try jsonString(message))
        try f.router.dbQueue.read {db in
            XCTAssertEqual(try Data.fetchAll(db,sql:"SELECT CAST(json_array(id,project_id,entity_id,kind,data) AS BLOB) FROM events WHERE entity_id=? ORDER BY id",arguments:[task["id"] as! String]),history)
            XCTAssertEqual(try Data.fetchAll(db,sql:"SELECT CAST(json_array(command_id,digest,result) AS BLOB) FROM commands WHERE principal=? ORDER BY command_id",arguments:[writer.principal]),receipts)
        }
    }

    func testF3OrdinaryRoundTicketNoteBeforePreparationAllowsDeletion() throws {try f3PlainNote(itemTicket:false,during:false)}
    func testF3OrdinaryRoundTicketNoteDuringPreparationAllowsDeletion() throws {try f3PlainNote(itemTicket:false,during:true)}
    func testF3OrdinaryItemTicketNoteBeforePreparationAllowsDeletion() throws {try f3PlainNote(itemTicket:true,during:false)}
    func testF3OrdinaryItemTicketNoteDuringPreparationAllowsDeletion() throws {try f3PlainNote(itemTicket:true,during:true)}

    private func f3ReferencedNote(file: Bool) throws {
        let f = try Fixture(),task = try results.task(f),round = try imageRound(f,"f3-reference.png")
        _ = try results.link(f,round,task)
        let closed = try cancel(f,round)
        let reference = file ? try XCTUnwrap(f.rows("attachment").first?["path"] as? String) : round["id"] as! String
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            _ = try self.results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":reference])
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        XCTAssertThrowsError(try worker(f,"media_round_delete",input(f,closed))) {error in
            XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual((error as? CoreError)?.details["check"] as? String,"changed_reference")
        }
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    func testF3DuringPreparationNoteNamingRoundRecordStillRefuses() throws {try f3ReferencedNote(file:false)}
    func testF3DuringPreparationNoteNamingRoundFileStillRefuses() throws {try f3ReferencedNote(file:true)}

    private func f3PendingRequest(itemTicket: Bool,changed: Bool) throws {
        let f = try Fixture(),(round,task) = try f3LinkedRound(f,itemTicket:itemTicket)
        let other = changed ? try results.task(f) : task
        let requestInput: JSON = ["task_id":other["id"]!,"title":"New owner question","blocking":false,"questions":[["id":"q","type":"text","prompt":"Keep this pass?"]]]
        let prior = changed ? try results.call(f,"human_request_create",requestInput) : nil
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            if var request = prior {
                // An existing pending request moves onto this linked ticket.
                try f.router.dbQueue.writeWithoutTransaction {db in
                    try f.router.withValidatedDomainTransaction(db) {
                        request["task_id"] = task["id"]
                        try f.router.save(db,f.router.revised(request),type:"request");return .commit
                    }
                }
            } else {_ = try self.results.call(f,"human_request_create",requestInput)}
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        XCTAssertThrowsError(try worker(f,"media_round_delete",input(f,round))) {error in
            XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual((error as? CoreError)?.details["record_type"] as? String,"request")
        }
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    func testF3NewPendingRoundTicketRequestDuringPreparationStillRefuses() throws {try f3PendingRequest(itemTicket:false,changed:false)}
    func testF3NewPendingItemTicketRequestDuringPreparationStillRefuses() throws {try f3PendingRequest(itemTicket:true,changed:false)}
    func testF3ChangedPendingRoundTicketRequestDuringPreparationStillRefuses() throws {try f3PendingRequest(itemTicket:false,changed:true)}
    func testF3ChangedPendingItemTicketRequestDuringPreparationStillRefuses() throws {try f3PendingRequest(itemTicket:true,changed:true)}

    func testF3CanceledLinkedRequestDuringPreparationAllowsDeletion() throws {
        let f = try Fixture(),(round,task) = try f3LinkedRound(f,itemTicket:false)
        f.router.mediaRoundDeletionPreparationProbe = {
            let request = try self.results.call(f,"human_request_create",["task_id":task["id"]!,"title":"Resolved owner question","blocking":false,"questions":[["id":"q","type":"text","prompt":"Keep this pass?"]]])
            _ = try self.results.call(f,"human_request_cancel",["request_id":request["id"]!,"expected_revision":request["revision"]!,"reason":"Already resolved"])
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        XCTAssertEqual(try worker(f,"media_round_delete",input(f,round))["deleted"] as? Bool,true)
    }
}
