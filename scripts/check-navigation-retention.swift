// Compile: bash scripts/compile-component.sh --scratch-path "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}" check-navigation-retention
// Run: "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}/check-navigation-retention"
// Isolated offscreen fixture; no Checklist service or user window/preferences.
import AppKit
import SwiftUI

@main
struct NavigationRetentionChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { guard value() else { fatalError(message) }; checks += 1 }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650)); window.contentView = content
        let anchor = RetentionAnchorView(frame: NSRect(x: 500, y: 0, width: 400, height: 650)); content.addSubview(anchor)
        let scroll = NSScrollView(frame: NSRect(x: 510, y: 100, width: 370, height: 500)); scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 2400)); scroll.documentView = document; content.addSubview(scroll)
        let editor = NSTextField(frame: NSRect(x: 530, y: 35, width: 300, height: 30)); editor.identifier = .init("per-item-editor"); content.addSubview(editor)
        let outside = NSTextField(frame: NSRect(x: 50, y: 35, width: 200, height: 30)); content.addSubview(outside)
        window.orderFront(nil)
        DetailItemNavigationMemory.shared.prepareNavigation(to: "task:first")
        let first = DetailItemStateRetention.Coordinator(key: "task:first"); first.anchor = anchor; first.restore()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 450)); window.makeFirstResponder(editor); first.capture()
        let saved = DetailItemNavigationMemory.shared.entries["task:first"]!
        check(saved.scrollOffsets.first?.y == 450 && saved.focus != nil, "An item must capture its scroll and actual editable focus")
        DetailItemNavigationMemory.shared.prepareNavigation(to: "task:second")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20)); window.makeFirstResponder(outside)
        let second = DetailItemStateRetention.Coordinator(key: "task:second"); second.anchor = anchor; second.restore(); second.capture()
        check(DetailItemNavigationMemory.shared.entries["task:second"]?.scrollOffsets.first?.y == 20, "Different item IDs must retain separate scroll positions")
        DetailItemNavigationMemory.shared.prepareNavigation(to: "task:first")
        first.update(key: "task:first"); first.restore()
        check(scroll.contentView.bounds.origin.y == 450, "Back must restore the earlier item's scroll offset")
        check((window.firstResponder as? NSTextView)?.delegate as? NSTextField === outside, "Per-item restoration must not steal focus from an outside clicked control")
        window.makeFirstResponder(window); first.restore()
        check((window.firstResponder as? NSTextView)?.delegate as? NSTextField === editor, "Back within overlay may restore the retained editable field")
        check(Detail.task("same").persistenceKey != Detail.request("same").persistenceKey, "Entity kinds must not share navigation state by coincidental ID")
        let a = Record(values: ["id": "A", "title": "Old A"]), b = Record(values: ["id": "B", "title": "B"])
        let prior = [TicketListRow(id: .ticket("A"), content: .ticket(a)), TicketListRow(id: .ticket("B"), content: .ticket(b))]
        let current = [TicketListRow(id: .ticket("B"), content: .ticket(b)), TicketListRow(id: .ticket("A"), content: .ticket(Record(values: ["id": "A", "title": "Updated A"])))]
        let held = StableTicketRows.holding(prior, current: current)
        check(held.map(\.id) == prior.map(\.id), "Live updates cannot move a different ticket under a pointer/key interaction")
        if case .ticket(let updated) = held[0].content { check(updated.string("title") == "Updated A", "Holding order must still refresh the same ticket's content") }
        else { fatalError("Ticket identity changed") }
        check(StableTicketRows.holding(prior, current: [current[0]]).map(\.id) == prior.map(\.id), "A filtered/removed row stays anchored until an interaction boundary")
        let stability = TicketListStability(); stability.pointer(true, rows: prior)
        check(stability.pending(current) && stability.rows(current).map(\.id) == prior.map(\.id), "Pointer interaction must expose deferred movement")
        stability.apply(current)
        check(!stability.pending(current) && stability.rows(current).map(\.id) == current.map(\.id), "Apply updates is an explicit safe reorder boundary")
        stability.pointer(false, rows: current)
        check(stability.rows(prior).map(\.id) == prior.map(\.id), "Leaving pointer interaction resumes current ordering")
        first.detach(); second.detach(); window.orderOut(nil)
        print("\(checks) navigation retention checks passed")
    }
}
