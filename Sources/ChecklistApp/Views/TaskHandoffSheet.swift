import SwiftUI
import AppKit

struct TaskHandoffSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let task: Record
    let provider: HandoffProvider
    @StateObject private var model = TaskHandoffModel()
    @State private var copied = false
    var applicationURL: URL? { provider.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var canCompose: Bool { model.composeURL != nil && applicationURL != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            AccessibleHStack { Text("Use in \(provider.name)").checklistFont(.sheetTitle); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.checklistIcon).accessibilityLabel("Close handoff").help("Close handoff") }
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("\(store.projectName(task.string("project_id"))) · \(task.string("key"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Text(task.string("title")).checklistFont(.bodyStrong).lineLimit(3)
            }
            if model.loading { ProgressView("Preparing ticket context…").frame(maxWidth: .infinity).padding(Spacing.group) }
            else {
                if !model.preparationFailure.isEmpty {
                    Text(model.preparationFailure).checklistFont(.callout).foregroundStyle(.orange)
                    Button("Retry preparation") { Task { await prepare() } }.checklistDisabled([(model.opening, "Waiting for the provider to open.")])
                }
                if !model.instruction.isEmpty {
                    Text(canCompose ? "Open the prepared \(provider.name) chat and press Send. Its prompt connects the actual thread to this ticket through Checklist; you do not need to copy the instruction or enter a session ID." : "Open a thread in \(provider.name) and paste this instruction. The thread connects itself through Checklist; you do not need to enter a session ID or configure a connection in Settings.").checklistFont(.callout)
                    ScrollView { Text(model.instruction).checklistFont(.codeCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.control) }.frame(minHeight: 80, maxHeight: 180).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.medium))
                    if applicationURL == nil { Text("\(provider.name) could not be located on this Mac. Copy the instruction to a supported conversation.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    if model.openedComposer { Label("Prepared chat opened. Press Send in \(provider.name) to connect the thread.", systemImage: "arrow.up.right.square").checklistFont(.micro).foregroundStyle(Color.checklistAccentText) }
                    if !model.limitation.isEmpty { Label(model.limitation, systemImage: "info.circle").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    Text("Opening a composer shares a draft prompt. It does not start a turn, assign the ticket or claim work.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                if !model.openingFailure.isEmpty {
                    Text("\(provider.name) opening failed: \(model.openingFailure) You can retry or copy the instruction. No connection or work claim is confirmed by opening a chat.").checklistFont(.callout).foregroundStyle(.orange)
                }
            }
            AccessibleHStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy instruction") { clipboard(model.instruction); copied = true }.checklistDisabled([(model.loading, "Still loading."), (model.instruction.isEmpty, "The ticket instruction is not ready yet.")])
                if canCompose {
                    Button(model.opening ? "Opening…" : model.openingFailure.isEmpty ? "Open prepared \(provider.name) chat" : "Retry prepared \(provider.name) chat") { Task { await openPreparedChat() } }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command).checklistDisabled([(model.loading, "Still loading."), (model.opening, "Waiting for \(provider.name) to open.")])
                } else if let applicationURL {
                    Button("Open \(provider.name)") {
                        Task {
                            await model.openApplication(applicationURL) { app in
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                                    }
                                }
                            }
                        }
                    }.checklistDisabled([(model.loading, "Still loading."), (model.instruction.isEmpty, "The ticket instruction is not ready yet."), (model.opening, "Waiting for the provider to open.")])
                }
            }
        }.padding(Spacing.page).checklistSheet(width: 600).task { await prepare() }
    }
    func prepare() async {
        copied = false
        await model.prepare(task: task, provider: provider, transport: store.request)
    }
    func openPreparedChat() async {
        await model.openPreparedChat(applicationURL: applicationURL) { url, app in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        if model.openedComposer { store.notice = "Prepared \(provider.name) chat opened. Press Send there to connect." }
    }
}
