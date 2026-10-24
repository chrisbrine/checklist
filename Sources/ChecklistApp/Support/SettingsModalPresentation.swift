import AppKit
import SwiftUI

struct SettingsModalActions {
    let present: () -> Void
    let isPresented: Bool
}
private struct SettingsModalActionsKey: FocusedValueKey { typealias Value = SettingsModalActions }
extension FocusedValues {
    var checklistSettings: SettingsModalActions? {
        get { self[SettingsModalActionsKey.self] }
        set { self[SettingsModalActionsKey.self] = newValue }
    }
}
private struct OpenChecklistSettingsKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openChecklistSettings: () -> Void {
        get { self[OpenChecklistSettingsKey.self] }
        set { self[OpenChecklistSettingsKey.self] = newValue }
    }
}

enum SettingsModalLayout {
    static func size(in content: NSSize) -> NSSize {
        guard content.width.isFinite, content.height.isFinite else { return .zero }
        return NSSize(width: max(0, min(1000, content.width - 80)), height: max(0, min(850, content.height - 80)))
    }
}

/// Each ContentView owns one presenter. The weak map only resolves native sheet/menu
/// routing back to that window; it stores no app-wide selection or presentation state.
@MainActor
final class SettingsModalPresentation: ObservableObject {
    @Published private(set) var isPresented = false
    private static let windows = NSMapTable<NSWindow, SettingsModalPresentation>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var anchor: NSView?
    private weak var parent: NSWindow?
    private weak var registeredWindow: NSWindow?
    private var content: (() -> AnyView)?
    private var panel: NSPanel?
    private var monitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private var resizeScheduled = false
    private var generation = 0
    private weak var originResponder: NSResponder?
    private var originAccessibility: AnyObject?
    private let panelFactory: @MainActor () -> NSPanel

    init(panelFactory: @escaping @MainActor () -> NSPanel = { SettingsSheetPanel() }) { self.panelFactory = panelFactory }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }

    static func forWindow(_ window: NSWindow?) -> SettingsModalPresentation? {
        var candidate = window
        for _ in 0..<8 {
            guard let current = candidate else { return nil }
            if let value = windows.object(forKey: current) { return value }
            candidate = current.sheetParent
        }
        return nil
    }
    static func currentWindow() -> SettingsModalPresentation? {
        forWindow(NSApp.keyWindow) ?? forWindow(NSApp.mainWindow)
    }

    func attach(_ view: NSView, content: @escaping () -> AnyView) {
        anchor = view; self.content = content
        if let window = view.window, registeredWindow !== window {
            unregisterWindow()
            registeredWindow = window
            Self.windows.setObject(self, forKey: window)
        }
    }
    func detach(_ view: NSView) {
        guard anchor === view else { return }
        anchor = nil
        unregisterWindow()
    }
    private func unregisterWindow() {
        if let registeredWindow, Self.windows.object(forKey: registeredWindow) === self { Self.windows.removeObject(forKey: registeredWindow) }
        registeredWindow = nil
    }

    func present() {
        guard !isPresented, let window = anchor?.window, window.attachedSheet == nil, NSApp.modalWindow == nil, let content else { return }
        let size = SettingsModalLayout.size(in: window.contentLayoutRect.size)
        guard size.width > 0, size.height > 0 else { return }
        captureOrigin(in: window)
        let panel: NSPanel
        if let cached = self.panel { panel = cached }
        else {
            panel = panelFactory()
            panel.title = "Checklist Settings"
            panel.isReleasedWhenClosed = false; panel.isRestorable = false
            panel.isExcludedFromWindowsMenu = true; panel.hidesOnDeactivate = false
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.contentViewController = NSHostingController(rootView: SettingsModalContents(content: content(), close: { [weak self] in self?.dismiss() }).checklistTextScaleRoot())
            if let sheet = panel as? SettingsSheetPanel { sheet.closeSettings = { [weak self] in self?.dismiss() } }
            self.panel = panel
        }
        panel.appearance = window.appearance
        panel.setContentSize(size)
        parent = window; generation += 1; isPresented = true
        installObservers(for: window)
        window.beginSheet(panel) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEndPresentation() }
        }
    }

    private var childDialogIsActive: Bool {
        panel?.attachedSheet != nil || (NSApp.modalWindow != nil && NSApp.modalWindow !== panel)
    }
    func dismiss() {
        guard isPresented, !childDialogIsActive, let parent, let panel, parent.attachedSheet === panel else { return }
        parent.endSheet(panel, returnCode: .cancel)
    }

    /// Returns nil only for this modal's own dismissing click/Escape. A save/open
    /// dialog and unrelated windows keep their events and native modality.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isPresented, !childDialogIsActive, menuTrackingDepth == 0, let parent, let panel else { return event }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), event.window === parent {
            dismiss(); return nil
        }
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, event.window === panel || event.window === parent {
            dismiss(); return nil
        }
        return event
    }

    private func installObservers(for window: NSWindow) {
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1) } }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated { consumed = self?.handle(event) == nil }
            return consumed ? nil : event
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleResize() }
        }
    }
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard self.isPresented, let parent = self.parent, let panel = self.panel else { return }
            let size = SettingsModalLayout.size(in: parent.contentLayoutRect.size)
            let current = panel.contentRect(forFrameRect: panel.frame).size
            if size.width > 0, size.height > 0, abs(size.width - current.width) > 0.5 || abs(size.height - current.height) > 0.5 { panel.setContentSize(size) }
        }
    }
    private func didEndPresentation() {
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }; resizeObserver = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver); menuObservers = []; menuTrackingDepth = 0
        isPresented = false
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected, !self.isPresented, let parent = self.parent else { return }
            defer { self.originResponder = nil; self.originAccessibility = nil }
            if let view = self.originResponder as? NSView, view.window === parent { parent.makeFirstResponder(view) }
            if let element = self.originAccessibility as? NSAccessibilityProtocol, element.accessibilityWindow() as? NSWindow === parent { element.setAccessibilityFocused(true) }
        }
    }

    private func captureOrigin(in window: NSWindow) {
        let responder = window.firstResponder
        originResponder = (responder as? NSTextView)?.delegate as? NSResponder ?? responder
        var element: NSAccessibilityProtocol?
        if let event = NSApp.currentEvent, event.window === window, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) {
            element = window.accessibilityHitTest(window.convertPoint(toScreen: event.locationInWindow)) as? NSAccessibilityProtocol
        } else { element = NSApp.accessibilityApplicationFocusedUIElement() as? NSAccessibilityProtocol }
        for _ in 0..<16 {
            guard let current = element else { break }
            if let role = current.accessibilityRole(), [.button, .menuItem, .textField, .textArea, .popUpButton].contains(role) {
                originAccessibility = current as AnyObject
                if let responder = current as? NSResponder { originResponder = responder }
                else if let cell = current as? NSCell, let view = cell.controlView { originResponder = view }
                return
            }
            element = current.accessibilityParent() as? NSAccessibilityProtocol
        }
        originAccessibility = nil
    }
}

