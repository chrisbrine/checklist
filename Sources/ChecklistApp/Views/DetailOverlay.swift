import SwiftUI
import AppKit

struct DetailOverlay: View {
    @EnvironmentObject var store: ChecklistStore
    let detail: Detail
    var body: some View {
        let _ = NativeRenderMetrics.body(.detailOverlay)
        VStack(spacing: Spacing.none) {
            HStack(spacing: Spacing.row) {
                OverlayNavigationButton(symbol: "chevron.left", label: "Back", identifier: "detailBackButton", help: "Back (⌘[)") { store.goBack() }.checklistDisabled([(store.detailBackStack.isEmpty, "There is no earlier detail.")])
                Text(breadcrumb).checklistFont(.caption).foregroundStyle(Color.checklistSecondaryText).lineLimit(1)
                Spacer()
                OverlayNavigationButton(symbol: "xmark", label: "Close details", identifier: "detailCloseButton", help: "Close details (Esc)", initialFocus: true) { store.closeDetail() }.foregroundStyle(Color.checklistSecondaryText)
            }.padding(.horizontal, Spacing.page).padding(.vertical, Spacing.group)
            Divider()
            Group {
                if case .task(let id) = detail {
                    if let task = store.selectedTask(id) {TaskDetailView(task:task).id(id).screenContentFrame(store.screenTiming, .ticketDetail, ready: store.detail == .task(id) && store.selectedTask(id) != nil, accessibilityContent:ScreenAccessibilityContent(text:task.bool("purged") ? [breadcrumb,"Purged ticket",task.string("key")] : [breadcrumb,task.string("title")],staticTextOnly:true))}
                    else if store.showsOfflineBanner || store.selectedTicketMissing {DetailUnavailable(symbol: "doc.text", title: "Ticket unavailable")}
                    else if let failure = store.selectedTicketError {VStack(spacing: Spacing.control) {Text(failure);Button("Retry ticket") {store.retrySelectedTicket()}}.padding(Spacing.group)}
                    else {ProgressView("Loading selected ticket…")}
                } else if case .request(let id) = detail {
                    // The form stays at the same structural identity while its record refreshes.
                    VStack(spacing: Spacing.none) {
                        if let error = store.otherDetailError {
                            HStack { Text(error); Button("Retry detail") { store.retryOtherDetail() } }
                                .checklistFont(.micro).foregroundStyle(.orange).padding(Spacing.control)
                        }
                        if store.otherDetailMissing {
                            Text("This request is no longer available. Your unsent draft is kept.")
                                .checklistFont(.callout).padding(Spacing.control)
                        } else if store.requestNoLongerListed(id) {
                            Text("This request is no longer in this Needs You view. Your draft is kept.")
                                .checklistFont(.callout).padding(Spacing.control)
                        }
                        if let request = store.requestDetail(id) {
                            RequestDetailView(request: request).id(id).checklistDisabled([(store.otherDetailMissing, "This request is no longer available. Your draft is kept.")])
                        } else if store.otherDetailLoading { ProgressView("Loading current detail…") }
                        else { DetailUnavailable(symbol: "bubble.left", title: "Request unavailable") }
                    }
                } else if store.otherDetailLoading && store.selectedOther == nil {ProgressView("Loading current detail…")}
                else if let error=store.otherDetailError {VStack(spacing: Spacing.control) {Text(error).multilineTextAlignment(.center);Button("Retry detail") {store.retryOtherDetail()}}.padding(Spacing.group)}
                else {switch detail {
                case .task: EmptyView()
                case .request: EmptyView()
                case .project(let id): if let project = store.project(id) { ProjectSettingsView(project: project).id(id) } else { DetailUnavailable(symbol: "gearshape", title: "Project settings unavailable") }
                case .group(let id): if let group = store.groups.first(where: { $0.id == id }) { if group.string("kind") == "epic" { EpicDetailView(epic: group).id(id) } else { TriageDetailView(triage: group).id(id) } } else { DetailUnavailable(symbol: "folder", title: "Epic or Triage unavailable") }
                }}
            }.background(DetailItemStateRetention(key: detail.persistenceKey).id(detail.persistenceKey))
        }.background(OverlayFocusAnchor(item: detail.persistenceKey, label: focusLabel))
            // Read the open detail as one destination before controls behind it.
            // Background navigation remains accessible after this container.
            .accessibilityElement(children: .contain).accessibilitySortPriority(1)
    }
    var focusLabel: String {
        switch detail {
        case .task: return "Ticket details"
        case .request: return "Request details"
        case .project: return "Project settings"
        case .group(let id): return groupKind(id).map { "\($0) details" } ?? "Epic or Triage details"
        }
    }
    var breadcrumb: String {
        switch detail {
        case .task(let id): guard let task = store.selectedTask(id) ?? store.task(id) else { return "Ticket" }; return "\(store.projectName(task.string("project_id")))  /  \(task.string("key"))"
        case .request(let id): guard let request = store.requests.first(where: { $0.id == id }) else { return "Request" }; return "\(store.projectName(request.string("project_id")))  /  Your answer"
        case .project(let id): return "\(store.projectName(id))  /  Settings"
        case .group(let id):
            guard let group = store.groups.first(where: { $0.id == id }), let kind = groupKind(id) else { return "Project" }
            return "\(store.projectName(group.string("project_id")))  /  \(kind)"
        }
    }
    /// The glossary name of a group record: "Epic" or "Triage".
    func groupKind(_ id: String) -> String? {
        guard let group = store.groups.first(where: { $0.id == id }) else { return nil }
        return group.string("kind") == "epic" ? "Epic" : "Triage"
    }
}

