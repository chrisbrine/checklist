import XCTest
import SwiftUI
import AppKit
import ChecklistCore
@testable import ChecklistApp

/// CL-126 R42A2 D1: the HEIR-102 conversation said "5 shown of 5" while the AX
/// dump had 4 rows; the newest Orchestrator only note was missing. Synthetic
/// template records in an offscreen host only: no service, slot or live store.
@MainActor final class TicketConversationRowsTests: XCTestCase {
    /// Three notes whose author, time, digest, routing and recipients collide
    /// keep one row identity each, newest first, whatever their audience.
    func testNotesWithCollidingFieldsKeepOneRowEach() {
        let rows = DeliveryLabels.correlateReplies(TaskDetailView.conversation(TicketConversationFixture.messages.map(Record.init), taskID: "ticket-0"))
        XCTAssertEqual(rows.map(\.id), ["note-3", "note-2", "note-1", "health-2", "health-1"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows.first?.records("deliveries").map(\.id), ["delivery-3"])
    }

    /// The product list renders every note row, including the Orchestrator only
    /// note and its receipt, once that part of the lazy stack is in the viewport.
    func testOrchestratorOnlyNoteRowRendersInTheTicketConversation() async throws {
        let fixture = TicketConversationFixture(preferences: isolatedDefaults("TicketConversationRows").preferences)
        defer { fixture.clean() }
        let store = fixture.store()
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        await store.refresh(quiet: true)
        store.open(.task("ticket-0"))
        try await AXProbe.until { store.selectedTicketCurrent("ticket-0") }
        XCTAssertNil(store.selectedTicketError)
        XCTAssertEqual(store.selectedMessageCount, 5)
        let restore = AXProbe.enableEnhancedUserInterface()
        let view = NSHostingView(rootView: TicketConversationHost(store: store).frame(width: 900, height: 560))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist ticket conversation AX test (offscreen)"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { restore(); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(AXProbe.scrollViews(view).first)
        let wanted = TicketConversationFixture.bodies + ["Orchestrator · Claude thread orch: Queued for agent pickup", "Sent to the Triage orchestrator only; Claude · holder holds AX-0."]
        // Walk the detail from top to bottom, as a reader scrolls; collect each
        // text the lazy stack exposes on the way.
        var seen = Set<String>(), atBottom = "", hiddenNewest = false
        for _ in 0..<60 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
            let text = AXProbe.text(view)
            for item in wanted where text.contains(item) { seen.insert(item) }
            // The runner's dump: the full count and the oldest rows, without the newest row above the viewport.
            if text.contains("Conversation · 5 shown of 5"), text.contains("Work health check 1:"), !text.contains(TicketConversationFixture.bodies[2]) { hiddenNewest = true }
            let clip = scroll.contentView, end = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            if clip.bounds.origin.y >= end { atBottom = text; break }
            clip.scroll(to: NSPoint(x: 0, y: min(end, clip.bounds.origin.y + 80)))
            scroll.reflectScrolledClipView(clip)
        }
        XCTAssertEqual(wanted.filter { !seen.contains($0) }, [], "Every note and the orchestrator receipt render as rows")
        // Record (not assert) what a bottom-only AX dump contains: offscreen rows
        // above the viewport stay lazy, which is what the runner's dump showed.
        print("TicketConversationRows bottom dump contains note 3: \(atBottom.contains(TicketConversationFixture.bodies[2])), note 2: \(atBottom.contains(TicketConversationFixture.bodies[1])), a position hid only the newest rows: \(hiddenNewest)")
    }
}

@MainActor private struct TicketConversationHost: View {
    @ObservedObject var store: ChecklistStore
    var body: some View {
        if let task = store.selectedTask("ticket-0") { TaskDetailView(task: task).environmentObject(store) }
    }
}

