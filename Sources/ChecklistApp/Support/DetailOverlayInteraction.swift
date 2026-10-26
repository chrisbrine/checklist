import AppKit
import SwiftUI

/// Observes this window's clicks without taking the event away from its normal target.
@MainActor
final class DetailOverlayInteraction: ObservableObject {
    enum Region { case content, overlay }
    private weak var contentView: NSView?
    private weak var overlayView: NSView?
    private weak var originResponder: NSResponder?
    private var originAccessibility: AnyObject?
    private struct OpeningIdentity {
        let instanceID: UUID
        let itemIdentity: String
    }
    private var openingOrigin: OpeningIdentity?
    private let openingControls = NSHashTable<DetailOverlayOpeningControlView>.weakObjects()
    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private var presented = false
    private var generation = 0
    private var pendingRestore: Int?
    private var isPresented: () -> Bool = { false }
    private var currentItem: () -> String? = { nil }
    private var dismiss: () -> Void = {}
    private let frameAutosaveName: NSWindow.FrameAutosaveName?
    private weak var configuredWindow: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    private var frameGeneration = 0

    init(frameAutosaveName: NSWindow.FrameAutosaveName? = nil) { self.frameAutosaveName = frameAutosaveName }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(_ view: NSView, region: Region) {
        switch region {
        case .content:
            contentView = view
            configureWindowIfNeeded(view.window)
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                    var routed: NSEvent? = event
                    MainActor.assumeIsolated { if let self { routed = self.route(event) } }
                    return routed
                }
            }
            if menuObservers.isEmpty {
                menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
                })
                menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1) } }
                })
            }
        case .overlay: overlayView = view
        }
    }

    private func configureWindowIfNeeded(_ window: NSWindow?) {
        guard let window, let name = frameAutosaveName, configuredWindow !== window else { return }
        frameObservers.forEach(NotificationCenter.default.removeObserver); frameObservers = []
        configuredWindow = window
        frameGeneration += 1
        let expected = frameGeneration
        // One native restore after attachment, never a frame write during layout.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.frameGeneration == expected, self.contentView?.window === window else { return }
            if window.frameAutosaveName.isEmpty { _ = window.setFrameAutosaveName(name) }
            // SwiftUI's singleton Window already owns a native autosave name.
            // Restore our stable workspace key without replacing that ownership.
            _ = window.setFrameUsingName(name)
            let center = NotificationCenter.default
            for event in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                self.frameObservers.append(center.addObserver(forName: event, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.configuredWindow === window else { return }
                        window.saveFrame(usingName: name)
                    }
                })
            }
            self.frameObservers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.configuredWindow === window else { return }
                    window.saveFrame(usingName: name)
                }
            })
        }
    }

    func detach(_ view: NSView, region: Region) {
        switch region {
        case .content where contentView === view:
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; contentView = nil
            frameObservers.forEach(NotificationCenter.default.removeObserver); frameObservers = []
            configuredWindow = nil; frameGeneration += 1
            menuObservers.forEach(NotificationCenter.default.removeObserver); menuObservers = []; menuTrackingDepth = 0
            generation += 1
            originResponder = nil; originAccessibility = nil; openingOrigin = nil
        case .overlay where overlayView === view:
            overlayView = nil
            if let expected = pendingRestore { pendingRestore = nil; scheduleRestore(expected: expected) }
        default: break
        }
    }

    func update(presented: Bool, isPresented: @escaping () -> Bool, currentItem: @escaping () -> String? = { nil }, dismiss: @escaping () -> Void) {
        self.isPresented = isPresented
        self.currentItem = currentItem
        self.dismiss = dismiss
        presentationChanged(presented)
    }

    /// The first Escape leaves an editor without destroying its detail or draft.
    func leaveEditorBeforeDismiss() -> Bool {
        guard isPresented(), let window = contentView?.window, let overlayView, overlayView.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isEditable else { return false }
        let field = (editor.delegate as? NSView) ?? editor
        let visible = field.convert(field.visibleRect.intersection(field.bounds), to: nil)
        guard !visible.isEmpty, overlayView.convert(overlayView.bounds, to: nil).contains(NSPoint(x: visible.midX, y: visible.midY)) else { return false }
        // A validation refusal also keeps the detail open, preserving the editor.
        _ = window.makeFirstResponder(nil)
        return true
    }

    private func presentationChanged(_ value: Bool) {
        guard value != presented else { return }
        presented = value; generation += 1
        if value {
            if openingOrigin == nil, originResponder == nil, let window = contentView?.window { captureOrigin(in: window, at: nil) }
        } else { restoreFocus() }
    }

    /// Keep Escape reachable after the first Escape moves focus from an editor to
    /// the NSWindow. SwiftUI's focused onExitCommand no longer owns that route.
    /// Only this presented overlay's unmodified Escape is consumed.
    func route(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              let window = contentView?.window, event.window === window,
              isPresented(), overlayView?.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil, menuTrackingDepth == 0 else { return handle(event) }
        if event.isARepeat { return nil }
        if !leaveEditorBeforeDismiss() { dismiss(); presentationChanged(false) }
        return nil
    }

    /// Internal so the isolated native fixture can exercise the actual event boundary.
    func handle(_ event: NSEvent) -> NSEvent {
        guard let window = contentView?.window, event.window === window else { return event }
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        guard isPresented() else {
            captureOrigin(in: window, at: event.type == .keyDown ? nil : event.locationInWindow)
            return event
        }
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let overlayView, overlayView.window === window,
              !overlayView.convert(overlayView.bounds, to: nil).contains(event.locationInWindow) else { return event }

        // App-owned SwiftUI rows are explicitly registered. Never dismiss before
        // their Button action: Store.open must see the prior detail and history.
        if !openingControls(at: event.locationInWindow, in: window).isEmpty { return event }

        // Ordinary controls/native fields retain the existing accessibility route.
        if interactiveElement(in: window, at: event.locationInWindow) != nil {
            let before = currentItem(), expected = generation
            let candidate = focusOrigin(in: window, at: event.locationInWindow)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, window != nil, self.generation == expected, self.isPresented(), self.currentItem() != before else { return }
                self.openingOrigin = nil
                (self.originResponder, self.originAccessibility) = candidate
            }
            return event
        }
        dismiss()
        presentationChanged(false)
        return event
    }

    func attachOpeningControl(_ view: DetailOverlayOpeningControlView) { openingControls.add(view) }
    func detachOpeningControl(_ view: DetailOverlayOpeningControlView) { openingControls.remove(view) }

    /// Called by the actual opening action, for pointer and keyboard activation.
    /// Identity belongs to one rendered control, not every row for the same task.
    func openingControlActivated(instanceID: UUID, itemIdentity: String) {
        guard let window = contentView?.window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let candidates = eligibleOpeningControls(in: window).filter { $0.instanceID == instanceID && $0.itemIdentity == itemIdentity }
        guard candidates.count == 1, let control = candidates.first else { return }
        captureOpeningControl(control)
    }

    private func openingFrame(_ control: DetailOverlayOpeningControlView, in window: NSWindow) -> NSRect? {
        guard let frame = control.visibleFrame(in: window), let contentView else { return nil }
        let content = contentView.convert(contentView.visibleRect.intersection(contentView.bounds), to: nil)
        let clipped = frame.intersection(content)
        guard !clipped.isEmpty else { return nil }
        // Pointer lookup checks the actual exposed point; the row center may
        // be covered by the detail while its left portion is still usable.
        if let overlayView, overlayView.window === window,
           overlayView.convert(overlayView.visibleRect.intersection(overlayView.bounds), to: nil).contains(clipped) { return nil }
        return clipped
    }
    private func eligibleOpeningControls(in window: NSWindow) -> [DetailOverlayOpeningControlView] {
        openingControls.allObjects.filter { openingFrame($0, in: window) != nil }
    }
    private func openingControls(at point: NSPoint, in window: NSWindow) -> [DetailOverlayOpeningControlView] {
        if let overlayView, overlayView.window === window,
           overlayView.convert(overlayView.bounds, to: nil).contains(point) { return [] }
        return eligibleOpeningControls(in: window).filter { openingFrame($0, in: window)?.contains(point) == true && $0.isExposed(at: point, in: window) }
    }
    private func captureOpeningControl(_ control: DetailOverlayOpeningControlView) {
        openingOrigin = OpeningIdentity(instanceID: control.instanceID, itemIdentity: control.itemIdentity)
        originResponder = nil; originAccessibility = nil
    }
    private func captureOrigin(in window: NSWindow, at point: NSPoint?) {
        // A keyboard opening from a focused row: the first responder is only the hosting view.
        if point == nil {
            let focused = eligibleOpeningControls(in: window).filter(\.keyboardFocused)
            if focused.count == 1, let control = focused.first { captureOpeningControl(control); return }
        }
        if let point {
            let candidates = openingControls(at: point, in: window)
            if candidates.count == 1, let control = candidates.first { captureOpeningControl(control); return }
            if !candidates.isEmpty {
                openingOrigin = nil; originResponder = nil; originAccessibility = nil
                return // The subsequent actual Button action records its own unique origin.
            }
        }
        openingOrigin = nil
        (originResponder, originAccessibility) = focusOrigin(in: window, at: point)
    }

    private func focusOrigin(in window: NSWindow, at point: NSPoint?) -> (NSResponder?, AnyObject?) {
        let responder = window.firstResponder
        var target = (responder as? NSTextView)?.delegate as? NSResponder ?? responder
        if let point {
            let element = interactiveElement(in: window, at: point)
            if let responder = element as? NSResponder { target = responder }
            else if let cell = element as? NSCell, let control = cell.controlView { target = control }
            return (target, element as AnyObject?)
        }
        return (target, NSApp.accessibilityApplicationFocusedUIElement() as AnyObject?)
    }

    private func interactiveElement(in window: NSWindow, at point: NSPoint) -> NSAccessibilityProtocol? {
        var element = window.accessibilityHitTest(window.convertPoint(toScreen: point)) as? NSAccessibilityProtocol
        let controls: Set<NSAccessibility.Role> = [.button, .radioButton, .checkBox, .textField, .textArea, .popUpButton, .menuButton, .comboBox, .slider, .incrementor, .disclosureTriangle, .link, .scrollBar, .tabGroup]
        // SwiftUI may hit a button's text child; walk only its bounded local ancestry.
        for _ in 0..<16 {
            guard let current = element else { return nil }
            if let role = current.accessibilityRole(), controls.contains(role) { return current }
            element = current.accessibilityParent() as? NSAccessibilityProtocol
        }
        return nil
    }

    private func restoreFocus() { scheduleRestore(expected: generation) }

    private func scheduleRestore(expected: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected, !self.isPresented(), let window = self.contentView?.window else { return }
            // The closing detail still covers its opening row during the exit
            // transition; restore that row after the detail leaves the window.
            if self.openingOrigin != nil, let overlayView = self.overlayView, overlayView.window === window {
                self.pendingRestore = expected
                return
            }
            defer { self.originResponder = nil; self.originAccessibility = nil; self.openingOrigin = nil }
            if let origin = self.openingOrigin {
                let candidates = self.eligibleOpeningControls(in: window).filter { $0.instanceID == origin.instanceID && $0.itemIdentity == origin.itemIdentity }
                // Restoration has no pointer point: keep native-cover safety
                // here without excluding a usable row during pointer lookup.
                if candidates.count == 1, let control = candidates.first,
                   let frame = self.openingFrame(control, in: window),
                   control.isExposed(at: NSPoint(x: frame.midX, y: frame.midY), in: window) {
                    control.restoreOpeningFocus?()
                }
                return // A removed/recycled row never falls back to an unrelated Search field.
            }
            if let view = self.originResponder as? NSView, view.window === window { window.makeFirstResponder(view) }
            else if let responder = self.originResponder, responder === window { window.makeFirstResponder(responder) }
            if let element = self.originAccessibility as? NSAccessibilityProtocol,
               element.accessibilityWindow() as? NSWindow === window { element.setAccessibilityFocused(true) }
        }
    }
}

struct DetailOverlayInteractionRegion: NSViewRepresentable {
    let interaction: DetailOverlayInteraction
    let region: DetailOverlayInteraction.Region
    var presented = false
    var isPresented: () -> Bool = { false }
    var currentItem: () -> String? = { nil }
    var dismiss: () -> Void = {}

    func makeNSView(context: Context) -> InteractionRegionView {
        let view = InteractionRegionView()
        view.interaction = interaction; view.region = region
        interaction.attach(view, region: region)
        return view
    }
    func updateNSView(_ view: InteractionRegionView, context: Context) {
        interaction.attach(view, region: region)
        if region == .content { interaction.update(presented: presented, isPresented: isPresented, currentItem: currentItem, dismiss: dismiss) }
    }
    static func dismantleNSView(_ view: InteractionRegionView, coordinator: ()) { view.interaction?.detach(view, region: view.region) }
}

final class InteractionRegionView: NSView {
    weak var interaction: DetailOverlayInteraction?
    var region: DetailOverlayInteraction.Region = .content
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A removed detail leaves the window before SwiftUI dismantles it.
        if window == nil, region == .overlay { interaction?.detach(self, region: region) }
        else { interaction?.attach(self, region: region) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
