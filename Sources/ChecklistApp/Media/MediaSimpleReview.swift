import SwiftUI
import AppKit
import AVFoundation
import AVKit
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
    /// CL-422: the type schema's `layout.review_in_draft` Boolean. An absent key means false.
    static func reviewInDraft(_ schema: MediaValues) -> Bool {(schema["layout"] as? MediaValues)?["review_in_draft"] as? Bool ?? false}
    /// How a card's decision is sent. `open`: a published item in an open round (`media_decide`).
    /// `firstDraft`: an unpublished item of a Draft round whose type sets `review_in_draft`; the
    /// first decision publishes the round first. `unavailable`: no decision control works.
    enum DecisionRoute: Equatable {case open,firstDraft,unavailable}
    static func decisionRoute(state: String,published: Bool,schema: MediaValues,historyOnly: Bool) -> DecisionRoute {
        guard !historyOnly else {return .unavailable}
        if state=="open",published {return .open}
        if state=="draft",!published,reviewInDraft(schema) {return .firstDraft}
        return .unavailable
    }
    @MainActor static func schema(_ card: MediaDirectionCard,fallback: MediaValues) -> MediaValues {card.header.object("type_revision")["schema"] as? MediaValues ?? fallback}
    @MainActor static func decisionRoute(_ card: MediaDirectionCard,model: MediaReviewModel) -> DecisionRoute {
        decisionRoute(state:card.header.string("state"),published:card.item.bool("published"),schema:schema(card,fallback:model.schema),historyOnly:model.historyOnly)
    }
    /// CL-421 rework: the plain hint of a decision that needs a note ("Changes requested") while
    /// the note is empty. nil when the decision can be sent. The card shows it and uses it as help.
    static let changesNeedNote = "Write a note to request changes."
    static func noteHint(_ disposition: String,note: String) -> String? {
        MediaReviewModel.decisionRequiresNote(disposition) && note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? changesNeedNote : nil
    }
    /// CL-421 rework: card media layout. The take and its reference each get one half of the card,
    /// at least `mediaMinWidth` wide, in a fixed `mediaHeight` frame. The grid's column minimum
    /// gives a card two halves; a narrower card puts the reference under the take.
    static let mediaMinWidth: CGFloat = 190
    static let mediaHeight: CGFloat = 180
    static let mediaSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 8
    static let cardMinWidth: CGFloat = mediaMinWidth*2+mediaSpacing+cardPadding*2+16
    /// The video's width/height from its probe, for an aspect-fit frame with no letterbox. nil when unknown.
    static func aspect(width: Int,height: Int) -> CGFloat? {width>0 && height>0 ? CGFloat(width)/CGFloat(height) : nil}
}
struct MediaSimpleDecision: Identifiable, Equatable {
    let title: String
    let disposition: String
    var id: String {disposition}
}

/// CL-428: the recommended decision of a card: the newest current agent suggestion of the item
/// whose choice is one of the card's three decisions. A flag is a recommendation of "Changes
/// requested" or "Needs look". It is advice only: it never counts as an owner decision until the
/// owner keeps it, and it shows only while the item has no owner decision for its current target.
struct MediaCardRecommendation: Equatable {
    let suggestionID: String
    let disposition: String
    let note: String
    let author: String
    /// "agent" or "check" (a flag that a check produced).
    let source: String
    static let flagDispositions: Set<String> = ["changes_requested","needs_look"]
    var isFlag: Bool {Self.flagDispositions.contains(disposition)}
    var choiceTitle: String {MediaSimpleLayout.decisions.first {$0.disposition==disposition}?.title ?? MediaReviewModel.dispositionLabel(disposition)}
    /// The plain reason on the card. `source:"check"` is the posting agent's claim, so a check flag
    /// also names that agent.
    var reason: String {
        guard isFlag else {return choiceTitle+" suggested by "+author+" — keep or change it"}
        return source=="check" ? "Flagged from checks by "+author : "Flagged by "+author
    }
    /// True when the owner decided the item's current target. "pending" and "stale" are no decision.
    static func ownerDecided(_ item: Record) -> Bool {!["","pending","stale"].contains(item.string("disposition",fallback:"pending"))}
    /// The item read's current suggestions: `agent_suggestions` when present, else the current
    /// agent rows of `suggestions` (`stale` false). A dismissed suggestion (CL-428) is never current.
    static func current(item: Record,dismissed: Set<String> = [],flagsDismissed: Bool = false) -> MediaCardRecommendation? {
        guard !ownerDecided(item) else {return nil}
        let listed=item.records("agent_suggestions").filter {!$0.id.isEmpty && $0.values["stale"] as? Bool != true}
        let rows=listed.isEmpty ? item.records("suggestions").filter {$0.string("origin",fallback:"agent")=="agent" && $0.values["stale"] as? Bool == false} : listed
        let cardChoices=Set(MediaSimpleLayout.decisions.map(\.disposition))
        guard let row=rows.first(where:{!$0.id.isEmpty && !dismissed.contains($0.id) && $0.object("dismissed").isEmpty &&
            !(flagsDismissed && flagDispositions.contains($0.string("disposition"))) && cardChoices.contains($0.string("disposition"))}) else {return nil}
        let display=row.string("author_display").trimmingCharacters(in:.whitespacesAndNewlines)
        let label=row.string("source_label").trimmingCharacters(in:.whitespacesAndNewlines)
        return .init(suggestionID:row.id,disposition:row.string("disposition"),note:row.string("note"),
                     author:!display.isEmpty ? display : !label.isEmpty ? label : "an agent",source:row.string("source")=="check" ? "check" : "agent")
    }
}

/// CL-428: the item's `hint` field value as short plain lines above the note. The full hint is in
/// the details popover.
enum MediaCardHints {
    static let shownLines = 3
    static func lines(_ raw: Any?) -> [String] {
        guard let text=MediaTakeLabel.value(raw) else {return []}
        return text.split(whereSeparator:\.isNewline).map {$0.trimmingCharacters(in:.whitespaces)}.filter {!$0.isEmpty}
    }
    /// At most `shownLines` lines, and true when more lines exist.
    static func shown(_ raw: Any?) -> (lines: [String],more: Bool) {
        let all=lines(raw)
        return (Array(all.prefix(shownLines)),all.count > shownLines)
    }
}

