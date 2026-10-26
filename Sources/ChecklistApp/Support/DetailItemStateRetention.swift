import AppKit
import SwiftUI

extension Detail {
    var persistenceKey: String {
        switch self {
        case .task(let id): return "task:" + id
        case .request(let id): return "request:" + id
        case .project(let id): return "project:" + id
        case .group(let id): return "group:" + id
        }
    }
}

@MainActor
final class DetailItemNavigationMemory {
    struct Focus {
        let index: Int
        let identifier: String?
        let selection: NSRange?
    }
    struct Entry {
        var scrollOffsets: [NSPoint] = []
        var focus: Focus?
    }
    static let shared = DetailItemNavigationMemory()
    var entries: [String: Entry] = [:]

    private struct WeakCoordinator {
        weak var value: DetailItemStateRetention.Coordinator?
    }
    private var attached: [ObjectIdentifier: WeakCoordinator] = [:]
    private weak var currentCoordinator: DetailItemStateRetention.Coordinator?
    private var activeKey: String?
    private(set) var navigationGeneration = 0
    private var lifecycleRestorePending = false

    /// The Store calls this before changing the logical item. Capture while its
    /// native editors still belong to that item, then invalidate outgoing work.
    func prepareNavigation(to key: String?) {
        guard key != activeKey else { return }
        currentCoordinator?.capture()
        currentCoordinator = nil
        activeKey = key
        navigationGeneration += 1
    }
    func owns(key: String, generation: Int) -> Bool {
        key == activeKey && generation == navigationGeneration
    }
    func register(_ coordinator: DetailItemStateRetention.Coordinator) {
        pruneDetached()
        attached[ObjectIdentifier(coordinator)] = WeakCoordinator(value: coordinator)
    }
    func isSoleAttachedItem(_ coordinator: DetailItemStateRetention.Coordinator) -> Bool {
        guard let window = coordinator.anchor?.window else { return false }
        pruneDetached()
        return attached.values.allSatisfy { entry in
            guard let other = entry.value, other !== coordinator else { return true }
            return other.anchor?.window !== window
        }
    }
    func didRestore(_ coordinator: DetailItemStateRetention.Coordinator) {
        currentCoordinator = coordinator
    }
    /// Teardown can precede physical native removal. A native detach/layout event
    /// schedules one coalesced attempt after that transaction, without polling.
    func nativeLifecycleChanged() {
        guard !lifecycleRestorePending else { return }
        lifecycleRestorePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lifecycleRestorePending = false
            self.pruneDetached()
            let coordinators = self.attached.values.compactMap(\.value)
            for coordinator in coordinators { coordinator.attach() }
        }
    }
    private func pruneDetached() {
        attached = attached.filter { $0.value.value?.anchor?.window != nil }
    }
}

private struct DetailNavigationMemoryKey: EnvironmentKey {
    static let defaultValue: DetailItemNavigationMemory? = nil
}
extension EnvironmentValues {
    var detailNavigationMemory: DetailItemNavigationMemory? {
        get { self[DetailNavigationMemoryKey.self] }
        set { self[DetailNavigationMemoryKey.self] = newValue }
    }
}

