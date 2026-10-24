import XCTest
import GRDB
@testable import ChecklistCore

final class NoteTrafficReadScopeTests: XCTestCase {
    func testOrdinaryNotesPreserveRetainedDeliveryHistory() throws {
        let f = try ReadPerformanceFixture("CL-251-deliveries"), r = f.router
        let project = try f.call("project_create",["name":"Note traffic","key_prefix":"NOTE"]),pid = project["id"] as! String
        let task = try f.call("task_create",["project_id":pid,"title":"Selected note"]),tid = task["id"] as! String
        try f.save((0..<256).map { ("delivery",["id":"retained-\($0)","project_id":pid,"revision":1,
            "message_id":"older-\($0)","state":"acknowledged","retained_payload":String(repeating:"history ",count:512)] as JSON) })
        let before = try r.dbQueue.read {try String.fetchAll($0,sql:"SELECT data FROM records WHERE type='delivery' ORDER BY rowid")}
        for _ in 0..<10 {
            let note = try f.call("message_send",["project_id":pid,"task_id":tid,"body":"Ordinary note"])
            XCTAssertEqual((note["deliveries"] as? [JSON])?.count,0)
        }
        let after = try r.dbQueue.read {try String.fetchAll($0,sql:"SELECT data FROM records WHERE type='delivery' ORDER BY rowid")}
        XCTAssertEqual(before,after,"Notes preserve all retained delivery payloads byte for byte")
        let count = try r.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='delivery'")}
        XCTAssertEqual(count,256,"Historical deliveries stay intact")
    }

    func testOrdinaryDeliveryLookupKeepsWholeByteExactMessageIdentity() throws {
        let f = try ReadPerformanceFixture("CL-251-message-identity"),r = f.router,pid = "project"
        let identities: [Any] = ["selected\0tail","é","e\u{301}",42]
        try f.save(identities.enumerated().map {("delivery",["id":"delivery-\($0.offset)","project_id":pid,"revision":1,"message_id":$0.element] as JSON)})
        try r.dbQueue.writeWithoutTransaction { db in
            try r.withValidatedDomainTransaction(db) {
                for (messageID,expected) in [("selected",[String]()),("selected\0tail",["delivery-0"]),("é",["delivery-1"]),("e\u{301}",["delivery-2"]),("42",[])] {
                    let rows = try r.queueOrdinaryDeliveries(db,message:["project_id":pid,"id":messageID],recipients:[])
                    XCTAssertEqual(rows.map {$0["id"] as! String},expected)
                }
                return .commit
            }
        }
    }
}

extension CoreTests {
    func testPendingDeliveryHistoryModeAndAcknowledgmentInvalidateCachedReads() throws {
        let f = try nativeHandlerFixture(),bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let first = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Acknowledged"])
        let acknowledgedID = (first["deliveries"] as! [JSON])[0]["id"] as! String
        _ = try call("message_ack",["project_id":f.pid,"delivery_id":acknowledgedID],f.worker)
        let second = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Pending"])
        let pendingID = (second["deliveries"] as! [JSON])[0]["id"] as! String
        let pending = try call("delivery_pending",[:],bridge)["deliveries"] as! [JSON]
        XCTAssertEqual(pending.map {$0["id"] as! String},[pendingID])
        XCTAssertEqual((pending[0]["message"] as? JSON)?["body"] as? String,"Pending")
        let all = try call("delivery_pending",["include_acknowledged":true],bridge)["deliveries"] as! [JSON]
        XCTAssertEqual(Set(all.map {$0["id"] as! String}),[acknowledgedID,pendingID])
        _ = try call("message_ack",["project_id":f.pid,"delivery_id":pendingID],f.worker)
        XCTAssertTrue((try call("delivery_pending",[:],bridge)["deliveries"] as! [JSON]).isEmpty,"The next read must retire the pre-ack snapshot")
        XCTAssertEqual((try call("delivery_pending",["include_acknowledged":true],bridge)["deliveries"] as! [JSON]).count,2)
    }
}
