import XCTest
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
    func testReviewModelAssignsOnlyChangedLists() {
        var rows=[row("N"),row("E")]
        XCTAssertFalse(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E")]))
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("N"),row("E",disposition:"accepted")]))
        XCTAssertEqual(rows[1].string("disposition"),"accepted")
        XCTAssertTrue(MediaReviewModel.assignIfChanged(&rows,[row("E",disposition:"accepted"),row("N")]),"A new order is a change")
    }
}
