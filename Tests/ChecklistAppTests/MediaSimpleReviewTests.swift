import XCTest
import AVKit
/// A scoped import: only the publisher protocol, because Combine also declares `Record`.
import protocol Combine.Publisher
import ChecklistCore
import ChecklistIPC
@testable import ChecklistApp

@MainActor private final class SimpleTake: MediaTakeControl {
    var plays=0,pauses=0,unloads=0
    var onUnload: () -> Void = {}
    func play() {plays+=1}
    func pause() {pauses+=1}
    func unload() {unloads+=1;onUnload()}
}

/// Records each fake preparation and release, by item ID, in order.
@MainActor private final class TakeLog {
    var prepared: [String]=[]
    var released: [String]=[]
    var controls: [String: SimpleTake]=[:]
    var slots: [String: String]=[:]
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
    // MARK: Take window (CL-421 rework: preload before a card shows, keep after it leaves)

    private func name(_ index: Int) -> String {String(format:"c%02d",index)}
    /// `count` loaded cards in list order, with a fake take source that logs each preparation.
    /// A video reference player logs as "<item ID>#ref".
    private func windowReview(_ count: Int,make: ((String) -> Record)? = nil) async -> (MediaSimpleReviewModel,TakeLog) {
        let review=MediaSimpleReviewModel(),log=TakeLog(),schema=schema()
        review.update(header:header())
        review.sync(scope:"project:round",rows:(0..<count).map {row(name($0))},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in make?(String(id.dropFirst(5))) ?? self.item(String(id.dropFirst(5)))}
        review.source = .init(schema:{_ in schema},prepare:{card,_,player,_ in
            let name=card.id+(player.isReference ? "#ref" : "")
            log.prepared.append(name);log.slots[name]=player.slotID ?? "take"
            let control=SimpleTake();control.onUnload={log.released.append(name)}
            log.controls[name]=control
            return self.take(player.key,control:control)
        })
        return (review,log)
    }
    private func card(_ review: MediaSimpleReviewModel,_ index: Int) -> MediaDirectionCard {review.cards["item-"+name(index)]!}
    private func show(_ review: MediaSimpleReviewModel,_ indices: [Int],reduceMotion: Bool = false) {
        for index in indices {review.cardShown(card(review,index),reduceMotion:reduceMotion)}
    }
    private func hide(_ review: MediaSimpleReviewModel,_ indices: [Int]) {for index in indices {review.cardLeft(card(review,index))}}
    private func prepared(_ review: MediaSimpleReviewModel) -> [Int] {review.order.indices.filter {review.playback.takes[card(review,$0).key] != nil}}
    private func playing(_ review: MediaSimpleReviewModel) -> [Int] {review.order.indices.filter {review.playback.playingKeys.contains(card(review,$0).key)}}
    private func ids(_ indices: some Sequence<Int>) -> [String] {indices.map {"item-"+name($0)}}

