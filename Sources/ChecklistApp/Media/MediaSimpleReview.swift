import SwiftUI
import AppKit
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

/// One card per item (one direction of one move). Cards and their players are kept by item
/// ID. A refresh diffs the rows by ID: an unchanged row keeps its card, item and playing
/// take; a changed row reads only that item again and updates its card in place.
@MainActor final class MediaSimpleReviewModel: ObservableObject {
    @Published private(set) var order: [String] = []
    @Published var pausedByOwner = false
    private(set) var cards: [String: MediaDirectionCard] = [:]
    private(set) var stale = Set<String>()
    private(set) var visible = Set<String>()
    private(set) var header = Record(values: [:])
    private var rowValues: [String: NSDictionary] = [:]
    private var groupTitles: [String: String] = [:]
    private(set) var scope = ""
    private var preparation: Task<Void,Never>?
    private var readingItems = false
    var referenceImages: [String: NSImage] = [:]
    let playback = MediaPlaybackCoordinator(directionGrid: true)
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

    func reset() {
        preparation?.cancel();preparation=nil;playback.releaseAll()
        cards=[:];rowValues=[:];groupTitles=[:];stale=[];visible=[];referenceImages=[:]
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
            if let card=cards.removeValue(forKey:id) {playback.release(card.key)}
            rowValues[id]=nil;groupTitles[id]=nil;stale.remove(id);visible.remove(id)
        }
        stale.formUnion(changed)
        if ids != order {order=ids}
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
    /// Updates one card in place. The take is kept unless the reviewed target changed.
    func apply(_ item: Record,to card: MediaDirectionCard) {
        guard !MediaReviewModel.sameRecord(card.item,item) else {return}
        let previous=card.key
        card.item=item
        if card.key != previous {playback.release(previous)}
        if card.draft.basis.isEmpty,!card.target.id.isEmpty {card.inspectCurrentBasis()}
    }
    /// Prepares one take at a time for a card on screen, then plays it muted and looped,
    /// unless Reduce Motion or the owner's Pause keeps the still first frame.
    func requestTake(_ card: MediaDirectionCard,model: MediaReviewModel,schema: MediaValues,reduceMotion: Bool) {
        visible.insert(card.id)
        guard !card.target.id.isEmpty,playback.takes[card.key] == nil,!model.projectID.isEmpty else {return}
        let previous=preparation,scope=scope,key=card.key,id=card.id
        preparation=Task { [weak self] in
            await previous?.value
            guard let self,!Task.isCancelled else {return}
            let current: @MainActor () -> Bool = {[weak self] in self?.scope==scope && self?.visible.contains(id)==true && card.key==key}
            guard current(),self.playback.takes[key] == nil else {return}
            do {
                let take=try await MediaDirectionTakePreparation.prepare(card,model:model,schema:schema,playback:self.playback,isCurrent:current)
                guard current() else {take.control.unload();return}
                take.player?.isMuted=true
                guard self.playback.admit(take) else {card.status="This take is over the playback limit for cards. Open it in item comparison.";return}
                card.status=""
                let layout=schema["layout"] as? MediaValues ?? [:]
                if MediaSimpleLayout.startsPlaying(layout:layout,reduceMotion:reduceMotion,pausedByOwner:self.pausedByOwner) {self.playback.play(key)}
            } catch is CancellationError {
            } catch {if current() {card.status=PlainError.text(error)}}
        }
    }
    func cardLeft(_ card: MediaDirectionCard) {visible.remove(card.id);playback.release(card.key)}
    func toggle(_ card: MediaDirectionCard) {
        if playback.playingKeys.contains(card.key) {playback.pause(card.key)} else {playback.play(card.key)}
    }
    func pauseAll() {pausedByOwner=true;playback.pauseAll()}
    func playAll() {pausedByOwner=false;playback.playAll()}
    /// The first available image reference declared by the layout, in declared order.
    static func referenceImage(item: Record,layout: MediaValues) -> (slot: Record,original: Record)? {
        let ids=MediaComparisonLabels.referenceSlotIDs(layout)
        guard let candidate=item.records("candidates").first else {return nil}
        let slots=candidate.records("slots").filter {ids.contains($0.string("slot_id"))}.sorted {(ids.firstIndex(of:$0.string("slot_id")) ?? 0)<(ids.firstIndex(of:$1.string("slot_id")) ?? 0)}
        for slot in slots {
            guard let original=item.records("originals").first(where:{$0.string("attachment_id")==slot.string("attachment_id")}),
                  MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:"image") == .image else {continue}
            return (slot,original)
        }
        return nil
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
    @ObservedObject var playback: MediaPlaybackCoordinator
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
                MediaSimpleReferenceView(card:card,simple:simple,model:model,layout:layout).frame(width:150)
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
        .task(id:card.key) {simple.requestTake(card,model:model,schema:schema,reduceMotion:reduceMotion)}
        .onDisappear {simple.cardLeft(card)}
    }
    @ViewBuilder var take: some View {
        if let prepared=playback.takes[card.key],let player=prepared.player {
            ZStack(alignment:.bottomTrailing) {
                NativePlayerAdapter(player:player,audio:false).accessibilityLabel("Take, "+card.label)
                Button(playback.playingKeys.contains(card.key) ? "Pause" : "Play") {simple.toggle(card)}
                    .accessibilityLabel((playback.playingKeys.contains(card.key) ? "Pause " : "Play ")+card.label).padding(6)
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

/// The card's reference image, beside the take. A decoded image is kept by reference ID,
/// so a refresh never reads or decodes it again.
private struct MediaSimpleReferenceView: View {
    @ObservedObject var card: MediaDirectionCard
    let simple: MediaSimpleReviewModel
    let model: MediaReviewModel
    let layout: MediaValues
    @State private var image: NSImage?
    @State private var status = ""
    var reference: (slot: Record,original: Record)? {MediaSimpleReviewModel.referenceImage(item:card.item,layout:layout)}
    var key: String {reference?.original.string("reference_id") ?? ""}
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            if let reference {
                if let image {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180).accessibilityLabel("Reference, "+MediaComparisonLabels.slot(reference.slot,definitions:model.slots))}
                else {Text(status.isEmpty ? "Loading reference…" : status).font(.caption).foregroundStyle(Color.checklistSecondaryText)}
                Text(MediaComparisonLabels.slot(reference.slot,definitions:model.slots)).font(.caption2).foregroundStyle(Color.checklistSecondaryText)
            } else {Text(card.target.id.isEmpty ? "" : "No reference image").font(.caption).foregroundStyle(Color.checklistSecondaryText)}
        }
        .task(id:key) {await load()}
    }
    func load() async {
        guard let reference,!key.isEmpty else {image=nil;return}
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
