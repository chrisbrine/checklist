import SwiftUI
import AppKit
import AVFoundation
/// Scoped imports: Combine also declares `Record`.
import class Combine.AnyCancellable
import protocol Combine.Publisher
import ChecklistCore
import ChecklistIPC

/// CL-421: the plain card label, "character · action · direction · take". It is built only
/// from the item's field values, never from a field ID, the item title or a file name.
/// A missing value shows its stated fallback.
enum MediaTakeLabel {
    static let fallbacks = ["character":"Character not set","animation_label":"Action not set","direction":"Direction not set","take":"Take not set"]
    static let directionWords = ["N":"North","NE":"North-east","E":"East","SE":"South-east","S":"South","SW":"South-west","W":"West","NW":"North-west"]
    private static let directionNames = Dictionary(uniqueKeysWithValues:directionWords.values.map {(squeezed($0),$0)})
    static func value(_ raw: Any?) -> String? {
        if let text=raw as? String {let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines);return trimmed.isEmpty ? nil : trimmed}
        if let number=raw as? NSNumber {return number.stringValue}
        return nil
    }
    /// A token such as "walk_cycle" or "hero__idle" reads as words: "Walk cycle", "Hero idle".
    static func words(_ value: String) -> String {
        let text=value.split(whereSeparator:{$0=="_" || $0==" "}).joined(separator:" ")
        guard let first=text.first else {return ""}
        return first.uppercased()+text.dropFirst()
    }
    private static func squeezed(_ value: String) -> String {value.uppercased().filter {$0.isLetter}}
    static func character(_ raw: Any?) -> String {value(raw).map(words) ?? fallbacks["character"]!}
    static func action(_ raw: Any?) -> String {value(raw).map(words) ?? fallbacks["animation_label"]!}
    /// Compass codes and spelled names both show as plain words: "SE" and "south_east" show "South-east".
    static func direction(_ raw: Any?) -> String {
        guard let text=value(raw) else {return fallbacks["direction"]!}
        let key=squeezed(text)
        return directionWords[key] ?? directionNames[key] ?? words(text)
    }
    static func take(_ raw: Any?) -> String {
        guard let text=value(raw) else {return fallbacks["take"]!}
        if Double(text) != nil {return "Take "+text}
        let plain=words(text)
        return plain.lowercased().hasPrefix("take") ? plain : "Take "+plain
    }
    static func parts(_ metadata: MediaValues) -> [String] {
        [character(metadata["character"]),action(metadata["animation_label"]),direction(metadata["direction"]),take(metadata["take"])]
    }
    static func text(_ metadata: MediaValues) -> String {parts(metadata).joined(separator:" · ")}
    static func group(_ metadata: MediaValues) -> String {parts(metadata).prefix(2).joined(separator:" · ")}
}

/// The simple card layout applies to the "Animation takes" layout (looping video_compare
/// with character, action and direction fields). The schema validator accepts no autoplay or
/// poster key, so an absent key means the starter default: a looping video_compare take plays
/// at once, and its still frame (the poster) is the take's first frame.
enum MediaSimpleLayout {
    static func usesCards(_ schema: MediaValues) -> Bool {MediaAnimationGroup.supports(schema)}
    static func autoplay(_ layout: MediaValues) -> Bool {
        layout["autoplay"] as? Bool ?? (layout["kind"] as? String == "video_compare" && layout["loop"] as? Bool == true)
    }
    static func startsPlaying(layout: MediaValues,reduceMotion: Bool,pausedByOwner: Bool) -> Bool {
        autoplay(layout) && !reduceMotion && !pausedByOwner
    }
    /// The three owner decisions on every card. No direction grid or other screen comes first.
    static let decisions: [MediaSimpleDecision] = [.init(title:"Accept",disposition:"accepted"),.init(title:"Changes requested",disposition:"changes_requested"),.init(title:"Needs look",disposition:"needs_look")]
}
struct MediaSimpleDecision: Identifiable, Equatable {
    let title: String
    let disposition: String
    var id: String {disposition}
}

extension MediaDirectionCard {
    var labelMetadata: MediaValues {
        let target=target.object("metadata")
        return target.isEmpty ? item.object("metadata") : target
    }
    var label: String {MediaTakeLabel.text(labelMetadata)}
}

struct MediaSimpleSection: Identifiable {
    let id: String
    let title: String
    let cards: [MediaDirectionCard]
}