/// Native offset/focus retention supplies macOS 14 support without making every
/// overlay screen share a ScrollView or publishing per-scroll state through the app.
struct DetailItemStateRetention: NSViewRepresentable {
    let key: String
    @Environment(\.detailNavigationMemory) private var navigationMemory
    func makeCoordinator() -> Coordinator { Coordinator(key: key, memory: navigationMemory ?? .shared) }
    func makeNSView(context: Context) -> RetentionAnchorView {
        let view = RetentionAnchorView()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }
    func updateNSView(_ view: RetentionAnchorView, context: Context) { context.coordinator.update(key: key) }
    static func dismantleNSView(_ view: RetentionAnchorView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        let memory: DetailItemNavigationMemory
        private var key: String
        private var observers: [NSObjectProtocol] = []
        private var restored = false
        private var readyToCapture = false
        private var generation = 0
        private var navigationGeneration: Int
        private var retired = false
        private var isCurrentItem: Bool {
            memory.owns(key: key, generation: navigationGeneration)
        }
        init(key: String, memory: DetailItemNavigationMemory? = nil) {
            let memory = memory ?? .shared
            self.key = key
            self.memory = memory
            navigationGeneration = memory.navigationGeneration
        }

        func update(key: String) {
            guard !retired else { return }
            let memory = self.memory
            let currentGeneration = memory.navigationGeneration
            let isCurrentKey = memory.owns(key: key, generation: currentGeneration)
            // SwiftUI can coalesce K -> nil -> K without dismantling this view.
            // Only its explicit update may reenter that current logical item;
            // outgoing notifications and layout never adopt a newer generation.
            let reenteredCurrentItem = isCurrentKey && navigationGeneration != currentGeneration
            if self.key != key || reenteredCurrentItem {
                capture(); self.key = key; restored = false; readyToCapture = false; generation += 1
                if isCurrentKey { navigationGeneration = currentGeneration }
            }
            attach()
        }
        func attach() {
            guard !retired, anchor?.window != nil else { return }
            let memory = self.memory
            memory.register(self)
            guard isCurrentItem, memory.isSoleAttachedItem(self) else { return }
            if observers.isEmpty {
                for name in [NSView.boundsDidChangeNotification, NSTextView.didChangeSelectionNotification, NSControl.textDidBeginEditingNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.capture() }
                    })
                }
            }
            guard !restored else { return }
            restored = true
            let expected = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                guard self.isCurrentItem, memory.isSoleAttachedItem(self) else {
                    self.restored = false
                    return
                }
                self.restore()
            }
        }
        func detach() {
            capture(); generation += 1
            retired = true
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            memory.nativeLifecycleChanged()
        }

        func capture() {
            guard !retired, readyToCapture, isCurrentItem,
                  memory.isSoleAttachedItem(self),
                  let anchor, let window = anchor.window else { return }
            let scrolls = scrollViews()
            var entry = memory.entries[key] ?? .init()
            entry.scrollOffsets = scrolls.map { $0.contentView.bounds.origin }
            if let focused = editingView(in: window), let index = editors().firstIndex(where: { $0 === focused }) {
                entry.focus = .init(index: index, identifier: focused.identifier?.rawValue,
                                    selection: (window.firstResponder as? NSTextView)?.selectedRange())
            }
            memory.entries[key] = entry
        }

        func restore() {
            let memory = self.memory
            guard !retired, isCurrentItem, memory.isSoleAttachedItem(self) else { restored = false; return }
            guard let anchor, anchor.bounds.width > 0, anchor.bounds.height > 0 else { restored = false; return }
            defer {
                if isCurrentItem, memory.isSoleAttachedItem(self) {
                    readyToCapture = true
                    memory.didRestore(self)
                }
            }
            guard let window = anchor.window, let entry = memory.entries[key] else { return }
            for (scroll, offset) in zip(scrollViews(), entry.scrollOffsets) {
                let bounds = scroll.contentView.constrainBoundsRect(NSRect(origin: offset, size: scroll.contentView.bounds.size))
                scroll.contentView.scroll(to: bounds.origin); scroll.reflectScrolledClipView(scroll.contentView)
            }
            // A click on an underlying control keeps its own focus. Back and other
            // overlay navigation may restore the prior item's editable responder.
            guard permitsFocusRestore(window), let focus = entry.focus else { return }
            let fields = editors()
            let field = focus.identifier.flatMap { id in fields.first { $0.identifier?.rawValue == id } } ?? (fields.indices.contains(focus.index) ? fields[focus.index] : nil)
            if let field {
                window.makeFirstResponder(field)
                guard isCurrentItem, memory.isSoleAttachedItem(self) else { return }
                if let text = (field as? NSTextView) ?? (window.firstResponder as? NSTextView), let selection = focus.selection {
                    let length = (text.string as NSString).length, location = min(selection.location, length)
                    text.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
                }
            }
        }

        private func editingView(in window: NSWindow) -> NSView? {
            if let text = window.firstResponder as? NSTextView {
                if text.isFieldEditor, let field = text.delegate as? NSTextField { return field }
                if text.isEditable { return text }
            }
            if let field = window.firstResponder as? NSTextField, field.isEditable { return field }
            return nil
        }
        private func permitsFocusRestore(_ window: NSWindow) -> Bool {
            if let field = editingView(in: window) { return withinAnchor(field) }
            if let element = NSApp.accessibilityApplicationFocusedUIElement() as? NSAccessibilityProtocol, let anchor {
                // A recreated detail can leave the native window focused. Its
                // whole-window AX frame does not represent an outside control.
                if (window.firstResponder == nil || window.firstResponder === window), element.accessibilityRole() == .window { return true }
                let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                let focused = element.accessibilityFrame()
                return rect.contains(NSPoint(x: focused.midX, y: focused.midY))
            }
            return window.firstResponder == nil || window.firstResponder === window
        }
        private func withinAnchor(_ view: NSView) -> Bool {
            guard let anchor, view.window === anchor.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let rect = view.convert(view.visibleRect.intersection(view.bounds), to: nil), region = anchor.convert(anchor.bounds, to: nil).insetBy(dx: -2, dy: -2)
            return rect.width > 0 && rect.height > 0 && region.contains(rect)
        }
        private func descendants() -> [NSView] {
            guard let content = anchor?.window?.contentView else { return [] }
            var result: [NSView] = [], pending = [content]
            while let view = pending.popLast() { result.append(view); pending.append(contentsOf: view.subviews.reversed()) }
            return result
        }
        private func editors() -> [NSView] {
            descendants().filter { view in
                withinAnchor(view) && ((view as? NSTextField)?.isEditable == true || ((view as? NSTextView)?.isEditable == true && (view as? NSTextView)?.isFieldEditor != true))
            }
        }
        private func scrollViews() -> [NSScrollView] {
            descendants().compactMap { $0 as? NSScrollView }.filter { withinAnchor($0) }.sorted {
                let a = $0.frame.width * $0.frame.height, b = $1.frame.width * $1.frame.height
                return a == b ? $0.frame.minY < $1.frame.minY : a > b
            }
        }
    }
}

final class RetentionAnchorView: NSView {
    // The native anchor keeps its coordinator alive until physical removal;
    // the coordinator's anchor is weak, so this does not form a retain cycle.
    var coordinator: DetailItemStateRetention.Coordinator?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator?.attach() }
        else { coordinator?.memory.nativeLifecycleChanged() }
    }
    override func layout() { super.layout(); coordinator?.attach() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