@MainActor private final class TicketConversationFixture {
    static let bodies = ["Synthetic note 1, audience Both.", "Synthetic note 2, audience Holder only.", "Synthetic note 3, audience Orchestrator only."]
    /// Chronological, as the selected ticket read returns them. The three owner
    /// notes share author, second, digest, routing and reply fields.
    static var messages: [[String: Any]] {
        func delivery(_ id: String, _ message: String, _ role: String, _ session: String, label: String = "") -> [String: Any] {
            ["id": id, "message_id": message, "project_id": "p", "recipient_role": role, "recipient_session_id": session, "recipient_label": role == "triage_orchestrator" ? "Claude thread orch" : "Claude thread holder", "state": "queued", "push_state": "unavailable", "label": label]
        }
        func note(_ index: Int, audience: String?, deliveries: [[String: Any]]) -> [String: Any] {
            var value: [String: Any] = ["id": "note-\(index)", "project_id": "p", "task_id": "ticket-0", "kind": "note", "origin": "human_ui", "author": "native-app:owner", "author_display": "You", "author_session_id": "human", "body": bodies[index - 1], "created_at": "2026-10-27T23:14:48Z", "content_digest": "same-digest", "ordinary_routing": "handlers", "reply_sender_session_id": "human", "revision": 1, "deliveries": deliveries]
            if let audience { value["audience"] = audience }
            return value
        }
        func health(_ index: Int, _ time: String) -> [String: Any] {
            ["id": "health-\(index)", "project_id": "p", "task_id": "ticket-0", "kind": "note", "origin": "service", "author_display": "Checklist work health", "body": "Work health check \(index): does work continue? " + String(repeating: "Reply to this exact note with current progress or a known wait, or call work_health_respond. ", count: 6), "created_at": time,
             "deliveries": [delivery("health-delivery-\(index)", "health-\(index)", "handler", "holder")]]
        }
        return [health(1, "2026-10-27T22:15:00Z"), health(2, "2026-10-27T23:10:00Z"),
                note(1, audience: nil, deliveries: [delivery("delivery-1a", "note-1", "handler", "holder"), delivery("delivery-1b", "note-1", "triage_orchestrator", "orch", label: "Also sent to Claude · holder, which holds AX-0.")]),
                note(2, audience: "holder", deliveries: [delivery("delivery-2", "note-2", "handler", "holder")]),
                note(3, audience: "orchestrator", deliveries: [delivery("delivery-3", "note-3", "triage_orchestrator", "orch", label: "Sent to the Triage orchestrator only; Claude · holder holds AX-0.")])]
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-conversation-rows-" + UUID().uuidString)
    let preferences: UserDefaults
    var service: [String: Any] { ["store_incarnation": "ticket-conversation-template", "read_version": "v1"] }
    var project: [String: Any] { ["id": "p", "name": "Synthetic conversation project", "revision": 1] }
    var task: [String: Any] { ["id": "ticket-0", "project_id": "p", "record_type": "task", "key": "AX-0", "title": "Synthetic conversation ticket", "brief": "Synthetic brief", "status_id": "queued", "status_name": "Queued", "status_category": "queued", "assignee_kind": "human", "revision": 1] }
    init(preferences: UserDefaults) {
        self.preferences = preferences
        preferences.set(Page.tasks.rawValue, forKey: "lastPage")
        preferences.set("p", forKey: "lastProject")
    }
    func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "changes_wait": try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError()
        case "task_list":
            return ["schema_version": 1, "tickets_page": ["query_key": "synthetic", "content_cursor": "c1", "tasks": [task], "ordinary_ids": ["ticket-0"], "triages": [], "scoped_count": 1, "matched_count": 1, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [project], "statuses": [["id": "queued", "project_id": "p", "name": "Queued", "category": "queued", "sort_order": 0]], "tags": [], "epics": [], "outstanding_request_count": 0, "human_task_count": 1, "overview_requests": [], "overview_request_count": 0, "service": service]]
        case "workspace_page":
            return ["workspace_version": 1, "surface": params["surface"] as? String ?? "", "record_id": params["record_id"] ?? "", "rows": [], "total": 0, "needs_you_count": 0, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [project], "service": service, "content_cursor": "c1"]
        case "task_context":
            return ["ui_version": 1, "context_cursor": "context1", "task": task, "project": project, "service": service, "collections": ["messages": Self.messages, "attachments": [], "attempts": [], "requests": [], "events": [], "sessions": [], "groups": [], "statuses": [], "tags": []], "counts": ["messages": 5, "attachments": 0, "attempts": 0, "requests": 0], "full_record_loaded": false, "next_history_cursor": NSNull(), "previous_history_cursor": NSNull(), "has_more_messages": false]
        case "task_get": return task.merging(["completion_eligibility": ["eligible": false, "task_revision": 1, "manifest_id": NSNull(), "blockers": []]]) { _, new in new }
        case "cleanup_job_list": return ["cleanup_jobs": []]
        case "media_navigation": return ["types": []]
        case "service_info": return service
        default: XCTFail("Unexpected template read \(method)"); throw NSError(domain: "UnexpectedTicketConversationRead", code: 1)
        }
    }
    func store() -> ChecklistStore {
        ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: TicketConversationNoAlerts()), requestTransport: { [self] in try await transport($0, $1) }, navigationMemory: DetailItemNavigationMemory())
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class TicketConversationNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected alert") }
    func remove(_ identifiers: [String]) {}
}