/// The prepared takes of the simple card review, kept by take key. A prepared take that does
/// not play stays paused. At most `MediaSimpleReviewModel.preparedTakes` takes are prepared
/// and at most `MediaSimpleReviewModel.playingTakes` play. The model decides which.
@MainActor final class MediaSimpleTakeCache: ObservableObject, MediaTakePreparationBudget {
    /// The byte and pixel totals are the direction-grid totals times preparedTakes / directionGridTakes (3),
    /// so each prepared take keeps the same average share as a direction-grid take.
    static let scale = MediaSimpleReviewModel.preparedTakes / MediaPlaybackBudget.directionGridTakes
    static let cacheBytes = MediaPlaybackBudget.directionGridCacheBytes * scale
    static let cachePixels = MediaPlaybackBudget.directionGridPixels * scale
    @Published private(set) var takes: [String: MediaPreparedTake] = [:]
    @Published private(set) var playingKeys = Set<String>()
    private var preparing: String?
    private var observations: [String: AnyCancellable] = [:]
    var cachedBytes: Int {takes.values.reduce(0) {$0+$1.measurement.bytes}}
    var cachedPixels: Int {takes.values.reduce(0) {$0+$1.measurement.facts.width*$1.measurement.facts.height}}
    func beginPreparation(_ key: String) -> Bool {
        guard preparing == nil || preparing == key else {return false}
        preparing=key;return true
    }
    func endPreparation(_ key: String) {if preparing == key {preparing=nil}}
    /// Checked before a native player is made, and again when the take is admitted.
    func gridAllows(bytes: Int,facts: MediaPlaybackBudget.Facts) -> Bool {
        guard takes.count < MediaSimpleReviewModel.preparedTakes,bytes > 0,bytes <= MediaPlaybackBudget.directionGridOriginalBytes,
              cachedBytes+bytes <= Self.cacheBytes,facts.width > 0,facts.height > 0,facts.width <= 1024,facts.height <= 1024 else {return false}
        return cachedPixels+facts.width*facts.height <= Self.cachePixels
    }
    @discardableResult func admit(_ take: MediaPreparedTake) -> Bool {
        release(take.key)
        guard take.kind == "video",gridAllows(bytes:take.measurement.bytes,facts:take.measurement.facts) else {take.control.unload();return false}
        takes[take.key]=take
        if let player=take.player {
            // The inline native controls can start or stop a take directly.
            observations[take.key]=player.publisher(for:\.timeControlStatus).receive(on:DispatchQueue.main).sink {[weak self,key=take.key] status in
                MainActor.assumeIsolated {
                    guard let self else {return}
                    if status == .paused {self.stopped(key)} else if self.takes[key] != nil,!self.playingKeys.contains(key) {self.playingKeys.insert(key)}
                }
            }
        }
        return true
    }
    /// Plays a prepared take. It refuses when `limit` takes already play.
    @discardableResult func play(_ key: String,limit: Int = MediaSimpleReviewModel.playingTakes) -> Bool {
        guard let take=takes[key],playingKeys.contains(key) || playingKeys.count < limit else {return false}
        if !playingKeys.contains(key) {playingKeys.insert(key)}
        take.control.play();return true
    }
    /// Plays the prepared players of one card together: all of them or none. It refuses when
    /// they do not all fit under `limit` playing players.
    @discardableResult func play(_ keys: [String],limit: Int) -> Bool {
        let waiting=keys.filter {takes[$0] != nil && !playingKeys.contains($0)}
        guard !waiting.isEmpty,playingKeys.count+waiting.count <= limit else {return false}
        for key in waiting {play(key,limit:limit)}
        return true
    }
    /// Moves a prepared player back to its first frame, without a play or pause.
    func rewind(_ key: String) {takes[key]?.player?.seek(to:.zero)}
    /// Pauses a take. With `rewind` it goes back to its first frame.
    func pause(_ key: String,rewind: Bool = false) {
        guard let take=takes[key] else {return}
        take.control.pause()
        if rewind {take.player?.seek(to:.zero)}
        stopped(key)
    }
    func pauseAll() {for key in Array(takes.keys) {pause(key)}}
    func release(_ key: String) {
        guard let take=takes.removeValue(forKey:key) else {return}
        observations[key]=nil;take.control.unload();take.player?.replaceCurrentItem(with:nil)
        stopped(key)
    }
    func releaseAll() {for key in Array(takes.keys) {release(key)}}
    private func stopped(_ key: String) {if playingKeys.contains(key) {playingKeys.remove(key)}}
}

/// One native player of a card: the take (`slotID` nil, the layout's primary slot) or the
/// card's video reference (`slotID` is that declared reference slot).
struct MediaSimplePlayer: Equatable {
    let key: String
    let slotID: String?
    var isReference: Bool {slotID != nil}
}

/// The reference shown beside a card's take. `kind` is "image" or "video".
struct MediaSimpleReference {
    let slot: Record
    let original: Record
    let kind: String
}

