import XCTest
import GRDB
@testable import ChecklistCore

// CL-248: ticket notes reach the ticket holder and the Triage orchestrator
// (docs/triage-orchestrators.md#message-routing). Synthetic projects and templates only.
extension EvidenceAuthorityTests {
    private func routeTriage(_ id: Any) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:"group") } }
    private func routeStart(_ p: JSON,_ caller: Caller) throws -> JSON { try call("triage_orchestrate",["project_id":p["id"]!,"action":"start"],caller) }
    private func routeAdd(_ p: JSON,_ group: Any,_ task: JSON,_ caller: Caller? = nil) throws {
        _ = try call("group_membership",["project_id":p["id"]!,"group_id":group,"expected_revision":try routeTriage(group)["revision"]!,"task_id":task["id"]!,"action":"add"],caller)
    }
    private func routeFresh(_ task: JSON) throws -> JSON { try router.dbQueue.read { try router.record($0,task["id"] as! String,type:"task") } }
    private func routeDeliveries(_ note: JSON) -> [String: JSON] {
        Dictionary(uniqueKeysWithValues:(note["deliveries"] as? [JSON] ?? []).map {($0["recipient_session_id"] as! String,$0)})
    }
    private func routeMessageCount(_ p: JSON) throws -> Int { try router.dbQueue.read { try router.records($0,type:"message",project:p["id"] as? String).count } }
    private func routeNote(_ p: JSON,_ task: JSON?,_ caller: Caller?,_ extra: JSON = [:],command: String? = nil) throws -> JSON {
        var input: JSON = ["project_id":p["id"]!,"body":"Routing note"]
        if let task { input["task_id"] = task["id"]! }
        for (key,value) in extra { input[key] = value }
        return try call("message_send",input,caller,command:command)
    }
    /// Orchestrator O owns a Triage with a ticket held by H (Claude) with accepted subagent S.
    private func routeFixture() throws -> (p: JSON,triage: JSON,task: JSON,orchestrator: Caller,holder: Caller,child: Caller,peer: Caller) {
        let p = try project(), o = try native(p,"orchestrator",domain:"host-o"), h = try native(p,"holder",domain:"host-h",provider:"claude")
        let s = try native(p,"subagent",domain:"host-s"), peer = try native(p,"peer",domain:"host-p")
        let triage = try routeStart(p,o), task = try ready(p)
        try routeAdd(p,triage["id"]!,task,o)
        let attempt = try claim(p,try routeFresh(task),caller:h)
        let offer = try call("work_delegate",["project_id":p["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"child_session_id":s.sessionID!,"file_scopes":[],"lane_scopes":[],"brief":"Check one file"],h)
        _ = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],s)
        return (p,triage,task,o,h,s,peer)
    }

    func testDefaultTicketNoteReachesHolderSubagentAndOrchestratorOnce() throws {
        let f = try routeFixture(), key = f.task["key"] as! String
        let note = try routeNote(f.p,f.task,f.peer)
        let d = routeDeliveries(note)
        XCTAssertEqual(Set(d.keys),Set([f.holder.sessionID!,f.child.sessionID!,f.orchestrator.sessionID!]))
        XCTAssertEqual(d[f.orchestrator.sessionID!]?["recipient_role"] as? String,"triage_orchestrator")
        XCTAssertEqual(d[f.orchestrator.sessionID!]?["label"] as? String,"Also sent to Claude · \(f.holder.sessionID!.prefix(8)), which holds \(key).")
        XCTAssertEqual(d[f.holder.sessionID!]?["recipient_role"] as? String,"handler")
        XCTAssertEqual(d[f.child.sessionID!]?["recipient_role"] as? String,"registered_child")
        XCTAssertTrue((d[f.holder.sessionID!]?["label"] as? String ?? "").hasPrefix("Also sent to Codex · \(f.orchestrator.sessionID!.prefix(8)), which orchestrates "))
        // The sender gets no copy.
        XCTAssertEqual(Set(routeDeliveries(try routeNote(f.p,f.task,f.holder)).keys),Set([f.child.sessionID!,f.orchestrator.sessionID!]))
        XCTAssertEqual(Set(routeDeliveries(try routeNote(f.p,f.task,f.orchestrator)).keys),Set([f.holder.sessionID!,f.child.sessionID!]))
        // session_inbox and message_delivery_list show the role and the label.
        let inbox = try call("session_inbox",["project_id":f.p["id"]!],f.orchestrator)["deliveries"] as! [JSON]
        XCTAssertTrue(inbox.contains { $0["message_id"] as? String == note["id"] as? String && $0["recipient_role"] as? String == "triage_orchestrator" && ($0["label"] as? String ?? "").contains(key) })
        let receipts = try call("message_delivery_list",["project_id":f.p["id"]!,"task_id":f.task["id"]!,"message_id":note["id"]!],f.peer)["deliveries"] as! [JSON]
        XCTAssertEqual(receipts.filter { $0["recipient_role"] as? String == "triage_orchestrator" && $0["label"] is String }.count,1)
        // One delivery when the orchestrator is also the holder.
        let own = try ready(f.p)
        try routeAdd(f.p,f.triage["id"]!,own,f.orchestrator)
        _ = try claim(f.p,try routeFresh(own),caller:f.orchestrator)
        let single = try routeNote(f.p,own,f.peer)["deliveries"] as! [JSON]
        XCTAssertEqual(single.count,1);XCTAssertEqual(single.first?["recipient_role"] as? String,"handler")
    }

    func testAudienceNarrowsOrdinaryNotesAndRefusesAtomically() throws {
        let f = try routeFixture()
        XCTAssertEqual(Set(routeDeliveries(try routeNote(f.p,f.task,f.peer,["audience":"holder"])).keys),Set([f.holder.sessionID!,f.child.sessionID!]))
        let toOrchestrator = try routeNote(f.p,f.task,nil,["audience":"orchestrator","expects_reply":true])
        XCTAssertEqual(Array(routeDeliveries(toOrchestrator).keys),[f.orchestrator.sessionID!])
        XCTAssertEqual(toOrchestrator["reply_recipient_session_id"] as? String,f.orchestrator.sessionID)
        XCTAssertEqual(toOrchestrator["audience"] as? String,"orchestrator")
        let loose = try ready(f.p), plan = try call("triage_create",["project_id":f.p["id"]!,"name":"Plan"])
        let planned = try ready(f.p);try routeAdd(f.p,plan["id"]!,planned)
        let before = try routeMessageCount(f.p)
        assertCode("INVALID_INPUT") { _ = try self.routeNote(f.p,f.task,f.peer,["audience":"holder","recipient":["kind":"session","session_id":f.holder.sessionID!]]) }
        assertCode("INVALID_INPUT") { _ = try self.routeNote(f.p,f.task,f.peer,["audience":"everyone"]) }
        assertCode("TRIAGE_ORCHESTRATOR_REQUIRED") { _ = try self.routeNote(f.p,loose,f.peer,["audience":"orchestrator"]) }
        assertCode("TRIAGE_ORCHESTRATOR_REQUIRED") { _ = try self.routeNote(f.p,planned,f.peer,["audience":"orchestrator"]) }
        // Owner directions always reach both roles; audience cannot narrow them.
        assertCode("INVALID_INPUT") { _ = try self.routeNote(f.p,f.task,nil,["audience":"holder","requires_action":true]) }
        XCTAssertEqual(try routeMessageCount(f.p),before,"A refused send saves no message.")
        let direction = try routeNote(f.p,f.task,nil,["requires_action":true])
        let roles = Dictionary(uniqueKeysWithValues:(direction["deliveries"] as! [JSON]).map {($0["recipient_session_id"] as! String,$0["recipient_role"] as! String)})
        XCTAssertEqual(roles,[f.holder.sessionID!:"handler",f.child.sessionID!:"registered_child",f.orchestrator.sessionID!:"triage_orchestrator"])
        // The schema is discoverable and closed.
        let tools = try call("tool_catalog",[:],f.peer)["tools"] as! [JSON]
        let schema = tools.first { $0["name"] as? String == "message_send" }?["inputSchema"] as? JSON
        XCTAssertEqual(((schema?["properties"] as? JSON)?["audience"] as? JSON)?["enum"] as? [String],["all","holder","orchestrator"])
        XCTAssertEqual(schema?["additionalProperties"] as? Bool,false)
    }

    func testTakeoverHandoffAndHealthNoticesReachBothRolesAndCoordinatorIsRetired() throws {
        let f = try routeFixture(), taker = try native(f.p,"taker",domain:"host-t")
        // Work health: the check request reaches the holder and the orchestrator.
        _ = try router.runWorkHealthChecks(at: Date().addingTimeInterval(7200))
        let health = try router.dbQueue.read { db -> [String] in
            let message = try router.records(db,type:"message",project:f.p["id"] as? String).first { $0["kind"] as? String == "work_health" && $0["task_id"] as? String == f.task["id"] as? String }
            return try router.records(db,type:"delivery",project:f.p["id"] as? String).filter { $0["message_id"] as? String == message?["id"] as? String }.compactMap { $0["recipient_session_id"] as? String }
        }
        XCTAssertEqual(Set(health),Set([f.holder.sessionID!,f.orchestrator.sessionID!]))
        // Takeover: each earlier holder and the Triage orchestrator.
        let project = try router.dbQueue.read { try router.record($0,f.p["id"] as! String,type:"project") }
        let taken = try call("work_takeover",["project_id":f.p["id"]!,"task_id":f.task["id"]!,"expected_revision":try routeFresh(f.task)["revision"]!,"reason":"Holder is busy","policy_revision":project["policy_revision"] ?? 1],taker)
        let takeover = (taken["takeover_notices"] as! [JSON]).flatMap { $0["deliveries"] as? [JSON] ?? [] }
        XCTAssertEqual(Set(takeover.compactMap { $0["recipient_session_id"] as? String }),Set([f.holder.sessionID!,f.child.sessionID!,f.orchestrator.sessionID!]))
        XCTAssertEqual(takeover.first { $0["recipient_session_id"] as? String == f.orchestrator.sessionID }?["recipient_role"] as? String,"triage_orchestrator")
        // Handoff: the earlier holder and the Triage orchestrator.
        let second = try ready(f.p);try routeAdd(f.p,f.triage["id"]!,second,f.orchestrator)
        let attempt = try claim(f.p,try routeFresh(second),caller:f.holder)
        let offer = try call("work_handoff_offer",["project_id":f.p["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"target_session_id":f.peer.sessionID!,"summary":"Please continue"],f.holder)
        let accepted = try call("work_handoff_accept",["project_id":f.p["id"]!,"offer_id":offer["id"]!],f.peer)
        let handoff = (accepted["handoff_notices"] as! [JSON]).flatMap { $0["deliveries"] as? [JSON] ?? [] }
        XCTAssertEqual(Set(handoff.compactMap { $0["recipient_session_id"] as? String }),Set([f.holder.sessionID!,f.orchestrator.sessionID!]))
        // coordinator_session_id no longer routes and new policy saves refuse it.
        let settings = try call("project_settings_get",["project_id":f.p["id"]!])
        var policy = settings["policy"] as! JSON;policy["coordinator_session_id"] = f.peer.sessionID!
        assertCode("INVALID_INPUT") { _ = try self.call("policy_apply",["project_id":f.p["id"]!,"expected_revision":settings["revision"]!,"policy":policy]) }
    }

    func testNotesWithNoRoleAreSavedAndDeliveredOnceOnJoin() throws {
        let p = try project(), o = try native(p,"orchestrator",domain:"host-o"), h = try native(p,"holder",domain:"host-h"), peer = try native(p,"peer",domain:"host-p")
        let plan = try call("triage_create",["project_id":p["id"]!,"name":"Pass 9"]), task = try ready(p)
        try routeAdd(p,plan["id"]!,task,peer)
        let saved = try routeNote(p,task,peer)
        XCTAssertEqual(saved["delivery_status"] as? String,"saved_for_pickup");XCTAssertEqual((saved["deliveries"] as! [JSON]).count,0)
        let planNote = try routeNote(p,nil,peer,["triage_id":plan["id"]!])
        XCTAssertEqual(planNote["delivery_status"] as? String,"saved_for_pickup")
        // The orchestrator joins: each saved note is delivered once.
        let started = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":plan["id"]!,"expected_revision":try routeTriage(plan["id"]!)["revision"]!,"action":"start"],o)
        XCTAssertEqual(started["saved_notes_delivered"] as? Int,2);XCTAssertEqual(started["saved_note_delivery_has_more"] as? Bool,false)
        let inbox = try call("session_inbox",["project_id":p["id"]!],o)["deliveries"] as! [JSON]
        XCTAssertEqual(Set(inbox.compactMap {$0["message_id"] as? String}),Set([saved["id"] as! String,planNote["id"] as! String]))
        // A later holder pickup does not deliver it again.
        _ = try claim(p,try routeFresh(task),caller:h)
        _ = try call("task_context",["project_id":p["id"]!,"task_id":task["id"]!],h)
        XCTAssertEqual((try call("message_delivery_list",["project_id":p["id"]!,"task_id":task["id"]!,"message_id":saved["id"]!],peer)["deliveries"] as! [JSON]).count,1)
        // No holder but an orchestrator: the orchestrator receives the note.
        let other = try ready(p);try routeAdd(p,plan["id"]!,other,o)
        let toOrchestrator = routeDeliveries(try routeNote(p,other,peer))
        XCTAssertEqual(Array(toOrchestrator.keys),[o.sessionID!])
        XCTAssertTrue((toOrchestrator[o.sessionID!]?["label"] as? String ?? "").contains("has no current holder"))
        // A holder that joins by claim receives a note saved before any role existed.
        let lone = try ready(p), early = try routeNote(p,lone,peer)
        XCTAssertEqual(early["delivery_status"] as? String,"saved_for_pickup")
        _ = try claim(p,try routeFresh(lone),caller:h)
        _ = try call("task_context",["project_id":p["id"]!,"task_id":lone["id"]!],h)
        let late = try call("message_delivery_list",["project_id":p["id"]!,"task_id":lone["id"]!,"message_id":early["id"]!],peer)["deliveries"] as! [JSON]
        XCTAssertEqual(late.compactMap {$0["recipient_session_id"] as? String},[h.sessionID!])
        // At most 50 saved notes per pickup; the rest are advertised.
        let crowded = try call("triage_create",["project_id":p["id"]!,"name":"Crowded plan"]), parked = try ready(p)
        try routeAdd(p,crowded["id"]!,parked,peer)
        for _ in 0..<51 { _ = try routeNote(p,nil,peer,["triage_id":crowded["id"]!]) }
        let helper = try native(p,"second-orchestrator",domain:"host-x")
        let joined = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":crowded["id"]!,"expected_revision":try routeTriage(crowded["id"]!)["revision"]!,"action":"start"],helper)
        XCTAssertEqual(joined["saved_notes_delivered"] as? Int,50);XCTAssertEqual(joined["saved_note_delivery_has_more"] as? Bool,true)
    }

    func testTicketFreeTriageNotesRouteCorrelateAndRefuseAtomically() throws {
        let p = try project(), o = try native(p,"orchestrator",domain:"host-o"), peer = try native(p,"peer",domain:"host-p")
        let empty = try routeStart(p,o), command = UUID().uuidString
        let note = try routeNote(p,nil,peer,["triage_id":empty["id"]!],command:command)
        let delivery = try XCTUnwrap(routeDeliveries(note)[o.sessionID!])
        XCTAssertEqual(routeDeliveries(note).count,1);XCTAssertEqual(delivery["recipient_role"] as? String,"triage_orchestrator")
        XCTAssertNil(note["task_id"]);XCTAssertEqual((note["subject"] as? JSON)?["kind"] as? String,"triage")
        // A same-command retry returns the same receipt without a second delivery.
        let retry = try routeNote(p,nil,peer,["triage_id":empty["id"]!],command:command)
        XCTAssertEqual(retry["id"] as? String,note["id"] as? String)
        let listed = try call("message_delivery_list",["project_id":p["id"]!,"triage_id":empty["id"]!,"message_id":note["id"]!],peer)["deliveries"] as! [JSON]
        XCTAssertEqual(listed.count,1)
        XCTAssertEqual(try call("message_ack",["project_id":p["id"]!,"delivery_id":delivery["id"]!,"stage":"acknowledged"],o)["state"] as? String,"acknowledged")
        // The orchestrator's correlated reply returns to the sender.
        let reply = try routeNote(p,nil,o,["reply_to":note["id"]!])
        XCTAssertEqual(Array(routeDeliveries(reply).keys),[peer.sessionID!]);XCTAssertEqual(reply["reply_to"] as? String,note["id"] as? String)
        XCTAssertEqual(reply["triage_id"] as? String,empty["id"] as? String)
        let other = try call("triage_create",["project_id":p["id"]!,"name":"Other plan"])
        let foreignRoot = directory.appendingPathComponent("foreign");try FileManager.default.createDirectory(at:foreignRoot,withIntermediateDirectories:true)
        let foreign = try call("project_create",["name":"Foreign","key_prefix":"F","root_path":foreignRoot.path])
        let foreignTriage = try call("triage_create",["project_id":foreign["id"]!,"name":"Elsewhere"])
        let before = try routeMessageCount(p)
        assertCode("INVALID_INPUT") { _ = try self.routeNote(p,nil,o,["reply_to":note["id"]!,"triage_id":other["id"]!]) }
        assertCode("INVALID_INPUT") { _ = try self.routeNote(p,nil,peer,["triage_id":empty["id"]!,"audience":"holder"]) }
        assertCode("INVALID_INPUT") { _ = try self.routeNote(p,nil,peer) }
        assertCode("TRIAGE_ORCHESTRATOR_REQUIRED") { _ = try self.routeNote(p,nil,peer,["triage_id":other["id"]!,"audience":"orchestrator"]) }
        XCTAssertThrowsError(try routeNote(p,nil,peer,["triage_id":foreignTriage["id"]!]))
        XCTAssertEqual(try routeMessageCount(p),before,"A refused send saves no message.")
        // A plan with an exact recipient delivers; without one the note is saved.
        let exact = try routeNote(p,nil,peer,["triage_id":other["id"]!,"recipient":["kind":"session","session_id":o.sessionID!]])
        XCTAssertEqual(Array(routeDeliveries(exact).keys),[o.sessionID!])
        XCTAssertEqual(try routeNote(p,nil,peer,["triage_id":other["id"]!])["delivery_status"] as? String,"saved_for_pickup")
    }
}
