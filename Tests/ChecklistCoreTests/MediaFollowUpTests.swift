import ChecklistContracts
import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-350 worker follow-up and one-press Close; CL-351 worker suggestions on exact Draft targets.
/// Owner and worker calls go through their own channels with the router's real dispatch.
final class MediaFollowUpTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()
    let rework = MediaReworkTests()

    func worker(_ f: Fixture,_ method: String,_ input: JSON = [:],command: String? = nil) throws -> JSON {
        var p = input;p["project_id"] = f.project
        if !MediaWorkerContract.readMethods.contains(method) {p["command_id"] = command ?? uuid()}
        return try f.router.handle(method:method,params:p,caller:f.worker)["data"] as! JSON
    }
    func owner(_ f: Fixture,_ method: String,_ input: JSON = [:]) throws -> JSON {
        var p = input;p["project_id"] = f.project
        if !CommandRouter.mediaOwnerReads.contains(method) {p["command_id"] = uuid()}
        return try f.router.handle(method:method,params:p,caller:f.owner)["data"] as! JSON
    }
    func ticket(_ f: Fixture,_ title: String = "Next production round") throws -> JSON {
        try f.storage.call("task_create",["project_id":f.project,"title":title,"command_id":uuid()])["data"] as! JSON
    }
    func setDone(_ f: Fixture,_ taskID: String) throws {
        var task = try f.record(taskID,"task")
        let done = try f.rows("status").first {$0["category"] as? String == "done"}!
        task["status_id"] = done["id"];task["revision"] = (task["revision"] as! Int) + 1
        try f.router.dbQueue.writeWithoutTransaction { db in
            try f.router.withValidatedDomainTransaction(db) {try f.router.save(db,task,type:"task");return .commit}
        }
    }
    /// The worker's exact observation and its own read of the decision heads.
    func followUp(_ f: Fixture,_ r: JSON,_ ids: [String]) throws -> JSON {
        // A real worker reads pages of at most 100 items.
        var view = try worker(f,"media_round_get",["round_id":r["id"]!]),all = view["items"] as! [JSON]
        while let cursor = view["next_cursor"] as? String {
            view = try worker(f,"media_round_get",["round_id":r["id"]!,"cursor":cursor]);all += view["items"] as! [JSON]
        }
        let manifest = view["manifest"] as! JSON,selected = Set(ids)
        let rows = all.filter {selected.contains($0["id"] as! String)}
        return ["round_id":view["id"]!,"expected_revision":view["revision"]!,"observed_context_token":view["observed_context_token"]!,
            "manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,
            "items":rows.map {["item_id":$0["id"]!,"expected_revision":$0["expected_revision"]!,"decision_id":$0["decision_id"]!]}]
    }
    func header(_ f: Fixture,_ r: JSON) throws -> JSON { try owner(f,"media_round_header",["round_id":r["id"]!]) }
    func close(_ f: Fixture,_ r: JSON) throws -> JSON {
        let current = try header(f,r),m = current["manifest"] as! JSON
        return try owner(f,"media_round_finish",["round_id":current["id"]!,"expected_revision":current["revision"]!,
            "observed_context_token":current["observed_context_token"]!,"manifest_id":m["id"]!,"manifest_digest":m["digest"]!])
    }
    func readiness(_ f: Fixture,_ r: JSON) throws -> JSON { try header(f,r)["closure_readiness"] as! JSON }

    // MARK: CL-350

    func testOneExistingTicketAnswersManyDecisionsAndOnePressClosesWithNeedsLookListed() throws {
        let (f,_,r,ids) = try rework.setup(5)
        try rework.decide(f,r,ids[0],"accepted")
        for id in ids[1...3] { try rework.decide(f,r,id,"changes_requested",["note":"Redo in the next round"]) }
        try rework.decide(f,r,ids[4],"needs_look")
        XCTAssertEqual(try readiness(f,r)["missing_follow_up"] as? Int,3)
        checks.checkError("MEDIA_UNRESOLVED") {try self.close(f,r)}
        let next = try ticket(f),taskID = next["id"] as! String
        let tasksBefore = try f.rows("task").count,decisionsBefore = try f.rows("media_owner_decision")
        let itemsBefore = try ids.map {try jsonString(f.record($0,"media_item"))},roundBefore = try jsonString(f.record(r["id"] as! String,"media_round"))
        var input = try followUp(f,r,Array(ids[1...3]));input["task_id"] = taskID
        let command = uuid(),saved = try worker(f,"media_follow_up_record",input,command:command)
        XCTAssertEqual(strings(saved,"created_link_ids").count,3);XCTAssertEqual(strings(saved,"reused_link_ids").count,0)
        // One ticket, no new ticket, and no owner record, head or round change.
        XCTAssertEqual(try f.rows("task").count,tasksBefore)
        XCTAssertEqual(try jsonString(f.rows("media_owner_decision")),try jsonString(decisionsBefore))
        XCTAssertEqual(try ids.map {try jsonString(f.record($0,"media_item"))},itemsBefore)
        XCTAssertEqual(try jsonString(f.record(r["id"] as! String,"media_round")),roundBefore)
        let links = try f.rows("media_rework_link")
        XCTAssertEqual(links.count,3);XCTAssertEqual(Set(links.map {$0["task_id"] as? String}),[taskID])
        XCTAssertEqual(Set(links.map {$0["origin"] as? String}),["agent"]);XCTAssertEqual(Set(links.map {$0["author_session_id"] as? String}),[f.worker.sessionID])
        // Same intent replays; a fresh identical record reuses every exact link.
        let replay = try worker(f,"media_follow_up_record",input,command:command)
        XCTAssertEqual(strings(replay,"created_link_ids"),strings(saved,"created_link_ids"))
        let again = try worker(f,"media_follow_up_record",input)
        XCTAssertEqual(strings(again,"created_link_ids").count,0);XCTAssertEqual(strings(again,"reused_link_ids").count,3)
        XCTAssertEqual(try f.rows("media_rework_link").count,3)
        // The owner sees one ticket row for three decisions, and Close is ready with Needs look open.
        let shown = try header(f,r)["rework"] as! JSON,tickets = shown["tickets"] as! [JSON]
        XCTAssertEqual(tickets.count,1);XCTAssertEqual(tickets[0]["decision_count"] as? Int,3);XCTAssertEqual(tickets[0]["task_key"] as? String,next["key"] as? String)
        XCTAssertEqual((shown["ticket_counts"] as! JSON)["open"] as? Int,1)
        let ready = try readiness(f,r)
        XCTAssertEqual(ready["missing_follow_up"] as? Int,0);XCTAssertEqual(ready["pending"] as? Int,0);XCTAssertEqual(ready["needs_look"] as? Int,1)
        // One owner command closes the round.
        let closed = try close(f,r),closure = closed["closure"] as! JSON,counts = closure["counts"] as! JSON
        XCTAssertEqual(closed["state"] as? String,"closed")
        XCTAssertEqual(counts["changes_requested"] as? Int,3);XCTAssertEqual(counts["rework_linked"] as? Int,3)
        XCTAssertEqual(counts["needs_look"] as? Int,1);XCTAssertEqual(counts["accepted"] as? Int,1)
        XCTAssertEqual(strings(closure,"needs_look_item_ids"),[ids[4]]);XCTAssertEqual(strings(closure,"rework_link_ids").count,3)
        // After Close the worker still reads the Needs look item and each follow-up.
        let view = try worker(f,"media_round_get",["round_id":r["id"]!]),rows = view["items"] as! [JSON]
        XCTAssertEqual(strings(view["closure"] as! JSON,"needs_look_item_ids"),[ids[4]])
        let look = rows.first {$0["id"] as? String == ids[4]}!
        XCTAssertEqual(look["disposition"] as? String,"needs_look");XCTAssertNil(look["follow_up"])
        let changed = rows.first {$0["id"] as? String == ids[1]}!,row = changed["follow_up"] as! JSON
        XCTAssertEqual(row["kind"] as? String,"ticket");XCTAssertEqual(row["task_id"] as? String,taskID)
        XCTAssertNil(row["author"]);XCTAssertNil(row["author_session_id"])
        // A later Done ticket changes neither the closed record nor a decision.
        let record = try jsonString(f.record(r["id"] as! String,"media_round"))
        try setDone(f,taskID)
        XCTAssertEqual(try jsonString(f.record(r["id"] as! String,"media_round")),record)
    }

    func testWorkerReasonIsShownToOwnerAndCountedApartFromOwnerNoFollowUpReason() throws {
        let (f,_,r,ids) = try rework.setup(3)
        try rework.decide(f,r,ids[0],"changes_requested");try rework.decide(f,r,ids[1],"changes_requested")
        try rework.decide(f,r,ids[2],"changes_requested",["no_follow_up_reason":"Owner keeps this as reference only"])
        XCTAssertEqual(try readiness(f,r)["missing_follow_up"] as? Int,2)
        let reason = "Redo work goes to the next PixelLab production round."
        var input = try followUp(f,r,Array(ids[0...1]));input["reason"] = reason
        _ = try worker(f,"media_follow_up_record",input)
        let links = try f.rows("media_rework_link")
        XCTAssertEqual(links.count,2);XCTAssertTrue(links.allSatisfy {$0["task_id"] == nil && $0["follow_up_reason"] as? String == reason && $0["origin"] as? String == "agent"})
        // The worker reason never enters the owner's decision.
        for id in ids[0...1] { XCTAssertNil(try f.record(try f.record(id,"media_item")["last_decision_id"] as! String,"media_owner_decision")["no_follow_up_reason"]) }
        let shown = try header(f,r)["rework"] as! JSON,reasons = shown["worker_reasons"] as! [JSON]
        XCTAssertEqual(reasons.count,1);XCTAssertEqual(reasons[0]["reason"] as? String,reason);XCTAssertEqual(reasons[0]["decision_count"] as? Int,2)
        XCTAssertEqual(reasons[0]["origin"] as? String,"agent");XCTAssertFalse((reasons[0]["source_label"] as? String ?? "").isEmpty)
        XCTAssertEqual(Set(strings(reasons[0],"item_ids")),Set(ids[0...1]))
        XCTAssertTrue((shown["links"] as! [JSON]).isEmpty);XCTAssertTrue((shown["tickets"] as! [JSON]).isEmpty)
        let item = try owner(f,"media_item_get",["round_id":r["id"]!,"item_id":ids[0]])
        XCTAssertEqual((item["follow_up"] as! JSON)["reason"] as? String,reason);XCTAssertEqual((item["follow_up"] as! JSON)["kind"] as? String,"worker_reason")
        XCTAssertEqual(try readiness(f,r)["missing_follow_up"] as? Int,0)
        // An owner ticket for the same decision is still possible; the worker reason is not a ticket.
        let epicID = try rework.epic(f),shownRework = try rework.preview(f,r,[ids[0]],epic:epicID)
        XCTAssertEqual((shownRework["items"] as! [JSON]).map {$0["action"] as? String},["create"])
        let closed = try close(f,r),closure = closed["closure"] as! JSON,counts = closure["counts"] as! JSON
        XCTAssertEqual(counts["worker_reason"] as? Int,2);XCTAssertEqual(counts["no_follow_up"] as? Int,1);XCTAssertEqual(counts["rework_linked"] as? Int,0)
        XCTAssertEqual(strings(closure,"worker_reason_link_ids").count,2)
        XCTAssertEqual(try f.rows("task").count,0)
    }

    func testOwnerAndWorkerChannelsStayDistinctAndEveryRefusalWritesNothing() throws {
        let (f,_,r,ids) = try rework.setup(4)
        try rework.decide(f,r,ids[0],"changes_requested");try rework.decide(f,r,ids[1],"accepted");try rework.decide(f,r,ids[2],"needs_look")
        let next = try ticket(f),taskID = next["id"] as! String
        var good = try followUp(f,r,[ids[0]]);good["task_id"] = taskID
        // The owner has no follow-up route and the worker has no Close route.
        XCTAssertFalse(CommandRouter.mediaOwnerMethods.contains("media_follow_up_record"))
        XCTAssertTrue(CommandRouter.mediaWorkerMethods.contains("media_follow_up_record"))
        let before = try f.allState()
        XCTAssertThrowsError(try owner(f,"media_follow_up_record",good))
        checks.checkError("FORBIDDEN") {try f.call("media_follow_up_record",good,as:f.owner)}
        checks.checkError("FORBIDDEN") {try self.worker(f,"media_round_finish",try self.rework.finishInput(f,r))}
        checks.checkError("FORBIDDEN") {try self.worker(f,"media_decide",good)}
        // A caller cannot supply provenance or both follow-up kinds.
        var forged = good;forged["origin"] = "human_ui"
        XCTAssertThrowsError(try worker(f,"media_follow_up_record",forged))
        var both = good;both["reason"] = "Also a reason"
        XCTAssertThrowsError(try worker(f,"media_follow_up_record",both))
        var neither = good;neither.removeValue(forKey:"task_id")
        XCTAssertThrowsError(try worker(f,"media_follow_up_record",neither))
        var blank = neither;blank["reason"] = "   "
        XCTAssertThrowsError(try worker(f,"media_follow_up_record",blank))
        // Only a current Changes requested owner decision is eligible.
        for id in [ids[1],ids[2]] {
            var other = try followUp(f,r,[id]);other["task_id"] = taskID
            checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.worker(f,"media_follow_up_record",other)}
        }
        // Only an open ticket of this project is eligible.
        var elsewhere = good;elsewhere["task_id"] = uuid()
        XCTAssertThrowsError(try worker(f,"media_follow_up_record",elsewhere))
        XCTAssertEqual(try f.allState(),before)
        let finished = try ticket(f,"Finished ticket");try setDone(f,finished["id"] as! String)
        var done = good;done["task_id"] = finished["id"]
        checks.checkError("MEDIA_FOLLOW_UP_INELIGIBLE") {try self.worker(f,"media_follow_up_record",done)}
        XCTAssertEqual(try f.rows("media_rework_link").count,0)
        // One selection commits or refuses as a whole, and a decision keeps its one follow-up.
        _ = try worker(f,"media_follow_up_record",good)
        let links = try f.rows("media_rework_link")
        var changed = try followUp(f,r,[ids[0]]);changed["reason"] = "Another answer"
        checks.checkError("MEDIA_FOLLOW_UP_EXISTS") {try self.worker(f,"media_follow_up_record",changed)}
        XCTAssertEqual(try jsonString(f.rows("media_rework_link")),try jsonString(links))
    }

    func testReversedDecisionNeedsItsOwnFollowUpAndPendingOrStaleStillBlockClose() throws {
        let (f,_,r,ids) = try rework.setup(3)
        try rework.decide(f,r,ids[0],"changes_requested");try rework.decide(f,r,ids[1],"accepted")
        var input = try followUp(f,r,[ids[0]]);input["reason"] = "Next round"
        let stale = input
        _ = try worker(f,"media_follow_up_record",input)
        // Pending blocks with the follow-up in place.
        XCTAssertEqual(try readiness(f,r)["pending"] as? Int,1)
        checks.checkError("MEDIA_UNRESOLVED") {try self.close(f,r)}
        try rework.decide(f,r,ids[2],"needs_look")
        // An owner reversal needs its own follow-up; the earlier reason is not listed as current.
        try rework.decide(f,r,ids[0],"changes_requested",["note":"Asked again"])
        XCTAssertEqual(try readiness(f,r)["missing_follow_up"] as? Int,1)
        XCTAssertTrue(((try header(f,r)["rework"] as! JSON)["worker_reasons"] as! [JSON]).isEmpty)
        checks.checkError("MEDIA_UNRESOLVED") {try self.close(f,r)}
        checks.checkError("REVISION_CONFLICT") {try self.worker(f,"media_follow_up_record",stale)}
        var current = try followUp(f,r,[ids[0]]);current["reason"] = "Next round again"
        // The current item revision with the superseded decision ID also refuses.
        var superseded = current;var old = (stale["items"] as! [JSON])[0];old["expected_revision"] = (current["items"] as! [JSON])[0]["expected_revision"];superseded["items"] = [old]
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.worker(f,"media_follow_up_record",superseded)}
        _ = try worker(f,"media_follow_up_record",current)
        // A Stale sibling still blocks Close, with its own readiness count.
        _ = try f.call("media_context_approve",["kind":"rubric","round_id":r["id"]!,"item_ids":[ids[1]],"body":"New rule for item 1"])
        _ = try f.reconcile(r)
        XCTAssertEqual(try readiness(f,r)["stale"] as? Int,1)
        checks.checkError("MEDIA_UNRESOLVED") {try self.close(f,r)}
        try rework.decide(f,r,ids[1],"accepted")
        XCTAssertEqual(try close(f,r)["state"] as? String,"closed")
        // A closed record takes no further follow-up.
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.worker(f,"media_follow_up_record",current)}
    }

    /// Heir's round 2 had 242 items. Times are recorded, not asserted, because the host load varies.
    func testFollowUpAndCloseAt242DecisionsStayExactAndRecordTheirTimes() throws {
        let (f,_,r,ids) = try rework.setup(242)
        var timed: [(String,Double)] = []
        func clock<T>(_ name: String,_ body: () throws -> T) rethrows -> T {
            let start = Date();defer {timed.append((name,Date().timeIntervalSince(start)))}
            return try body()
        }
        for start in stride(from:0,to:ids.count,by:200) {
            let chunk = Array(ids[start..<min(start + 200,ids.count)])
            _ = try f.call("media_decide",f.decisionParams(try f.get(r),ids:chunk,disposition:"changes_requested"))
        }
        XCTAssertEqual(try clock("header missing 242") {try readiness(f,r)}["missing_follow_up"] as? Int,242)
        let reason = "Redo work goes to the next PixelLab production round."
        for start in stride(from:0,to:ids.count,by:200) {
            var input = try followUp(f,r,Array(ids[start..<min(start + 200,ids.count)]));input["reason"] = reason
            _ = try clock("follow-up \(min(200,ids.count - start))") {try worker(f,"media_follow_up_record",input)}
        }
        XCTAssertEqual(try clock("header missing 0") {try readiness(f,r)}["missing_follow_up"] as? Int,0)
        let shown = (try header(f,r)["rework"] as! JSON)["worker_reasons"] as! [JSON]
        XCTAssertEqual(shown.count,1);XCTAssertEqual(shown[0]["decision_count"] as? Int,242)
        let closed = try clock("close 242") {try close(f,r)}
        XCTAssertEqual(((closed["closure"] as! JSON)["counts"] as! JSON)["worker_reason"] as? Int,242)
        try assertWholeStoreValidates(f)
        for (name,seconds) in timed { print("P350-TIMING \(name): \(String(format:"%.3f",seconds)) s") }
    }

    /// Every stored media record, including a follow-up with no ticket and a Draft suggestion
    /// with no manifest, passes the registry check that export and backup share.
    func assertWholeStoreValidates(_ f: Fixture,file: StaticString = #filePath,line: UInt = #line) throws {
        let envelopes = try f.router.dbQueue.read {try MediaRecordRegistry.envelopes($0,project:f.project)}
        XCTAssertNoThrow(try MediaRecordRegistry.validate(envelopes),file:file,line:line)
    }

    func testDraftSuggestionAndWorkerReasonRecordsPassTheRegistryCheck() throws {
        let f = try Fixture(),round = try draftRound(f)
        let view = try worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        _ = try worker(f,"media_suggest",draftSuggestion(view,items[0]))
        try assertWholeStoreValidates(f)
        _ = try ownerPublish(f,round)
        let open = try f.get(round)
        _ = try f.call("media_decide",f.decisionParams(open,ids:[items[0]["id"] as! String],disposition:"changes_requested"))
        var input = try followUp(f,round,[items[0]["id"] as! String]);input["reason"] = "Next production round"
        _ = try worker(f,"media_follow_up_record",input)
        try assertWholeStoreValidates(f)
    }

    // MARK: CL-351

    func draftRound(_ f: Fixture,items: Int = 2) throws -> JSON {
        let type = try f.type(checks.schema()),round = try worker(f,"media_round_create",["type_id":type["id"]!,"title":"Worker Draft"])
        for index in 0..<items { _ = try f.item(round,title:"Item \(index)",texts:["take \(index)"],as:f.worker) }
        return round
    }
    func draftSuggestion(_ view: JSON,_ item: JSON,disposition: String = "changes_requested",note: String = "Flagged before publication") -> JSON {
        var p: JSON = ["round_id":view["id"]!,"expected_revision":view["revision"]!,"observed_context_token":view["observed_context_token"]!,
            "disposition":disposition,"note":note,
            "items":[["item_id":item["id"]!,"expected_revision":item["expected_revision"]!,"target_id":item["target_id"]!,"review_basis_signature":item["review_basis_signature"]!]]]
        if disposition == "accepted" {p["winner_id"] = strings(item,"candidate_ids")[0]}
        return p
    }
    func ownerPublish(_ f: Fixture,_ round: JSON) throws -> JSON {
        let preview = try owner(f,"media_publication_preview",["round_id":round["id"]!])
        var p = f.observation(preview["round"] as! JSON)
        p["items"] = (preview["items"] as! [JSON]).map {row in row.filter {["item_id","expected_revision","target_id","review_basis_signature"].contains($0.key)}}
        return try owner(f,"media_round_publish",p)
    }
    func suggestions(_ f: Fixture,_ round: JSON,_ item: JSON) throws -> (JSON,[JSON]) {
        let detail = try owner(f,"media_item_get",["round_id":round["id"]!,"item_id":item["id"]!])
        return (detail,detail["suggestions"] as! [JSON])
    }

    func testDraftSuggestionShowsBesideItemAtPublicationWithNoFurtherWorkerCall() throws {
        let f = try Fixture(),round = try draftRound(f)
        let view = try worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        XCTAssertEqual(view["state"] as? String,"draft")
        let flagged = items[0],accepted = items[1]
        let before = try f.record(flagged["id"] as! String,"media_item")
        let first = (try worker(f,"media_suggest",draftSuggestion(view,flagged))["decisions"] as! [JSON])[0]
        let second = (try worker(f,"media_suggest",draftSuggestion(view,accepted,disposition:"accepted",note:"Good take"))["decisions"] as! [JSON])[0]
        XCTAssertEqual(first["target_phase"] as? String,"draft");XCTAssertNil(first["manifest_id"]);XCTAssertNil(first["manifest_digest"])
        XCTAssertEqual(first["origin"] as? String,"agent");XCTAssertEqual(first["author_session_id"] as? String,f.worker.sessionID)
        // A suggestion moves no head, no item revision and no round state.
        XCTAssertEqual(try jsonString(f.record(flagged["id"] as! String,"media_item")),try jsonString(before))
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        let published = try ownerPublish(f,round)
        XCTAssertEqual(published["state"] as? String,"open")
        let (detail,shown) = try suggestions(f,round,flagged)
        XCTAssertEqual(shown.map {$0["id"] as? String},[first["id"] as? String])
        XCTAssertEqual(shown[0]["stale"] as? Bool,false);XCTAssertEqual(shown[0]["note"] as? String,"Flagged before publication")
        XCTAssertEqual(shown[0]["origin"] as? String,"agent");XCTAssertFalse((shown[0]["source_label"] as? String ?? "").isEmpty)
        // Publication writes a new target. The Draft suggestion is current through its exact lineage.
        let target = detail["target"] as! JSON
        XCTAssertNotEqual(target["id"] as? String,first["target_id"] as? String)
        XCTAssertEqual(target["published_from_target_id"] as? String,first["target_id"] as? String)
        XCTAssertEqual(detail["disposition"] as? String,"pending");XCTAssertNil(detail["decision"])
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        // The Draft suggestion can be adopted by the owner like a published one.
        let current = try f.get(round),row = current["items"] as! [JSON]
        let exact = row.first {$0["id"] as? String == accepted["id"] as? String}!,exactTarget = exact["published_target"] as! JSON
        var adopt = f.observation(current);let m = current["manifest"] as! JSON
        adopt["manifest_id"] = m["id"];adopt["manifest_digest"] = m["digest"];adopt["suggestion_id"] = second["id"]
        adopt["items"] = [["item_id":exact["id"]!,"expected_revision":exact["revision"]!,"target_id":exactTarget["id"]!,"review_basis_signature":exactTarget["review_basis_signature"]!]]
        let adopted = (try f.call("media_adopt_suggestion",adopt)["decisions"] as! [JSON])[0]
        XCTAssertEqual(adopted["adopted_suggestion_id"] as? String,second["id"] as? String);XCTAssertEqual(adopted["disposition"] as? String,"accepted")
    }

    func testDraftSuggestionWhoseTargetChangedBeforePublicationIsNotShownAsCurrent() throws {
        let f = try Fixture(),round = try draftRound(f,items:3)
        let view = try worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        let titled = items[0],content = items[1],same = items[2]
        var saved: [String:JSON] = [:]
        for item in items { saved[item["id"] as! String] = (try worker(f,"media_suggest",draftSuggestion(view,item))["decisions"] as! [JSON])[0] }
        // A title edit keeps the basis and still changes the exact target.
        let titledRecord = try f.record(titled["id"] as! String,"media_item")
        let retitled = try f.call("media_item_update",["item_id":titled["id"]!,"expected_revision":titledRecord["revision"]!,"title":"New title"])
        XCTAssertEqual((retitled["draft_target"] as! JSON)["review_basis_signature"] as? String,titled["review_basis_signature"] as? String)
        let contentRecord = try f.record(content["id"] as! String,"media_item")
        let recaptured = try f.call("media_item_update",["item_id":content["id"]!,"expected_revision":contentRecord["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"another take"]]]]])
        XCTAssertNotEqual((recaptured["draft_target"] as! JSON)["review_basis_signature"] as? String,content["review_basis_signature"] as? String)
        // Before publication the owner's Draft view already labels both as not current.
        XCTAssertEqual(try suggestions(f,round,titled).1[0]["stale"] as? Bool,true)
        XCTAssertEqual(try suggestions(f,round,content).1[0]["stale"] as? Bool,true)
        XCTAssertEqual(try suggestions(f,round,same).1[0]["stale"] as? Bool,false)
        // The old observation refuses a new suggestion on the changed item.
        checks.checkError("REVISION_CONFLICT") {try self.worker(f,"media_suggest",self.draftSuggestion(view,titled))}
        _ = try ownerPublish(f,round)
        XCTAssertEqual(try suggestions(f,round,titled).1[0]["stale"] as? Bool,true)
        XCTAssertEqual(try suggestions(f,round,content).1[0]["stale"] as? Bool,true)
        XCTAssertEqual(try suggestions(f,round,same).1[0]["stale"] as? Bool,false)
        // A stale Draft suggestion cannot be adopted as current.
        let current = try f.get(round),exact = (current["items"] as! [JSON]).first {$0["id"] as? String == titled["id"] as? String}!,target = exact["published_target"] as! JSON
        var adopt = f.observation(current);let m = current["manifest"] as! JSON
        adopt["manifest_id"] = m["id"];adopt["manifest_digest"] = m["digest"];adopt["suggestion_id"] = saved[titled["id"] as! String]!["id"]
        adopt["items"] = [["item_id":exact["id"]!,"expected_revision":exact["revision"]!,"target_id":target["id"]!,"review_basis_signature":target["review_basis_signature"]!]]
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_adopt_suggestion",adopt)}
        // A later publication of a new target makes even the unchanged Draft suggestion earlier history.
        _ = try ownerPublish(f,round)
        XCTAssertEqual(try suggestions(f,round,same).1[0]["stale"] as? Bool,true)
    }

    func testDraftSuggestionFenceRefusesManifestWrongTargetAndOpenRoundWithoutManifest() throws {
        let f = try Fixture(),round = try draftRound(f,items:2)
        let view = try worker(f,"media_round_get",["round_id":round["id"]!]),items = view["items"] as! [JSON]
        let before = try f.allState()
        var withManifest = draftSuggestion(view,items[0]);withManifest["manifest_id"] = "manifest";withManifest["manifest_digest"] = String(repeating:"a",count:64)
        checks.checkError("MEDIA_MANIFEST_CHANGED") {try self.worker(f,"media_suggest",withManifest)}
        var half = draftSuggestion(view,items[0]);half["manifest_id"] = "manifest"
        XCTAssertThrowsError(try worker(f,"media_suggest",half))
        var wrong = draftSuggestion(view,items[0]);var entry = (wrong["items"] as! [JSON])[0];entry["target_id"] = items[1]["target_id"];wrong["items"] = [entry]
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.worker(f,"media_suggest",wrong)}
        var token = draftSuggestion(view,items[0]);token["observed_context_token"] = "mc1.other"
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try self.worker(f,"media_suggest",token)}
        // Grammar is the same as a published suggestion's.
        var noWinner = draftSuggestion(view,items[0],disposition:"accepted");noWinner.removeValue(forKey:"winner_id")
        checks.checkError("INVALID_INPUT") {try self.worker(f,"media_suggest",noWinner)}
        XCTAssertEqual(try f.allState(),before)
        // An Open round still needs its manifest observation.
        _ = try ownerPublish(f,round)
        let open = try worker(f,"media_round_get",["round_id":round["id"]!])
        checks.checkError("MEDIA_MANIFEST_CHANGED") {try self.worker(f,"media_suggest",self.draftSuggestion(open,(open["items"] as! [JSON])[0]))}
    }
}
