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

/// updateNSView arms the probe only when that surface's own content is present.
/// The transparent overlay draws after the surface's native content. Record
/// that pass immediately; it is not a physical scan-out timestamp.
private struct ScreenContentFrame: View {
    let timing: ScreenTiming
    let surface: ScreenTiming.Surface
    let ready: Bool
    var body: some View {
        // Track the clock in this tiny body, not in AppKit's untracked update
        // callback or in the potentially large content surface's body.
        NativeContentFrame(timing:timing,surface:surface,navigation:ready ? timing.navigation(surface) : nil)
    }
}

private struct NativeContentFrame: NSViewRepresentable {
    let timing: ScreenTiming
    let surface: ScreenTiming.Surface
    let navigation: ScreenTiming.Navigation?
    func makeNSView(context: Context) -> FrameView { FrameView() }
    func updateNSView(_ view: FrameView, context: Context) {
        guard view.navigation != navigation else {return}
        view.identifier = NSUserInterfaceItemIdentifier(surface.rawValue)
        view.navigation = navigation
        view.completion = navigation.map { navigation in
            { timing.installed(surface, navigation: navigation) }
        }
        view.needsDisplay = navigation != nil
    }
    final class FrameView: NSView {
        var navigation: ScreenTiming.Navigation?
        var completion: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let completion else { return }
            self.completion = nil
            completion()
        }
    }
}
extension View {
    @MainActor func screenContentFrame(_ timing: ScreenTiming, _ surface: ScreenTiming.Surface, ready: Bool) -> some View {
        // Opaque native scroll views may completely occlude a background and
        // skip its draw. A transparent, non-interactive overlay participates in
        // the content's display pass even when that content fills the surface.
        overlay(ScreenContentFrame(timing: timing, surface: surface, ready: ready).allowsHitTesting(false).accessibilityHidden(true))
    }
}
