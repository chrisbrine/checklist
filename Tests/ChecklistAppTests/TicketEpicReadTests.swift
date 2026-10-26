import XCTest
import ChecklistIPC
import SwiftUI
import AppKit
@testable import ChecklistApp

/// Screen-return fixtures use transport templates only; no service or database is opened.
@MainActor final class TicketEpicReadTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cached-screen-" + UUID().uuidString)
        let preferences: UserDefaults
        init(_ preferences: UserDefaults) { self.preferences = preferences }
        let surfaces = ChecklistStore.overviewGroups.map(\.surface) + ["human_tasks", "recent_reviews", "completed_since"]
        var version: String? = "fixture-version"
        var catalogMarker = "initial"
        var catalogProjects: [[String: Any]] = [["id": "p"], ["id": "q"]]
        var calls: [(String, [String: Any])] = []
        var hold = false
        var contextError: Error?
        var pending: [(CheckedContinuation<[String: Any], Error>, [String: Any])] = []
        var service: [String: Any] {
            var value: [String: Any] = ["store_incarnation": "fixture-store", "catalog_marker": catalogMarker]
            value["read_version"] = version
            return value
        }
        func task(_ id: String) -> [String: Any] {
            ["id": id, "project_id": "p", "title": "Ticket \(id)", "key": "T-\(id)", "revision": 1]
        }
        func context(_ id: String) -> [String: Any] {
            var collections = Dictionary(uniqueKeysWithValues: ["messages", "attachments", "attempts", "requests", "events", "sessions", "groups", "statuses", "tags"].map { ($0, [[String: Any]]()) })
            collections["messages"] = [["id": "message-\(id)", "project_id": "p", "task_id": id, "text": "Conversation \(id)"]]
            return ["ui_version": 1, "context_cursor": "context-\(id)-\(version ?? "legacy")", "task": task(id), "project": ["id": "p"], "service": service,
                "collections": collections, "counts": ["messages": 1, "attachments": 0, "attempts": 0, "requests": 0], "full_record_loaded": false,
                "next_history_cursor": NSNull(), "previous_history_cursor": NSNull(), "has_more_messages": false]
        }
        func workspace(_ params: [String: Any]) -> [String: Any] {
            let surface = params["surface"] as! String
            if surface == "overview" {
                return ["groups": Dictionary(uniqueKeysWithValues: surfaces.map { name in
                    var query = params; query["surface"] = name
                    return (name, workspace(query))
                }), "service": service, "event_cursor": "covered"]
            }
            return ["workspace_version": 1, "surface": surface, "record_id": "", "rows": [["id": "row-\(surface)", "project_id": params["project_id"] as? String ?? "p"]],
                "total": 1, "needs_you_count": 0, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(),
                "projects": catalogProjects, "service": service, "content_cursor": "covered"]
        }
        func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            if method == "changes_wait" { try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() }
            calls.append((method, params))
            let response: [String: Any]
            switch method {
            case "task_context":
                if let contextError { throw contextError }
                response = context(params["task_id"] as! String)
            case "task_get":
                var value = task(params["task_id"] as! String)
                value["completion_eligibility"] = ["eligible": true, "task_revision": 1, "manifest_id": NSNull(), "blockers": [[String: Any]]()]
                return value
            case "workspace_page": response = workspace(params)
            case "service_info": response = service
            default: XCTFail("Unexpected fake read \(method)"); return [:]
            }
            if hold { return try await withCheckedThrowingContinuation { pending.append(($0, response)) } }
            return response
        }
        func store() -> ChecklistStore {
            preferences.set(Page.overview.rawValue, forKey: "lastPage")
            return ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                desktopAlerts: DesktopAlertCoordinator(sink: EpicReadAlertSink()), requestTransport: { [self] in try await transport($0, $1) }, navigationMemory: DetailItemNavigationMemory())
        }
        func release(_ index: Int) { let (continuation, response) = pending.remove(at: index); continuation.resume(returning: response) }
        func release() { let reads = pending; pending = []; for (continuation, response) in reads { continuation.resume(returning: response) } }
        func cleanup() { for (continuation, _) in pending { continuation.resume(throwing: CancellationError()) }; pending = []; try? FileManager.default.removeItem(at: root) }
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Cached-screen fake did not settle", file: file, line: line); throw CancellationError()
    }
    private struct Host: View {
        @ObservedObject var store: ChecklistStore
        let appeared: () -> Void
        var body: some View {
            Group {
                if case .task(let id) = store.detail, let task = store.selectedTask(id) {
                    TicketEpicSection(task: task).onAppear(perform: appeared)
                } else { Text("No selected ticket") }
            }.environmentObject(store).frame(width: 560, height: 600)
        }
    }
    func testCachedDetailWaitsForCurrentContextBeforeReadingEpicChoices() async throws {
        _ = NSApplication.shared
        let f = Fixture(isolatedDefaults("EpicReadCachedDetail").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
        var appearances = 0
        let host = NSHostingView(rootView: Host(store: store) { appearances += 1 })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        draw()
        try await until { f.calls.contains { $0.0 == "workspace_page" && $0.1["surface"] as? String == "epics" } }
        store.closeDetail(); draw()
        try await Task.sleep(nanoseconds: 500_000_000)
        f.hold = true
        let before = f.calls.filter { $0.0 == "workspace_page" && $0.1["surface"] as? String == "epics" }.count
        store.open(.task("a")); draw()
        try await until { appearances >= 2 && !f.pending.isEmpty }
        // Let the mounted SwiftUI tasks enter their fake transports. This is a
        // behaviour check against held replies, never a latency budget.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(store.selectedTask("a"))
        XCTAssertFalse(store.selectedTicketCurrent("a"))
        XCTAssertEqual(f.calls.filter { $0.0 == "workspace_page" && $0.1["surface"] as? String == "epics" }.count, before,
                       "An auxiliary choice read must not race the cached detail's authoritative refresh")
        f.hold = false; f.release()
        try await until { store.selectedTicketCurrent("a") }
        draw()
        try await until { f.calls.filter { $0.0 == "workspace_page" && $0.1["surface"] as? String == "epics" }.count > before }
    }
    func testAcceptedEpicChoicesSurviveSelectedContextRefreshWithoutAnotherPageRead() async throws {
        _ = NSApplication.shared
        let f = Fixture(isolatedDefaults("EpicReadLiveRefresh").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
        let host = NSHostingView(rootView: Host(store: store) {})
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        func choiceReads() -> Int { f.calls.filter { $0.0 == "workspace_page" && $0.1["surface"] as? String == "epics" }.count }
        draw(); try await until { choiceReads() == 1 }
        // Allow the initial SwiftUI task to install its template page.
        try await Task.sleep(nanoseconds: 30_000_000)
        for version in ["status-commit", "note-commit", "queue-return"] {
            f.version = version; f.hold = true
            store.retrySelectedTicket(); draw()
            try await until { !f.pending.isEmpty }
            XCTAssertFalse(store.selectedTicketCurrent("a"))
            f.hold = false; f.release()
            try await until { store.selectedTicketCurrent("a") }
            draw()
            // Let the hosted .task observe both sides of the held context read.
            // This asserts request behaviour, never an elapsed-time budget.
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(choiceReads(), 1, "An accepted choice page must not amplify ordinary selected-context refreshes")
        }
    }

}
@MainActor private final class EpicReadAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func remove(_ identifiers: [String]) {}
    func send(_ alert: DesktopAlert) async throws { XCTFail("An Epic choice read never sends an alert") }
}
