import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-430 exercises the existing owner/worker paths against owned stores only.
final class MediaItemTaskTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let results = MediaRoundResultTests()
    let cleanup = MediaLinkedTaskCleanupTests()
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()

    func link(_ f: Fixture,_ round: JSON,_ id: String,_ task: JSON?,worker: Bool = false,command: String? = nil) throws -> JSON {
        let item = try f.record(id,"media_item")
        let p: JSON = ["round_id":round["id"]!,"item_id":id,"expected_revision":item["revision"]!,"task_id":task?["id"] ?? NSNull()]
        return try worker ? channel.worker(f,"media_item_link_task",p,command:command) : f.call("media_item_link_task",p,command:command)
    }

    func testItemLinkOwnerWorkerReadsFallbackGateAndExactReplay() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a)
        let beforeItem = try f.record(ids[0],"media_item"),beforeRound = try f.get(r),command = uuid()
        let input: JSON = ["round_id":r["id"]!,"item_id":ids[0],"expected_revision":beforeItem["revision"]!,"task_id":b["id"]!]
        let linked = try channel.worker(f,"media_item_link_task",input,command:command)
        XCTAssertEqual(linked["revision"] as? Int,int(beforeItem,"revision") + 1)
        XCTAssertEqual((linked["task_linked_by"] as? JSON)?["actor_kind"] as? String,"agent")
        XCTAssertGreaterThan(int(try f.get(r),"revision"),int(beforeRound,"revision"))
        let after = try f.allState()
        XCTAssertEqual(try channel.worker(f,"media_item_link_task",input,command:command)["replayed"] as? Bool,true)
        var changed = input;changed["task_id"] = NSNull()
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.channel.worker(f,"media_item_link_task",changed,command:command)}
        XCTAssertEqual(try f.allState(),after)
        try f.reopen()
        let workerRows = try channel.worker(f,"media_round_get",["round_id":r["id"]!])["items"] as! [JSON]
        let ownerRows = try f.get(r)["items"] as! [JSON]
        let page = try f.router.executeMediaOwnerChannel(method:"media_item_page",params:["project_id":f.project,"round_id":r["id"]!],caller:f.owner)
        for rows in [workerRows,ownerRows,page["rows"] as! [JSON]] {
            let summary = try XCTUnwrap(rows.first {$0["id"] as? String == ids[0]}?["task"] as? JSON)
            XCTAssertEqual(Set(summary.keys),["id","key","title","status_name"])
            XCTAssertEqual(summary["id"] as? String,b["id"] as? String)
            XCTAssertTrue(rows.first {$0["id"] as? String == ids[1]}?["task"] is NSNull,"Unlinked items read null; the client falls back to the round")
        }
        let detail = try f.router.executeMediaOwnerChannel(method:"media_item_get",params:["project_id":f.project,"round_id":r["id"]!,"item_id":ids[0]],caller:f.owner)
        XCTAssertEqual((detail["task"] as? JSON)?["id"] as? String,b["id"] as? String)
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        let gated = try f.allState()
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try self.link(f,r,ids[0],nil,worker:true)}
        XCTAssertEqual(try f.allState(),gated)
        var clear = input;clear["expected_revision"] = linked["revision"];clear["task_id"] = NSNull();clear["project_id"] = f.project;clear["command_id"] = uuid()
        let cleared = try f.router.executeMediaOwnerChannel(method:"media_item_link_task",params:clear,caller:f.owner)
        XCTAssertTrue(cleared["task"] is NSNull)
        try results.decide(f,r,ids[0],"needs_look","Uses fallback")
        let send = try f.call("media_round_send_result",results.sendInput(f,r))
        XCTAssertEqual((send["sends"] as! [JSON])[0]["task_id"] as? String,a["id"] as? String)
    }

    func testItemLinkRejectsWrongProjectRoundStaleMissingAndClosedWithoutWrites() throws {
        let f = try Fixture(),task = try results.task(f),r = try f.round(f.type(checks.schema())),item = try f.item(r)
        let other = try f.round(f.type(checks.schema()))
        let root = f.base.appendingPathComponent("foreign-workspace")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let foreign = try results.call(f,"project_create",["name":"Foreign","key_prefix":"FR","root_path":root.path])
        let epic = try results.call(f,"epic_create",["project_id":foreign["id"]!,"name":"Foreign"])
        let foreignTask = try results.call(f,"task_create",["project_id":foreign["id"]!,"title":"Other","epic_id":epic["id"]!])
        let p: JSON = ["round_id":r["id"]!,"item_id":item["id"]!,"expected_revision":item["revision"]!,"task_id":task["id"]!]
        let before = try f.allState()
        for id in [foreignTask["id"]!,uuid()] {
            var input = p;input["task_id"] = id
            checks.checkError("NOT_FOUND") {try f.call("media_item_link_task",input)}
        }
        var input = p;input["round_id"] = other["id"]
        checks.checkError("NOT_FOUND") {try f.call("media_item_link_task",input)}
        input = p;input["expected_revision"] = 999
        checks.checkError("REVISION_CONFLICT") {try f.call("media_item_link_task",input)}
        input = p;input["task_id"] = nil
        checks.checkError("INVALID_INPUT") {try f.call("media_item_link_task",input)}
        XCTAssertEqual(try f.allState(),before)
        let canceled = try f.call("media_round_cancel",["round_id":r["id"]!,"expected_revision":r["revision"]!,"reason":"Retire"])
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_item_link_task",p)}
        _ = try f.call("media_round_archive",["round_id":r["id"]!,"expected_revision":canceled["revision"]!])
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_item_link_task",p)}
        let (closed,ids) = try MediaAgentRoundActionTests().published(f,1)
        try f.acceptEach(closed)
        _ = try f.call("media_round_finish",MediaAgentRoundActionTests().fence(f.get(closed)))
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.link(f,closed,ids[0],task)}
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_round_send_result",self.results.sendInput(f,closed))}
    }

    func testMixedSendPartitionsRecipientsAndOnlyResendsChangedItemOrDestination() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a);_ = try link(f,r,ids[1],b,worker:true)
        let oa = try results.session(f,"mixed-orchestrator-a"),ob = try results.session(f,"mixed-orchestrator-b")
        try results.triage(f,a,oa);try results.triage(f,b,ob)
        let holder = try results.session(f,"mixed-holder")
        let ready = try results.call(f,"task_edit",["task_id":a["id"]!,"expected_revision":try f.record(a["id"] as! String,"task")["revision"]!,"patch":["readiness":"ready"]])
        _ = try results.call(f,"work_claim",["task_id":a["id"]!,"expected_revision":ready["revision"]!,"file_scopes":[],"lane_scopes":[]],as:holder)
        for (id,note) in zip(ids,["fallback A","explicit B","sibling A","also A"]) {try results.decide(f,r,id,"needs_look",note)}
        let input = try results.sendInput(f,r),command = uuid(),sent = try f.call("media_round_send_result",input,command:command)
        let sends = sent["sends"] as! [JSON]
        XCTAssertEqual(sends.count,2);XCTAssertEqual(sent["unsent_item_count"] as? Int,0)
        for send in sends {
            let isA = send["task_id"] as? String == a["id"] as? String
            let body = try f.record(send["message_id"] as! String,"message")["body"] as! String
            XCTAssertEqual(body.contains("explicit B"),!isA);XCTAssertEqual(body.contains("fallback A"),isA)
            XCTAssertEqual(Set((send["recipients"] as! [JSON]).compactMap {$0["session_id"] as? String}),isA ? [oa.sessionID!,holder.sessionID!] : [ob.sessionID!])
            XCTAssertEqual(send["item_count"] as? Int,isA ? 3 : 1)
        }
        let before = try f.allState()
        XCTAssertEqual(try f.call("media_round_send_result",input,command:command)["replayed"] as? Bool,true)
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
        try results.decide(f,r,ids[0],"needs_look","changed A")
        var update = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(update.count,1);XCTAssertEqual(update[0]["item_count"] as? Int,1)
        _ = try link(f,r,ids[0],b)
        update = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(update.count,1);XCTAssertEqual(update[0]["task_id"] as? String,b["id"] as? String);XCTAssertEqual(update[0]["item_count"] as? Int,1)
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
    }

    func testMixedSendRoutesWithdrawalOnlyToItsPreviouslySentTicket() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a);_ = try link(f,r,ids[1],b)
        let oa = try results.session(f,"withdrawal-orchestrator-a"),ob = try results.session(f,"withdrawal-orchestrator-b")
        try results.triage(f,a,oa);try results.triage(f,b,ob)
        let holder = try results.session(f,"withdrawal-holder-a")
        let ready = try results.call(f,"task_edit",["task_id":a["id"]!,"expected_revision":try f.record(a["id"] as! String,"task")["revision"]!,"patch":["readiness":"ready"]])
        _ = try results.call(f,"work_claim",["task_id":a["id"]!,"expected_revision":ready["revision"]!,"file_scopes":[],"lane_scopes":[]],as:holder)
        try results.decide(f,r,ids[0],"accepted","Sent A")
        try results.decide(f,r,ids[1],"needs_look","Sent B")
        _ = try f.call("media_round_send_result",results.sendInput(f,r))
        let view = try f.get(r),manifest = view["manifest"] as! JSON
        let item = (view["items"] as! [JSON]).first {$0["id"] as? String == ids[0]}!
        var input = f.observation(view)
        input["manifest_id"] = manifest["id"];input["manifest_digest"] = manifest["digest"]
        input["items"] = [["item_id":ids[0],"expected_revision":item["revision"]!,"decision_id":item["last_decision_id"]!]]
        _ = try f.call("media_decision_withdraw",input)
        try results.decide(f,r,ids[1],"accepted","Changed B")
        let sent = try f.call("media_round_send_result",results.sendInput(f,r)),sends = sent["sends"] as! [JSON]
        XCTAssertEqual(sends.count,2);XCTAssertEqual(sent["changed_only"] as? Bool,true)
        XCTAssertNil(sent["message_id"],"Mixed routing keeps receipts per ticket")
        XCTAssertEqual(sent["unsent_item_count"] as? Int,0)
        for send in sends {
            let isA = send["task_id"] as? String == a["id"] as? String
            let body = try f.record(send["message_id"] as! String,"message")["body"] as! String
            XCTAssertEqual(Array(body.components(separatedBy:"\n\n").dropFirst()),[isA ? "Walk @literal: Pending — decision withdrawn" : "Idle: Accepted — Changed B"])
            XCTAssertEqual(send["item_count"] as? Int,1)
            XCTAssertEqual(Set((send["recipients"] as! [JSON]).map {$0["session_id"] as! String}),isA ? [oa.sessionID!,holder.sessionID!] : [ob.sessionID!])
        }
        let receipt = try XCTUnwrap(f.get(r)["last_result_sent"] as? JSON),baseline = receipt["sends"] as! [JSON]
        XCTAssertEqual(baseline.count,1);XCTAssertEqual(baseline[0]["task_id"] as? String,b["id"] as? String)
        XCTAssertEqual(strings(receipt,"decision_ids"),[try f.record(ids[1],"media_item")["last_decision_id"] as! String])
        let before = try f.allState()
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
    }

    func testItemOnlySendCountsUnroutedAndMixedLateFailureRollsBackAllNotes() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        checks.checkError("MEDIA_ROUND_NO_TASK") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
        _ = try link(f,r,ids[0],a);_ = try link(f,r,ids[1],b)
        checks.checkError("MEDIA_ROUND_NO_DECISIONS") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
        for id in ids {try results.decide(f,r,id,"needs_look","Decision "+id)}
        let before = try f.allState()
        try f.router.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER mixed_result_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned mixed late failure');END")
        }
        XCTAssertThrowsError(try f.call("media_round_send_result",results.sendInput(f,r)))
        XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER mixed_result_failure")}
        let sent = try f.call("media_round_send_result",results.sendInput(f,r))
        XCTAssertEqual((sent["sends"] as! [JSON]).count,2);XCTAssertEqual(sent["unsent_item_count"] as? Int,2)
        XCTAssertNil(sent["message_id"])
    }

    func testAllNamedTasksGateAutomaticArchiveIncludingFallbackAndUnpublishedItems() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),c = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a)
        for id in ids {_ = try link(f,r,id,b)}
        try f.acceptEach(r)
        let draft = try f.item(r,title:"Future item")
        _ = try link(f,r,draft["id"] as! String,c)
        try cleanup.done(f,b)
        XCTAssertEqual(try f.get(r)["state"] as? String,"open","The unused round fallback is still a named ticket")
        try cleanup.done(f,a)
        XCTAssertEqual(try f.get(r)["state"] as? String,"open","An unpublished item's explicit ticket still gates archive")
        try cleanup.done(f,c)
        XCTAssertEqual(try f.get(r)["state"] as? String,"archived","The last item ticket completion finds the round")
        let before = try f.allState()
        for t in [a,b,c] {try cleanup.done(f,t,changeStatus:false)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testItemOnlyDoneClosesAndUndecidedWarningsReachEveryNamedOrchestratorOnce() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try link(f,r,ids[0],a);_ = try link(f,r,ids[1],b)
        let oa = try results.session(f,"warning-orchestrator-a"),ob = try results.session(f,"warning-orchestrator-b")
        try results.triage(f,a,oa);try results.triage(f,b,ob)
        try cleanup.done(f,a)
        XCTAssertTrue(try f.rows("message").isEmpty,"An earlier Done must not report a premature undecided count")
        try results.decide(f,r,ids[0],"accepted","Decided between completions")
        try f.reopen()
        try cleanup.done(f,b)
        let warnings = try f.rows("message")
        XCTAssertEqual(warnings.count,2)
        XCTAssertTrue(warnings.allSatisfy {$0["body"] as? String == "First pass has 3 undecided items; it stays open"})
        XCTAssertEqual(Set(try f.rows("delivery").compactMap {$0["recipient_session_id"] as? String}),[oa.sessionID!,ob.sessionID!])
        let before = try f.allState()
        try cleanup.done(f,b,changeStatus:false)
        XCTAssertEqual(try f.allState(),before)
        XCTAssertEqual(try f.rows("message").count,2)
        XCTAssertEqual(try f.get(r)["state"] as? String,"open")
        try f.acceptEach(r)
        try cleanup.done(f,b,changeStatus:false)
        XCTAssertEqual(try f.get(r)["state"] as? String,"archived")
    }

    func testEarlierDoneOrchestratorGenerationChangeKeepsFinalWarningForPickup() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try link(f,r,ids[0],a);_ = try link(f,r,ids[1],b)
        let oa = try results.session(f,"revoked-warning-a"),ob = try results.session(f,"live-warning-b")
        try results.triage(f,a,oa);try results.triage(f,b,ob)
        try cleanup.done(f,a)
        try f.router.dbQueue.write {db in
            var session = try f.router.record(db,oa.sessionID!,type:"session")
            session["authorization_generation"] = uuid();try f.router.save(db,f.router.revised(session),type:"session")
        }
        try cleanup.done(f,b)
        let saved = try XCTUnwrap(f.rows("message").first {$0["task_id"] as? String == a["id"] as? String})
        XCTAssertEqual(saved["pickup_pending"] as? Bool,true)
        XCTAssertEqual(Set(try f.rows("delivery").compactMap {$0["recipient_session_id"] as? String}),[ob.sessionID!])
    }

    func testLegacyPrematureWarningDoesNotSuppressTheFinalDoneCount() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a);_ = try link(f,r,ids[0],b)
        let oa = try results.session(f,"legacy-warning-a"),ob = try results.session(f,"legacy-warning-b")
        try results.triage(f,a,oa);try results.triage(f,b,ob)
        // Create the actual old warning and delivery while A still has membership.
        let old = try f.router.dbQueue.write {db in
            try f.router.messageWrite(db,["project_id":f.project,"task_id":a["id"]!,"audience":"orchestrator",
                "body":"First pass has 4 undecided items; it stays open"],f.owner,"message_send",purpose:.systemNote,literalBody:true)
        }
        try cleanup.done(f,a)
        // Installed build-289 receipts predate done_task_orchestrators and stage.
        try f.router.dbQueue.write {db in
            var round = try f.router.record(db,r["id"] as! String,type:"media_round")
            let warning: JSON = ["task_id":a["id"]!,"message_id":old["id"]!,"undecided_count":4,"at":now()]
            round["done_task_warning"] = warning;round["done_task_warnings"] = [warning]
            round["done_task_orchestrators"] = nil
            try f.router.save(db,f.router.revised(round),type:"media_round")
        }
        try results.decide(f,r,ids[0],"accepted","Between Dones")
        try f.reopen()
        try cleanup.done(f,b)
        let finalNotes = try f.rows("message").filter {$0["id"] as? String != old["id"] as? String}
        XCTAssertEqual(finalNotes.count,2)
        XCTAssertTrue(finalNotes.allSatisfy {$0["body"] as? String == "First pass has 3 undecided items; it stays open"})
        let messageIDs = Set(finalNotes.compactMap {$0["id"] as? String})
        let deliveries = try f.rows("delivery").filter {messageIDs.contains($0["message_id"] as? String ?? "")}
        XCTAssertEqual(Set(deliveries.compactMap {$0["recipient_session_id"] as? String}),[oa.sessionID!,ob.sessionID!])
        let stored = try f.record(r["id"] as! String,"media_round")
        XCTAssertEqual((stored["done_task_warning"] as? JSON)?["undecided_count"] as? Int,3)
        XCTAssertEqual((stored["done_task_warning"] as? JSON)?["stage"] as? String,"all_named_done")
    }

    func testCanceledAndSupersededNamedTicketsNotifyOnceAndRetainOriginals() throws {
        for reason in ["canceled","superseded"] {
            let f = try Fixture(),(a,r,attachment) = try cleanup.imageRound(f),b = try results.task(f)
            let id = try XCTUnwrap((f.get(r)["items"] as? [JSON])?.first?["id"] as? String)
            _ = try link(f,r,id,b)
            let oa = try results.session(f,"terminal-a"),ob = try results.session(f,"terminal-b")
            try results.triage(f,a,oa);try results.triage(f,b,ob)
            try cleanup.done(f,a)
            XCTAssertTrue(try f.rows("message").isEmpty)
            let current = try f.record(b["id"] as! String,"task")
            if reason == "canceled" {
                let statusID = try f.router.dbQueue.read {try f.router.status($0,f.project,"canceled")["id"]!}
                _ = try results.call(f,"task_transition",["task_id":b["id"]!,"expected_revision":current["revision"]!,"target_status_id":statusID,"reason":"No longer needed"])
            } else {
                let canonical = try results.task(f)
                _ = try results.call(f,"task_link",["task_id":b["id"]!,"expected_revision":current["revision"]!,"action":"add","relation":"duplicate_of","target_task_id":canonical["id"]!])
            }
            let messages = try f.rows("message")
            XCTAssertEqual(messages.count,2,reason)
            XCTAssertTrue(messages.allSatisfy {($0["body"] as? String ?? "").contains("is \(reason); change its ticket links or cancel and archive the round.")})
            XCTAssertEqual(Set(try f.rows("delivery").compactMap {$0["recipient_session_id"] as? String}),[oa.sessionID!,ob.sessionID!])
            XCTAssertEqual(try f.get(r)["state"] as? String,"open")
            XCTAssertNil(try f.record(r["id"] as! String,"media_round")["done_task_cleanup"])
            let path = f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as! String
            XCTAssertTrue(FileManager.default.fileExists(atPath:path))
            XCTAssertTrue(try f.rows("storage_hold").contains {$0["kind"] as? String == "media_reference" && $0["state"] as? String == "active"})
            let before = try f.allState()
            try cleanup.done(f,b,changeStatus:false)
            XCTAssertEqual(try f.allState(),before,"Repeated terminal actions must not repeat the notice")
        }
    }

    func testCanceledNamedTicketWithoutOrchestratorSavesNoticeForPickup() throws {
        let f = try Fixture(),a = try results.task(f),r = try f.round(f.type(checks.schema()))
        _ = try f.item(r)
        _ = try results.link(f,r,a)
        let statusID = try f.router.dbQueue.read {try f.router.status($0,f.project,"canceled")["id"]!}
        _ = try results.call(f,"task_transition",["task_id":a["id"]!,"expected_revision":a["revision"]!,"target_status_id":statusID,"reason":"No longer needed"])
        let note = try XCTUnwrap(f.rows("message").first)
        XCTAssertEqual(note["pickup_pending"] as? Bool,true)
        XCTAssertTrue(try f.rows("delivery").isEmpty)
        XCTAssertEqual(try f.get(r)["state"] as? String,"draft")
    }

    func testRelinkedItemAndRoundWithdrawalsReturnOnlyToTheirSentDestinations() throws {
        for route in ["item","round","cleared"] {
            let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
            _ = try results.link(f,r,a)
            try results.decide(f,r,ids[0],"accepted","Sent to A")
            _ = try f.call("media_round_send_result",results.sendInput(f,r))
            let baseline = try XCTUnwrap(f.get(r)["last_result_sent"] as? JSON)
            XCTAssertEqual((baseline["sends"] as! [JSON])[0]["task_key"] as? String,a["key"] as? String)
            if route == "item" {_ = try link(f,r,ids[0],b)}
            else {_ = try results.link(f,r,route == "cleared" ? nil : b)}
            let view = try f.get(r),manifest = view["manifest"] as! JSON
            let item = (view["items"] as! [JSON]).first {$0["id"] as? String == ids[0]}!
            var withdrawal = f.observation(view)
            withdrawal["manifest_id"] = manifest["id"];withdrawal["manifest_digest"] = manifest["digest"]
            withdrawal["items"] = [["item_id":ids[0],"expected_revision":item["revision"]!,"decision_id":item["last_decision_id"]!]]
            _ = try f.call("media_decision_withdraw",withdrawal)
            let input = try results.sendInput(f,r),command = uuid()
            let sent = try f.call("media_round_send_result",input,command:command),sends = sent["sends"] as! [JSON]
            XCTAssertEqual(sends.count,1,route)
            XCTAssertEqual(sends[0]["task_id"] as? String,a["id"] as? String,route)
            XCTAssertEqual(sends[0]["item_count"] as? Int,1)
            let body = try f.record(sends[0]["message_id"] as! String,"message")["body"] as! String
            XCTAssertTrue(body.hasSuffix("Walk @literal: Pending — decision withdrawn"))
            XCTAssertTrue(((try f.get(r)["last_result_sent"] as! JSON)["sends"] as! [JSON]).isEmpty)
            let before = try f.allState()
            XCTAssertEqual(try f.call("media_round_send_result",input,command:command)["replayed"] as? Bool,true)
            checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
            XCTAssertEqual(try f.allState(),before)
        }
    }

    func testUnlinkedSentChoiceSurvivesAnInterveningSendBeforeWithdrawal() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try link(f,r,ids[0],a);_ = try link(f,r,ids[1],b)
        for id in ids.prefix(2) {try results.decide(f,r,id,"accepted","Original choice")}
        _ = try f.call("media_round_send_result",results.sendInput(f,r))
        let original = try f.record(ids[0],"media_item")["last_decision_id"] as! String
        _ = try link(f,r,ids[0],nil)
        try results.decide(f,r,ids[1],"needs_look","Changed sibling")
        let sibling = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(sibling.count,1);XCTAssertEqual(sibling[0]["task_id"] as? String,b["id"] as? String)
        XCTAssertTrue(strings(try f.get(r)["last_result_sent"] as! JSON,"decision_ids").contains(original))
        let view = try f.get(r),manifest = view["manifest"] as! JSON
        let item = (view["items"] as! [JSON]).first {$0["id"] as? String == ids[0]}!
        var withdrawal = f.observation(view)
        withdrawal["manifest_id"] = manifest["id"];withdrawal["manifest_digest"] = manifest["digest"]
        withdrawal["items"] = [["item_id":ids[0],"expected_revision":item["revision"]!,"decision_id":original]]
        _ = try f.call("media_decision_withdraw",withdrawal)
        let sent = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(sent.count,1);XCTAssertEqual(sent[0]["task_id"] as? String,a["id"] as? String)
        XCTAssertTrue((try f.record(sent[0]["message_id"] as! String,"message")["body"] as! String).hasSuffix("Walk @literal: Pending — decision withdrawn"))
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.results.sendInput(f,r))}
    }

    func testMixedSendReceiptDistinguishesPickupFromQueuedRecipients() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a);_ = try link(f,r,ids[1],b)
        let ob = try results.session(f,"receipt-orchestrator-b");try results.triage(f,b,ob)
        for id in ids.prefix(2) {try results.decide(f,r,id,"needs_look","Review")}
        let sent = try f.call("media_round_send_result",results.sendInput(f,r))
        for send in sent["sends"] as! [JSON] {
            let pickup = send["task_id"] as? String == a["id"] as? String
            XCTAssertEqual(send["delivery_state"] as? String,pickup ? "saved_for_pickup" : "queued")
            XCTAssertEqual((send["recipients"] as! [JSON]).isEmpty,pickup)
            let note = try f.record(send["message_id"] as! String,"message")
            XCTAssertEqual(bool(note,"pickup_pending"),pickup)
        }
    }

    func testMixedManagedOriginalHandoffWaitsForTheLastTicket() throws {
        let f = try Fixture(),(a,r,attachment) = try cleanup.imageRound(f),b = try results.task(f)
        let item = try XCTUnwrap((f.get(r)["items"] as? [JSON])?.first)
        _ = try link(f,r,item["id"] as! String,b)
        let path = f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as! String
        try cleanup.done(f,a)
        XCTAssertEqual(try f.get(r)["state"] as? String,"open")
        XCTAssertNil(try f.record(r["id"] as! String,"media_round")["done_task_cleanup"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        XCTAssertTrue(try f.rows("storage_hold").contains {$0["kind"] as? String == "media_reference" && $0["state"] as? String == "active"})
        try cleanup.done(f,b)
        XCTAssertEqual(try f.get(r)["state"] as? String,"archived")
        XCTAssertTrue(FileManager.default.fileExists(atPath:path),"Handoff itself moves no bytes")
        XCTAssertEqual((try f.record(r["id"] as! String,"media_round")["done_task_cleanup"] as? JSON)?["state"] as? String,"handed_off")
    }

    func testLegacySingleTicketBaselineSurvivesItemOverrideAndRoundRelinking() throws {
        let f = try Fixture(),a = try results.task(f),b = try results.task(f),(r,ids) = try results.fixture(f)
        _ = try results.link(f,r,a)
        for id in ids {try results.decide(f,r,id,"needs_look","Legacy "+id)}
        _ = try f.call("media_round_send_result",results.sendInput(f,r))
        // Recreate the retained CL-427 receipt shape, without changing decisions.
        try f.router.dbQueue.write {db in
            var round = try f.router.record(db,r["id"] as! String,type:"media_round")
            var receipt = round["last_result_sent"] as! JSON
            receipt["sends"] = nil;round["last_result_sent"] = receipt
            try f.router.save(db,f.router.revised(round),type:"media_round")
        }
        _ = try link(f,r,ids[0],b)
        var sent = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(sent.count,1);XCTAssertEqual(sent[0]["task_id"] as? String,b["id"] as? String);XCTAssertEqual(sent[0]["item_count"] as? Int,1)
        _ = try results.link(f,r,b)
        sent = try f.call("media_round_send_result",results.sendInput(f,r))["sends"] as! [JSON]
        XCTAssertEqual(sent.count,1);XCTAssertEqual(sent[0]["item_count"] as? Int,3,"The already sent explicit item is not resent with the fallback changes")
    }

    func testPreparedItemLinkRechecksGateAndDestinationAtWriterCommit() throws {
        let f = try Fixture(),task = try results.task(f),r = try f.round(f.type(checks.schema())),item = try f.item(r)
        let p: JSON = ["project_id":f.project,"command_id":uuid(),"round_id":r["id"]!,"item_id":item["id"]!,"expected_revision":item["revision"]!,"task_id":task["id"]!]
        var resources = PreparedMediaResources();resources.workerChannel = true
        let prepared = try XCTUnwrap(f.router.prepareMediaCommand(method:"media_item_link_task",params:p,caller:f.worker,resources:resources))
        defer {try? prepared.observer.close()}
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        func commit() throws {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {try prepared.commit(db,router:f.router,caller:f.worker);return .commit}
            }
        }
        var before = try f.allState()
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try commit()}
        XCTAssertEqual(try f.allState(),before)
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"allowed")
        try results.purge(f,task)
        before = try f.allState()
        checks.checkError("TICKET_PURGED") {try commit()}
        XCTAssertEqual(try f.allState(),before)
    }
}
