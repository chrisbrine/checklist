import SwiftUI
import ChecklistCore
import ChecklistIPC

/// A complete character/action key, independent of the currently loaded list page or filter.
struct MediaAnimationGroup: Identifiable, Equatable {
    let character: String
    let action: String
    var id: String { (try? JSONSerialization.data(withJSONObject: [character,action]))?.base64EncodedString() ?? "" }
    var title: String { character + " · " + action }
    var metadata: MediaValues { ["character":character,"animation_label":action] }
    static func == (a: Self,b: Self) -> Bool { a.id == b.id }
    init?(headerID: String,schema: MediaValues) {
        guard Self.supports(schema),headerID.hasPrefix("group:"),
              let data=Data(base64Encoded:String(headerID.dropFirst(6))),
              let path=(try? JSONSerialization.jsonObject(with:data)) as? [MediaValues],path.count==2,
              path[0]["field_id"] as? String == "character",path[1]["field_id"] as? String == "animation_label",
              let character=path[0]["value"] as? String,let action=path[1]["value"] as? String else {return nil}
        self.character=character;self.action=action
    }
    init?(metadata: MediaValues,schema: MediaValues) {
        guard Self.supports(schema),let character=metadata["character"] as? String,
              let action=metadata["animation_label"] as? String else {return nil}
        self.character=character;self.action=action
    }
    static func supports(_ schema: MediaValues) -> Bool {
        let layout=schema["layout"] as? MediaValues ?? [:]
        let fields=schema["fields"] as? [MediaValues] ?? []
        return layout["kind"] as? String == "video_compare" && layout["loop"] as? Bool == true &&
            ["character","animation_label","direction"].allSatisfy {id in fields.contains {$0["id"] as? String==id}}
    }
    @MainActor func pageRequest(roundID: String,schema: MediaValues) -> MediaValues {
        ["round_id":roundID,"list":MediaReviewModel.defaultList(schema),"limit":9,"filter":["metadata":metadata]]
    }
}

@MainActor final class MediaDirectionCard: ObservableObject, Identifiable {
    @Published var item: Record
    @Published var draft: MediaOwnerDraft {didSet {saveDraft?(draft)}}
    private let saveDraft: ((MediaOwnerDraft) -> Void)?
    @Published var status = ""
    @Published var sending = false
    let header: Record
    nonisolated let id: String
    var target: Record { Record(values:item.object("target")) }
    var metadata: MediaValues { target.object("metadata") }
    var direction: String { metadata["direction"] as? String ?? "Direction unavailable" }
    var key: String { "grid:"+id+":"+target.id }
    init(item: Record,header: Record,draft: MediaOwnerDraft,saveDraft: ((MediaOwnerDraft) -> Void)? = nil) {
        self.id=item.id;self.item=item;self.header=header;self.draft=draft;self.saveDraft=saveDraft
    }
    var basisMatches: Bool {
        draft.targetID==target.id && draft.basis==target.string("review_basis_signature") &&
        draft.contextToken==header.string("observed_context_token") &&
        draft.manifestID==Record(values:header.object("manifest")).id &&
        draft.manifestDigest==Record(values:header.object("manifest")).string("digest")
    }
    func inspectCurrentBasis() {
        draft.targetID=target.id;draft.basis=target.string("review_basis_signature")
        draft.contextToken=header.string("observed_context_token")
        draft.manifestID=Record(values:header.object("manifest")).id
        draft.manifestDigest=Record(values:header.object("manifest")).string("digest")
    }
    func decisionRequest(_ disposition: String) throws -> MediaValues {
        guard item.bool("published"),header.string("state")=="open",header.records("attention").isEmpty,basisMatches else {
            throw ChecklistError("MEDIA_CONTEXT_CHANGED","Inspect the current target and approved context before deciding.")
        }
        if MediaReviewModel.decisionRequiresNote(disposition),draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            throw ChecklistError("NOTE_REQUIRED","Enter what should change in the owner note.")
        }
        var p: MediaValues=["round_id":header.id,"expected_revision":header.integer("revision"),
            "observed_context_token":draft.contextToken,"manifest_id":draft.manifestID,"manifest_digest":draft.manifestDigest,
            "items":[["item_id":id,"expected_revision":item.integer("revision"),"target_id":draft.targetID,"review_basis_signature":draft.basis]],
            "disposition":disposition]
        if !draft.note.isEmpty {p["note"]=draft.note}
        let candidates=target.strings("candidate_ids")
        if disposition=="accepted" {
            let winner=draft.winnerID.isEmpty && candidates.count==1 ? candidates[0] : draft.winnerID
            guard candidates.contains(winner) else {throw ChecklistError("WINNER_REQUIRED","Choose the exact winning candidate in item comparison.")}
            p["winner_id"]=winner
        }
        if disposition=="changes_requested",candidates.count>1 {p["none_fit"]=true}
        return p
    }
}

