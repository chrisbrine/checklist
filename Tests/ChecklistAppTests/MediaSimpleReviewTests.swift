import XCTest
/// A scoped import: only the publisher protocol, because Combine also declares `Record`.
import protocol Combine.Publisher
import ChecklistCore
import ChecklistIPC
@testable import ChecklistApp

@MainActor private final class SimpleTake: MediaTakeControl {
    var plays=0,pauses=0,unloads=0
    func play() {plays+=1}
    func pause() {pauses+=1}
    func unload() {unloads+=1}
}

/// CL-421. Mock rows, items and take controls only. No native app, service, keychain or decoder.
@MainActor final class MediaSimpleReviewTests: XCTestCase {
    private let directions=["N","E","SE"]
    private func schema() -> MediaValues {MediaTypeSettings.schema(title:"Animation",starter:"animation_video")}
    private func header() -> Record {
        Record(values:["id":"round","state":"open","revision":3,"observed_context_token":"context","manifest":["id":"manifest","digest":"digest"],"attention":[],"type_revision":["schema":schema()]])
    }
    private func metadata(_ direction: String) -> MediaValues {["character":"Hero","animation_label":"walk_cycle","direction":direction,"take":"2","frame_rate":12]}
    private func row(_ direction: String,disposition: String = "pending",revision: Int = 2) -> Record {
        Record(values:["id":"item-"+direction,"title":"hero__walk_cycle__"+direction+".mp4","disposition":disposition,"revision":revision,"metadata":metadata(direction)])
    }
    private func item(_ direction: String,disposition: String = "pending",target: String? = nil) -> Record {
        Record(values:["id":"item-"+direction,"title":"hero__walk_cycle__"+direction+".mp4","revision":2,"published":true,"disposition":disposition,
            "target":["id":target ?? "target-"+direction,"review_basis_signature":"basis-"+direction,"metadata":metadata(direction),"candidate_ids":["candidate-"+direction]],
            "candidates":[["id":"candidate-"+direction,"slots":[]]],"originals":[]])
    }
    private func take(_ key: String,control: SimpleTake) -> MediaPreparedTake {
        .init(key:key,label:key,kind:"video",ids:[:],control:control,measurement:.init(copyMilliseconds:0,probeMilliseconds:0,bytes:1024,facts:.init(durationSeconds:1,width:64,height:64,frames:8,hasVideo:true,hasAudio:false)))
    }
    /// Three loaded cards, each with a playing fake take.
    private func loadedReview() async -> (MediaSimpleReviewModel,[String: SimpleTake]) {
        let review=MediaSimpleReviewModel()
        review.update(header:header())
        review.sync(scope:"project:round",rows:directions.map {row($0)},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in self.item(String(id.dropFirst(5)))}
        var controls: [String: SimpleTake]=[:]
        for card in review.orderedCards {
            let control=SimpleTake();controls[card.id]=control
            XCTAssertTrue(review.playback.admit(take(card.key,control:control)));review.playback.play(card.key)
        }
        return (review,controls)
    }