/// CL-428: a "Not made" card for each direction choice of the type with no item for that
/// character and action in the round.
enum MediaNotMade {
    /// The type's `direction` field choices, in schema order.
    static func directionChoices(_ schema: MediaValues) -> [String] {
        let field=(schema["fields"] as? [MediaValues] ?? []).first {$0["id"] as? String=="direction"}
        return (field?["choices"] as? [Any] ?? []).compactMap {($0 as? String) ?? (($0 as? MediaValues).flatMap {($0["value"] ?? $0["id"]) as? String})}
    }
    /// The plain "Not made" texts by group title, in choice order. `entries` are the group title and
    /// the label metadata of each card. A group with no character or action value gets no card.
    static func missing(entries: [(group: String,metadata: MediaValues)],choices: [String]) -> [String: [String]] {
        var made: [String: Set<String>] = [:],order: [String] = []
        for entry in entries where MediaTakeLabel.value(entry.metadata["character"]) != nil && MediaTakeLabel.value(entry.metadata["animation_label"]) != nil {
            if made[entry.group] == nil {order.append(entry.group);made[entry.group]=[]}
            made[entry.group]!.insert(MediaTakeLabel.direction(entry.metadata["direction"]))
        }
        var words: [String] = []
        for choice in choices.map(MediaTakeLabel.direction) where !words.contains(choice) {words.append(choice)}
        var result: [String: [String]] = [:]
        for group in order {
            let texts=words.filter {!made[group]!.contains($0)}.map {group+" · "+$0+": Not made"}
            if !texts.isEmpty {result[group]=texts}
        }
        return result
    }
}

extension MediaDirectionCard {
    var labelMetadata: MediaValues {
        let target=target.object("metadata")
        return target.isEmpty ? item.object("metadata") : target
    }
    var label: String {MediaTakeLabel.text(labelMetadata)}
    /// Only the current owner head whose choice applies to the displayed basis can be removed.
    /// A carried choice can name the successor's Draft target: publication replaces that target
    /// while preserving the basis, so the current disposition and basis establish its applicability.
    var currentOwnerDecision: Record? {
        let decision=Record(values:item.object("decision"))
        let basis=decision.string("review_basis_signature")
        let applies=decision.string("target_id")==target.id || (!basis.isEmpty && basis==target.string("review_basis_signature"))
        guard MediaCardRecommendation.ownerDecided(item),!decision.id.isEmpty,
              applies,decision.string("disposition")==item.string("disposition") else {return nil}
        return decision
    }
    func isCurrentDecision(_ disposition: String) -> Bool {currentOwnerDecision?.string("disposition")==disposition}
    /// CL-428: remove the exact observed owner head without making another choice or changing its note.
    func withdrawalRequest() throws -> MediaValues {
        var p=try decisionRequest("needs_look")
        for key in ["disposition","note","winner_id","none_fit"] {p.removeValue(forKey:key)}
        guard let decision=currentOwnerDecision else {throw ChecklistError("MEDIA_BASIS_CHANGED","This take no longer has the current owner decision. Inspect it again.")}
        p["items"]=[["item_id":id,"expected_revision":item.integer("revision"),"decision_id":decision.id]]
        return p
    }
    func decisionNoteHint(_ disposition: String) -> String? {
        isCurrentDecision(disposition) ? nil : MediaSimpleLayout.noteHint(disposition,note:draft.note)
    }
    /// CL-428: the exact selection of `media_adopt_suggestion` for this card. It is the decision
    /// selection with no choice: the service copies the suggestion's own choice and note.
    func adoptionRequest(_ suggestionID: String) throws -> MediaValues {
        // "needs_look" adds no note or winner rule, so the request holds only the checked selection.
        var p=try decisionRequest("needs_look")
        for key in ["disposition","note","winner_id","none_fit"] {p.removeValue(forKey:key)}
        p["suggestion_id"]=suggestionID
        return p
    }
}