/// One card per item (one direction of one move). Cards and their players are kept by item
/// ID. A card holds one player for its take, and a second one when its reference is a video.
/// Both players count against `preparedTakes` and `playingTakes`. A refresh diffs the rows by
/// ID: an unchanged row keeps its card, item and playing take; a changed row reads only that
/// item again and updates its card in place.
///
/// Take window: the views report which cards are on screen. The window is the visible cards plus
/// `preloadCards` cards before and after them. Each card in the window gets a prepared take, one
/// at a time, nearest to the visible cards first. Only visible cards play; the other prepared
/// takes stay paused at their first frame. A take is released only when its card leaves the
/// window (or its card or target goes). At `preparedTakes` the take farthest from the visible
/// cards is released first, and never for a card that is farther away.
@MainActor final class MediaSimpleReviewModel: ObservableObject {
    /// Cards before and after the visible cards that get a take ahead of time: two rows of a
    /// three-column grid (three rows at two columns, one and a half rows at four).
    static let preloadCards = 6
    /// The most prepared takes (native players) at once.
    static let preparedTakes = 24
    /// The most takes that play at once: the direction-grid budget.
    static let playingTakes = MediaPlaybackBudget.directionGridTakes
    /// How a player is made for a card: its take, or its video reference (`player.slotID`).
    /// The view supplies the native preparation; tests supply fakes.
    struct TakeSource {
        var schema: @MainActor (MediaDirectionCard) -> MediaValues
        var prepare: @MainActor (MediaDirectionCard,MediaValues,MediaSimplePlayer,@escaping @MainActor () -> Bool) async throws -> MediaPreparedTake
    }
    @Published private(set) var order: [String] = []
    @Published var pausedByOwner = false
    private(set) var cards: [String: MediaDirectionCard] = [:]
    private(set) var stale = Set<String>()
    private(set) var visible = Set<String>()
    private(set) var header = Record(values: [:])
    private var rowValues: [String: NSDictionary] = [:]
    private var groupTitles: [String: String] = [:]
    private(set) var scope = ""
    private var readingItems = false
    var referenceImages: [String: NSImage] = [:]
    let playback = MediaSimpleTakeCache()
    var source: TakeSource?
    var reduceMotion = false
    /// The prepared-take bound in use. It is `preparedTakes`; a test can set a smaller one.
    var preparedLimit = MediaSimpleReviewModel.preparedTakes
    /// The order indices from the first to the last visible card. It stays when no card is on
    /// screen for a moment (a scroll step or a refresh), so that no take is released then.
    private(set) var focus: ClosedRange<Int>?
    private var failedKeys = Set<String>()
    private var pump: Task<Void,Never>?
    private var pumpGeneration = 0
    var orderedCards: [MediaDirectionCard] {order.compactMap {cards[$0]}}
    var sections: [MediaSimpleSection] {
        var result: [MediaSimpleSection] = [],seen: [String: Int] = [:]
        for card in orderedCards {
            let title=groupTitles[card.id] ?? MediaTakeLabel.group(card.labelMetadata)
            if let last=result.last,last.title==title {result[result.count-1]=MediaSimpleSection(id:last.id,title:title,cards:last.cards+[card]);continue}
            let index=seen[title,default:0];seen[title]=index+1
            result.append(MediaSimpleSection(id:title+"#"+String(index),title:title,cards:[card]))
        }
        return result
    }
    /// The layout of the card's type revision.
    func layout(_ card: MediaDirectionCard) -> MediaValues {
        let schema=source?.schema(card) ?? (card.header.object("type_revision")["schema"] as? MediaValues) ?? [:]
        return schema["layout"] as? MediaValues ?? [:]
    }
    /// The card's reference player, when its chosen reference is a video. The key holds the
    /// reference ID, so a changed reference gets a new player.
    func referencePlayer(_ card: MediaDirectionCard) -> MediaSimplePlayer? {
        guard let reference=Self.reference(item:card.item,layout:layout(card)),reference.kind=="video" else {return nil}
        return MediaSimplePlayer(key:"reference:"+card.key+":"+reference.original.string("reference_id"),slotID:reference.slot.string("slot_id"))
    }
    /// The card's players: the take first, then a video reference.
    func players(_ card: MediaDirectionCard) -> [MediaSimplePlayer] {
        [MediaSimplePlayer(key:card.key,slotID:nil)]+(referencePlayer(card).map {[$0]} ?? [])
    }
    func keys(_ card: MediaDirectionCard) -> [String] {players(card).map(\.key)}
    /// True when a player of the card plays.
    func isPlaying(_ card: MediaDirectionCard) -> Bool {keys(card).contains {playback.playingKeys.contains($0)}}