    func testCardJustOutsideTheVisibleRangeIsPreparedButNotPlaying() async {
        XCTAssertEqual(MediaSimpleReviewModel.preloadCards,6)
        let (review,log)=await windowReview(20)
        show(review,[0,1,2])
        await review.settle()
        XCTAssertEqual(prepared(review),Array(0...8),"The visible cards and six cards after them have a prepared take")
        XCTAssertEqual(log.prepared,ids(0...8),"Visible cards first, then the nearest")
        XCTAssertEqual(playing(review),[0,1,2],"Only visible cards play")
        for index in 3...8 {
            let control=log.controls["item-"+name(index)]!
            XCTAssertEqual(control.plays,0,"Card \(index) is prepared but must not play");XCTAssertEqual(control.unloads,0)
        }
        // Reduce Motion: the visible card is prepared and keeps its still frame.
        let (still,stillLog)=await windowReview(4)
        show(still,[0],reduceMotion:true)
        await still.settle()
        XCTAssertEqual(prepared(still),[0,1,2,3]);XCTAssertTrue(playing(still).isEmpty)
        XCTAssertEqual(stillLog.controls.values.map(\.plays).reduce(0,+),0)
    }
    func testCardThatLeavesTheScreenInsideTheWindowKeepsItsTake() async {
        let (review,log)=await windowReview(20)
        show(review,[0,1,2])
        await review.settle()
        let first=review.playback.takes[card(review,0).key].map(ObjectIdentifier.init)
        // Scroll down by one card: card 0 leaves the screen, card 3 comes on screen.
        show(review,[3]);hide(review,[0])
        await review.settle()
        let control=log.controls["item-c00"]!
        XCTAssertEqual(control.unloads,0,"A card that leaves the screen but stays in the window keeps its take")
        XCTAssertGreaterThanOrEqual(control.pauses,1)
        XCTAssertEqual(playing(review),[1,2,3])
        XCTAssertEqual(log.controls["item-c03"]?.plays,1,"A preloaded card plays at once when it comes on screen")
        XCTAssertEqual(prepared(review),Array(0...9),"The window moved one card down")
        // Scroll back: card 0 plays its kept take, with no new preparation.
        show(review,[0]);hide(review,[3])
        await review.settle()
        XCTAssertEqual(log.prepared.filter {$0=="item-c00"}.count,1)
        XCTAssertEqual(review.playback.takes[card(review,0).key].map(ObjectIdentifier.init),first)
        XCTAssertEqual(control.plays,2);XCTAssertEqual(playing(review),[0,1,2])
        XCTAssertEqual(log.controls["item-c03"]?.unloads,0)
        XCTAssertEqual(log.released,["item-c09"],"Only card 9 left the window (now cards 0 to 8)")
        // When no card is on screen for a moment, the window and every take stay.
        hide(review,[0,1,2])
        await review.settle()
        XCTAssertEqual(prepared(review),Array(0...8));XCTAssertTrue(playing(review).isEmpty);XCTAssertEqual(log.released,["item-c09"])
    }
    func testCardThatLeavesTheWindowIsReleased() async {
        let (review,log)=await windowReview(20)
        show(review,[0])
        await review.settle()
        XCTAssertEqual(prepared(review),Array(0...6))
        // Jump to card 10: the window is now cards 4 to 16.
        show(review,[10]);hide(review,[0])
        await review.settle()
        XCTAssertEqual(Set(log.released),Set(ids(0...3)),"Cards 0 to 3 left the window")
        for index in 0...3 {XCTAssertEqual(log.controls["item-"+name(index)]?.unloads,1)}
        for index in 4...6 {XCTAssertEqual(log.controls["item-"+name(index)]?.unloads,0)}
        XCTAssertEqual(prepared(review),Array(4...16))
        XCTAssertEqual(log.prepared.filter {$0=="item-c05"}.count,1,"A card that stays in the window is not prepared again")
        // A removed item releases its take; a changed target replaces only that take.
        review.sync(scope:"project:round",rows:(0..<20).filter {$0 != 12}.map {row(name($0))},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        XCTAssertEqual(log.controls["item-c12"]?.unloads,1)
        let oldTake=log.controls["item-c11"]!
        review.sync(scope:"project:round",rows:(0..<20).filter {$0 != 12}.map {$0==11 ? row(name($0),revision:5) : row(name($0))},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in self.item(String(id.dropFirst(5)),target:"target-new")}
        await review.settle()
        XCTAssertEqual(oldTake.unloads,1,"A changed target releases the old take")
        XCTAssertEqual(log.prepared.filter {$0=="item-c11"}.count,2,"The new target gets a new take")
        XCTAssertEqual(log.controls["item-c11"]?.unloads,0)
        XCTAssertEqual(log.controls["item-c10"]?.unloads,0)
    }
    func testPreparedBoundReleasesTheFarthestTakeFirst() async {
        XCTAssertEqual(MediaSimpleReviewModel.preparedTakes,24)
        let (review,log)=await windowReview(20)
        review.preparedLimit=5
        show(review,[10])
        await review.settle()
        XCTAssertEqual(log.prepared,ids([10,9,11,8,12]),"Nearest first; the bound stops the preparation")
        XCTAssertTrue(log.released.isEmpty,"No take is released for a card that is not nearer")
        // Scroll down by two cards: the visible card is now 12.
        show(review,[12]);hide(review,[10])
        await review.settle()
        XCTAssertEqual(log.released,ids([8,9]),"The farthest take goes first")
        XCTAssertEqual(prepared(review),Array(10...14))
        // The real bound: thirteen visible cards make a 25-card window, and 24 takes are prepared.
        let (wide,_)=await windowReview(40)
        show(wide,Array(10...22))
        await wide.settle()
        XCTAssertEqual(wide.playback.takes.count,24)
        XCTAssertEqual(prepared(wide).count,24);XCTAssertTrue(Set(10...22).isSubset(of:prepared(wide)))
    }
    func testPlayBudgetStaysEight() async {
        XCTAssertEqual(MediaSimpleReviewModel.playingTakes,8)
        let (review,log)=await windowReview(30)
        show(review,Array(0...11))
        await review.settle()
        XCTAssertEqual(playing(review),Array(0...7),"Twelve visible cards: only eight play")
        // The owner's Play on a ninth card pauses the playing take farthest from it.
        review.toggle(card(review,11))
        XCTAssertEqual(playing(review),Array(1...7)+[11])
        XCTAssertEqual(log.controls["item-c00"]?.pauses,1)
        review.pauseAll()
        XCTAssertTrue(playing(review).isEmpty);XCTAssertTrue(review.pausedByOwner)
        show(review,[0])
        XCTAssertTrue(playing(review).isEmpty,"The owner's Pause all keeps a card that comes on screen still")
        review.playAll()
        XCTAssertEqual(playing(review),Array(0...7))
        XCTAssertLessThanOrEqual(review.playback.playingKeys.count,8)
        XCTAssertFalse(review.playback.play(card(review,9).key),"The take cache refuses a ninth playing take")
    }
    // MARK: Reference beside the take (CL-421 rework: an earlier-take video reference plays beside the take)

    /// An item with a take and, on request, an image reference (model sheet) and an earlier-take
    /// video reference. `videoAvailability` sets the earlier take's original availability.
    private func referenceItem(_ direction: String,image: Bool = false,video: Bool = false,videoAvailability: String = "available",videoReference: String? = nil) -> Record {
        var slots: [MediaValues]=[["slot_id":"take","attachment_id":"a-take-"+direction,"media_kind":"video","sha256":"t"]]
        var originals: [MediaValues]=[["attachment_id":"a-take-"+direction,"reference_id":"r-take-"+direction,"availability":"available","size":1024]]
        if image {
            slots.append(["slot_id":"model_sheet","attachment_id":"a-sheet-"+direction,"media_kind":"image","sha256":"s"])
            originals.append(["attachment_id":"a-sheet-"+direction,"reference_id":"r-sheet-"+direction,"availability":"available","size":1024])
        }
        if video {
            slots.append(["slot_id":"reference","attachment_id":"a-earlier-"+direction,"media_kind":"video","sha256":"e"])
            originals.append(["attachment_id":"a-earlier-"+direction,"reference_id":videoReference ?? "r-earlier-"+direction,"availability":videoAvailability,"size":1024])
        }
        var values=item(direction).values
        values["candidates"]=[["id":"candidate-"+direction,"slots":slots]];values["originals"]=originals
        return Record(values:values)
    }
    private var layout: MediaValues {schema()["layout"] as? MediaValues ?? [:]}
    private func videoItem(_ direction: String) -> Record {referenceItem(direction,video:true)}

    func testVideoOnlyReferenceIsChosenAndPrepared() async throws {
        XCTAssertEqual(MediaComparisonLabels.referenceSlotIDs(layout),["model_sheet","concept_art","reference"])
        let reference=try XCTUnwrap(MediaSimpleReviewModel.reference(item:videoItem("S"),layout:layout))
        XCTAssertEqual(reference.kind,"video");XCTAssertEqual(reference.slot.string("slot_id"),"reference")
        XCTAssertEqual(reference.original.string("reference_id"),"r-earlier-S")
        let (review,log)=await windowReview(1,make:videoItem)
        let first=card(review,0)
        let player=try XCTUnwrap(review.referencePlayer(first))
        XCTAssertEqual(player.slotID,"reference");XCTAssertEqual(review.keys(first),[first.key,player.key])
        show(review,[0])
        await review.settle()
        XCTAssertEqual(log.prepared,["item-c00","item-c00#ref"],"The take first, then its earlier take, through the same preparation")
        XCTAssertEqual(log.slots["item-c00#ref"],"reference");XCTAssertEqual(log.slots["item-c00"],"take")
        XCTAssertNotNil(review.playback.takes[player.key])
        XCTAssertEqual(review.playback.playingKeys,[first.key,player.key],"Both play beside each other")
        XCTAssertEqual(log.controls["item-c00#ref"]?.plays,1)
        // The rate rule is the take's: the item's frame rate, for every player that the preparation makes.
        let rate=MediaDirectionTakePreparation.playbackSettings(first,layout:layout)
        XCTAssertTrue(rate.loop);XCTAssertEqual(rate.frameRate,12)
        // An unchanged refresh keeps both players; a changed earlier take replaces only the reference.
        review.apply(videoItem(name(0)),to:first)
        XCTAssertEqual(log.controls["item-c00"]?.unloads,0);XCTAssertEqual(log.controls["item-c00#ref"]?.unloads,0)
        let oldReference=try XCTUnwrap(log.controls["item-c00#ref"])
        review.apply(referenceItem(name(0),video:true,videoReference:"r-earlier-2"),to:first)
        await review.settle()
        XCTAssertEqual(oldReference.unloads,1);XCTAssertEqual(log.controls["item-c00"]?.unloads,0)
        XCTAssertEqual(log.prepared,["item-c00","item-c00#ref","item-c00#ref"])
    }
    func testImageAndVideoReferencePicksTheEarlierTakeVideo() throws {
        let both=try XCTUnwrap(MediaSimpleReviewModel.reference(item:referenceItem("S",image:true,video:true),layout:layout))
        XCTAssertEqual(both.kind,"video","The owner compares takes: the earlier take wins over the model sheet that comes first in layout order")
        XCTAssertEqual(both.slot.string("slot_id"),"reference")
        // An unavailable earlier take does not count: the first image shows.
        let missing=try XCTUnwrap(MediaSimpleReviewModel.reference(item:referenceItem("S",image:true,video:true,videoAvailability:"missing"),layout:layout))
        XCTAssertEqual(missing.kind,"image");XCTAssertEqual(missing.slot.string("slot_id"),"model_sheet")
    }
    func testImageOnlyReferenceStillShowsTheImage() async throws {
        let reference=try XCTUnwrap(MediaSimpleReviewModel.reference(item:referenceItem("S",image:true),layout:layout))
        XCTAssertEqual(reference.kind,"image");XCTAssertEqual(reference.slot.string("slot_id"),"model_sheet")
        XCTAssertEqual(reference.original.string("reference_id"),"r-sheet-S")
        let (review,log)=await windowReview(1,make:{self.referenceItem($0,image:true)})
        XCTAssertNil(review.referencePlayer(card(review,0)),"An image reference needs no player")
        show(review,[0])
        await review.settle()
        XCTAssertEqual(log.prepared,["item-c00"]);XCTAssertEqual(review.playback.takes.count,1)
    }
    func testNoReferenceShowsPlainFallback() async {
        XCTAssertEqual(MediaSimpleReviewModel.noReference,"No reference")
        XCTAssertNil(MediaSimpleReviewModel.reference(item:item("S"),layout:layout))
        XCTAssertNil(MediaSimpleReviewModel.reference(item:referenceItem("S"),layout:layout),"The take itself is not a reference")
        XCTAssertNil(MediaSimpleReviewModel.reference(item:referenceItem("S",video:true,videoAvailability:"cleaned"),layout:layout))
        let (review,_)=await windowReview(1)
        XCTAssertEqual(review.keys(card(review,0)),[card(review,0).key])
    }
    func testCardWithVideoReferenceUsesTwoOfThePreparedAndPlayingBounds() async {
        let (review,log)=await windowReview(20,make:videoItem)
        review.preparedLimit=6
        show(review,[10])
        await review.settle()
        XCTAssertEqual(log.prepared,["item-c10","item-c10#ref","item-c09","item-c09#ref","item-c11","item-c11#ref"],"Three cards hold six players")
        XCTAssertEqual(review.playback.takes.count,6);XCTAssertEqual(review.playback.playingKeys.count,2)
        // The real bounds: twelve cards in the window hold 24 players; eight players play, so four cards.
        let (wide,wideLog)=await windowReview(30,make:videoItem)
        show(wide,Array(0...5))
        await wide.settle()
        XCTAssertEqual(wide.playback.takes.count,MediaSimpleReviewModel.preparedTakes)
        XCTAssertEqual(Set(wideLog.prepared.map {String($0.prefix(8))}),Set(ids(0...11)))
        XCTAssertEqual(wide.playback.playingKeys.count,MediaSimpleReviewModel.playingTakes)
        XCTAssertEqual(wide.order.indices.filter {wide.isPlaying(card(wide,$0))},[0,1,2,3])
        for index in 0...3 {XCTAssertTrue(wide.keys(card(wide,index)).allSatisfy {wide.playback.playingKeys.contains($0)})}
        // The owner's Play on card 5 pauses both players of the farthest card (card 0).
        wide.toggle(card(wide,5))
        XCTAssertEqual(wide.order.indices.filter {wide.isPlaying(card(wide,$0))},[1,2,3,5])
        XCTAssertEqual(wideLog.controls["item-c00"]?.pauses,1);XCTAssertEqual(wideLog.controls["item-c00#ref"]?.pauses,1)
        XCTAssertEqual(wide.playback.playingKeys.count,8)
    }
    func testPlayPauseAndPauseAllActOnBothPlayers() async {
        let (review,log)=await windowReview(3,make:videoItem)
        show(review,[0])
        await review.settle()
        let take=log.controls["item-c00"]!,reference=log.controls["item-c00#ref"]!
        XCTAssertEqual(take.plays,1);XCTAssertEqual(reference.plays,1)
        review.toggle(card(review,0))
        XCTAssertFalse(review.isPlaying(card(review,0)));XCTAssertEqual(take.pauses,1);XCTAssertEqual(reference.pauses,1)
        review.toggle(card(review,0))
        XCTAssertEqual(review.playback.playingKeys,Set(review.keys(card(review,0))));XCTAssertEqual(take.plays,2);XCTAssertEqual(reference.plays,2)
        review.pauseAll()
        XCTAssertTrue(review.playback.playingKeys.isEmpty);XCTAssertEqual(reference.pauses,2)
        review.playAll()
        XCTAssertEqual(review.playback.playingKeys,Set(review.keys(card(review,0))))
        // A card that leaves the screen pauses both players and keeps them prepared.
        hide(review,[0])
        XCTAssertTrue(review.playback.playingKeys.isEmpty);XCTAssertEqual(take.unloads,0);XCTAssertEqual(reference.unloads,0)
        // Reduce Motion: both stay on the still first frame until Play, then both play.
        let (still,stillLog)=await windowReview(2,make:videoItem)
        show(still,[0],reduceMotion:true)
        await still.settle()
        XCTAssertEqual(still.playback.takes.count,4);XCTAssertTrue(still.playback.playingKeys.isEmpty)
        XCTAssertEqual(stillLog.controls.values.map(\.plays).reduce(0,+),0)
        still.toggle(card(still,0))
        XCTAssertEqual(still.playback.playingKeys,Set(still.keys(card(still,0))))
    }
    // MARK: Visible cards from frames (CL-421 rework 421d: autoplay after scrolling)

    /// Frames of a three-column grid in the scroll view's coordinates. Row `r` starts at
    /// `r * rowHeight - offset`. `rows` limits the cells that a lazy grid still lays out.
    private func gridFrames(_ review: MediaSimpleReviewModel,offset: CGFloat,rowHeight: CGFloat = 300,rows: ClosedRange<Int>? = nil) -> [String: CGRect] {
        var frames: [String: CGRect]=[:]
        for (index,id) in review.order.enumerated() where rows?.contains(index/3) ?? true {
            frames[id]=CGRect(x:CGFloat(index%3)*400,y:CGFloat(index/3)*rowHeight-offset,width:390,height:rowHeight-10)
        }
        return frames
    }
    private func playingCards(_ review: MediaSimpleReviewModel) -> [Int] {review.order.indices.filter {review.isPlaying(card(review,$0))}}
    private func fullyPlaying(_ review: MediaSimpleReviewModel,_ index: Int) -> Bool {review.keys(card(review,index)).allSatisfy {review.playback.playingKeys.contains($0)}}

    func testVisibleOrderUsesFramesNearestTheMiddleFirst() {
        let frames=["a":CGRect(x:0,y:-400,width:100,height:290),"b":CGRect(x:0,y:-100,width:100,height:290),"c":CGRect(x:0,y:300,width:100,height:290),
                    "d":CGRect(x:400,y:300,width:100,height:290),"e":CGRect(x:0,y:700,width:100,height:290),"f":CGRect(x:0,y:600,width:100,height:0)]
        XCTAssertEqual(MediaSimpleReviewModel.visibleOrder(frames:frames,viewport:700),["c","d","b"],"Off-screen cells and empty frames are not visible; nearest the middle first, then left to right")
        XCTAssertEqual(MediaSimpleReviewModel.visibleOrder(frames:frames,viewport:0),[])
    }
    /// The runner's sequence: the top row plays, then the view scrolls two pages and one page. The
    /// lazy grid first keeps the old cells (their frames move off screen; no leave report), then
    /// drops them (no frame at all). The budget frees and each newly visible card plays its take
    /// and its earlier-take video reference by itself.
    func testScrollMovesTheVisibleCardsWithoutLeaveReportsAndNewCardsPlay() async {
        let (review,log)=await windowReview(13,make:videoItem)
        review.updateViewport(height:300)
        review.updateFrames(gridFrames(review,offset:0))
        await review.settle()
        XCTAssertEqual(review.priority,ids(0...2));XCTAssertEqual(playingCards(review),[0,1,2])
        for index in 0...2 {XCTAssertTrue(fullyPlaying(review,index))}
        // Two pages down. The old cells keep a frame above the visible area.
        review.updateFrames(gridFrames(review,offset:600))
        await review.settle()
        XCTAssertEqual(review.priority,ids(6...8))
        XCTAssertEqual(playingCards(review),[6,7,8],"The cards that scrolled off free the budget with no leave report")
        for index in 6...8 {XCTAssertTrue(fullyPlaying(review,index),"Card \(index) plays its take and its video reference")}
        XCTAssertEqual(review.playback.playingKeys.count,6)
        XCTAssertGreaterThanOrEqual(log.controls["item-c00"]?.pauses ?? 0,1)
        // One page down. The lazy grid dropped the cells of rows 0 and 1: they report no frame.
        review.updateFrames(gridFrames(review,offset:900,rows:2...4))
        await review.settle()
        XCTAssertEqual(playingCards(review),[9,10,11])
        for index in 9...11 {
            XCTAssertTrue(fullyPlaying(review,index))
            XCTAssertGreaterThanOrEqual(log.controls["item-"+name(index)+"#ref"]?.plays ?? 0,1,"The earlier take of card \(index) plays beside its take")
        }
        // A little more: the last row comes into view too. Four cards with references fill the budget.
        review.updateFrames(gridFrames(review,offset:1000,rows:2...4))
        await review.settle()
        XCTAssertEqual(playingCards(review),[9,10,11,12]);XCTAssertEqual(review.playback.playingKeys.count,MediaSimpleReviewModel.playingTakes)
        XCTAssertTrue(fullyPlaying(review,12))
    }
    /// The old model played a visible card only when it was shown or when its player became ready.
    /// A card refused at the budget stayed still after the budget freed.
    func testVisibleCardRefusedAtTheBudgetPlaysWhenTheBudgetFrees() async {
        let (review,log)=await windowReview(10,make:videoItem)
        show(review,[0,1,2,3])
        await review.settle()
        XCTAssertEqual(playingCards(review),[0,1,2,3])
        // The next card comes on screen before the first one leaves (a scroll step).
        show(review,[4])
        await review.settle()
        XCTAssertNotNil(review.playback.takes[card(review,4).key]);XCTAssertFalse(review.isPlaying(card(review,4)),"No budget yet: still frame with Play")
        hide(review,[0])
        XCTAssertEqual(playingCards(review),[1,2,3,4],"The freed budget goes to the waiting visible card")
        XCTAssertTrue(fullyPlaying(review,4))
        XCTAssertEqual(log.controls["item-c04"]?.plays,1);XCTAssertEqual(log.controls["item-c04#ref"]?.plays,1)
    }
    func testOwnerPausedCardStaysPausedAfterAScroll() async {
        let (review,log)=await windowReview(13)
        review.updateViewport(height:300)
        review.updateFrames(gridFrames(review,offset:0))
        await review.settle()
        XCTAssertEqual(playing(review),[0,1,2])
        review.toggle(card(review,1))
        XCTAssertEqual(playing(review),[0,2])
        review.updateFrames(gridFrames(review,offset:600))
        await review.settle()
        XCTAssertEqual(playing(review),[6,7,8])
        review.updateFrames(gridFrames(review,offset:0))
        await review.settle()
        XCTAssertEqual(playing(review),[0,2],"The owner's Pause holds after the card scrolls off and back")
        XCTAssertEqual(log.controls["item-c01"]?.plays,1)
        review.toggle(card(review,1))
        XCTAssertEqual(playing(review),[0,1,2])
        // Pause all takes holds across a scroll; Play all takes plays the visible cards again.
        review.pauseAll()
        review.updateFrames(gridFrames(review,offset:300))
        await review.settle()
        XCTAssertTrue(playing(review).isEmpty)
        review.playAll()
        XCTAssertEqual(playing(review),[3,4,5])
        // Reduce Motion: no card plays by itself after a scroll; the owner's Play still works.
        let (still,_)=await windowReview(13)
        still.setReduceMotion(true)
        still.updateViewport(height:300)
        still.updateFrames(gridFrames(still,offset:600))
        await still.settle()
        XCTAssertTrue(playing(still).isEmpty)
        still.toggle(card(still,7))
        XCTAssertEqual(playing(still),[7])
        still.updateFrames(gridFrames(still,offset:900))
        await still.settle()
        XCTAssertTrue(playing(still).isEmpty,"Reduce Motion keeps newly visible cards still")
    }
    func testBudgetOverflowPlaysTheCardsNearestTheMiddle() async {
        let (review,_)=await windowReview(15,make:videoItem)
        // Rows 0 to 2 are visible: nine cards, eighteen players. Row 1 is in the middle, row 2 is
        // nearer to the middle than row 0.
        review.updateViewport(height:900)
        review.updateFrames(gridFrames(review,offset:0))
        await review.settle()
        XCTAssertEqual(review.priority,ids([3,4,5,6,7,8,0,1,2]))
        XCTAssertEqual(playingCards(review),[3,4,5,6]);XCTAssertEqual(review.playback.playingKeys.count,8)
        for index in [0,1,2,7,8] {XCTAssertNotNil(review.playback.takes[card(review,index).key],"Card \(index) shows its still frame")}
        // The visible area gets shorter: rows 0 and 1 stay. Row 2 leaves and frees the budget,
        // and the nearest waiting card plays.
        review.updateViewport(height:600)
        await review.settle()
        XCTAssertEqual(review.priority,ids([3,4,5,0,1,2]))
        XCTAssertEqual(playingCards(review),[0,3,4,5])
        for index in [0,3,4,5] {XCTAssertTrue(fullyPlaying(review,index))}
    }
    func testReviewModelAssignsOnlyChangedLists() {
        var rows=[row("N"),row("E")]
        XCTAssertFalse(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E")]))
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E",disposition:"accepted")]))
        XCTAssertEqual(rows[1].string("disposition"),"accepted")
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("E",disposition:"accepted"),row("N")]),"A new order is a change")
    }
}