/// Owns only the opened group's decoders. Reads and decisions keep exact service observations.
@MainActor final class MediaDirectionGridModel: ObservableObject {
    @Published private(set) var cards: [MediaDirectionCard] = []
    @Published private(set) var loading = false
    @Published var error: String?
    let playback=MediaPlaybackCoordinator(directionGrid:true)
    private var generation=UUID()
    private var scope=""
    private var loadTask: Task<Void,Never>?
    private let prepareTake: (@MainActor (MediaDirectionCard) async throws -> MediaPreparedTake)?
    init(prepareTake: (@MainActor (MediaDirectionCard) async throws -> MediaPreparedTake)? = nil) {self.prepareTake=prepareTake}
    func close() {generation=UUID();loadTask?.cancel();playback.releaseAll();cards=[];loading=false;scope=""}

    func open(group: MediaAnimationGroup,model: MediaReviewModel) async {
        let previous=loadTask,project=model.projectID,round=model.roundID
        close();let token=generation;loading=true;error=nil
        // A cancelled native probe may still be retiring. Never overlap it with a
        // replacement group's preparation or steal its single-preparation token.
        await previous?.value
        guard token==generation,!Task.isCancelled,model.projectID==project,model.roundID==round else {
            if token==generation {loading=false};return
        }
        let task=Task { @MainActor in await self.load(group:group,model:model,project:project,round:round,token:token) }
        loadTask=task
        await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
    }
    private func load(group: MediaAnimationGroup,model: MediaReviewModel,project: String,round: String,token: UUID) async {
        scope=project+":"+round;loading=true;error=nil
        defer {if token==generation {loading=false}}
        do {
            let header=Record(values:try await model.read("media_round_header",["round_id":round]))
            try Task.checkCancellation()
            guard token==generation,model.projectID==project,model.roundID==round else {return}
            let schema=Record(values:header.object("type_revision")).object("schema")
            let page=try await model.read("media_item_page",group.pageRequest(roundID:round,schema:schema))
            let rows=(page["rows"] as? [MediaValues] ?? []).map(Record.init)
            guard rows.count<=MediaPlaybackBudget.directionGridTakes,page["next_cursor"] as? String == nil else {
                throw ChecklistError("GRID_CAPACITY","This group has more than eight items. Use item comparison or separate actions/takes into groups.")
            }
            var loaded:[MediaDirectionCard]=[],directions=Set<Data>()
            for row in rows {
                try Task.checkCancellation()
                let item=Record(values:try await model.read("media_item_get",["round_id":round,"item_id":row.id]))
                guard token==generation,model.projectID==project,model.roundID==round else {return}
                let metadata=Record(values:item.object("target")).object("metadata")
                guard let actual=MediaAnimationGroup(metadata:metadata,schema:schema),actual==group,
                      let direction=metadata["direction"] as? String,directions.insert(Data(direction.utf8)).inserted else {
                    throw ChecklistError("GRID_AMBIGUOUS","The group changed or has multiple takes for one direction. Use item comparison.")
                }
                loaded.append(MediaDirectionCard(item:item,header:header,draft:model.ownerDraft(for:item,header:header),saveDraft:{[weak model] value in
                    model?.saveOwnerDraft(value,itemID:item.id)
                }))
            }
            guard token==generation else {return};cards=loaded
            for card in loaded {
                try Task.checkCancellation()
                guard token==generation,model.projectID==project,model.roundID==round else {return}
                do {
                    if let prepareTake {
                        let take=try await prepareTake(card)
                        guard !Task.isCancelled,token==generation else {take.control.unload();throw CancellationError()}
                        guard playback.admit(take) else {throw ChecklistError("GRID_BUDGET","The take exceeds the direction-grid budget.")}
                    } else {try await prepare(card,model:model,schema:schema,token:token)}
                }
                catch is CancellationError {throw CancellationError()}
                catch {card.status=PlainError.text(error)}
            }
            guard token==generation else {return}
            playback.playAll()
        } catch is CancellationError {if token==generation {close()}}
        catch {if token==generation {self.error=PlainError.text(error);playback.releaseAll()}}
    }
    private func prepare(_ card: MediaDirectionCard,model: MediaReviewModel,schema: MediaValues,token: UUID) async throws {
        let project=model.projectID
        let candidates=card.item.records("candidates"),layout=schema["layout"] as? MediaValues ?? [:]
        guard candidates.count==1 else {throw ChecklistError("GRID_CANDIDATES","Choose among this item's candidates in item comparison.")}
        guard let slot=candidates[0].records("slots").first(where:{$0.string("slot_id")==layout["primary_slot_id"] as? String}),
              let original=card.item.records("originals").first(where:{$0.string("attachment_id")==slot.string("attachment_id")}),
              MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:"video") == .playback("video") else {
            throw ChecklistError("MANAGED_ORIGINAL_UNAVAILABLE","No available primary video for this direction.")
        }
        guard playback.beginPreparation(card.key) else {throw CancellationError()}
        defer {playback.endPreparation(card.key)}
        card.status="Preparing exact take…"
        let (file,copyMS)=try await MediaTakeLoader.verifiedCopy(expectedSHA256:slot.string("sha256"),maximumBytes:MediaPlaybackBudget.directionGridOriginalBytes,
            lease:{
                let (method,params)=MediaReviewModel.playbackLeaseRequest(roundID:card.header.id,selectedID:card.id,targetID:card.target.id,original:original,example:nil)
                let reply=try await model.read(method,params,projectID:project),attachment=Record(values:reply["attachment"] as? MediaValues ?? [:])
                guard let id=reply["lease_id"] as? String else {throw ChecklistError("MANAGED_ORIGINAL_UNAVAILABLE","No exact reader lease was returned.")}
                return .init(id:id,path:attachment.string("path"),size:attachment.integer("size"),name:attachment.string("name"),attachmentID:attachment.id)
            },release:{await model.releasePlaybackLease($0,projectID:project)})
        let (asset,facts,probeMS)=try await MediaTakeLoader.probe(url:file.url,kind:"video")
        let settings=MediaComparisonLabels.playbackSettings(slotID:slot.string("slot_id"),layout:layout,historical:false,metadata:card.metadata)
        let timing=try await MediaTakeLoader.timing(asset:asset,frameRate:settings.frameRate)
        try Task.checkCancellation();guard token==generation else {throw CancellationError()}
        guard playback.gridAllows(bytes:original.integer("size"),facts:facts) else {
            throw ChecklistError("GRID_BUDGET","This take exceeds the direction-grid byte, pixel or decoder budget. Use item comparison.")
        }
        let control=MediaNativeTakeControl(asset:asset,loop:true,playbackRate:timing.rate)
        let take=MediaPreparedTake(key:card.key,label:card.direction,kind:"video",ids:["item_id":card.id,"target_id":card.target.id,"reference_id":original.string("reference_id"),"slot_id":slot.string("slot_id")],control:control,player:control.player,file:file,
            measurement:.init(copyMilliseconds:copyMS,probeMilliseconds:probeMS,bytes:original.integer("size"),facts:facts,loop:true,timing:timing))
        guard playback.admit(take) else {throw ChecklistError("GRID_BUDGET","This take exceeds the direction-grid byte, pixel or decoder budget. Use item comparison.")}
        card.status=""
    }
    func decide(_ disposition: String,card: MediaDirectionCard,model: MediaReviewModel) async {
        guard !card.sending else {return};card.sending=true
        var dispatched=false
        let token=generation
        defer {if !dispatched {card.sending=false}}
        do {
            var params=try card.decisionRequest(disposition)
            // One card's earlier observation must not retarget another card after live changes.
            let current=Record(values:try await model.read("media_round_header",["round_id":card.header.id]))
            guard current.string("observed_context_token")==card.header.string("observed_context_token"),
                  NSDictionary(dictionary:current.object("manifest")).isEqual(to:card.header.object("manifest")),current.records("attention").isEmpty,
                  token==generation,model.projectID+":"+model.roundID==scope else {throw ChecklistError("MEDIA_CONTEXT_CHANGED","The group context changed. Reopen the group and inspect it before deciding.")}
            params["expected_revision"]=current.integer("revision")
            // Use the native durable command journal, including its unknown-outcome recovery.
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

struct MediaDirectionGrid: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    let group: MediaAnimationGroup
    let close: () -> Void
    @StateObject private var grid=MediaDirectionGridModel()
    var scope: String {model.projectID+":"+model.roundID+":"+group.id}
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Text(group.title).font(.title3);Spacer();Button("Close direction grid",action:close)}
            if model.filter != "all" {Text("All directions in this action, including items outside the list filter.").font(.caption)}
            HStack {
                Button("Play all") {grid.playback.playAll()}
                Button("Pause all") {grid.playback.pauseAll()}
                Button("Reload group") {Task {await grid.open(group:group,model:model)}}
            }
            DisclosureGroup("Playback limits") {
                Text("Up to 8 looping takes · 32 MiB each · 256 MiB total · 2,097,152 source pixels total · 1024 px per edge. Larger takes stay available in item comparison.").font(.caption)
            }
            if grid.loading {ProgressView("Preparing direction grid")}
            if let error=grid.error {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
            if !grid.loading,grid.cards.isEmpty,grid.error==nil {Text("No directions in this group.")}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:210),alignment:.top)],alignment:.leading,spacing:12) {
                ForEach(grid.cards) {card in MediaDirectionCardView(card:card,grid:grid,model:model)}
            }
            MediaTakeDetails(playback:grid.playback)
        }
        .accessibilityIdentifier("mediaDirectionGrid")
        .task(id:scope) {await grid.open(group:group,model:model)}
        .onDisappear {grid.close()}
    }
}

