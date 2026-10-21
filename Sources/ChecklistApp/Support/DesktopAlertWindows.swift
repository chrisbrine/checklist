import AppKit
import SwiftUI

/// CL-59: the most recently active window opens a clicked desktop alert's ticket or request.
@MainActor final class DesktopAlertWindows {
    static let shared = DesktopAlertWindows()
    private let clicks: DesktopAlertClicks
    init(clicks: DesktopAlertClicks = .shared) { self.clicks = clicks }
    private struct Weak { weak var store: ChecklistStore? }
    private var stores: [Weak] = []
    private var installed = false
    func activate(_ store: ChecklistStore) {
        stores.removeAll { $0.store == nil || $0.store === store }
        stores.append(Weak(store: store))
        if !installed { installed = true; clicks.setHandler { [weak self] in self?.open($0) ?? false } }
        clicks.flush()
    }
    func remove(_ store: ChecklistStore) { stores.removeAll { $0.store == nil || $0.store === store } }
    var hasWindow: Bool { stores.contains { $0.store != nil } }
    /// Opens the item in the most recent window, or keeps it for the next window that appears.
    func openOrWait(_ target: DesktopAlertTarget) { if !open(target) { clicks.route(target) } }
    @discardableResult func open(_ target: DesktopAlertTarget) -> Bool {
        guard let store = stores.last(where: { $0.store != nil })?.store else { return false }
        NSApp?.activate(ignoringOtherApps: true)
        switch target {
        case .request(let id): store.open(.request(id))
        case .task(let id): store.open(.task(id))
        }
        return true
    }
}
