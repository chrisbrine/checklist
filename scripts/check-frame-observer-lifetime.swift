// Compile: xcrun swiftc -swift-version 5 -parse-as-library Sources/ChecklistApp/Support/DetailOverlayInteraction.swift scripts/check-frame-observer-lifetime.swift -o /tmp/checklist-frame-observer-lifetime
// Isolated hidden native windows and a persistence spy; no user preferences.
import AppKit
import SwiftUI

@MainActor final class FrameLifetimeWindow: NSWindow {
    var configured: [String] = [], restored: [String] = [], saved: [String] = []
    override var frameAutosaveName: NSWindow.FrameAutosaveName { "NativeSceneName" }
    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { configured.append(name); return true }
    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool { restored.append(name); return true }
    override func saveFrame(usingName name: NSWindow.FrameAutosaveName) { saved.append(name) }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@main struct FrameObserverLifetimeChecks {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { guard value() else { fatalError(message) }; count += 1 }
        func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }
        let window = FrameLifetimeWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size)); window.contentView = anchor
        var bridge: DetailOverlayInteraction? = DetailOverlayInteraction(frameAutosaveName: "PrivateWorkspaceKey")
        bridge!.attach(anchor, region: .content); bridge!.detach(anchor, region: .content); await settle()
        check(window.restored.isEmpty && window.saved.isEmpty, "Detached deferred restore must not touch the frame")
        bridge!.attach(anchor, region: .content); bridge!.detach(anchor, region: .content); bridge!.attach(anchor, region: .content)
        await settle()
        check(window.restored == ["PrivateWorkspaceKey"], "Superseded same-window attachments must restore only once")
        check(window.configured.isEmpty, "Existing scene autosave ownership must be retained")
        check(window.saved.isEmpty, "Restore/attachment must not overwrite an existing saved owner frame")
        for _ in 0..<20 { bridge!.attach(anchor, region: .content) }; await settle()
        check(window.restored.count == 1 && window.saved.isEmpty, "Repeated layout attachment must not restore or persist again")
        window.setContentSize(NSSize(width: 920, height: 670))
        check(window.saved == ["PrivateWorkspaceKey"], "One real native resize must have one persistence observer")
        bridge!.detach(anchor, region: .content)
        window.setContentSize(NSSize(width: 930, height: 680))
        check(window.saved.count == 1, "Detached bridge must release window persistence observers")
        bridge!.attach(anchor, region: .content); await settle()
        window.setContentSize(NSSize(width: 940, height: 690))
        check(window.restored.count == 2 && window.saved.count == 2, "Reattachment must restore one observer after prior cleanup")
        weak var released = bridge; bridge = nil; await settle()
        check(released == nil, "Native observers must not retain the bridge")
        window.setContentSize(NSSize(width: 950, height: 700))
        check(window.saved.count == 2, "Deinitialized bridge must remove native observers")
        print("\(count) native frame observer lifetime checks passed")
    }
}