    func reset() {
        pump?.cancel();pump=nil;pumpGeneration+=1;playback.releaseAll()
        cards=[:];rowValues=[:];groupTitles=[:];stale=[];visible=[];focus=nil;failedKeys=[];referenceImages=[:]
        if !order.isEmpty {order=[]}
    }
    /// A changed round header moves into each card in place; an unchanged one changes nothing.
    func update(header next: Record) {
        guard !MediaReviewModel.sameRecord(header,next) else {return}
        header=next
        for card in cards.values where !MediaReviewModel.sameRecord(card.header,next) {card.header=next}
    }
    /// Diffs the list rows by stable item ID. Returns the IDs whose item must be read.
    @discardableResult func sync(scope next: String,rows: [Record],draft: (Record) -> MediaOwnerDraft,saveDraft: @escaping (String,MediaOwnerDraft) -> Void) -> Set<String> {
        if next != scope {reset();scope=next}
        var ids: [String] = [],seen=Set<String>(),changed=Set<String>()
        for row in rows where !row.id.isEmpty && seen.insert(row.id).inserted {
            ids.append(row.id)
            let values=NSDictionary(dictionary:row.values)
            groupTitles[row.id]=MediaTakeLabel.group(row.object("metadata"))
            if cards[row.id] == nil {
                let id=row.id
                cards[id]=MediaDirectionCard(item:row,header:header,draft:draft(row),saveDraft:{saveDraft(id,$0)})
            } else if rowValues[row.id] == values {continue}
            rowValues[row.id]=values;changed.insert(row.id)
        }
        for id in Array(cards.keys) where !seen.contains(id) {
            if let card=cards.removeValue(forKey:id) {for key in keys(card) {playback.release(key)}}
            rowValues[id]=nil;groupTitles[id]=nil;stale.remove(id);visible.remove(id)
        }
        stale.formUnion(changed)
        if ids != order {order=ids}
        schedule()
        return changed
    }
    /// Reads each changed item, one at a time, in list order. Only that card changes.
    func readStale(_ read: @escaping @MainActor (String) async throws -> Record) async {
        guard !readingItems else {return}
        readingItems=true
        defer {readingItems=false}
        while let id=order.first(where:{stale.contains($0)}),!Task.isCancelled {
            stale.remove(id)
            let current=scope
            do {
                let item=try await read(id)
                guard scope==current,let card=cards[id] else {continue}
                apply(item,to:card)
            } catch is CancellationError {stale.insert(id);return}
            catch {if scope==current {cards[id]?.status=PlainError.text(error)}}
        }
    }
    /// Updates one card in place. The take is kept unless the reviewed target changed; the video
    /// reference is kept unless the target or the chosen reference changed.
    func apply(_ item: Record,to card: MediaDirectionCard) {
        guard !MediaReviewModel.sameRecord(card.item,item) else {return}
        let previous=keys(card)
        card.item=item
        let current=keys(card)
        if current != previous {
            for key in previous where !current.contains(key) {playback.release(key)}
            schedule()
        }
        if card.draft.basis.isEmpty,!card.target.id.isEmpty {card.inspectCurrentBasis()}
    }

