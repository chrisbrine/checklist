import XCTest
@testable import ChecklistApp
import ChecklistCore

/// CL-337: typing persists local item notes but never supplies an owner decision.
@MainActor final class MediaNoteAutosaveTests: XCTestCase {
    private func fixture() async -> (MediaOwnerSliceTests.Peer,ChecklistStore,IsolatedDefaults,URL,MediaReviewModel) {
        let defaults=isolatedDefaults("MediaNoteAutosave")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:directory)}
        let peer=MediaOwnerSliceTests.Peer()
        peer.types=[["id":"animation","title":"Animation","enabled":true]]
        let store=peer.store(defaults.preferences,directory)
        let model=await connectedModel(store)
        return (peer,store,defaults,directory,model)
    }
    private func connectedModel(_ store:ChecklistStore) async -> MediaReviewModel {
        let model=store.mediaReview
        await model.connect(store:store)
        model.roundID="round"
        await model.refresh()
        await model.select("item-a")
        return model
    }
    private func savedNote(_ preferences:UserDefaults,item:String="item-a") throws -> String {
        let data=try XCTUnwrap(preferences.data(forKey:"mediaDraft:synthetic-project:"+item))
        return try JSONDecoder().decode(MediaOwnerDraft.self,from:data).note
    }
    private func settle(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() {return}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        XCTFail("Synthetic media decision did not settle")
    }

    func testEveryTypedEditAutosavesWithoutDecisionAndRestoresPerItemFromSavedBytes() async throws {
        let (peer,store,defaults,directory,model)=await fixture()
        peer.calls=[]
        for note in ["R","Re","Redo the landing\nKeep the pause ⏸"] {
            model.draft.note=note
            XCTAssertEqual(try savedNote(defaults.preferences),note,"No save or selection change is needed")
        }
        await model.select("item-b")
        XCTAssertEqual(model.draft.note,"")
        model.draft.note="A different pose"
        XCTAssertEqual(try savedNote(defaults.preferences,item:"item-b"),"A different pose")
        await model.select("item-a")
        XCTAssertEqual(model.draft.note,"Redo the landing\nKeep the pause ⏸")
        XCTAssertEqual(model.item.string("disposition"),"pending")
        XCTAssertFalse(peer.calls.contains {$0.0=="media_decide"})
        XCTAssertEqual(store.projectID,"synthetic-project")

        // A fresh preference object receives only the persisted snapshot. Neither the
        // previous model's draft cache nor the prior preference instance can restore it.
        let restart=isolatedDefaults("MediaNoteRestart")
        for (key,value) in defaults.preferences.dictionaryRepresentation() {restart.preferences.set(value,forKey:key)}
        let reopened=peer.store(restart.preferences,directory)
        let restored=await connectedModel(reopened)
        XCTAssertEqual(restored.draft.note,"Redo the landing\nKeep the pause ⏸")
        await restored.select("item-b")
        XCTAssertEqual(restored.draft.note,"A different pose")
        restored.draft.note=""
        XCTAssertEqual(try savedNote(restart.preferences,item:"item-b"),"","Deleting a note also autosaves")
        XCTAssertFalse(peer.calls.contains {$0.0=="media_decide"})
    }

    func testOldAnimationChoicesMapToNativeActionsAndKeepTypedReasons() {
        let typed="  Shorten the anticipation.\nUse the previous silhouette.  "
        let expected:[MediaAnimationReviewChoice:String]=[.accept:"accepted",.redo:"changes_requested",.otherPose:"changes_requested",.lookAtIt:"needs_look"]
        for choice in MediaAnimationReviewChoice.allCases {
            XCTAssertEqual(choice.mapping(note:typed),MediaOwnerDecisionChoice(disposition:expected[choice]!,note:typed))
        }
        XCTAssertEqual(MediaAnimationReviewChoice.redo.mapping(note:"\n ").note,"Redo")
        XCTAssertEqual(MediaAnimationReviewChoice.otherPose.mapping(note:"").note,"Other pose")
        XCTAssertEqual(MediaAnimationReviewChoice.accept.mapping(note:"").note,"")
        XCTAssertEqual(MediaAnimationReviewChoice.lookAtIt.mapping(note:"").note,"")
        XCTAssertTrue(MediaReviewModel.decisionRequiresNote("changes_requested"))
        XCTAssertTrue(MediaReviewModel.decisionRequiresNote("excluded"))
        XCTAssertFalse(MediaReviewModel.decisionRequiresNote("accepted"))
        XCTAssertFalse(MediaReviewModel.decisionRequiresNote("needs_look"))
    }

    func testChangesRequestedNeedsMeaningfulNoteAndOnePressPreservesItAfterDecisionAndRestart() async throws {
        let (peer,store,defaults,directory,model)=await fixture()
        peer.calls=[]
        model.draft.note=" \n "
        model.decide("changes_requested")
        XCTAssertFalse(peer.calls.contains {$0.0=="media_decide"})
        XCTAssertEqual(model.error,"Enter a note describing the requested changes.")
        XCTAssertFalse(model.hasDecisionNote)
        model.draft.note="Redo the landing"
        XCTAssertTrue(model.hasDecisionNote)
        model.decide("changes_requested")
        try await settle {peer.calls.contains {$0.0=="media_decide"} && !store.busy && !model.loading}
        let decisions=peer.calls.filter {$0.0=="media_decide"}
        XCTAssertEqual(decisions.count,1)
        XCTAssertEqual(decisions[0].1["disposition"] as? String,"changes_requested")
        XCTAssertEqual(decisions[0].1["note"] as? String,"Redo the landing")
        XCTAssertEqual(model.draft.note,"Redo the landing")
        XCTAssertEqual(try savedNote(defaults.preferences),"Redo the landing")
        let reopened=peer.store(defaults.preferences,directory)
        let restored=await connectedModel(reopened)
        XCTAssertEqual(restored.draft.note,"Redo the landing")
    }

    func testEachLegacyChoiceSendsOneExplicitDecisionWithoutClearingTheItemNote() async throws {
        for choice in MediaAnimationReviewChoice.allCases {
            let (peer,store,defaults,_,model)=await fixture()
            peer.calls=[]
            model.decide(choice)
            try await settle {peer.calls.contains {$0.0=="media_decide"} && !store.busy && !model.loading}
            let sent=peer.calls.filter {$0.0=="media_decide"}
            XCTAssertEqual(sent.count,1,choice.rawValue)
            let mapped=choice.mapping(note:"")
            XCTAssertEqual(sent[0].1["disposition"] as? String,mapped.disposition)
            XCTAssertEqual(sent[0].1["note"] as? String,mapped.note.isEmpty ? nil : mapped.note)
            XCTAssertEqual(model.draft.note,mapped.note)
            XCTAssertEqual(try savedNote(defaults.preferences),mapped.note)
            XCTAssertNil(sent[0].1["origin"],"The native authenticated connection supplies owner provenance")
        }
    }

    /// CL-334: every current reference stays visible, while old historical buffers replace.
    func testCurrentImagesCoexistWithinSlotAndInFlightBoundsAndClearOnItemChange() async {
        let (_,store,_,_,model)=await fixture()
        XCTAssertTrue(model.beginImage("reference-1",historical:false))
        XCTAssertTrue(model.beginImage("reference-2",historical:false))
        XCTAssertFalse(model.beginImage("reference-3",historical:false))
        model.endImage();model.endImage()
        for index in 3...8 {
            XCTAssertTrue(model.beginImage("reference-"+String(index),historical:false))
            model.endImage()
        }
        for index in 1...8 {XCTAssertTrue(model.imageIsActive("reference-"+String(index),historical:false))}
        XCTAssertFalse(model.beginImage("reference-9",historical:false))
        XCTAssertTrue(model.beginImage("old-example",historical:true));model.endImage()
        XCTAssertTrue(model.beginImage("new-example",historical:true));model.endImage()
        XCTAssertFalse(model.imageIsActive("old-example",historical:true))
        XCTAssertTrue(model.imageIsActive("new-example",historical:true))
        await model.select("item-b")
        for index in 1...8 {XCTAssertFalse(model.imageIsActive("reference-"+String(index),historical:false))}
        XCTAssertFalse(model.imageIsActive("new-example",historical:true))
        XCTAssertTrue(model.beginImage("next-reference",historical:false));model.endImage()
        XCTAssertEqual(model.imageLoads,0)
        XCTAssertEqual(store.projectID,"synthetic-project")
    }

    func testReplacementTargetOnSameItemReleasesPreviousImageCapacity() async {
        let (peer,store,_,_,model)=await fixture()
        for index in 1...8 {XCTAssertTrue(model.beginImage("old-\(index)",historical:false));model.endImage()}
        peer.target="replacement-target"
        await model.select("item-a")
        for index in 1...8 {
            XCTAssertFalse(model.imageIsActive("old-\(index)",historical:false))
            XCTAssertTrue(model.beginImage("replacement-\(index)",historical:false));model.endImage()
        }
        XCTAssertTrue(model.contextConflict,"Preserved notes still require explicit inspection of the replacement")
        XCTAssertEqual(store.projectID,"synthetic-project")
    }
}
