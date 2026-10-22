import SwiftUI
import AppKit
import ChecklistCore

struct ImageReviewSection: View {
    let manifest: Record?
    let projection: ReviewProjection
    @State private var showing = false
    @State private var selection = Set<ImageInspectionIdentity>()
    var current: [ImageReviewCandidate] { manifest.map { ImageReviewProjection.candidates(manifest: $0, review: projection) } ?? [] }
    var previous: [ImageReviewCandidate] {
        guard let manifest, let old = ImageReviewProjection.previous(to: manifest, review: projection) else { return [] }
        return ImageReviewProjection.candidates(manifest: old, review: projection)
    }
    var body: some View {
        if !current.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Button("Compare candidate images…") { showing = true }.checklistFont(.micro)
                Text("\(current.count) exact candidate images. Inspection selections do not approve a review.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }.sheet(isPresented: $showing) { ImageReviewSheet(current: current, previous: previous, selection: $selection, editable: false) }
                .onChange(of: manifest?.id) { _, _ in selection = [] }
        }
    }
}

struct ImageReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: [ImageReviewCandidate]
    var previous: [ImageReviewCandidate] = []
    @Binding var selection: Set<ImageInspectionIdentity>
    var editable = true
    @State private var selectedView = Data()
    @State private var selectedCurrent = ""
    @State private var selectedPrevious = ""
    var groups: [ImageReviewGroup] { ImageReviewGroup.make(current: current, previous: previous) }
    var group: ImageReviewGroup? { groups.first { $0.id == selectedView } ?? groups.first }
    var currentImage: ImageReviewCandidate? { group?.current.first { $0.file.id == selectedCurrent } ?? group?.current.first }
    var previousImage: ImageReviewCandidate? {
        if let chosen = group?.previous.first(where: { $0.file.id == selectedPrevious }) { return chosen }
        return group?.previous.count == 1 ? group?.previous.first : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack {
                Text("Compare candidate images").font(.title2.bold()); Spacer()
                if editable { Text("Inspected \(current.filter { selection.contains($0.identity) }.count) of \(current.count)").font(.callout) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(editable ? "Mark each original after inspecting it. Choose and send an approval separately." : "View the exact submitted originals. Owner inspection selections are recorded in the associated approval request.").font(.caption).foregroundStyle(Color.checklistSecondaryText)
            Picker("View", selection: Binding(get: { group?.id ?? Data() }, set: { selectedView = $0; selectedCurrent = ""; selectedPrevious = "" })) {
                ForEach(groups) { group in Text("\(group.viewName) · \(group.current.count) current").tag(group.id) }
            }.onChange(of: selectedView) { _, _ in selectedCurrent = ""; selectedPrevious = "" }
            HStack(alignment: .top, spacing: Spacing.row) {
                VStack(alignment: .leading) {
                    Text("Previous round").font(.headline)
                    if let group, group.previous.count > 1 {
                        Picker("Previous candidate", selection: $selectedPrevious) {
                            Text("Choose an exact previous candidate").tag("")
                            ForEach(group.previous) { Text($0.file.string("name")).tag($0.file.id) }
                        }
                    }
                    if let previousImage { ImageInspectionPane(candidate: previousImage, selection: .constant([]), editable: false, spaceQuickLook: false).id(previousImage.identity) }
                    else { ContentUnavailableView("No unambiguous previous image", systemImage: "photo.on.rectangle", description: Text("Previous history may be outside the loaded context, or this view has no previous candidate.")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading) {
                    Text("Selected round").font(.headline)
                    if let group, group.current.count > 1 {
                        Picker("Current candidate", selection: Binding(get: { currentImage?.file.id ?? "" }, set: { selectedCurrent = $0 })) {
                            ForEach(group.current) { Text($0.file.string("name")).tag($0.file.id) }
                        }
                    }
                    if let currentImage { ImageInspectionPane(candidate: currentImage, selection: $selection, editable: editable, spaceQuickLook: true).id(currentImage.identity) }
                    else { ContentUnavailableView("No candidate in this round", systemImage: "photo") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(Spacing.page).frame(minWidth: 760, idealWidth: 1180, maxWidth: 1600, minHeight: 540, idealHeight: 730, maxHeight: 1100)
            .onAppear { selectedView = groups.first?.id ?? Data() }
    }
}

private struct ImageInspectionPane: View {
    @EnvironmentObject var store: ChecklistStore
    let candidate: ImageReviewCandidate
    @Binding var selection: Set<ImageInspectionIdentity>
    let editable: Bool
    let spaceQuickLook: Bool
    @StateObject private var loader = FilePreviewLoader()
    @State private var quickLook = false
    @State private var decoded = false
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(candidate.file.string("name")).font(.callout.bold()).lineLimit(2)
            if let reason = candidate.unavailable { Text(reason).foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if loader.loading { ProgressView("Loading exact original…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let file = loader.file {
                ImageFrameReviewPreview(url: file.url, metadata: candidate.file.object("preview_presentation"), onReady: { decoded = true })
                if !loader.problem.isEmpty { Text(loader.problem).font(.caption).foregroundStyle(.orange) }
                HStack {
                    if spaceQuickLook { Button("Quick Look (Space)") { quickLook = true }.keyboardShortcut(" ", modifiers: []) }
                    else { Button("Quick Look") { quickLook = true } }
                    Spacer()
                    if editable {
                        Toggle("Inspected", isOn: Binding(get: { selection.contains(candidate.identity) }, set: { value in
                            if value { selection.insert(candidate.identity) } else { selection.remove(candidate.identity) }
                        })).checklistDisabled([(!decoded, "The image is still loading.")]).help("Records an inspection selection for this exact original. It does not approve the candidate.")
                    }
                }
                TechnicalDetails([("Attachment", candidate.file.id), ("SHA-256", candidate.identity.sha256), ("Submission", candidate.identity.targetManifestID)])
            } else { Text(loader.problem).foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: candidate.identity) { if candidate.unavailable == nil { await loader.load(candidate.file, store: store) } }
            .onDisappear { loader.cancel() }
            .sheet(isPresented: $quickLook) { if let file = loader.file { FileQuickLookSheet(file: file) } }
    }
}
