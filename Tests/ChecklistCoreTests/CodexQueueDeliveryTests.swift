import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private var queueBridge: Caller { Caller(role:"owner",installation:"native-bridge",projectIDs:[]) }
    private func queueReceipt(stage: String = "native_send_started") -> JSON {
        ["stage":stage,"route":"codex_app_queue","route_generation":"g","queue_poll_result":"not_started","open_result":"not_started"]
    }
    private func queueNote(_ f: (pid: String, task: JSON, sid: String, worker: Caller),_ body: String = "Synthetic queue note") throws -> (id: String, note: JSON) {
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":body,"recipient":["kind":"session","session_id":f.sid]])
        return ((note["deliveries"] as! [JSON])[0]["id"] as! String,note)
    }
    private func storedDelivery(_ id: String) throws -> JSON { try router.dbQueue.read { try router.record($0,id,type:"delivery") } }
    private func changeStored(_ id: String,_ fields: JSON) throws {
        try router.dbQueue.write { db in var d = try router.record(db,id,type:"delivery");for (k,v) in fields { d[k] = v };try router.save(db,d,type:"delivery") }
    }

    func testQueueFinalReceiptDoesNotChangeAFenceDuringTheWait() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        for fence: JSON in [["owner_disconnect_ref":"synthetic-disconnect"],["state":"quarantined","push_state":"quarantined"],["restore_incarnation":"synthetic"]] {
            let id = try queueNote(f).id
            _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge)
            _ = try call("delivery_record",["delivery_id":id,"state":"provider_accepted","receipt":queueReceipt(stage:"codex_queue_command_exited_zero")],queueBridge)
            try changeStored(id,fence)
            let held = try storedDelivery(id)
            for state in ["provider_accepted","failed","transport_written"] {
                var final = queueReceipt(stage:"codex_queue_command_exited_zero");final["queue_poll_result"] = "pending_after_20s"
                _ = try call("delivery_record",["delivery_id":id,"state":state,"receipt":final],queueBridge)
                let now = try storedDelivery(id)
                XCTAssertEqual(now["state"] as? String,held["state"] as? String);XCTAssertEqual(now["push_state"] as? String,held["push_state"] as? String)
                XCTAssertEqual((now["transport_receipt"] as? JSON)?["queue_poll_result"] as? String,"not_started")
                XCTAssertEqual(now["revision"] as? Int,held["revision"] as? Int)
            }
            assertCode("RECIPIENT_CHANGED") { _ = try self.call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":self.queueReceipt()],self.queueBridge) }
        }
    }
    func testRefusedQueueCheckReleasesTheFenceToThePriorState() throws {
        let f = try nativeHandlerFixture(provider:"codex");let id = try queueNote(f).id
        let before = try storedDelivery(id)
        XCTAssertEqual(before["push_state"] as? String,"unavailable")
        _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        XCTAssertEqual(try storedDelivery(id)["state"] as? String,"delivery_uncertain")
        _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","release_queue_fence":true],queueBridge)
        let after = try storedDelivery(id)
        XCTAssertEqual(after["state"] as? String,before["state"] as? String);XCTAssertEqual(after["push_state"] as? String,"unavailable")
        XCTAssertNil(after["transport_receipt"]);XCTAssertNil(after["queue_fence_prior_state"])
        // A release can only undo the fence. After an actual result it changes nothing.
        _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        _ = try call("delivery_record",["delivery_id":id,"state":"provider_accepted","receipt":queueReceipt(stage:"codex_queue_command_exited_zero")],queueBridge)
        _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","release_queue_fence":true],queueBridge)
        XCTAssertEqual(try storedDelivery(id)["push_state"] as? String,"provider_accepted")
    }
    /// L4: the store decides which route takes a note, in one transaction each.
    func testQueueAndHookDoNotBothTakeOneNote() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        let first = try queueNote(f,"First").id
        _ = try call("codex_hook_confirm",["delivery_ids":[first]],f.worker)
        assertCode("RECIPIENT_CHANGED") { _ = try self.call("delivery_record",["delivery_id":first,"state":"uncertain","receipt":self.queueReceipt()],self.queueBridge) }
        XCTAssertEqual(try storedDelivery(first)["push_state"] as? String,"unavailable")

        let second = try queueNote(f,"Second").id
        _ = try call("delivery_record",["delivery_id":second,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        let items = (try call("codex_hook_pickup",[:],f.worker)["pending_notes"] as! JSON)["items"] as! [JSON]
        XCTAssertFalse(items.contains { $0["delivery_id"] as? String == second })
        XCTAssertEqual(try call("codex_hook_confirm",["delivery_ids":[second]],f.worker)["skipped"] as? [String],[second])
        XCTAssertNil(try storedDelivery(second)["hook_state"])
    }
    func testExactDeliveryStateReadsOneRecord() throws {
        let f = try nativeHandlerFixture(provider:"codex");let id = try queueNote(f).id
        func state() throws -> String? { try call("delivery_pending",["delivery_id":id],queueBridge)["route_state"] as? String }
        XCTAssertEqual(try state(),"current")
        try changeStored(id,["state":"acknowledged"]);XCTAssertEqual(try state(),"acknowledged")
        try changeStored(id,["state":"queued","owner_disconnect_ref":"x"]);XCTAssertEqual(try state(),"changed")
        try changeStored(id,["owner_disconnect_ref":NSNull(),"recipient_authorization_generation":"old"]);XCTAssertEqual(try state(),"changed")
    }
    func testCreatedAtMinimumNarrowsCandidatesAndLeavesTheNoteUnchanged() throws {
        let f = try nativeHandlerFixture(provider:"codex");let id = try queueNote(f).id
        let before = try storedDelivery(id)
        func rows(_ minimum: String) throws -> [JSON] {
            try call("delivery_pending",["native_session_ids":[f.sid],"native_dispatch_candidates":true,"created_at_min":minimum],queueBridge)["deliveries"] as! [JSON]
        }
        XCTAssertEqual(try rows("2000-01-01T00:00:00Z").map { $0["id"] as? String },[id])
        XCTAssertEqual(try rows("2999-01-01T00:00:00Z").count,0)
        XCTAssertEqual(try storedDelivery(id)["revision"] as? Int,before["revision"] as? Int)
    }
    func testOpenFollowupsListOnlyTheStagesWithNoFinalResult() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        let fence = try queueNote(f,"Fence").id,accepted = try queueNote(f,"Accepted").id,done = try queueNote(f,"Done").id,failed = try queueNote(f,"Failed").id,other = try queueNote(f,"Other").id
        _ = try call("delivery_record",["delivery_id":fence,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        _ = try call("delivery_record",["delivery_id":accepted,"state":"provider_accepted","receipt":queueReceipt(stage:"codex_queue_command_exited_zero")],queueBridge)
        var final = queueReceipt(stage:"codex_queue_command_exited_zero");final["queue_poll_result"] = "removed"
        _ = try call("delivery_record",["delivery_id":done,"state":"provider_accepted","receipt":final],queueBridge)
        var failure = queueReceipt(stage:"codex_queue_failed");failure["open_result"] = "refused"
        _ = try call("delivery_record",["delivery_id":failed,"state":"failed","receipt":failure],queueBridge)
        _ = other
        let rows = try call("delivery_pending",["codex_queue_open_followups":true],queueBridge)["deliveries"] as! [JSON]
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }),[fence,accepted])
    }
    private func hookPickup(_ f: (pid: String, task: JSON, sid: String, worker: Caller)) throws -> [String] {
        ((try call("codex_hook_pickup",[:],f.worker)["pending_notes"] as! JSON)["items"] as! [JSON]).compactMap { $0["delivery_id"] as? String }
    }
    /// F5: the hook waits only inside the fence and the running wait.
    func testHookTakesAQueueDeliveryAfterTheWaitAndAfterAFailure() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        let accepted = try queueNote(f,"Accepted").id
        _ = try call("delivery_record",["delivery_id":accepted,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        XCTAssertFalse(try hookPickup(f).contains(accepted),"Inside the fence")
        _ = try call("delivery_record",["delivery_id":accepted,"state":"provider_accepted","receipt":queueReceipt(stage:"codex_queue_command_exited_zero")],queueBridge)
        XCTAssertFalse(try hookPickup(f).contains(accepted),"Inside the wait")
        XCTAssertEqual(try call("codex_hook_confirm",["delivery_ids":[accepted]],f.worker)["skipped"] as? [String],[accepted])
        var pending = queueReceipt(stage:"codex_queue_command_exited_zero");pending["queue_poll_result"] = "pending_after_20s"
        _ = try call("delivery_record",["delivery_id":accepted,"state":"provider_accepted","receipt":pending],queueBridge)
        XCTAssertTrue(try hookPickup(f).contains(accepted),"A running turn gets the note after a tool call")
        XCTAssertEqual(try call("codex_hook_confirm",["delivery_ids":[accepted]],f.worker)["confirmed"] as? [String],[accepted])
        XCTAssertEqual(try storedDelivery(accepted)["push_state"] as? String,"provider_accepted")

        let failed = try queueNote(f,"Failed").id
        _ = try call("delivery_record",["delivery_id":failed,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        let failure: JSON = ["route":"codex_app_queue","result":"failed","reason_code":"queue_command_failed","queue_poll_result":"not_started","open_result":"refused"]
        _ = try call("delivery_record",["delivery_id":failed,"state":"failed","receipt":failure],queueBridge)
        XCTAssertTrue(try hookPickup(f).contains(failed),"A failed result lets the hook take the note")
        XCTAssertEqual(try call("codex_hook_confirm",["delivery_ids":[failed]],f.worker)["confirmed"] as? [String],[failed])

        let unknown = try queueNote(f,"Unknown").id
        _ = try call("delivery_record",["delivery_id":unknown,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        var unknownReceipt = failure;unknownReceipt["result"] = "uncertain"
        _ = try call("delivery_record",["delivery_id":unknown,"state":"uncertain","receipt":unknownReceipt],queueBridge)
        XCTAssertTrue(try hookPickup(f).contains(unknown),"The queue call ended, so the fence ended")
    }
    /// F9: a release never sets an acknowledged note back.
    func testFenceReleaseKeepsAnAcknowledgment() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        for state in ["acknowledged","addressed"] {
            let id = try queueNote(f).id
            _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge)
            try changeStored(id,["state":state])
            let held = try storedDelivery(id)
            _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","release_queue_fence":true],queueBridge)
            let after = try storedDelivery(id)
            XCTAssertEqual(after["state"] as? String,state);XCTAssertEqual(after["revision"] as? Int,held["revision"] as? Int)
            XCTAssertEqual(after["push_state"] as? String,"uncertain")
        }
    }
    /// F8: a crash during the queue call leaves the fence. Its final receipt is accepted once, so startup stops selecting it.
    func testCrashDuringTheQueueCallGetsItsFinalReceipt() throws {
        let f = try nativeHandlerFixture(provider:"codex")
        let plain = try queueNote(f,"Plain").id,changed = try queueNote(f,"Changed").id
        for id in [plain,changed] { _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge) }
        try changeStored(changed,["recipient_authorization_generation":"synthetic-old"])
        let open = { try self.call("delivery_pending",["codex_queue_open_followups":true],self.queueBridge)["deliveries"] as! [JSON] }
        XCTAssertEqual(Set(try open().compactMap { $0["id"] as? String }),[plain,changed])
        for id in [plain,changed] {
            var final = queueReceipt();final["queue_poll_result"] = "service_restarted"
            _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":final],queueBridge)
            XCTAssertEqual((try storedDelivery(id)["transport_receipt"] as? JSON)?["queue_poll_result"] as? String,"service_restarted")
            XCTAssertEqual(try storedDelivery(id)["state"] as? String,"delivery_uncertain")
        }
        XCTAssertEqual(try open().count,0)
        // A fence start still needs a current, unattempted delivery.
        assertCode("RECIPIENT_CHANGED") { _ = try self.call("delivery_record",["delivery_id":plain,"state":"uncertain","receipt":self.queueReceipt()],self.queueBridge) }
    }
    /// F6: a stated refusal holds its reason, keeps the delivery's state and stays a candidate.
    func testQueueRefusalReceiptKeepsTheStateAndWritesOnce() throws {
        let f = try nativeHandlerFixture(provider:"codex");let id = try queueNote(f).id
        let before = try storedDelivery(id)
        let receipt: JSON = ["route":"codex_app_queue","result":"refused","reason_code":"registration_unproven","queue_poll_result":"not_started","open_result":"not_started"]
        _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","queue_refusal_receipt":true,"receipt":receipt],queueBridge)
        let after = try storedDelivery(id)
        XCTAssertEqual(after["state"] as? String,before["state"] as? String);XCTAssertEqual(after["push_state"] as? String,"unavailable")
        XCTAssertEqual((after["transport_receipt"] as? JSON)?["reason_code"] as? String,"registration_unproven")
        _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","queue_refusal_receipt":true,"receipt":receipt],queueBridge)
        XCTAssertEqual(try storedDelivery(id)["revision"] as? Int,after["revision"] as? Int,"The same reason writes once")
        XCTAssertTrue(try hookPickup(f).contains(id))
        XCTAssertEqual((try call("delivery_pending",["codex_queue_open_followups":true],queueBridge)["deliveries"] as! [JSON]).count,0)
        // The thread proves itself later: the fence starts from the unchanged state.
        _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":queueReceipt()],queueBridge)
        _ = try call("delivery_record",["delivery_id":id,"state":"unavailable","release_queue_fence":true],queueBridge)
        XCTAssertEqual(try storedDelivery(id)["state"] as? String,before["state"] as? String)
    }
}
