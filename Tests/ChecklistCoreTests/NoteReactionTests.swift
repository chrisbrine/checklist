import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func noteRecipientFixture() throws -> (pid: String, task: JSON, sid: String, worker: Caller, workspace: URL) {
        let workspace = directory.appendingPathComponent("note-reactions");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Reactions","key_prefix":"REACT","root_path":workspace.path]);let pid = project["id"] as! String
        let task = try ready(project,self.task(project));let sid = UUID().uuidString
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"claude","installation":"handler"])
        let worker = Caller(role:"worker",installation:"handler",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        _ = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!],worker)
        return (pid,task,sid,worker,workspace)
    }
    /// Uses the full command path, including the worker's closed MCP field schema.
    func reactionAck(_ p: JSON,_ caller: Caller) throws -> JSON { try call("message_ack",p,caller) }

    func testOwnerNoteIsNotADirectionAndDoesNotBlockSubmission() throws {
        let p = try project();let t = try ready(p,task(p))
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        // The app's note: no requires_action field. The agent decides how to respond.
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"FYI: the logo is final.","expects_reply":true])
        XCTAssertEqual(note["requires_action"] as? Bool,false)
        let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertTrue((context["unresolved_directions"] as? [JSON] ?? []).isEmpty)
        XCTAssertNoThrow(try submitTriageArtifact(p,t,claim))
    }

    func testOwnerReplyAllowanceGoesToHandlerWhenCoordinatorSortsFirst() throws {
        let workspace = directory.appendingPathComponent("reply-fanout");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Fanout","key_prefix":"FAN","root_path":workspace.path]);let pid = project["id"] as! String
        let task = try ready(project,self.task(project))
        // Recipients are sorted by session ID; this coordinator sorts before the handler.
        let handlerID = "ffffffff-ffff-4fff-bfff-ffffffffffff",coordinatorID = "00000000-0000-4000-8000-000000000000"
        for (id,name) in [(handlerID,"handler")] { _ = try call("session_register",["project_id":pid,"session_id":id,"role":"worker","provider":"claude","installation":name,"workspace":workspace.path]) }
        // CL-248: the Triage orchestrator (which sorts first) replaces the retired coordinator_session_id.
        _ = try call("session_register",["project_id":pid,"session_id":coordinatorID,"role":"worker","provider":"claude","installation":"coordinator","workspace":workspace.path,"execution_domain":"host-coordinator"])
        let coordinator = Caller(role:"worker",installation:"coordinator",projectIDs:[pid],sessionID:coordinatorID,workspace:workspace.path,executionDomain:"host-coordinator")
        let triage = try call("triage_orchestrate",["project_id":pid,"action":"start"],coordinator)
        _ = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":task["id"]!,"action":"add"],coordinator)
        let handler = Caller(role:"worker",installation:"handler",projectIDs:[pid],sessionID:handlerID,workspace:workspace.path)
        _ = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!],handler)
        let note = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Which logo size did you pick?","expects_reply":true])
        // docs/triage-orchestrators.md, Message routing: the holder and the Triage orchestrator.
        XCTAssertEqual(Set((note["deliveries"] as! [JSON]).compactMap {$0["recipient_session_id"] as? String}),Set([handlerID,coordinatorID]))
        XCTAssertEqual(note["reply_recipient_session_id"] as? String,handlerID)
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        assertCode("FORBIDDEN") { _ = try self.call("native_reply_record",["project_id":pid,"reply_to":note["id"]!,"recipient_session_id":coordinatorID,"body":"Coordinator answer","source_evidence":[:]],bridge) }
        let reply = try call("native_reply_record",["project_id":pid,"reply_to":note["id"]!,"recipient_session_id":handlerID,"body":"The 512 px one.","source_evidence":[:]],bridge)
        XCTAssertEqual(reply["author_session_id"] as? String,handlerID)
    }

    func testRecipientReactionIsAcknowledgmentOnly() throws {
        let f = try noteRecipientFixture()
        let tools = try call("tool_catalog",[:],f.worker)["tools"] as! [JSON]
        let ackSchema = try XCTUnwrap(tools.first { $0["name"] as? String == "message_ack" }?["inputSchema"] as? JSON)
        XCTAssertNotNil((ackSchema["properties"] as? JSON)?["reaction"])
        let note = try call("message_send",["project_id":f.pid,"task_id":f.task["id"]!,"body":"Can you check the logo size?","expects_reply":true])
        let deliveryID = (note["deliveries"] as! [JSON])[0]["id"]!
        let acked = try reactionAck(["project_id":f.pid,"delivery_id":deliveryID,"reaction":"thumbs_up"],f.worker)
        XCTAssertEqual(acked["state"] as? String,"acknowledged")
        XCTAssertEqual(acked["reaction"] as? String,"thumbs_up")
        XCTAssertNotNil(acked["reaction_at"])
        // A later marker replaces the earlier one; there is one current reaction per recipient.
        XCTAssertEqual(try reactionAck(["project_id":f.pid,"delivery_id":deliveryID,"reaction":"done"],f.worker)["reaction"] as? String,"done")
        // The note is not addressed, and the reply allowance is unchanged.
        let messages = try call("task_context",["project_id":f.pid,"task_id":f.task["id"]!])["messages"] as! [JSON]
        let stored = try XCTUnwrap(messages.first { $0["id"] as? String == note["id"] as? String })
        XCTAssertEqual(stored["addressed"] as? Bool,false)
        XCTAssertEqual(stored["reply_used"] as? Bool,false)
        // Only the fixed set, and only the exact recipient.
        assertCode("INVALID_INPUT") { _ = try self.reactionAck(["project_id":f.pid,"delivery_id":deliveryID,"reaction":"heart"],f.worker) }
        let otherID = UUID().uuidString
        _ = try call("session_register",["project_id":f.pid,"session_id":otherID,"role":"worker","provider":"codex","installation":"other"])
        let other = Caller(role:"worker",installation:"other",projectIDs:[f.pid],sessionID:otherID,workspace:f.workspace.path)
        assertCode("FORBIDDEN") { _ = try self.reactionAck(["project_id":f.pid,"delivery_id":deliveryID,"reaction":"thumbs_down"],other) }
        // The owner's snapshot carries the reaction to the note row.
        let snapshot = try call("snapshot")
        let row = try XCTUnwrap((snapshot["messages"] as! [JSON]).first { $0["id"] as? String == note["id"] as? String })
        XCTAssertEqual((row["deliveries"] as? [JSON])?.first?["reaction"] as? String,"done")
    }
}
