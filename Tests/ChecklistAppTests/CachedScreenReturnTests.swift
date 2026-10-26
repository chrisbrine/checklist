import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// Screen-return fixtures use transport templates only; no service or database is opened.
@MainActor final class CachedScreenReturnTests: XCTestCase {
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
                desktopAlerts: DesktopAlertCoordinator(sink: CachedScreenAlertSink()), requestTransport: { [self] in try await transport($0, $1) }, navigationMemory: DetailItemNavigationMemory())
        }
        func release(_ index: Int) { let (continuation, response) = pending.remove(at: index); continuation.resume(returning: fixtureReply(response)) }
        func release() { let reads = pending; pending = []; for (continuation, response) in reads { continuation.resume(returning: fixtureReply(response)) } }
        func cleanup() { for (continuation, _) in pending { continuation.resume(throwing: CancellationError()) }; pending = []; try? FileManager.default.removeItem(at: root) }
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Cached-screen fake did not settle", file: file, line: line); throw CancellationError()
    }
    func testTicketReturnRestoresConversationBeforeAnyBackgroundRead() async throws {
        let f = Fixture(isolatedDefaults("CachedScreenReturn").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
        let message = store.detailRecords("messages", task: try XCTUnwrap(store.selectedTask("a"))).map(\.id)
        store.closeDetail(); f.hold = true
        let before = f.calls.count
        store.open(.task("a"))
        XCTAssertEqual(f.calls.count, before, "Rendering cached content must not require a service round trip")
        let cached = store.selectedTask("a")
        XCTAssertNotNil(cached, "Reopening a loaded ticket must synchronously restore its display")
        XCTAssertFalse(store.selectedTicketCurrent("a"), "A cached display does not establish fresh read authority")
        XCTAssertFalse(store.selectedRecordsCurrent)
        if let cached { XCTAssertEqual(store.detailRecords("messages", task: cached).map(\.id), message) }
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.selectedTicketCurrent("a") }
    }
    func testOverviewReturnRestoresMatchingGroupsBeforeAnyBackgroundRead() async throws {
        let f = Fixture(isolatedDefaults("CachedScreenReturn").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        let prior = store.overviewObservations.mapValues { $0.rows.map(\.id) }
        store.endOverviewVisit(); f.catalogMarker = "newer-metadata"; store.select(.epics, project: "p")
        try await until { store.workspacePageLoaded && !store.workspaceLoading }
        f.hold = true
        let before = f.calls.count
        store.select(.overview)
        XCTAssertEqual(f.calls.count, before)
        XCTAssertEqual(store.service.string("catalog_marker"), "newer-metadata", "Cached page restoration must not replay older shared metadata")
        for surface in f.surfaces where surface != "completed_since" {
            XCTAssertEqual(store.overviewObservations[surface]?.rows.map(\.id), prior[surface], surface)
        }
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
    }
    func testEachTicketRestoresItsOwnCachedConversation() async throws {
        let f = Fixture(isolatedDefaults("CacheTicketIdentity").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        for id in ["a", "b"] { store.open(.task(id)); try await until { store.selectedTicketCurrent(id) } }
        f.hold = true
        let before = f.calls.count
        store.goBack()
        XCTAssertEqual(f.calls.count, before)
        let task = try XCTUnwrap(store.selectedTask("a"))
        XCTAssertEqual(store.detailRecords("messages", task: task).map(\.id), ["message-a"])
        XCTAssertNil(store.selectedTask("b"))
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.selectedTicketCurrent("a") }
    }
    func testKnownDataOrGrantVersionAndMissingIdentityRetireCachedDetails() async throws {
        for version: String? in ["committed-version", "new-grant-version", nil] {
            let f = Fixture(isolatedDefaults("CacheVersionFence").preferences); defer { f.cleanup() }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { store.connected }
            store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
            store.closeDetail(); f.version = version
            _ = try await store.request("service_info")
            f.hold = true
            store.open(.task("a"))
            XCTAssertNil(store.selectedTask("a"), "Known data/grant changes or missing identity retire the prior display")
            try await until { !f.pending.isEmpty }; f.hold = false; f.release()
            try await until { store.selectedTicketCurrent("a") }
        }
    }
    func testTicketDisplayCacheDoesNotCrossProjectSelectionScope() async throws {
        let f = Fixture(isolatedDefaults("CacheProjectScope").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
        store.closeDetail(); store.select(.epics, project: "p")
        try await until { store.workspacePageLoaded && !store.workspaceLoading }
        f.hold = true; store.open(.task("a"))
        XCTAssertNil(store.selectedTask("a"), "The all-projects cache cannot authorize another selection scope")
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.selectedTicketCurrent("a") }
        store.closeDetail()
        let before = f.calls.count; store.open(.task("a"))
        XCTAssertEqual(f.calls.count, before); XCTAssertNotNil(store.selectedTask("a"))
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.selectedTicketCurrent("a") }
    }
    func testUnversionedAndObsoleteRepliesCannotPopulateTheDetailCache() async throws {
        for obsolete in [false, true] {
            let f = Fixture(isolatedDefaults("CacheReplyOwnership").preferences); defer { f.cleanup() }
            if !obsolete { f.version = nil }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { store.connected }
            if obsolete {
                f.hold = true; store.open(.task("a"))
                try await until { f.pending.count == 1 }
                store.open(.task("b")); try await until { f.pending.count == 2 }
                f.release(0); f.release(0)
                try await until { store.selectedTicketCurrent("b") }
            } else {
                store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
            }
            store.closeDetail(); f.hold = true; store.open(.task("a"))
            XCTAssertNil(store.selectedTask("a"))
            try await until { !f.pending.isEmpty }; f.release()
            try await until { store.selectedTicketCurrent("a") }
        }
    }
    func testKnownCoverageChangeRetiresOffscreenConversation() async throws {
        let f = Fixture(isolatedDefaults("CacheCoverage").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
        store.closeDetail()
        await store.applyChangeCoverage(["event_cursor": "after-commit", "coverage": ["schema_version": 2, "complete": true, "reset": false,
            "changes": [["project_id": "p", "families": ["messages"], "task_ids": ["a"], "all_tasks": false]]]])
        f.hold = true; store.open(.task("a"))
        XCTAssertNil(store.selectedTask("a"))
        try await until { !f.pending.isEmpty }; f.release()
        try await until { store.selectedTicketCurrent("a") }
    }

    func testDefiniteMissingOrDeniedReadRetiresCachedConversation() async throws {
        for code in ["NOT_FOUND", "FORBIDDEN", "DENIED"] {
            let f = Fixture(isolatedDefaults("CacheDefiniteFailure").preferences); defer { f.cleanup() }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { store.connected }
            store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
            store.closeDetail(); f.contextError = ChecklistError(code, "Synthetic inaccessible ticket")
            store.open(.task("a")); XCTAssertNotNil(store.selectedTask("a"))
            try await until { store.selectedTicketError != nil }
            XCTAssertNil(store.selectedTask("a"), "A definite absence or scope denial retires the cached display")
            store.closeDetail(); f.contextError = nil; f.hold = true
            store.open(.task("a")); XCTAssertNil(store.selectedTask("a"))
            try await until { !f.pending.isEmpty }; f.release()
            try await until { store.selectedTicketCurrent("a") }
        }
    }

    func testKnownVersionOrCoverageRetiresRestoredDetailBeforeItsRefreshReply() async throws {
        for coverage in [false, true] {
            let f = Fixture(isolatedDefaults("CacheVisibleVersion").preferences); defer { f.cleanup() }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { store.connected }
            store.open(.task("a")); try await until { store.selectedTicketCurrent("a") }
            store.closeDetail(); f.hold = true; store.open(.task("a"))
            XCTAssertNotNil(store.selectedTask("a"))
            try await until { f.pending.count == 1 }
            f.version = "newly-known-commit"
            let commit = Task {
                if coverage {
                    await store.applyChangeCoverage(["event_cursor": "new-coverage", "coverage": ["schema_version": 2, "complete": true, "reset": false,
                        "changes": [["project_id": "p", "families": ["messages"], "task_ids": ["a"], "all_tasks": false]]]])
                } else { _ = try await store.request("service_info") }
            }
            // Coverage starts the visible page and selected detail in parallel.
            try await until { f.pending.count >= 2 }
            if !coverage { f.release(1); try await commit.value }
            XCTAssertNil(store.selectedTask("a"), "A known commit retires visible cached content before any replacement reply")
            f.hold = false; f.release(); try await commit.value
            try await until { store.selectedTicketCurrent("a") }
        }
    }
    func testTemplateCatalogOverviewReturnNeedsNoReadOrCatalogReplay() async throws {
        let f = Fixture(isolatedDefaults("CacheTemplateTiming").preferences); defer { f.cleanup() }
        let template = String(repeating: "Synthetic project instructions. ", count: 128)
        f.catalogProjects += (0..<64).map { ["id": "template-\($0)", "name": "Template \($0)", "instructions": template] }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        var samples: [Double] = []
        for _ in 0..<5 {
            store.endOverviewVisit(); store.select(.epics, project: "p")
            try await until { store.workspacePageLoaded && !store.workspaceLoading }
            f.hold = true
            let calls = f.calls.count, start = ProcessInfo.processInfo.systemUptime
            store.select(.overview)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(f.calls.count, calls)
            XCTAssertNotNil(store.overviewObservations["needs_pickup"]?.page)
            try await until { !f.pending.isEmpty }; f.hold = false; f.release()
            try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        }
        print("P9-r4 template catalog=66 projects cached_overview_return_ms=\(samples)")
        XCTAssertTrue(samples.allSatisfy { $0 < 300 }, "Model return must restore content before the background transport runs")
    }

}

@MainActor private final class CachedScreenAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("A cached read never sends an alert") }
    func remove(_ identifiers: [String]) {}
}