    /// The order indices of the cards that keep a take: the visible cards and `preloadCards` on each side.
    var window: ClosedRange<Int>? {
        guard let focus,!order.isEmpty else {return nil}
        let low=max(0,focus.lowerBound-Self.preloadCards),high=min(order.count-1,focus.upperBound+Self.preloadCards)
        return low <= high ? low...high : nil
    }
    /// How many cards an order index is from the nearest visible card (0 for a visible card).
    func distance(_ index: Int) -> Int {
        guard let focus else {return Int.max}
        return index < focus.lowerBound ? focus.lowerBound-index : index > focus.upperBound ? index-focus.upperBound : 0
    }
    /// The order index of each player key (take and video reference).
    private func positions() -> [String: Int] {
        var result: [String: Int] = [:]
        for i in order.indices {if let card=cards[order[i]] {for key in keys(card) where result[key] == nil {result[key]=i}}}
        return result
    }
    /// The player keys of the card at an order index.
    private func keys(at index: Int?) -> [String] {
        guard let index,order.indices.contains(index),let card=cards[order[index]] else {return []}
        return keys(card)
    }
    /// A card came on screen, or its take changed. The window moves to it and its take plays when it is ready.
    func cardShown(_ card: MediaDirectionCard,reduceMotion: Bool) {
        self.reduceMotion=reduceMotion
        visible.insert(card.id)
        schedule()
        start(card)
    }
    /// A card left the screen. Its players pause at their first frame and stay prepared while the card is in the window.
    func cardLeft(_ card: MediaDirectionCard) {
        visible.remove(card.id)
        for key in keys(card) {playback.pause(key,rewind:true)}
        schedule()
    }
    /// Moves the window to the visible cards, releases each take whose card left it, and starts
    /// the preparation of the missing takes. With no card on screen the last window stays.
    private func schedule() {
        let shown=order.indices.filter {visible.contains(order[$0])}
        if let low=shown.first,let high=shown.last {
            focus=low...high
            let keep=Set(window.map {$0.flatMap {keys(at:$0)}} ?? [])
            for key in Array(playback.takes.keys) where !keep.contains(key) {playback.release(key)}
            failedKeys.formIntersection(keep)
        }
        guard pump == nil,source != nil,window != nil else {return}
        pumpGeneration+=1
        let generation=pumpGeneration
        pump=Task {[weak self] in await self?.prepareWindow(generation)}
    }
    /// The player in the window that is missing and nearest to the visible cards. A card's take
    /// comes before its video reference.
    private func nextPlayer() -> (card: MediaDirectionCard,index: Int,player: MediaSimplePlayer)? {
        guard let window else {return nil}
        var best: (card: MediaDirectionCard,index: Int,player: MediaSimplePlayer,rank: (Int,Int,Int))?
        for i in window {
            guard let card=cards[order[i]],!card.target.id.isEmpty else {continue}
            for (n,player) in players(card).enumerated() where playback.takes[player.key] == nil && !failedKeys.contains(player.key) {
                let rank=(distance(i),i,n)
                if best == nil || rank < best!.rank {best=(card,i,player,rank)}
            }
        }
        return best.map {($0.card,$0.index,$0.player)}
    }
    /// Releases the prepared players farthest from the visible cards until one more fits. Both
    /// players of a card go together. It never releases a player that is as near as the waiting
    /// card; then it returns false.
    private func makeRoom(for index: Int) -> Bool {
        guard playback.takes.count >= preparedLimit else {return true}
        let positions=positions()
        let rank: (String) -> (Int,Int) = {key in positions[key].map {(self.distance($0),$0)} ?? (Int.max,Int.max)}
        while playback.takes.count >= preparedLimit {
            guard let farthest=playback.takes.keys.max(by:{rank($0) < rank($1)}),rank(farthest).0 > distance(index) else {return false}
            for key in Set([farthest]+keys(at:positions[farthest])) {playback.release(key)}
        }
        return true
    }
    /// Prepares one take at a time, nearest first, until each card in the window has one or the
    /// bound stops it. A take that is not current any more (its card left the window, its target
    /// changed or the round changed) is unloaded.
    private func prepareWindow(_ generation: Int) async {
        defer {if pumpGeneration == generation {pump=nil}}
        while !Task.isCancelled,pumpGeneration == generation,let source,let next=nextPlayer(),makeRoom(for:next.index) {
            let card=next.card,player=next.player,key=player.key,cardKey=card.key,id=card.id,scope=scope
            let current: @MainActor () -> Bool = {[weak self] in
                guard let self,self.scope == scope,card.key == cardKey,self.keys(card).contains(key),let window=self.window,let i=self.order.firstIndex(of:id) else {return false}
                return window.contains(i)
            }
            let report: (String) -> Void = {text in if player.isReference {card.referenceStatus=text} else {card.status=text}}
            do {
                let take=try await source.prepare(card,source.schema(card),player,current)
                guard current() else {take.control.unload();continue}
                take.player?.isMuted=true
                guard playback.admit(take) else {
                    failedKeys.insert(key)
                    report(player.isReference ? "This reference is over the playback limit for cards. Open it in item comparison." : "This take is over the playback limit for cards. Open it in item comparison.")
                    continue
                }
                report("")
                start(card,admitted:player)
            } catch {
                // A failed player is not tried again until its card leaves the window and comes back.
                guard current() else {continue}
                failedKeys.insert(key)
                if !(error is CancellationError) {report(PlainError.text(error))}
            }
        }
    }
    /// A visible card plays its prepared players together (take and video reference), muted and
    /// looped, unless Reduce Motion or the owner's Pause keeps the still first frame, and only
    /// when all of them fit in the play budget. A video reference that becomes ready after its
    /// take follows the take: it plays only when the take plays, and the take goes back to its
    /// first frame so that both loops start together.
    private func start(_ card: MediaDirectionCard,admitted: MediaSimplePlayer? = nil) {
        guard let source,visible.contains(card.id) else {return}
        if let admitted,admitted.isReference,playback.takes[card.key] != nil {
            guard playback.playingKeys.contains(card.key),playback.playingKeys.count < Self.playingTakes else {return}
            playback.rewind(card.key)
            playback.play([admitted.key],limit:Self.playingTakes)
            return
        }
        let ready=keys(card).filter {playback.takes[$0] != nil}
        guard !ready.isEmpty,!ready.contains(where:{playback.playingKeys.contains($0)}) else {return}
        let layout=source.schema(card)["layout"] as? MediaValues ?? [:]
        guard MediaSimpleLayout.startsPlaying(layout:layout,reduceMotion:reduceMotion,pausedByOwner:pausedByOwner) else {return}
        playback.play(ready,limit:Self.playingTakes)
    }
    /// The card's Play or Pause. It acts on both players of the card together. At the play
    /// budget the owner's Play pauses the cards farthest from this card until its players fit.
    func toggle(_ card: MediaDirectionCard) {
        let ready=keys(card).filter {playback.takes[$0] != nil}
        if ready.contains(where:{playback.playingKeys.contains($0)}) {for key in ready {playback.pause(key)};return}
        if let index=order.firstIndex(of:card.id) {
            let positions=positions()
            let far: (String) -> Int = {positions[$0].map {abs($0-index)} ?? Int.max}
            while playback.playingKeys.count+ready.count > Self.playingTakes,let other=playback.playingKeys.max(by:{(far($0),$0) < (far($1),$1)}) {
                for key in Set([other]+keys(at:positions[other])) {playback.pause(key)}
            }
        }
        playback.play(ready,limit:Self.playingTakes)
    }
    func pauseAll() {pausedByOwner=true;playback.pauseAll()}
    /// Plays the prepared players of the visible cards, in list order, within the play budget.
    /// A card plays both of its players or none.
    func playAll() {
        pausedByOwner=false
        for id in order where visible.contains(id) {if let card=cards[id] {playback.play(keys(card),limit:Self.playingTakes)}}
    }
    /// Waits until the current preparation pass ends (tests).
    func settle() async {while let task=pump {await task.value}}
    /// The fallback text of a card with no reference.
    static let noReference = "No reference"
    /// The reference shown beside the take (CL-421). Only the references that the layout declares
    /// (`reference_slot_ids`) and that are available count, in layout order. Rule: the first
    /// video reference (the earlier take) wins, because the owner compares takes; with no video
    /// reference, the first image reference. A slot whose captured kind is not image or video,
    /// or whose original is not available, is skipped. Nil means no reference ("No reference").
    static func reference(item: Record,layout: MediaValues) -> MediaSimpleReference? {
        let ids=MediaComparisonLabels.referenceSlotIDs(layout)
        guard let candidate=item.records("candidates").first else {return nil}
        let slots=candidate.records("slots").filter {ids.contains($0.string("slot_id"))}.sorted {(ids.firstIndex(of:$0.string("slot_id")) ?? 0)<(ids.firstIndex(of:$1.string("slot_id")) ?? 0)}
        var image: MediaSimpleReference?
        for slot in slots {
            guard let original=item.records("originals").first(where:{$0.string("attachment_id")==slot.string("attachment_id")}) else {continue}
            if MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:"video") == .playback("video") {
                return MediaSimpleReference(slot:slot,original:original,kind:"video")
            }
            if image == nil,MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:"image") == .image {
                image=MediaSimpleReference(slot:slot,original:original,kind:"image")
            }
        }
        return image
    }
    /// The existing owner decision route: the native command journal through `media_decide`.
    func decide(_ disposition: String,card: MediaDirectionCard,model: MediaReviewModel) async {
        guard !card.sending else {return};card.sending=true
        var dispatched=false
        let scope=scope
        defer {if !dispatched {card.sending=false}}
        do {
            var params=try card.decisionRequest(disposition)
            let current=Record(values:try await model.read("media_round_header",["round_id":card.header.id]))
            guard current.string("observed_context_token")==card.header.string("observed_context_token"),
                  NSDictionary(dictionary:current.object("manifest")).isEqual(to:card.header.object("manifest")),current.records("attention").isEmpty,
                  self.scope==scope else {throw ChecklistError("MEDIA_CONTEXT_CHANGED","The round context changed. Inspect this take again before deciding.")}
            params["expected_revision"]=current.integer("revision")
            dispatched=true
            model.mutateReportingFailure("media_decide",params,onFailure:{error in card.sending=false;card.status=PlainError.text(error)}) {reply in
                card.sending=false
                if let decision=(reply["decisions"] as? [MediaValues])?.first,
                   decision["item_id"] as? String==card.id,decision["target_id"] as? String==card.target.id {
                    var values=card.item.values;values["disposition"]=disposition;values["decision"]=decision
                    values["revision"]=card.item.integer("revision")+1;card.item=Record(values:values)
                    card.status="Saved: "+MediaReviewModel.dispositionLabel(disposition)
                }
            }
        } catch {card.status=PlainError.text(error)}
    }
}

