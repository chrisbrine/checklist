// Compile: bash scripts/compile-component.sh --scratch-path "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}" check-settings-modal
// Run: "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}/check-settings-modal"
// Hidden native AppKit lifecycle fixture: never activates, orders, or attaches a real sheet.
// Installed menu, visual layout, accessibility traversal, and file-dialog checks remain independent review work.
import AppKit
import SwiftUI

@MainActor
final class SettingsParentFixture: NSWindow {
    var fixtureSheet: NSWindow?
    var completions: [(NSApplication.ModalResponse) -> Void] = []
    var beginCount = 0
    var endCount = 0
    override var attachedSheet: NSWindow? { fixtureSheet }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        beginCount += 1; fixtureSheet = sheetWindow
        if let sheet = sheetWindow as? SettingsPanelFixture { sheet.fixtureParent = self }
        if let handler { completions.append(handler) }
    }
    override func endSheet(_ sheetWindow: NSWindow, returnCode: NSApplication.ModalResponse) {
        guard fixtureSheet === sheetWindow else { return }
        endCount += 1; fixtureSheet = nil
        if let sheet = sheetWindow as? SettingsPanelFixture { sheet.fixtureParent = nil }
        let handler = completions.removeFirst(); handler(returnCode)
    }
}
@MainActor
final class SettingsPanelFixture: NSPanel {
    weak var fixtureParent: NSWindow?
    var fixtureChild: NSWindow?
    var sizes: [NSSize] = []
    override var sheetParent: NSWindow? { fixtureParent }
    override var attachedSheet: NSWindow? { fixtureChild }
    override var canBecomeKey: Bool { true }
    override func setContentSize(_ size: NSSize) { sizes.append(size); super.setContentSize(size) }
}
@MainActor
final class SettingsFocusFixture: NSButton { override var acceptsFirstResponder: Bool { true } }

