import XCTest
import GRDB
@testable import ChecklistCore

// CL-248 item 3 (runner R42C): a verdict that returns work notifies the holder and the
// orchestrator of the return Triage, written after the verdict's Triage move
// (docs/triage-orchestrators.md#message-routing). Synthetic projects and templates only.
extension EvidenceAuthorityTests {
    private func vnTriage(_ id: Any) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:"group") } }
    private func vnMembers(_ id: Any) throws -> [String] { router.triageMemberIDs(try vnTriage(id)) }
    private func vnFresh(_ task: JSON) throws -> JSON { try router.dbQueue.read { try router.record($0,task["id"] as! String,type:"task") } }
    /// Recipient session to delivery receipt for one notice, read with message_delivery_list.
    private func vnDeliveries(_ p: JSON,_ task: JSON,_ messageID: Any?,_ reader: Caller) throws -> [String: JSON] {
        let mid = try XCTUnwrap(messageID as? String,"The verdict wrote a return notice.")
        let rows = try call("message_delivery_list",["project_id":p["id"]!,"task_id":task["id"]!,"message_id":mid],reader)["deliveries"] as! [JSON]
        return Dictionary(uniqueKeysWithValues:rows.map {($0["recipient_session_id"] as! String,$0)})
    }
    private typealias VNSetup = (p: JSON,ta: JSON,tb: JSON?,oa: Caller,h: Caller,b: Caller)
    /// OA orchestrates TA; holder H orchestrates nothing; reviewer B orchestrates TB when asked.
    private func vnSetup(reviewerOrchestrates: Bool) throws -> VNSetup {
        try sourceFixture()
        let p = try project()
        let oa = try native(p,"orchestrator-a",domain:"codex:vn-oa"), h = try native(p,"holder",domain:"codex:vn-h")
        let b = try native(p,"reviewer-b",domain:"claude:vn-b",provider:"claude")
        let ta = try call("triage_orchestrate",["project_id":p["id"]!,"action":"start"],oa)
        let tb = reviewerOrchestrates ? try call("triage_orchestrate",["project_id":p["id"]!,"action":"start"],b) : nil
        return (p,ta,tb,oa,h,b)
    }
    /// A ticket in TA that H claims and submits and B review-claims.
    private func vnReviewed(_ s: VNSetup) throws -> (task: JSON,review: JSON) {
        let task = try ready(s.p)
        _ = try call("group_membership",["project_id":s.p["id"]!,"group_id":s.ta["id"]!,"expected_revision":try vnTriage(s.ta["id"]!)["revision"]!,"task_id":task["id"]!,"action":"add"],s.oa)
        let attempt = try claim(s.p,try vnFresh(task),caller:s.h)
        var input = auth(s.p,attempt);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
        let review = try reviewClaim(s.p,try call("work_submit",input,s.h),s.b)
        let tid = task["id"] as! String
        if let tb = s.tb { XCTAssertTrue(try vnMembers(tb["id"]!).contains(tid),"The review claim moves the ticket to B's Triage.") }
        else { XCTAssertTrue(try vnMembers(s.ta["id"]!).contains(tid),"A reviewer with no Triage leaves the ticket in TA.") }
        return (task,review)
    }
    /// Return notices vary only by verdict. Clone their submitted, claimed
    /// target rather than repeating enrollment, orchestration and capture.
    private func vnReviewedPhase(reviewerOrchestrates: Bool) throws -> (setup: VNSetup, task: JSON, review: JSON) {
        let phase = try preparedPhase("verdict-notice-\(reviewerOrchestrates)") { fixture in
            let setup = try fixture.vnSetup(reviewerOrchestrates: reviewerOrchestrates)
            let (task, review) = try fixture.vnReviewed(setup)
            var payload: JSON = ["project":setup.p,"ta":setup.ta,"oa":setup.oa.sessionID!,"holder":setup.h.sessionID!,"reviewer":setup.b.sessionID!,"task":task,"review":review]
            if let tb = setup.tb { payload["tb"] = tb }
            return payload
        }
        let setup: VNSetup = (phase["project"] as! JSON, phase["ta"] as! JSON, phase["tb"] as? JSON,
                              try phaseCaller(phase["oa"]!), try phaseCaller(phase["holder"]!), try phaseCaller(phase["reviewer"]!))
        let task = phase["task"] as! JSON, review = phase["review"] as! JSON, tid = task["id"] as! String
        // Assert the actual private copy's pre-verdict membership on every use.
        if let tb = setup.tb { XCTAssertTrue(try vnMembers(tb["id"]!).contains(tid),"The review claim moves the ticket to B's Triage.") }
        else { XCTAssertTrue(try vnMembers(setup.ta["id"]!).contains(tid),"A reviewer with no Triage leaves the ticket in TA.") }
        return (setup, task, review)
    }

    private func vnVerdict(_ p: JSON,_ review: JSON,_ kind: String) throws -> JSON {
        var input = reviewInput(p,review,verdict:kind == "implementation_blocked" ? "blocked" : kind)
        if kind != "reject" { input["reason"] = "The implementing session must supply the recorded device check." }
        if kind == "not_run" { input["check"] = "device check" }
        if kind == "implementation_blocked" { input["blocked_on"] = "implementation" }
        if kind == "implementation_blocked" || kind == "reject" {
            let manifest = try router.dbQueue.read { try router.record($0,review["manifest_id"] as! String,type:"manifest") }
            let source = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
            input["findings"] = [["client_ref":"gap","description":"Supply the recorded device input","severity":"normal","evidence_refs":[["source_capture_id":source["id"]!,"sha256":source["sha256"]!]]]]
        }
        return input
    }
    private func vnAssertReturnNotice(_ kind: String, reviewerOrchestrates: Bool = true) throws {
        let (f,task,review) = try vnReviewedPhase(reviewerOrchestrates: reviewerOrchestrates)
        let result = try call("review_record",try vnVerdict(f.p,review,kind),f.b)
        let routing = try XCTUnwrap(result["implementation_return"] as? JSON,kind)
        XCTAssertEqual(routing["state"] as? String,"active",kind)
        XCTAssertTrue(try vnMembers(f.ta["id"]!).contains(task["id"] as! String),"\(kind): the ticket is back in its return Triage.")
        if let tb = f.tb { XCTAssertFalse(try vnMembers(tb["id"]!).contains(task["id"] as! String),kind) }
        let d = try vnDeliveries(f.p,task,routing["message_id"],f.h), key = task["key"] as! String
        XCTAssertEqual(Set(d.keys),Set([f.h.sessionID!,f.oa.sessionID!]),"\(kind): one copy each for the holder and TA's orchestrator, none for the reviewer.")
        XCTAssertEqual(d[f.h.sessionID!]?["recipient_role"] as? String,"handler",kind)
        XCTAssertTrue((d[f.h.sessionID!]?["label"] as? String ?? "").contains("which orchestrates"),kind)
        XCTAssertEqual(d[f.oa.sessionID!]?["recipient_role"] as? String,"triage_orchestrator",kind)
        XCTAssertTrue((d[f.oa.sessionID!]?["label"] as? String ?? "").contains(key),kind)
        let stored = try router.dbQueue.read { try router.record($0,result["id"] as! String,type:"review") }
        XCTAssertEqual((stored["implementation_return"] as? JSON)?["message_id"] as? String,routing["message_id"] as? String,kind)
    }

    // R42C: the reviewer orchestrates another Triage, so the ticket sits in TB when the verdict is recorded.
    func testVerdictReturnNoticeReachesHolderAndReturnTriageOrchestrator() throws {
        try vnAssertReturnNotice("evidence_missing")
    }

    func testNotRunVerdictReturnNoticeReachesHolderAndReturnTriageOrchestrator() throws {
        try vnAssertReturnNotice("not_run")
    }

    func testImplementationBlockedVerdictReturnNoticeReachesHolderAndReturnTriageOrchestrator() throws {
        try vnAssertReturnNotice("implementation_blocked")
    }

    func testVerdictReturnNoticeWhenReviewerOrchestratesNoTriage() throws {
        try vnAssertReturnNotice("evidence_missing", reviewerOrchestrates: false)
    }

    // A reject queues the ticket with no holder; its notice reaches the return Triage's orchestrator, never the reviewer.
    func testRejectNoticeReachesReturnTriageOrchestrator() throws {
        let (s,task,review) = try vnReviewedPhase(reviewerOrchestrates: true)
        let result = try call("review_record",try vnVerdict(s.p,review,"reject"),s.b)
        XCTAssertNil(result["implementation_return"])
        XCTAssertTrue(try vnMembers(s.ta["id"]!).contains(task["id"] as! String))
        let d = try vnDeliveries(s.p,task,result["return_notice_message_id"],s.oa)
        XCTAssertNil(d[s.b.sessionID!],"The reviewer gets no copy.")
        XCTAssertEqual(d[s.oa.sessionID!]?["recipient_role"] as? String,"triage_orchestrator")
        XCTAssertTrue((d[s.oa.sessionID!]?["label"] as? String ?? "").contains(task["key"] as! String))
        let stored = try router.dbQueue.read { try router.record($0,result["id"] as! String,type:"review") }
        XCTAssertEqual(stored["return_notice_message_id"] as? String,result["return_notice_message_id"] as? String)
    }
}
