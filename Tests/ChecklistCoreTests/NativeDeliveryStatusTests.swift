import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testCodexQueueProviderAcceptanceFencesNativeRetryButKeepsInboxAndAck() throws {
        let f = try nativeHandlerFixture(provider:"codex");let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Synthetic Codex queue receipt"])
        let id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        let candidates: JSON = ["native_session_ids":[f.sid],"native_dispatch_candidates":true]
        XCTAssertEqual((try call("delivery_pending",candidates,bridge)["deliveries"] as! [JSON]).count,1)
        // The durable before-send fence prevents retries even if the process dies before the provider responds.
        _ = try call("delivery_record",["delivery_id":id,"state":"uncertain","receipt":["stage":"native_send_started"]],bridge)
        XCTAssertTrue((try call("delivery_pending",candidates,bridge)["deliveries"] as! [JSON]).isEmpty)
        _ = try call("delivery_record",["delivery_id":id,"state":"provider_accepted","receipt":["route":"codex_app_queue","result":"provider_accepted"]],bridge)
        try router.closeStore();router = nil;router = try CommandRouter(root:directory)
        XCTAssertTrue((try call("delivery_pending",candidates,bridge)["deliveries"] as! [JSON]).isEmpty)
        let listing = try call("message_delivery_list",["project_id":f.pid,"task_id":f.task["id"]!,"message_id":note["id"]!])
        let delivery = (listing["deliveries"] as! [JSON])[0]
        XCTAssertEqual(delivery["state"] as? String,"queued")
        XCTAssertEqual(delivery["push_state"] as? String,"provider_accepted")
        XCTAssertEqual((delivery["route_receipt"] as? JSON)?["result"] as? String,"provider_accepted")
        XCTAssertNil(delivery["acknowledged_at"])
        let inbox = try call("session_inbox",["project_id":f.pid],f.worker)["deliveries"] as! [JSON]
        XCTAssertEqual(inbox.count,1)
        XCTAssertEqual(inbox[0]["id"] as? String,id)
        _ = try call("message_ack",["project_id":f.pid,"delivery_id":id],f.worker)
        let acknowledged = try call("message_delivery_list",["project_id":f.pid,"task_id":f.task["id"]!,"message_id":note["id"]!])
        XCTAssertEqual((acknowledged["deliveries"] as! [JSON])[0]["state"] as? String,"acknowledged")
        XCTAssertTrue((try call("delivery_pending",candidates,bridge)["deliveries"] as! [JSON]).isEmpty)
    }

    func testCodexQueueRouteReceiptShowsSafeEvidenceWithoutTransportSecrets() throws {
        let f = try nativeHandlerFixture(provider:"codex");let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Synthetic private note body"])
        let id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        let item = "queue_opaque-item-123"
        let receipt: JSON = ["route":"codex_app_queue","result":"provider_accepted","reason_code":"source_vscode",
            "observer":"codex_state_5_threads_source","source":"vscode","queued_item_id":item,"queue_poll_result":"pending_after_20s",
            "open_result":"exited_zero","open_exit_status":0,"private_body":"Synthetic private note body","credential":"secret",
            "state_path":"/private/owner/.codex/state_5.sqlite","reason":"Local diagnostics must stay private"]
        _ = try call("delivery_record",["delivery_id":id,"state":"provider_accepted","receipt":receipt],bridge)
        let listing = try call("message_delivery_list",["project_id":f.pid,"task_id":f.task["id"]!,"message_id":note["id"]!])
        let delivery = (listing["deliveries"] as! [JSON])[0]
        let safe = try XCTUnwrap(delivery["route_receipt"] as? JSON)
        XCTAssertEqual(Set(safe.keys),Set(["route","result","reason_code","observer","source","queued_item_id","queue_poll_result","open_result","open_exit_status"]))
        XCTAssertEqual(safe["queued_item_id"] as? String,item)
        XCTAssertEqual(safe["queue_poll_result"] as? String,"pending_after_20s")
        XCTAssertEqual(safe["open_exit_status"] as? Int,0)
        XCTAssertNil(delivery["transport_receipt"])
        XCTAssertNil(delivery["body"])
        for key in ["private_body","credential","state_path","reason"] { XCTAssertNil(safe[key]) }
    }

    func testCodexQueueRouteReceiptRejectsValuesOutsideClosedVocabulary() throws {
        let hostile = "/private/owner/secret note body"
        let safe = try XCTUnwrap(router.codexQueueRouteReceipt(["route":"codex_app_queue","result":hostile,"reason_code":hostile,
            "observer":hostile,"source":"{\"subagent\":{\"private\":\"body\"}}","queued_item_id":hostile,
            "queue_poll_result":hostile,"open_result":hostile,"open_exit_status":99999]))
        XCTAssertEqual(safe.count,1)
        XCTAssertEqual(safe["route"] as? String,"codex_app_queue")
        XCTAssertNil(router.codexQueueRouteReceipt(["route":hostile,"result":"provider_accepted"]))
        XCTAssertNil(router.codexQueueRouteReceipt(nil))
        for item in ["",String(repeating:"a",count:161),"queue/item","queue item","queue\nitem","queue💬item"] {
            XCTAssertNil(router.codexQueueRouteReceipt(["route":"codex_app_queue","queued_item_id":item])?["queued_item_id"])
        }
        XCTAssertNil(router.codexQueueRouteReceipt(["route":"codex_app_queue","open_exit_status":true])?["open_exit_status"])
    }

    func testCodexQueueRouteReceiptPreservesEveryDefinedReasonAndOutcome() throws {
        let vocabulary: [String:[String]] = [
            "result":["provider_accepted","refused","failed","uncertain"],
            "source":["vscode","exec","mcp","subagent","unknown"],
            "reason_code":["source_vscode","source_exec","source_mcp","source_subagent","source_unknown","thread_missing",
                "database_missing","database_version_unsupported","database_locked","schema_unrecognized","database_read_error",
                "database_unsafe","recipient_invalid","route_disabled","queue_command_failed","queue_outcome_unknown","recipient_changed"],
            "queue_poll_result":["not_started","item_unconfirmed","removed","pending_after_20s","database_missing",
                "database_version_unsupported","database_locked","schema_unrecognized","database_read_error","database_unsafe","authorization_changed"],
            "open_result":["not_started","not_needed","disabled","refused","authorization_changed","exited_zero","failed","outcome_unknown"]
        ]
        for (field,values) in vocabulary { for value in values {
            XCTAssertEqual(router.codexQueueRouteReceipt(["route":"codex_app_queue",field:value])?[field] as? String,value,"\(field): \(value)")
        } }
    }

    func nativeHandlerFixture(provider: String = "claude") throws -> (pid: String, task: JSON, sid: String, worker: Caller) {
        let workspace = directory.appendingPathComponent("native-delivery");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Native","key_prefix":"NAT","root_path":workspace.path]);let pid = project["id"] as! String
        let task = try ready(project,self.task(project));let sid = UUID().uuidString
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":provider,"installation":"handler"])
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
