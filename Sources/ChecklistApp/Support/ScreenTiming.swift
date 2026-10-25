import SwiftUI
import AppKit
import Observation
import OSLog

/// Window-local navigation clock. Only the fixed surface vocabulary and elapsed
/// time leave the process. A native drawing pass, not a model assignment, ends it.
@MainActor @Observable final class ScreenTiming {
    enum Surface: String, CaseIterable { case overview, tickets, epics, ticketDetail = "ticket_detail", projectSwitch = "project_switch", cleanup }
    struct Navigation: Equatable {
        let id = UUID()
        let start = DispatchTime.now().uptimeNanoseconds
        var cached = false
    }
    private var pending: [Surface: Navigation] = [:]
    private static let logger = Logger(subsystem: "org.checklist.app", category: "ScreenTiming")
    func begin(_ surface: Surface) { pending[surface] = Navigation() }
    func cached(_ surface: Surface, _ cached: Bool) {
        guard pending[surface] != nil else { return }
        pending[surface]?.cached = cached
    }
    func navigation(_ surface: Surface) -> Navigation? { pending[surface] }
    func cancel(_ surface: Surface) { pending.removeValue(forKey: surface) }
    func installed(_ surface: Surface, navigation: Navigation) {
        guard pending[surface]?.id == navigation.id else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - navigation.start) / 1_000_000
        let cache = navigation.cached ? "cached" : "cold"
        Self.logger.notice("surface=\(surface.rawValue, privacy: .public) cache=\(cache, privacy: .public) duration_ms=\(ms, privacy: .public)")
        NativeRenderMetrics.screenInstalled(surface.rawValue, cached: navigation.cached, milliseconds: ms)
        // End the clock in draw, before unrelated queued focus/AX work. Only
        // observation teardown waits until outside the native drawing pass.
        DispatchQueue.main.async { [weak self] in
            guard self?.pending[surface]?.id == navigation.id else {return}
            self?.pending.removeValue(forKey:surface)
        }
    }
}

/// A content receipt requires every expected string within the optional named
/// section. Identifiers and text stay inside the window, never in timing logs.
struct ScreenAccessibilityContent: Equatable {
    var identifier: String? = nil
    let text: [String]
    var staticTextOnly = false
    @MainActor func isPresent(in root: NSObject) -> Bool {
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to:selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        func children(_ node: NSObject) -> [NSObject] {attribute(node,"accessibilityChildren") as? [NSObject] ?? []}
        func excluded(_ node: NSObject) -> Bool {
            let role = attribute(node,"accessibilityRole") as? String ?? ""
            return ["AXMenu","AXMenuBar","AXMenuButton","AXPopUpButton"].contains(role)
        }
        var section = root
        if let identifier {
            var queue = [root], index = 0
            var found: NSObject?
            while index < queue.count, index < 5000 {
                let node = queue[index];index += 1
                if excluded(node) {continue}
                if attribute(node,"accessibilityIdentifier") as? String == identifier {found = node;break}
                queue += children(node)
            }
            guard let found else {return false}
            section = found
        }
        var remaining = Set(text), queue = [section], index = 0
        while index < queue.count, index < 5000, !remaining.isEmpty {
            let node = queue[index];index += 1
            // Hidden menu choices and matching background buttons cannot prove
            // that the destination's static header or scoped facts are ready.
            if excluded(node) {continue}
            if !staticTextOnly || attribute(node,"accessibilityRole") as? String == "AXStaticText" {
                let strings = ["accessibilityLabel","accessibilityTitle","accessibilityValue"].compactMap {attribute(node,$0) as? String}
                remaining = remaining.filter {expected in !strings.contains {$0.contains(expected)}}
            }
            queue += children(node)
        }
        return remaining.isEmpty
    }
}

/// The navigation token is captured by the content builder, not observed by a
/// retained probe. A new clock cannot arm a frame built for preceding content.
private struct NativeContentFrame: NSViewRepresentable {
    let timing: ScreenTiming
    let surface: ScreenTiming.Surface
    let navigation: ScreenTiming.Navigation?
    let accessibilityContent: ScreenAccessibilityContent?
    func makeNSView(context: Context) -> FrameView { FrameView() }
    func updateNSView(_ view: FrameView, context: Context) {
        guard view.navigation != navigation || view.accessibilityContent != accessibilityContent else {return}
        view.identifier = NSUserInterfaceItemIdentifier(surface.rawValue)
        view.navigation = navigation
        view.accessibilityContent = accessibilityContent
        view.accessibilityRetries = 0
        view.completion = navigation.map { navigation in
            { timing.installed(surface, navigation: navigation) }
        }
        view.needsDisplay = navigation != nil
    }
    final class FrameView: NSView {
        var navigation: ScreenTiming.Navigation?
        var accessibilityContent: ScreenAccessibilityContent?
        var accessibilityRetries = 0
        var completion: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let completion else { return }
            if let accessibilityContent,
               window?.contentView.map({accessibilityContent.isPresent(in:$0)}) != true {
                // AX publication may follow layout. Request at most two extra
                // draws for this content/token, with no timer or redraw loop.
                // Later natural content draws can still satisfy a pending probe.
                guard accessibilityRetries < 2 else {return}
                accessibilityRetries += 1
                let navigation = self.navigation
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.navigation == navigation,self.completion != nil else {return}
                    self.needsDisplay = true
                }
                return
            }
            self.completion = nil
            completion()
        }
    }
}
extension View {
    @MainActor func screenContentFrame(_ timing: ScreenTiming, _ surface: ScreenTiming.Surface, ready: Bool, accessibilityContent: ScreenAccessibilityContent? = nil) -> some View {
        // Opaque native scroll views may completely occlude a background and
        // skip its draw. A transparent, non-interactive overlay participates in
        // the content's display pass even when that content fills the surface.
        overlay(NativeContentFrame(timing: timing, surface: surface, navigation: ready ? timing.navigation(surface) : nil, accessibilityContent:accessibilityContent).allowsHitTesting(false).accessibilityHidden(true))
    }
}
