import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

/// CL-422: owned router fixtures only. No live store, app, service or Keychain.
final class MediaDraftContextTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()

    func publication(_ f: Fixture,_ round: JSON,as caller: Caller? = nil) throws -> JSON {
        let view = try f.get(round,as:caller)
        var p = f.observation(view);p["items"] = f.selection(view,publish:true)
        return p
    }
    func editBrief(_ f: Fixture,_ brief: String,as caller: Caller? = nil) throws {
        let project = try f.record(f.project,"project")
        _ = try f.router.handle(method:"project_edit",params:["command_id":uuid(),"project_id":f.project,
            "expected_revision":project["revision"]!,"brief":brief],caller:caller ?? f.owner)
    }
    func successor(_ f: Fixture,_ source: JSON,_ items: [JSON]) throws -> JSON {
        let view = try f.get(source),manifest = view["manifest"] as! JSON
        var p = f.observation(view);p["source_round_id"] = p.removeValue(forKey:"round_id")
        p["manifest_id"] = manifest["id"];p["manifest_digest"] = manifest["digest"]
        p["title"] = "Draft with a carried decision";p["items"] = items
        return try f.call("media_round_successor",p)
    }
    /// Seed the exact pre-fix pending record shape without going through today's automatic
    /// approval hook. This fixture-only write represents retained pre-upgrade attention.
    @discardableResult func legacyAttention(_ f: Fixture,_ r: JSON) throws -> JSON {
        try f.router.dbQueue.write { db in
            var round = try f.router.record(db,r["id"] as! String,type:"media_round")
            let fields: JSON = ["kind":"instruction","instruction_kind":"direction","body":"New approved context",
                "instruction_id":uuid(),"round_id":round["id"]!,"type_id":round["type_id"]!,"item_ids":[String]()]
            var sourceFields = fields;sourceFields["signature"] = try MediaCanonical.signature(fields.filter {$0.key != "instruction_id"})
            let source = f.router.mediaRecord(sourceFields,project:f.project,caller:f.owner,
                references:[try f.router.mediaRef("media_round",round)])
            try f.router.mediaWrite(db,source,type:"media_review_context")
            let attention = f.router.mediaRecord(["round_id":round["id"]!,"source_id":source["id"]!,"state":"pending",
                "proposed_type_revision_id":NSNull()],project:f.project,caller:f.owner,
                references:[try f.router.mediaRef("media_round",round),try f.router.mediaRef("media_review_context",source)])
            try f.router.mediaWrite(db,attention,type:"media_context_attention")
            round["attention_ids"] = strings(round,"attention_ids") + [attention["id"] as! String]
            round["record_references"] = (round["record_references"] as! [JSON]) + [try f.router.mediaRef("media_context_attention",attention)]
            try f.router.mediaWrite(db,f.router.revised(round),type:"media_round")
            return attention
        }
    }
    func assertOwnerReceipt(_ receipt: JSON,_ f: Fixture,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(receipt["action"] as? String,"migrate",file:file,line:line)
        XCTAssertEqual(receipt["origin"] as? String,"human_ui",file:file,line:line)
        XCTAssertEqual(receipt["author"] as? String,f.owner.principal,file:file,line:line)
        XCTAssertEqual(receipt["author_session_id"] as? String,"human",file:file,line:line)
        XCTAssertFalse((receipt["reason"] as? String ?? "").isEmpty,file:file,line:line)
    }

    func testProjectApprovalAdoptsAllThirteenUndecidedDraftItemsAndPublishesAtOnce() throws {
        let f = try Fixture()
        try editBrief(f,"Preexisting project brief")
        let type = try f.type(checks.schema()),round = try f.round(type)
        for i in 0..<13 {_ = try f.item(round,title:"Item \(i)")}
        let original = try f.get(round),before = try f.allState()
        checks.checkError("MEDIA_PROJECT_CONTEXT_REQUIRED") {try f.publish(round)}
        XCTAssertEqual(try f.allState(),before)
        let project = try f.record(f.project,"project")
        let approved = try f.call("media_context_approve",["kind":"project","expected_project_revision":project["revision"]!])
        let ready = try f.get(round)
        XCTAssertTrue(strings(ready,"attention_ids").isEmpty)
        XCTAssertTrue(strings(ready["context"] as! JSON,"source_ids").contains(approved["id"] as! String))
        XCTAssertEqual(f.selection(original,publish:true).map {$0["target_id"] as! String},f.selection(ready,publish:true).map {$0["target_id"] as! String})
        XCTAssertTrue(zip(f.selection(original,publish:true),f.selection(ready,publish:true)).allSatisfy {$0.0["review_basis_signature"] as? String != $0.1["review_basis_signature"] as? String})
        let receipt = try XCTUnwrap(f.rows("media_context_reconciliation").first)
        assertOwnerReceipt(receipt,f)
        XCTAssertTrue((receipt["reason"] as! String).contains("project context"))
        let published = try f.publish(round)
        XCTAssertEqual(published["state"] as? String,"open")
        XCTAssertEqual((published["manifest"] as! JSON)["context_id"] as? String,ready["context_id"] as? String)
        XCTAssertEqual((published["items"] as! [JSON]).count,13)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
    }

    func testProjectApprovalReplayAndChangedIntentDoNotRepeatMigration() throws {
        let f = try Fixture();try editBrief(f,"Approve once")
        let round = try f.round(try f.type(checks.schema()));_ = try f.item(round)
        let project = try f.record(f.project,"project"),input: JSON = ["kind":"project","expected_project_revision":project["revision"]!]
        let command = uuid(),first = try f.call("media_context_approve",input,command:command),before = try f.allState()
        let replay = try f.call("media_context_approve",input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual(replay["id"] as? String,first["id"] as? String)
        var changed = input;changed["expected_project_revision"] = (project["revision"] as! Int) + 1
        checks.checkError("IDEMPOTENCY_CONFLICT") {try f.call("media_context_approve",changed,command:command)}
        XCTAssertEqual(try f.allState(),before)
        XCTAssertEqual(try f.rows("media_context_reconciliation").count,1)
    }

    func testOwnerProjectEditAndScopedInstructionAutomaticallyAdoptDraftContext() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),round = try f.round(type)
        let a = try f.item(round,title:"A"),b = try f.item(round,title:"B")
        try editBrief(f,"Owner edited the approved brief")
        XCTAssertTrue(strings(try f.get(round),"attention_ids").isEmpty)
        let before = try f.get(round)
        _ = try f.call("media_context_approve",["kind":"rubric","round_id":round["id"]!,"item_ids":[a["id"]!],"body":"New rule for A"])
        let after = try f.get(round)
        XCTAssertTrue(strings(after,"attention_ids").isEmpty)
        let old = Dictionary(uniqueKeysWithValues:f.selection(before,publish:true).map {($0["item_id"] as! String,$0["review_basis_signature"] as! String)})
        let new = Dictionary(uniqueKeysWithValues:f.selection(after,publish:true).map {($0["item_id"] as! String,$0["review_basis_signature"] as! String)})
        XCTAssertNotEqual(old[a["id"] as! String],new[a["id"] as! String]);XCTAssertEqual(old[b["id"] as! String],new[b["id"] as! String])
        _ = try f.publish(round)
    }

    func testCarriedDraftDecisionAndOpenRoundStillRequireOwnerChoice() throws {
        let f = try Fixture(),source = try f.round(try f.type(checks.schema())),item = try f.item(source)
        _ = try f.publish(source);try f.acceptEach(source)
        let decision = try f.record(item["id"] as! String,"media_item")["last_decision_id"]!
        let draft = try successor(f,source,[["item_id":item["id"]!,"carry_decision_id":decision]])
        let history = try f.rows("media_owner_decision")
        try editBrief(f,"Approved after the carried decision")
        for round in [source,draft] {
            let view = try f.get(round)
            XCTAssertFalse(strings(view,"attention_ids").isEmpty)
            let before = try f.allState()
            checks.checkError("MEDIA_CONTEXT_ATTENTION") {try f.publish(round)}
            XCTAssertEqual(try f.allState(),before)
        }
        for decision in history {XCTAssertEqual(try jsonString(f.record(decision["id"] as! String,"media_owner_decision")),try jsonString(decision))}
        XCTAssertTrue(try f.rows("media_context_reconciliation").isEmpty)
        _ = try f.reconcile(draft,action:"keep")
        XCTAssertTrue(strings(try f.get(draft),"attention_ids").isEmpty)
    }

    func testScopedUndecidedItemAdoptsBesideCarriedDecisionAndLeavesOtherAttention() throws {
        let f = try Fixture(),source = try f.round(try f.type(checks.schema())),item = try f.item(source)
        _ = try f.publish(source);try f.acceptEach(source)
        let original = try f.record(item["id"] as! String,"media_item")
        let draft = try successor(f,source,[["item_id":item["id"]!,"carry_decision_id":original["last_decision_id"]!]])
        let carried = (draft["items"] as! [JSON])[0],undecided = try f.item(draft,title:"Undecided sibling")
        _ = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"item_ids":[carried["id"]!],"body":"Changes the decided item"])
        let pending = strings(try f.get(draft),"attention_ids")
        XCTAssertEqual(pending.count,1)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"item_ids":[undecided["id"]!],"body":"Only the undecided sibling"])
        XCTAssertEqual(strings(try f.get(draft),"attention_ids"),pending)
        XCTAssertEqual(try f.rows("media_context_reconciliation").count,1)
        let after = try f.get(draft),rows = after["items"] as! [JSON]
        XCTAssertEqual((rows.first {$0["id"] as? String == carried["id"] as? String}?["publication_preview"] as? JSON)?["review_basis_signature"] as? String,
                       (carried["publication_preview"] as! JSON)["review_basis_signature"] as? String)
    }

    func testSupersedingPendingInstructionMigratesWholeChainWithoutRestoringOldScope() throws {
        let f = try Fixture(),source = try f.round(try f.type(checks.schema())),item = try f.item(source)
        _ = try f.publish(source);try f.acceptEach(source)
        let original = try f.record(item["id"] as! String,"media_item")
        let draft = try successor(f,source,[["item_id":item["id"]!,"carry_decision_id":original["last_decision_id"]!]])
        let carried = (draft["items"] as! [JSON])[0],undecided = try f.item(draft,title:"Undecided sibling")
        let old = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"item_ids":[carried["id"]!],"body":"Old pending rule"])
        XCTAssertEqual(strings(try f.get(draft),"attention_ids").count,1)
        let current = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"item_ids":[undecided["id"]!],"body":"Only the undecided sibling","supersedes_id":old["id"]!])
        var view = try f.get(draft)
        XCTAssertTrue(strings(view,"attention_ids").isEmpty)
        XCTAssertEqual(strings(view["context"] as! JSON,"source_ids"),[current["id"] as! String])
        let receipt = try XCTUnwrap(f.rows("media_context_reconciliation").first)
        XCTAssertEqual(strings(receipt,"attention_ids").count,2,"Consume every superseded pending revision together")
        _ = try f.call("media_context_approve",["kind":"rubric","round_id":draft["id"]!,"item_ids":[carried["id"]!],"body":"Independent owner choice"])
        _ = try f.reconcile(draft)
        view = try f.get(draft)
        let sources = strings(view["context"] as! JSON,"source_ids")
        XCTAssertTrue(sources.contains(current["id"] as! String));XCTAssertFalse(sources.contains(old["id"] as! String))
    }

    func testProjectApprovalReversionConsumesWholePendingChain() throws {
        let f = try Fixture();try editBrief(f,"Pinned approved brief")
        let source = try f.round(try f.type(checks.schema())),item = try f.item(source)
        let project = try f.record(f.project,"project")
        let approved = try f.call("media_context_approve",["kind":"project","expected_project_revision":project["revision"]!])
        _ = try f.publish(source);try f.acceptEach(source)
        let original = try f.record(item["id"] as! String,"media_item")
        let draft = try successor(f,source,[["item_id":item["id"]!,"carry_decision_id":original["last_decision_id"]!]])
        let pinSets: [[JSON]] = [[["body":"Temporary global pin"]],[]]
        for pins in pinSets {
            let current = try f.record(f.project,"project")
            _ = try f.router.handle(method:"project_edit",params:["command_id":uuid(),"project_id":f.project,
                "expected_revision":current["revision"]!,"pinned_decisions":pins],caller:f.owner)
            if !pins.isEmpty {XCTAssertEqual(strings(try f.get(draft),"attention_ids").count,1)}
        }
        let view = try f.get(draft)
        XCTAssertTrue(strings(view,"attention_ids").isEmpty)
        let contextID = try XCTUnwrap(strings(view["context"] as! JSON,"source_ids").first)
        let current = try f.record(contextID,"media_review_context")
        XCTAssertEqual(current["signature"] as? String,approved["signature"] as? String)
        let receipt = try XCTUnwrap(f.rows("media_context_reconciliation").last {$0["round_id"] as? String == draft["id"] as? String})
        XCTAssertEqual(strings(receipt,"attention_ids").count,2)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"body":"Independent later change"])
        _ = try f.reconcile(draft)
        let sources = try strings(try f.get(draft)["context"] as! JSON,"source_ids").map {try f.record($0,"media_review_context")}
        XCTAssertEqual(sources.first {$0["kind"] as? String == "project_approval"}?["signature"] as? String,approved["signature"] as? String)
    }

    func testFailedCarryHasNoCurrentDecisionToProtectFromApproval() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),source = try f.round(type),item = try f.item(source)
        _ = try f.publish(source);try f.acceptEach(source)
        let original = try f.record(item["id"] as! String,"media_item")
        _ = try checks.revise(f,type,checks.schema(),rubric:"Changed successor basis");_ = try f.adoptType(type)
        // The Open source keeps its old basis; Keep permits an explicit successor request.
        _ = try f.reconcile(source,action:"keep")
        let draft = try successor(f,source,[["item_id":item["id"]!,"carry_decision_id":original["last_decision_id"]!]])
        let row = try XCTUnwrap((draft["items"] as? [JSON])?.first)
        XCTAssertNil(row["last_decision_id"]);XCTAssertNotNil(row["stale_predecessor_decision_id"])
        let decisions = try f.rows("media_owner_decision").count
        _ = try f.call("media_context_approve",["kind":"direction","round_id":draft["id"]!,"body":"Approved before reviewing the successor"])
        XCTAssertTrue(strings(try f.get(draft),"attention_ids").isEmpty)
        XCTAssertEqual(try f.rows("media_owner_decision").count,decisions)
    }

    func testOwnerPublicationMigratesLegacyAttentionAndKeepsExactDraftLineage() throws {
        let f = try Fixture(),round = try f.round(try f.type(checks.schema()));_ = try f.item(round)
        let attention = try legacyAttention(f,round),input = try publication(f,round)
        let beforeContext = try f.get(round)["context_id"] as! String
        let command = uuid(),published = try f.call("media_round_publish",input,command:command)
        XCTAssertEqual(published["state"] as? String,"open");XCTAssertTrue(strings(published,"attention_ids").isEmpty)
        XCTAssertNotEqual(published["context_id"] as? String,beforeContext)
        let target = ((published["items"] as! [JSON])[0]["published_target"] as! JSON),selected = (input["items"] as! [JSON])[0]
        XCTAssertEqual(target["published_from_target_id"] as? String,selected["target_id"] as? String)
        XCTAssertNotEqual(target["review_basis_signature"] as? String,selected["review_basis_signature"] as? String)
        let receipt = try XCTUnwrap(f.rows("media_context_reconciliation").first);assertOwnerReceipt(receipt,f)
        XCTAssertEqual(strings(receipt,"attention_ids"),[attention["id"] as! String])
        XCTAssertEqual(try f.record(attention["id"] as! String,"media_context_attention")["state"] as? String,"reconciled")
        let before = try f.allState()
        XCTAssertEqual(try f.call("media_round_publish",input,command:command)["replayed"] as? Bool,true)
        XCTAssertEqual(try f.allState(),before)
        _ = try f.call("media_decide",f.decisionParams(published))
    }

    func testWorkerPublicationOfLegacyAttentionRefusesWithoutReconciling() throws {
        let f = try Fixture(),round = try f.round(try f.type(checks.schema()));_ = try f.item(round)
        _ = try legacyAttention(f,round)
        var input = try publication(f,round,as:f.worker);input["project_id"] = f.project;input["command_id"] = uuid()
        let before = try f.allState()
        checks.checkError("MEDIA_CONTEXT_ATTENTION") {try f.router.handle(method:"media_round_publish",params:input,caller:f.worker)}
        XCTAssertEqual(try f.allState(),before);XCTAssertTrue(try f.rows("media_context_reconciliation").isEmpty)
    }

    func testLegacyAttentionDoesNotBypassOriginalBasisTargetOrObservationChecks() throws {
        let f = try Fixture(),round = try f.round(try f.type(checks.schema()));_ = try f.item(round)
        let stale = try publication(f,round);_ = try legacyAttention(f,round)
        let input = try publication(f,round),before = try f.allState()
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_round_publish",stale)}
        for (key,value,code) in [("review_basis_signature","changed","MEDIA_BASIS_CHANGED"),("target_id","changed","REVISION_CONFLICT")] {
            var bad = input,items = input["items"] as! [JSON];items[0][key] = value;bad["items"] = items
            checks.checkError(code) {try f.call("media_round_publish",bad)}
        }
        XCTAssertEqual(try f.allState(),before)
        XCTAssertTrue(try f.rows("media_context_reconciliation").isEmpty)
    }

    func testLegacyAttentionAndIncompleteTargetRefuseWithoutAnyMigration() throws {
        let f = try Fixture(),round = try f.round(try f.type(checks.schema()))
        _ = try f.call("media_item_create",["round_id":round["id"]!,"title":"No capture"])
        _ = try legacyAttention(f,round)
        let input = try publication(f,round),before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_round_publish",input)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testApprovalAndPublicationRollBackAutomaticMigrationWithFailedReceipt() throws {
        let f = try Fixture();try editBrief(f,"Needs approval")
        let round = try f.round(try f.type(checks.schema()));_ = try f.item(round)
        let project = try f.record(f.project,"project"),before = try f.allState()
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TEMP TRIGGER cl422_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned receipt failure');END")}
        XCTAssertThrowsError(try f.call("media_context_approve",["kind":"project","expected_project_revision":project["revision"]!]))
        XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cl422_receipt_failure")}
        _ = try f.call("media_context_approve",["kind":"project","expected_project_revision":project["revision"]!])
        _ = try legacyAttention(f,round)
        let input = try publication(f,round),beforePublication = try f.allState()
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TEMP TRIGGER cl422_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned receipt failure');END")}
        XCTAssertThrowsError(try f.call("media_round_publish",input))
        XCTAssertEqual(try f.allState(),beforePublication)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cl422_receipt_failure")}
        _ = try f.call("media_round_publish",input)
    }

    func testPendingTypeMigrationStillRefusesANewlyIncompleteDraft() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),round = try f.round(type);_ = try f.item(round)
        _ = try checks.revise(f,type,checks.schema(fields:[checks.field("required",required:true)]))
        let head = try f.call("media_type_get",["type_id":type["id"]!],as:f.worker)
        _ = try f.router.handle(method:"media_type_adopt",params:["project_id":f.project,"command_id":uuid(),
            "type_id":type["id"]!,"type_revision_id":head["draft_revision_id"]!,
            "expected_revision":head["revision"]!,"observed_type_token":head["observed_type_token"]!],caller:f.worker)
        let input = try publication(f,round),before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_round_publish",input)}
        XCTAssertEqual(try f.allState(),before,"The migration, new context, manifest and receipt all roll back")
        XCTAssertFalse(strings(try f.get(round),"attention_ids").isEmpty)
    }

    func testOwnerTypeApprovalAdoptsUndecidedDraftButAgentAdoptionLeavesAttention() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),round = try f.round(type);_ = try f.item(round)
        _ = try checks.revise(f,type,checks.schema(),rubric:"Owner adopted rubric")
        let adopted = try f.adoptType(type)
        let ready = try f.get(round)
        XCTAssertTrue(strings(ready,"attention_ids").isEmpty)
        XCTAssertEqual(ready["type_revision_id"] as? String,adopted["adopted_revision_id"] as? String)
        _ = try checks.revise(f,type,checks.schema(),rubric:"Agent adopted rubric")
        let head = try f.call("media_type_get",["type_id":type["id"]!],as:f.worker)
        var input: JSON = ["project_id":f.project,"command_id":uuid(),"type_id":type["id"]!,"expected_revision":head["revision"]!,
            "type_revision_id":head["draft_revision_id"]!,"observed_type_token":head["observed_type_token"]!]
        _ = try f.router.handle(method:"media_type_adopt",params:input,caller:f.worker)
        XCTAssertFalse(strings(try f.get(round),"attention_ids").isEmpty)
        input = try publication(f,round,as:f.worker);input["project_id"] = f.project;input["command_id"] = uuid()
        let before = try f.allState()
        checks.checkError("MEDIA_CONTEXT_ATTENTION") {try f.router.handle(method:"media_round_publish",params:input,caller:f.worker)}
        XCTAssertEqual(try f.allState(),before)
        let published = try f.publish(round)
        XCTAssertTrue(strings(published,"attention_ids").isEmpty)
        XCTAssertEqual(published["state"] as? String,"open")
    }
}