/// CL-421: the default review of an "Animation takes" round. Each card plays its take at once,
/// beside its reference, with a plain label and the three owner decisions.
struct MediaSimpleReview: View {
    @ObservedObject var model: MediaReviewModel
    @StateObject private var simple = MediaSimpleReviewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scope: String {model.projectID+":"+model.roundID}
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(MediaReviewModel.countsText(model.counts)).font(.caption).foregroundStyle(Color.checklistSecondaryText)
                    Spacer()
                    if simple.pausedByOwner || (reduceMotion && simple.playback.playingKeys.isEmpty) {
                        Button("Play all takes") {simple.playAll()}
                    } else {Button("Pause all takes") {simple.pauseAll()}}
                }
                if reduceMotion {Text("Reduce Motion is on. Takes show a still frame. Press Play on a card to watch it.").font(.caption)}
                if model.rows.isEmpty,!model.loading {Text("No items in this round for the current filter.").foregroundStyle(Color.checklistSecondaryText)}
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(simple.sections) {section in
                        Text(section.title).font(.title3).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:380),alignment:.top)],alignment:.leading,spacing:12) {
                            ForEach(section.cards) {card in
                                MediaSimpleCardView(card:card,simple:simple,playback:simple.playback,model:model,reduceMotion:reduceMotion)
                            }
                        }
                    }
                }
                if model.next != nil {Button("Load more items") {Task {await model.moreRows()}}}
            }.padding(8)
        }
        .accessibilityIdentifier("mediaSimpleReview")
        .onReceive(model.$header) {simple.update(header:$0)}
        .onReceive(model.$rows) {rows in sync(rows)}
        .onDisappear {simple.reset()}
    }
    func sync(_ rows: [Record]) {
        if simple.source == nil {
            let review=simple
            simple.source = .init(
                schema:{[weak model] card in card.header.object("type_revision")["schema"] as? MediaValues ?? model?.schema ?? [:]},
                prepare:{[weak model,weak review] card,schema,player,current in
                    guard let model,let review,!model.projectID.isEmpty else {throw CancellationError()}
                    return try await MediaDirectionTakePreparation.prepare(card,model:model,schema:schema,playback:review.playback,referenceSlotID:player.slotID,key:player.key,isCurrent:current)
                })
        }
        let header=simple.header
        let changed=simple.sync(scope:scope,rows:rows,draft:{model.ownerDraft(for:$0,header:header)},saveDraft:{[weak model] id,value in model?.saveOwnerDraft(value,itemID:id)})
        guard !changed.isEmpty else {return}
        let round=model.roundID
        Task {await simple.readStale {id in Record(values:try await model.read("media_item_get",["round_id":round,"item_id":id]))}}
    }
}

