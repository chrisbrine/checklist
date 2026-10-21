// Compile: xcrun swiftc -swift-version 5 -parse-as-library Sources/ChecklistApp/Support/DetailOverlayInteraction.swift Sources/ChecklistApp/Support/DetailOverlayOpeningControl.swift scripts/check-overlay-interactions.swift -o /tmp/checklist-overlay-interactions
// Runs an isolated offscreen AppKit fixture. No Checklist service, settings or user window changes.
import AppKit
import SwiftUI

@MainActor
final class FixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AutosaveSpyWindow: NSWindow {
    var savedNames: [String] = []
    var restoredNames: [String] = []
    var existingName = ""
    override var frameAutosaveName: NSWindow.FrameAutosaveName { existingName }
    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { savedNames.append(name); return true }
    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool { restoredNames.append(name); return true }
}

@MainActor
final class FocusButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class ClickCounter: NSObject {
    var count = 0
    @objc func clicked(_ sender: Any?) { count += 1 }
}

var overlayChecksFinished = false

@main
struct OverlayInteractionChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared
        // An early drain exit must fail, never look like a pass.
        atexit { if !overlayChecksFinished { FileHandle.standardError.write(Data("Overlay interaction checks ended early\n".utf8)); _exit(1) } }
        app.setActivationPolicy(.accessory)
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checked += 1
        }
        func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }
        let window = FixtureWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        window.contentView = content
        let contentRegion = InteractionRegionView(frame: content.bounds)
        content.addSubview(contentRegion)
        let overlayRegion = InteractionRegionView(frame: NSRect(x: 500, y: 0, width: 400, height: 650))
        content.addSubview(overlayRegion)
        let opener = FocusButton(title: "Open details", target: nil, action: nil)
        opener.frame = NSRect(x: 100, y: 100, width: 150, height: 30); content.addSubview(opener)
        let editor = NSTextField(frame: NSRect(x: 600, y: 100, width: 160, height: 30)); content.addSubview(editor)
        let outsideField = NSTextField(frame: NSRect(x: 100, y: 200, width: 160, height: 30)); content.addSubview(outsideField)
        let counter = ClickCounter()
        let outsideButton = FocusButton(title: "Another ticket", target: counter, action: #selector(ClickCounter.clicked(_:)))
        outsideButton.frame = NSRect(x: 100, y: 300, width: 150, height: 30); content.addSubview(outsideButton)
        window.orderFront(nil)
        let interaction = DetailOverlayInteraction()
        interaction.attach(contentRegion, region: .content)
        interaction.attach(overlayRegion, region: .overlay)
        var item = "first"
        var presented = false
        var dismissals = 0
        func update() { interaction.update(presented: presented, isPresented: { presented }, currentItem: { presented ? item : nil }, dismiss: { presented = false; dismissals += 1 }) }
        func mouse(_ point: NSPoint, in target: NSWindow? = nil, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (target ?? window).windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func open() {
            presented = false; update(); item = "first"
            window.makeFirstResponder(opener)
            _ = interaction.handle(mouse(NSPoint(x: 150, y: 115)))
            presented = true; update()
            window.makeFirstResponder(editor)
        }
        update(); open()
        check(interaction.leaveEditorBeforeDismiss() && presented, "First Escape leaves an editable overlay responder without dismissing details")
        check(!interaction.leaveEditorBeforeDismiss() && presented, "A second Escape can follow normal detail dismissal")
        window.makeFirstResponder(editor)
        let inside = mouse(NSPoint(x: 650, y: 115))
        check(interaction.handle(inside) === inside && presented && dismissals == 0, "Overlay clicks remain untouched")
        let moved = mouse(NSPoint(x: 20, y: 20), type: .mouseMoved)
        check(interaction.handle(moved) === moved && presented, "Non-click events cannot dismiss details")
        let other = FixtureWindow(contentRect: NSRect(x: -6000, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.orderFront(nil)
        let otherEvent = mouse(NSPoint(x: 20, y: 20), in: other)
        check(interaction.handle(otherEvent) === otherEvent && presented, "Other windows cannot dismiss this overlay")
        let empty = mouse(NSPoint(x: 20, y: 20))
        check(interaction.handle(empty) === empty && !presented && dismissals == 1, "Empty outside click dismisses once without consuming the event")
        await settle()
        check(window.firstResponder === opener, "Empty outside click restores the opening control")
        open()
        let fieldClick = mouse(NSPoint(x: 150, y: 215))
        check(interaction.handle(fieldClick) === fieldClick && presented, "Outside field receives its original click")
        window.makeFirstResponder(outsideField); await settle()
        check((window.firstResponder as? NSTextView)?.delegate as? NSTextField === outsideField, "Dismissal does not steal focus from the clicked field")
        presented = true; update()
        window.makeFirstResponder(outsideField)
        check(!interaction.leaveEditorBeforeDismiss(), "The overlay does not resign a field in the underlying content")
        presented = false; update(); await settle()
        open()
        let rowClick = mouse(NSPoint(x: 150, y: 315))
        check(interaction.handle(rowClick) === rowClick && presented, "Another ticket keeps its original click and existing detail until its own action")
        // performClick runs a nested event loop that can stop the async main drain early.
        outsideButton.sendAction(outsideButton.action, to: outsideButton.target)
        check(counter.count == 1, "The underlying control can perform its normal action")
        item = "second"; presented = true; update(); window.makeFirstResponder(editor); await settle()
        check(presented, "A new ticket opened by the same click is not closed by delayed restoration")
        presented = false; update(); await settle()
        check(window.firstResponder === outsideButton, "Closing the new ticket restores its own opening control")
        open(); presented = false; update(); await settle()
        check(window.firstResponder === opener, "Explicit Close or Escape state changes restore origin")
        // A ticket row whose center lies under the closing detail, with a native view in that detail.
        let row = DetailOverlayOpeningControlView(frame: NSRect(x: 300, y: 400, width: 500, height: 40))
        var rowRestores = 0
        row.interaction = interaction; row.itemIdentity = "row"; row.restoreOpeningFocus = { rowRestores += 1 }
        content.addSubview(row, positioned: .below, relativeTo: overlayRegion)
        let cover = FocusButton(title: "Detail control", target: nil, action: nil); cover.frame = NSRect(x: 500, y: 380, width: 400, height: 80); content.addSubview(cover)
        overlayRegion.interaction = interaction; overlayRegion.region = .overlay
        func openRow() {
            presented = false; update(); item = "row"
            interaction.openingControlActivated(instanceID: row.instanceID, itemIdentity: "row")
            presented = true; update()
        }
        openRow(); presented = false; update(); await settle()
        check(rowRestores == 0, "Row restoration waits while the closing detail still covers the row")
        cover.removeFromSuperview(); overlayRegion.removeFromSuperview(); await settle()
        check(rowRestores == 1, "The row regains focus after the closing detail leaves the window")
        content.addSubview(overlayRegion); content.addSubview(cover)
        openRow(); presented = false; update(); await settle()
        presented = true; update()
        cover.removeFromSuperview(); overlayRegion.removeFromSuperview(); await settle()
        check(rowRestores == 1, "A detail reopened before the exit ends cancels the earlier row restoration")
        content.addSubview(overlayRegion); presented = false; update(); await settle()
        overlayRegion.removeFromSuperview(); await settle()
        // A keyboard opening while the row holds SwiftUI focus; the window's first responder is another view.
        let restoresBefore = rowRestores
        content.addSubview(overlayRegion)
        window.makeFirstResponder(opener); row.keyboardFocused = true
        let nextTicket = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        _ = interaction.handle(nextTicket)
        row.keyboardFocused = false; item = "keyboard"; presented = true; update()
        presented = false; update(); await settle()
        overlayRegion.removeFromSuperview(); await settle()
        check(rowRestores == restoresBefore + 1, "A keyboard opening from a focused row returns focus to that row")
        content.addSubview(overlayRegion); row.removeFromSuperview()
        open(); contentRegion.removeFromSuperview(); interaction.detach(contentRegion, region: .content)
        let detached = mouse(NSPoint(x: 20, y: 20))
        check(interaction.handle(detached) === detached && presented, "A detached window bridge has no remaining dismissal authority")
        interaction.detach(overlayRegion, region: .overlay)
        let autosaveWindow = AutosaveSpyWindow(contentRect: NSRect(x: -9000,y: 0,width: 100,height: 100), styleMask: [], backing: .buffered, defer: false)
        let autosaveRegion = NSView(frame: NSRect(x:0,y:0,width:100,height:100)); autosaveWindow.contentView = autosaveRegion
        let autosave = DetailOverlayInteraction(frameAutosaveName: "FixtureOnly")
        autosave.attach(autosaveRegion, region: .content)
        check(autosaveWindow.savedNames.isEmpty, "Window frame persistence is deferred beyond attachment/layout")
        autosave.attach(autosaveRegion, region: .content); await settle()
        check(autosaveWindow.savedNames == ["FixtureOnly"] && autosaveWindow.restoredNames == ["FixtureOnly"], "Native autosave/restore is configured only once per window")
        autosave.detach(autosaveRegion, region: .content)
        let preserved = DetailOverlayInteraction(frameAutosaveName: "MustNotReplaceExisting")
        autosaveWindow.existingName = "NativeExisting"
        preserved.attach(autosaveRegion, region: .content); await settle()
        check(autosaveWindow.savedNames == ["FixtureOnly"], "Existing native window autosave ownership is preserved")
        preserved.detach(autosaveRegion, region: .content)
        other.orderOut(nil); window.orderOut(nil)
        overlayChecksFinished = true
        print("\(checked) overlay interaction checks passed")
    }
}
