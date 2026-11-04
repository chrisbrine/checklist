import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-428: owner choice withdrawal uses real router dispatch on owned media fixtures.
final class MediaDecisionWithdrawalTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()
    let rework = MediaReworkTests()
    let followUp = MediaFollowUpTests()

    func owner(_ f: Fixture,_ method: String,_ input: JSON,command: String? = nil) throws -> JSON {
        var p = input;p["project_id"] = f.project
        if !CommandRouter.mediaOwnerReads.contains(method) { p["command_id"] = command ?? uuid() }
        let reply = try f.router.handle(method:method,params:p,caller:f.owner)
        XCTAssertEqual(reply["command_id"] as? String,p["command_id"] as? String)
        return try XCTUnwrap(reply["data"] as? JSON)
    }

    func params(_ f: Fixture,_ round: JSON,_ ids: [String]) throws -> JSON {
        let current = try f.get(round),manifest = try XCTUnwrap(current["manifest"] as? JSON)
        var p = f.observation(current)
        p["manifest_id"] = manifest["id"];p["manifest_digest"] = manifest["digest"]
        p["items"] = try ids.map { id -> JSON in
            let item = rework.row(current,id)
            return ["item_id":id,"expected_revision":try XCTUnwrap(item["revision"]),
                    "decision_id":try XCTUnwrap(item["last_decision_id"] as? String)]
        }
        return p
    }

    @discardableResult func withdraw(_ f: Fixture,_ round: JSON,_ ids: [String]) throws -> [JSON] {
        let result = try owner(f,"media_decision_withdraw",params(f,round,ids))
        return try XCTUnwrap(result["decisions"] as? [JSON])
    }

    func successorInput(_ f: Fixture,_ round: JSON,_ entries: [JSON]) throws -> JSON {
        let current = try f.get(round),manifest = try XCTUnwrap(current["manifest"] as? JSON)
        return ["source_round_id":current["id"]!,"expected_revision":current["revision"]!,
                "observed_context_token":current["observed_context_token"]!,"manifest_id":manifest["id"]!,
                "manifest_digest":manifest["digest"]!,"title":"Explicit next pass","items":entries]
    }

    func testWithdrawalAppendsImmutableHistoryAndPendingAcrossOwnerWorkerCountsAndClosure() throws {
        let (f,_,r,ids) = try rework.setup(2)
        let original = try rework.decide(f,r,ids[0],"accepted")
        try rework.decide(f,r,ids[1],"accepted")
        let originalJSON = try jsonString(original)
        let withdrawal = try XCTUnwrap(withdraw(f,r,[ids[0]]).first)
        XCTAssertEqual(withdrawal["disposition"] as? String,"withdrawn")
        XCTAssertEqual(withdrawal["withdraws_decision_id"] as? String,original["id"] as? String)
        XCTAssertEqual(withdrawal["supersedes_decision_id"] as? String,original["id"] as? String)
        XCTAssertEqual(withdrawal["origin"] as? String,"human_ui")
        XCTAssertEqual(withdrawal["author"] as? String,f.owner.principal)
        XCTAssertEqual(try f.rows("media_owner_decision").count,3)
        XCTAssertEqual(try jsonString(f.record(original["id"] as! String,"media_owner_decision")),originalJSON)
        XCTAssertEqual(try f.record(ids[0],"media_item")["last_decision_id"] as? String,withdrawal["id"] as? String)

        let round = try f.get(r),ownerItem = try rework.ownerItem(f,r,ids[0])
        XCTAssertEqual(rework.row(round,ids[0])["disposition"] as? String,"pending")
        XCTAssertEqual(ownerItem["disposition"] as? String,"pending")
        XCTAssertNil(ownerItem["follow_up"])
        let worker = try followUp.worker(f,"media_round_get",["round_id":r["id"]!])
        XCTAssertEqual(rework.row(worker,ids[0])["disposition"] as? String,"pending")
        let counts = try owner(f,"media_item_counts",["round_id":r["id"]!])
        XCTAssertEqual(counts["counts"] as? [String:Int],["pending":1,"accepted":1])
        let pendingPage = try owner(f,"media_item_page",["round_id":r["id"]!,"filter":["dispositions":["pending"]]])
        XCTAssertEqual((pendingPage["rows"] as? [JSON])?.map {$0["id"] as! String},[ids[0]])
        XCTAssertEqual(try followUp.readiness(f,r)["pending"] as? Int,1)
        let beforeClose = try f.allState()
        checks.checkError("MEDIA_UNRESOLVED") {try self.followUp.close(f,r)}
        XCTAssertEqual(try f.allState(),beforeClose)

        // Both records are immutable, and a later explicit choice supersedes the withdrawal.
        for record in [original,withdrawal] {
            try f.router.dbQueue.write { db in
                var changed = record;changed["note"] = "Cannot rewrite owner history"
                XCTAssertThrowsError(try f.router.mediaWrite(db,changed,type:"media_owner_decision"))
            }
        }
        let accepted = try rework.decide(f,r,ids[0],"accepted")
        XCTAssertEqual(accepted["supersedes_decision_id"] as? String,withdrawal["id"] as? String)
        XCTAssertEqual(try followUp.readiness(f,r)["pending"] as? Int,0)
        XCTAssertEqual(try followUp.close(f,r)["state"] as? String,"closed")
    }

    func testWithdrawalReplayKeepsExactRecordsAndChangedIntentRefuses() throws {
        let (f,_,r,ids) = try rework.setup(2)
        for id in ids {try rework.decide(f,r,id,"accepted")}
        let input = try params(f,r,ids),command = uuid()
        let saved = try owner(f,"media_decision_withdraw",input,command:command)
        let records = try XCTUnwrap(saved["decisions"] as? [JSON]),before = try f.allState()
        XCTAssertEqual(records.count,2)
        let replay = try owner(f,"media_decision_withdraw",input,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try jsonString(replay["decisions"] as! [JSON]),try jsonString(records))
        var changed = input;changed["items"] = [(input["items"] as! [JSON])[0]]
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.owner(f,"media_decision_withdraw",changed,command:command)}
        XCTAssertEqual(try f.allState(),before)
        XCTAssertEqual(try f.rows("media_owner_decision").count,4)
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.withdraw(f,r,ids)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testEveryCurrentOwnerChoiceCanReturnToPendingWithoutItsOldFollowUpRequirement() throws {
        let (f,_,r,ids) = try rework.setup(4)
        for (id,disposition) in zip(ids,["accepted","changes_requested","needs_look","excluded"]) {
            try rework.decide(f,r,id,disposition,disposition == "excluded" ? ["note":"Outside this review"] : [:])
        }
        XCTAssertEqual(try followUp.readiness(f,r)["missing_follow_up"] as? Int,1)
        let withdrawals = try withdraw(f,r,ids)
        XCTAssertEqual(withdrawals.count,4)
        XCTAssertTrue(withdrawals.allSatisfy {$0["disposition"] as? String == "withdrawn"})
        XCTAssertTrue((try f.get(r)["items"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "pending"})
        XCTAssertEqual(try owner(f,"media_item_counts",["round_id":r["id"]!])["counts"] as? [String:Int],["pending":4])
        let readiness = try followUp.readiness(f,r)
        XCTAssertEqual(readiness["pending"] as? Int,4)
        XCTAssertEqual(readiness["missing_follow_up"] as? Int,0)
        XCTAssertEqual(readiness["needs_look"] as? Int,0)
    }

    func testStaleRevisionHeadContextAndManifestRefuseTheWholeSelection() throws {
        let (f,_,r,ids) = try rework.setup(2)
        for id in ids {try rework.decide(f,r,id,"accepted")}
        let good = try params(f,r,ids)
        for (kind,code) in [("round_revision","REVISION_CONFLICT"),("item_revision","REVISION_CONFLICT"),
                            ("head","MEDIA_BASIS_CHANGED"),("context","MEDIA_CONTEXT_CHANGED"),
                            ("manifest_id","MEDIA_MANIFEST_CHANGED"),("manifest_digest","MEDIA_MANIFEST_CHANGED")] {
            var input = good,items = input["items"] as! [JSON]
            switch kind {
            case "round_revision": input["expected_revision"] = 999
            case "item_revision": items[1]["expected_revision"] = 999
            case "head": items[1]["decision_id"] = uuid()
            case "context": input["observed_context_token"] = "stale observation"
            default: input[kind] = "changed manifest"
            }
            input["items"] = items
            let before = try f.allState()
            checks.checkError(code) {try self.owner(f,"media_decision_withdraw",input)}
            XCTAssertEqual(try f.allState(),before,kind)
        }
        let oldDecision = (good["items"] as! [JSON])[1]["decision_id"] as! String
        try rework.decide(f,r,ids[1],"needs_look")
        var staleHead = try params(f,r,ids),items = staleHead["items"] as! [JSON]
        items[1]["decision_id"] = oldDecision;staleHead["items"] = items
        let before = try f.allState()
        checks.checkError("MEDIA_BASIS_CHANGED") {try self.owner(f,"media_decision_withdraw",staleHead)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testClosedCanceledAndArchivedRoundsRefuseWithdrawal() throws {
        let (f,_,r,ids) = try rework.setup(1)
        try rework.decide(f,r,ids[0],"accepted")
        _ = try followUp.close(f,r)
        var before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.withdraw(f,r,ids)}
        XCTAssertEqual(try f.allState(),before)

        let canceled = try f.round(f.rows("media_review_type")[0])
        let item = try f.item(canceled);_ = try f.publish(canceled)
        let id = item["id"] as! String
        try rework.decide(f,canceled,id,"needs_look")
        let current = try f.get(canceled)
        let canceledView = try f.call("media_round_cancel",["round_id":canceled["id"]!,"expected_revision":current["revision"]!,"reason":"Retire this pass"])
        before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.withdraw(f,canceled,[id])}
        XCTAssertEqual(try f.allState(),before)
        _ = try f.call("media_round_archive",["round_id":canceled["id"]!,"expected_revision":canceledView["revision"]!])
        before = try f.allState()
        checks.checkError("MEDIA_ROUND_CLOSED") {try self.withdraw(f,canceled,[id])}
        XCTAssertEqual(try f.allState(),before)
    }

    func testWithdrawalIsOwnerOnlyAndAbsentFromTheWorkerCommands() throws {
        let (f,_,r,ids) = try rework.setup(1)
        try rework.decide(f,r,ids[0],"accepted")
        let input = try params(f,r,ids),before = try f.allState()
        XCTAssertTrue(CommandRouter.mediaOwnerMethods.contains("media_decision_withdraw"))
        XCTAssertFalse(CommandRouter.mediaWorkerMethods.contains("media_decision_withdraw"))
        checks.checkError("FORBIDDEN") {try self.followUp.worker(f,"media_decision_withdraw",input)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testReworkTicketAndWorkerReasonReferencesPreventAtomicWithdrawal() throws {
        let (f,_,r,ids) = try rework.setup(3)
        try rework.decide(f,r,ids[0],"accepted")
        for id in ids[1...2] {try rework.decide(f,r,id,"changes_requested")}
        let epic = try rework.epic(f),preview = try rework.preview(f,r,[ids[1]],epic:epic)
        _ = try f.call("media_rework_create",rework.createInput(preview))
        var reason = try followUp.followUp(f,r,[ids[2]]);reason["reason"] = "Next production pass"
        _ = try followUp.worker(f,"media_follow_up_record",reason)
        for id in ids[1...2] {
            let input = try params(f,r,[ids[0],id]),before = try f.allState()
            checks.checkError("MEDIA_DECISION_IN_USE") {try self.owner(f,"media_decision_withdraw",input)}
            XCTAssertEqual(try f.allState(),before)
            XCTAssertEqual(rework.row(try f.get(r),ids[0])["disposition"] as? String,"accepted")
        }
    }

    func testExactSuccessorCarryPreventsWithdrawalOfItsSourceDecision() throws {
        let (f,_,r,ids) = try rework.setup(1)
        let original = try rework.decide(f,r,ids[0],"accepted")
        let successor = try f.call("media_round_successor",successorInput(f,r,[["item_id":ids[0],"carry_decision_id":original["id"]!]]))
        let outcome = try XCTUnwrap((successor["successor"] as? JSON)?["items"] as? [JSON]).first!
        XCTAssertEqual(outcome["carried"] as? Bool,true)
        let carried = try f.record(outcome["decision_id"] as! String,"media_owner_decision")
        XCTAssertEqual(carried["carried_from_decision_id"] as? String,original["id"] as? String)
        let before = try f.allState()
        checks.checkError("MEDIA_DECISION_IN_USE") {try self.withdraw(f,r,ids)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testWithdrawnHeadIsIneligibleForReworkFollowUpCarryAndApprovedExamples() throws {
        let (f,type,r,ids) = try rework.setup(1)
        try rework.decide(f,r,ids[0],"accepted")
        let current = try f.round(type),item = try f.item(current),examples = MediaListQueryTests()
        XCTAssertEqual((try examples.show(f,current,item)["examples"] as? [JSON])?.count,1)
        let withdrawal = try XCTUnwrap(withdraw(f,r,ids).first)
        XCTAssertTrue((try examples.show(f,current,item)["examples"] as! [JSON]).isEmpty)
        let epic = try rework.epic(f),before = try f.allState()
        checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.rework.preview(f,r,ids,epic:epic)}
        let workerView = try followUp.worker(f,"media_round_get",["round_id":r["id"]!])
        let workerItem = rework.row(workerView,ids[0]),manifest = workerView["manifest"] as! JSON
        let reason: JSON = ["round_id":r["id"]!,"expected_revision":workerView["revision"]!,
            "observed_context_token":workerView["observed_context_token"]!,"manifest_id":manifest["id"]!,
            "manifest_digest":manifest["digest"]!,"reason":"No current owner change request",
            "items":[["item_id":ids[0],"expected_revision":workerItem["expected_revision"]!,"decision_id":withdrawal["id"]!]]]
        checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.followUp.worker(f,"media_follow_up_record",reason)}
        let carry = try successorInput(f,r,[["item_id":ids[0],"carry_decision_id":withdrawal["id"]!]])
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_round_successor",carry)}
        XCTAssertEqual(try f.allState(),before)
        let successor = try f.call("media_round_successor",successorInput(f,r,[["item_id":ids[0]]]))
        let outcomes = (successor["successor"] as! JSON)["items"] as! [JSON]
        XCTAssertEqual(outcomes[0]["carried"] as? Bool,false)
        let published = try f.publish(successor)
        XCTAssertEqual(rework.row(published,outcomes[0]["item_id"] as! String)["disposition"] as? String,"pending")
    }

    func testResultSendingOmitsWithdrawnHeadAndRefusesWhenNoOwnerChoiceRemains() throws {
        let (f,_,r,ids) = try rework.setup(2),task = try followUp.ticket(f,"Ticket owning the reviewed takes")
        let current = try f.get(r)
        _ = try f.call("media_round_link_task",["round_id":r["id"]!,"expected_revision":current["revision"]!,"task_id":task["id"]!])
        try rework.decide(f,r,ids[0],"accepted",["note":"Withdrawn choice must stay out of the result"])
        try rework.decide(f,r,ids[1],"needs_look",["note":"Still current"])
        try withdraw(f,r,[ids[0]])
        let sentView = try f.get(r)
        let sent = try f.call("media_round_send_result",["round_id":r["id"]!,"expected_revision":sentView["revision"]!])
        XCTAssertEqual(sent["item_count"] as? Int,1)
        let body = try f.record(sent["message_id"] as! String,"message")["body"] as! String
        XCTAssertFalse(body.contains("Withdrawn choice"));XCTAssertFalse(body.contains(": Accepted"))
        XCTAssertTrue(body.contains(": Needs look — Still current"))
        try withdraw(f,r,[ids[1]])
        let pending = try f.get(r),before = try f.allState()
        checks.checkError("MEDIA_ROUND_NO_DECISIONS") {try f.call("media_round_send_result",["round_id":r["id"]!,"expected_revision":pending["revision"]!])}
        XCTAssertEqual(try f.allState(),before)
    }
}
