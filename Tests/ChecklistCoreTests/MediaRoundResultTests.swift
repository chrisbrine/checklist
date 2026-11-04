import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-427 uses owned router fixtures, ordinary queued note receipts and exact replay.
/// No app, relay process, service or live project is accessed.
final class MediaRoundResultTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()

    @discardableResult func call(_ f: Fixture,_ method: String,_ input: JSON = [:],as caller: Caller? = nil) throws -> JSON {
        var p = input;p["project_id"] = p["project_id"] ?? f.project;p["command_id"] = uuid()
        return try f.router.handle(method:method,params:p,caller:caller ?? f.owner)["data"] as! JSON
    }
    func task(_ f: Fixture) throws -> JSON {
        let epic = try XCTUnwrap(f.rows("group").first {$0["kind"] as? String == "epic"})
        return try call(f,"task_create",["title":"Takes owned by this ticket","brief":"Review the exact takes","epic_id":epic["id"]!])
    }
    func link(_ f: Fixture,_ r: JSON,_ task: JSON?) throws -> JSON {
        let v = try f.get(r)
        return try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":v["revision"]!,"task_id":task?["id"] ?? NSNull()])
    }
    func sendInput(_ f: Fixture,_ r: JSON) throws -> JSON {
        let v = try f.get(r);return ["round_id":r["id"]!,"expected_revision":v["revision"]!]
    }
    func decide(_ f: Fixture,_ r: JSON,_ id: String,_ disposition: String,_ note: String) throws {
        var p = f.decisionParams(try f.get(r),ids:[id],disposition:disposition);p["note"] = note
        _ = try f.call("media_decide",p)
    }
    func fixture(_ f: Fixture) throws -> (JSON,[String]) {
        let r = try f.round(f.type(checks.schema()))
        var ids: [String] = []
        for title in ["Walk @literal","Idle","Hit","Defeat"] {ids.append(try f.item(r,title:title)["id"] as! String)}
        _ = try f.publish(r);return (r,ids)
    }
    func session(_ f: Fixture,_ id: String,provider: String = "codex") throws -> Caller {
        let installation = "fixture-\(id)",domain = "fixture-domain-\(id)"
        _ = try call(f,"session_register",["provider":provider,"session_id":id,"installation":installation,"execution_domain":domain,"label":"Display \(id)","workspace":f.workspace.path])
        return Caller(role:"worker",installation:installation,projectIDs:[f.project],sessionID:id,workspace:f.workspace.path,executionDomain:domain)
    }
    func triage(_ f: Fixture,_ t: JSON,_ orchestrator: Caller) throws {
        let group = try call(f,"triage_orchestrate",["action":"start"],as:orchestrator)
        _ = try call(f,"group_membership",["group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":t["id"]!,"action":"add"],as:orchestrator)
    }

    func testCreateLinkClearReadAndWorkerGateWithReplayAndChangedIntent() throws {
        let f = try Fixture(),t = try task(f),type = try f.type(checks.schema())
        let input: JSON = ["type_id":type["id"]!,"title":"Linked pass","task_id":t["id"]!],command = uuid()
        let r = try channel.worker(f,"media_round_create",input,command:command)
        XCTAssertEqual((r["task"] as? JSON)?["id"] as? String,t["id"] as? String)
        XCTAssertEqual((try f.get(r)["task"] as? JSON)?["key"] as? String,t["key"] as? String)
        let ownerHeader = try f.router.executeMediaOwnerChannel(method:"media_round_header",params:["project_id":f.project,"round_id":r["id"]!],caller:f.owner)
        XCTAssertEqual((ownerHeader["task"] as? JSON)?["title"] as? String,t["title"] as? String)
        var changed = input;changed["task_id"] = uuid()
        let before = try f.allState()
        XCTAssertEqual(try channel.worker(f,"media_round_create",input,command:command)["replayed"] as? Bool,true)
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.channel.worker(f,"media_round_create",changed,command:command)}
        XCTAssertEqual(try f.allState(),before)
        let clear: JSON = ["round_id":r["id"]!,"expected_revision":r["revision"]!,"task_id":NSNull()],clearCommand = uuid()
        let cleared = try channel.worker(f,"media_round_link_task",clear,command:clearCommand)
        XCTAssertTrue(cleared["task"] is NSNull)
        XCTAssertEqual(try channel.worker(f,"media_round_get",["round_id":r["id"]!])["task"] as? NSNull,NSNull())
        changed = clear;changed["task_id"] = t["id"]
        let after = try f.allState()
        XCTAssertEqual(try channel.worker(f,"media_round_link_task",clear,command:clearCommand)["replayed"] as? Bool,true)
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.channel.worker(f,"media_round_link_task",changed,command:clearCommand)}
        XCTAssertEqual(try f.allState(),after)
        let linked = try link(f,r,t)
        let summary = try XCTUnwrap(linked["task"] as? JSON)
        XCTAssertEqual(Set(summary.keys),["id","key","title","status_name"])
        XCTAssertFalse((summary["status_name"] as? String ?? "").isEmpty)
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        let gated = try f.allState()
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try self.channel.worker(f,"media_round_create",input)}
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try self.channel.worker(f,"media_round_link_task",["round_id":r["id"]!,"expected_revision":linked["revision"]!,"task_id":NSNull()])}
        XCTAssertEqual(try f.allState(),gated)
    }

    func testLinkRefusesForeignUnknownClosedArchivedAndStaleWithoutWrites() throws {
        let f = try Fixture(),r = try f.round(f.type(checks.schema())),t = try task(f)
        let foreignRoot = f.base.appendingPathComponent("foreign-workspace")
        try FileManager.default.createDirectory(at:foreignRoot,withIntermediateDirectories:true)
        let foreign = try f.router.handle(method:"project_create",params:["command_id":uuid(),"name":"Foreign","key_prefix":"FR","root_path":foreignRoot.path],caller:f.owner)["data"] as! JSON
        let epic = try call(f,"epic_create",["project_id":foreign["id"]!,"name":"Foreign tickets"])
        let other = try call(f,"task_create",["project_id":foreign["id"]!,"title":"Foreign takes","epic_id":epic["id"]!])
        let before = try f.allState()
        for id in [uuid(),other["id"] as! String] {
            checks.checkError("NOT_FOUND") {try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":r["revision"]!,"task_id":id])}
            checks.checkError("NOT_FOUND") {try f.call("media_round_create",["type_id":r["type_id"]!,"title":"Foreign","task_id":id])}
        }
        checks.checkError("NOT_FOUND") {try f.call("media_round_link_task",["round_id":uuid(),"expected_revision":1,"task_id":t["id"]!])}
        checks.checkError("REVISION_CONFLICT") {try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":999,"task_id":t["id"]!])}
        checks.checkError("INVALID_INPUT") {try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":r["revision"]!])}
        XCTAssertEqual(try f.allState(),before)
        let canceled = try f.call("media_round_cancel",["round_id":r["id"]!,"expected_revision":r["revision"]!,"reason":"Retire"])
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":canceled["revision"]!,"task_id":t["id"]!])}
        let archived = try f.call("media_round_archive",["round_id":r["id"]!,"expected_revision":canceled["revision"]!])
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":archived["revision"]!,"task_id":NSNull()])}
        let (complete,_) = try MediaAgentRoundActionTests().published(f,1)
        try f.acceptEach(complete)
        let closed = try f.call("media_round_finish",MediaAgentRoundActionTests().fence(f.get(complete)))
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_round_link_task",["round_id":complete["id"]!,"expected_revision":closed["revision"]!,"task_id":t["id"]!])}
    }

    func testSendQuotesAllDispositionsNotesAndOnlyChangesWithAtomicReplay() throws {
        let f = try Fixture(),t = try task(f),(r,ids) = try fixture(f)
        _ = try link(f,r,t)
        for (id,value) in zip(ids,["accepted","changes_requested","needs_look","excluded"]) {try decide(f,r,id,value,"Owner @literal note: \(value)")}
        let input = try sendInput(f,r),command = uuid(),sent = try f.call("media_round_send_result",input,command:command)
        XCTAssertEqual(sent["item_count"] as? Int,4);XCTAssertEqual(sent["changed_only"] as? Bool,false)
        let message = try f.record(sent["message_id"] as! String,"message"),body = message["body"] as! String
        for label in ["Walk @literal: Accepted","Idle: Changes requested","Hit: Needs look","Defeat: Excluded"] {XCTAssertTrue(body.contains(label))}
        XCTAssertTrue(body.contains("Owner @literal note: accepted"));XCTAssertTrue(body.contains("First pass"))
        XCTAssertEqual(message["origin"] as? String,"human_ui")
        XCTAssertTrue((sent["recipients"] as! [JSON]).isEmpty)
        XCTAssertEqual(message["pickup_pending"] as? Bool,true)
        let receipt = try f.get(r)["last_result_sent"] as! JSON
        XCTAssertEqual(receipt["message_id"] as? String,sent["message_id"] as? String);XCTAssertEqual(strings(receipt,"decision_ids").count,4)
        let before = try f.allState()
        XCTAssertEqual(try f.call("media_round_send_result",input,command:command)["replayed"] as? Bool,true)
        var changed = input;changed["expected_revision"] = 999
        checks.checkError("IDEMPOTENCY_CONFLICT") {try f.call("media_round_send_result",changed,command:command)}
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.sendInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
        try decide(f,r,ids[0],"accepted","Changed note")
        let update = try f.call("media_round_send_result",sendInput(f,r))
        XCTAssertEqual(update["item_count"] as? Int,1);XCTAssertEqual(update["changed_only"] as? Bool,true)
        let updateBody = try f.record(update["message_id"] as! String,"message")["body"] as! String
        XCTAssertTrue(updateBody.contains("Walk @literal: Accepted — Changed note"));XCTAssertFalse(updateBody.contains("Idle:"))
        // A new decision ID with identical disposition/note is not another change.
        try decide(f,r,ids[0],"accepted","Changed note")
        checks.checkError("MEDIA_ROUND_NOTHING_NEW") {try f.call("media_round_send_result",self.sendInput(f,r))}
        try decide(f,r,ids[1],"accepted","Disposition changed")
        let dispositionUpdate = try f.call("media_round_send_result",sendInput(f,r))
        XCTAssertEqual(dispositionUpdate["item_count"] as? Int,1)
        XCTAssertTrue((try f.record(dispositionUpdate["message_id"] as! String,"message")["body"] as! String).contains("Idle: Accepted — Disposition changed"))
        // Relinking sends the complete result to the new ticket.
        _ = try link(f,r,task(f))
        let relinked = try f.call("media_round_send_result",sendInput(f,r))
        XCTAssertEqual(relinked["item_count"] as? Int,4);XCTAssertEqual(relinked["changed_only"] as? Bool,false)
    }

    func testSendRefusalsAndCurrentHolderOrchestratorRecipients() throws {
        let f = try Fixture(),t = try task(f),(r,ids) = try fixture(f)
        var before = try f.allState()
        checks.checkError("MEDIA_ROUND_NO_TASK") {try f.call("media_round_send_result",self.sendInput(f,r))}
        checks.checkError("NOT_FOUND") {try f.call("media_round_send_result",["round_id":uuid(),"expected_revision":1])}
        XCTAssertEqual(try f.allState(),before)
        _ = try link(f,r,t);before = try f.allState()
        checks.checkError("MEDIA_ROUND_NO_DECISIONS") {try f.call("media_round_send_result",self.sendInput(f,r))}
        checks.checkError("REVISION_CONFLICT") {try f.call("media_round_send_result",["round_id":r["id"]!,"expected_revision":999])}
        checks.checkError("FORBIDDEN") {try self.channel.worker(f,"media_round_send_result",self.sendInput(f,r))}
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_round_send_result",self.sendInput(f,r),as:f.worker)}
        XCTAssertEqual(try f.allState(),before)
        let orchestrator = try session(f,"result-orchestrator"),holder = try session(f,"result-holder",provider:"claude")
        try triage(f,t,orchestrator)
        try decide(f,r,ids[0],"needs_look","Inspect cadence")
        let first = try f.call("media_round_send_result",sendInput(f,r))
        XCTAssertEqual((first["recipients"] as! [JSON]).map {$0["session_id"] as! String},[orchestrator.sessionID!])
        let ready = try call(f,"task_edit",["task_id":t["id"]!,"expected_revision":try f.record(t["id"] as! String,"task")["revision"]!,"patch":["readiness":"ready"]])
        _ = try call(f,"work_claim",["task_id":t["id"]!,"expected_revision":ready["revision"]!,"file_scopes":[],"lane_scopes":[]],as:holder)
        try decide(f,r,ids[1],"needs_look","New item")
        let sent = try f.call("media_round_send_result",sendInput(f,r)),recipients = sent["recipients"] as! [JSON]
        XCTAssertEqual(Set(recipients.map {$0["session_id"] as! String}),[orchestrator.sessionID!,holder.sessionID!])
        XCTAssertTrue(recipients.allSatisfy {($0["display"] as? String ?? "").hasPrefix("Display ")})
        let deliveries = try f.rows("delivery").filter {$0["message_id"] as? String == sent["message_id"] as? String}
        XCTAssertEqual(deliveries.count,2);XCTAssertTrue(deliveries.allSatisfy {$0["state"] as? String == "queued"})
    }

    func testStaleDecisionsAreNotSentAndLateJournalFailureRollsBackTheWholeSend() throws {
        let f = try Fixture(),t = try task(f),(r,ids) = try fixture(f)
        _ = try link(f,r,t);try decide(f,r,ids[0],"needs_look","Current decision")
        _ = try f.call("media_context_approve",["kind":"direction","round_id":r["id"]!,"body":"Changes the review basis"])
        _ = try f.reconcile(r)
        let before = try f.allState()
        checks.checkError("MEDIA_ROUND_NO_DECISIONS") {try f.call("media_round_send_result",self.sendInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
        try decide(f,r,ids[0],"needs_look","Fresh decision")
        let input = try sendInput(f,r),fresh = try f.allState()
        try f.router.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER media_result_late_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned late result failure');END")
        }
        XCTAssertThrowsError(try f.call("media_round_send_result",input))
        XCTAssertEqual(try f.allState(),fresh,"The note, outbox, event, baseline and journal share one commit")
    }

    func testChangedSelectedCandidateIsSentEvenWhenDispositionAndNoteMatch() throws {
        let f = try Fixture(),t = try task(f),r = try f.round(f.type(checks.schema()))
        let item = try f.item(r,texts:["Choice A","Choice B"]);_ = try f.publish(r);_ = try link(f,r,t)
        let view = try f.get(r),target = (view["items"] as! [JSON])[0]["published_target"] as! JSON
        let candidates = strings(target,"candidate_ids")
        var input = f.decisionParams(view,ids:[item["id"] as! String]);input["note"] = "Use this take";input["winner_id"] = candidates[0]
        _ = try f.call("media_decide",input);_ = try f.call("media_round_send_result",sendInput(f,r))
        input = f.decisionParams(try f.get(r),ids:[item["id"] as! String]);input["note"] = "Use this take";input["winner_id"] = candidates[1]
        _ = try f.call("media_decide",input)
        let sent = try f.call("media_round_send_result",sendInput(f,r))
        XCTAssertEqual(sent["changed_only"] as? Bool,true);XCTAssertEqual(sent["item_count"] as? Int,1)
    }

    func testPreparedWorkerCreateAndLinkRecheckTheRuleSwitchAtCommit() throws {
        let f = try Fixture(),t = try task(f),type = try f.type(checks.schema()),r = try f.round(type)
        for (method,input) in [
            ("media_round_create",["type_id":type["id"]!,"title":"Prepared","task_id":t["id"]!] as JSON),
            ("media_round_link_task",["round_id":r["id"]!,"expected_revision":r["revision"]!,"task_id":t["id"]!] as JSON)
        ] {
            var p = input;p["project_id"] = f.project;p["command_id"] = uuid()
            var resources = PreparedMediaResources();resources.workerChannel = true
            let prepared = try XCTUnwrap(f.router.prepareMediaCommand(method:method,params:p,caller:f.worker,resources:resources))
            defer {try? prepared.observer.close()}
            try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
            let before = try f.allState()
            checks.checkError("HUMAN_CHANNEL_REQUIRED") {
                try ArchiveStorageGate.withExclusive(root:f.root) {_ in
                    try f.router.dbQueue.writeWithoutTransaction {db in
                        try f.router.withValidatedDomainTransaction(db) {
                            try prepared.commit(db,router:f.router,caller:f.worker);return .commit
                        }
                    }
                }
            }
            XCTAssertEqual(try f.allState(),before)
            try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"allowed")
        }
    }

    func purge(_ f: Fixture,_ t: JSON) throws {
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {
                let current = try f.router.record(db,t["id"] as! String,type:"task")
                let tombstone: JSON = ["id":t["id"]!,"project_id":f.project,"key":t["key"]!,"title":"Purged ticket",
                    "revision":int(current,"revision") + 1,"purged":true,"purged_at":now(),"purged_by":"owned fixture","trashed":true,"archived":true]
                try f.router.save(db,tombstone,type:"task");return .commit
            }
        }
    }

    func testPurgedTicketKeepsHistoryButRefusesNewLinksAndResultNotes() throws {
        let f = try Fixture(),t = try task(f),(r,ids) = try fixture(f)
        _ = try link(f,r,t);try decide(f,r,ids[0],"needs_look","Retained decision")
        try purge(f,t)
        let before = try f.allState()
        checks.checkError("TICKET_PURGED") {try f.call("media_round_send_result",self.sendInput(f,r))}
        checks.checkError("TICKET_PURGED") {try self.link(f,r,t)}
        checks.checkError("TICKET_PURGED") {try f.call("media_round_create",["type_id":r["type_id"]!,"title":"Purged link","task_id":t["id"]!])}
        XCTAssertEqual(try f.allState(),before)
        XCTAssertEqual((try f.get(r)["task"] as? JSON)?["title"] as? String,"Purged ticket")
    }
}
