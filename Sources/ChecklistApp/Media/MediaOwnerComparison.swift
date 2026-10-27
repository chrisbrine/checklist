import SwiftUI
import AppKit
import ImageIO
import CryptoKit
import ChecklistCore

struct MediaOwnerComparison: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    @State private var direction=""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if !model.item.id.isEmpty {
                Text(model.item.string("title")).font(.title3).accessibilityAddTraits(.isHeader)
                Text(MediaReviewModel.dispositionLabel(model.item.string("disposition"))).font(.headline)
                if !model.item.object("decision").isEmpty {
                    let decision=Record(values:model.item.object("decision"))
                    Text("Last owner action: "+GlossaryText.title(decision.string("disposition"))+" · "+MediaComparisonLabels.time(decision.string("created_at"))+" · "+MediaComparisonLabels.origin(decision.string("origin"))).font(.caption).textSelection(.enabled)
                    Text(decision.string("note")).textSelection(.enabled)
                }
                ForEach(candidateChoices) {choice in
                    let candidate=choice.candidate
                    VStack(alignment:.leading,spacing:6) {
                        Text(choice.label).font(.headline).accessibilityLabel(choice.label)
                        ForEach(candidate.records("slots"),id:\.stringID) {slot in
                            MediaSlotView(model:model,slot:slot,example:nil,candidateIndex:choice.index)
                        }
                    }.padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:6))
                }
                if model.item.records("candidates").isEmpty {Text("No captured original. Title-only Draft; publication and owner decisions require captured material.").foregroundStyle(Color.checklistSecondaryText)}
                Button(model.examplesShown ? "Hide past approved examples" : "Show past approved examples") {Task {await model.showExamples(!model.examplesShown)}}
                    .accessibilityIdentifier("mediaExamplesToggle")
                if model.examplesShown {
                    Text("Historical owner-accepted examples — no current approval. Availability and current acceptance are rechecked when shown.").font(.caption)
                    if model.examples.isEmpty {Text("No matching available approved examples.").foregroundStyle(Color.checklistSecondaryText)}
                    ForEach(model.examples) {example in
                        VStack(alignment:.leading) {
                            Text(example.string("title")).font(.headline)
                            Text(example.string("historical_context_label")).font(.caption)
                            Text(example.string("round_title")+" · "+example.string("source_name")+" · "+MediaComparisonLabels.time(example.string("decision_created_at"))+" · "+MediaComparisonLabels.origin(example.string("decision_origin"))).font(.caption)
                            ForEach(example.records("slots"),id:\.stringID) {slot in MediaSlotView(model:model,slot:slot,example:example)}
                        }.padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:6))
                    }
                    if model.examplesNext != nil {Button("More approved examples") {Task {await model.showExamples(true,more:true)}}}
                }
                if model.writable {ownerActions}
                TechnicalDetails(raw: [("Selected media and candidates",model.item.values),("Historical examples",model.examples.map(\.values)),("Review attention",model.header.records("attention").map(\.values)),("Review context sources",model.header.records("context_sources").map(\.values)),("Proposed context sources",model.header.records("attention_sources").map(\.values))]).id(model.item.id)
                MediaTakeDetails(playback:model.playback)
            } else {Text("Select a media item to inspect its exact original and history.").foregroundStyle(Color.checklistSecondaryText)}
        }.accessibilityElement(children:.contain).accessibilityIdentifier("mediaComparison")
    }
    var candidateChoices: [MediaCandidateChoice] {
        MediaComparisonLabels.choices(item:model.item,definitions:model.slots)
    }
    var ownerActions: some View {
        VStack(alignment:.leading,spacing:8) {
            if !model.header.records("attention").isEmpty {
                Text("Approved context changed. Your input is saved. Inspect the current attention before keeping or migrating.").foregroundStyle(.orange)
                ForEach(model.header.records("attention_sources")) {source in
                    Text(MediaComparisonLabels.context(source)).font(.caption).textSelection(.enabled)
                }
                TextField("Reason for keeping or migrating context",text:$model.draft.reconciliationReason)
                HStack {
                    Button("Keep pinned context") {model.reconcile("keep")}
                    Button("Migrate to approved context") {model.reconcile("migrate")}
                }.checklistDisabled([(model.draft.reconciliationReason.isEmpty,"Enter a reason for keeping or migrating context."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            }
            DisclosureGroup("Approved review context") {
                ForEach(model.header.records("context_sources")) {source in Text(MediaComparisonLabels.context(source)).textSelection(.enabled)}
                TextField("Requires-action direction for this round",text:$direction)
                Button("Approve direction for this round") {model.mutate("media_context_approve",["kind":"direction","body":direction,"round_id":model.roundID]) {_ in direction=""}}
                    .checklistDisabled([(direction.isEmpty,"Enter the direction to approve."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            }
            if model.contextConflict {
                Text("The review context or target changed. Your draft is preserved; refresh and inspect before sending it again.").foregroundStyle(.orange)
                Button("I inspected the refreshed target and context") {model.reviewRefreshedContext()}
            }
            Picker("Winning candidate",selection:$model.draft.winnerID) {
                Text("Choose a winner").tag("")
                ForEach(candidateChoices) {choice in Text(choice.label).tag(choice.id).accessibilityLabel(choice.label)}
            }
            Text("Owner note · saved on this Mac, not sent").font(.caption)
            TextEditor(text:$model.draft.note).frame(minHeight:80).overlay(RoundedRectangle(cornerRadius:4).stroke(.separator)).accessibilityLabel("Media owner decision note")
            TextField("No-follow-up reason (optional)",text:$model.draft.noFollowUpReason)
            ViewThatFits(in:.horizontal) {
                HStack {decisionButtons}
                VStack(alignment:.leading) {decisionButtons}
            }.checklistDisabled([(!model.decisionEnabled,"Publish the selected item and choose whether to keep or update its review context before deciding."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            Text("Unanswered stays Pending. Show/Hide never records a decision. Changes requested creates no ticket here; rework and review closure are a later slice.").font(.caption).foregroundStyle(Color.checklistSecondaryText)
        }
    }
    @ViewBuilder var decisionButtons: some View {
        Button("Accept") {model.decide("accepted")}.accessibilityLabel("Accept exact selected media")
        Button("Needs look") {model.decide("needs_look")}
        Button(model.item.records("candidates").count > 1 ? "None fit / Changes requested" : "Changes requested") {model.decide("changes_requested")}
        Button("Exclude with reason") {model.decide("excluded")}.checklistDisabled([(model.draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter an exclusion reason in the owner note.")])
    }
}
private extension Record {var stringID:String {string("slot_id")}}

/// Human labels share the exact candidate ordering in cards and winner choices.
/// IDs remain selection values; full provenance and hashes belong to TechnicalDetails.
struct MediaCandidateChoice: Identifiable {
    let candidate: Record
    let label: String
    var index = 0
    var id: String { candidate.id }
}
enum MediaComparisonLabels {
    static func context(_ source: Record) -> String {
        if !source.string("body").isEmpty {return source.string("body")}
        if !source.string("rubric").isEmpty {return source.string("rubric")}
        let approved=Record(values:source.object("approved_context"))
        let text=([approved.string("brief")]+approved.records("pinned_decisions").map {
            [$0.string("title"),$0.string("body")].filter {!$0.isEmpty}.joined(separator:": ")
        }).filter {!$0.isEmpty}.joined(separator:"\n\n")
        return text.isEmpty ? "No written review context." : text
    }
    static func origin(_ value: String) -> String {
        switch value {
        case "human_ui": return "Owner"
        case "agent": return "Agent capture"
        default: return "Recorded capture"
        }
    }
    static func time(_ value: String) -> String {
        let parser=ISO8601DateFormatter()
        parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let date=parser.date(from:value) ?? ISO8601DateFormatter().date(from:value)
        return date?.formatted(date:.abbreviated,time:.shortened) ?? "Time unavailable"
    }
    static func slot(_ slot: Record, definitions: [Record]) -> String {
        let index=definitions.firstIndex {$0.id==slot.string("slot_id")}
        let definition=index.map {definitions[$0]}
        let label=definition?.string("label") ?? ""
        if !label.isEmpty, label != definition?.id {return label}
        let kind=definition?.string("kind") ?? (slot.values["text"] is String ? "text" : slot.string("media_kind"))
        let name=["text","image","audio","video"].contains(kind) ? kind.capitalized : "Media"
        return name+" slot"+(index.map {" \($0+1)"} ?? "")
    }
    /// Comparison role: the layout's declared reference slot, otherwise the numbered candidate.
    static func role(slotID: String, candidateIndex: Int?, referenceSlotID: String, historical: Bool) -> String {
        let base = !referenceSlotID.isEmpty && slotID == referenceSlotID ? "Reference" : candidateIndex.map {"Candidate \($0+1)"} ?? "Candidate"
        return historical ? "Approved example · "+base : base
    }
    static func imageAccessibilityLabel(_ slot: Record, definitions: [Record]) -> String {
        "Verified original image, "+self.slot(slot,definitions:definitions)
    }
    static func choices(item: Record, definitions: [Record]) -> [MediaCandidateChoice] {
        item.records("candidates").enumerated().map {index,candidate in
            let slots=candidate.records("slots").map {slot($0,definitions:definitions)}.joined(separator:", ")
            let label=["Candidate \(index+1)",item.string("title"),candidate.string("source_name",fallback:"Inline text"),origin(candidate.string("origin")),time(candidate.string("created_at")),slots].filter {!$0.isEmpty}.joined(separator:" · ")
            return MediaCandidateChoice(candidate:candidate,label:label,index:index)
        }
    }
}

enum MediaComparisonAvailability: Equatable {
    case text(String),image,playback(String),unavailable(String),unsupported(String)
    /// The captured take must match its slot's declared kind before any read or decode.
    static func resolve(slot:Record,original:Record?,declaredKind:String?=nil) -> Self {
        if let text=slot.values["text"] as? String {return .text(text)}
        let kind=slot.string("media_kind")
        if let declaredKind,!declaredKind.isEmpty,declaredKind != kind {return .unsupported("This take is "+(kind.isEmpty ? "untyped" : kind)+", but its slot declares "+declaredKind+". It cannot be compared.")}
        if ["video","audio"].contains(kind) {
            guard let original,original.string("availability")=="available" else {return .unavailable(unavailableText(original))}
            guard original.integer("size",fallback:0)<=MediaPlaybackBudget.originalBytes else {return .unsupported("This "+kind+" original exceeds the 500 MiB playback bound.")}
            return .playback(kind)
        }
        guard kind=="image" else {return .unsupported("This media format is not supported.")}
        guard let original,original.string("availability")=="available" else {return .unavailable(unavailableText(original))}
        guard original.integer("size",fallback:0)<=8*1024*1024 else {return .unsupported("This image exceeds the 8 MiB in-app original-read bound.")}
        return .image
    }
    /// Honest outcome per service reason; metadata stays visible, nothing is reauthorized.
    static func unavailableText(_ original:Record?) -> String {
        switch original?.string("unavailable_reason") ?? "" {
        case "cleaned": return "Original cleaned. Its record and history remain, but the exact bytes were removed, so it cannot be compared."
        case "missing": return "Original missing from managed storage. It cannot be compared."
        case "changed": return "Original changed after capture. It no longer matches its recorded size, so it cannot be compared."
        case "reference_unavailable": return "Original reference unavailable for this project. It cannot be compared."
        default: return "Original unavailable. A cached preview cannot establish exact review availability."
        }
    }
}

struct MediaSlotView: View {
    @ObservedObject var model:MediaReviewModel
    let slot:Record
    let example:Record?
    var candidateIndex:Int?=nil
    @State private var image:NSImage?
    @State private var status="Image not loaded"
    var original:Record? {
        if let example {return example.records("original_references").first {$0.string("slot_id")==slot.string("slot_id")}.map {var v=$0.values;v["availability"]="available";return Record(values:v)}}
        return model.item.records("originals").first {$0.string("attachment_id")==slot.string("attachment_id")}
    }
    var declaredKind:String {model.slots.first {$0.id==slot.string("slot_id")}?.string("kind") ?? ""}
    var role:String {MediaComparisonLabels.role(slotID:slot.string("slot_id"),candidateIndex:candidateIndex,referenceSlotID:model.referenceSlotID,historical:example != nil)}
    var imageKey:String {(original?.string("reference_id") ?? "")+":"+slot.string("slot_id")}
    var active:Bool {model.imageIsActive(imageKey,historical:example != nil)}
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(MediaComparisonLabels.slot(slot,definitions:model.slots)).font(.caption)
            switch MediaComparisonAvailability.resolve(slot:slot,original:original,declaredKind:declaredKind) {
            case .text(let value): Text(value).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel("Exact captured text: "+value)
            case .unavailable(let reason),.unsupported(let reason):Text(reason).foregroundStyle(Color.checklistSecondaryText)
            case .playback(let kind):
                if let original {
                    Text(role).font(.caption.weight(.semibold))
                    MediaPlaybackSlotView(model:model,playback:model.playback,slot:slot,original:original,example:example,kind:kind,label:role+" · "+MediaComparisonLabels.slot(slot,definitions:model.slots))
                }
            case .image:
                if active,let image {Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:460,maxHeight:300).accessibilityLabel(MediaComparisonLabels.imageAccessibilityLabel(slot,definitions:model.slots))}
                else {Text(active ? status : "Image not loaded");Button("Load exact image") {Task {await load()}}.checklistDisabled([(model.imageLoads>=2,"Two original images are loading. Wait for one to finish.")])}
            }
        }
        .onChange(of:model.currentImageReference) {_,_ in if !active {image=nil}}
        .onChange(of:model.historicalImageReference) {_,_ in if !active {image=nil}}
        .id((example?.string("target_id") ?? model.item.object("target")["id"] as? String ?? "")+slot.string("slot_id"))
    }
    @MainActor func load() async {
        guard let original,model.beginImage(imageKey,historical:example != nil) else {return}
        defer {model.endImage()}
        status="Loading verified original…"
        let selected=model.selectedID,target=model.item.object("target")["id"] as? String ?? ""
        var leaseID:String?
        do {
            let bytes:Data
            if let example {
                let lease=try await model.read("media_example_read_lease",["round_id":model.roundID,"target_id":example.string("target_id"),"decision_id":example.string("decision_id"),"reference_id":original.string("reference_id"),"seconds":300])
                leaseID=lease["lease_id"] as? String
                let attachment=Record(values:lease["attachment"] as? MediaValues ?? [:])
                bytes=try await MediaImageDecode.read(path:attachment.string("path"),size:attachment.integer("size",fallback:0),sha256:original.string("sha256"))
            } else {
                let value=try await model.read("media_original_read",["round_id":model.roundID,"item_id":selected,"target_id":target,"reference_id":original.string("reference_id")])
                guard let data=Data(base64Encoded:value["base64"] as? String ?? "") else {throw MediaImageDecode.Failure.unavailable};bytes=data
            }
            let decoded=try await MediaImageDecode.decode(bytes,sha256:slot.string("sha256"))
            if selected==model.selectedID,active,!Task.isCancelled {image=decoded;status="Verified original available"}
        } catch {status="Original unavailable or unsupported: "+PlainError.text(error);image=nil}
        if let leaseID {_ = try? await model.read("media_example_read_release",["lease_id":leaseID])}
    }
}

/// Explicit image reads/decodes use two dispatch workers, with no cooperative-pool
/// blocking, no unbounded NSImage lazy decoding and no persistent preview cache.
enum MediaImageDecode {
    enum Failure:Error {case unavailable,unsupported}
    private static let queue:OperationQueue = {let q=OperationQueue();q.maxConcurrentOperationCount=2;q.qualityOfService = .userInitiated;return q}()
    static func read(path:String,size:Int,sha256:String) async throws -> Data {
        try await work {
            guard size>0,size<=8*1024*1024 else {throw Failure.unsupported}
            let file=try FileHandle(forReadingFrom:URL(fileURLWithPath:path));defer {try? file.close()}
            let data=try file.read(upToCount:size+1) ?? Data()
            guard data.count==size,digest(data)==sha256 else {throw Failure.unavailable};return data
        }
    }
    @MainActor static func decode(_ bytes:Data,sha256:String) async throws -> NSImage {
        let cg = try await work {
            guard bytes.count<=8*1024*1024,digest(bytes)==sha256,
                  let source=CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width=(props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height=(props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width>0,height>0,width<=16_000_000/height,
                  let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {throw Failure.unsupported}
            return cg
        }
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
    private static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()}
    private static func work<T: Sendable>(_ operation:@escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation {continuation in queue.addOperation {do {continuation.resume(returning:try operation())} catch {continuation.resume(throwing:error)}}}
    }
}
