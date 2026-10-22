// Compile: bash scripts/compile-component.sh --scratch-path "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}" check-item-navigation-ownership
// Run: "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}/check-item-navigation-ownership"
// Component regression only: actual retention helper, no Store, service or visible UI activation.
// Actual installed pointer Back focus remains an independent acceptance check.
import AppKit
import SwiftUI

@main
struct ItemOwnershipChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let baseline = CommandLine.arguments.contains("baseline")
        let memory = DetailItemNavigationMemory.shared
        memory.entries = [:]
        var checks: [[String: Any]] = []
        var observations: [String: Int] = [:]
        func check(_ name: String, _ result: Bool) { checks.append(["name": name, "passed": result]) }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
        func field(_ x: CGFloat, _ y: CGFloat) -> NSTextField {
            let result = NSTextField(frame: NSRect(x: x, y: y, width: 180, height: 24))
            result.stringValue = "synthetic fixture"
            result.isEditable = true
            return result
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        window.contentView = content
        func anchor(_ key: String) -> (RetentionAnchorView, DetailItemStateRetention.Coordinator) {
            let c = DetailItemStateRetention.Coordinator(key: key)
            let v = RetentionAnchorView(frame: NSRect(x: 0, y: 0, width: 560, height: 567))
            v.coordinator = c; c.anchor = v
            content.addSubview(v)
            c.attach()
            return (v, c)
        }
        func isFocused(_ field: NSTextField) -> Bool {
            window.firstResponder === field || (window.firstResponder as? NSTextView)?.delegate as? NSTextField === field
        }

        // Native descendants share the same geometric region, as in the real
        // transition. Incoming editors precede outgoing editors in native order.
        memory.prepareNavigation(to: "request:origin")
        let first = field(20, 40), answer = field(20, 80)
        content.addSubview(first); content.addSubview(answer)
        let (outgoingAnchor, outgoing) = anchor("request:origin")
        drain()
        check("initial responder accepted", window.makeFirstResponder(answer))
        outgoing.capture()
        check("initial request index1", memory.entries["request:origin"]?.focus?.index == 1)
        memory.prepareNavigation(to: "task:destination")
        let incomingFields = [field(20, 120), field(20, 160), field(20, 200)]
        for editor in incomingFields { content.addSubview(editor, positioned: .below, relativeTo: first) }
        let (incomingAnchor, incoming) = anchor("task:destination")
        drain()
        incoming.restore()
        check("incoming restore retains live outgoing responder during overlap", isFocused(answer))
        outgoing.capture()
        incoming.capture()
        observations["outgoing_index_after_overlap"] = memory.entries["request:origin"]?.focus?.index ?? -1
        observations["incoming_index_during_overlap"] = memory.entries["task:destination"]?.focus?.index ?? -1
        check("overlap keeps outgoing index1", memory.entries["request:origin"]?.focus?.index == 1)
        check("incoming cannot claim outgoing responder", memory.entries["task:destination"]?.focus == nil)
        if !baseline {
            // Dismantling before native removal must retain the ownership fence.
            outgoing.detach()
            drain()
            incoming.restore(); incoming.capture()
            check("early dismantle keeps physical outgoing barrier", memory.entries["task:destination"]?.focus == nil)
            check("early dismantle keeps outgoing answer responder", isFocused(answer))
            outgoingAnchor.removeFromSuperview()
            first.removeFromSuperview(); answer.removeFromSuperview()
            drain()
            check("incoming responder accepted after physical teardown", window.makeFirstResponder(incomingFields[1]))
            incoming.capture()
            check("incoming captures own stable index1", memory.entries["task:destination"]?.focus?.index == 1)
            check("outgoing cache stays1 after physical teardown", memory.entries["request:origin"]?.focus?.index == 1)

            memory.prepareNavigation(to: "request:origin")
            let returnedFields = [field(20, 40), field(20, 80)]
            for editor in returnedFields { content.addSubview(editor, positioned: .below, relativeTo: incomingFields[0]) }
            let (returnedAnchor, returned) = anchor("request:origin")
            drain()
            check("incoming restore waits while prior tree remains", isFocused(incomingFields[1]))
            incoming.detach()
            drain()
            check("retired prior tree still prevents incoming restore", isFocused(incomingFields[1]))
            incomingAnchor.removeFromSuperview()
            incomingFields.forEach { $0.removeFromSuperview() }
            // The real failing Back trace reaches AXWindow after prior removal.
            _ = window.makeFirstResponder(nil)
            drain()
            // This prohibited-activation component cannot qualify final App AX
            // focus semantics. It checks current-item eligibility after teardown;
            // original visible App focus restoration remains independent review.
            observations["old_request_window_attached_after_return"] = outgoingAnchor.window == nil ? 0 : 1
            observations["old_task_window_attached_after_return"] = incomingAnchor.window == nil ? 0 : 1
            observations["returned_window_attached"] = returnedAnchor.window == nil ? 0 : 1
            observations["returned_is_sole_item"] = memory.isSoleAttachedItem(returned) ? 1 : 0
            observations["memory_epoch_at_return"] = memory.navigationGeneration
            check("Back cache preserves requested index1", memory.entries["request:origin"]?.focus?.index == 1)
            _ = window.makeFirstResponder(returnedFields[0])
            returned.capture()
            check("returned current item can capture its own field after teardown", memory.entries["request:origin"]?.focus?.index == 0)

            let unchangedGeneration = memory.navigationGeneration
            memory.prepareNavigation(to: "request:origin")
            check("same item does not advance navigation generation", memory.navigationGeneration == unchangedGeneration)

            let outside = field(590, 300)
            content.addSubview(outside)
            check("outside responder accepted", window.makeFirstResponder(outside))
            returned.restore()
            check("outside focus is retained", isFocused(outside))
            memory.nativeLifecycleChanged()
            drain()
            check("outside focus refusal is not retried", isFocused(outside))

            returned.detach(); returnedAnchor.removeFromSuperview()
            returnedFields.forEach { $0.removeFromSuperview() }
            drain()
            memory.prepareNavigation(to: "request:queued")
            memory.entries["request:queued"] = .init(focus: .init(index: 0, identifier: nil, selection: nil))
            let queuedField = field(20, 40)
            content.addSubview(queuedField)
            let (queuedAnchor, queued) = anchor("request:queued")
            // Invalidate before its one queued restore is allowed to run.
            memory.prepareNavigation(to: "task:newer")
            drain()
            check("stale queued restore does not steal focus", isFocused(outside))
            queued.capture()
            check("stale capture cannot replace queued cache", memory.entries["request:queued"]?.focus?.index == 0)
            queued.detach(); queuedAnchor.removeFromSuperview(); queuedField.removeFromSuperview()
            outside.removeFromSuperview()

            // Model SwiftUI coalescing close/reopen into the same native identity.
            // These scroll-only checks use actual no-entry restore completion,
            // returning before AX/focus, with no event-loop drain in this block.
            let coalescedKey = "request:coalesced"
            memory.prepareNavigation(to: coalescedKey)
            let coalescedScroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 500, height: 400))
            coalescedScroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 1400))
            content.addSubview(coalescedScroll)
            let (coalescedAnchor, coalesced) = anchor(coalescedKey)
            coalesced.restore(); coalesced.capture()
            let originalOffset = memory.entries[coalescedKey]?.scrollOffsets.first?.y ?? -1
            check("same-key fixture initially captures its scroll", originalOffset >= 0)
            memory.prepareNavigation(to: nil)
            memory.prepareNavigation(to: coalescedKey)
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 80))
            coalesced.attach(); coalesced.capture()
            check("same-key attach and capture cannot adopt epoch", memory.entries[coalescedKey]?.scrollOffsets.first?.y == originalOffset)
            coalesced.update(key: coalescedKey)
            coalesced.capture()
            check("same-key reentry stays fenced before restore completion", memory.entries[coalescedKey]?.scrollOffsets.first?.y == originalOffset)
            // Remove the entry solely to complete real restore without AX/focus.
            // A stale coordinator must still fail this current-generation guard.
            memory.entries.removeValue(forKey: coalescedKey)
            coalesced.restore()
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 120))
            coalesced.capture()
            let actualReentryOffset = coalescedScroll.contentView.bounds.origin.y
            observations["same_key_native_offset"] = Int(actualReentryOffset)
            observations["same_key_captured_offset"] = Int(memory.entries[coalescedKey]?.scrollOffsets.first?.y ?? -1)
            check("explicit same-key update resumes current-generation capture", memory.entries[coalescedKey]?.scrollOffsets.first?.y == actualReentryOffset)
            coalesced.update(key: coalescedKey)
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 160))
            coalesced.capture()
            let stableOffset = coalescedScroll.contentView.bounds.origin.y
            check("same-epoch update does not restart or fence ready capture", memory.entries[coalescedKey]?.scrollOffsets.first?.y == stableOffset)
            memory.prepareNavigation(to: "task:other-current-item")
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 200))
            coalesced.attach(); coalesced.capture()
            coalesced.update(key: coalescedKey); coalesced.capture()
            check("outgoing update cannot adopt another logical item's epoch", memory.entries[coalescedKey]?.scrollOffsets.first?.y == stableOffset)
            memory.prepareNavigation(to: coalescedKey)
            coalesced.update(key: coalescedKey)
            memory.entries.removeValue(forKey: coalescedKey)
            coalesced.restore()
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 240))
            coalesced.capture()
            let beforeRetirement = coalescedScroll.contentView.bounds.origin.y
            check("later current-key update invalidates stale queued generations", memory.entries[coalescedKey]?.scrollOffsets.first?.y == beforeRetirement)
            coalesced.detach()
            memory.prepareNavigation(to: nil)
            memory.prepareNavigation(to: coalescedKey)
            coalesced.update(key: coalescedKey)
            coalescedScroll.contentView.scroll(to: NSPoint(x: 0, y: originalOffset + 280))
            coalesced.restore(); coalesced.capture()
            check("retired same-key anchor remains physically attached", coalescedAnchor.window === window)
            check("same-key update never revives retired outgoing capture", memory.entries[coalescedKey]?.scrollOffsets.first?.y == beforeRetirement)
            coalescedAnchor.removeFromSuperview(); coalescedScroll.removeFromSuperview()

            memory.prepareNavigation(to: "request:lifetime")
            weak var weakCoordinator: DetailItemStateRetention.Coordinator?
            autoreleasepool {
                var lifetimeCoordinator: DetailItemStateRetention.Coordinator? = .init(key: "request:lifetime")
                weakCoordinator = lifetimeCoordinator
                let lifetimeAnchor = RetentionAnchorView(frame: NSRect(x: 0, y: 0, width: 560, height: 567))
                lifetimeAnchor.coordinator = lifetimeCoordinator
                lifetimeCoordinator?.anchor = lifetimeAnchor
                content.addSubview(lifetimeAnchor)
                lifetimeCoordinator = nil
                check("native anchor keeps coordinator alive", weakCoordinator != nil)
                weakCoordinator?.detach()
                check("early dismantle retains coordinator until physical removal", weakCoordinator != nil)
                lifetimeAnchor.removeFromSuperview()
            }
            drain()
            check("native removal releases acyclic coordinator", weakCoordinator == nil)
            memory.prepareNavigation(to: nil)
            window.close()
        }
        let failed = checks.filter { ($0["passed"] as? Bool) != true }
        let data = try! JSONSerialization.data(withJSONObject: ["mode": baseline ? "release22" : "ownership", "observations": observations, "checks": checks, "passed": checks.count - failed.count, "failed": failed.count, "native_event_qualification": false], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        // A red baseline is expected and retained as counterexample evidence.
        exit(failed.isEmpty ? 0 : 1)
    }
}