@MainActor private final class DraftNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}

/// CL-422: a fake service with one Draft round. It records every call in order. Publication
/// opens the round; refusals carry `command_outcome: rejected`, as the service sends them.
@MainActor private final class DraftService {
    var calls: [(String,MediaValues)] = []
    var state = "draft"
    var reviewInDraft: Bool? = true
    var publishFailures: [Error] = []
    var approveFailures: [Error] = []
    var withdrawalFailures: [Error] = []
    var ready = ["N":true,"E":true,"SE":false]
    /// CL-428: the item read's suggestion rows, by direction. The fake keeps returning a dismissed
    /// row as current, so a test proves that the card itself keeps a cleared flag gone.
    var suggestions: [String: [MediaValues]] = [:]
    var hints: [String: String] = [:]
    var decisions: [String: MediaValues] = [:]
    var itemRevisions: [String: Int] = [:]
    // CL-427 X1: opt-in routing/receipt refreshes with a stable inspected context.
    var metadataRevision = 0
    var linkedTask: MediaValues?
    var itemTasks: [String: MediaValues] = [:]
    var listedDirections: [String]?
    var validateObservation = false
    var writes: [String] {calls.map(\.0).filter {["media_round_publish","media_context_approve","media_decide","media_decision_withdraw","media_adopt_suggestion","media_suggestion_dismiss","media_round_send_result","media_round_link_task","media_item_link_task"].contains($0)}}
    func params(_ method: String) -> [MediaValues] {calls.filter {$0.0==method}.map(\.1)}
    var schema: MediaValues {
        var schema=MediaTypeSettings.schema(title:"Animation",starter:"animation_video")
        var layout=schema["layout"] as? MediaValues ?? [:]
        // The Animation takes starter sets review_in_draft (CL-422 Core); nil means the key is absent.
        if let reviewInDraft {layout["review_in_draft"]=reviewInDraft} else {layout.removeValue(forKey:"review_in_draft")}
        schema["layout"]=layout;return schema
    }
    var header: MediaValues {
        var value: MediaValues = state=="draft" ? ["id":"round","title":"Takes","state":"draft","origin":"agent","revision":1,"observed_context_token":"draft-context","manifest":[:] as MediaValues,"attention":[] as [MediaValues],"type_revision":["schema":schema]]
            : ["id":"round","title":"Takes","state":"open","revision":2,"observed_context_token":"open-context","manifest":["id":"manifest","digest":"digest"],"attention":[] as [MediaValues],"type_revision":["schema":schema]]
        value["revision"] = (state=="draft" ? 1 : 2) + metadataRevision
        value["task"] = linkedTask ?? NSNull()
        return value
    }
    func item(_ direction: String) -> MediaValues {
        var metadata: MediaValues=["character":"Hero","animation_label":"walk_cycle","direction":direction,"take":"1"]
        if let hint=hints[direction] {metadata["hint"]=hint}
        let target: MediaValues=state=="draft" ? ["id":"draft-"+direction,"review_basis_signature":"draft-basis-"+direction,"metadata":metadata,"candidate_ids":["candidate-"+direction]]
            : ["id":"pub-"+direction,"review_basis_signature":"published-basis-"+direction,"published_from_target_id":"draft-"+direction,"metadata":metadata,"candidate_ids":["candidate-"+direction]]
        var item: MediaValues=["id":"item-"+direction,"title":"hero__walk_cycle__"+direction+".mp4","revision":state=="draft" ? 2 : 3,"published":state=="open","disposition":"pending",
                "target":target,"candidates":[["id":"candidate-"+direction,"slots":[] as [MediaValues]]],"originals":[] as [MediaValues],
                "suggestions":suggestions[direction] ?? [] as [MediaValues]]
        item["revision"] = itemRevisions[direction] ?? (state=="draft" ? 2 : 3)
        item["task"] = itemTasks[direction] ?? NSNull()
        if let decision=decisions[direction] {
            item["decision_id"]=decision["id"]
            item["decision"]=decision;item["disposition"]=decision["disposition"] as? String=="withdrawn" ? "pending" : decision["disposition"]
            item["revision"]=itemRevisions[direction]
        }
        return item
    }
    func request(_ method: String,_ params: MediaValues) throws -> MediaValues {
        calls.append((method,params))
        if validateObservation,["media_decide","media_adopt_suggestion"].contains(method) {
            guard params["expected_revision"] as? Int == header["revision"] as? Int else {throw ChecklistError("REVISION_CONFLICT","Use the refreshed header revision.")}
            guard params["observed_context_token"] as? String == header["observed_context_token"] as? String else {throw ChecklistError("MEDIA_CONTEXT_CHANGED","The inspected context changed.")}
        }
        switch method {
        case "media_navigation":return ["types":[["id":"type","title":"Animation","enabled":true]]]
        case "media_round_page":return ["rows":[["id":"round","title":"Takes","state":state]],"has_more":false]
        case "media_round_header":return header
        case "media_item_page":return ["rows":(listedDirections ?? []).map {item($0)},"counts":[:] as MediaValues]
        case "media_item_get":return item(String((params["item_id"] as? String ?? "").dropFirst(5)))
        case "media_publication_preview":
            return ["round":header,"items":["N","E","SE"].map {d -> MediaValues in ["item_id":"item-"+d,"target_id":"draft-"+d,"expected_revision":2,"review_basis_signature":"published-basis-"+d,"title":d,"publication_ready":ready[d]!]}]
        case "media_round_publish":
            if !publishFailures.isEmpty {throw publishFailures.removeFirst()}
            state="open";return header
        case "media_context_approve":
            if !approveFailures.isEmpty {throw approveFailures.removeFirst()}
            return ["approved":true]
        case "media_decide":
            let selection=(params["items"] as? [MediaValues])?.first ?? [:]
            let direction=String((selection["item_id"] as? String ?? "").dropFirst(5))
            let decision: MediaValues=["id":"decision-"+direction,"item_id":selection["item_id"]!,"target_id":selection["target_id"]!,"disposition":params["disposition"]!]
            itemRevisions[direction]=(selection["expected_revision"] as? Int ?? 0)+1
            decisions[direction]=decision;return ["decisions":[decision]]
        case "media_adopt_suggestion":
            let selection=(params["items"] as? [MediaValues])?.first ?? [:]
            let suggestion=suggestions.values.flatMap {$0}.first {$0["id"] as? String==params["suggestion_id"] as? String} ?? [:]
            let direction=String((selection["item_id"] as? String ?? "").dropFirst(5))
            let decision: MediaValues=["id":"adopted-"+direction,"item_id":selection["item_id"]!,"target_id":selection["target_id"]!,"disposition":suggestion["disposition"] ?? "accepted"]
            itemRevisions[direction]=(selection["expected_revision"] as? Int ?? 0)+1
            decisions[direction]=decision;return ["decisions":[decision]]
        case "media_decision_withdraw":
            if !withdrawalFailures.isEmpty {throw withdrawalFailures.removeFirst()}
            let selection=(params["items"] as? [MediaValues])?.first ?? [:]
            let direction=String((selection["item_id"] as? String ?? "").dropFirst(5))
            let target=item(direction)["target"] as? MediaValues ?? [:]
            let decision: MediaValues=["id":"withdrawal-"+direction,"item_id":selection["item_id"]!,"target_id":target["id"]!,
                "disposition":"withdrawn","withdraws_decision_id":selection["decision_id"]!,"supersedes_decision_id":selection["decision_id"]!]
            itemRevisions[direction]=(selection["expected_revision"] as? Int ?? 0)+1
            decisions[direction]=decision;return ["decisions":[decision]]
        case "media_round_link_task":
            metadataRevision+=1
            linkedTask=(params["task_id"] as? String).map {["id":$0,"key":"HEIR-131","title":"Another ticket"]}
            return header
        case "media_item_link_task":
            metadataRevision+=1
            let direction=String((params["item_id"] as? String ?? "").dropFirst(5))
            itemTasks[direction]=(params["task_id"] as? String).map {["id":$0,"key":"HEIR-132","title":"Item ticket"]}
            itemRevisions[direction]=(item(direction)["revision"] as? Int ?? 3)+1
            return item(direction)
        case "media_round_send_result":
            metadataRevision+=1
            return ["message_id":"result-note","recipients":[] as [MediaValues],"item_count":decisions.count,"changed_only":false,"sent_at":"2026-11-04T08:00:00Z"]
        case "media_suggestion_dismiss":return ["suggestion_id":params["suggestion_id"]!,"dismissed":["by":"owner"]]
        default:return [:]
        }
    }
}

