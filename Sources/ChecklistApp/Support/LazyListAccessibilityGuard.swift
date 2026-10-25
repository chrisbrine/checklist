import AppKit
import ObjectiveC

/// CL-272: on this macOS release, SwiftUI traps in `ForEachState.item(at:offset:)`
/// when an accessibility client (VoiceOver or automation) performs AXScrollToTop
/// or AXScrollToBottom on a lazy stack whose rows are not all created yet. The
/// trap is in SwiftUI's own `AccessibilityLazyLayoutNode`, not in a list's data
/// or IDs: a static 60-row `LazyVStack` traps on one AXScrollToBottom, while a
/// 5-row one, a `VStack` and a `List` do not.
///
/// The guard answers only those two actions on that node type, by scrolling the
/// enclosing scroll view to its edge. Every other action, and every other node,
/// keeps SwiftUI's own handling. If SwiftUI renames the node, nothing changes.
enum LazyListAccessibilityGuard {
    static let nodeClassName = "SwiftUI.AccessibilityLazyLayoutNode"
    static let edgeActions: Set<String> = ["AXScrollToTop", "AXScrollToBottom"]
    private static var installed = false

    /// Installs the guard once per process. Returns true when the node type
    /// exists and its action handler now goes through the guard.
    @MainActor @discardableResult static func install() -> Bool {
        if installed { return true }
        let selector = NSSelectorFromString("accessibilityPerformAction:")
        guard let node = NSClassFromString(nodeClassName), let method = class_getInstanceMethod(node, selector),
              let types = method_getTypeEncoding(method) else { return false }
        typealias Perform = @convention(c) (NSObject, Selector, NSString) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Perform.self)
        let handler: @convention(block) (NSObject, NSString) -> Void = { object, action in
            if edgeActions.contains(action as String), scrollToEdge(from: object, top: action as String == "AXScrollToTop") { return }
            original(object, selector, action)
        }
        let replacement = imp_implementationWithBlock(handler)
        // Replace only the node type's own handler; an inherited one stays as it is.
        if !class_addMethod(node, selector, replacement, types) { method_setImplementation(method, replacement) }
        installed = true
        return true
    }

    /// Scrolls the nearest enclosing scroll view of an accessibility node to
    /// its top or bottom. Returns false when no scroll view is found.
    static func scrollToEdge(from node: NSObject, top: Bool) -> Bool {
        var current: NSObject? = node
        for _ in 0..<64 {
            guard let object = current else { return false }
            if let scroll = (object as? NSScrollView) ?? (object as? NSView)?.enclosingScrollView {
                guard let document = scroll.documentView else { return false }
                let clip = scroll.contentView
                let end = max(0, document.frame.height - clip.bounds.height)
                let y = top == document.isFlipped ? 0 : end
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(clip)
                return true
            }
            let parent = NSSelectorFromString("accessibilityParent")
            current = object.responds(to: parent) ? object.perform(parent)?.takeUnretainedValue() as? NSObject : nil
        }
        return false
    }
}
