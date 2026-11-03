import XCTest
import Foundation
import GRDB
import ChecklistContracts
@testable import ChecklistCore

/// CL-420 (owner, 3 November 2026): an agent cancels, archives, finishes and continues a media
/// round, captures rework, restores a retired type and adopts a suggestion through the worker MCP,
/// on the owner's domain path, under the project's agent_rule_changes switch. Media decisions and
/// context approval stay owner only. Also CL-419 review follow-ups: unknown targets, publish of a
/// closed round, a changed intent for each CL-419 command and the retry rule for retire.
final class MediaAgentRoundActionTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()
    let types = MediaAgentTypeChangeTests()
    let zero = String(repeating:"0",count:64)

    func worker(_ f: Fixture,_ method: String,_ input: JSON = [:],command: String? = nil) throws -> JSON {
        try channel.worker(f,method,input,command:command)
    }
    func view(_ f: Fixture,_ round: JSON) throws -> JSON { try worker(f,"media_round_get",["round_id":round["id"]!]) }
    /// The worker's own round and manifest fences from media_round_get.
    func fence(_ v: JSON) -> JSON {
        var p: JSON = ["round_id":v["id"]!,"expected_revision":v["revision"]!,"observed_context_token":v["observed_context_token"]!]
        if let m = v["manifest"] as? JSON,let id = m["id"] { p["manifest_id"] = id;p["manifest_digest"] = m["digest"] }
        return p
    }
    func published(_ f: Fixture,_ count: Int) throws -> (JSON,[String]) {
        let t = try f.type(checks.schema()),r = try f.round(t)
        for index in 0..<count { _ = try f.item(r,title:"Item \(index)",texts:["Exact \(index)\r\n"]) }
        let p = try f.publish(r)
        return (p,(try f.get(p)["items"] as! [JSON]).map {$0["id"] as! String})
    }
    func decide(_ f: Fixture,_ r: JSON,_ id: String,_ disposition: String) throws {
        _ = try f.call("media_decide",f.decisionParams(try f.get(r),ids:[id],disposition:disposition))
    }
    func epic(_ f: Fixture) throws -> String {
        (try f.router.handle(method:"epic_create",params:["command_id":uuid(),"project_id":f.project,"name":"Agent rework"],caller:f.owner)["data"] as! JSON)["id"] as! String
    }
    func assertAgent(_ actor: Any?,_ f: Fixture,file: StaticString = #filePath,line: UInt = #line) {
        let actor = actor as? JSON
        XCTAssertEqual(actor?["actor_kind"] as? String,"agent",file:file,line:line)
        XCTAssertEqual(actor?["origin"] as? String,"agent_mcp",file:file,line:line)
        XCTAssertEqual(actor?["session_id"] as? String,f.worker.sessionID,file:file,line:line)
    }
    /// A retry with the original command_id replays the first result; a changed intent refuses with no writes.
    func assertRetry(_ f: Fixture,_ method: String,_ input: JSON,_ changed: JSON,command: String,first: JSON,file: StaticString = #filePath,line: UInt = #line) throws {
        let before = try f.allState()
        let replay = try worker(f,method,input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true,method,file:file,line:line)
        XCTAssertEqual(replay["id"] as? String,first["id"] as? String,method,file:file,line:line)
        checks.checkError("IDEMPOTENCY_CONFLICT",{try self.worker(f,method,changed,command:command)},file:file,line:line)
        XCTAssertEqual(try f.allState(),before,method,file:file,line:line)
    }
    func changed(_ input: JSON,_ key: String,_ value: Any) -> JSON { var p = input;p[key] = value;return p }

    func testAgentCancelsAndArchivesRoundWithProvenanceAndRetries() throws {
        let f = try Fixture(),round = try f.round(try f.type(checks.schema()))
        _ = try f.item(round)
        let v = try view(f,round),input: JSON = ["round_id":v["id"]!,"expected_revision":v["revision"]!,"reason":"The agent replaces this pass"]
        let command = uuid(),canceled = try worker(f,"media_round_cancel",input,command:command)
        XCTAssertEqual(canceled["state"] as? String,"canceled");XCTAssertNil(canceled["record_references"])
        let stored = try f.record(round["id"] as! String,"media_round")
        assertAgent(stored["canceled_by"],f);XCTAssertEqual(stored["cancellation_reason"] as? String,"The agent replaces this pass")
        try assertRetry(f,"media_round_cancel",input,changed(input,"reason","Other"),command:command,first:canceled)
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.worker(f,"media_round_cancel",self.changed(input,"expected_revision",canceled["revision"]!))}
        let archiveInput: JSON = ["round_id":round["id"]!,"expected_revision":canceled["revision"]!]
        let archiveCommand = uuid(),archived = try worker(f,"media_round_archive",archiveInput,command:archiveCommand)
        XCTAssertEqual(archived["state"] as? String,"archived")
        assertAgent(try f.record(round["id"] as! String,"media_round")["archived_by"],f)
        try assertRetry(f,"media_round_archive",archiveInput,changed(archiveInput,"expected_revision",(canceled["revision"] as! Int) + 5),command:archiveCommand,first:archived)
        let before = try f.allState()
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_round_cancel",["round_id":uuid(),"expected_revision":1,"reason":"Unknown"])}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_round_archive",["round_id":uuid(),"expected_revision":1])}
        XCTAssertEqual(try f.allState(),before)
    }

    func testAgentFinishesRoundRefusesClosedPublishAndCreatesSuccessor() throws {
        let f = try Fixture(),(r,ids) = try published(f,2)
        try decide(f,r,ids[0],"accepted")
        var before = try f.allState()
        checks.checkError("MEDIA_UNRESOLVED") {try self.worker(f,"media_round_finish",self.fence(try self.view(f,r)))}
        XCTAssertEqual(try f.allState(),before)
        try decide(f,r,ids[1],"accepted")
        let open = try view(f,r),input = fence(open),command = uuid()
        let closed = try worker(f,"media_round_finish",input,command:command)
        XCTAssertEqual(closed["state"] as? String,"closed")
        XCTAssertEqual(((closed["closure"] as? JSON)?["counts"] as? JSON)?["accepted"] as? Int,2)
        assertAgent(try f.record(r["id"] as! String,"media_round")["closed_by"],f)
        try assertRetry(f,"media_round_finish",input,changed(input,"manifest_digest",zero),command:command,first:closed)
        // CL-419 review: an agent publication of a closed round refuses with no writes.
        let now = try view(f,r),item = (now["items"] as! [JSON])[0]
        var publish = fence(now);publish["manifest_id"] = nil;publish["manifest_digest"] = nil
        publish["items"] = [["item_id":item["item_id"]!,"expected_revision":item["expected_revision"]!,"target_id":item["target_id"]!,"review_basis_signature":item["review_basis_signature"]!]]
        before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.worker(f,"media_round_publish",publish)}
        XCTAssertEqual(try f.allState(),before)
        // Successor of the closed record, carrying the exact current decision.
        var successor = fence(now);successor["source_round_id"] = successor.removeValue(forKey:"round_id");successor["title"] = "Agent successor"
        successor["items"] = [["item_id":ids[0],"carry_decision_id":try f.record(ids[0],"media_item")["last_decision_id"]!]]
        let successorCommand = uuid(),next = try worker(f,"media_round_successor",successor,command:successorCommand)
        XCTAssertEqual(next["state"] as? String,"draft");XCTAssertEqual(next["predecessor_round_id"] as? String,r["id"] as? String)
        XCTAssertEqual(((next["successor"] as? JSON)?["items"] as? [JSON])?.map {$0["carried"] as? Bool},[true])
        let stored = try f.record(next["id"] as! String,"media_round")
        XCTAssertEqual(stored["origin"] as? String,"agent");XCTAssertEqual(stored["author_session_id"] as? String,f.worker.sessionID)
        try assertRetry(f,"media_round_successor",successor,changed(successor,"title","Other"),command:successorCommand,first:next)
        before = try f.allState()
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_round_successor",self.changed(successor,"source_round_id",uuid()))}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_round_finish",self.changed(input,"round_id",uuid()))}
        XCTAssertEqual(try f.allState(),before)
    }

    func testAgentCapturesReworkFromOwnPreview() throws {
        let f = try Fixture(),(r,ids) = try published(f,2),epicID = try epic(f)
        try decide(f,r,ids[0],"accepted");try decide(f,r,ids[1],"changes_requested")
        let before = try f.allState()
        checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.worker(f,"media_rework_preview",["round_id":r["id"]!,"epic_id":epicID,"items":[["item_id":ids[0]]]])}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_rework_preview",["round_id":uuid(),"epic_id":epicID,"items":[["item_id":ids[1]]]])}
        let preview = try worker(f,"media_rework_preview",["round_id":r["id"]!,"epic_id":epicID,"items":[["item_id":ids[1]]]])
        XCTAssertEqual(try f.allState(),before,"A preview writes nothing")
        XCTAssertEqual((preview["items"] as! [JSON]).map {$0["action"] as? String},["create"])
        var input: JSON = [:]
        for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","epic_id","preview_digest"] { input[key] = preview[key] }
        input["items"] = (preview["items"] as! [JSON]).map {["item_id":$0["item_id"]!,"expected_revision":$0["expected_revision"]!,"decision_id":$0["decision_id"]!]}
        let command = uuid(),created = try worker(f,"media_rework_create",input,command:command)
        let taskIDs = strings(created,"created_task_ids")
        XCTAssertEqual(taskIDs.count,1)
        let link = try XCTUnwrap((created["links"] as? [JSON])?.first)
        XCTAssertEqual(link["origin"] as? String,"agent");XCTAssertEqual(link["author_session_id"] as? String,f.worker.sessionID)
        XCTAssertEqual(try f.record(taskIDs[0],"task")["epic_id"] as? String,epicID)
        let replayBefore = try f.allState()
        let replay = try worker(f,"media_rework_create",input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual(strings(replay,"created_task_ids"),taskIDs)
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.worker(f,"media_rework_create",self.changed(input,"preview_digest","changed"),command:command)}
        XCTAssertEqual(try f.allState(),replayBefore)
    }

    func testAgentAdoptsSuggestionWhileDecisionsAndContextStayOwnerOnly() throws {
        let f = try Fixture(),(r,_) = try published(f,1)
        let v = try view(f,r),row = (v["items"] as! [JSON])[0]
        let suggested = try worker(f,"media_suggest",channel.suggestion(v,row,disposition:"needs_look"))
        let suggestionID = try XCTUnwrap((suggested["decisions"] as? [JSON])?.first?["id"] as? String)
        let current = try view(f,r),item = (current["items"] as! [JSON])[0]
        var input = fence(current);input["suggestion_id"] = suggestionID
        input["items"] = [["item_id":item["item_id"]!,"expected_revision":item["expected_revision"]!,"target_id":item["target_id"]!,"review_basis_signature":item["review_basis_signature"]!]]
        let command = uuid(),adopted = try worker(f,"media_adopt_suggestion",input,command:command)
        let decision = try XCTUnwrap((adopted["decisions"] as? [JSON])?.first)
        XCTAssertEqual(decision["origin"] as? String,"agent");XCTAssertEqual(decision["adopted_suggestion_id"] as? String,suggestionID)
        XCTAssertEqual(decision["disposition"] as? String,"needs_look");assertAgent(decision["adopted_by"],f)
        let before = try f.allState()
        let replay = try worker(f,"media_adopt_suggestion",input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual((replay["decisions"] as? [JSON])?.first?["id"] as? String,decision["id"] as? String)
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.worker(f,"media_adopt_suggestion",self.changed(input,"suggestion_id",uuid()),command:command)}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_adopt_suggestion",self.changed(input,"suggestion_id",uuid()))}
        // The owner's own answers and approvals stay with the trusted app.
        for method in ["media_decide","media_context_approve","media_context_reconcile","media_bulk_prepare","media_bulk_apply"] {
            XCTAssertFalse(MediaWorkerContract.methods.contains(method),method)
            checks.checkError("FORBIDDEN") {try self.worker(f,method,["round_id":r["id"]!])}
        }
        XCTAssertEqual(try f.allState(),before)
    }

    /// Rule (CL-420): a retire or restore retry with its original command_id replays the first
    /// result for owner and agent alike; a new command on an already retired type refuses.
    func testRetireAndRestoreRetryRuleForAgentAndOwner() throws {
        let f = try Fixture(),t = try f.type(checks.schema())
        let retireInput: JSON = ["type_id":t["id"]!,"expected_revision":t["revision"]!]
        let retireCommand = uuid(),retired = try worker(f,"media_type_retire",retireInput,command:retireCommand)
        XCTAssertEqual(retired["state"] as? String,"retired")
        try assertRetry(f,"media_type_retire",retireInput,changed(retireInput,"expected_revision",(t["revision"] as! Int) + 5),command:retireCommand,first:retired)
        checks.checkError("MEDIA_TYPE_RETIRED") {try self.worker(f,"media_type_retire",self.changed(retireInput,"expected_revision",retired["revision"]!))}
        let restoreInput: JSON = ["type_id":t["id"]!,"expected_revision":retired["revision"]!]
        let restoreCommand = uuid(),restored = try worker(f,"media_type_restore",restoreInput,command:restoreCommand)
        XCTAssertEqual(restored["state"] as? String,"adopted");XCTAssertEqual(restored["enabled"] as? Bool,true)
        assertAgent((try f.record(t["id"] as! String,"media_review_type")["restorations"] as? [JSON])?.last,f)
        XCTAssertTrue((try worker(f,"media_type_list")["types"] as! [JSON]).contains {$0["id"] as? String == t["id"] as? String})
        try assertRetry(f,"media_type_restore",restoreInput,changed(restoreInput,"expected_revision",99),command:restoreCommand,first:restored)
        checks.checkError("MEDIA_TYPE_NOT_RETIRED") {try self.worker(f,"media_type_restore",self.changed(restoreInput,"expected_revision",restored["revision"]!))}
        // The owner's domain path follows the same rule.
        let ownerInput: JSON = ["type_id":t["id"]!,"expected_revision":restored["revision"]!]
        let ownerCommand = uuid(),ownerRetired = try f.call("media_type_retire",ownerInput,command:ownerCommand)
        XCTAssertEqual(ownerRetired["state"] as? String,"retired")
        let before = try f.allState()
        let ownerReplay = try f.call("media_type_retire",ownerInput,command:ownerCommand)
        XCTAssertEqual(ownerReplay["replayed"] as? Bool,true);XCTAssertEqual(ownerReplay["revision"] as? Int,ownerRetired["revision"] as? Int)
        XCTAssertEqual(try f.allState(),before)
        checks.checkError("MEDIA_TYPE_RETIRED") {try f.call("media_type_retire",["type_id":t["id"]!,"expected_revision":ownerRetired["revision"]!])}
        let ownerRestored = try f.call("media_type_restore",["type_id":t["id"]!,"expected_revision":ownerRetired["revision"]!])
        XCTAssertEqual(ownerRestored["state"] as? String,"adopted")
        XCTAssertEqual((ownerRestored["restorations"] as? [JSON])?.last?["actor_kind"] as? String,"owner")
        let unknownBefore = try f.allState()
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_type_restore",["type_id":uuid(),"expected_revision":1])}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_type_retire",["type_id":uuid(),"expected_revision":1])}
        XCTAssertEqual(try f.allState(),unknownBefore)
    }

    func testOwnerOnlySwitchRefusesEveryCL420Command() throws {
        let f = try Fixture(),(r,ids) = try published(f,1),t = try f.type(checks.schema(),adopt:false)
        let v = try view(f,r),epicID = try epic(f)
        try types.setAgentRuleChanges(f,"owner_only")
        let before = try f.allState()
        let open = fence(v)
        var successor = open;successor["source_round_id"] = successor.removeValue(forKey:"round_id");successor["title"] = "Next";successor["items"] = [["item_id":ids[0]]]
        let inputs: [String:JSON] = [
            "media_round_cancel":["round_id":r["id"]!,"expected_revision":v["revision"]!,"reason":"Stop"],
            "media_round_archive":["round_id":r["id"]!,"expected_revision":v["revision"]!],
            "media_round_finish":open,
            "media_round_successor":successor,
            "media_rework_create":open.merging(["epic_id":epicID,"preview_digest":"x","items":[["item_id":ids[0],"expected_revision":1,"decision_id":"d"]]]) {$1},
            "media_type_restore":["type_id":t["id"]!,"expected_revision":t["revision"]!],
            "media_adopt_suggestion":open.merging(["suggestion_id":"s","items":[["item_id":ids[0],"expected_revision":1,"target_id":"t","review_basis_signature":zero]]]) {$1},
        ]
        XCTAssertEqual(Set(inputs.keys).union(["media_type_adopt_starter","media_type_create","media_type_revise","media_type_adopt","media_type_retire","media_round_publish"]),MediaWorkerContract.settingMethods)
        for (method,input) in inputs {checks.checkError("HUMAN_CHANNEL_REQUIRED") {try self.worker(f,method,input)}}
        XCTAssertEqual(try f.allState(),before)
    }

    /// CL-419 review follow-ups: a changed intent and an unknown target for each CL-419 command.
    func testCL419CommandsRefuseChangedIntentAndUnknownTargets() throws {
        let f = try Fixture()
        let createInput: JSON = ["title":"Agent type","schema":checks.schema()]
        let createCommand = uuid(),created = try worker(f,"media_type_create",createInput,command:createCommand)
        try assertRetry(f,"media_type_create",createInput,changed(createInput,"title","Other"),command:createCommand,first:created)
        let reviseInput: JSON = ["type_id":created["id"]!,"expected_revision":created["revision"]!,"title":"Agent type v2"]
        let reviseCommand = uuid(),revised = try worker(f,"media_type_revise",reviseInput,command:reviseCommand)
        try assertRetry(f,"media_type_revise",reviseInput,changed(reviseInput,"title","Other"),command:reviseCommand,first:revised)
        let adoptInput: JSON = ["type_id":created["id"]!,"expected_revision":revised["revision"]!,"type_revision_id":revised["draft_revision_id"]!,"observed_type_token":revised["observed_type_token"]!]
        let adoptCommand = uuid(),adopted = try worker(f,"media_type_adopt",adoptInput,command:adoptCommand)
        try assertRetry(f,"media_type_adopt",adoptInput,changed(adoptInput,"observed_type_token","mt1.x"),command:adoptCommand,first:adopted)
        let round = try f.round(adopted)
        _ = try f.item(round)
        let v = try view(f,round),item = (v["items"] as! [JSON])[0],preview = item["publication_preview"] as! JSON
        var publishInput = fence(v)
        publishInput["items"] = [["item_id":item["item_id"]!,"expected_revision":item["expected_revision"]!,"target_id":preview["target_id"]!,"review_basis_signature":preview["review_basis_signature"]!]]
        let publishCommand = uuid(),published = try worker(f,"media_round_publish",publishInput,command:publishCommand)
        try assertRetry(f,"media_round_publish",publishInput,changed(publishInput,"observed_context_token","x"),command:publishCommand,first:published)
        let other = try f.type(checks.schema())
        let retireInput: JSON = ["type_id":other["id"]!,"expected_revision":other["revision"]!]
        let retireCommand = uuid(),retired = try worker(f,"media_type_retire",retireInput,command:retireCommand)
        try assertRetry(f,"media_type_retire",retireInput,changed(retireInput,"expected_revision",99),command:retireCommand,first:retired)
        let before = try f.allState()
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_type_revise",self.changed(reviseInput,"type_id",uuid()))}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_type_adopt",self.changed(adoptInput,"type_id",uuid()))}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_type_retire",self.changed(retireInput,"type_id",uuid()))}
        checks.checkError("NOT_FOUND") {try self.worker(f,"media_round_publish",self.changed(publishInput,"round_id",uuid()))}
        checks.checkError("MEDIA_STARTER_UNKNOWN") {try self.worker(f,"media_type_adopt_starter",["starter":"unknown","expected_revision":try self.types.projectRevision(f)])}
        XCTAssertEqual(try f.allState(),before)
    }
}