extension MediaSimpleReviewTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<1200 where !condition() {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(condition(),"The condition did not hold within 6 s")
    }
    /// A loaded simple review of a Draft round, wired to the fake service through the store's command journal.
    private func draftReview(_ service: DraftService) async -> (MediaSimpleReviewModel,MediaReviewModel,ChecklistStore) {
        let defaults=isolatedDefaults("SimpleDraft"),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=ChecklistStore(draftJournal:LocalDraftJournal(directory:directory),preferences:defaults.preferences,restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:DraftNoAlerts()),requestTransport:{method,params in ["data":try service.request(method,params)]},
            navigationMemory:DetailItemNavigationMemory(),pendingCommandPersistence:PendingCommandPersistence(read:{_ in nil},save:{_,_ in},remove:{_ in}))
        store.data=["service":["store_incarnation":"synthetic"],"projects":[["id":"project","name":"Synthetic","revision":4]]];store.connected=true;store.projectID="project"
        let model=store.mediaReview;await model.connect(store:store);model.roundID="round"
        let review=MediaSimpleReviewModel()
        review.update(header:Record(values:service.header))
        review.sync(scope:"project:round",rows:["N","E","SE"].map {Record(values:["id":"item-"+$0,"revision":2,"metadata":["direction":$0]])},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in Record(values:service.item(String(id.dropFirst(5))))}
        service.calls=[]
        return (review,model,store)
    }

    func testReviewInDraftShowsDecisionsOnDraftCardsOnlyWhenTheTypeSaysSo() async throws {
        let on=DraftService(),off=DraftService();off.reviewInDraft=nil
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"draft",published:false,schema:on.schema,historyOnly:false),.firstDraft)
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"draft",published:false,schema:off.schema,historyOnly:false),.unavailable,"An absent key means false")
        off.reviewInDraft=false
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"draft",published:false,schema:off.schema,historyOnly:false),.unavailable)
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"draft",published:false,schema:on.schema,historyOnly:true),.unavailable)
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"open",published:true,schema:on.schema,historyOnly:false),.open)
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(state:"open",published:true,schema:off.schema,historyOnly:false),.open)
        let (review,model,_)=await draftReview(on)
        let card=try XCTUnwrap(review.cards["item-N"])
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(card,model:model),.firstDraft);XCTAssertTrue(card.basisMatches)
        // A type without the key keeps today's Draft flow: no decision is sent from a Draft card.
        let plain=DraftService();plain.reviewInDraft=nil
        let (plainReview,plainModel,plainStore)=await draftReview(plain)
        let plainCard=try XCTUnwrap(plainReview.cards["item-N"])
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(plainCard,model:plainModel),.unavailable)
        await plainReview.press("accepted",card:plainCard,model:plainModel)
        XCTAssertEqual(plain.writes,[]);XCTAssertFalse(plainCard.status.isEmpty)
        XCTAssertEqual(plain.calls.count,0,"The route refuses before any read");withExtendedLifetime(plainStore) {}
    }
    func testFirstDraftDecisionPublishesThenDecidesAndLaterDecisionOnlyDecides() async throws {
        let service=DraftService()
        let (review,model,store)=await draftReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending && service.writes.contains("media_decide")}
        XCTAssertEqual(service.writes,["media_round_publish","media_decide"])
        let publish=try XCTUnwrap(service.params("media_round_publish").first)
        XCTAssertEqual(publish["round_id"] as? String,"round");XCTAssertEqual(publish["expected_revision"] as? Int,1)
        XCTAssertEqual(publish["observed_context_token"] as? String,"draft-context")
        let published=publish["items"] as? [MediaValues] ?? []
        XCTAssertEqual(published.map {$0["item_id"] as? String},["item-N","item-E"],"Only the publication-ready items are published")
        XCTAssertEqual(published.map {$0["target_id"] as? String},["draft-N","draft-E"])
        XCTAssertEqual(published.map {$0["review_basis_signature"] as? String},["published-basis-N","published-basis-E"])
        let decide=try XCTUnwrap(service.params("media_decide").first)
        XCTAssertNotNil(decide["command_id"],"The decision uses the native command journal")
        XCTAssertEqual(decide["round_id"] as? String,"round");XCTAssertEqual(decide["expected_revision"] as? Int,2)
        XCTAssertEqual(decide["observed_context_token"] as? String,"open-context")
        XCTAssertEqual(decide["manifest_id"] as? String,"manifest");XCTAssertEqual(decide["manifest_digest"] as? String,"digest")
        XCTAssertEqual(decide["disposition"] as? String,"accepted");XCTAssertEqual(decide["winner_id"] as? String,"candidate-N")
        let selection=try XCTUnwrap((decide["items"] as? [MediaValues])?.first)
        XCTAssertEqual(selection["item_id"] as? String,"item-N");XCTAssertEqual(selection["target_id"] as? String,"pub-N")
        XCTAssertEqual(selection["review_basis_signature"] as? String,"published-basis-N");XCTAssertEqual(selection["expected_revision"] as? Int,3)
        XCTAssertEqual(north.item.string("disposition"),"accepted");XCTAssertEqual(north.status,"Saved: Accepted")
        XCTAssertTrue(review.cards["item-N"] === north,"The card is kept by item ID")
        // A later decision on the open round sends only media_decide.
        await model.waitUntilWritable();XCTAssertFalse(store.hasPendingMutation)
        review.sync(scope:"project:round",rows:["N","E","SE"].map {Record(values:["id":"item-"+$0,"revision":3,"metadata":["direction":$0]])},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in Record(values:service.item(String(id.dropFirst(5))))}
        let east=try XCTUnwrap(review.cards["item-E"])
        XCTAssertEqual(MediaSimpleLayout.decisionRoute(east,model:model),.open)
        XCTAssertTrue(east.basisMatches,"A target published from the Draft target this card showed takes the open basis")
        service.calls=[]
        await review.press("needs_look",card:east,model:model)
        try await settle {!east.sending && service.writes.contains("media_decide")}
        XCTAssertEqual(service.writes,["media_decide"])
        XCTAssertEqual((service.params("media_decide").first?["items"] as? [MediaValues])?.first?["target_id"] as? String,"pub-E")
    }
    func testRefusedPublicationRecordsNoDecisionAndShowsTheError() async throws {
        let service=DraftService()
        service.publishFailures=[ChecklistError("MEDIA_BASIS_CHANGED","The exact complete target must match the publication preview.",details:["command_outcome":"rejected"])]
        // The model holds the store weakly: the test keeps it, as the app does.
        let (review,model,store)=await draftReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending}
        XCTAssertEqual(service.writes,["media_round_publish"])
        await model.waitUntilWritable();XCTAssertFalse(store.hasPendingMutation,"The refusal leaves no pending command")
        XCTAssertTrue(north.status.hasPrefix("Could not publish this round: "),north.status)
        XCTAssertTrue(north.status.hasSuffix(". No decision was saved."),north.status)
        XCTAssertTrue(north.status.contains("publication preview"),north.status)
        XCTAssertEqual(north.item.string("disposition"),"pending")
        XCTAssertNil(store.error,"The card shows the refusal; no global alert shows it");XCTAssertNil(model.error)
        // A card whose item is not publication-ready sends nothing at all.
        service.calls=[]
        let southEast=try XCTUnwrap(review.cards["item-SE"])
        await review.press("needs_look",card:southEast,model:model)
        XCTAssertEqual(service.writes,[]);XCTAssertTrue(southEast.status.hasPrefix("Could not publish this round: "),southEast.status)
        XCTAssertEqual(service.calls.map(\.0),["media_publication_preview"],"Only the preview is read");XCTAssertNotNil(model.store)
        withExtendedLifetime(store) {}
    }
    private static func contextRequired() -> ChecklistError {
        ChecklistError("MEDIA_PROJECT_CONTEXT_REQUIRED","Approve the project context once before the first publication. No records changed.",details:["command_outcome":"rejected"])
    }
    /// The service methods of the publication sequence, in order.
    private func sequence(_ service: DraftService) -> [String] {
        service.calls.map(\.0).filter {["media_publication_preview","media_round_publish","media_context_approve","media_decide"].contains($0)}
    }
    /// CL-422 rework (owner, 3 Nov 2026): the owner's press is the context approval. No dialog, no global alert.
    func testProjectContextRefusalApprovesByItselfThenPublishesAndDecides() async throws {
        let service=DraftService()
        service.publishFailures=[Self.contextRequired()]
        let (review,model,store)=await draftReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending && service.writes.contains("media_decide")}
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve","media_round_publish","media_decide"])
        XCTAssertEqual(sequence(service),["media_publication_preview","media_round_publish","media_context_approve","media_publication_preview","media_round_publish","media_decide"],
            "The second publication reads the preview again")
        let approve=try XCTUnwrap(service.params("media_context_approve").first)
        XCTAssertEqual(approve["kind"] as? String,"project");XCTAssertEqual(approve["expected_project_revision"] as? Int,4)
        XCTAssertEqual(Set(approve.keys),["kind","expected_project_revision","project_id","command_id"],"The same request as the setup button")
        XCTAssertEqual((service.params("media_decide").first?["items"] as? [MediaValues])?.first?["target_id"] as? String,"pub-N")
        XCTAssertEqual(north.status,"Saved: Accepted")
        XCTAssertNil(store.error,"No OK-only global alert");XCTAssertNil(model.error,"No orange line");XCTAssertFalse(store.hasPendingMutation)
    }
    func testFailedContextApprovalRecordsNoDecisionAndShowsOneCardError() async throws {
        let service=DraftService()
        service.publishFailures=[Self.contextRequired()]
        service.approveFailures=[ChecklistError("REVISION_CONFLICT","The project changed. Refresh and try again.",details:["command_outcome":"rejected"])]
        let (review,model,store)=await draftReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending}
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve"],"No second publication and no decision")
        XCTAssertTrue(north.status.hasPrefix("Could not publish this round: "),north.status)
        XCTAssertTrue(north.status.hasSuffix(". No decision was saved."),north.status)
        XCTAssertEqual(north.item.string("disposition"),"pending")
        await model.waitUntilWritable();XCTAssertFalse(store.hasPendingMutation)
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error)
    }
    func testPublishActionApprovesContextByItselfThenPublishes() async throws {
        let service=DraftService();service.ready["SE"]=true
        service.publishFailures=[Self.contextRequired()]
        let (_,model,store)=await draftReview(service)
        model.header=Record(values:service.header)
        XCTAssertTrue(model.preparedPublicationAvailable)
        await model.publishPreparedRound()
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve","media_round_publish"])
        XCTAssertEqual(model.roundState,"open");XCTAssertNil(model.error);XCTAssertNil(store.error)
        XCTAssertEqual((service.params("media_round_publish").last?["items"] as? [MediaValues])?.count,3)
    }
    /// CL-426: the intake "Publish these N items" press approves the context by itself, then publishes the same items.
    private func intakePreview(_ service: DraftService) async -> (MediaReviewModel,ChecklistStore) {
        service.ready["SE"]=true
        let (_,model,store)=await draftReview(service)
        await model.previewPublication()
        XCTAssertEqual(model.publication.count,3);service.calls=[]
        return (model,store)
    }
    func testIntakePublishApprovesContextByItselfThenPublishesTheSameItems() async throws {
        let service=DraftService()
        let (model,store)=await intakePreview(service)
        service.publishFailures=[Self.contextRequired()]
        await model.publishShownPreview()
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve","media_round_publish"])
        XCTAssertEqual(sequence(service),["media_round_publish","media_context_approve","media_publication_preview","media_round_publish"],
            "The first publication sends the frozen preview; the second reads it again")
        let approve=try XCTUnwrap(service.params("media_context_approve").first)
        XCTAssertEqual(Set(approve.keys),["kind","expected_project_revision","project_id","command_id"],"The same request as the setup button")
        XCTAssertEqual(approve["kind"] as? String,"project");XCTAssertEqual(approve["expected_project_revision"] as? Int,4)
        let sent=service.params("media_round_publish")
        XCTAssertEqual(sent.first?["observed_context_token"] as? String,"draft-context")
        for publish in sent {XCTAssertEqual((publish["items"] as? [MediaValues])?.compactMap {$0["item_id"] as? String},["item-N","item-E","item-SE"])}
        XCTAssertEqual(model.roundState,"open");XCTAssertTrue(model.publication.isEmpty);XCTAssertNil(model.publicationFailure)
        XCTAssertNil(store.error,"No OK-only global alert");XCTAssertNil(model.error,"No orange line");XCTAssertFalse(store.hasPendingMutation)
    }
    func testIntakePublishFailedApprovalShowsOneLineAndPublishesNothing() async throws {
        let service=DraftService()
        let (model,store)=await intakePreview(service)
        service.publishFailures=[Self.contextRequired()]
        service.approveFailures=[ChecklistError("REVISION_CONFLICT","The project changed. Refresh and try again.",details:["command_outcome":"rejected"])]
        await model.publishShownPreview()
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve"],"No second publication")
        XCTAssertEqual(model.publicationFailure,"Could not publish these items: The project changed. Refresh and try again. Nothing was published.")
        XCTAssertEqual(service.state,"draft");XCTAssertEqual(model.publication.count,3,"The owner still sees the items")
        await model.waitUntilWritable();XCTAssertFalse(store.hasPendingMutation)
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error)
    }
    func testIntakePublishRefusalShowsOneLineAndPublishesNothing() async throws {
        let service=DraftService()
        let (model,store)=await intakePreview(service)
        service.publishFailures=[ChecklistError("MEDIA_BASIS_CHANGED","The exact complete target must match the publication preview.",details:["command_outcome":"rejected"])]
        await model.publishShownPreview()
        XCTAssertEqual(service.writes,["media_round_publish"])
        XCTAssertEqual(model.publicationFailure,"Could not publish these items: The exact complete target must match the publication preview. Nothing was published.")
        XCTAssertEqual(service.state,"draft");XCTAssertNil(store.error);XCTAssertNil(model.error)
        // A new preview clears the line.
        await model.previewPublication();XCTAssertNil(model.publicationFailure)
    }
    func testIntakePublishAfterApprovalSendsNothingWhenTheItemsChanged() async throws {
        let service=DraftService()
        let (model,store)=await intakePreview(service)
        // The owner saw two items; the preview after the approval holds three.
        model.publication=Array(model.publication.prefix(2))
        service.publishFailures=[Self.contextRequired()]
        await model.publishShownPreview()
        XCTAssertEqual(service.writes,["media_round_publish","media_context_approve"],"No second publication")
        XCTAssertEqual(model.publicationFailure,"Could not publish these items: The publication items changed. Preview the publication again. Nothing was published.")
        XCTAssertEqual(service.state,"draft");XCTAssertNil(store.error);XCTAssertNil(model.error)
    }
    /// Review 8b119aed R3: items read again before the open header arrives still take the open basis in place.
    func testOtherCardsTakeTheOpenBasisAfterPublicationWithNoReopen() async throws {
        let service=DraftService();service.ready["SE"]=true
        let (review,model,store)=await draftReview(service)
        model.header=Record(values:service.header)
        await model.publishPreparedRound()
        XCTAssertEqual(service.writes,["media_round_publish"])
        // The item rows arrive first, while each card still holds the Draft header.
        review.sync(scope:"project:round",rows:["N","E","SE"].map {Record(values:["id":"item-"+$0,"revision":3,"metadata":["direction":$0]])},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in Record(values:service.item(String(id.dropFirst(5))))}
        let east=try XCTUnwrap(review.cards["item-E"])
        XCTAssertEqual(east.target.id,"pub-E");XCTAssertEqual(east.header.string("state"),"draft")
        review.update(header:Record(values:service.header))
        XCTAssertTrue(east.basisMatches,"No inspection press is needed")
        await model.waitUntilWritable();service.calls=[]
        await review.press("accepted",card:east,model:model)
        try await settle {!east.sending && service.writes.contains("media_decide")}
        XCTAssertEqual(service.writes,["media_decide"]);XCTAssertEqual(east.status,"Saved: Accepted")
        withExtendedLifetime(store) {}
    }
    /// Review 8b119aed R2: the card player has no inline control, so no pause can bypass `ownerPaused`.
    func testCardPlayerHasNoInlineControls() {
        let view=AVPlayerView(),player=AVPlayer()
        MediaSimpleCardPlayer.configure(view,player:player)
        XCTAssertEqual(view.controlsStyle,.none);XCTAssertFalse(view.showsFullScreenToggleButton)
        XCTAssertTrue(view.player===player);XCTAssertEqual(view.videoGravity,.resizeAspect)
    }
    /// CL-421 rework: "Changes requested" needs a note; the card says so and enables it with text.
    func testChangesRequestedShowsTheNoteHintAndEnablesWithANote() async throws {
        XCTAssertEqual(MediaSimpleLayout.changesNeedNote,"Write a note to request changes.")
        XCTAssertEqual(MediaSimpleLayout.noteHint("changes_requested",note:""),"Write a note to request changes.")
        XCTAssertEqual(MediaSimpleLayout.noteHint("changes_requested",note:"  \n"),"Write a note to request changes.")
        XCTAssertNil(MediaSimpleLayout.noteHint("changes_requested",note:"Raise the arm"))
        XCTAssertNil(MediaSimpleLayout.noteHint("accepted",note:""));XCTAssertNil(MediaSimpleLayout.noteHint("needs_look",note:""))
        let service=DraftService()
        let (review,model,store)=await draftReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.press("changes_requested",card:north,model:model)
        XCTAssertEqual(north.status,"Write a note to request changes.");XCTAssertEqual(service.calls.count,0)
        north.draft.note="Raise the arm"
        XCTAssertNil(MediaSimpleLayout.noteHint("changes_requested",note:north.draft.note),"The button enables as soon as the note has text")
        withExtendedLifetime(store) {}
    }
}