private struct OverlayNavigationButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var help: String? = nil
    var initialFocus = false
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var spokenFocus: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }.buttonStyle(.checklistIcon)
            .focused($focused).accessibilityFocused($spokenFocus)
            .onAppear { if initialFocus { focused = NSApp.isFullKeyboardAccessEnabled; spokenFocus = true } }
            .help(help ?? label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}


private struct OverlayFocusAnchor: NSViewRepresentable {
    let item: String
    let label: String
    func makeNSView(context: Context) -> OverlayFocusView { OverlayFocusView() }
    func updateNSView(_ view: OverlayFocusView, context: Context) { view.update(item: item, label: label) }
}

/// Default macOS keyboard navigation excludes Buttons, so the panel needs its own responder.
final class OverlayFocusView: NSView {
    private var item: String?
    private var focusGeneration = 0
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus(initial: true)
    }
    func update(item: String, label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        guard self.item != item else { return }
        let initial = self.item == nil
        self.item = item
        requestFocus(initial: initial)
    }
    private func requestFocus(initial: Bool) {
        focusGeneration += 1
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusGeneration == generation, let window = self.window,
                  !NSApp.isFullKeyboardAccessEnabled, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            guard initial || window.firstResponder == nil || window.firstResponder === window else { return }
            if window.makeFirstResponder(self) {
                self.setAccessibilityFocused(true)
                if initial { for delay in [0.25, 0.7] { self.reclaimLateHostFocus(generation, after: delay) } }
            }
        }
    }
    /// A clicked SwiftUI row can apply its click focus after the panel took focus (seen once, on the
    /// first click after an install). Then the first responder is the SwiftUI host that contains this
    /// panel; take focus back. A text field, editor or native control keeps the focus it was given.
    private func reclaimLateHostFocus(_ generation: Int, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.focusGeneration == generation, let window = self.window,
                  !NSApp.isFullKeyboardAccessEnabled, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let host = window.firstResponder as? NSView, host !== self, !(host is NSText), !(host is NSControl),
                  self.isDescendant(of: host) else { return }
            if window.makeFirstResponder(self) { self.setAccessibilityFocused(true) }
        }
    }
}
