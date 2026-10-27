import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-118 owned-store templates: rework links, closure, closed-record rework and successors.
final class MediaReworkTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()

    func setup(_ count: Int) throws -> (Fixture,JSON,JSON,[String]) {
        let f = try Fixture(),t = try f.type(checks.schema()),r = try f.round(t)
        for index in 0..<count { _ = try f.item(r,title:"Item \(index)",texts:["Exact \(index)\r\n"]) }
        let published = try f.publish(r)
        return (f,t,published,(published["items"] as! [JSON]).map {$0["id"] as! String})
    }
    func epic(_ f: Fixture,_ name: String = "Media rework") throws -> String {
        (try f.storage.call("epic_create",["project_id":f.project,"name":name])["data"] as! JSON)["id"] as! String
    }
    @discardableResult func decide(_ f: Fixture,_ r: JSON,_ id: String,_ disposition: String,_ extra: JSON = [:]) throws -> JSON {
        var p = f.decisionParams(try f.get(r),ids:[id],disposition:disposition)
        for (key,value) in extra { p[key] = value }
        return (try f.call("media_decide",p)["decisions"] as! [JSON])[0]
    }
    func preview(_ f: Fixture,_ r: JSON,_ ids: [String],epic: String) throws -> JSON {
        try f.call("media_rework_preview",["round_id":r["id"]!,"epic_id":epic,"items":ids.map {["item_id":$0]}])
    }
    func createInput(_ preview: JSON) -> JSON {
        var p: JSON = [:]
        for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","epic_id","preview_digest"] { p[key] = preview[key] }
        p["items"] = (preview["items"] as! [JSON]).map {["item_id":$0["item_id"]!,"expected_revision":$0["expected_revision"]!,"decision_id":$0["decision_id"]!]}
        return p
    }
    func row(_ r: JSON,_ id: String) -> JSON { (r["items"] as! [JSON]).first {$0["id"] as? String == id}! }
    func finishInput(_ f: Fixture,_ r: JSON) throws -> JSON {
        let current = try f.get(r);var p = f.observation(current);let m = current["manifest"] as! JSON
        p["manifest_id"] = m["id"];p["manifest_digest"] = m["digest"];return p
    }
    func tasks(_ f: Fixture) throws -> [JSON] {try f.rows("task")}
    func category(_ f: Fixture,_ task: JSON) throws -> String? {try f.record(task["status_id"] as! String,"status")["category"] as? String}

    func testOnlySelectedChangesRequestedCreateDraftTicketsAndRetriesReuseExactLinks() throws {
        let (f,_,r,ids) = try setup(5),epicID = try epic(f)
        try decide(f,r,ids[0],"accepted");try decide(f,r,ids[1],"changes_requested",["note":"Tighten the second line"])
        try decide(f,r,ids[2],"changes_requested");try decide(f,r,ids[3],"needs_look")
        // Accepted, Needs look and Pending items never produce rework.
        for id in [ids[0],ids[3],ids[4]] { checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.preview(f,r,[id],epic:epicID)} }
        let groupsBefore = try f.rows("group"),sessionsBefore = try f.rows("session").count
        let acceptedBefore = try jsonString(f.record(ids[0],"media_item")),decisionsBefore = try f.rows("media_owner_decision")
        let shown = try preview(f,r,[ids[1]],epic:epicID)
        XCTAssertEqual((shown["items"] as! [JSON]).map {$0["action"] as? String},["create"])
        XCTAssertEqual(shown["readiness"] as? String,"draft");XCTAssertTrue(shown["assignment"] is NSNull)
        // Worker, stale preview, foreign Epic and an accepted sibling refuse with zero writes.
        let input = createInput(shown),before = try f.allState()
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_rework_create",input,as:f.worker)}
        var stale = input;stale["preview_digest"] = "changed"
        checks.checkError("MEDIA_REWORK_PREVIEW_CHANGED") {try f.call("media_rework_create",stale)}
        var foreign = input;foreign["epic_id"] = uuid()
        XCTAssertThrowsError(try f.call("media_rework_create",foreign))
        var sibling = input;sibling["items"] = [["item_id":ids[0],"expected_revision":row(try f.get(r),ids[0])["revision"]!,"decision_id":row(try f.get(r),ids[0])["last_decision_id"]!]]
        checks.checkError("MEDIA_REWORK_INELIGIBLE") {try f.call("media_rework_create",sibling)}
        XCTAssertEqual(try f.allState(),before)
        let command = uuid()
        let created = try f.call("media_rework_create",input,command:command)
        let taskIDs = strings(created,"created_task_ids");XCTAssertEqual(taskIDs.count,1)
        let task = try f.record(taskIDs[0],"task")
        XCTAssertEqual(task["readiness"] as? String,"draft");XCTAssertEqual(try category(f,task),"queued")
        XCTAssertEqual(task["epic_id"] as? String,epicID);XCTAssertEqual(task["project_id"] as? String,f.project)
        XCTAssertNil(task["planned_assignee"]);XCTAssertEqual(task["origin"] as? String,"human_ui")
        // Published order follows item IDs, so read the exact target title of the selected item.
        XCTAssertEqual(task["title"] as? String,"Rework: " + ((row(try f.get(r),ids[1])["published_target"] as! JSON)["title"] as! String))
        XCTAssertTrue((task["brief"] as? String ?? "").contains("Tighten the second line"))
        // No Triage restoration, session, attempt, review request or media decision.
        XCTAssertEqual(try f.rows("group").filter {$0["kind"] as? String == "triage"}.count,groupsBefore.filter {$0["kind"] as? String == "triage"}.count)
        XCTAssertEqual(try f.rows("session").count,sessionsBefore)
        XCTAssertTrue(try f.rows("work_attempt").isEmpty);XCTAssertTrue(try f.rows("review_request").isEmpty)
        XCTAssertEqual(try jsonString(f.rows("media_owner_decision")),try jsonString(decisionsBefore))
        XCTAssertEqual(try jsonString(f.record(ids[0],"media_item")),acceptedBefore)
        let link = (created["links"] as! [JSON])[0]
        XCTAssertEqual(link["decision_id"] as? String,row(try f.get(r),ids[1])["last_decision_id"] as? String)
        XCTAssertEqual(link["task_id"] as? String,taskIDs[0])
        // Identical command replays; a fresh command for the same decision reuses the exact link.
        let replay = try f.call("media_rework_create",input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual(strings(replay,"created_task_ids"),taskIDs)
        let again = try f.call("media_rework_create",createInput(try preview(f,r,[ids[1]],epic:epicID)))
        XCTAssertEqual(strings(again,"created_task_ids"),[]);XCTAssertEqual(strings(again,"reused_link_ids"),[link["id"] as! String])
        let mixed = try preview(f,r,[ids[1],ids[2]],epic:epicID)
        XCTAssertEqual((mixed["items"] as! [JSON]).map {$0["action"] as? String},["reuse","create"])
        let both = try f.call("media_rework_create",createInput(mixed))
        XCTAssertEqual(strings(both,"created_task_ids").count,1);XCTAssertEqual(strings(both,"reused_link_ids"),[link["id"] as! String])
        XCTAssertEqual(try tasks(f).count,2);XCTAssertEqual(try f.rows("media_rework_link").count,2)
        XCTAssertEqual(try jsonString(f.record(ids[0],"media_item")),acceptedBefore)
        // A changed decision head refuses an old preview; a new decision gets its own link.
        try decide(f,r,ids[1],"changes_requested",["note":"Second request"])
        XCTAssertThrowsError(try f.call("media_rework_create",input))
        let fresh = try f.call("media_rework_create",createInput(try preview(f,r,[ids[1]],epic:epicID)))
        XCTAssertEqual(strings(fresh,"created_task_ids").count,1)
        XCTAssertEqual(try tasks(f).count,3)
    }

    func testClosureRequiresCurrentDispositionsAndLinkOrOwnerNoFollowUpReason() throws {
        let (f,_,r,ids) = try setup(3),epicID = try epic(f)
        checks.checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",try self.finishInput(f,r))}
        try decide(f,r,ids[0],"accepted");try decide(f,r,ids[1],"changes_requested");try decide(f,r,ids[2],"needs_look")
        checks.checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",try self.finishInput(f,r))}
        try decide(f,r,ids[2],"changes_requested")
        _ = try f.call("media_rework_create",createInput(try preview(f,r,[ids[1]],epic:epicID)))
        // Item 2 has neither a link nor a reason; a stale accepted sibling also blocks closure.
        var before = try f.allState()
        checks.checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",try self.finishInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
        _ = try f.call("media_context_approve",["kind":"rubric","round_id":r["id"]!,"item_ids":[ids[0]],"body":"New rule for item 0"])
        _ = try f.reconcile(r)
        XCTAssertEqual(row(try f.get(r),ids[0])["disposition"] as? String,"stale")
        try decide(f,r,ids[2],"changes_requested",["no_follow_up_reason":"Owner keeps this as reference only"])
        checks.checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",try self.finishInput(f,r))}
        try decide(f,r,ids[0],"accepted")
        // A link to a superseded decision no longer resolves the item.
        try decide(f,r,ids[1],"changes_requested",["note":"Reversed and asked again"])
        before = try f.allState()
        checks.checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",try self.finishInput(f,r))}
        XCTAssertEqual(try f.allState(),before)
        _ = try f.call("media_rework_create",createInput(try preview(f,r,[ids[1]],epic:epicID)))
        let closed = try f.call("media_round_finish",try finishInput(f,r))
        XCTAssertEqual(closed["state"] as? String,"closed")
        let closure = closed["closure"] as! JSON,counts = closure["counts"] as! JSON
        XCTAssertEqual(counts["accepted"] as? Int,1);XCTAssertEqual(counts["changes_requested"] as? Int,2)
        XCTAssertEqual(counts["rework_linked"] as? Int,1);XCTAssertEqual(counts["no_follow_up"] as? Int,1)
        XCTAssertEqual(counts["excluded"] as? Int,0)
        let current = try f.rows("media_rework_link").first {$0["decision_id"] as? String == row(try f.get(r),ids[1])["last_decision_id"] as? String}!
        XCTAssertEqual(strings(closure,"rework_link_ids"),[current["id"] as! String])
    }

    func testClosedRecordShowsOpenReworkAndTicketDoneNeverAcceptsMediaOrGate() throws {
        let (f,_,r,ids) = try setup(2),epicID = try epic(f)
        try decide(f,r,ids[0],"accepted");try decide(f,r,ids[1],"changes_requested")
        let created = try f.call("media_rework_create",createInput(try preview(f,r,[ids[1]],epic:epicID)))
        let taskID = strings(created,"created_task_ids")[0]
        _ = try f.call("media_round_finish",try finishInput(f,r))
        let closed = try f.get(r),rework = closed["rework"] as! JSON
        XCTAssertEqual(closed["state"] as? String,"closed")
        XCTAssertEqual((rework["counts"] as! JSON)["open"] as? Int,1)
        XCTAssertEqual(((rework["links"] as! [JSON])[0])["task_open"] as? Bool,true)
        let roundRecord = try f.record(r["id"] as! String,"media_round")
        let header = try f.router.dbQueue.read {try f.router.mediaOwnerHeader($0,roundRecord,f.owner)}
        XCTAssertEqual(((header["rework"] as! JSON)["counts"] as! JSON)["open"] as? Int,1)
        // Ordinary ticket guards still apply: no media decision stands in for a code-review gate.
        var task = try f.record(taskID,"task")
        XCTAssertThrowsError(try f.storage.call("task_complete",["project_id":f.project,"task_id":taskID,"expected_revision":task["revision"]!]))
        checks.checkError("MEDIA_ROUND_CLOSED") {try f.call("media_rework_create",self.createInput(["round_id":r["id"]!,"items":[JSON]()]))}
        let media = try MediaRecordRegistry.families.sorted().map {try jsonString(f.rows($0))}
        // Simulate an ordinary Done ticket through the store's own save boundary.
        let done = try f.rows("status").first {$0["category"] as? String == "done"}!
        task["status_id"] = done["id"];task["revision"] = (task["revision"] as! Int) + 1
        try f.router.dbQueue.writeWithoutTransaction { db in
            try f.router.withValidatedDomainTransaction(db) {try f.router.save(db,task,type:"task");return .commit}
        }
        XCTAssertEqual(try MediaRecordRegistry.families.sorted().map {try jsonString(f.rows($0))},media)
        let after = try f.get(r)
        XCTAssertEqual(row(after,ids[1])["disposition"] as? String,"changes_requested")
        XCTAssertEqual(((after["rework"] as! JSON)["counts"] as! JSON)["closed"] as? Int,1)
        XCTAssertTrue(try f.rows("review_request").isEmpty);XCTAssertTrue(try f.rows("review_verdict").isEmpty)
        var decide = f.decisionParams(after,ids:[ids[1]],disposition:"accepted")
        decide["manifest_id"] = (after["manifest"] as! JSON)["id"]
        checks.checkError("MEDIA_MANIFEST_CHANGED") {try f.call("media_decide",decide)}
    }

    func testSuccessorCarriesOnlyExplicitIdenticalDecisionsAndChangedItemsStartPendingOrStale() throws {
        let (f,t,r,ids) = try setup(3)
        for id in ids { try decide(f,r,id,"accepted") }
        let closed = try f.call("media_round_finish",try finishInput(f,r))
        let source = try f.get(closed),manifest = source["manifest"] as! JSON
        func input(_ items: [JSON],_ s: JSON? = nil) throws -> JSON {
            let s = try s ?? f.get(closed)
            return ["source_round_id":s["id"]!,"expected_revision":s["revision"]!,"observed_context_token":s["observed_context_token"]!,
                    "manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,"title":"Second pass","items":items]
        }
        let heads = ids.map {row(source,$0)["last_decision_id"] as! String}
        let sourceRecord = try jsonString(f.record(r["id"] as! String,"media_round"))
        // Exact refusals: worker, non-head decision, stale observation, foreign item.
        let before = try f.allState()
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_round_successor",try input([["item_id":ids[0]]]),as:f.worker)}
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_round_successor",try input([["item_id":ids[0],"carry_decision_id":heads[1]]]))}
        var stale = try input([["item_id":ids[0]]]);stale["observed_context_token"] = "stale"
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_round_successor",stale)}
        XCTAssertThrowsError(try f.call("media_round_successor",try input([["item_id":uuid()]])))
        XCTAssertEqual(try f.allState(),before)
        let successor = try f.call("media_round_successor",try input([["item_id":ids[0],"carry_decision_id":heads[0]],["item_id":ids[1]]]))
        XCTAssertEqual(successor["state"] as? String,"draft");XCTAssertEqual(successor["predecessor_round_id"] as? String,r["id"] as? String)
        let outcomes = (successor["successor"] as! JSON)["items"] as! [JSON]
        XCTAssertEqual(outcomes.map {$0["carried"] as? Bool},[true,false])
        XCTAssertEqual((successor["items"] as! [JSON]).count,2)
        let published = try f.publish(successor)
        let carried = outcomes[0]["item_id"] as! String,plain = outcomes[1]["item_id"] as! String
        XCTAssertEqual(row(published,carried)["disposition"] as? String,"accepted")
        XCTAssertEqual(row(published,plain)["disposition"] as? String,"pending")
        let decision = try f.record(outcomes[0]["decision_id"] as! String,"media_owner_decision")
        XCTAssertEqual(decision["carried_from_decision_id"] as? String,heads[0]);XCTAssertEqual(decision["origin"] as? String,"human_ui")
        XCTAssertEqual(try jsonString(f.record(r["id"] as! String,"media_round")),sourceRecord)
        // A changed type context: the explicit carry is not applied and the item is Stale.
        _ = try f.call("media_context_approve",["kind":"rubric","type_id":t["id"]!,"body":"New type rule"])
        let decisions = try f.rows("media_owner_decision").count
        let second = try f.call("media_round_successor",try input([["item_id":ids[2],"carry_decision_id":heads[2]]]))
        let outcome = ((second["successor"] as! JSON)["items"] as! [JSON])[0]
        XCTAssertEqual(outcome["carried"] as? Bool,false);XCTAssertEqual(outcome["reason"] as? String,"basis_changed")
        XCTAssertEqual(try f.rows("media_owner_decision").count,decisions)
        let republished = try f.publish(second)
        XCTAssertEqual(row(republished,outcome["item_id"] as! String)["disposition"] as? String,"stale")
        let page = try f.call("media_item_page",["round_id":second["id"]!,"filter":["dispositions":["stale"]]])
        XCTAssertEqual((page["rows"] as! [JSON]).count,1)
        XCTAssertEqual(try jsonString(f.record(r["id"] as! String,"media_round")),sourceRecord)
    }
}
