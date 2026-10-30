import ChecklistTestSupport
import XCTest
import Foundation
import Darwin
@testable import ChecklistCore

/// CL-318/CL-349: bulk decisions, adoption and list filters through the owner channel,
/// the route the app uses. Owned template stores and synthetic text items only.
final class MediaBulkOwnerChannelTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let decisions = MediaDecisionTests()
    let checks = MediaRoundTests()

    func owner(_ f: Fixture,_ method: String,_ params: JSON = [:],command: String? = nil) throws -> JSON {
        var p = params;p["project_id"] = f.project
        if !CommandRouter.mediaOwnerReads.contains(method) {p["command_id"] = command ?? uuid()}
        return try f.router.handle(method:method,params:p,caller:f.owner)["data"] as! JSON
    }
    /// The owner's plan from a selection: one take, so the only candidate is the winner.
    func prepareParams(_ selection: JSON,disposition: String = "accepted",ids: Set<String>? = nil) -> JSON {
        var p: JSON = [:]
        for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest"] {p[key] = selection[key]}
        p["disposition"] = disposition
        p["items"] = (selection["entries"] as! [JSON]).filter {ids == nil || ids!.contains($0["item_id"] as! String)}.map { entry -> JSON in
            var value: JSON = [:]
            for key in ["item_id","expected_revision","target_id","review_basis_signature"] {value[key] = entry[key]}
            if disposition == "accepted" {value["winner_id"] = (entry["candidate_ids"] as! [String])[0]}
            return value
        }
        return p
    }
    func suggest(_ f: Fixture,_ r: JSON,_ id: String,_ disposition: String,note: String? = nil) throws -> JSON {
        var p = decisions.params(f,try f.get(r,as:f.worker),ids:[id],disposition:disposition)
        if let note {p["note"] = note}
        return (try f.call("media_suggest",p,as:f.worker)["decisions"] as! [JSON])[0]
    }
    func listed(_ f: Fixture,_ r: JSON,_ filter: JSON) throws -> [String] {
        (try owner(f,"media_item_page",["round_id":r["id"]!,"filter":filter])["rows"] as! [JSON]).map {$0["id"] as! String}
    }
    func load() -> String {
        var values = [Double](repeating:0,count:3)
        getloadavg(&values,3)
        return values.map {String(format:"%.2f",$0)}.joined(separator:" ")
    }

    /// Acceptance CL-349 item 3: more than 200 items in one action, each with its own owner
    /// decision. Records the time of the whole action on the owner channel.
    func test250ItemRoundIsAcceptedInOneActionWithOwnerDecisionPerItem() throws {
        let (f,r) = try decisions.setup(250)
        let start = Date()
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"filter":["dispositions":["pending"],"agent_suggestion_excludes":["changes_requested"]]])
        let selected = Date()
        XCTAssertEqual((selection["entries"] as! [JSON]).count,250)
        let operation = try owner(f,"media_bulk_prepare",prepareParams(selection))
        let prepared = Date()
        let chunks = operation["chunks"] as! [JSON]
        XCTAssertEqual(chunks.map {($0["items"] as! [JSON]).count},[200,50])
        var applied: [TimeInterval] = []
        for chunk in chunks {
            let before = Date()
            let reply = try owner(f,"media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunk["id"]!],command:chunk["command_id"] as? String)
            applied.append(Date().timeIntervalSince(before))
            XCTAssertEqual((reply["chunk"] as! JSON)["state"] as? String,"committed")
        }
        let view = try owner(f,"media_bulk_get",["operation_id":operation["id"]!])
        let end = Date()
        XCTAssertEqual(strings(view,"committed_item_ids").count,250)
        XCTAssertTrue(strings(view,"failed_item_ids").isEmpty);XCTAssertTrue(strings(view,"uncommitted_item_ids").isEmpty)
        print(String(format:"CL349_TIMING items=250 total_s=%.3f selection_s=%.3f prepare_s=%.3f apply_s=%@ load=%@",end.timeIntervalSince(start),selected.timeIntervalSince(start),prepared.timeIntervalSince(selected),applied.map {String(format:"%.3f",$0)}.joined(separator:","),load()))
        let recorded = try f.rows("media_owner_decision")
        XCTAssertEqual(recorded.count,250)
        XCTAssertEqual(Set(recorded.map {$0["item_id"] as! String}).count,250)
        for decision in recorded {
            XCTAssertEqual(decision["origin"] as? String,"human_ui");XCTAssertEqual(decision["author"] as? String,f.owner.principal)
            XCTAssertEqual(decision["disposition"] as? String,"accepted");XCTAssertEqual(decision["bulk_operation_id"] as? String,operation["id"] as? String)
        }
        XCTAssertEqual((try owner(f,"media_item_counts",["round_id":r["id"]!])["counts"] as! [String:Int])["accepted"],250)
    }
    func testFailedChunkRefreshesOnlyFailedItemsAndNeverRepeatsCommittedOnes() throws {
        let (f,r) = try decisions.setup(201)
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!])
        let operation = try owner(f,"media_bulk_prepare",prepareParams(selection)),chunks = operation["chunks"] as! [JSON]
        let changed = (((chunks[1]["items"] as! [JSON]))[0]["item_id"] as! String)
        _ = try owner(f,"media_item_update",["item_id":changed,"expected_revision":decisions.row(try f.get(r),changed)["revision"]!,"title":"New label, same material"])
        XCTAssertEqual((try owner(f,"media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunks[0]["id"]!],command:chunks[0]["command_id"] as? String)["chunk"] as! JSON)["state"] as? String,"committed")
        let failed = try owner(f,"media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunks[1]["id"]!],command:chunks[1]["command_id"] as? String)["chunk"] as! JSON
        XCTAssertEqual(failed["state"] as? String,"failed");XCTAssertEqual((failed["error"] as! JSON)["code"] as? String,"REVISION_CONFLICT")
        let view = try owner(f,"media_bulk_get",["operation_id":operation["id"]!])
        XCTAssertEqual(strings(view,"failed_item_ids"),[changed]);XCTAssertEqual(strings(view,"committed_item_ids").count,200)
        // The app's retry: a selection of exactly the unresolved IDs, on the current observation.
        let current = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"item_ids":[changed]])
        XCTAssertEqual((current["entries"] as! [JSON]).map {$0["item_id"] as! String},[changed])
        var refresh = prepareParams(current);refresh["supersedes_operation_id"] = operation["id"]
        let retry = try owner(f,"media_bulk_prepare",refresh),retryChunk = (retry["chunks"] as! [JSON])[0]
        XCTAssertEqual((try owner(f,"media_bulk_apply",["operation_id":retry["id"]!,"chunk_id":retryChunk["id"]!],command:retryChunk["command_id"] as? String)["chunk"] as! JSON)["state"] as? String,"committed")
        XCTAssertEqual(try f.rows("media_owner_decision").count,201)
        // A lost reply: the same chunk command replays and adds nothing.
        _ = try owner(f,"media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunks[0]["id"]!],command:chunks[0]["command_id"] as? String)
        XCTAssertEqual(try f.rows("media_owner_decision").count,201)
    }
    func testFiltersUseCurrentSuggestionsAndNotes() throws {
        let (f,r) = try decisions.setup(5),ids = (r["items"] as! [JSON]).map {$0["id"] as! String}
        _ = try suggest(f,r,ids[0],"changes_requested",note:"Arm clips")
        _ = try suggest(f,r,ids[1],"accepted")
        var noted = decisions.params(f,try f.get(r),ids:[ids[2]],disposition:"needs_look");noted["note"] = "Check the feet"
        _ = try owner(f,"media_decide",noted)
        XCTAssertEqual(Set(try listed(f,r,["has_agent_suggestion":true])),Set(ids[0...1]))
        XCTAssertEqual(Set(try listed(f,r,["has_agent_suggestion":false])),Set(ids[2...4]))
        XCTAssertEqual(Set(try listed(f,r,["agent_suggestion_excludes":["changes_requested"]])),Set(ids[1...4]))
        XCTAssertEqual(Set(try listed(f,r,["dispositions":["pending"],"agent_suggestion_excludes":["changes_requested"]])),Set([ids[1],ids[3],ids[4]]))
        XCTAssertEqual(Set(try listed(f,r,["has_note":true])),Set([ids[0],ids[2]]))
        XCTAssertEqual(Set(try listed(f,r,["has_note":false])),Set([ids[1],ids[3],ids[4]]))
        XCTAssertEqual(Set(try listed(f,r,["has_note":true,"note_item_ids":[ids[4]]])),Set([ids[0],ids[2],ids[4]]))
        // The same filter selects the same items for a bulk decision.
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"filter":["has_agent_suggestion":true]])
        XCTAssertEqual(Set((selection["entries"] as! [JSON]).map {$0["item_id"] as! String}),Set(ids[0...1]))
        XCTAssertEqual((selection["entries"] as! [JSON]).first {$0["item_id"] as? String == ids[0]}?["agent_suggestions"] as? [String],["changes_requested"])
        let page = try owner(f,"media_item_page",["round_id":r["id"]!])["rows"] as! [JSON]
        XCTAssertEqual(page.first {$0["id"] as? String == ids[0]}?["agent_suggestions"] as? [String],["changes_requested"])
        XCTAssertNil(page.first {$0["id"] as? String == ids[3]}?["agent_suggestions"])
        checks.checkError("INVALID_INPUT") {try owner(f,"media_item_page",["round_id":r["id"]!,"filter":["has_note":"yes"]])}
        checks.checkError("INVALID_INPUT") {try owner(f,"media_item_page",["round_id":r["id"]!,"filter":["agent_suggestion_excludes":["unknown"]]])}
        // New material: the suggestion on the earlier target stops counting as current.
        let stale = decisions.row(try f.get(r),ids[0])
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":stale["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Successor take"]]]]])
        let next = try f.publish(r)
        XCTAssertEqual(Set(try listed(f,next,["has_agent_suggestion":true])),[ids[1]])
        XCTAssertEqual((try owner(f,"media_item_page",["round_id":r["id"]!])["rows"] as! [JSON]).first {$0["id"] as? String == ids[0]}?["agent_suggestions"] as? [String],nil)
    }
    func testOwnerAdoptionKeepsAgentChoiceAsOwnerDecisionAndAgentsHaveNoRoute() throws {
        let (f,r) = try decisions.setup(2,takes:2),ids = (r["items"] as! [JSON]).map {$0["id"] as! String}
        var noneFit = decisions.params(f,try f.get(r,as:f.worker),ids:[ids[0]],disposition:"changes_requested")
        noneFit["none_fit"] = true;noneFit["note"] = "No take meets the brief"
        let suggestion = (try f.call("media_suggest",noneFit,as:f.worker)["decisions"] as! [JSON])[0]
        var adoption = f.decisionParams(try f.get(r),ids:[ids[0]],disposition:"needs_look")
        adoption.removeValue(forKey:"disposition");adoption["suggestion_id"] = suggestion["id"]
        for method in ["media_bulk_selection","media_bulk_prepare","media_bulk_get","media_bulk_apply","media_adopt_suggestion"] {
            checks.checkError("FORBIDDEN") {try f.router.handle(method:method,params:["project_id":f.project,"command_id":uuid(),"round_id":r["id"]!],caller:f.worker)}
        }
        let before = try f.rows("media_owner_decision").count
        XCTAssertEqual(before,0)
        let decision = (try owner(f,"media_adopt_suggestion",adoption)["decisions"] as! [JSON])[0]
        XCTAssertEqual(decision["origin"] as? String,"human_ui");XCTAssertEqual(decision["author"] as? String,f.owner.principal)
        XCTAssertEqual(decision["adopted_suggestion_id"] as? String,suggestion["id"] as? String)
        XCTAssertEqual(decision["disposition"] as? String,"changes_requested");XCTAssertEqual(decision["note"] as? String,"No take meets the brief")
        XCTAssertEqual(decision["selection_outcome"] as? String,"none_fit")
        XCTAssertEqual(try jsonString(f.record(suggestion["id"] as! String,"media_suggestion")),try jsonString(suggestion))
        XCTAssertEqual(decisions.row(try f.get(r),ids[1])["disposition"] as? String,"pending")
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"item_ids":[ids[1]]])
        XCTAssertEqual(((selection["entries"] as! [JSON])[0]["candidate_ids"] as! [String]).count,2)
        let catalog = try jsonString(f.router.handle(method:"tool_catalog",params:[:],caller:f.worker))
        for method in ["media_bulk_","media_adopt_suggestion"] {XCTAssertFalse(catalog.contains(method),method)}
    }
}
