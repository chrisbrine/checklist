import ChecklistContracts
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

/// CL-428: owned stores only; actual owner/worker router boundaries, no native app or service.
final class MediaRecommendationTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()

    func owner(_ f: Fixture,_ method: String,_ input: JSON,command: String? = nil) throws -> JSON {
        var p = input;p["project_id"] = f.project
        if !CommandRouter.mediaOwnerReads.contains(method) {p["command_id"] = command ?? uuid()}
        let reply = try f.router.handle(method:method,params:p,caller:f.owner)
        return try XCTUnwrap(reply["data"] as? JSON)
    }
    func setup(_ count: Int = 1,publish: Bool = true) throws -> (Fixture,JSON,[String]) {
        let f = try Fixture(),r = try f.round(try f.type(checks.schema()))
        var ids: [String] = []
        for i in 0..<count {ids.append(try f.item(r,title:"Take \(i)")["id"] as! String)}
        return (f,publish ? try f.publish(r) : r,ids)
    }
    func suggestionInput(_ f: Fixture,_ r: JSON,_ id: String,disposition: String = "needs_look",source: String? = nil) throws -> JSON {
        let v = try f.get(r,as:f.worker)
        var p: JSON
        if v["state"] as? String == "draft" {
            p = f.observation(v);p["items"] = f.selection(v,publish:true).filter {$0["item_id"] as? String == id}
            p["disposition"] = disposition
        } else {p = f.decisionParams(v,ids:[id],disposition:disposition)}
        p["note"] = "Inspect the foot contact\nSaved evidence: frame 7";p["source"] = source
        return p
    }
    func suggest(_ f: Fixture,_ r: JSON,_ id: String,disposition: String = "needs_look",source: String? = nil) throws -> JSON {
        let result = try channel.worker(f,"media_suggest",suggestionInput(f,r,id,disposition:disposition,source:source))
        return try XCTUnwrap((result["decisions"] as? [JSON])?.first)
    }
    func item(_ f: Fixture,_ r: JSON,_ id: String) throws -> JSON {
        try owner(f,"media_item_get",["round_id":r["id"]!,"item_id":id])
    }
    func dismiss(_ f: Fixture,_ r: JSON,_ s: JSON,command: String? = nil) throws -> JSON {
        try owner(f,"media_suggestion_dismiss",["round_id":r["id"]!,"suggestion_id":s["id"]!],command:command)
    }
    func listed(_ f: Fixture,_ r: JSON,_ filter: JSON) throws -> [String] {
        (try owner(f,"media_item_page",["round_id":r["id"]!,"filter":filter])["rows"] as! [JSON]).map {$0["id"] as! String}
    }

    func testSuggestionSourceDefaultCheckProjectionReplayAndChangedIntent() throws {
        let (f,r,ids) = try setup(2)
        let agent = try suggest(f,r,ids[0],disposition:"accepted")
        XCTAssertEqual(agent["source"] as? String,"agent")
        let input = try suggestionInput(f,r,ids[1],disposition:"changes_requested",source:"check"),command = uuid()
        let first = try channel.worker(f,"media_suggest",input,command:command)
        let flag = try XCTUnwrap((first["decisions"] as? [JSON])?.first)
        XCTAssertEqual(flag["source"] as? String,"check")
        XCTAssertEqual(flag["author_session_id"] as? String,f.worker.sessionID)
        XCTAssertEqual(flag["origin"] as? String,"agent")
        let before = try f.allState()
        XCTAssertEqual(try channel.worker(f,"media_suggest",input,command:command)["replayed"] as? Bool,true)
        var changed = input;changed["source"] = "agent"
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.channel.worker(f,"media_suggest",changed,command:command)}
        XCTAssertEqual(try f.allState(),before)
        let workerView = try channel.get(f,r)
        for (id,source) in [(ids[0],"agent"),(ids[1],"check")] {
            let detail = try item(f,r,id)
            let advice = try XCTUnwrap((detail["agent_suggestions"] as? [JSON])?.first)
            XCTAssertEqual(Set(advice.keys),Set(["id","disposition","note","author_display","source"]))
            XCTAssertEqual(advice["source"] as? String,source)
            XCTAssertFalse((advice["author_display"] as? String ?? "").isEmpty)
            XCTAssertEqual(advice["note"] as? String,input["note"] as? String)
            let workerItem = try XCTUnwrap((workerView["items"] as? [JSON])?.first {$0["id"] as? String == id})
            XCTAssertEqual(try jsonString(workerItem["agent_suggestions"]!),try jsonString(detail["agent_suggestions"]!))
            XCTAssertEqual(detail["disposition"] as? String,"pending");XCTAssertNil(detail["decision"])
        }
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        // Legacy records without the optional source retain their old content and read as agent.
        var legacy = agent;legacy["id"] = uuid();legacy["source"] = nil
        try f.router.dbQueue.write {try f.router.save($0,legacy,type:"media_suggestion")}
        XCTAssertEqual(((try item(f,r,ids[0])["agent_suggestions"] as! [JSON])[0])["source"] as? String,"agent")
        XCTAssertNil(try f.record(legacy["id"] as! String,"media_suggestion")["source"])
    }

    func testInvalidSourceAndOwnerSpoofingRefuseWithoutWrites() throws {
        let (f,r,ids) = try setup(),input = try suggestionInput(f,r,ids[0])
        let before = try f.allState()
        for invalid: Any in ["evidence","",17,true,NSNull(),["agent"]] {
            var p = input;p["source"] = invalid
            checks.checkError("INVALID_INPUT") {try self.channel.worker(f,"media_suggest",p)}
        }
        checks.checkError("FORBIDDEN") {try f.call("media_suggest",input)}
        var forged = input;forged["author_display"] = "Owner"
        checks.checkError("INVALID_INPUT") {try self.channel.worker(f,"media_suggest",forged)}
        var decision = f.decisionParams(try f.get(r));decision["source"] = "check"
        checks.checkError("INVALID_INPUT") {try self.owner(f,"media_decide",decision)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testDismissFlagsUpdatesEveryCurrentReadAndPreservesImmutableAdoption() throws {
        let (f,r,ids) = try setup(2),flag = try suggest(f,r,ids[0],source:"check")
        let other = try suggest(f,r,ids[1],disposition:"changes_requested")
        var adoption = f.decisionParams(try f.get(r),ids:[ids[0]],disposition:"needs_look")
        adoption["disposition"] = nil;adoption["suggestion_id"] = flag["id"]
        let kept = try owner(f,"media_adopt_suggestion",adoption)
        let decision = (kept["decisions"] as! [JSON])[0],canonical = try jsonString(f.record(flag["id"] as! String,"media_suggestion"))
        let first = try dismiss(f,r,flag),marker = try XCTUnwrap(first["dismissed"] as? JSON)
        XCTAssertEqual(marker["by"] as? String,"owner");XCTAssertNotNil(marker["at"])
        XCTAssertEqual(first["stale"] as? Bool,true)
        let detail = try item(f,r,ids[0])
        XCTAssertTrue((detail["agent_suggestions"] as! [JSON]).isEmpty)
        XCTAssertEqual(try jsonString((detail["suggestions"] as! [JSON])[0]["dismissed"]!),try jsonString(marker))
        XCTAssertEqual((detail["decision"] as? JSON)?["id"] as? String,decision["id"] as? String)
        XCTAssertEqual(detail["disposition"] as? String,"needs_look")
        XCTAssertEqual(try f.rows("media_owner_decision").count,1)
        XCTAssertEqual(try jsonString(f.record(flag["id"] as! String,"media_suggestion")),canonical)
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),[ids[1]])
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":false]),[ids[0]])
        XCTAssertEqual(try listed(f,r,["agent_suggestion_excludes":["needs_look"]]).count,2)
        XCTAssertEqual(try listed(f,r,["has_note":true]).count,2,"The adopted owner's own note survives")
        let selection = try owner(f,"media_bulk_selection",["round_id":r["id"]!])
        XCTAssertNil((selection["entries"] as! [JSON]).first {$0["item_id"] as? String == ids[0]}?["agent_suggestions"])
        XCTAssertEqual((selection["entries"] as! [JSON]).first {$0["item_id"] as? String == ids[1]}?["agent_suggestions"] as? [String],["changes_requested"])
        _ = try dismiss(f,r,other)
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),[])
        XCTAssertEqual(try listed(f,r,["has_note":true]),[ids[0]],"Dismissed advice contributes no note to filters")
        let workerItems = try channel.get(f,r)["items"] as! [JSON]
        XCTAssertTrue(workerItems.allSatisfy {($0["agent_suggestions"] as? [JSON])?.isEmpty == true})
        // Capture validation still resolves the exact immutable suggestion referenced by adoption.
        try f.router.dbQueue.read {db in try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db))}
        var again = f.decisionParams(try f.get(r),ids:[ids[0]],disposition:"needs_look")
        again["disposition"] = nil;again["suggestion_id"] = flag["id"]
        let before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.owner(f,"media_adopt_suggestion",again)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testDismissReplayChangedIntentAndRepeatedMarkerAfterRestart() throws {
        let (f,r,ids) = try setup(2),flag = try suggest(f,r,ids[0]),other = try suggest(f,r,ids[1])
        let command = uuid(),first = try dismiss(f,r,flag,command:command)
        let before = try f.allState()
        let replay = try dismiss(f,r,flag,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try jsonString(replay["dismissed"]!),try jsonString(first["dismissed"]!))
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.dismiss(f,r,other,command:command)}
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.owner(f,"media_suggestion_dismiss",["round_id":uuid(),"suggestion_id":flag["id"]!],command:command)}
        XCTAssertEqual(try f.allState(),before)
        let revision = try f.record(r["id"] as! String,"media_round")["revision"] as! Int
        let repeated = try dismiss(f,r,flag)
        XCTAssertEqual(try jsonString(repeated["dismissed"]!),try jsonString(first["dismissed"]!))
        XCTAssertEqual(try f.record(r["id"] as! String,"media_round")["revision"] as? Int,revision)
        try f.reopen()
        XCTAssertTrue((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).isEmpty)
        XCTAssertEqual(try jsonString((try item(f,r,ids[0])["suggestions"] as! [JSON])[0]["dismissed"]!),try jsonString(first["dismissed"]!))
        XCTAssertEqual(try dismiss(f,r,flag,command:command)["replayed"] as? Bool,true)
    }

    func testDismissIsOwnerOnlyScopedAndFlagOnlyWithClosedInputShape() throws {
        let (f,r,ids) = try setup(2),flag = try suggest(f,r,ids[0]),accept = try suggest(f,r,ids[1],disposition:"accepted")
        let otherRound = try f.round(try f.type(checks.schema())),foreign = try Fixture()
        let foreignRound = try foreign.round(try foreign.type(checks.schema())),foreignItem = try foreign.item(foreignRound)
        _ = try foreign.publish(foreignRound)
        let foreignFlag = try suggest(foreign,foreignRound,foreignItem["id"] as! String)
        let before = try f.allState()
        XCTAssertTrue(CommandRouter.mediaOwnerMethods.contains("media_suggestion_dismiss"))
        XCTAssertFalse(MediaWorkerContract.methods.contains("media_suggestion_dismiss"))
        for caller in [f.worker,Caller(role:"assistant",installation:"fixture",projectIDs:[f.project],assistantGrants:[f.project:["read":true]])] {
            checks.checkError("FORBIDDEN") {try f.router.handle(method:"media_suggestion_dismiss",params:["project_id":f.project,"command_id":uuid(),"round_id":r["id"]!,"suggestion_id":flag["id"]!],caller:caller)}
            let catalog = try jsonString(f.router.handle(method:"tool_catalog",params:[:],caller:caller))
            XCTAssertFalse(catalog.contains("media_suggestion_dismiss"))
        }
        for input: JSON in [["round_id":uuid(),"suggestion_id":flag["id"]!],
                            ["round_id":r["id"]!,"suggestion_id":uuid()],
                            ["round_id":otherRound["id"]!,"suggestion_id":flag["id"]!],
                            ["round_id":r["id"]!,"suggestion_id":foreignFlag["id"]!],
                            ["round_id":foreignRound["id"]!,"suggestion_id":flag["id"]!]] {
            checks.checkError("NOT_FOUND") {try self.owner(f,"media_suggestion_dismiss",input)}
        }
        checks.checkError("INVALID_INPUT") {try self.dismiss(f,r,accept)}
        for extra: JSON in [["dismissed":["at":"forged","by":"owner"]],["source":"check"],["expected_revision":1],["items":[]]] {
            var input: JSON = ["round_id":r["id"]!,"suggestion_id":flag["id"]!]
            input.merge(extra) {$1}
            checks.checkError("INVALID_INPUT") {try self.owner(f,"media_suggestion_dismiss",input)}
        }
        for missing: JSON in [["round_id":r["id"]!],["suggestion_id":flag["id"]!],["round_id":r["id"]!,"suggestion_id":NSNull()]] {
            checks.checkError("INVALID_INPUT") {try self.owner(f,"media_suggestion_dismiss",missing)}
        }
        XCTAssertEqual(try f.allState(),before)
    }

    func testDraftDismissSurvivesExactPublicationLineageAndSuppressesLaterFlagsOnly() throws {
        let (f,r,ids) = try setup(publish:false),flag = try suggest(f,r,ids[0],source:"check")
        XCTAssertEqual(flag["target_phase"] as? String,"draft")
        let canonical = try jsonString(f.record(flag["id"] as! String,"media_suggestion"))
        _ = try dismiss(f,r,flag)
        _ = try f.publish(r)
        let detail = try item(f,r,ids[0]),target = detail["target"] as! JSON
        XCTAssertEqual(target["published_from_target_id"] as? String,flag["target_id"] as? String)
        XCTAssertTrue((detail["agent_suggestions"] as! [JSON]).isEmpty)
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),[])
        XCTAssertEqual(try listed(f,r,["has_note":true]),[])
        XCTAssertEqual(try jsonString(f.record(flag["id"] as! String,"media_suggestion")),canonical)
        let newFlag = try suggest(f,r,ids[0],disposition:"changes_requested")
        let checkFlag = try suggest(f,r,ids[0],source:"check")
        XCTAssertTrue((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).isEmpty)
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),[])
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":false]),ids)
        XCTAssertEqual(try listed(f,r,["has_note":true]),[])
        XCTAssertEqual(try listed(f,r,["agent_suggestion_excludes":["changes_requested","needs_look"]]),ids)
        XCTAssertNil((try owner(f,"media_bulk_selection",["round_id":r["id"]!])["entries"] as! [JSON])[0]["agent_suggestions"])
        for s in [newFlag,checkFlag] {
            let history = (try item(f,r,ids[0])["suggestions"] as! [JSON]).first {$0["id"] as? String == s["id"] as? String}!
            XCTAssertNotNil(history["dismissed"])
            XCTAssertNil(try f.record(s["id"] as! String,"media_suggestion")["dismissed"],"Suggestion bodies remain immutable")
        }
        let accepted = try suggest(f,r,ids[0],disposition:"accepted")
        XCTAssertEqual((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).map {$0["id"] as! String},[accepted["id"] as! String])
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),ids)
        XCTAssertEqual(try listed(f,r,["agent_suggestion_excludes":["changes_requested","needs_look"]]),ids)
        XCTAssertEqual((try owner(f,"media_bulk_selection",["round_id":r["id"]!])["entries"] as! [JSON])[0]["agent_suggestions"] as? [String],["accepted"])
        try f.reopen()
        let worker = try channel.get(f,r)["items"] as! [JSON]
        XCTAssertEqual((worker[0]["agent_suggestions"] as! [JSON]).map {$0["id"] as! String},[accepted["id"] as! String])
    }

    func testPublishedDismissSuppressesOtherDraftFlagsButReplacementTargetCanBeFlagged() throws {
        let (f,r,ids) = try setup(publish:false)
        let first = try suggest(f,r,ids[0]),other = try suggest(f,r,ids[0],disposition:"changes_requested")
        _ = try f.publish(r)
        let target = try item(f,r,ids[0])["target"] as! JSON
        let dismissed = try dismiss(f,r,first)
        XCTAssertEqual((dismissed["dismissed"] as? JSON)?["target_id"] as? String,target["id"] as? String)
        XCTAssertTrue((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).isEmpty)
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),[])
        XCTAssertEqual(try listed(f,r,["has_note":true]),[])
        let before = try f.allState()
        var adopt = f.decisionParams(try f.get(r),ids:ids,disposition:"changes_requested")
        adopt["disposition"] = nil;adopt["suggestion_id"] = other["id"]
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.owner(f,"media_adopt_suggestion",adopt)}
        XCTAssertEqual(try f.allState(),before)
        let original = try f.record(ids[0],"media_item")
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":original["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Replacement take"]]]]])
        _ = try f.publish(r)
        let newFlag = try suggest(f,r,ids[0])
        XCTAssertEqual((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).map {$0["id"] as! String},[newFlag["id"] as! String])
        XCTAssertEqual(try listed(f,r,["has_agent_suggestion":true]),ids)
    }

    func testDismissRefusesStaleSameBasisTargetAndClosedCanceledArchivedRounds() throws {
        let (f,r,ids) = try setup(publish:false),flag = try suggest(f,r,ids[0])
        let old = try f.record(ids[0],"media_item")
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":old["revision"]!,"title":"Display-only target successor"])
        let detail = try item(f,r,ids[0])
        XCTAssertEqual((detail["target"] as? JSON)?["review_basis_signature"] as? String,flag["review_basis_signature"] as? String)
        var before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.dismiss(f,r,flag)}
        XCTAssertEqual(try f.allState(),before)
        let (closedFixture,closedRound,closedIDs) = try setup(),closedFlag = try suggest(closedFixture,closedRound,closedIDs[0])
        try closedFixture.acceptEach(closedRound)
        let open = try closedFixture.get(closedRound)
        var finish = closedFixture.observation(open),manifest = open["manifest"] as! JSON
        finish["manifest_id"] = manifest["id"];finish["manifest_digest"] = manifest["digest"]
        _ = try owner(closedFixture,"media_round_finish",finish)
        before = try closedFixture.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.dismiss(closedFixture,closedRound,closedFlag)}
        XCTAssertEqual(try closedFixture.allState(),before)
        let current = try f.get(r)
        let canceled = try owner(f,"media_round_cancel",["round_id":r["id"]!,"expected_revision":current["revision"]!,"reason":"No more takes"])
        before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.dismiss(f,r,flag)}
        XCTAssertEqual(try f.allState(),before)
        _ = try owner(f,"media_round_archive",["round_id":r["id"]!,"expected_revision":canceled["revision"]!])
        before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.dismiss(f,r,flag)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testDismissalHistoryDoesNotAttributeANewTargetDismissalToEarlierFlags() throws {
        let (f,r,ids) = try setup(publish:false),old = try suggest(f,r,ids[0])
        let stored = try f.record(ids[0],"media_item")
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":stored["revision"]!,"title":"A different exact target"])
        let current = try suggest(f,r,ids[0]),dismissed = try dismiss(f,r,current)
        let history = try item(f,r,ids[0])["suggestions"] as! [JSON]
        let earlier = try XCTUnwrap(history.first {$0["id"] as? String == old["id"] as? String})
        XCTAssertTrue(bool(earlier,"stale"))
        XCTAssertNil(earlier["dismissed"],"An earlier target was not cleared by the owner's current-target action")
        XCTAssertNotNil(dismissed["dismissed"])
        XCTAssertTrue((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).isEmpty)
    }

    func testDismissRollsBackWithFailedCommandReceipt() throws {
        let (f,r,ids) = try setup(),flag = try suggest(f,r,ids[0]),before = try f.allState()
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TEMP TRIGGER cl428_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned receipt failure');END")}
        XCTAssertThrowsError(try dismiss(f,r,flag))
        XCTAssertEqual(try f.allState(),before)
        XCTAssertEqual((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).count,1)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cl428_receipt_failure")}
        _ = try dismiss(f,r,flag)
        XCTAssertTrue((try item(f,r,ids[0])["agent_suggestions"] as! [JSON]).isEmpty)
    }
}
