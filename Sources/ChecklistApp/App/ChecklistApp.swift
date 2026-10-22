import ChecklistIPC
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let termination: CaptureTerminationCoordinator
    private var terminationReply: ((Bool) -> Void)?
    private var terminationFailure: ((String) -> Void)?
    override init() { termination = MainActor.assumeIsolated { .shared }; super.init() }
    init(termination: CaptureTerminationCoordinator, reply: @escaping (Bool) -> Void, failure: @escaping (String) -> Void) {
        self.termination = termination; terminationReply = reply; terminationFailure = failure; super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(reply: terminationReply ?? { sender.reply(toApplicationShouldTerminate: $0) }, failure: terminationFailure ?? { message in
            // The pending termination has already been canceled before showing UI.
            DispatchQueue.main.async {
                sender.presentError(NSError(domain: "Checklist.Capture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Checklist could not quit safely", NSLocalizedRecoverySuggestionErrorKey: message]))
            }
        })
    }

    /// The notification delegate must exist before launch ends, so that a click that launched the app opens its item (CL-59).
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = DesktopAlertCoordinator.shared }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            QuickCaptureController.shared.registerShortcut()
            QuickCaptureController.shared.updateMenuBarItem()
        }
    }
    /// CL-65: files dropped on the Dock icon (or opened with Checklist) start a quick capture with them.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        MainActor.assumeIsolated { QuickCaptureController.shared.show(files: files) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ChecklistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window(ChecklistInstance.current.displayName, id: "main") {
            WorkspaceWindowRoot(identity: .primary).checklistTestIdentification()
        }
        .defaultSize(width: 1240, height: 820)
        .commands { ChecklistWindowCommands() }

        WindowGroup(ChecklistInstance.current.displayName, id: "workspace", for: UUID.self) { $id in
            WorkspaceWindowRoot(identity: .workspace(id)).checklistTestIdentification()
        } defaultValue: { UUID() }
        .defaultSize(width: 1240, height: 820)
    }
}

extension Notification.Name { static let toggleChecklistSidebar = Notification.Name("toggleChecklistSidebar") }

private struct ChecklistStoreFocusKey: FocusedValueKey { typealias Value = ChecklistStore }
extension FocusedValues {
    var checklistStore: ChecklistStore? {
        get { self[ChecklistStoreFocusKey.self] }
        set { self[ChecklistStoreFocusKey.self] = newValue }
    }
}

struct ChecklistWindowCommands: Commands {
    @FocusedValue(\.checklistStore) private var store
    @FocusedValue(\.checklistTicketOrder) private var ticketOrder
    @AppStorage(TextScale.key, store: .standard) private var textScale = 1.0
    @FocusedValue(\.checklistSettings) private var settings
    @Environment(\.openWindow) private var openWindow
    @AppStorage private var lastWorkspaceID: String
    init(storage: WorkspaceWindowStorage = .application) {
        _lastWorkspaceID = AppStorage(wrappedValue: "", WorkspaceWindowStorage.lastWorkspaceKey, store: storage.primaryPreferences)
    }
    private var modalActive: Bool { settings?.isPresented ?? SettingsModalPresentation.currentWindow()?.isPresented ?? false }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if let settings { settings.present() }
                else { SettingsModalPresentation.currentWindow()?.present() }
            }.keyboardShortcut(",", modifiers: .command)
                .checklistDisabled([(settings == nil && SettingsModalPresentation.currentWindow() == nil, "Open a Checklist window first.")])
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "workspace", value: UUID()) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .checklistDisabled([(modalActive, "Close the open dialog first.")])
            Button("Reopen Last Workspace") {
                if let id = UUID(uuidString: lastWorkspaceID) { openWindow(id: "workspace", value: id) }
            }.checklistDisabled([(modalActive, "Close the open dialog first."), (UUID(uuidString: lastWorkspaceID) == nil, "There is no earlier workspace to reopen.")])
            Divider()
            Group {
                Button("New Ticket…") { store?.showCapture = true }.keyboardShortcut("n")
                Button("New Project…") { store?.showNewProject = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            }.checklistDisabled([(modalActive, "Close the open dialog first."), (store == nil, "Open a Checklist window first.")])
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { textScale = TextScale.stepping(textScale, by: 1) }
                .keyboardShortcut("+", modifiers: .command).checklistDisabled([(TextScale.normalized(textScale) == TextScale.steps.last, "Text is already at the largest size.")])
            Button("Smaller Text") { textScale = TextScale.stepping(textScale, by: -1) }
                .keyboardShortcut("-", modifiers: .command).checklistDisabled([(TextScale.normalized(textScale) == TextScale.steps.first, "Text is already at the smallest size.")])
            Button("Actual Size Text") { textScale = 1 }.keyboardShortcut("0", modifiers: .command)
        }
        CommandMenu("Navigate") {
            Button("Next Ticket") { navigate(forward: true) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .checklistDisabled([(modalActive, "Close the open dialog first."), (destination(forward: true) == nil, "There is no next ticket.")])
            Button("Previous Ticket") { navigate(forward: false) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .checklistDisabled([(modalActive, "Close the open dialog first."), (destination(forward: false) == nil, "There is no previous ticket.")])
            Button("Back") { store?.goBack() }.keyboardShortcut("[", modifiers: .command)
                .checklistDisabled([(modalActive, "Close the open dialog first."), (store?.detailBackStack.isEmpty != false, "There is no earlier detail.")])
            Divider()
            Group {
                Button("Overview") { store?.select(.overview) }.keyboardShortcut("1")
                Button("Needs You") { store?.select(.needsYou) }.keyboardShortcut("2")
                Divider()
                Button("Refresh") { if let store { Task { await store.refresh() } } }.keyboardShortcut("r")
                Button("Toggle Sidebar") { if let store { NotificationCenter.default.post(name: .toggleChecklistSidebar, object: store) } }.keyboardShortcut("s", modifiers: [.command, .control])
            }.checklistDisabled([(modalActive, "Close the open dialog first."), (store == nil, "Open a Checklist window first.")])
        }
    }
    private func destination(forward: Bool) -> String? {
        guard let store else { return nil }
        let current: String?
        if case .task(let id) = store.detail { current = id } else { current = nil }
        return TicketKeyboardNavigation.destination(in: ticketOrder ?? [], current: current, forward: forward)
    }
    private func navigate(forward: Bool) {
        if let id = destination(forward: forward) { store?.open(.task(id)) }
    }

}
