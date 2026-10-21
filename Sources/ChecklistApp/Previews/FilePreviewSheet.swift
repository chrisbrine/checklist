import SwiftUI
import AppKit
import ChecklistCore

struct FilePreviewSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let attachment: Record
    var resources: [Record] = []
    var inspected: (() -> Void)? = nil
    var openExternally = false
    @StateObject private var loader = FilePreviewLoader()
    @State private var showOpenIn = false
    @State private var showSource = false
    @State private var showQuickLook = false
    var kind: FilePreviewKind { FilePreviewKind.detect(name: attachment.string("name"), contentType: attachment.string("content_type")) }
    var presentation: FilePreviewPresentation { .resolved(kind: kind, metadata: attachment.object("preview_presentation")) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack {
                Text(attachment.string("name")).font(.headline).lineLimit(2)
                Spacer()
                if presentation.showsSource, loader.file != nil { Toggle("Source", isOn: $showSource).toggleStyle(.button) }
                if kind == .image { Button("Quick Look (Space)") { showQuickLook = true }.keyboardShortcut(" ", modifiers: []).checklistDisabled([(loader.file == nil, originalUnavailableReason)]) }
                Button("Open in…") { showOpenIn = true }.checklistDisabled([(loader.file == nil, originalUnavailableReason)])
                if loader.loading {
                    Button("Cancel preview") { loader.cancelPreparation() }.keyboardShortcut(.cancelAction)
                        .checklistDisabled([(loader.canceling, "Preview preparation is stopping.")])
                    Button("Close") { dismiss() }
                } else { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            Text("Viewing does not approve this candidate. External apps receive a separate working copy.").font(.caption).foregroundStyle(.secondary)
            if loader.loading {
                VStack(spacing: Spacing.row) {
                    if loader.copying {
                        ProgressView(value: Double(loader.copiedBytes), total: Double(max(1, loader.totalBytes)))
                            .accessibilityLabel("Preparing verified preview")
                        Text("\(ByteCountFormatter.string(fromByteCount: loader.copiedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: loader.totalBytes, countStyle: .file)) copied")
                            .monospacedDigit().accessibilityIdentifier("filePreviewCopyProgress")
                            .accessibilityLabel("Verified preview copy")
                            .accessibilityValue(Text(verbatim: "\(loader.copiedBytes) of \(loader.totalBytes) bytes"))
                    } else { ProgressView("Authorizing original…") }
                    Text(loader.canceling ? "Canceling preview…" : "Preparing verified preview…")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if loader.canceled {
                NativePreviewUnavailable(reason: loader.cancellationSummary, title: "Preview canceled")
                if !loader.problem.isEmpty { Text(loader.problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            else if let file = loader.file {
                NativeFilePreview(file: file, kind: kind, presentation: presentation, source: showSource, resources: resources)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !loader.problem.isEmpty { Text(loader.problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let inspected {
                    Button("Mark this original as inspected") { inspected(); dismiss() }.buttonStyle(.borderedProminent)
                        .help("Records only your inspection selection. Choose and send a verdict separately.")
                }
            } else if !loader.problem.isEmpty {
                NativePreviewUnavailable(reason: loader.problem, title: "Original unavailable")
            }
        }.padding(Spacing.page)
            .frame(minWidth: 640, idealWidth: 960, maxWidth: 1400, minHeight: 480, idealHeight: 680, maxHeight: 1000)
            // A sheet must own inherited AX properties, rather than forwarding
            // them into the conditional unavailable subtree's preferences.
            .accessibilityElement(children: .contain)
            .task(id: attachment.id + attachment.string("sha256") + attachment.string("availability")) { await loader.load(attachment, store: store) }
            .onChange(of: loader.file?.url) { _, url in if url != nil && openExternally { showOpenIn = true } }
            .onDisappear { loader.cancel() }
            .sheet(isPresented: $showOpenIn) { if let file = loader.file { OpenInApplicationsSheet(file: file) } }
            .sheet(isPresented: $showQuickLook) { if let file = loader.file { FileQuickLookSheet(file: file) } }
    }
    private var originalUnavailableReason: String {
        if loader.canceled { return "Preview preparation was canceled. Close and reopen to prepare another copy." }
        return loader.problem.isEmpty ? "The verified copy is not ready yet." : loader.problem
    }
}

struct NativeOpenApplication: Identifiable, Equatable {
    let url: URL
    let isDefault: Bool
    var id: String { url.path }
    var name: String { (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent }
}

@MainActor
enum NativeOpenApplications {
    static func discover(_ file: URL) -> [NativeOpenApplication] {
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: file)
        let urls = workspace.urlsForApplications(toOpen: file) + (preferred.map { [$0] } ?? [])
        var seen = Set<String>()
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
            .map { NativeOpenApplication(url: $0, isDefault: $0.standardizedFileURL == preferred?.standardizedFileURL) }
            .sorted { if $0.isDefault != $1.isDefault { return $0.isDefault }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct OpenInApplicationsSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let file: AuthorizedPreviewFile
    @State private var apps: [NativeOpenApplication] = []
    @State private var selection = ""
    @State private var opening = false
    @State private var problem = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text("Open in…").font(.title2.bold())
            Text("macOS reports these installed apps as compatible. The chosen app receives a working copy of \(file.source.string("name")); edits never replace the recorded original or approve a review.").font(.callout)
            if apps.isEmpty { Text("No compatible installed application is available for this file type.").foregroundStyle(.orange) }
            else {
                List(apps, selection: $selection) { app in
                    VStack(alignment: .leading) {
                        Text(app.name + (app.isDefault ? " (default)" : ""))
                        Text(app.url.path).font(.caption).foregroundStyle(.secondary)
                    }.tag(app.id)
                }.frame(minHeight: 170)
            }
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { store.notice = "Opening canceled; no application was launched."; dismiss() }.keyboardShortcut(.cancelAction).checklistDisabled([(opening, "An app is still opening. Wait for it to finish.")])
                Spacer()
                if opening { ProgressView().controlSize(.small) }
                Button("Open working copy") { open() }.buttonStyle(.borderedProminent).checklistDisabled([(opening, "An app is still opening. Wait for it to finish."), (!apps.contains(where: { $0.id == selection }), "Choose a compatible app first.")])
            }
        }.padding(Spacing.page).frame(width: 540, height: 400)
            .onAppear { apps = NativeOpenApplications.discover(file.url); selection = apps.first(where: \.isDefault)?.id ?? apps.first?.id ?? "" }
    }
    func open() {
        guard !opening, let chosen = apps.first(where: { $0.id == selection }),
              NativeOpenApplications.discover(file.url).contains(where: { $0.id == chosen.id }) else { problem = "That compatible app is no longer available. Close and reopen the chooser."; return }
        opening = true; problem = ""
        Task {
            do {
                // Refresh service authorization before exporting even a previously viewed copy.
                let response = try await store.request("attachment_read", ["project_id": file.source.string("project_id"), "attachment_id": file.source.id, "representation": "original"])
                let actual = Record(values: response), hold = response["read_hold_id"] as? String
                if let hold { _ = try await store.request("attachment_read_release", ["command_id": UUID().uuidString, "project_id": file.source.string("project_id"), "read_hold_id": hold]) }
                guard actual.id == file.source.id, actual.string("sha256") == file.sha256, actual.string("availability") == "available" else { throw FilePreviewFailure("The original is no longer available with this identity.") }
                let copy = try await Task.detached(priority: .userInitiated) { try file.externalWorkingCopy() }.value
                NSWorkspace.shared.open([copy], withApplicationAt: chosen.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    Task { @MainActor in
                        opening = false
                        if let error {
                            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent().deletingLastPathComponent())
                            problem = Canceled.isUserCancellation(error) ? "Opening was canceled. No approval was recorded." : "macOS could not open this working copy: " + PlainError.text(error)
                        } else { store.notice = "macOS accepted the working copy for \(chosen.name). No review verdict was recorded."; dismiss() }
                    }
                }
            } catch { opening = false; problem = PlainError.text(error) }
        }
    }
}
