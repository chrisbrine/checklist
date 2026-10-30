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
    let followUp = MediaFollowUpTests()

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
        try QualificationSuite.requireEnabled()
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
        try QualificationSuite.requireEnabled()
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
        // New material and a new publication: every published suggestion names an earlier target.
        // Item detail already calls an unchanged item's advice stale here, so the filter agrees.
        let stale = decisions.row(try f.get(r),ids[0])
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":stale["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Successor take"]]]]])
        let next = try f.publish(r)
        XCTAssertEqual(try listed(f,next,["has_agent_suggestion":true]),[])
        XCTAssertEqual(try followUp.suggestions(f,next,["id":ids[1]]).1[0]["stale"] as? Bool,true)
        XCTAssertEqual((try owner(f,"media_item_page",["round_id":r["id"]!])["rows"] as! [JSON]).first {$0["id"] as? String == ids[0]}?["agent_suggestions"] as? [String],nil)
    }
    // MARK: Finding c87e0e1e: one rule of current advice for detail, filters, list and bulk.

    func entry(_ selection: JSON,_ id: Any?) -> JSON? {(selection["entries"] as! [JSON]).first {$0["item_id"] as? String == id as? String}}
    func pageRow(_ f: Fixture,_ round: JSON,_ id: Any?) throws -> JSON? {(try owner(f,"media_item_page",["round_id":round["id"]!])["rows"] as! [JSON]).first {$0["id"] as? String == id as? String}}
    /// Detail, filters, list badge and bulk entry all give one answer for one item.
    func assertAdvice(_ f: Fixture,_ round: JSON,_ id: Any?,current: Bool,badge: [String]?,line: UInt = #line) throws {
        let sid = id as! String,item: JSON = ["id":sid]
        XCTAssertEqual(try followUp.suggestions(f,round,item).1[0]["stale"] as? Bool,!current,"detail",line:line)
        XCTAssertEqual(try listed(f,round,["has_agent_suggestion":true]).contains(sid),current,"Has agent suggestion",line:line)
        XCTAssertEqual(try listed(f,round,["has_agent_suggestion":false]).contains(sid),!current,"No agent suggestion",line:line)
        XCTAssertEqual(try listed(f,round,["has_note":true]).contains(sid),current,"Has note",line:line)
        XCTAssertEqual(try listed(f,round,["has_note":false]).contains(sid),!current,"No note",line:line)
        XCTAssertEqual(try pageRow(f,round,sid)?["agent_suggestions"] as? [String],badge,"list badge",line:line)
    }
    /// Reviewer case 1: a Draft suggestion, a title-only edit (same basis), then publication.
    func testStaleDraftSuggestionAfterTitleEditIsStaleInFiltersAndBadges() throws {
        let f = try Fixture(),round = try followUp.draftRound(f,items:2)
        let view = try followUp.worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        let titled = items[0],same = items[1]
        for item in items {_ = try followUp.worker(f,"media_suggest",followUp.draftSuggestion(view,item))}
        let record = try f.record(titled["id"] as! String,"media_item")
        let retitled = try f.call("media_item_update",["item_id":titled["id"]!,"expected_revision":record["revision"]!,"title":"New title"])
        XCTAssertEqual((retitled["draft_target"] as! JSON)["review_basis_signature"] as? String,titled["review_basis_signature"] as? String)
        // On the Draft itself the rule already applies, with no manifest.
        try assertAdvice(f,round,titled["id"],current:false,badge:nil)
        try assertAdvice(f,round,same["id"],current:true,badge:["changes_requested"])
        _ = try followUp.ownerPublish(f,round)
        // The reviewer's assertions: neither filter selects it, and Pending/no-Changes keeps it.
        XCTAssertFalse(try listed(f,round,["has_agent_suggestion":true]).contains(titled["id"] as! String))
        XCTAssertFalse(try listed(f,round,["has_note":true]).contains(titled["id"] as! String))
        XCTAssertTrue(try listed(f,round,["dispositions":["pending"],"agent_suggestion_excludes":["changes_requested"]]).contains(titled["id"] as! String))
        try assertAdvice(f,round,titled["id"],current:false,badge:nil)
        XCTAssertNil(entry(try owner(f,"media_bulk_selection",["round_id":round["id"]!]),titled["id"])?["agent_suggestions"])
    }
    /// Reviewer case 2: an unchanged Draft publication keeps advice current through its lineage.
    func testUnchangedDraftPublicationKeepsAdviceInListBulkAndFilters() throws {
        let f = try Fixture(),round = try followUp.draftRound(f,items:2)
        let view = try followUp.worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        let flagged = items[0],clean = items[1]
        _ = try followUp.worker(f,"media_suggest",followUp.draftSuggestion(view,flagged))
        _ = try followUp.ownerPublish(f,round)
        // The reviewer's assertions: the list badge and the bulk entry that drives the warning.
        XCTAssertEqual(try pageRow(f,round,flagged["id"])?["agent_suggestions"] as? [String],["changes_requested"])
        let selection = try owner(f,"media_bulk_selection",["round_id":round["id"]!])
        XCTAssertEqual(entry(selection,flagged["id"])?["agent_suggestions"] as? [String],["changes_requested"])
        XCTAssertNil(entry(selection,clean["id"])?["agent_suggestions"])
        try assertAdvice(f,round,flagged["id"],current:true,badge:["changes_requested"])
        XCTAssertFalse(try listed(f,round,["agent_suggestion_excludes":["changes_requested"]]).contains(flagged["id"] as! String))
        // The bulk decision does not accept for the owner: every item stays Pending until a decision.
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        XCTAssertEqual(entry(selection,flagged["id"])?["disposition"] as? String,"pending")
    }
    /// A lineage counts only for a Draft suggestion: a republished target ends published advice.
    func testPublishedSuggestionDoesNotFollowLineageToALaterPublication() throws {
        let f = try Fixture(),round = try followUp.draftRound(f,items:1)
        _ = try followUp.ownerPublish(f,round)
        let open = try f.get(round),id = ((open["items"] as! [JSON])[0])["id"]
        _ = try suggest(f,open,id as! String,"changes_requested",note:"Arm clips")
        try assertAdvice(f,round,id,current:true,badge:["changes_requested"])
        _ = try followUp.ownerPublish(f,round)
        try assertAdvice(f,round,id,current:false,badge:nil)
    }
    /// The same 250-item action as above with a current suggestion on every item: the filters
    /// read all of them. Records the filter times and the time of the whole action.
    func test250ItemRoundWithCurrentSuggestionsKeepsFilterAndActionTime() throws {
        try QualificationSuite.requireEnabled()
        let (f,r) = try decisions.setup(250),ids = (r["items"] as! [JSON]).map {$0["id"] as! String}
        for part in [Array(ids[0..<200]),Array(ids[200..<249])] {
            var p = decisions.params(f,try f.get(r,as:f.worker),ids:part,disposition:"needs_look");p["note"] = "Check it"
            _ = try f.call("media_suggest",p,as:f.worker)
        }
        _ = try suggest(f,r,ids[249],"changes_requested",note:"Arm clips")
        var filters: [String] = []
        for (name,count,filter) in [("has_suggestion",250,["has_agent_suggestion":true] as JSON),("no_suggestion",0,["has_agent_suggestion":false]),("has_note",250,["has_note":true]),("no_changes",249,["dispositions":["pending"],"agent_suggestion_excludes":["changes_requested"]])] {
            let before = Date()
            let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"filter":filter])
            filters.append(String(format:"%@=%.3f",name,Date().timeIntervalSince(before)))
            XCTAssertEqual((selection["entries"] as! [JSON]).count,count,name)
        }
        let start = Date()
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!,"filter":["dispositions":["pending"],"agent_suggestion_excludes":["changes_requested"]]])
        let selected = Date()
        let operation = try owner(f,"media_bulk_prepare",prepareParams(selection))
        for chunk in operation["chunks"] as! [JSON] {
            _ = try owner(f,"media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunk["id"]!],command:chunk["command_id"] as? String)
        }
        let end = Date()
        XCTAssertEqual(strings(try owner(f,"media_bulk_get",["operation_id":operation["id"]!]),"committed_item_ids").count,249)
        print(String(format:"CL349_TIMING_SUGGESTED items=250 suggestions=250 total_s=%.3f selection_s=%.3f filters=%@ load=%@",end.timeIntervalSince(start),selected.timeIntervalSince(start),filters.joined(separator:","),load()))
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