struct MediaSimpleSection: Identifiable {
    let id: String
    let title: String
    let cards: [MediaDirectionCard]
    /// CL-428: the plain "Not made" texts of this group.
    var notMade: [String] = []
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
/// Take window: the view reports the card frames, and a card is on screen (visible) when its frame
/// meets the scroll view's visible area. The window is the visible cards plus
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
    /// The visible card IDs in play order. From the view's frames: nearest to the middle of the
    /// visible area first. From `cardShown`: in report order.
    private(set) var priority: [String] = []
    /// Cards that the owner paused with the card's Pause. They stay paused after any scroll until
    /// the owner's Play on the card or "Play all takes".
    private(set) var ownerPaused = Set<String>()
    /// Visible cards that the owner played with the card's Play. They play first, also with
    /// Reduce Motion or "Pause all takes". A card leaves this set when it leaves the screen.
    private(set) var ownerPlayed = Set<String>()
    /// Cards paused to make room for the owner's Play. They play again last, when the budget frees.
    private(set) var yielded = Set<String>()
    /// The owner's "Play all takes": visible cards play also with Reduce Motion, until "Pause all takes".
    private(set) var ownerPlaysAll = false
    /// The last card frames (scroll view coordinates) and visible height that the view reported.
    private var cardFrames: [String: CGRect] = [:]
    private var viewportHeight: CGFloat = 0
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
    /// CL-428: the type's direction choices, for "Not made" cards. Empty: no "Not made" cards.
    var directionChoices: [String] = []
    /// CL-428: true when the cards are the whole round (filter "all", no further page). Only then
    /// can a direction with no card be "Not made".
    var listComplete = false
    /// CL-428: flags that the owner cleared in this round. They do not come back for that take.
    private(set) var dismissedSuggestions = Set<String>()
    /// A later suggestion cannot flag the same item target again in this round. Accept advice
    /// remains available, and a new target can still have its own flag.
    private(set) var dismissedFlagTargets: [String: Set<String>] = [:]
    /// CL-428: the suggestion whose note each card took as its draft note, by item ID.
    private var seededNotes: [String: String] = [:]
    var orderedCards: [MediaDirectionCard] {order.compactMap {cards[$0]}}
    var sections: [MediaSimpleSection] {
        var result: [MediaSimpleSection] = [],seen: [String: Int] = [:]
        var entries: [(group: String,metadata: MediaValues)] = []
        for card in orderedCards {
            let title=groupTitles[card.id] ?? MediaTakeLabel.group(card.labelMetadata)
            entries.append((title,card.labelMetadata))
            if let last=result.last,last.title==title {result[result.count-1]=MediaSimpleSection(id:last.id,title:title,cards:last.cards+[card]);continue}
            let index=seen[title,default:0];seen[title]=index+1
            result.append(MediaSimpleSection(id:title+"#"+String(index),title:title,cards:[card]))
        }
        guard listComplete,!directionChoices.isEmpty else {return result}
        var missing=MediaNotMade.missing(entries:entries,choices:directionChoices)
        for i in result.indices {if let texts=missing.removeValue(forKey:result[i].title) {result[i].notMade=texts}}
        return result
    }
    /// CL-428: the card's recommended decision, while the owner has no decision on its item.
    func recommendation(_ card: MediaDirectionCard) -> MediaCardRecommendation? {
        MediaCardRecommendation.current(item:card.item,dismissed:dismissedSuggestions,
            flagsDismissed:dismissedFlagTargets[card.id]?.contains(card.target.id) == true)
    }
    /// The older advice line is only for choices outside the card's three buttons. Otherwise it
    /// could show a cleared flag again as soon as its recommendation disappears.
    func otherSuggestion(_ card: MediaDirectionCard) -> MediaSuggestionPresentation? {
        let choices=Set(MediaSimpleLayout.decisions.map(\.disposition))
        let ids=Set(card.item.records("suggestions").filter {!choices.contains($0.string("disposition")) &&
            !dismissedSuggestions.contains($0.id) && $0.object("dismissed").isEmpty}.map(\.id))
        return MediaComparisonLabels.suggestions(item:card.item).first {$0.isCurrent && ids.contains($0.id)}
    }
    /// CL-428: a new recommendation puts its note in an empty note box once, as an editable draft.
    func seedRecommendationNote(_ card: MediaDirectionCard) {
        guard let recommendation=recommendation(card),seededNotes[card.id] != recommendation.suggestionID else {return}
        seededNotes[card.id]=recommendation.suggestionID
        if card.draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!recommendation.note.isEmpty {card.draft.note=recommendation.note}
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
        dismissedSuggestions=[];dismissedFlagTargets=[:];seededNotes=[:]
        // The last reported frames stay: the next `sync` takes the visible cards from them, also
        // when the view sends no new frames (its layout did not change).
        priority=[];ownerPaused=[];ownerPlayed=[];yielded=[];ownerPlaysAll=false
        if !order.isEmpty {order=[]}
    }
    /// A changed round header moves into each card in place; an unchanged one changes nothing.
    /// CL-422 rework (review 8b119aed R3): the publication in place moves the round from Draft to
    /// open. A card whose item was read again before this header arrived took its published target
    /// by lineage under the Draft header (`apply`), so its look held the Draft context token. It
    /// takes the open round's basis here, so it needs no inspection press and no reopen.
    func update(header next: Record) {
        guard !MediaReviewModel.sameRecord(header,next) else {return}
        header=next
        for card in cards.values where !MediaReviewModel.sameRecord(card.header,next) {
            let published=card.header.id==next.id && card.header.string("state")=="draft" && next.string("state")=="open"
            card.header=next
            let target=card.target,lineage=target.string("published_from_target_id")
            if published,!target.id.isEmpty,!lineage.isEmpty,
               card.draft.targetID==target.id || card.draft.targetID==lineage {card.inspectCurrentBasis()}
        }
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
                seedRecommendationNote(cards[id]!)
            } else if rowValues[row.id] == values {continue}
            rowValues[row.id]=values;changed.insert(row.id)
        }
        for id in Array(cards.keys) where !seen.contains(id) {
            if let card=cards.removeValue(forKey:id) {for key in keys(card) {playback.release(key)}}
            rowValues[id]=nil;groupTitles[id]=nil;stale.remove(id);visible.remove(id)
            priority.removeAll {$0==id};ownerPaused.remove(id);ownerPlayed.remove(id);yielded.remove(id)
        }
        stale.formUnion(changed)
        if ids != order {order=ids}
        if !applyFrames() {schedule()}
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
        // CL-422: a target published from the exact Draft target that this card showed keeps the
        // owner's look; the card takes the open round's basis at once.
        let lineage=card.target.string("published_from_target_id")
        if !card.target.id.isEmpty,card.draft.basis.isEmpty || (!lineage.isEmpty && lineage==card.draft.targetID) {card.inspectCurrentBasis()}
        seedRecommendationNote(card)
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
    /// The view reports the frame of each card that SwiftUI lays out, in the scroll view's
    /// coordinate space (CL-421 rework). A lazy grid keeps some cells that are off screen and drops
    /// others with no report, and a card's appear task can run after the card left. So the model
    /// does not use appear or disappear: a card is visible when its frame meets the visible area.
    func updateFrames(_ frames: [String: CGRect]) {cardFrames=frames;applyFrames()}
    /// The height of the scroll view's visible area.
    func updateViewport(height: CGFloat) {
        guard height != viewportHeight else {return}
        viewportHeight=height;applyFrames()
    }
    /// Sets the visible cards from the last reported frames. False when the view reported no
    /// visible area yet or the visible cards did not change.
    @discardableResult private func applyFrames() -> Bool {
        guard viewportHeight > 0 else {return false}
        let next=Self.visibleOrder(frames:cardFrames,viewport:viewportHeight).filter {cards[$0] != nil}
        guard next != priority else {return false}
        setVisible(next);return true
    }
    /// The cards whose frame meets the visible area (0 to `viewport`), nearest to its middle first.
    /// Cards at the same distance go top to bottom, then left to right.
    static func visibleOrder(frames: [String: CGRect],viewport: CGFloat) -> [String] {
        guard viewport > 0 else {return []}
        let middle=viewport/2
        return frames.filter {$0.value.height > 0 && $0.value.maxY > 0 && $0.value.minY < viewport}
            .sorted {(abs($0.value.midY-middle),$0.value.minY,$0.value.minX,$0.key) < (abs($1.value.midY-middle),$1.value.minY,$1.value.minX,$1.key)}
            .map(\.key)
    }
    func setReduceMotion(_ value: Bool) {
        guard value != reduceMotion else {return}
        reduceMotion=value;reconcile()
    }
    /// Replaces the visible cards; `ordered` is their play order. A card that is not visible any
    /// more pauses its players at their first frame; they stay prepared while it is in the window.
    /// Then the window moves and the play budget goes to the visible cards again.
    func setVisible(_ ordered: [String]) {
        var seen=Set<String>()
        let next=ordered.filter {cards[$0] != nil && seen.insert($0).inserted}
        let left=priority.filter {!seen.contains($0)}
        priority=next;visible=seen
        for id in left {
            ownerPlayed.remove(id);yielded.remove(id)
            if let card=cards[id] {for key in keys(card) {playback.pause(key,rewind:true)}}
        }
        schedule()
    }
    /// A card came on screen (report order; tests and callers without frames).
    func cardShown(_ card: MediaDirectionCard,reduceMotion: Bool) {
        self.reduceMotion=reduceMotion
        setVisible(priority.contains(card.id) ? priority : priority+[card.id])
    }
    /// A card left the screen (tests and callers without frames).
    func cardLeft(_ card: MediaDirectionCard) {setVisible(priority.filter {$0 != card.id})}
    /// Moves the window to the visible cards, releases each take whose card left it, gives the play
    /// budget to the visible cards, and starts the preparation of the missing takes. With no card
    /// on screen the last window stays.
    private func schedule() {
        let shown=order.indices.filter {visible.contains(order[$0])}
        if let low=shown.first,let high=shown.last {
            focus=low...high
            let keep=Set(window.map {$0.flatMap {keys(at:$0)}} ?? [])
            for key in Array(playback.takes.keys) where !keep.contains(key) {playback.release(key)}
            failedKeys.formIntersection(keep)
        }
        reconcile()
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
                reconcile()
            } catch {
                // A failed player is not tried again until its card leaves the window and comes back.
                guard current() else {continue}
                failedKeys.insert(key)
                if !(error is CancellationError) {report(PlainError.text(error))}
            }
        }
    }
    /// True when a visible card plays by itself: the layout autoplays (or the owner pressed "Play
    /// all takes"), Reduce Motion is off (or "Play all takes"), and the owner did not pause it.
    private func autoplays(_ card: MediaDirectionCard) -> Bool {
        guard !pausedByOwner,!ownerPaused.contains(card.id) else {return false}
        return ownerPlaysAll || MediaSimpleLayout.startsPlaying(layout:layout(card),reduceMotion:reduceMotion,pausedByOwner:false)
    }
    /// Gives the play budget to the visible cards, after every change of the visible cards, a
    /// prepared or released player, an owner control or Reduce Motion. Order: the cards that the
    /// owner played, then the cards that play by themselves in play order (nearest the middle
    /// first), then the cards that gave way to the owner's Play. A card plays all of its prepared
    /// players (take and video reference) or none, muted and looped, within `playingTakes`. A
    /// visible card that does not fit keeps its still frame and its Play, and plays when the budget
    /// frees. A video reference that becomes ready after its take joins it: the take goes back to
    /// its first frame so that both loops start together. Players of cards that are not visible
    /// are not changed here; they count against the budget.
    private func reconcile() {
        let shown=priority.compactMap {cards[$0]}
        let shownKeys=Set(shown.flatMap {keys($0)})
        var used=playback.playingKeys.subtracting(shownKeys).count
        let manual=shown.filter {ownerPlayed.contains($0.id)}
        let automatic=shown.filter {!ownerPlayed.contains($0.id) && autoplays($0)}
        var chosen: [MediaDirectionCard] = []
        for card in manual+automatic.filter({!yielded.contains($0.id)})+automatic.filter({yielded.contains($0.id)}) {
            let ready=keys(card).filter {playback.takes[$0] != nil}
            guard !ready.isEmpty,used+ready.count <= Self.playingTakes else {continue}
            chosen.append(card);used+=ready.count
        }
        let chosenKeys=Set(chosen.flatMap {keys($0)})
        for key in shownKeys where playback.playingKeys.contains(key) && !chosenKeys.contains(key) {playback.pause(key)}
        for card in chosen {
            let ready=keys(card).filter {playback.takes[$0] != nil}
            let waiting=ready.filter {!playback.playingKeys.contains($0)}
            guard !waiting.isEmpty else {continue}
            for key in ready where playback.playingKeys.contains(key) {playback.rewind(key)}
            playback.play(waiting,limit:Self.playingTakes)
        }
    }
    /// The card's Play or Pause. It acts on both players of the card together. The owner's Pause
    /// keeps the card still after any scroll until the owner's Play. At the play budget the
    /// owner's Play pauses the cards farthest from this card until its players fit; those cards
    /// play again when the budget frees.
    func toggle(_ card: MediaDirectionCard) {
        let ready=keys(card).filter {playback.takes[$0] != nil}
        yielded.remove(card.id)
        if ready.contains(where:{playback.playingKeys.contains($0)}) {
            ownerPaused.insert(card.id);ownerPlayed.remove(card.id)
            for key in ready {playback.pause(key)}
            reconcile();return
        }
        ownerPaused.remove(card.id)
        if visible.contains(card.id) {ownerPlayed.insert(card.id)}
        if let index=order.firstIndex(of:card.id) {
            let positions=positions()
            let far: (String) -> Int = {positions[$0].map {abs($0-index)} ?? Int.max}
            while playback.playingKeys.count+ready.count > Self.playingTakes,let other=playback.playingKeys.max(by:{(far($0),$0) < (far($1),$1)}) {
                for key in Set([other]+keys(at:positions[other])) {playback.pause(key)}
                if let position=positions[other] {yielded.insert(order[position]);ownerPlayed.remove(order[position])}
            }
        }
        playback.play(ready,limit:Self.playingTakes)
        reconcile()
    }
    func pauseAll() {
        pausedByOwner=true;ownerPlaysAll=false;ownerPlayed=[];yielded=[]
        playback.pauseAll()
    }
    /// Plays the prepared players of the visible cards, in play order, within the play budget,
    /// also with Reduce Motion. It clears each card's Pause. A card plays both of its players or none.
    func playAll() {
        pausedByOwner=false;ownerPlaysAll=true;ownerPaused=[];ownerPlayed=[];yielded=[]
        reconcile()
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
    /// The owner decision route uses the native command journal. A second press on the owner's
    /// current choice sends `media_decision_withdraw`, leaving the take Pending again.
    /// CL-428: with `keep`, a press that keeps the card's current recommendation with its own note
    /// sends `media_adopt_suggestion` for that suggestion. A note that the owner changed makes it
    /// the owner's own decision of that choice (`media_decide` with the owner's note).
    func decide(_ disposition: String,card: MediaDirectionCard,model: MediaReviewModel,keep: Bool = false) async {
        guard !card.sending else {return}
        let withdrawnDecision=card.isCurrentDecision(disposition) ? card.currentOwnerDecision : nil
        let kept=keep ? recommendation(card).flatMap {
            $0.disposition==disposition && card.draft.note.trimmingCharacters(in:.whitespacesAndNewlines)==$0.note.trimmingCharacters(in:.whitespacesAndNewlines) ? $0 : nil
        } : nil
        if kept != nil,let hint=MediaSimpleLayout.noteHint(disposition,note:card.draft.note) {card.status=hint;return}
        card.sending=true
        var dispatched=false
        let scope=scope
        defer {if !dispatched {card.sending=false}}
        do {
            var params: MediaValues
            let method: String
            if withdrawnDecision != nil {params=try card.withdrawalRequest();method="media_decision_withdraw"}
            else if let kept {params=try card.adoptionRequest(kept.suggestionID);method="media_adopt_suggestion"}
            else {params=try card.decisionRequest(disposition);method="media_decide"}
            let current=Record(values:try await model.read("media_round_header",["round_id":card.header.id]))
            guard current.string("observed_context_token")==card.header.string("observed_context_token"),
                  NSDictionary(dictionary:current.object("manifest")).isEqual(to:card.header.object("manifest")),current.records("attention").isEmpty,
                  self.scope==scope else {throw ChecklistError("MEDIA_CONTEXT_CHANGED","The round context changed. Inspect this take again before deciding.")}
            params["expected_revision"]=current.integer("revision")
            dispatched=true
            model.mutateReportingFailure(method,params,onFailure:{error in card.sending=false;card.status=PlainError.text(error)}) {reply in
                card.sending=false
                if let decision=(reply["decisions"] as? [MediaValues])?.first,
                   decision["item_id"] as? String==card.id,decision["target_id"] as? String==card.target.id {
                    let pending=withdrawnDecision != nil && decision["disposition"] as? String=="withdrawn" &&
                        decision["withdraws_decision_id"] as? String==withdrawnDecision?.id
                    guard withdrawnDecision == nil || pending else {return}
                    let saved=pending ? "pending" : disposition
                    var values=card.item.values;values["disposition"]=saved;values["decision"]=decision
                    if pending {values.removeValue(forKey:"follow_up")}
                    values["revision"]=card.item.integer("revision")+1;card.item=Record(values:values)
                    card.status="Saved: "+MediaReviewModel.dispositionLabel(saved)
                }
            }
        } catch {card.status=PlainError.text(error)}
    }
    /// The card's decision press. An open round sends `media_decide`. A Draft round whose type
    /// sets `review_in_draft` publishes first (CL-422).
    func press(_ disposition: String,card: MediaDirectionCard,model: MediaReviewModel,keep: Bool = false) async {
        if MediaSimpleLayout.decisionRoute(card,model:model) == .firstDraft {await decideFromDraft(disposition,card:card,model:model,keep:keep)}
        else {await decide(disposition,card:card,model:model,keep:keep)}
    }
    /// CL-428: the card's "Keep". One press keeps the current recommendation.
    func keep(_ card: MediaDirectionCard,model: MediaReviewModel) async {
        guard let recommendation=recommendation(card) else {return}
        await press(recommendation.disposition,card:card,model:model,keep:true)
    }
    /// CL-428: the cards whose recommendation "Keep all recommendations" keeps: a current
    /// recommendation, no owner decision, a published item of an open round and a matching basis.
    func keepAllCards(model: MediaReviewModel) -> [MediaDirectionCard] {
        orderedCards.filter {recommendation($0) != nil && MediaSimpleLayout.decisionRoute($0,model:model) == .open && $0.basisMatches && !$0.sending}
    }
    /// CL-428: one confirmation, then one `media_adopt_suggestion` per card, one at a time.
    func keepAllConfirmation(model: MediaReviewModel) -> PendingConfirmation? {
        let cards=keepAllCards(model:model)
        guard !cards.isEmpty else {return nil}
        let count=cards.count==1 ? "1 take" : String(cards.count)+" takes"
        return PendingConfirmation(title:"Keep all recommendations?",
            effect:"Checklist keeps the recommended decision on "+count+" in this round, as your decision. Takes with your own decision stay as they are.",
            confirmLabel:"Keep "+String(cards.count)+(cards.count==1 ? " recommendation" : " recommendations"),keepLabel:"Cancel") {[weak self,weak model] in
            guard let self,let model else {return}
            Task {await self.keepAll(cards,model:model)}
        }
    }
    func keepAll(_ cards: [MediaDirectionCard],model: MediaReviewModel) async {
        let scope=scope
        for card in cards {
            guard self.scope==scope,!Task.isCancelled else {return}
            await model.waitUntilWritable()
            guard self.cards[card.id]===card,recommendation(card) != nil else {continue}
            await keep(card,model:model)
        }
    }
    /// CL-428: "Clear flag" sends `media_suggestion_dismiss`. The card then has no recommendation,
    /// and the flag does not come back for that take in this round. A note that is still the flag's
    /// own note leaves the note box.
    func clearFlag(_ card: MediaDirectionCard,model: MediaReviewModel) {
        guard !card.sending,!model.historyOnly,let flag=recommendation(card),flag.isFlag else {return}
        card.sending=true
        let scope=scope,target=card.target.id
        model.mutateReportingFailure("media_suggestion_dismiss",["round_id":card.header.id,"suggestion_id":flag.suggestionID],
            onFailure:{error in card.sending=false;card.status=PlainError.text(error)}) {[weak self] _ in
            card.sending=false
            guard let self,self.scope==scope else {return}
            self.dismissedSuggestions.insert(flag.suggestionID)
            if !target.isEmpty {self.dismissedFlagTargets[card.id,default:[]].insert(target)}
            if card.draft.note.trimmingCharacters(in:.whitespacesAndNewlines)==flag.note.trimmingCharacters(in:.whitespacesAndNewlines) {card.draft.note=""}
            card.status="Flag cleared"
        }
    }
    /// CL-422: one press publishes the Draft's publication-ready items (this card's item with the
    /// Draft target the owner saw must be one of them), reads the open round and this item again,
    /// and then records the decision through `decide`. A refused publication records no decision.
    /// On `MEDIA_PROJECT_CONTEXT_REQUIRED` the model approves the project context and publishes
    /// again (`publishFrozenPreview`); the owner's press is the approval. No dialog shows.
    func decideFromDraft(_ disposition: String,card: MediaDirectionCard,model: MediaReviewModel,keep: Bool = false) async {
        guard !card.sending else {return}
        if let hint=MediaSimpleLayout.noteHint(disposition,note:card.draft.note) {card.status=hint;return}
        let viewed=card.target.id,scope=scope,round=card.header.id
        guard !viewed.isEmpty,card.basisMatches else {card.status="Inspect this take before deciding.";return}
        card.sending=true;card.status="Publishing this round for review…"
        let published: [Record]
        do {
            published=try await model.publishFrozenPreview(onlyReady:true,required:(card.id,viewed))
        } catch {
            card.sending=false
            if self.scope==scope,!(error is CancellationError) {card.status=Self.notPublished(error)}
            return
        }
        card.status="Saving decision…"
        do {
            let frozen=published.first {$0.string("item_id")==card.id}
            let header=Record(values:try await model.read("media_round_header",["round_id":round]))
            let item=Record(values:try await model.read("media_item_get",["round_id":round,"item_id":card.id]))
            guard self.scope==scope,cards[card.id]===card else {card.sending=false;return}
            let target=Record(values:item.object("target")),lineage=target.string("published_from_target_id")
            // A target published from the exact Draft target that the card showed is the same take. The
            // owner's publication can migrate pending context attention (CL-422), which changes only the
            // context part of the basis, so lineage is enough; a target without lineage must keep the basis.
            let sameTake=lineage.isEmpty ? target.string("review_basis_signature")==frozen?.string("review_basis_signature") : lineage==viewed
            guard header.id==round,header.string("state")=="open",item.bool("published"),!target.id.isEmpty,sameTake else {
                throw ChecklistError("MEDIA_CONTEXT_CHANGED","The round is published, but this take changed. Look at it again before deciding.")
            }
            update(header:header);apply(item,to:card);card.inspectCurrentBasis()
        } catch {
            card.sending=false;card.status="Published. No decision recorded. "+PlainError.text(error);return
        }
        await model.waitUntilWritable()
        card.sending=false
        // CL-428: Keep adopts the suggestion only while it is still current for the published item.
        await decide(disposition,card:card,model:model,keep:keep)
    }
    /// The card's one plain line for a refused publication, an approval that failed included.
    static func notPublished(_ error: Error) -> String {
        var reason=PlainError.text(error).trimmingCharacters(in:.whitespacesAndNewlines)
        while reason.hasSuffix(".") {reason.removeLast()}
        return "Could not publish this round: "+reason+". No decision was saved."
    }
}

