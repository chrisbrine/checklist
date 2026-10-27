import XCTest
@testable import ChecklistApp
import ChecklistCore

/// CL-300: owner rework, closure and successor screens against the synthetic mock service.
extension MediaOwnerSliceTests {
    func reworkRows() -> [MediaValues] {
        [["id":"changed","title":"Changed walk","disposition":"changes_requested","decision_id":"decision-changed","metadata":[:]],
         ["id":"kept","title":"Kept idle","disposition":"accepted","decision_id":"decision-kept","metadata":[:]],
         ["id":"waiting","title":"Waiting run","disposition":"pending","decision_id":"","metadata":[:]],
         ["id":"moved","title":"Moved jump","disposition":"stale","decision_id":"decision-old","metadata":[:]]]
    }
    func testReworkPreviewSendsOnlySelectedChangesRequestedItemsAndCreateRepeatsTheExactPreview() async throws {
        let (peer,store,_,_)=fixture();peer.rows=reworkRows();let model=await setup(peer,store)
        XCTAssertEqual(model.reworkCandidates.map(\.id),["changed"])
        for row in model.rows {model.toggleRework(row)}
        XCTAssertEqual(model.reworkSelection,["changed"])
        model.reworkEpicID="epic-1"
        let preview:MediaValues=["round_id":"round","expected_revision":4,"observed_context_token":"context-1","manifest_id":"manifest","manifest_digest":"digest","epic_id":"epic-1","preview_digest":"preview-1","readiness":"draft",
            "items":[["item_id":"changed","expected_revision":2,"decision_id":"decision-changed","title":"Rework: Changed walk","action":"create"]]]
        peer.extra["media_rework_preview"]=preview
        await model.previewRework()
        let asked=try XCTUnwrap(peer.calls.last {$0.0=="media_rework_preview"}?.1)
        XCTAssertNil(asked["command_id"]);XCTAssertEqual(asked["epic_id"] as? String,"epic-1")
        XCTAssertEqual((asked["items"] as? [MediaValues])?.map {$0["item_id"] as? String},["changed"])
        XCTAssertEqual(MediaRoundActions.reworkPreviewLabel(model.reworkPreview.records("items")[0]),"Rework: Changed walk · Creates a Draft ticket")
        // A changed Epic drops the preview; create can only send a preview the owner saw.
        model.reworkEpicID="epic-2";XCTAssertTrue(model.reworkPreview.records("items").isEmpty)
        model.reworkEpicID="epic-1";await model.previewRework()
        store.connected=true;model.createRework();try await settle {peer.calls.contains {$0.0=="media_rework_create"} && model.reworkSelection.isEmpty}
        let sent=try XCTUnwrap(peer.calls.last {$0.0=="media_rework_create"}?.1)
        XCTAssertNotNil(sent["command_id"])
        for key in ["round_id","observed_context_token","manifest_id","manifest_digest","epic_id","preview_digest"] {XCTAssertEqual(sent[key] as? String,preview[key] as? String,key)}
        XCTAssertEqual(sent["expected_revision"] as? Int,4)
        let items=try XCTUnwrap(sent["items"] as? [MediaValues]);XCTAssertEqual(items.count,1)
        XCTAssertEqual(items[0]["item_id"] as? String,"changed");XCTAssertEqual(items[0]["expected_revision"] as? Int,2);XCTAssertEqual(items[0]["decision_id"] as? String,"decision-changed")
        XCTAssertEqual(Set(items[0].keys),["item_id","expected_revision","decision_id"])
        // A retry's fresh preview shows the reused exact link for the same decision.
        var reused=preview;reused["items"]=[["item_id":"changed","expected_revision":2,"decision_id":"decision-changed","title":"Rework: Changed walk","action":"reuse","link_id":"link-1"]]
        peer.extra["media_rework_preview"]=reused;model.toggleRework(model.reworkCandidates[0]);await model.previewRework()
        XCTAssertEqual(MediaRoundActions.reworkPreviewLabel(model.reworkPreview.records("items")[0]),"Rework: Changed walk · Reuses its existing rework ticket")
    }
    func testClosureBlocksPendingNeedsLookAndStaleWithTheirOwnTextAndWaitsForConfirmation() async throws {
        let blockers=MediaReviewModel.closureBlockers(["pending":1,"needs_look":2,"stale":3,"accepted":4])
        XCTAssertEqual(blockers.filter {$0.0}.count,3);XCTAssertEqual(Set(blockers.map {$0.1}).count,3)
        XCTAssertTrue(blockers[0].1.hasPrefix("1 Pending"));XCTAssertTrue(blockers[1].1.hasPrefix("2 Needs look"));XCTAssertTrue(blockers[2].1.hasPrefix("3 Stale"))
        XCTAssertTrue(MediaReviewModel.closureBlockers(["accepted":2,"changes_requested":1,"excluded":1]).allSatisfy {!$0.0})
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        XCTAssertTrue(model.reworkAvailable);XCTAssertTrue(model.successorAvailable)
        let sent=try await assertConfirmation({model.finishRoundConfirmation()},method:"media_round_finish",object:"Synthetic round",peer:peer,store:store)
        XCTAssertEqual(sent["round_id"] as? String,"round");XCTAssertEqual(sent["expected_revision"] as? Int,1)
        XCTAssertEqual(sent["observed_context_token"] as? String,"context-1")
        XCTAssertEqual(sent["manifest_id"] as? String,"manifest");XCTAssertEqual(sent["manifest_digest"] as? String,"digest")
        model.header=Record(values:["id":"round","title":"Closed","state":"closed","revision":2,"rework":["links":[["task_key":"CL-9","task_title":"Rework: Changed walk","task_open":true,"task_status_category":"queued"]],"counts":["open":1,"closed":0,"unavailable":0]]])
        XCTAssertFalse(model.reworkAvailable);XCTAssertTrue(model.successorAvailable)
        XCTAssertEqual(MediaRoundActions.reworkLinkLabel(Record(values:(model.header.object("rework")["links"] as! [MediaValues])[0])),"CL-9 Rework: Changed walk · Open")
    }
    func testSuccessorSendsOnlyExplicitInclusionAndCarriesOnlyCurrentDecisions() async throws {
        let (peer,store,_,_)=fixture();peer.rows=reworkRows();let model=await setup(peer,store)
        let rows=Dictionary(uniqueKeysWithValues:model.rows.map {($0.id,$0)})
        XCTAssertTrue(MediaReviewModel.canCarry(rows["kept"]!));XCTAssertFalse(MediaReviewModel.canCarry(rows["waiting"]!));XCTAssertFalse(MediaReviewModel.canCarry(rows["moved"]!))
        model.includeInSuccessor(rows["kept"]!,include:true,carry:true)
        model.includeInSuccessor(rows["waiting"]!,include:true,carry:true)
        model.includeInSuccessor(rows["moved"]!,include:true,carry:true)
        model.includeInSuccessor(rows["changed"]!,include:true,carry:false);model.includeInSuccessor(rows["changed"]!,include:false,carry:false)
        peer.extra["media_round_successor"]=["id":"round-next","state":"draft","revision":1]
        store.connected=true;model.createSuccessor(title:"Next pass");try await settle {model.roundID=="round-next"}
        let sent=try XCTUnwrap(peer.calls.last {$0.0=="media_round_successor"}?.1)
        XCTAssertEqual(sent["source_round_id"] as? String,"round");XCTAssertEqual(sent["title"] as? String,"Next pass")
        XCTAssertEqual(sent["manifest_digest"] as? String,"digest");XCTAssertEqual(sent["observed_context_token"] as? String,"context-1")
        let items=try XCTUnwrap(sent["items"] as? [MediaValues])
        XCTAssertEqual(items.map {$0["item_id"] as? String},["kept","moved","waiting"])
        XCTAssertEqual(items.map {$0["carry_decision_id"] as? String},["decision-kept",nil,nil])
        XCTAssertEqual(model.roundState,"draft");XCTAssertTrue(model.successorItems.isEmpty)
    }
    func testChangedSuccessorItemShowsStaleInRowHeadlineAndCounts() async throws {
        let (peer,store,_,_)=fixture()
        peer.rows=[["id":"moved","title":"Moved jump","disposition":"stale","metadata":[:]]];peer.pageCounts=["stale":1];peer.itemDisposition="stale"
        let model=await setup(peer,store);await model.select("moved")
        let row=try XCTUnwrap(model.rows.first)
        XCTAssertEqual(MediaReviewModel.dispositionLabel(row.string("disposition")),"Stale")
        XCTAssertEqual(MediaReviewModel.dispositionLabel(model.item.string("disposition")),"Stale")
        XCTAssertEqual(MediaReviewModel.countsText(model.counts),"Stale: 1")
        XCTAssertTrue(MediaReviewWorkspace.rowLabel(row).hasPrefix("Moved jump, Stale"))
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ChecklistApp/Media")
        let comparison=try String(contentsOf:root.appendingPathComponent("MediaOwnerComparison.swift"),encoding:.utf8)
        let workspace=try String(contentsOf:root.appendingPathComponent("MediaReviewWorkspace.swift"),encoding:.utf8)
        XCTAssertTrue(comparison.contains("MediaReviewModel.dispositionLabel(model.item.string(\"disposition\"))"))
        XCTAssertTrue(workspace.contains("MediaReviewModel.countsText(model.counts)"))
        XCTAssertTrue(workspace.contains("MediaRoundActions(model:model,confirmation:$confirmation)"))
    }
}
