import XCTest
import Foundation
import GRDB
import ChecklistContracts
@testable import ChecklistCore

/// CL-419 (owner, 3 November 2026): an agent adopts a built-in starter, creates, revises,
/// adopts and retires media types and publishes a round through the worker MCP, under the
/// project's agent_rule_changes switch. Owner decisions and context approval stay owner only.
final class MediaAgentTypeChangeTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()

    func worker(_ f: Fixture,_ method: String,_ input: JSON = [:],as caller: Caller? = nil,command: String? = nil) throws -> JSON {
        try channel.worker(f,method,input,as:caller,command:command)
    }
    func projectRevision(_ f: Fixture) throws -> Int {
        try f.router.dbQueue.read {try XCTUnwrap(f.router.record($0,f.project,type:"project")["revision"] as? Int)}
    }
    func setAgentRuleChanges(_ f: Fixture,_ mode: String) throws {
        try f.router.dbQueue.write { db in
            var project = try f.router.record(db,f.project,type:"project"),policy = project["policy"] as? JSON ?? [:]
            policy["agent_rule_changes"] = mode;project["policy"] = policy;try f.router.save(db,project,type:"project")
        }
    }
    func starter(_ f: Fixture,_ name: String = "Animation takes",command: String? = nil,revision: Int? = nil) throws -> JSON {
        try worker(f,"media_type_adopt_starter",["starter":name,"expected_revision":try revision ?? projectRevision(f)],command:command)
    }

    func testAgentAdoptsStarterThroughOwnerPathWithAgentProvenanceAndReplay() throws {
        let f = try Fixture(),command = uuid()
        let adopted = try starter(f,command:command)
        XCTAssertEqual(adopted["state"] as? String,"adopted");XCTAssertEqual(adopted["enabled"] as? Bool,true)
        XCTAssertEqual(adopted["starter_id"] as? String,"animation_video");XCTAssertEqual(adopted["title"] as? String,"Animation takes")
        XCTAssertNil(adopted["adoptions"]);XCTAssertNil(adopted["record_references"])
        let stored = try f.record(adopted["id"] as! String,"media_review_type")
        XCTAssertEqual(stored["origin"] as? String,"agent");XCTAssertEqual(stored["author_session_id"] as? String,f.worker.sessionID)
        let adoption = try XCTUnwrap((stored["adoptions"] as? [JSON])?.last)
        XCTAssertEqual(adoption["actor_kind"] as? String,"agent");XCTAssertEqual(adoption["origin"] as? String,"agent_mcp")
        XCTAssertEqual(adoption["session_id"] as? String,f.worker.sessionID);XCTAssertEqual(adoption["actor"] as? String,f.worker.principal)
        XCTAssertNil(adoption["owner"]);XCTAssertNotNil(adoption["adopted_at"])
        // The stored definition equals the owner's starter definition, apart from the server-owned type ID.
        let listed = try XCTUnwrap((try worker(f,"media_type_list")["types"] as! [JSON]).first {$0["id"] as? String == adopted["id"] as? String})
        var expected = MediaStarterCatalog.schema(title:"Animation takes",starter:"animation_video");expected["id"] = adopted["id"]
        XCTAssertEqual(listed["schema"] as? NSDictionary,expected as NSDictionary)
        let ownerType = try f.call("media_type_create",["title":"Animation takes copy","schema":MediaStarterCatalog.schema(title:"Animation takes copy",starter:"animation_video")])
        let ownerAdopted = try f.adoptType(ownerType)
        let ownerRevision = try f.record(ownerAdopted["adopted_revision_id"] as! String,"media_review_type_revision")
        var ownerSchema = ownerRevision["schema"] as! JSON,agentSchema = listed["schema"] as! JSON
        for key in ["id","name"] {ownerSchema[key] = nil;agentSchema[key] = nil}
        XCTAssertEqual(ownerSchema as NSDictionary,agentSchema as NSDictionary)
        XCTAssertEqual(ownerRevision["rubric"] as? String,listed["rubric"] as? String)
        // A retry returns the original result; a changed intent with that ID refuses.
        let before = try f.allState()
        let replay = try starter(f,command:command)
        XCTAssertEqual(replay["id"] as? String,adopted["id"] as? String);XCTAssertEqual(replay["replayed"] as? Bool,true)
        checks.checkError("IDEMPOTENCY_CONFLICT") {try starter(f,"Video takes",command:command)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testStarterRefusalsLeaveNoWrites() throws {
        let f = try Fixture()
        let before = try f.allState()
        checks.checkError("MEDIA_STARTER_UNKNOWN") {try starter(f,"animation takes")}
        checks.checkError("MEDIA_STARTER_UNKNOWN") {try starter(f,"Custom")}
        checks.checkError("REVISION_CONFLICT") {try starter(f,revision:try projectRevision(f) + 1)}
        let denied = Caller(role:"worker",installation:f.worker.installation,projectIDs:[],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        checks.checkError("FORBIDDEN") {try worker(f,"media_type_adopt_starter",["starter":"text","expected_revision":try projectRevision(f)],as:denied)}
        XCTAssertEqual(try f.allState(),before)
        let adopted = try starter(f,"text")
        checks.checkError("MEDIA_TYPE_ALREADY_ADOPTED") {try starter(f,"Story text")}
        let retired = try worker(f,"media_type_retire",["type_id":adopted["id"]!,"expected_revision":adopted["revision"]!])
        XCTAssertEqual(retired["state"] as? String,"retired")
        let record = try f.record(adopted["id"] as! String,"media_review_type")
        XCTAssertEqual((record["retired_by"] as? JSON)?["actor_kind"] as? String,"agent")
        checks.checkError("MEDIA_TYPE_RETIRED") {try starter(f,"text")}
        checks.checkError("MEDIA_TYPE_RETIRED") {try worker(f,"media_type_retire",["type_id":adopted["id"]!,"expected_revision":retired["revision"]!])}
        XCTAssertFalse((try worker(f,"media_type_list")["types"] as! [JSON]).contains {$0["id"] as? String == adopted["id"] as? String})
    }

    func testOwnerOnlySwitchRefusesEveryAgentMediaSettingCommand() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),round = try f.round(type)
        _ = try f.item(round)
        try setAgentRuleChanges(f,"owner_only")
        let before = try f.allState()
        let inputs: [String:JSON] = [
            "media_type_adopt_starter":["starter":"text","expected_revision":try projectRevision(f)],
            "media_type_create":["title":"Custom"],
            "media_type_revise":["type_id":type["id"]!,"expected_revision":type["revision"]!,"title":"Renamed"],
            "media_type_adopt":["type_id":type["id"]!,"expected_revision":type["revision"]!,"type_revision_id":type["draft_revision_id"]!,"observed_type_token":"mt1.x"],
            "media_type_retire":["type_id":type["id"]!,"expected_revision":type["revision"]!],
            "media_round_publish":["round_id":round["id"]!,"expected_revision":round["revision"]!,"observed_context_token":"x",
                "items":[["item_id":"i","expected_revision":1,"target_id":"t","review_basis_signature":String(repeating:"0",count:64)]]],
        ]
        // CL-420 adds round, rework, restore and adoption commands; MediaAgentRoundActionTests covers them.
        XCTAssertTrue(Set(inputs.keys).isSubset(of:MediaWorkerContract.settingMethods))
        for (method,input) in inputs {checks.checkError("HUMAN_CHANNEL_REQUIRED") {try worker(f,method,input)}}
        XCTAssertEqual(try f.allState(),before)
        // The owner's own routes are unchanged by the switch.
        try setAgentRuleChanges(f,"allowed")
        XCTAssertEqual(try starter(f,"text")["state"] as? String,"adopted")
    }

    func testAgentCreatesRevisesAndAdoptsCustomTypeLikeOwner() throws {
        let f = try Fixture()
        let created = try worker(f,"media_type_create",["title":"Custom story","schema":checks.schema(),"rubric":"Prefer clear text."])
        XCTAssertEqual(created["state"] as? String,"draft");XCTAssertNotNil(created["observed_type_token"])
        XCTAssertEqual((created["draft_revision"] as? JSON)?["rubric"] as? String,"Prefer clear text.")
        checks.checkError("MEDIA_TYPE_NOT_ADOPTED") {try worker(f,"media_type_get",["type_id":created["id"]!])}
        let adopted = try worker(f,"media_type_adopt",["type_id":created["id"]!,"expected_revision":created["revision"]!,
            "type_revision_id":created["draft_revision_id"]!,"observed_type_token":created["observed_type_token"]!])
        XCTAssertEqual(adopted["state"] as? String,"adopted")
        checks.checkError("REVISION_CONFLICT") {try worker(f,"media_type_revise",["type_id":created["id"]!,"expected_revision":created["revision"]!,"title":"Stale"])}
        let revised = try worker(f,"media_type_revise",["type_id":created["id"]!,"expected_revision":adopted["revision"]!,"title":"Custom story v2"])
        XCTAssertNotEqual(revised["draft_revision_id"] as? String,adopted["adopted_revision_id"] as? String)
        XCTAssertEqual((try worker(f,"media_type_get",["type_id":created["id"]!]))["title"] as? String,"Custom story")
        let readopted = try worker(f,"media_type_adopt",["type_id":created["id"]!,"expected_revision":revised["revision"]!,
            "type_revision_id":revised["draft_revision_id"]!,"observed_type_token":revised["observed_type_token"]!])
        XCTAssertEqual(readopted["title"] as? String,"Custom story v2")
        let record = try f.record(created["id"] as! String,"media_review_type")
        XCTAssertEqual((record["adoptions"] as? [JSON])?.map {$0["actor_kind"] as? String},["agent","agent"])
        let revision = try f.record(revised["draft_revision_id"] as! String,"media_review_type_revision")
        XCTAssertEqual(revision["origin"] as? String,"agent");XCTAssertEqual(revision["author_session_id"] as? String,f.worker.sessionID)
        // The worker channel never accepts owner provenance fields.
        checks.checkError("INVALID_INPUT") {try worker(f,"media_type_create",["title":"Forged","origin":"human_ui"])}
    }

    func testAgentPublishesRoundThroughOwnerChecks() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),round = try f.round(type)
        _ = try f.item(round)
        let view = try worker(f,"media_round_get",["round_id":round["id"]!])
        let item = try XCTUnwrap((view["items"] as? [JSON])?.first),preview = try XCTUnwrap(item["publication_preview"] as? JSON)
        XCTAssertEqual(preview["publication_ready"] as? Bool,true)
        var p: JSON = ["round_id":view["id"]!,"expected_revision":view["revision"]!,"observed_context_token":view["observed_context_token"]!,
            "items":[["item_id":item["item_id"]!,"expected_revision":item["expected_revision"]!,"target_id":preview["target_id"]!,"review_basis_signature":String(repeating:"0",count:64)]]]
        let before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try worker(f,"media_round_publish",p)}
        XCTAssertEqual(try f.allState(),before)
        p["items"] = [["item_id":item["item_id"]!,"expected_revision":item["expected_revision"]!,"target_id":preview["target_id"]!,"review_basis_signature":preview["review_basis_signature"]!]]
        let command = uuid(),published = try worker(f,"media_round_publish",p,command:command)
        XCTAssertEqual(published["state"] as? String,"open");XCTAssertNotNil((published["manifest"] as? JSON)?["digest"])
        let stored = try f.record(round["id"] as! String,"media_round")
        XCTAssertEqual((stored["published_by"] as? JSON)?["actor_kind"] as? String,"agent")
        XCTAssertEqual((stored["published_by"] as? JSON)?["session_id"] as? String,f.worker.sessionID)
        XCTAssertEqual(try worker(f,"media_round_publish",p,command:command)["manifest"] as? NSDictionary,published["manifest"] as? NSDictionary)
        // Decisions stay with the owner.
        checks.checkError("FORBIDDEN") {try worker(f,"media_decide",["round_id":round["id"]!])}
    }

    func testAgentCreatesAndRevisesReviewInDraftWithAllowedRuleChanges() throws {
        let f = try Fixture()
        try setAgentRuleChanges(f,"allowed")
        var schema = checks.schema(),layout = schema["layout"] as! JSON
        layout["review_in_draft"] = true;schema["layout"] = layout
        let created = try worker(f,"media_type_create",["title":"Draft review","schema":schema])
        let first = try XCTUnwrap(created["draft_revision"] as? JSON)
        XCTAssertEqual(((first["schema"] as? JSON)?["layout"] as? JSON)?["review_in_draft"] as? Bool,true)
        let adopted = try worker(f,"media_type_adopt",["type_id":created["id"]!,"expected_revision":created["revision"]!,
            "type_revision_id":created["draft_revision_id"]!,"observed_type_token":created["observed_type_token"]!])
        let read = try worker(f,"media_type_get",["type_id":created["id"]!])
        let listed = try XCTUnwrap((try worker(f,"media_type_list")["types"] as? [JSON])?.first {$0["id"] as? String == created["id"] as? String})
        for view in [read,listed] {
            XCTAssertEqual(((view["schema"] as? JSON)?["layout"] as? JSON)?["review_in_draft"] as? Bool,true)
        }

        schema = first["schema"] as! JSON;layout = schema["layout"] as! JSON
        layout["review_in_draft"] = false;schema["layout"] = layout
        let revised = try worker(f,"media_type_revise",["type_id":created["id"]!,"expected_revision":adopted["revision"]!,"schema":schema])
        let second = try XCTUnwrap(revised["draft_revision"] as? JSON)
        XCTAssertNotEqual(revised["draft_revision_id"] as? String,created["draft_revision_id"] as? String)
        let firstStored = try f.record(created["draft_revision_id"] as! String,"media_review_type_revision")
        let secondStored = try f.record(revised["draft_revision_id"] as! String,"media_review_type_revision")
        XCTAssertNotEqual(secondStored["definition_signature"] as? String,firstStored["definition_signature"] as? String)
        XCTAssertEqual(((second["schema"] as? JSON)?["layout"] as? JSON)?["review_in_draft"] as? Bool,false)
        let readopted = try worker(f,"media_type_adopt",["type_id":created["id"]!,"expected_revision":revised["revision"]!,
            "type_revision_id":revised["draft_revision_id"]!,"observed_type_token":revised["observed_type_token"]!])
        let reread = try worker(f,"media_type_get",["type_id":created["id"]!])
        XCTAssertEqual(((reread["schema"] as? JSON)?["layout"] as? JSON)?["review_in_draft"] as? Bool,false)
        let stored = try f.record(revised["draft_revision_id"] as! String,"media_review_type_revision")
        XCTAssertEqual(((stored["schema"] as? JSON)?["layout"] as? JSON)?["review_in_draft"] as? Bool,false)
        XCTAssertEqual(stored["origin"] as? String,"agent")
        XCTAssertEqual(stored["author_session_id"] as? String,f.worker.sessionID)

        layout["review_in_draft"] = nil;schema["layout"] = layout
        let omitted = try worker(f,"media_type_revise",["type_id":created["id"]!,"expected_revision":readopted["revision"]!,"schema":schema])
        let omittedSchema = (omitted["draft_revision"] as! JSON)["schema"] as! JSON
        XCTAssertNil((omittedSchema["layout"] as! JSON)["review_in_draft"])
        XCTAssertFalse(try MediaReviewSchema.parse(omittedSchema).layout.reviewInDraft)

        let before = try f.allState()
        for invalid in ["true", 1] as [Any] {
            layout["review_in_draft"] = invalid;schema["layout"] = layout
            checks.checkError("INVALID_INPUT") {try worker(f,"media_type_create",["title":"Invalid","schema":schema])}
            checks.checkError("INVALID_INPUT") {try worker(f,"media_type_revise",["type_id":created["id"]!,"expected_revision":omitted["revision"]!,"schema":schema])}
        }
        XCTAssertEqual(try f.allState(),before)
    }
}