    func testLabelIsBuiltFromFieldValuesInPlainWords() {
        XCTAssertEqual(MediaTakeLabel.text(metadata("SE")),"Hero · Walk cycle · South-east · Take 2")
        let words=["N":"North","NE":"North-east","E":"East","SE":"South-east","S":"South","SW":"South-west","W":"West","NW":"North-west"]
        for (code,word) in words {XCTAssertEqual(MediaTakeLabel.direction(code),word);XCTAssertEqual(MediaTakeLabel.direction(code.lowercased()),word)}
        XCTAssertEqual(MediaTakeLabel.direction("south_east"),"South-east")
        XCTAssertEqual(MediaTakeLabel.direction("north-west"),"North-west")
        XCTAssertEqual(MediaTakeLabel.take("take_3"),"Take 3")
        XCTAssertEqual(MediaTakeLabel.take(NSNumber(value:4)),"Take 4")
        XCTAssertEqual(MediaTakeLabel.take("b"),"Take B")
        XCTAssertEqual(MediaTakeLabel.group(metadata("N")),"Hero · Walk cycle")
        let label=MediaTakeLabel.text(["character":"hero__knight","animation_label":"idle","direction":"W","take":"1"])
        XCTAssertEqual(label,"Hero knight · Idle · West · Take 1")
        for token in ["animation_label","character:","direction:","__",".mp4"] {XCTAssertFalse(label.contains(token),token)}
    }
    func testMissingValuesShowStatedFallbacks() {
        XCTAssertEqual(MediaTakeLabel.text([:]),"Character not set · Action not set · Direction not set · Take not set")
        XCTAssertEqual(MediaTakeLabel.text(["character":"  ","animation_label":NSNull(),"direction":"","take":"\n"]),"Character not set · Action not set · Direction not set · Take not set")
        XCTAssertEqual(MediaTakeLabel.text(["character":"Hero","direction":"S"]),"Hero · Action not set · South · Take not set")
        // A card label never falls back to the item title (a file name).
        let card=MediaDirectionCard(item:Record(values:["id":"x","title":"hero__walk__S.mp4"]),header:header(),draft:MediaOwnerDraft())
        XCTAssertEqual(card.label,"Character not set · Action not set · Direction not set · Take not set")
    }
    func testUnchangedRefreshKeepsIdentitiesOrderAndPlayers() async {
        let (review,controls)=await loadedReview()
        let cards=review.orderedCards.map(ObjectIdentifier.init),order=review.order
        let takes=review.orderedCards.map {ObjectIdentifier(review.playback.takes[$0.key]!)}
        var published=0
        let watch=review.objectWillChange.sink {published+=1}
        var reads=0
        for _ in 0..<3 {
            // Each refresh returns new Record values that are equal to the shown ones.
            let changed=review.sync(scope:"project:round",rows:directions.map {row($0)},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
            review.update(header:header())
            await review.readStale {id in reads+=1;return self.item(String(id.dropFirst(5)))}
            XCTAssertTrue(changed.isEmpty)
        }
        watch.cancel()
        XCTAssertEqual(published,0,"An unchanged refresh must publish nothing")
        XCTAssertEqual(reads,0)
        XCTAssertEqual(review.order,order)
        XCTAssertEqual(review.orderedCards.map(ObjectIdentifier.init),cards)
        XCTAssertEqual(review.orderedCards.map {ObjectIdentifier(review.playback.takes[$0.key]!)},takes)
        XCTAssertEqual(review.playback.playingKeys,Set(review.orderedCards.map(\.key)))
        XCTAssertTrue(controls.values.allSatisfy {$0.plays==1 && $0.pauses==0 && $0.unloads==0},"A playing take must not restart or stop")
    }
    func testChangedItemUpdatesOnlyThatCardInPlace() async {
        let (review,controls)=await loadedReview()
        let before=Dictionary(uniqueKeysWithValues:review.orderedCards.map {($0.id,($0,ObjectIdentifier(review.playback.takes[$0.key]!)))})
        let rows=directions.map {$0=="E" ? row($0,disposition:"needs_look",revision:3) : row($0)}
        let changed=review.sync(scope:"project:round",rows:rows,draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        XCTAssertEqual(changed,["item-E"])
        var reads: [String]=[]
        await review.readStale {id in reads.append(id);return self.item(String(id.dropFirst(5)),disposition:id=="item-E" ? "needs_look" : "pending")}
        XCTAssertEqual(reads,["item-E"])
        XCTAssertEqual(review.order,directions.map {"item-"+$0})
        for card in review.orderedCards {
            XCTAssertTrue(card === before[card.id]!.0)
            XCTAssertEqual(ObjectIdentifier(review.playback.takes[card.key]!),before[card.id]!.1)
            XCTAssertEqual(card.item.string("disposition"),card.id=="item-E" ? "needs_look" : "pending")
        }
        XCTAssertTrue(controls.values.allSatisfy {$0.plays==1 && $0.unloads==0})
        // New material for one item replaces only that item's take.
        review.sync(scope:"project:round",rows:directions.map {$0=="SE" ? row($0,revision:4) : $0=="E" ? row($0,disposition:"needs_look",revision:3) : row($0)},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in self.item("SE",target:"target-SE-2")}
        XCTAssertEqual(controls["item-SE"]?.unloads,1)
        XCTAssertEqual(controls["item-N"]?.unloads,0);XCTAssertEqual(controls["item-E"]?.unloads,0)
        // A removed item releases its card and take; the others stay.
        review.sync(scope:"project:round",rows:[row("N"),row("E",disposition:"needs_look",revision:3)],draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        XCTAssertEqual(review.order,["item-N","item-E"])
        XCTAssertTrue(review.cards["item-N"] === before["item-N"]!.0)
    }
    func testCardOffersThreeDecisionsWithNoDirectionGridStep() async throws {
        XCTAssertEqual(MediaSimpleLayout.decisions.map(\.title),["Accept","Changes requested","Needs look"])
        XCTAssertEqual(MediaSimpleLayout.decisions.map(\.disposition),["accepted","changes_requested","needs_look"])
        XCTAssertTrue(MediaSimpleLayout.usesCards(schema()))
        XCTAssertFalse(MediaSimpleLayout.usesCards(MediaTypeSettings.schema(title:"Video",starter:"video")))
        let (review,_)=await loadedReview()
        let card=try XCTUnwrap(review.cards["item-SE"])
        XCTAssertTrue(card.basisMatches,"A loaded card is ready to decide without opening the direction grid")
        let accept=try card.decisionRequest("accepted")
        XCTAssertEqual(accept["disposition"] as? String,"accepted");XCTAssertEqual(accept["winner_id"] as? String,"candidate-SE")
        XCTAssertEqual((accept["items"] as? [MediaValues])?.first?["item_id"] as? String,"item-SE")
        XCTAssertEqual(try card.decisionRequest("needs_look")["disposition"] as? String,"needs_look")
        XCTAssertThrowsError(try card.decisionRequest("changes_requested"),"Changes requested still needs the owner note")
        card.draft.note="Feet slide"
        XCTAssertEqual(try card.decisionRequest("changes_requested")["note"] as? String,"Feet slide")
    }
    func testAutoplayFollowsLayoutReduceMotionAndOwnerPause() {
        let layout=schema()["layout"] as? MediaValues ?? [:]
        XCTAssertNil(layout["autoplay"],"Adopted types have no autoplay key; the starter default applies")
        XCTAssertTrue(MediaSimpleLayout.autoplay(layout))
        XCTAssertTrue(MediaSimpleLayout.startsPlaying(layout:layout,reduceMotion:false,pausedByOwner:false))
        XCTAssertFalse(MediaSimpleLayout.startsPlaying(layout:layout,reduceMotion:true,pausedByOwner:false),"Reduce Motion shows a still frame")
        XCTAssertFalse(MediaSimpleLayout.startsPlaying(layout:layout,reduceMotion:false,pausedByOwner:true))
        var off=layout;off["autoplay"]=false
        XCTAssertFalse(MediaSimpleLayout.autoplay(off))
        XCTAssertFalse(MediaSimpleLayout.autoplay(["kind":"video_compare"]))
        let review=MediaSimpleReviewModel()
        review.pauseAll();XCTAssertTrue(review.pausedByOwner)
        review.playAll();XCTAssertFalse(review.pausedByOwner)
    }
    func testReviewModelAssignsOnlyChangedLists() {
        var rows=[row("N"),row("E")]
        XCTAssertFalse(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E")]))
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E",disposition:"accepted")]))
        XCTAssertEqual(rows[1].string("disposition"),"accepted")
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("E",disposition:"accepted"),row("N")]),"A new order is a change")
    }
}
