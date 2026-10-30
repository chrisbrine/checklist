import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

@MainActor final class MediaMixedComparisonTests: XCTestCase {
    func testAnimationStarterDeclaresOneLoopingTakeAndMixedReferenceSlots() throws {
        let raw=MediaTypeSettings.schema(title:"Animation review",starter:"animation_video")
        let parsed=try MediaReviewSchema.parse(raw)
        XCTAssertEqual(parsed.layout.primarySlotID?.rawValue,"take")
        XCTAssertEqual(parsed.layout.referenceSlotIDs.map(\.rawValue),["model_sheet","concept_art","reference"])
        XCTAssertEqual(parsed.slots.map(\.kind),[.video,.image,.image,.video])
        XCTAssertTrue(parsed.layout.loop);XCTAssertNil(parsed.layout.frameRate)
        XCTAssertEqual(parsed.layout.frameRateFieldID?.rawValue,"frame_rate")
    }

    func testOneCandidateProjectsTakeThenEveryMixedReferenceWithReadableRoles() async {
        let defaults=isolatedDefaults("MixedComparison")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:directory)}
        let peer=MediaOwnerSliceTests.Peer()
        peer.schema=MediaTypeSettings.schema(title:"Animation review",starter:"animation_video")
        peer.types=[["id":"animation","title":"Animation review","enabled":true]]
        let store=peer.store(defaults.preferences,directory),model=store.mediaReview
        await model.connect(store:store);model.roundID="round";await model.refresh()
        let slots:[MediaValues]=[["slot_id":"reference","media_kind":"video"],["slot_id":"concept_art","media_kind":"image"],
            ["slot_id":"take","media_kind":"video"],["slot_id":"model_sheet","media_kind":"image"]]
        let candidate=Record(values:["id":"one-candidate","slots":slots])
        model.item=Record(values:["id":"item","title":"Walk north","candidates":[candidate.values]])
        let layout=model.schema["layout"] as? MediaValues ?? [:]
        let projected=MediaComparisonLabels.orderedSlots(candidate,layout:layout)
        XCTAssertEqual(MediaComparisonLabels.choices(item:model.item,definitions:model.slots).count,1)
        XCTAssertEqual(projected.map {$0.string("slot_id")},["take","model_sheet","concept_art","reference"])
        let original=Record(values:["availability":"available","size":100])
        for slot in projected {
            let id=slot.string("slot_id"),kind=model.slots.first {$0.id==id}!.string("kind")
            XCTAssertEqual(MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:kind),kind=="image" ? .image : .playback("video"))
            XCTAssertEqual(MediaComparisonLabels.role(slotID:id,candidateIndex:0,layout:layout,historical:false),id=="take" ? "Candidate 1" : "Reference")
        }
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"reference",candidateIndex:0,layout:layout,historical:true),"Approved example · Reference")
        XCTAssertEqual(MediaComparisonLabels.referenceSlotIDs(["reference_slot_id":"legacy"]),["legacy"])
        XCTAssertFalse(peer.calls.contains {$0.0=="media_decide"})
    }

    func testCurrentPlaybackSettingsNeverRetargetHistoricalExamplesOrReferenceVideos() {
        let layout:MediaValues=["primary_slot_id":"take","loop":true,"frame_rate":12]
        let current=MediaComparisonLabels.playbackSettings(slotID:"take",layout:layout,historical:false)
        XCTAssertTrue(current.loop);XCTAssertEqual(current.frameRate,12)
        for (slot,historical) in [("take",true),("reference",false)] {
            let settings=MediaComparisonLabels.playbackSettings(slotID:slot,layout:layout,historical:historical)
            XCTAssertFalse(settings.loop);XCTAssertNil(settings.frameRate)
        }
    }
}