/// CL-421: the default review of an "Animation takes" round. Each card plays its take at once,
/// beside its reference, with a plain label and the three owner decisions.
struct MediaSimpleReview: View {
    @ObservedObject var model: MediaReviewModel
    @EnvironmentObject var store: ChecklistStore
    @StateObject private var simple = MediaSimpleReviewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: PendingConfirmation?
    var scope: String {model.projectID+":"+model.roundID}
    var body: some View {
        GeometryReader {viewport in
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(MediaReviewModel.countsText(model.counts)).font(.caption).foregroundStyle(Color.checklistSecondaryText)
                    Spacer()
                    // CL-428: one confirmed press keeps every current recommendation of the round.
                    if !simple.keepAllCards(model:model).isEmpty {
                        Button("Keep all recommendations…") {confirmation=simple.keepAllConfirmation(model:model)}
                            .checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
                    }
                    if simple.pausedByOwner || (reduceMotion && simple.playback.playingKeys.isEmpty) {
                        Button("Play all takes") {simple.playAll()}
                    } else {Button("Pause all takes") {simple.pauseAll()}}
                }
                if reduceMotion {Text("Reduce Motion is on. Takes show a still frame. Press Play on a card to watch it.").font(.caption)}
                if model.rows.isEmpty,!model.loading {Text("No items in this round for the current filter.").foregroundStyle(Color.checklistSecondaryText)}
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(simple.sections) {section in
                        Text(section.title).font(.title3).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:MediaSimpleLayout.cardMinWidth),alignment:.top)],alignment:.leading,spacing:12) {
                            ForEach(section.cards) {card in
                                MediaSimpleCardView(card:card,simple:simple,playback:simple.playback,model:model)
                            }
                            // CL-428: a direction of the type with no take: no take and no decisions.
                            ForEach(section.notMade,id:\.self) {text in
                                Text(text).font(.callout).foregroundStyle(Color.checklistSecondaryText)
                                    .frame(maxWidth:.infinity,alignment:.leading).padding(MediaSimpleLayout.cardPadding)
                                    .background(.quaternary.opacity(0.15),in:RoundedRectangle(cornerRadius:6))
                                    .accessibilityIdentifier("mediaSimpleNotMade:"+text)
                            }
                        }
                    }
                }
                if model.next != nil {Button("Load more items") {Task {await model.moreRows()}}}
            }.padding(8)
        }
        .coordinateSpace(.named(mediaSimpleScrollSpace))
        // The visible cards come from the card frames, never from lazy-cell appear or disappear.
        .onPreferenceChange(MediaSimpleCardFrames.self) {[review=simple] frames in MainActor.assumeIsolated {review.updateFrames(frames)}}
        .onChange(of:viewport.size.height,initial:true) {_,height in simple.updateViewport(height:height)}
        .onChange(of:reduceMotion,initial:true) {_,value in simple.setReduceMotion(value)}
        .accessibilityIdentifier("mediaSimpleReview")
        .checklistConfirmation($confirmation)
        .onReceive(model.$header) {simple.update(header:$0)}
        .onReceive(model.$rows) {rows in sync(rows)}
        .onDisappear {simple.reset()}
        }
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
        // CL-428: "Not made" cards need the type's direction choices and the whole round.
        simple.directionChoices=MediaNotMade.directionChoices(header.object("type_revision")["schema"] as? MediaValues ?? model.schema)
        simple.listComplete=model.next == nil && model.filter == "all"
        let changed=simple.sync(scope:scope,rows:rows,draft:{model.ownerDraft(for:$0,header:header)},saveDraft:{[weak model] id,value in model?.saveOwnerDraft(value,itemID:id)})
        guard !changed.isEmpty else {return}
        let round=model.roundID
        Task {await simple.readStale {id in Record(values:try await model.read("media_item_get",["round_id":round,"item_id":id]))}}
    }
}