/// CL-428: recommendations, flags, Keep, Keep all, Clear flag, hints and "Not made" cards.
/// Fake service, rows and items only.
extension MediaSimpleReviewTests {
    private func suggestion(_ id: String,_ disposition: String,note: String = "",source: String = "agent",stale: Bool = false) -> MediaValues {
        ["id":id,"origin":"agent","disposition":disposition,"note":note,"source_label":"Heir worker","author_display":"Heir worker","source":source,"stale":stale]
    }
    private func openReview(_ service: DraftService) async -> (MediaSimpleReviewModel,MediaReviewModel,ChecklistStore) {
        service.state="open";return await draftReview(service)
    }
    func testEachRecommendationTextAndARecommendationIsNotADecision() async throws {
        let service=DraftService()
        service.suggestions=["N":[suggestion("s-N","accepted",note:"Looks right")],"E":[suggestion("s-E","needs_look",note:"Foot slides")],
                             "SE":[suggestion("s-SE","changes_requested",note:"Arm clips the cape",source:"check")]]
        let (review,model,store)=await openReview(service)
        let north=try XCTUnwrap(review.cards["item-N"]),east=try XCTUnwrap(review.cards["item-E"]),southEast=try XCTUnwrap(review.cards["item-SE"])
        XCTAssertEqual(review.recommendation(north)?.reason,"Accept suggested by Heir worker — keep or change it")
        XCTAssertEqual(review.recommendation(east)?.reason,"Flagged by Heir worker")
        XCTAssertEqual(review.recommendation(southEast)?.reason,"Flagged from checks by Heir worker","A check flag names the agent that posted it")
        XCTAssertEqual(review.recommendation(north)?.isFlag,false);XCTAssertEqual(review.recommendation(east)?.isFlag,true)
        XCTAssertEqual(review.recommendation(southEast)?.choiceTitle,"Changes requested")
        XCTAssertEqual(north.draft.note,"Looks right","The suggestion's note is an editable draft");XCTAssertEqual(southEast.draft.note,"Arm clips the cape")
        // Advice only: nothing is sent, the item has no owner decision and the counts stay as the service sends them.
        XCTAssertEqual(service.writes,[]);XCTAssertEqual(north.item.string("disposition"),"pending");XCTAssertTrue(model.counts.isEmpty)
        XCTAssertFalse(MediaCardRecommendation.ownerDecided(north.item))
        // Not current: a stale row, a dismissed row, or an item with an owner decision.
        XCTAssertNil(MediaCardRecommendation.current(item:Record(values:["disposition":"pending","suggestions":[suggestion("old","accepted",stale:true)]])))
        XCTAssertNil(MediaCardRecommendation.current(item:Record(values:["disposition":"pending","suggestions":[suggestion("gone","needs_look")]]),dismissed:["gone"]))
        var dismissed=suggestion("d","needs_look");dismissed["dismissed"]=["by":"owner","at":"2026-11-03T00:00:00Z"]
        XCTAssertNil(MediaCardRecommendation.current(item:Record(values:["disposition":"pending","suggestions":[dismissed]])))
        XCTAssertNil(MediaCardRecommendation.current(item:Record(values:["disposition":"accepted","suggestions":[suggestion("x","needs_look")]])))
        XCTAssertEqual(MediaCardRecommendation.current(item:Record(values:["disposition":"stale",
            "agent_suggestions":[["id":"a","disposition":"needs_look","note":"","author_display":"Heir worker","source":"agent"]]]))?.reason,"Flagged by Heir worker",
            "A stale owner decision is no decision for the current target; agent_suggestions rows count")
        withExtendedLifetime(store) {}
    }
    func testKeepSendsAdoptSuggestionAndAnotherChoiceSendsTheDecision() async throws {
        let service=DraftService()
        service.suggestions=["N":[suggestion("s-N","accepted",note:"Looks right")],"E":[suggestion("s-E","accepted")]]
        let (review,model,store)=await openReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.keep(north,model:model)
        try await settle {!north.sending && service.writes.contains("media_adopt_suggestion")}
        XCTAssertEqual(service.writes,["media_adopt_suggestion"])
        let adopt=try XCTUnwrap(service.params("media_adopt_suggestion").first)
        XCTAssertEqual(adopt["suggestion_id"] as? String,"s-N");XCTAssertNotNil(adopt["command_id"],"The native command journal sends it")
        XCTAssertNil(adopt["disposition"]);XCTAssertNil(adopt["note"]);XCTAssertNil(adopt["winner_id"])
        XCTAssertEqual(adopt["round_id"] as? String,"round");XCTAssertEqual(adopt["expected_revision"] as? Int,2)
        XCTAssertEqual(adopt["observed_context_token"] as? String,"open-context");XCTAssertEqual(adopt["manifest_id"] as? String,"manifest")
        let selection=try XCTUnwrap((adopt["items"] as? [MediaValues])?.first)
        XCTAssertEqual(selection["item_id"] as? String,"item-N");XCTAssertEqual(selection["target_id"] as? String,"pub-N")
        XCTAssertEqual(selection["review_basis_signature"] as? String,"published-basis-N");XCTAssertEqual(selection["expected_revision"] as? Int,3)
        XCTAssertEqual(north.item.string("disposition"),"accepted");XCTAssertEqual(north.status,"Saved: Accepted")
        XCTAssertNil(review.recommendation(north),"A kept recommendation is now the owner's decision")
        // One press on another choice decides that choice.
        await model.waitUntilWritable();service.calls=[]
        let east=try XCTUnwrap(review.cards["item-E"])
        await review.press("needs_look",card:east,model:model)
        try await settle {!east.sending && service.writes.contains("media_decide")}
        XCTAssertEqual(service.writes,["media_decide"]);XCTAssertEqual(service.params("media_decide").first?["disposition"] as? String,"needs_look")
        XCTAssertEqual(east.item.string("disposition"),"needs_look")
        withExtendedLifetime(store) {}
    }
    func testKeepAllKeepsEveryRecommendationAfterOneConfirmation() async throws {
        let service=DraftService()
        service.suggestions=["N":[suggestion("s-N","accepted")],"E":[suggestion("s-E","needs_look",note:"Foot slides")]]
        let (review,model,store)=await openReview(service)
        XCTAssertEqual(review.keepAllCards(model:model).map(\.id),["item-N","item-E"])
        let confirmation=try XCTUnwrap(review.keepAllConfirmation(model:model))
        XCTAssertEqual(confirmation.confirmLabel,"Keep 2 recommendations");XCTAssertEqual(service.writes,[],"Nothing is sent before the confirmation")
        confirmation.perform()
        try await settle {service.params("media_adopt_suggestion").count==2 && review.cards["item-E"]?.sending == false}
        XCTAssertEqual(service.writes,["media_adopt_suggestion","media_adopt_suggestion"],"One adoption per item and no other write")
        XCTAssertEqual(service.params("media_adopt_suggestion").map {$0["suggestion_id"] as? String},["s-N","s-E"])
        XCTAssertEqual(review.cards["item-E"]?.item.string("disposition"),"needs_look");XCTAssertEqual(review.cards["item-SE"]?.item.string("disposition"),"pending")
        XCTAssertNil(review.keepAllConfirmation(model:model),"No recommendation is left to keep")
        withExtendedLifetime(store) {}
    }
    func testSecondCardAndKeepAllStayDecidableAfterResultSendAndTicketLinks() async throws {
        for method in ["media_round_send_result","media_round_link_task","media_item_link_task"] {
            let service=DraftService()
            service.linkedTask=["id":"task-A","key":"HEIR-130","title":"Owning ticket"]
            service.listedDirections=["N","E","SE"];service.validateObservation=true
            service.suggestions=["E":[suggestion("s-E","accepted")],"SE":[suggestion("s-SE","accepted")]]
            let (review,model,store)=await openReview(service)
            await model.refresh()
            // Mirrors MediaSimpleReview's onReceive(model.$header), including the post-write refresh.
            let updates=model.$header.sink {review.update(header:$0)}
            defer {updates.cancel()}
            let north=try XCTUnwrap(review.cards["item-N"]),east=try XCTUnwrap(review.cards["item-E"])
            let inspected=east.draft
            await review.press("accepted",card:north,model:model)
            try await settle {!north.sending && north.item.string("disposition")=="accepted"}
            await model.waitUntilWritable()
            service.calls=[]
            switch method {
            case "media_round_send_result":
                XCTAssertNotNil(model.resultAction)
                await model.sendResults()
            case "media_round_link_task": model.linkTask("task-B")
            default: model.linkItemTask("item-N","task-C")
            }
            try await settle {model.header.integer("revision")==3 && east.header.integer("revision")==3}
            await model.waitUntilWritable()
            XCTAssertEqual(service.params(method).count,1,method)
            XCTAssertTrue(review.cards["item-E"]===east,"The same card keeps the owner's observation")
            XCTAssertEqual(east.draft,inspected,"No inspection press or automatic reinspection")
            XCTAssertTrue(east.basisMatches,method)
            XCTAssertEqual(try east.decisionRequest("accepted")["expected_revision"] as? Int,3)
            XCTAssertEqual(review.keepAllCards(model:model).map(\.id),["item-E","item-SE"],method)
            await review.press("accepted",card:east,model:model)
            try await settle {!east.sending && east.item.string("disposition")=="accepted"}
            let decision=try XCTUnwrap(service.params("media_decide").last)
            XCTAssertEqual(decision["expected_revision"] as? Int,3,method)
            XCTAssertEqual(decision["observed_context_token"] as? String,inspected.contextToken,method)
            await model.waitUntilWritable()
            XCTAssertEqual(review.keepAllCards(model:model).map(\.id),["item-SE"])
            let keep=try XCTUnwrap(review.keepAllConfirmation(model:model))
            keep.perform()
            try await settle {service.params("media_adopt_suggestion").count==1 && review.cards["item-SE"]?.sending==false}
            XCTAssertEqual(service.params("media_adopt_suggestion").first?["expected_revision"] as? Int,3,method)
            XCTAssertEqual(review.cards["item-SE"]?.item.string("disposition"),"accepted",method)
            withExtendedLifetime(store) {}
        }
    }

