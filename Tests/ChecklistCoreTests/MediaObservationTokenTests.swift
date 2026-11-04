import Foundation
import XCTest
@testable import ChecklistCore

/// CL-427 X1: actual router commands on owned stores; no service or native UI.
final class MediaObservationTokenTests: XCTestCase {
    let checks = MediaRoundTests()
    let recommendations = MediaRecommendationTests()
    let results = MediaRoundResultTests()
    let itemTasks = MediaItemTaskTests()

    func testSecondItemAcceptsInspectedTokenAfterSendRoundLinkItemLinkAndFlagDismissal() throws {
        for (method,worker) in [("media_round_send_result",false),("media_round_link_task",false),
                                ("media_round_link_task",true),("media_item_link_task",false),
                                ("media_item_link_task",true),("media_suggestion_dismiss",false)] {
            let (f,r,ids) = try recommendations.setup(2)
            _ = try results.link(f,r,results.task(f))
            let flag = try recommendations.suggest(f,r,ids[0])
            let observed = try f.get(r),token = observed["observed_context_token"] as? String
            var second = f.decisionParams(observed,ids:[ids[1]])
            _ = try f.call("media_decide",f.decisionParams(observed,ids:[ids[0]]))
            XCTAssertEqual(try f.get(r)["observed_context_token"] as? String,token,"An owner decision changes its item head, not the inspected context")
            switch method {
            case "media_round_send_result": _ = try f.call(method,results.sendInput(f,r))
            case "media_round_link_task":
                let task = try results.task(f)
                if worker {
                    _ = try recommendations.channel.worker(f,method,["round_id":r["id"]!,"expected_revision":observed["revision"]!,"task_id":task["id"]!])
                } else {_ = try results.link(f,r,task)}
            case "media_item_link_task": _ = try itemTasks.link(f,r,ids[0],results.task(f),worker:worker)
            default: _ = try recommendations.dismiss(f,r,flag)
            }
            let refreshed = try f.get(r)
            XCTAssertGreaterThan(int(refreshed,"revision"),int(observed,"revision"),method)
            XCTAssertEqual(refreshed["observed_context_token"] as? String,token,method)
            let before = try f.allState()
            checks.checkError("REVISION_CONFLICT") {try f.call("media_decide",second)}
            XCTAssertEqual(try f.allState(),before)
            // The app refreshes only the header revision; the inspected selection/token stay saved.
            second["expected_revision"] = refreshed["revision"]
            let saved = try f.call("media_decide",second)["decisions"] as! [JSON]
            XCTAssertEqual(saved.first?["item_id"] as? String,ids[1],method)
            XCTAssertEqual(saved.first?["disposition"] as? String,"accepted",method)
            XCTAssertEqual(try f.get(r)["observed_context_token"] as? String,token,method)
            let after = try f.allState()
            checks.checkError("REVISION_CONFLICT") {try f.call("media_decide",second)}
            XCTAssertEqual(try f.allState(),after,"The selected item's own revision still fences a second decision")
        }
    }

    func testDoneWarningKeepsTokenForTheStillOpenRound() throws {
        let (f,r,ids) = try recommendations.setup(2),task = try results.task(f)
        _ = try results.link(f,r,task)
        let observed = try f.get(r)
        var decision = f.decisionParams(observed,ids:[ids[1]])
        try MediaLinkedTaskCleanupTests().done(f,task)
        let refreshed = try f.get(r)
        XCTAssertEqual(refreshed["state"] as? String,"open")
        XCTAssertGreaterThan(int(refreshed,"revision"),int(observed,"revision"))
        XCTAssertEqual(refreshed["observed_context_token"] as? String,observed["observed_context_token"] as? String)
        XCTAssertNotNil(try f.record(r["id"] as! String,"media_round")["done_task_warning"])
        decision["expected_revision"] = refreshed["revision"]
        XCTAssertEqual((try f.call("media_decide",decision)["decisions"] as! [JSON]).first?["item_id"] as? String,ids[1])
    }