@main
struct SettingsModalChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checked += 1
        }
        func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }
        func parent() -> SettingsParentFixture {
            let value = SettingsParentFixture(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            value.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
            return value
        }
        func mouse(in target: NSWindow, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func escape(in target: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }
        check(SettingsModalLayout.size(in: NSSize(width: 900, height: 650)) == NSSize(width: 820, height: 570), "Minimum content leaves a 40-point scrim on each side")
        check(SettingsModalLayout.size(in: NSSize(width: 1100, height: 740)) == NSSize(width: 1000, height: 660), "Larger content uses the bounded modal size")
        check(SettingsModalLayout.size(in: NSSize(width: 3000, height: 2000)) == NSSize(width: 1000, height: 850), "Large windows keep a usable maximum settings size")
        check(SettingsModalLayout.size(in: NSSize(width: 20, height: 20)) == .zero && SettingsModalLayout.size(in: NSSize(width: CGFloat.infinity, height: 650)) == .zero, "Tiny and invalid layout cannot create a negative or infinite frame")
        let window = parent(), other = parent()
        let opener = SettingsFocusFixture(title: "Settings", target: nil, action: nil)
        opener.frame = NSRect(x: 10, y: 10, width: 100, height: 30); window.contentView!.addSubview(opener)
        let otherFocus = SettingsFocusFixture(title: "Other", target: nil, action: nil)
        otherFocus.frame = NSRect(x: 10, y: 50, width: 100, height: 30); window.contentView!.addSubview(otherFocus)
        let anchor = NSView(frame: .zero); window.contentView!.addSubview(anchor)
        let detailRegion = NSView(frame: NSRect(x: 500, y: 0, width: 400, height: 650)); window.contentView!.addSubview(detailRegion)
        let details = DetailOverlayInteraction(); var detailDismissals = 0
        details.attach(window.contentView!, region: .content); details.attach(detailRegion, region: .overlay)
        details.update(presented: true, isPresented: { true }, currentItem: { "retained-ticket" }, dismiss: { detailDismissals += 1 })
        let panel = SettingsPanelFixture(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var factoryCalls = 0, contentCalls = 0
        let presentation = SettingsModalPresentation(panelFactory: { factoryCalls += 1; return panel })
        presentation.attach(anchor, content: { contentCalls += 1; return AnyView(Text("Retained settings section")) })
        check(SettingsModalPresentation.forWindow(window) === presentation && SettingsModalPresentation.forWindow(other) == nil, "Presenter routing is local to its attached parent")
        window.makeFirstResponder(opener)
        presentation.present(); presentation.present()
        let hosted = panel.contentViewController
        check(presentation.isPresented && window.beginCount == 1 && factoryCalls == 1 && contentCalls == 1, "One presentation creates exactly one attached content host")
        check(SettingsModalPresentation.forWindow(panel) === presentation, "Menu routing from the attached sheet resolves its parent presenter")
        check(!window.isVisible && !panel.isVisible && !other.isVisible, "Fixture remains hidden and never activates a user window")
        let inside = mouse(in: panel)
        check(presentation.handle(inside) === inside && presentation.isPresented, "Settings content clicks are unchanged")
        let unrelated = mouse(in: other)
        check(presentation.handle(unrelated) === unrelated && presentation.isPresented, "Other windows keep their events")
        let moved = mouse(in: window, type: .mouseMoved)
        check(presentation.handle(moved) === moved && presentation.isPresented, "Mouse motion cannot dismiss Settings")
        let modified = escape(in: panel, modifiers: .command)
        check(presentation.handle(modified) === modified && presentation.isPresented, "Modified Escape remains a separate shortcut")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        let menuEscape = escape(in: panel)
        check(presentation.handle(menuEscape) === menuEscape && presentation.isPresented, "Escape remains owned by an open menu")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        window.makeFirstResponder(otherFocus)
        let outside = mouse(in: window)
        check(details.handle(outside) === outside && detailDismissals == 0, "An earlier ticket monitor ignores the Settings scrim click before any ticket dismissal")
        let underlyingEscape = escape(in: window)
        check(details.route(underlyingEscape) === underlyingEscape && detailDismissals == 0, "An earlier ticket monitor leaves Settings Escape ownership unchanged")
        check(presentation.handle(outside) == nil && !presentation.isPresented && window.endCount == 1, "Outside parent click closes and is consumed before any background action")
        await settle()
        check(window.firstResponder === opener, "Dismissal restores the parent opening responder")
        presentation.present()
        check(panel.contentViewController === hosted && factoryCalls == 1 && contentCalls == 1, "Reopening retains the same SwiftUI content host and section state")
        let child = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        panel.fixtureChild = child
        let duringChild = mouse(in: window)
        check(presentation.handle(duringChild) === duringChild, "A child file dialog retains native event ownership")
        presentation.dismiss()
        check(presentation.isPresented && window.endCount == 1, "Close does not tear down Settings while a child dialog is active")
        let childEscape = escape(in: panel)
        check(presentation.handle(childEscape) === childEscape && presentation.isPresented, "Escape does not close Settings behind a child dialog")
        panel.fixtureChild = nil
        let key = escape(in: panel)
        check(presentation.handle(key) == nil && !presentation.isPresented && window.endCount == 2, "Unmodified Escape closes the Settings sheet and is consumed")
        await settle()
        let foreign = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.fixtureSheet = foreign; presentation.present()
        check(!presentation.isPresented && window.beginCount == 2, "An existing unrelated native sheet is never replaced")
        window.fixtureSheet = nil
        presentation.present()
        let beforeResize = panel.sizes.count
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        await settle()
        check(panel.sizes.count == beforeResize, "Unchanged repeated resize observations do not write a new panel frame")
        window.setContentSize(NSSize(width: 1100, height: 740))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        await settle()
        check(panel.sizes.last == NSSize(width: 1000, height: 660), "Parent resize updates only the bounded sheet size")
        presentation.dismiss(); await settle()
        let panelClose = SettingsSheetPanel(); var closeCount = 0
        panelClose.closeSettings = { closeCount += 1 }
        panelClose.cancelOperation(nil); panelClose.performClose(nil)
        check(closeCount == 2 && panelClose.canBecomeKey && !panelClose.canBecomeMain, "Native Escape/Close responders route to the same dismissal")
        details.detach(window.contentView!, region: .content); details.detach(detailRegion, region: .overlay)
        presentation.detach(anchor)
        check(SettingsModalPresentation.forWindow(window) == nil, "Detaching releases parent routing ownership")
        presentation.present()
        check(!presentation.isPresented, "A detached presenter cannot open a stale Settings sheet")
        check(!window.isVisible && !panel.isVisible && !other.isVisible && !child.isVisible && !foreign.isVisible && !panelClose.isVisible, "All native fixtures remain hidden at completion")
        print("\(checked) hidden Settings modal checks passed")
    }
}