    func testRealContextManifestAndAttentionRefreshStillRequireInspection() async throws {
        for kind in ["context","manifest","attention"] {
            let service=DraftService();service.suggestions=["E":[suggestion("s-E","accepted")]]
            let (review,model,store)=await openReview(service)
            let east=try XCTUnwrap(review.cards["item-E"]),inspected=east.draft
            var next=service.header;next["revision"]=3;next["observed_context_token"]="changed-"+kind
            if kind=="manifest" {next["manifest"]=["id":"next-manifest","digest":"new-digest"]}
            if kind=="attention" {next["attention"]=[["id":"new-attention"]]}
            review.update(header:Record(values:next))
            XCTAssertEqual(east.draft,inspected)
            XCTAssertFalse(east.basisMatches,kind)
            XCTAssertThrowsError(try east.decisionRequest("accepted"),kind)
            XCTAssertTrue(review.keepAllCards(model:model).isEmpty,kind)
            XCTAssertTrue(service.writes.isEmpty)
            withExtendedLifetime(store) {}
        }
    }

    func testSecondPressOnEachOwnerChoiceWithdrawsExactHeadAndLeavesPending() async throws {
        let service=DraftService()
        let (review,model,store)=await openReview(service)
        for (direction,choice) in zip(["N","E","SE"],MediaSimpleLayout.decisions) {
            let card=try XCTUnwrap(review.cards["item-"+direction])
            card.draft.note="Feet slide"
            await review.press(choice.disposition,card:card,model:model)
            try await settle {!card.sending && card.item.string("disposition")==choice.disposition}
            let decision=try XCTUnwrap(card.currentOwnerDecision),revision=card.item.integer("revision")
            await model.waitUntilWritable();service.calls=[]
            card.draft.note=""
            XCTAssertTrue(card.isCurrentDecision(choice.disposition))
            XCTAssertNil(card.decisionNoteHint(choice.disposition),"Removing Changes requested needs no new owner note")
            await review.press(choice.disposition,card:card,model:model)
            try await settle {!card.sending && service.writes.contains("media_decision_withdraw")}
            XCTAssertEqual(service.writes,["media_decision_withdraw"],"The second press removes the owner head instead of deciding again")
            let withdraw=try XCTUnwrap(service.params("media_decision_withdraw").first)
            XCTAssertEqual(withdraw["round_id"] as? String,"round");XCTAssertEqual(withdraw["expected_revision"] as? Int,2)
            XCTAssertEqual(withdraw["observed_context_token"] as? String,"open-context")
            XCTAssertEqual(withdraw["manifest_id"] as? String,"manifest");XCTAssertEqual(withdraw["manifest_digest"] as? String,"digest")
            XCTAssertNotNil(withdraw["command_id"],"Withdrawal goes through the same native command journal as decisions")
            for key in ["disposition","note","winner_id","none_fit","suggestion_id"] {XCTAssertNil(withdraw[key],key)}
            let selections=try XCTUnwrap(withdraw["items"] as? [MediaValues]),selection=try XCTUnwrap(selections.first)
            XCTAssertEqual(selections.count,1);XCTAssertEqual(Set(selection.keys),Set(["item_id","expected_revision","decision_id"]))
            XCTAssertEqual(selection["item_id"] as? String,card.id);XCTAssertEqual(selection["expected_revision"] as? Int,revision)
            XCTAssertEqual(selection["decision_id"] as? String,decision.id)
            XCTAssertEqual(card.item.string("disposition"),"pending");XCTAssertEqual(card.status,"Saved: Pending")
            XCTAssertEqual(card.item.object("decision")["withdraws_decision_id"] as? String,decision.id)
            XCTAssertNil(card.currentOwnerDecision);XCTAssertFalse(MediaCardRecommendation.ownerDecided(card.item))
            // A later service item read keeps the take Pending and its immutable withdrawal head.
            review.apply(Record(values:service.item(direction)),to:card)
            XCTAssertEqual(card.item.string("disposition"),"pending");XCTAssertNil(card.currentOwnerDecision)
            await model.waitUntilWritable();service.calls=[]
        }
        withExtendedLifetime(store) {}
    }
    func testSecondPressWithdrawsAKeptRecommendationAndRefusalKeepsTheOwnerChoice() async throws {
        let service=DraftService();service.suggestions=["N":[suggestion("s-N","accepted")]]
        let (review,model,store)=await openReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        await review.keep(north,model:model)
        try await settle {!north.sending && north.currentOwnerDecision != nil}
        let adopted=try XCTUnwrap(north.currentOwnerDecision)
        await model.waitUntilWritable();service.calls=[]
        service.withdrawalFailures=[ChecklistError("MEDIA_DECISION_USED","This decision already has a rework link.",details:["command_outcome":"rejected"])]
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending && service.writes.contains("media_decision_withdraw")}
        XCTAssertEqual(service.writes,["media_decision_withdraw"])
        XCTAssertEqual(north.currentOwnerDecision?.id,adopted.id);XCTAssertEqual(north.item.string("disposition"),"accepted")
        XCTAssertTrue(north.status.contains("already has a rework link"),north.status)
        await model.waitUntilWritable();service.calls=[]
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending && service.writes.contains("media_decision_withdraw")}
        XCTAssertEqual(service.writes,["media_decision_withdraw"])
        XCTAssertEqual((service.params("media_decision_withdraw").first?["items"] as? [MediaValues])?.first?["decision_id"] as? String,adopted.id)
        XCTAssertEqual(north.item.string("disposition"),"pending");XCTAssertEqual(north.status,"Saved: Pending")
        XCTAssertEqual(review.recommendation(north)?.suggestionID,"s-N","The remaining advice is separate from the removed owner choice")
        withExtendedLifetime(store) {}
    }
    func testPublishedCarriedChoiceWithdrawsWhenItsBasisMatchesAcrossTargetIDs() async throws {
        let service=DraftService()
        service.decisions["N"]=["id":"carried-N","item_id":"item-N","target_id":"draft-N","disposition":"accepted",
            "review_basis_signature":"published-basis-N","carried_from_decision_id":"predecessor-N"]
        service.itemRevisions["N"]=4
        let (review,model,store)=await openReview(service)
        let north=try XCTUnwrap(review.cards["item-N"])
        XCTAssertEqual(north.target.id,"pub-N");XCTAssertEqual(north.item.string("disposition"),"accepted")
        XCTAssertEqual(north.currentOwnerDecision?.id,"carried-N","Publication changes the target ID without invalidating an unchanged carried basis")
        // An authoritative Stale disposition must still keep an earlier choice from toggling.
        var stale=service.item("N");stale["disposition"]="stale"
        review.apply(Record(values:stale),to:north);XCTAssertNil(north.currentOwnerDecision)
        review.apply(Record(values:service.item("N")),to:north)
        await review.press("accepted",card:north,model:model)
        try await settle {!north.sending && service.writes.contains("media_decision_withdraw")}
        XCTAssertEqual(service.writes,["media_decision_withdraw"])
        let selection=try XCTUnwrap((service.params("media_decision_withdraw").first?["items"] as? [MediaValues])?.first)
        XCTAssertEqual(selection["decision_id"] as? String,"carried-N");XCTAssertEqual(selection["expected_revision"] as? Int,4)
        XCTAssertEqual(north.item.string("disposition"),"pending");XCTAssertEqual(north.status,"Saved: Pending")
        XCTAssertEqual(north.item.object("decision")["target_id"] as? String,"pub-N")
        XCTAssertEqual(north.item.object("decision")["withdraws_decision_id"] as? String,"carried-N")
        withExtendedLifetime(store) {}
    }
    func testClearFlagSendsDismissAndTheFlagStaysGone() async throws {
        let service=DraftService()
        service.suggestions=["E":[suggestion("s-E","changes_requested",note:"Foot slides")]]
        let (review,model,store)=await openReview(service)
        let east=try XCTUnwrap(review.cards["item-E"])
        XCTAssertEqual(review.recommendation(east)?.isFlag,true);XCTAssertEqual(east.draft.note,"Foot slides")
        review.clearFlag(east,model:model)
        try await settle {!east.sending && service.writes.contains("media_suggestion_dismiss")}
        XCTAssertEqual(service.writes,["media_suggestion_dismiss"])
        let dismiss=try XCTUnwrap(service.params("media_suggestion_dismiss").first)
        XCTAssertEqual(dismiss["round_id"] as? String,"round");XCTAssertEqual(dismiss["suggestion_id"] as? String,"s-E")
        XCTAssertNil(review.recommendation(east));XCTAssertEqual(east.draft.note,"");XCTAssertEqual(east.status,"Flag cleared")
        XCTAssertNil(review.otherSuggestion(east),"The old advice line must not show the cleared flag")
        // A refresh reads the item again. The fake still lists the row as current; the flag stays gone.
        await model.waitUntilWritable()
        review.sync(scope:"project:round",rows:["N","E","SE"].map {Record(values:["id":"item-"+$0,"revision":4,"metadata":["direction":$0]])},draft:{_ in MediaOwnerDraft()},saveDraft:{_,_ in})
        await review.readStale {id in Record(values:service.item(String(id.dropFirst(5))))}
        XCTAssertTrue(review.cards["item-E"] === east);XCTAssertNil(review.recommendation(east))
        XCTAssertEqual(east.draft.note,"","The cleared flag's note does not come back");XCTAssertEqual(east.item.string("disposition"),"pending")
        XCTAssertEqual(service.writes,["media_suggestion_dismiss"],"Clearing a flag sends no decision")
        withExtendedLifetime(store) {}
    }
    func testClearedFlagCoversCurrentTargetButAllowsAcceptAdviceAndNewTargetFlags() async throws {
        let service=DraftService();service.suggestions=["E":[suggestion("first-flag","changes_requested",note:"Foot slides")]]
        let (review,model,store)=await openReview(service)
        let east=try XCTUnwrap(review.cards["item-E"])
        review.clearFlag(east,model:model)
        try await settle {!east.sending && service.writes.contains("media_suggestion_dismiss")}
        XCTAssertEqual(review.dismissedFlagTargets[east.id],Set([east.target.id]))
        // Different records, both flag choices and both sources, still refer to the cleared take.
        for (choice,source) in [("changes_requested","agent"),("needs_look","check")] {
            service.suggestions["E"]=[suggestion("new-"+choice,choice,note:"Flag returned",source:source)]
            review.apply(Record(values:service.item("E")),to:east)
            XCTAssertNil(review.recommendation(east));XCTAssertNil(review.otherSuggestion(east))
            XCTAssertEqual(east.draft.note,"")
        }
        service.suggestions["E"]=[suggestion("new-flag","needs_look"),suggestion("new-accept","accepted",note:"Looks good")]
        review.apply(Record(values:service.item("E")),to:east)
        XCTAssertEqual(review.recommendation(east)?.suggestionID,"new-accept","Clearing flags never dismisses Accept advice")
        var changed=service.item("E"),target=changed["target"] as? MediaValues ?? [:]
        target["id"]="pub-E-new";changed["target"]=target;changed["suggestions"]=[suggestion("next-take-flag","needs_look")]
        review.apply(Record(values:changed),to:east)
        XCTAssertEqual(review.recommendation(east)?.suggestionID,"next-take-flag","A new target can carry a flag of its own")
        withExtendedLifetime(store) {}
    }
    func testHintLinesShowAboveTheNote() async throws {
        let hint="Feet stay planted\n\nLoop at frame 8\nCape follows\nShadow under feet"
        let shown=MediaCardHints.shown(hint)
        XCTAssertEqual(shown.lines,["Feet stay planted","Loop at frame 8","Cape follows"]);XCTAssertTrue(shown.more,"The rest is in the details")
        XCTAssertEqual(MediaCardHints.shown("One line").lines,["One line"]);XCTAssertFalse(MediaCardHints.shown("One line").more)
        XCTAssertTrue(MediaCardHints.shown(nil).lines.isEmpty);XCTAssertTrue(MediaCardHints.shown("  \n ").lines.isEmpty)
        let service=DraftService();service.hints=["N":"Feet stay planted"]
        let (review,_,store)=await openReview(service)
        XCTAssertEqual(MediaCardHints.shown(try XCTUnwrap(review.cards["item-N"]).labelMetadata["hint"]).lines,["Feet stay planted"],"The card reads the item's hint field")
        withExtendedLifetime(store) {}
    }
    func testNotMadeCardForADirectionWithNoTake() async throws {
        XCTAssertEqual(MediaNotMade.directionChoices(schema()),["N","NE","E","SE","S","SW","W","NW"])
        let (review,_)=await loadedReview()
        XCTAssertTrue(review.sections.allSatisfy {$0.notMade.isEmpty},"No Not made card before the choices are known")
        review.directionChoices=MediaNotMade.directionChoices(schema());review.listComplete=true
        let section=try XCTUnwrap(review.sections.first)
        XCTAssertEqual(section.title,"Hero · Walk cycle");XCTAssertEqual(section.cards.count,3,"A Not made card is not a take card")
        XCTAssertEqual(section.notMade,["North-east","South","South-west","West","North-west"].map {"Hero · Walk cycle · "+$0+": Not made"})
        review.listComplete=false
        XCTAssertEqual(review.sections.first?.notMade,[],"A filtered or partial list shows no Not made card")
    }
}
