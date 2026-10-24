import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// CL-65: quick capture from anywhere: title, project, optional note and image or file.
struct QuickCaptureView: View {
    @ObservedObject var model: QuickCaptureModel
    var close: () -> Void
    var submitDraft: () -> Void
    var openTicket: (String) -> Void
    static let lockedReason = "This ticket is being created; its title, project, Epic and files are fixed."
    @FocusState private var titleFocused: Bool
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            if case .captured(let key, let taskID, _) = model.state {
                captured(key: key, taskID: taskID)
            } else {
                form
            }
        }
        .padding(Spacing.section)
        .frame(minWidth: 420, minHeight: 300, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: drop)
        .onExitCommand { close() }
        .task(id:model.draft.projectID) {await model.loadEpics()}
    }

    @ViewBuilder var form: some View {
        let locked = model.state == .sending || (model.draft.createdTaskID != nil && model.draft.pendingCreate == nil)
        let filesLocked = locked || model.draft.pendingCreate != nil || model.draft.createdTaskID != nil
        TextField("What needs doing?", text: $model.draft.title).checklistFont(.subheading).textFieldStyle(.roundedBorder)
            .focused($titleFocused).accessibilityIdentifier("quickCaptureTitle").checklistDisabled([(locked, QuickCaptureView.lockedReason)])
            .onAppear { titleFocused = true }
            .onSubmit { submitDraft() }
        Picker("Project", selection: $model.draft.projectID) {
            Text("Choose a project").tag("")
            if !model.draft.projectID.isEmpty, !model.projects.contains(where: { $0.id == model.draft.projectID }) { Text("Saved project").tag(model.draft.projectID) }
            ForEach(model.projects) { Text($0.name).tag($0.id) }
        }.checklistDisabled([(locked, QuickCaptureView.lockedReason)]).accessibilityIdentifier("quickCaptureProject")
        if !model.draft.projectID.isEmpty {
            if model.epicTotal == 0,!model.epicLoading {CaptureEpicCreator(projectID:model.draft.projectID,request:model.createEpicRequest) {epic in guard RecordIdentity(epic.string("project_id"))==RecordIdentity(model.draft.projectID) else {return};model.draft.epicID=epic.id;Task {await model.loadEpics()}}}
            Picker("Epic", selection: Binding(get: {model.draft.epicID ?? ""}, set: {model.draft.epicID = $0})) {
                Text("Choose an Epic").tag("")
                if let saved = model.draft.epicID, !saved.isEmpty, !model.availableEpics.contains(where: {$0.id == saved}) {Text("Saved Epic").tag(saved)}
                ForEach(model.availableEpics) {Text(ProductionGroups.label($0)).tag($0.id)}
            }.checklistDisabled([(locked, QuickCaptureView.lockedReason), (model.epicLoading, "Epics are still loading.")]).accessibilityIdentifier("quickCaptureEpic")
            AccessibleHStack {
                if model.epicLoading {ProgressView().controlSize(.small)}
                if let cursor = model.epicPrevious {Button("Previous Epics") {Task {await model.loadEpics(cursor:cursor)}}}
                if let cursor = model.epicNext {Button("More Epics") {Task {await model.loadEpics(cursor:cursor)}}}
                if let failure = model.epicError {Text(failure).foregroundStyle(.orange);Button("Retry Epics") {Task {await model.loadEpics()}}}
            }.checklistFont(.micro).checklistDisabled([(model.epicLoading, "Epics are still loading.")])
        }
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Note (optional)").checklistFont(.caption).foregroundStyle(Color.checklistSecondaryText)
            TextEditor(text: $model.draft.note).checklistFont(.body).frame(minHeight: 70).padding(Spacing.tight)
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).accessibilityLabel("Note").checklistDisabled([(locked, QuickCaptureView.lockedReason)])
        }
        AccessibleHStack {
            Button("Add file…") { model.attach(chooseFiles(directories: false)) }
            Button("Attach clipboard image") { model.attachClipboardImage() }
                .checklistDisabled([(!QuickCaptureModel.clipboardHasImage(), "The clipboard has no image.")])
            Spacer()
        }.checklistDisabled([(filesLocked, "Finish checking this ticket before changing files.")])
        ForEach(model.draft.files) { file in
            AccessibleHStack {
                Label(URL(fileURLWithPath: file.path).lastPathComponent, systemImage: file.attached ? "checkmark.circle" : "doc").lineLimit(1)
                Spacer()
                if !file.attached && !filesLocked {
                    Button { model.remove(file) } label: { Image(systemName: "xmark") }.buttonStyle(.checklistIcon)
                        .accessibilityLabel("Remove \(URL(fileURLWithPath: file.path).lastPathComponent)")
                }
            }.checklistFont(.callout)
        }
        Text("Drop files here or on the Checklist Dock icon. Files are attached as managed copies; the originals stay where they are.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        if model.draft.pendingCreate != nil {
            Text(QuickCaptureModel.newerEdits).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
        if case .uncertain(let reason) = model.state {
            Text(reason).checklistFont(.callout).foregroundStyle(.orange).accessibilityIdentifier("quickCaptureUncertain")
        } else if case .filesPending(let reason) = model.state {
            Text(reason).checklistFont(.callout).foregroundStyle(.orange).accessibilityIdentifier("quickCaptureFilesPending")
        } else if case .notSent(let reason) = model.state { Text(reason).checklistFont(.callout).foregroundStyle(.orange).accessibilityIdentifier("quickCaptureNotSent") }
        else if !model.projectsAvailable && model.projects.isEmpty { Text("Checklist's service is not available, so no projects are listed. Your draft is saved on this Mac.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
        if let problem = model.problem { Text(problem).checklistFont(.micro).foregroundStyle(.orange) }
        Spacer(minLength: 0)
        AccessibleHStack {
            Button("Close") { close() }.keyboardShortcut(.cancelAction).help("Close; the draft stays saved on this Mac")
            Spacer()
            if model.state == .sending { ProgressView().controlSize(.small) }
            Button(model.sendTitle, action: submitDraft)
                .buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command)
                .checklistDisabled([(model.draft.pendingCreate == nil && model.draft.createdTaskID == nil && model.draft.projectID.isEmpty, "Choose a project first."),
                                    (model.draft.pendingCreate == nil && model.draft.createdTaskID == nil && model.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a title first."),
                                    (model.draft.pendingCreate == nil && model.draft.createdTaskID == nil && (model.draft.epicID ?? "").isEmpty, "Choose an Epic first."),
                                    (model.state == .sending, DisabledReasons.saving)])
        }
    }

    @ViewBuilder func captured(key: String, taskID: String) -> some View {
        Label(key.isEmpty ? "Ticket captured as a Draft." : "\(key) captured as a Draft.", systemImage: "checkmark.circle.fill")
            .checklistFont(.subheading).accessibilityIdentifier("quickCaptureDone")
        Text("Add its outcome and make it ready in Checklist when you are set.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
        if !model.draft.isEmpty {
            Text("Your newer edits are saved as the next draft.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
        }
        Spacer(minLength: 0)
        AccessibleHStack {
            Button("Close") { close() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(model.draft.isEmpty ? "New ticket" : "Continue draft") { model.startAnother(); titleFocused = true }
            Button("Open ticket") { openTicket(taskID) }.buttonStyle(.checklistProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in if let url, model.draft.createdTaskID == nil { model.attach([url]) } }
            }
        }
        return true
    }
}

enum QuickCaptureSettings {
    static let menuBarKey = "showMenuBarItem"
    static let help = "The menu bar item and the shortcut open New Ticket from any app, also when every Checklist window is closed. Files dropped on the Checklist Dock icon open it with those files."
}

/// Settings > General: the menu bar item and the owner's quick-capture shortcut.
struct QuickCaptureSettingsSection: View {
    @AppStorage(QuickCaptureSettings.menuBarKey, store: .standard) private var showMenuBarItem = true
    @State private var shortcut = QuickCaptureShortcut.load()
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?
    var body: some View {
        Section("Quick capture") {
            Toggle("Show Checklist in the menu bar", isOn: $showMenuBarItem)
                .onChange(of: showMenuBarItem) { _, _ in QuickCaptureController.shared.updateMenuBarItem() }
            LabeledContent("Shortcut") {
                AccessibleHStack {
                    Text(recording ? "Type the new shortcut…" : shortcut?.display ?? "Off").checklistFont(.body).accessibilityIdentifier("quickCaptureShortcut")
                    Button(recording ? "Cancel" : "Change…") { recording ? stop() : record() }
                    if shortcut != nil && !recording { Button("Turn off") { apply(nil) } }
                    if shortcut == nil && !recording { Button("Use \(QuickCaptureShortcut.standard.display)") { apply(.standard) } }
                }
            }
            if let problem { Text(problem).checklistFont(.micro).foregroundStyle(.orange) }
            Text(QuickCaptureSettings.help).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }.onDisappear { stop() }
    }
    private func record() {
        recording = true; problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            guard let next = QuickCaptureShortcut.from(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) else {
                problem = "Use Command, Control or Option with a key."; return nil
            }
            apply(next); stop(); return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
    }
    private func apply(_ next: QuickCaptureShortcut?) {
        QuickCaptureShortcut.save(next)
        QuickCaptureController.shared.registerShortcut()
        shortcut = QuickCaptureShortcut.load()
        problem = QuickCaptureController.shared.shortcutProblem
    }
}
