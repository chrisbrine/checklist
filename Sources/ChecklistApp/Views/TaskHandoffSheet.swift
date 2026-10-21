import SwiftUI
import AppKit

struct HandoffProvider: Identifiable {
    let id: String
    var name: String { id == "claude" ? "Claude" : "Codex" }
    var bundleID: String { id == "claude" ? "com.anthropic.claudefordesktop" : "com.openai.codex" }
}

struct TaskHandoffSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let task: Record
    let provider: HandoffProvider
    @State private var commandID = UUID().uuidString
    @State private var loading = true
    @State private var instruction = ""
    @State private var limitation = ""
    @State private var failure = ""
    @State private var copied = false
    @State private var composeURL: URL?
    @State private var openedComposer = false
    var applicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID) }
    var canCompose: Bool { composeURL != nil && applicationURL != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            AccessibleHStack { Text("Use in \(provider.name)").checklistFont(.sheetTitle); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.checklistIcon).accessibilityLabel("Close handoff").help("Close handoff") }
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("\(store.projectName(task.string("project_id"))) · \(task.string("key"))").checklistFont(.micro).foregroundStyle(.secondary)
                Text(task.string("title")).checklistFont(.bodyStrong).lineLimit(3)
            }
            if loading { ProgressView("Preparing ticket context…").frame(maxWidth: .infinity).padding(Spacing.group) }
            else if !failure.isEmpty {
                Text(failure).checklistFont(.callout).foregroundStyle(.orange)
                Button("Retry preparation") { Task { await prepare() } }
            } else {
                Text(canCompose ? "Open the prepared Codex chat and press Send. Its prompt connects the actual thread to this ticket through Checklist; you do not need to copy the instruction or enter a session ID." : "Open a thread in \(provider.name) and paste this instruction. The thread connects itself through Checklist; you do not need to enter a session ID or configure a connection in Settings.").checklistFont(.callout)
                ScrollView { Text(instruction).checklistFont(.codeCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.control) }.frame(minHeight: 80, maxHeight: 180).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.medium))
                if openedComposer { Label("Prepared chat opened. Press Send in Codex to connect the thread.", systemImage: "arrow.up.right.square").checklistFont(.micro).foregroundStyle(Color.checklistAccentText) }
                if !limitation.isEmpty { Label(limitation, systemImage: "info.circle").checklistFont(.micro).foregroundStyle(.secondary) }
                Text("Opening a composer shares a draft prompt. It does not start a turn, assign the ticket or claim work.").checklistFont(.micro).foregroundStyle(.secondary)
            }
            AccessibleHStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if canCompose {
                    Button(copied ? "Copied" : "Copy instruction") { clipboard(instruction); copied = true }.checklistDisabled([(loading, "Still loading."), (instruction.isEmpty, "The ticket instruction is not ready yet.")])
                    Button("Open prepared Codex chat") { openPreparedChat() }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command).checklistDisabled([(loading, "Still loading."), (!failure.isEmpty, "Loading failed. Read the message above.")])
                } else {
                    if let applicationURL {
                        Button("Open \(provider.name)") {
                            NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                                if let error { Task { @MainActor in failure = PlainError.text(error) } }
                            }
                        }.checklistDisabled([(loading, "Still loading."), (!failure.isEmpty, "Loading failed. Read the message above.")])
                    }
                    Button(copied ? "Copied" : "Copy instruction") { clipboard(instruction); copied = true }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command).checklistDisabled([(loading, "Still loading."), (instruction.isEmpty, "The ticket instruction is not ready yet.")])
                }
            }
        }.padding(Spacing.page).checklistSheet(width: 600).task { await prepare() }
    }
    func prepare() async {
        loading = true; failure = ""; composeURL = nil
        defer { loading = false }
        do {
            let response = try await store.request("task_handoff_prepare", ["command_id": commandID, "project_id": task.string("project_id"), "task_id": task.id, "provider": provider.id])
            guard let returned = response["instruction"] as? String, !returned.isEmpty else { throw NSError(domain: "Checklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "The service did not return a ticket instruction. No thread was created."]) }
            instruction = returned
            limitation = response["limitation"] as? String ?? ""
            if let raw = response["compose_url"] as? String {
                guard provider.id == "codex", let validated = CodexComposeLink.validated(raw) else { throw NSError(domain: "Checklist", code: 2, userInfo: [NSLocalizedDescriptionKey: "The service returned an unsupported compose link. No chat was opened."]) }
                composeURL = validated
            }
        } catch { failure = PlainError.text(error) }
    }
    func openPreparedChat() {
        guard let composeURL, let applicationURL else { return }
        NSWorkspace.shared.open([composeURL], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error { failure = PlainError.text(error) }
                else { openedComposer = true; store.notice = "Prepared Codex chat opened. Press Send there to connect." }
            }
        }
    }
}