    func testDraftFrozenSelectionSurvivesUnselectedItemAddAndRoundLink() throws {
        let (f,r,ids) = try recommendations.setup(2,publish:false),observed = try f.get(r)
        var publication = f.observation(observed);publication["items"] = f.selection(observed,publish:true)
        let extra = try f.item(r,title:"Added after the frozen preview")
        _ = try results.link(f,r,results.task(f))
        let refreshed = try f.get(r)
        XCTAssertEqual(refreshed["observed_context_token"] as? String,observed["observed_context_token"] as? String)
        let before = try f.allState()
        checks.checkError("REVISION_CONFLICT") {try f.call("media_round_publish",publication)}
        XCTAssertEqual(try f.allState(),before)
        publication["expected_revision"] = refreshed["revision"]
        let published = try f.call("media_round_publish",publication),manifest = published["manifest"] as! JSON
        XCTAssertEqual(Set((manifest["items"] as! [JSON]).map {$0["item_id"] as! String}),Set(ids))
        XCTAssertFalse((manifest["items"] as! [JSON]).contains {$0["item_id"] as? String == extra["id"] as? String})
        XCTAssertNotEqual(published["observed_context_token"] as? String,observed["observed_context_token"] as? String,"Publication changes the manifest")
    }

    func testDraftFrozenSelectionStillRefusesChangedTargetAndBasis() throws {
        let (f,r,ids) = try recommendations.setup(1,publish:false),observed = try f.get(r)
        var publication = f.observation(observed);publication["items"] = f.selection(observed,publish:true)
        let old = try f.record(ids[0],"media_item")
        _ = try f.call("media_item_update",["item_id":ids[0],"expected_revision":old["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Changed exact take"]]]]])
        let refreshed = try f.get(r)
        XCTAssertEqual(refreshed["observed_context_token"] as? String,observed["observed_context_token"] as? String,"Per-item target guards are separate from round context")
        let before = try f.allState()
        checks.checkError("REVISION_CONFLICT") {try f.call("media_round_publish",publication)}
        var selection = f.selection(refreshed,publish:true)
        selection[0]["review_basis_signature"] = (publication["items"] as! [JSON])[0]["review_basis_signature"]
        publication["items"] = selection
        checks.checkError("MEDIA_BASIS_CHANGED") {try f.call("media_round_publish",publication)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testAttentionReconciliationAndReplacementManifestStillFenceInspectedToken() throws {
        let (f,r,ids) = try recommendations.setup(2),observed = try f.get(r)
        let saved = f.decisionParams(observed,ids:[ids[1]])
        _ = try f.call("media_context_approve",["kind":"direction","round_id":r["id"]!,"body":"Owner changed the review instruction"])
        let attention = try f.get(r),before = try f.allState()
        var stale = saved;stale["expected_revision"] = attention["revision"]
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",stale)}
        checks.checkError("MEDIA_CONTEXT_ATTENTION") {try f.call("media_decide",f.decisionParams(attention,ids:[ids[1]]))}
        XCTAssertEqual(try f.allState(),before)
        let reconciled = try f.reconcile(r)
        stale["expected_revision"] = reconciled["revision"]
        let after = try f.allState()
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",stale)}
        XCTAssertEqual(try f.allState(),after)
        var priorManifest = f.decisionParams(reconciled,ids:[ids[1]])
        let published = try f.publish(r)
        XCTAssertEqual(published["context_id"] as? String,reconciled["context_id"] as? String)
        XCTAssertNotEqual(published["observed_context_token"] as? String,reconciled["observed_context_token"] as? String)
        priorManifest["expected_revision"] = published["revision"]
        let afterPublish = try f.allState()
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",priorManifest)}
        XCTAssertEqual(try f.allState(),afterPublish)
    }
}
