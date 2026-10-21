import AppKit
import SwiftUI

private struct DetailOverlayInteractionKey: EnvironmentKey {
    static let defaultValue: DetailOverlayInteraction? = nil
}
extension EnvironmentValues {
    var detailOverlayInteraction: DetailOverlayInteraction? {
        get { self[DetailOverlayInteractionKey.self] }
        set { self[DetailOverlayInteractionKey.self] = newValue }
    }
}

/// Identifies an app-owned opening control even when SwiftUI exposes a virtual
/// accessibility element rather than a native responder. Geometry never takes
/// the event: the Button still performs its own action exactly once.
struct DetailOverlayOpeningControl: NSViewRepresentable {
    @Environment(\.detailOverlayInteraction) private var interaction
    @Environment(\.isEnabled) private var enabled
    let instanceID: UUID
    let itemIdentity: String
    /// The control's own SwiftUI keyboard focus; the window's first responder is only the hosting view.
    var keyboardFocused = false
    let restoreFocus: () -> Void

    func makeNSView(context: Context) -> DetailOverlayOpeningControlView {
        let view = DetailOverlayOpeningControlView()
        configure(view)
        return view
    }
    func updateNSView(_ view: DetailOverlayOpeningControlView, context: Context) { configure(view) }
    private func configure(_ view: DetailOverlayOpeningControlView) {
        if view.interaction !== interaction { view.interaction?.detachOpeningControl(view) }
        view.instanceID = instanceID; view.itemIdentity = itemIdentity
        view.controlEnabled = enabled; view.restoreOpeningFocus = restoreFocus; view.keyboardFocused = keyboardFocused
        view.interaction = interaction
        interaction?.attachOpeningControl(view)
    }
    static func dismantleNSView(_ view: DetailOverlayOpeningControlView, coordinator: ()) {
        view.interaction?.detachOpeningControl(view)
        view.restoreOpeningFocus = nil
    }
}

@MainActor
final class DetailOverlayOpeningControlView: NSView {
    weak var interaction: DetailOverlayInteraction?
    var instanceID = UUID()
    var itemIdentity = ""
    var controlEnabled = true
    var keyboardFocused = false
    var restoreOpeningFocus: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { interaction?.detachOpeningControl(self) }
        else { interaction?.attachOpeningControl(self) }
    }
    func visibleFrame(in window: NSWindow) -> NSRect? {
        guard self.window === window, controlEnabled, !isHiddenOrHasHiddenAncestor else { return nil }
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return nil }
        let frame = convert(visible, to: nil)
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        return frame
    }

    /// A native sibling (for example a popover's covering content) owns its hit.
    /// SwiftUI's shared hosting ancestor is allowed; another native control is not.
    func isExposed(at point: NSPoint, in window: NSWindow) -> Bool {
        guard self.window === window, let root = window.contentView,
              let target = root.hitTest(root.convert(point, from: nil)) else { return false }
        return target === self || isDescendant(of: target)
    }
}