/// The coordinate space of the simple review's scroll view. Card frames in it are relative to the
/// visible area: 0 is its top edge.
private let mediaSimpleScrollSpace = "mediaSimpleScroll"
/// The frame of each laid-out card, by item ID. A lazy cell that SwiftUI dropped reports nothing.
private struct MediaSimpleCardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect],nextValue: () -> [String: CGRect]) {value.merge(nextValue()) {$1}}
}
private struct MediaSimpleFrameReporter: View {
    let id: String
    var body: some View {
        GeometryReader {proxy in Color.clear.preference(key:MediaSimpleCardFrames.self,value:[id:proxy.frame(in:.named(mediaSimpleScrollSpace))])}
    }
}

private struct MediaSimpleCardView: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var card: MediaDirectionCard
    let simple: MediaSimpleReviewModel
    @ObservedObject var playback: MediaSimpleTakeCache
    let model: MediaReviewModel
    @State private var showDetails = false
    var schema: MediaValues {card.header.object("type_revision")["schema"] as? MediaValues ?? model.schema}
    var layout: MediaValues {schema["layout"] as? MediaValues ?? [:]}
    var route: MediaSimpleLayout.DecisionRoute {MediaSimpleLayout.decisionRoute(card,model:model)}
    var recommendation: MediaCardRecommendation? {simple.recommendation(card)}
    /// The owner's own decision on the current target; empty when none.
    var current: String {MediaCardRecommendation.ownerDecided(card.item) ? card.item.string("disposition") : ""}
    /// A selected choice (the recommendation or the owner's decision) shows as the prominent button.
    @ViewBuilder func choiceButton(_ title: String,selected: Bool,action: @escaping () -> Void) -> some View {
        if selected {Button(title,action:action).buttonStyle(.borderedProminent)} else {Button(title,action:action)}
    }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.firstTextBaseline) {
                Text(card.label).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(MediaReviewModel.dispositionLabel(card.item.string("disposition",fallback:"pending"))).font(.caption)
                Button {showDetails.toggle()} label: {Image(systemName:"info.circle")}.buttonStyle(.plain)
                    .accessibilityLabel("Details, "+card.label).help("Show item details")
                    .popover(isPresented:$showDetails) {details.environmentObject(store)}
            }
            // CL-430: the item's own ticket, only when it differs from the round's ticket.
            if let ticket=MediaReviewModel.cardTicketLabel(item:card.item,header:card.header) {
                Text(ticket).font(.caption).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
                    .accessibilityIdentifier("mediaSimpleTicket:"+card.id)
            }
            // CL-421 rework: two equal halves when the card is wide enough, else the reference under the take.
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.top,spacing:MediaSimpleLayout.mediaSpacing) {takeColumn;referenceColumn}
                VStack(alignment:.leading,spacing:MediaSimpleLayout.mediaSpacing) {takeColumn;referenceColumn}
            }
            // CL-428: the recommended decision and its plain reason. It is not an owner decision.
            if let recommendation {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Text(recommendation.reason).font(.caption).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("mediaSimpleRecommendation:"+card.id)
                    Spacer(minLength:4)
                    if recommendation.isFlag {
                        Button("Clear flag") {simple.clearFlag(card,model:model)}.controlSize(.small)
                            .accessibilityLabel("Clear flag, "+card.label)
                            .checklistDisabled([(card.sending,"Wait for this decision to finish."),(model.historyOnly,"This round is history only."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
                    }
                }
            } else if let suggestion=simple.otherSuggestion(card) {
                Text("Agent suggests: "+suggestion.choice).font(.caption).foregroundStyle(Color.checklistSecondaryText)
            }
            // CL-428: the item's hint as short lines above the note; the details show all of it.
            let hints=MediaCardHints.shown(card.labelMetadata["hint"])
            if !hints.lines.isEmpty {
                VStack(alignment:.leading,spacing:1) {
                    ForEach(Array(hints.lines.enumerated()),id:\.offset) {Text($0.element)}
                    if hints.more {Button("more") {showDetails=true}.buttonStyle(.link).accessibilityLabel("More hint lines, "+card.label)}
                }.font(.caption).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal:false,vertical:true)
            }
            // A flag opens its note at once: the note box is taller for a flagged card.
            TextField("Owner note",text:$card.draft.note,axis:.vertical).lineLimit(recommendation?.isFlag == true ? 2...4 : 1...3)
                .accessibilityLabel("Owner note for "+card.label)
            if !card.basisMatches,!card.target.id.isEmpty {
                Button("I inspected this target and context") {card.inspectCurrentBasis()}
            }
            HStack {
                if let recommendation {
                    Button("Keep") {Task {await simple.keep(card,model:model)}}.buttonStyle(.borderedProminent)
                        .accessibilityLabel("Keep "+recommendation.choiceTitle+", "+card.label)
                        .help("Keep the recommended decision: "+recommendation.choiceTitle)
                }
                ForEach(MediaSimpleLayout.decisions) {choice in
                    let hint=card.decisionNoteHint(choice.disposition)
                    let suggested=recommendation?.disposition==choice.disposition
                    choiceButton(choice.title+(suggested ? " (suggested)" : ""),selected:suggested || current==choice.disposition) {
                        Task {await simple.press(choice.disposition,card:card,model:model,keep:suggested)}
                    }
                        .checklistDisabled([(hint != nil,hint ?? "")])
                        .accessibilityLabel(choice.title+(suggested ? ", suggested" : current==choice.disposition ? ", your decision" : "")+", "+card.label)
                        .help(card.isCurrentDecision(choice.disposition) ? "Press again to remove your decision and mark this take Pending." : hint ?? choice.title)
                }
                if card.sending {ProgressView().controlSize(.small).accessibilityLabel("Working on this decision")}
            }.checklistDisabled([(card.sending,"Wait for this decision to finish."),(card.target.id.isEmpty,"This item is still loading."),(route == .unavailable && card.header.string("state") == "draft","Publish this Draft round before deciding."),(!card.basisMatches || route == .unavailable,"Inspect a published item in an open round before deciding."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            if let hint=card.decisionNoteHint("changes_requested") {
                Text(hint).font(.caption).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal:false,vertical:true)
            }
            if !card.status.isEmpty {Text(card.status).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
        }
        .padding(MediaSimpleLayout.cardPadding).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:6))
        .clipShape(RoundedRectangle(cornerRadius:6))
        .accessibilityElement(children:.contain).accessibilityLabel(card.label)
        .accessibilityIdentifier("mediaSimpleCard:"+card.id)
        .background(MediaSimpleFrameReporter(id:card.id))
    }
    /// The take half: the take in its fixed frame, then its label and the card's Play/Pause.
    var takeColumn: some View {
        VStack(alignment:.leading,spacing:2) {
            take.mediaSimpleHalf()
            HStack(alignment:.firstTextBaseline,spacing:4) {
                Text("Take").font(.caption2).foregroundStyle(Color.checklistSecondaryText)
                Spacer(minLength:4)
                if playback.takes[card.key]?.player != nil {
                    // One control for both players of the card (the take and a video reference).
                    Button(simple.isPlaying(card) ? "Pause" : "Play") {simple.toggle(card)}
                        .controlSize(.small).fixedSize()
                        .accessibilityLabel((simple.isPlaying(card) ? "Pause " : "Play ")+card.label)
                }
            }
        }.frame(minWidth:MediaSimpleLayout.mediaMinWidth,idealWidth:MediaSimpleLayout.mediaMinWidth,maxWidth:.infinity,alignment:.leading)
    }
    var referenceColumn: some View {
        MediaSimpleReferenceView(card:card,simple:simple,playback:playback,model:model,layout:layout)
            .frame(minWidth:MediaSimpleLayout.mediaMinWidth,idealWidth:MediaSimpleLayout.mediaMinWidth,maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder var take: some View {
        if let prepared=playback.takes[card.key],let player=prepared.player {
            MediaSimpleCardPlayer(player:player,aspect:MediaSimpleLayout.aspect(width:prepared.measurement.facts.width,height:prepared.measurement.facts.height))
                .accessibilityLabel("Take, "+card.label)
        } else {
            Text(card.status.isEmpty || card.status.hasPrefix("Saved") ? "Preparing take…" : card.status)
                .font(.caption).foregroundStyle(Color.checklistSecondaryText).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    /// Technical text stays out of the card. It is available here on request.
    var details: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(card.label).font(.headline)
            // Every line wraps: the popover is at most 360 points wide, and a long measurement or
            // metadata line was cut with "…" (round 95 UI check).
            Text("Item: "+card.item.string("title")).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            // CL-430: set or change this item's ticket with the round's picker.
            MediaItemTicketControl(model:model,item:card.item)
            if let hint=card.labelMetadata["hint"] as? String,!hint.isEmpty {Text("Hint: "+hint).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            if let prepared=playback.takes[card.key] {
                Text(MediaPlaybackLabels.playback(loop:true,frameRate:prepared.measurement.timing?.declaredFrameRate)).fixedSize(horizontal:false,vertical:true)
                Text(MediaPlaybackLabels.measurement(prepared.measurement)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }
            ForEach(card.labelMetadata.keys.sorted(),id:\.self) {key in
                Text(key+": "+String(describing:card.labelMetadata[key]!)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }
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
                        MediaSimpleCardPlayer(player:native,aspect:MediaSimpleLayout.aspect(width:prepared.measurement.facts.width,height:prepared.measurement.facts.height))
                            .accessibilityLabel("Reference, "+label).mediaSimpleHalf()
                    } else {Text(card.referenceStatus.isEmpty ? "Preparing reference…" : card.referenceStatus).font(.caption).foregroundStyle(Color.checklistSecondaryText).mediaSimpleHalf()}
                } else if let image {Image(nsImage:image).resizable().scaledToFit().accessibilityLabel("Reference, "+label).mediaSimpleHalf()}
                else {Text(status.isEmpty ? "Loading reference…" : status).font(.caption).foregroundStyle(Color.checklistSecondaryText).mediaSimpleHalf()}
                Text(label).font(.caption2).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal:false,vertical:true)
            } else {Text(card.target.id.isEmpty ? "" : MediaSimpleReviewModel.noReference).font(.caption).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal:false,vertical:true)}
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

/// CL-421 rework: one half of a card's media. A fixed-height frame as wide as its half, with the
/// content centred and clipped to it, so a take or reference never draws past its half.
private extension View {
    func mediaSimpleHalf() -> some View {
        frame(maxWidth:.infinity,maxHeight:.infinity).frame(height:MediaSimpleLayout.mediaHeight).clipped()
    }
}

/// CL-421 rework: a card player. `NativePlayerAdapter` keeps AVPlayerView's own size: its inline
/// controls need more width than half a card, so the reference drew past its 150-point frame
/// into the next card, and its black background showed as a band beside an aspect-fit video.
/// This view takes exactly the size it is offered, has no controls of its own (the card's
/// Play/Pause plays both players together), a clear background, and an aspect-fit frame of the
/// probed video size, so no letterbox band shows.
struct MediaSimpleCardPlayer: View {
    let player: AVPlayer
    let aspect: CGFloat?
    var body: some View {
        if let aspect {Surface(player:player).aspectRatio(aspect,contentMode:.fit)}
        else {Surface(player:player)}
    }
    /// No inline controls (review 8b119aed R2): an inline pause was not recorded as the owner's
    /// pause, so the next budget pass played the take again. The card's visible Play/Pause is the
    /// only control, and it records `ownerPaused`.
    static func configure(_ view: AVPlayerView,player: AVPlayer) {
        view.controlsStyle = .none
        view.showsFullScreenToggleButton=false
        view.videoGravity = .resizeAspect
        view.wantsLayer=true;view.layer?.backgroundColor=NSColor.clear.cgColor
        view.player=player
        view.setAccessibilityLabel("Video")
    }
    private struct Surface: NSViewRepresentable {
        let player: AVPlayer
        func makeNSView(context: Context) -> AVPlayerView {
            let view=AVPlayerView()
            MediaSimpleCardPlayer.configure(view,player:player)
            return view
        }
        func updateNSView(_ view: AVPlayerView,context: Context) {
            if view.player !== player {view.player?.pause();view.player=player}
        }
        /// The offered size, never the view's own: an unspecified dimension is zero.
        func sizeThatFits(_ proposal: ProposedViewSize,nsView: AVPlayerView,context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions(by:.zero)
        }
        static func dismantleNSView(_ view: AVPlayerView,coordinator: ()) {view.player?.pause();view.player=nil}
    }
}
