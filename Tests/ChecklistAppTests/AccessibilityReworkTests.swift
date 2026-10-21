import XCTest
import SwiftUI
@testable import ChecklistApp

final class AccessibilityReworkTests: XCTestCase {
    func testComposerMovesIntoDocumentOnlyAboveReflowThreshold() {
        for scale in [0.85, 1, 1.15, 1.3] { XCTAssertFalse(TextScale.usesInlineComposer(at: scale)) }
        for scale in [Double(1.3).nextUp, 1.5, 1.75, 2] { XCTAssertTrue(TextScale.usesInlineComposer(at: scale)) }
    }
    func testNativeControlsUseSmallerTextRolesForCompactSizes() {
        XCTAssertEqual(ControlTextRole.role(for: .mini).size, TextRole.caption.size)
        XCTAssertEqual(ControlTextRole.role(for: .small).size, TextRole.callout.size)
        XCTAssertEqual(ControlTextRole.role(for: .regular).size, TextRole.body.size)
        XCTAssertEqual(ControlTextRole.role(for: .large).size, TextRole.body.size)
        XCTAssertLessThan(ControlTextRole.role(for: .mini).size, ControlTextRole.role(for: .small).size)
        XCTAssertLessThan(ControlTextRole.role(for: .small).size, ControlTextRole.role(for: .regular).size)
    }
    @MainActor func testOverlayFocusAnchorAcceptsFocusWithoutTakingClicks() {
        let view = OverlayFocusView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.update(item: "ticket:a", label: "Ticket details")
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)))
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.accessibilityLabel(), "Ticket details")
        view.update(item: "request:b", label: "Request details")
        XCTAssertEqual(view.accessibilityLabel(), "Request details")
    }

    /// A late SwiftUI click focus lands on the host that contains the panel; a field keeps its focus.
    @MainActor func testOverlayFocusAnchorReclaimsLateHostFocusOnly() throws {
        let app = NSApplication.shared // the panel reads NSApp
        try XCTSkipIf(app.isFullKeyboardAccessEnabled, "The panel anchor is the keyboard-navigation-off route")
        final class Host: NSView { override var acceptsFirstResponder: Bool { true } }
        func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func drainInitialFocus() {
            // requestFocus queues its initial change on the main queue. Wait
            // for that queue turn, rather than assume it ran within 50 ms.
            let drained = expectation(description: "Initial panel focus queue turn")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
        let window = NSWindow(contentRect: NSRect(x: -9000, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let host = Host(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); window.contentView = host
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24)); host.addSubview(field)
        let anchor = OverlayFocusView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        anchor.update(item: "ticket:a", label: "Ticket details")
        host.addSubview(anchor); drainInitialFocus()
        XCTAssertTrue(window.firstResponder === anchor, "The panel takes focus when it appears")
        window.makeFirstResponder(host); settle(0.35)
        XCTAssertTrue(window.firstResponder === anchor, "A late host focus returns to the panel")

        anchor.removeFromSuperview(); anchor.update(item: "ticket:b", label: "Ticket details")
        let second = OverlayFocusView(frame: anchor.frame); second.update(item: "ticket:c", label: "Ticket details")
        host.addSubview(second); drainInitialFocus()
        window.makeFirstResponder(field); settle(0.8)
        XCTAssertFalse(window.firstResponder === second, "A field the user chose keeps its focus")
        window.orderOut(nil)
    }
}