private struct MediaSimpleCardView: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var card: MediaDirectionCard
    let simple: MediaSimpleReviewModel
    @ObservedObject var playback: MediaSimpleTakeCache
    let model: MediaReviewModel
    let reduceMotion: Bool
    @State private var showDetails = false
    var schema: MediaValues {card.header.object("type_revision")["schema"] as? MediaValues ?? model.schema}
    var layout: MediaValues {schema["layout"] as? MediaValues ?? [:]}
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.firstTextBaseline) {
                Text(card.label).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(MediaReviewModel.dispositionLabel(card.item.string("disposition",fallback:"pending"))).font(.caption)
                Button {showDetails.toggle()} label: {Image(systemName:"info.circle")}.buttonStyle(.plain)
                    .accessibilityLabel("Details, "+card.label).help("Show item details")
                    .popover(isPresented:$showDetails) {details}
            }
            HStack(alignment:.top,spacing:8) {
                take.frame(minWidth:180,maxWidth:.infinity,minHeight:160,maxHeight:220)
                MediaSimpleReferenceView(card:card,simple:simple,playback:playback,model:model,layout:layout).frame(width:150)
            }
            if let suggestion=MediaComparisonLabels.suggestions(item:card.item).first(where:\.isCurrent) {
                Text("Agent suggests: "+suggestion.choice).font(.caption).foregroundStyle(Color.checklistSecondaryText)
            }
            TextField("Owner note",text:$card.draft.note,axis:.vertical).lineLimit(1...3)
                .accessibilityLabel("Owner note for "+card.label)
            if !card.basisMatches,!card.target.id.isEmpty {
                Button("I inspected this target and context") {card.inspectCurrentBasis()}
            }
            HStack {
                ForEach(MediaSimpleLayout.decisions) {choice in
                    Button(choice.title) {Task {await simple.decide(choice.disposition,card:card,model:model)}}
                        .checklistDisabled([(MediaReviewModel.decisionRequiresNote(choice.disposition) && card.draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter what should change in the owner note.")])
                        .accessibilityLabel(choice.title+", "+card.label)
                }
            }.checklistDisabled([(card.sending,"Wait for this decision to finish."),(card.target.id.isEmpty,"This item is still loading."),(!card.basisMatches || !card.item.bool("published") || card.header.string("state") != "open" || model.historyOnly,"Inspect a published item in an open round before deciding."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            if !card.status.isEmpty {Text(card.status).font(.caption).textSelection(.enabled)}
        }
        .padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:6))
        .accessibilityElement(children:.contain).accessibilityLabel(card.label)
        .accessibilityIdentifier("mediaSimpleCard:"+card.id)
        .task(id:card.key) {simple.cardShown(card,reduceMotion:reduceMotion)}
        .onDisappear {simple.cardLeft(card)}
    }
    @ViewBuilder var take: some View {
        if let prepared=playback.takes[card.key],let player=prepared.player {
            ZStack(alignment:.bottomTrailing) {
                NativePlayerAdapter(player:player,audio:false).accessibilityLabel("Take, "+card.label)
                // One control for both players of the card (the take and a video reference).
                Button(simple.isPlaying(card) ? "Pause" : "Play") {simple.toggle(card)}
                    .accessibilityLabel((simple.isPlaying(card) ? "Pause " : "Play ")+card.label).padding(6)
            }
        } else {
            Text(card.status.isEmpty || card.status.hasPrefix("Saved") ? "Preparing take…" : card.status)
                .font(.caption).foregroundStyle(Color.checklistSecondaryText).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    /// Technical text stays out of the card. It is available here on request.
    var details: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(card.label).font(.headline)
            Text("Item: "+card.item.string("title")).textSelection(.enabled)
            if let hint=card.labelMetadata["hint"] as? String,!hint.isEmpty {Text("Hint: "+hint).textSelection(.enabled)}
            if let prepared=playback.takes[card.key] {
                Text(MediaPlaybackLabels.playback(loop:true,frameRate:prepared.measurement.timing?.declaredFrameRate))
                Text(MediaPlaybackLabels.measurement(prepared.measurement)).textSelection(.enabled)
            }
            ForEach(card.labelMetadata.keys.sorted(),id:\.self) {key in Text(key+": "+String(describing:card.labelMetadata[key]!)).textSelection(.enabled)}
        }.font(.caption).padding(12).frame(maxWidth:360,alignment:.leading)
    }
}

/// The card's reference, beside the take (rule: `MediaSimpleReviewModel.reference`). A video
/// reference is the card's second player: the model prepares it in the take window and plays it
/// with the take. A decoded image is kept by reference ID, so a refresh never reads or decodes
/// it again.
private struct MediaSimpleReferenceView: View {
    @ObservedObject var card: MediaDirectionCard
    let simple: MediaSimpleReviewModel
    @ObservedObject var playback: MediaSimpleTakeCache
    let model: MediaReviewModel
    let layout: MediaValues
    @State private var image: NSImage?
    @State private var status = ""
    var reference: MediaSimpleReference? {MediaSimpleReviewModel.reference(item:card.item,layout:layout)}
    /// The image reference ID to read; empty for a video reference.
    var key: String {reference.map {$0.kind == "image" ? $0.original.string("reference_id") : ""} ?? ""}
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            if let reference {
                let label=MediaComparisonLabels.slot(reference.slot,definitions:model.slots)
                if reference.kind == "video" {
                    if let player=simple.referencePlayer(card),let prepared=playback.takes[player.key],let native=prepared.player {
                        NativePlayerAdapter(player:native,audio:false).frame(minHeight:120,maxHeight:180).accessibilityLabel("Reference, "+label)
                    } else {Text(card.referenceStatus.isEmpty ? "Preparing reference…" : card.referenceStatus).font(.caption).foregroundStyle(Color.checklistSecondaryText)}
                } else if let image {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180).accessibilityLabel("Reference, "+label)}
                else {Text(status.isEmpty ? "Loading reference…" : status).font(.caption).foregroundStyle(Color.checklistSecondaryText)}
                Text(label).font(.caption2).foregroundStyle(Color.checklistSecondaryText)
            } else {Text(card.target.id.isEmpty ? "" : MediaSimpleReviewModel.noReference).font(.caption).foregroundStyle(Color.checklistSecondaryText)}
        }
        .task(id:key) {await load()}
    }
    func load() async {
        guard let reference,reference.kind == "image",!key.isEmpty else {image=nil;return}
        if let cached=simple.referenceImages[key] {image=cached;return}
        do {
            let value=try await model.read("media_original_read",["round_id":card.header.id,"item_id":card.id,"target_id":card.target.id,"reference_id":key])
            guard let data=Data(base64Encoded:value["base64"] as? String ?? "") else {throw MediaImageDecode.Failure.unavailable}
            let decoded=try await MediaImageDecode.decode(data,sha256:reference.slot.string("sha256"))
            guard !Task.isCancelled else {return}
            simple.referenceImages[key]=decoded;image=decoded
        } catch is CancellationError {
        } catch {status="Reference unavailable: "+PlainError.text(error)}
    }
}
