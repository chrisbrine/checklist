import SwiftUI
import AppKit
import Carbon.HIToolbox

/// CL-65: an owner-chosen global shortcut. Carbon hot keys need no Accessibility permission;
/// they only receive the exact registered key combination.
struct QuickCaptureShortcut: Codable, Equatable {
    static let key = "quickCaptureShortcut"
    static let enabledKey = "quickCaptureShortcutEnabled"
    /// Control-Option-Command-N: no system or Checklist command uses it.
    static let standard = QuickCaptureShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "N")
    let keyCode: UInt32
    /// Carbon modifier bits (cmdKey, optionKey, controlKey, shiftKey).
    let modifiers: UInt32
    let keyLabel: String

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        return bits
    }
    /// A global shortcut needs Command, Control or Option, so ordinary typing in other apps is never taken.
    static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> QuickCaptureShortcut? {
        let bits = carbonModifiers(flags)
        guard bits & UInt32(cmdKey | controlKey | optionKey) != 0, let label = characters?.uppercased(), !label.trimmingCharacters(in: .whitespaces).isEmpty,
              ![UInt16(kVK_Escape), UInt16(kVK_Return), UInt16(kVK_Tab), UInt16(kVK_Delete)].contains(keyCode) else { return nil }
        return QuickCaptureShortcut(keyCode: UInt32(keyCode), modifiers: bits, keyLabel: label)
    }
    static func load(_ defaults: UserDefaults = .standard) -> QuickCaptureShortcut? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(QuickCaptureShortcut.self, from: $0) } ?? standard
    }
    static func save(_ shortcut: QuickCaptureShortcut?, _ defaults: UserDefaults = .standard) {
        defaults.set(shortcut != nil, forKey: enabledKey)
        if let shortcut { defaults.set(try? JSONEncoder().encode(shortcut), forKey: key) }
    }
}

@MainActor
private final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init?(_ shortcut: QuickCaptureShortcut, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let target = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { target.action() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x434B_4C54), id: 1)
        guard installed == noErr,
              RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}

/// Handle panel commands before the hosting view or its field editor consumes them. A
/// nonactivating panel can receive typing without activating SwiftUI's app/menu shortcuts.
@MainActor
final class QuickCapturePanel: NSPanel {
    var submitDraft: () -> Void = {}
    var closeCapture: () -> Void = {}

    override var canBecomeKey: Bool { true }

    @discardableResult
    func handleCaptureKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let submit = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(event.keyCode) && modifiers == .command
        let close = event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty
        guard submit || close else { return false }
        // Consume repeats without creating another ticket or closing another window.
        if !event.isARepeat {
            if submit { submitDraft() } else { closeCapture() }
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCaptureKey(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if !handleCaptureKey(event) { super.sendEvent(event) }
    }
}

/// The quick-capture panel. It floats above other apps and does not need the main window.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = QuickCaptureController()
    let model: QuickCaptureModel
    private let pasteboard: NSPasteboard
    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?
    private(set) var statusItem: NSStatusItem?
    /// Captured by a workspace view and retained after its window closes.
    var openMainWindow: (() -> Void)?
    private(set) var shortcutProblem: String?

    init(model: QuickCaptureModel? = nil, pasteboard: NSPasteboard = .general) {
        self.model = model ?? QuickCaptureModel()
        self.pasteboard = pasteboard
        super.init()
    }

    /// AppKit owns the menu bar item independently of SwiftUI's app scene graph.
    func updateMenuBarItem(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: QuickCaptureSettings.menuBarKey) as? Bool ?? true else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for (title, action): (String, Selector?) in [
            ("New Ticket…", #selector(newTicket)),
            ("New Ticket from Clipboard Image", #selector(newTicketFromClipboard)),
            ("", nil),
            ("Open Checklist", #selector(openChecklist)),
            ("", nil),
            ("Quit Checklist", #selector(quitChecklist))
        ] {
            if let action {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            } else { menu.addItem(.separator()) }
        }
        menuNeedsUpdate(menu)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Checklist")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Checklist")
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 1)?.isEnabled = QuickCaptureModel.clipboardHasImage(pasteboard)
    }

    @objc private func newTicket() { show() }
    @objc private func newTicketFromClipboard() { show(clipboardImage: true) }
    @objc private func quitChecklist() { NSApp.terminate(nil) }

    @objc func openChecklist() {
        NSApp.activate(ignoringOtherApps: true)
        if !DesktopAlertWindows.shared.hasWindow { openMainWindow?() }
    }

    func registerShortcut(_ defaults: UserDefaults = .standard) {
        hotKey?.unregister(); hotKey = nil; shortcutProblem = nil
        guard let shortcut = QuickCaptureShortcut.load(defaults) else { return }
        hotKey = GlobalHotKey(shortcut) { [weak self] in self?.show() }
        if hotKey == nil { shortcutProblem = "\(shortcut.display) is already used by another app. Choose another shortcut." }
    }

    func show(files: [URL] = [], clipboardImage: Bool = false) {
        if case .captured = model.state { model.startAnother() }
        if !files.isEmpty { model.attach(files) }
        if clipboardImage { model.attachClipboardImage(pasteboard) }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Task { await model.loadProjects() }
    }
    func close() { panel?.orderOut(nil) }

    func submitDraft() {
        guard model.canSend else { return }
        Task { await model.send() }
    }

    /// Opens the captured ticket in the most recent Checklist window, or a new main window.
    func openTicket(_ taskID: String) {
        close()
        DesktopAlertWindows.shared.openOrWait(.task(taskID))
        openChecklist()
    }

    private func makePanel() -> NSPanel {
        let panel = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "New Ticket"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("ChecklistQuickCapture")
        panel.delegate = self
        panel.submitDraft = { [weak self] in self?.submitDraft() }
        panel.closeCapture = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: QuickCaptureView(model: model, close: panel.closeCapture, submitDraft: panel.submitDraft, openTicket: { [weak self] in self?.openTicket($0) })
            .checklistTextScaleRoot().tint(.checklistAccentText))
        return panel
    }
}