private struct MediaDirectionCardView: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var card: MediaDirectionCard
    @ObservedObject var grid: MediaDirectionGridModel
    @ObservedObject var model: MediaReviewModel
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(card.direction).font(.headline).accessibilityAddTraits(.isHeader)
            Text(MediaReviewModel.dispositionLabel(card.item.string("disposition"))).font(.caption)
            if let take=card.metadata["take"] as? String,!take.isEmpty {Text(take).font(.caption)}
            MediaDirectionPlayer(playback:grid.playback,card:card)
            if let hint=card.metadata["hint"] as? String,!hint.isEmpty {Text(hint).font(.caption).textSelection(.enabled)}
            ForEach(MediaComparisonLabels.suggestions(item:card.item)) {suggestion in
                Text((suggestion.isCurrent ? "Agent suggestion: " : "Earlier agent suggestion: ")+suggestion.source+" · "+suggestion.choice+" · "+suggestion.note).font(.caption).textSelection(.enabled)
            }
            TextField("Owner note",text:$card.draft.note,axis:.vertical).lineLimit(2...4)
                .accessibilityLabel("Owner note for "+card.direction)
            if !card.basisMatches {
                Button("I inspected this target and context") {card.inspectCurrentBasis()}
            }
            VStack(alignment:.leading) {
                Button("Accept") {decide("accepted")}
                Button("Changes requested") {decide("changes_requested")}
                    .checklistDisabled([(card.draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter what should change in the owner note.")])
                Button("Needs look") {decide("needs_look")}
            }.checklistDisabled([(grid.loading || card.sending,"Wait for this group or decision to finish."),(!card.basisMatches || !card.item.bool("published") || card.header.string("state") != "open" || model.historyOnly,"Inspect a published item in an open round before deciding."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            if !card.status.isEmpty {Text(card.status).font(.caption).textSelection(.enabled)}
        }.padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:6))
        .accessibilityElement(children:.contain).accessibilityLabel("Direction "+card.direction)
        .accessibilityIdentifier("mediaDirection:"+card.direction)
    }
    func decide(_ disposition: String) {Task {await grid.decide(disposition,card:card,model:model)}}
}

private struct MediaDirectionPlayer: View {
    @ObservedObject var playback: MediaPlaybackCoordinator
    @ObservedObject var card: MediaDirectionCard
    var body: some View {
        if let take=playback.takes[card.key],let player=take.player {
            NativePlayerAdapter(player:player,audio:false).frame(minHeight:140,maxHeight:220)
                .accessibilityLabel("Looping "+card.direction+" take")
            Text(MediaPlaybackLabels.playback(loop:true,frameRate:take.measurement.timing?.declaredFrameRate)).font(.caption)
        } else {Text(card.status.isEmpty ? "Take unavailable" : card.status).font(.caption)}
    }
}
