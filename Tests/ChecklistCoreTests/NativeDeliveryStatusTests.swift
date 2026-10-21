import XCTest
@testable import ChecklistCore

extension CoreTests {
    func nativeHandlerFixture() throws -> (pid: String, task: JSON, sid: String, worker: Caller) {
        let workspace = directory.appendingPathComponent("native-delivery");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Native","key_prefix":"NAT","root_path":workspace.path]);let pid = project["id"] as! String
        let task = try ready(project,self.task(project));let sid = UUID().uuidString
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"claude","installation":"handler"])
        let worker = Caller(role:"worker",installation:"handler",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        _ = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!],worker)
        return (pid,task,sid,worker)
    }

    func testHostHoldIsRecordedApartFromWriteAndNeverAcknowledges() throws {
        let f = try nativeHandlerFixture();let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Synthetic hold test","expects_reply":true])
        let id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":["stage":"native_send_started"]],bridge)
        _ = try call("delivery_record",["delivery_id":id,"state":"transport_written","receipt":["bytes":741]],bridge)
        let held = try call("delivery_host_status",["delivery_id":id,"status":"held","receipt":["host_status":"held","correlation":"orig_msg_id"]],bridge)
        XCTAssertEqual(held["state"] as? String,"held_for_approval")
        XCTAssertEqual(held["push_state"] as? String,"transport_written")
        XCTAssertEqual((held["transport_receipt"] as? JSON)?["bytes"] as? Int,741)
        XCTAssertEqual((held["host_status_receipt"] as? JSON)?["correlation"] as? String,"orig_msg_id")
        XCTAssertTrue((held["reason"] as? String)?.contains("next Checklist check") == true)
        // The held note stays available through MCP pickup, and the held route is not dispatched again.
        XCTAssertEqual((try call("session_inbox",["project_id":f.pid],f.worker)["deliveries"] as! [JSON]).count,1)
        let pending = try call("delivery_pending",[:],bridge)["deliveries"] as! [JSON]
        XCTAssertFalse(pending.contains { $0["id"] as? String == id && $0["push_state"] as? String == "unavailable" })
        let refused = try call("delivery_host_status",["delivery_id":id,"status":"refused"],bridge)
        XCTAssertEqual(refused["state"] as? String,"refused")
        assertCode("INVALID_INPUT") { _ = try self.call("delivery_host_status",["delivery_id":id,"status":"delivered"],bridge) }
        assertCode("FORBIDDEN") { _ = try self.call("delivery_host_status",["delivery_id":id,"status":"held"]) }
    }

    func testOwnerNoteGrantsOneNativeReplyAndRejectsReplay() throws {
        let f = try nativeHandlerFixture();let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Synthetic reply test","expects_reply":true])
        XCTAssertEqual(note["reply_allowed"] as? Bool,true)
        let input: JSON = ["project_id":f.pid,"reply_to":note["id"]!,"recipient_session_id":f.sid,"body":"Synthetic answer","source_evidence":["native_peer_pid":1]]
        let reply = try call("native_reply_record",input,bridge)
        XCTAssertEqual(reply["reply_to"] as? String,note["id"] as? String)
        XCTAssertEqual(reply["task_id"] as? String,f.task["id"] as? String)
        let inbox = try call("session_inbox",["project_id":f.pid],f.worker)["deliveries"] as! [JSON]
        XCTAssertEqual(inbox.first?["state"] as? String,"acknowledged")
        assertCode("FORBIDDEN") { _ = try self.call("native_reply_record",input,bridge) }
        // A late host notice cannot downgrade an exact recipient acknowledgment.
        XCTAssertEqual(try call("delivery_host_status",["delivery_id":inbox[0]["id"]!,"status":"held"],bridge)["state"] as? String,"acknowledged")
        // The single allowance cannot be spent again through MCP.
        assertCode("FORBIDDEN") { _ = try self.call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"reply_to":note["id"]!,"body":"Second reply"],f.worker) }
    }
}