final class SettingsSheetPanel: NSPanel {
    var closeSettings: (() -> Void)?
    init() { super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false) }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { closeSettings?() }
    override func performClose(_ sender: Any?) { closeSettings?() }
}

private struct SettingsModalContents: View {
    let content: AnyView
    let close: () -> Void
    var body: some View {
        VStack(spacing: Spacing.none) {
            HStack {
                Text("Settings").checklistFont(.sheetHeading)
                Spacer()
                Button(action: close) { Label("Close", systemImage: "xmark").frame(minWidth: 70, minHeight: 30).contentShape(Rectangle()) }
                    .buttonStyle(.checklistBordered).keyboardShortcut(.cancelAction).accessibilityIdentifier("settingsCloseButton")
            }.padding(.horizontal, Spacing.section).padding(.vertical, Spacing.control)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.regularMaterial).focusSection().accessibilityIdentifier("settingsModal")
    }
}

struct SettingsModalAnchor: NSViewRepresentable {
    let presentation: SettingsModalPresentation
    let content: () -> AnyView
    func makeNSView(context: Context) -> SettingsAnchorView {
        let view = SettingsAnchorView(); view.presentation = presentation; view.content = content
        presentation.attach(view, content: content); return view
    }
    func updateNSView(_ view: SettingsAnchorView, context: Context) { view.content = content; presentation.attach(view, content: content) }
    static func dismantleNSView(_ view: SettingsAnchorView, coordinator: ()) { view.presentation?.detach(view) }
}
final class SettingsAnchorView: NSView {
    weak var presentation: SettingsModalPresentation?
    var content: (() -> AnyView)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let content { presentation?.attach(self, content: content) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Keep the invoking workspace mounted while the native sheet is presented.
struct SettingsModalBackground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let isPresented: Bool
    func body(content: Content) -> some View {
        content
            // A conditional disabled-reason wrapper replaces the workspace,
            // detaching its native anchor and canceling its live read tasks.
            .environment(\.isEnabled, isEnabled && !isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented { Color.black.opacity(0.18).ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true) }
            }
    }
}
