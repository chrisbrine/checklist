import XCTest
import SwiftUI
import AppKit
import ChecklistCore
@testable import ChecklistApp

/// CL-272 item 3. Real product views in bounded, offscreen AppKit hosts;
/// all reads are inert templates, with no service, test slot or live store.
@MainActor final class RemainingLazyListAccessibilityTests: XCTestCase {
    func testTicketsSurviveAccessibilityEdgesWhileRowsChange() async throws {
        let fixture = ChangingListFixture(page: .tasks, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store()
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        await store.refresh(quiet: true)
        let host = ChangingListHost(TaskWorkspaceView().environmentObject(store))
        defer { host.close() }
        try await AXProbe.until { store.preparedTicketWorkspace != nil && !ChangingListAX.lazyNodes(host.view).isEmpty }
        XCTAssertEqual(store.ticketPageShownCount, 120, "Tickets must use the task_list page protocol")
        try await ChangingListAX.exercise(host, absent: "Ticket 119 generation 0", middleRow: "Ticket 60") { round in
            fixture.generation = round + 1
            await store.refresh(quiet: true)
            XCTAssertEqual(store.ticketPageShownCount, round == 1 ? 110 : 120)
        }
        XCTAssertTrue(host.window.contentView === host.view, "The hosted app view stays alive")
    }

    func testYourTicketsSurviveAccessibilityEdgesWhileRowsChange() async throws {
        let fixture = ChangingListFixture(page: .needsYou, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store()
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        await store.refresh(quiet: true)
        let host = ChangingListHost(NeedsYouView().environmentObject(store))
        defer { host.close() }
        let segment = try XCTUnwrap(AXProbe.nodes(host.view).first {
            (AXProbe.attribute($0, "accessibilityLabel") as? String ?? "").hasPrefix("Your tickets")
        })
        ChangingListAX.activate(segment)
        try await AXProbe.until { fixture.surfaces.contains("human_tasks") && store.workspaceRows.count == 50 && !ChangingListAX.lazyNodes(host.view).isEmpty }
        XCTAssertEqual(store.workspaceRows.first?.string("record_type"), "task")
        try await ChangingListAX.exercise(host, absent: "Ticket 49 generation 0", middleRow: "Ticket 25") { round in
            fixture.generation = round + 1
            await store.refresh(quiet: true)
            XCTAssertEqual(store.workspaceRows.first?.string("title"), "Ticket 49 generation \(round + 1)")
        }
        XCTAssertTrue(host.window.contentView === host.view)
    }

    func testTicketDetailSectionsSurviveAccessibilityEdgesWhileDataChanges() async throws {
        try await exerciseDetail(conversation: false)
    }

    func testTicketConversationSurvivesAccessibilityEdgesWhileMessagesChange() async throws {
        try await exerciseDetail(conversation: true)
    }

    private func exerciseDetail(conversation: Bool) async throws {
        let fixture = ChangingListFixture(page: .tasks, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store()
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        await store.refresh(quiet: true)
        store.open(.task("ticket-0"))
        try await AXProbe.until { store.selectedTicketCurrent("ticket-0") }
        let host = ChangingListHost(ChangingTicketDetail(store: store))
        defer { host.close() }
        try await AXProbe.until { !ChangingListAX.lazyNodes(host.view).isEmpty }
        if conversation { try await ChangingListAX.revealConversation(host) }
        try await ChangingListAX.exercise(host, absent: "Message 0 generation 0", middleRow: "Message 25", nested: conversation) { round in
            fixture.generation = round + 1
            store.retrySelectedTicket()
        }
        XCTAssertTrue(store.selectedTicketCurrent("ticket-0"))
        XCTAssertEqual(store.detailRecords("messages", task: try XCTUnwrap(store.selectedTask("ticket-0"))).first?.string("body"), "Message 49 generation 3")
        XCTAssertTrue(host.window.contentView === host.view)
    }

    func testMediaPublicationSurvivesAccessibilityEdgesWhileRowsChange() async throws {
        let fixture = ChangingListFixture(page: .media, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store(), model = MediaReviewModel()
        defer { store.stopWindowReads() }
        model.header = Record(values: ["id": "round", "title": "Synthetic round", "state": "draft"])
        model.publication = mediaRows(generation: 0)
        model.types = [Record(values: ["id": "type", "enabled": true, "title": "Synthetic type"])]
        model.typeID = "type"; model.roundID = "round"
        model.rounds = [model.header]
        let host = ChangingListHost(MediaReviewWorkspace(model: model).environmentObject(store))
        defer { host.close() }
        try await ChangingListAX.expand("Publication items", in: host.view)
        try await ChangingListAX.exercise(host, absent: "Media 119 generation 0", middleRow: "Media 60", innermost: true) { round in
            model.publication = self.mediaRows(generation: round + 1)
        }
        XCTAssertEqual(model.publication.first?.string("title"), "Media 119 generation 3")
        XCTAssertTrue(host.window.contentView === host.view)
    }

    func testMediaItemsSurviveAccessibilityEdgesWhileRowsChange() async throws {
        let fixture = ChangingListFixture(page: .media, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store(), model = MediaReviewModel()
        defer { store.stopWindowReads() }
        model.rows = mediaRows(generation: 0)
        let host = ChangingListHost(ChangingMediaItems(model: model).environmentObject(store))
        defer { host.close() }
        try await ChangingListAX.exercise(host, absent: "Media 119 generation 0", middleRow: "Media 60") { round in
            model.rows = self.mediaRows(generation: round + 1)
        }
        XCTAssertEqual(model.rows.first?.string("title"), "Media 119 generation 3")
        XCTAssertTrue(host.window.contentView === host.view)
    }

    func testMediaFrozenIntakeSurvivesAccessibilityEdgesWhileRowsChange() async throws {
        let fixture = ChangingListFixture(page: .media, preferences: isolatedDefaults("RemainingLazyAX").preferences)
        defer { fixture.clean() }
        let store = fixture.store(), model = MediaReviewModel()
        defer { store.stopWindowReads() }
        func intake(_ generation: Int) -> Record {
            Record(values: ["id": "intake", "rows": mediaRows(generation: generation).map(\.values), "remaining_row_ids": ["remaining"]])
        }
        model.intake = intake(0)
        let host = ChangingListHost(VStack { MediaFrozenIntakeView(model: model); Spacer() }.environmentObject(store))
        defer { host.close() }
        try await ChangingListAX.expand("Frozen intake", in: host.view)
        try await ChangingListAX.exercise(host, absent: "Media 119 generation 0", middleRow: "Media 60") { round in
            model.intake = intake(round + 1)
        }
        XCTAssertEqual(model.intake.records("rows").first?.string("title"), "Media 119 generation 3")
        XCTAssertTrue(host.window.contentView === host.view)
    }

    func testMarkdownSurvivesAccessibilityEdgesWhileDocumentChanges() async throws {
        let holder = ChangingMarkdown()
        let host = ChangingListHost(ChangingMarkdownView(holder: holder))
        defer { host.close() }
        try await ChangingListAX.exercise(host, absent: "Paragraph 119 generation 0", middleRow: "Paragraph 60") { round in
            holder.generation = round + 1
        }
        XCTAssertTrue(AXProbe.text(host.view).contains("generation 3"))
        XCTAssertTrue(host.window.contentView === host.view)
    }

    private func mediaRows(generation: Int) -> [Record] {
        let ids = generation == 0 ? Array(0..<120) : Array((generation % 2 == 0 ? 10 : 0)..<120).reversed().map { $0 }
        return ids.map { Record(values: ["id": "media-\($0)", "item_id": "media-\($0)", "title": "Media \($0) generation \(generation)", "publication_ready": true, "disposition": "pending", "status": "ready", "name": "Template \($0)", "capture_state": "committed"]) }
    }
}

/// Keep the model observation inside a mounted View body when exercising a
/// product subview; extracting a computed subview before hosting freezes its rows.
@MainActor private struct ChangingMediaItems: View {
    @ObservedObject var model: MediaReviewModel
    var body: some View { MediaReviewWorkspace(model: model).itemList }
}

@MainActor private struct ChangingTicketDetail: View {
    @ObservedObject var store: ChecklistStore
    var body: some View {
        if let task = store.selectedTask("ticket-0") { TaskDetailView(task: task).environmentObject(store) }
    }
}

@MainActor private final class ChangingMarkdown: ObservableObject {
    @Published var generation = 0
    var document: MarkdownDocument {
        MarkdownDocument.parse((generation == 0 ? Array(0..<120) : Array(10..<120).reversed().map { $0 }).map { "Paragraph \($0) generation \(generation)" }.joined(separator: "\n\n"))
    }
}
@MainActor private struct ChangingMarkdownView: View {
    @ObservedObject var holder: ChangingMarkdown
    var body: some View { RenderedMarkdownPreview(document: holder.document, resources: [], source: Record(values: [:])) }
}

@MainActor private final class ChangingListHost {
    let window: NSWindow
    let view: NSView
    let restore: () -> Void
    init<V: View>(_ content: V) {
        restore = AXProbe.enableEnhancedUserInterface()
        view = NSHostingView(rootView: content.frame(width: 900, height: 400))
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist changing-list AX test (offscreen)"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
    }
    func close() { restore(); window.contentView = nil; window.close() }
}

@MainActor private enum ChangingListAX {
    static func lazyNodes(_ root: NSObject) -> [NSObject] {
        AXProbe.scrollTargets(root).filter { NSStringFromClass(type(of: $0)) == LazyListAccessibilityGuard.nodeClassName }
    }
    static func expand(_ label: String, in root: NSView) async throws {
        var disclosure: NSObject?
        try await AXProbe.until {
            root.layoutSubtreeIfNeeded()
            disclosure = AXProbe.nodes(root).first { node in
                guard AXProbe.attribute(node, "accessibilityRole") as? String == NSAccessibility.Role.disclosureTriangle.rawValue else { return false }
                if AXProbe.text(node).contains(label) { return true }
                return (AXProbe.attribute(node, "accessibilityParent") as? NSObject).map { AXProbe.text($0).contains(label) } ?? false
            }
            return disclosure != nil
        }
        activate(try XCTUnwrap(disclosure))
        try await Task.sleep(nanoseconds: 30_000_000)
        root.layoutSubtreeIfNeeded()
    }
    static func activate(_ node: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { XCTFail("The native AX control cannot be activated"); return }
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        // Some SwiftUI controls return false after changing selection; verify
        // the resulting product state, rather than interpreting that Bool.
        _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
    }
    static func enclosingScroll(_ node: NSObject) -> NSScrollView? {
        var next: NSObject? = node
        for _ in 0..<64 {
            guard let current = next else { return nil }
            if let scroll = (current as? NSScrollView) ?? (current as? NSView)?.enclosingScrollView { return scroll }
            next = AXProbe.attribute(current, "accessibilityParent") as? NSObject
        }
        return nil
    }
    static func revealConversation(_ host: ChangingListHost) async throws {
        let scroll = try XCTUnwrap(AXProbe.scrollViews(host.view).first)
        for _ in 0..<30 {
            host.view.layoutSubtreeIfNeeded()
            if lazyNodes(host.view).count >= 2 { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y + 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The product conversation lazy stack never entered the viewport")
    }
    static func edges(_ node: NSObject) throws {
        let names = AXProbe.scrollActions(node)
        XCTAssertTrue(names.contains("AXScrollToTop"))
        XCTAssertTrue(names.contains("AXScrollToBottom"))
        let scroll = try XCTUnwrap(enclosingScroll(node))
        let start = scroll.contentView.bounds.origin.y
        AXProbe.perform(node, "AXScrollToBottom")
        let bottom = scroll.contentView.bounds.origin.y
        AXProbe.perform(node, "AXScrollToTop") // SwiftUI's scrollToBeginning crash path.
        let top = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(abs(bottom - top), 5, "Both AX edges move the actual product list (start \(start), bottom \(bottom), top \(top))")
    }
    static func exercise(_ host: ChangingListHost, absent: String, middleRow: String, nested: Bool = false, innermost: Bool = false, mutate: (Int) async throws -> Void) async throws {
        XCTAssertTrue(LazyListAccessibilityGuard.install())
        try await AXProbe.until { host.view.layoutSubtreeIfNeeded(); return !lazyNodes(host.view).isEmpty }
        XCTAssertTrue(AXProbe.text(host.view).contains("generation 0"), "The intended template rows are exposed in the product list")
        XCTAssertLessThan(AXProbe.nodes(host.view).count, 3000, "The AX traversal must be complete, not truncated before the far row")
        XCTAssertFalse(AXProbe.text(host.view).contains(absent), "Far rows must still be unrealized before the first AX action")
        func target() throws -> NSObject {
            let nodes = lazyNodes(host.view)
            if nested { XCTAssertGreaterThanOrEqual(nodes.count, 2, "Exercise the conversation's nested lazy stack as well as the outer sections") }
            if innermost {
                return try XCTUnwrap(nodes.first { node in
                    guard let scroll = enclosingScroll(node), let document = scroll.documentView else { return false }
                    return document.frame.height > scroll.contentView.bounds.height + 5
                })
            }
            return try XCTUnwrap(nested ? nodes.last : nodes.first)
        }
        try edges(target())
        for round in 0..<3 {
            if nested { try await revealConversation(host) }
            let stale = try target()
            try await mutate(round)
            try edges(stale) // Retained AX node straddles the published data change.
            try await Task.sleep(nanoseconds: 30_000_000)
            host.view.layoutSubtreeIfNeeded()
            if nested { try await revealConversation(host) }
            try await AXProbe.until {
                host.view.layoutSubtreeIfNeeded()
                return AXProbe.text(host.view).contains("generation \(round + 1)")
            }
            let changedText = AXProbe.text(host.view)
            XCTAssertTrue(changedText.contains("generation \(round + 1)"), "The changed product rows have settled")
            XCTAssertFalse(changedText.contains("\(middleRow) generation \(round + 1)"), "The changed list still has unrealized middle rows before its fresh AX actions")
            try edges(target())
        }
        XCTAssertTrue(AXProbe.text(host.view).contains("generation 3"), "The changed product content is visible after AX actions")
        print("CHANGING LAZY LIST: 7 exact top/bottom pairs; process \(ProcessInfo.processInfo.processIdentifier) alive")
    }
}

@MainActor private final class ChangingListFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("remaining-list-ax-" + UUID().uuidString)
    let preferences: UserDefaults
    let page: Page
    var generation = 0
    var surfaces: [String] = []
    var service: [String: Any] { ["store_incarnation": "changing-list-template", "read_version": "v\(generation)"] }
    var project: [String: Any] { ["id": "p", "name": "Synthetic AX project", "revision": 1] }
    init(page: Page, preferences: UserDefaults) {
        self.page = page
        self.preferences = preferences
        preferences.set(page.rawValue, forKey: "lastPage")
        preferences.set("p", forKey: "lastProject")
    }
    func tasks(_ count: Int) -> [[String: Any]] {
        let ids = generation == 0 ? Array(0..<count) : Array((generation % 2 == 0 ? 10 : 0)..<count).reversed().map { $0 }
        return ids.map { ["id": "ticket-\($0)", "project_id": "p", "record_type": "task", "key": "AX-\($0)", "title": "Ticket \($0) generation \(generation)", "brief": "Synthetic brief generation \(generation)", "status_id": "queued", "status_name": "Queued", "status_category": "queued", "assignee_kind": "human", "revision": generation + 1] }
    }
    var messageCount: Int { generation > 0 && generation % 2 == 0 ? 40 : 50 }
    var selectedTask: [String: Any] {
        tasks(120)[0].merging(["id": "ticket-0", "key": "AX-0", "title": "Ticket 0 generation \(generation)"]) { _, new in new }
    }
    func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if method == "changes_wait" { try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() }
        switch method {
        case "task_list":
            let rows = tasks(120)
            return ["schema_version": 1, "tickets_page": ["query_key": "synthetic", "content_cursor": "c\(generation)", "tasks": rows, "ordinary_ids": rows.map { $0["id"]! }, "triages": [], "scoped_count": rows.count, "matched_count": rows.count, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [project], "statuses": [["id": "queued", "project_id": "p", "name": "Queued", "category": "queued", "sort_order": 0]], "tags": [], "epics": [], "outstanding_request_count": 0, "human_task_count": rows.count, "overview_requests": [], "overview_request_count": 0, "service": service]]
        case "workspace_page":
            let surface = params["surface"] as? String ?? ""
            surfaces.append(surface)
            let rows = surface == "human_tasks" ? tasks(50) : []
            return ["workspace_version": 1, "surface": surface, "record_id": params["record_id"] ?? "", "rows": rows, "total": rows.count, "needs_you_count": 0, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [project], "service": service, "content_cursor": "c\(generation)"]
        case "task_context":
            let task = selectedTask
            let messages: [[String: Any]] = (0..<messageCount).reversed().map { ["id": "message-\($0)", "project_id": "p", "task_id": "ticket-0", "body": "Message \($0) generation \(generation)", "created_at": "2026-10-24T10:00:\(String(format: "%02d", $0))Z"] }
            return ["ui_version": 1, "context_cursor": "context\(generation)", "task": task, "project": project, "service": service, "collections": ["messages": messages, "attachments": [], "attempts": [], "requests": [], "events": [], "sessions": [], "groups": [], "statuses": [], "tags": []], "counts": ["messages": messageCount, "attachments": 0, "attempts": 0, "requests": 0], "full_record_loaded": false, "next_history_cursor": NSNull(), "previous_history_cursor": NSNull(), "has_more_messages": false]
        case "task_get": return selectedTask.merging(["completion_eligibility": ["eligible": false, "task_revision": generation + 1, "manifest_id": NSNull(), "blockers": []]]) { _, new in new }
        case "cleanup_job_list": return ["cleanup_jobs": []]
        case "media_navigation": return ["types": []]
        case "service_info": return service
        default: XCTFail("Unexpected template read \(method)"); throw NSError(domain: "UnexpectedChangingListRead", code: 1)
        }
    }
    func store() -> ChecklistStore {
        ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: ChangingListNoAlerts()), requestTransport: { [self] in try await transport($0, $1) }, navigationMemory: DetailItemNavigationMemory())
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class ChangingListNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected alert") }
    func remove(_ identifiers: [String]) {}
}
