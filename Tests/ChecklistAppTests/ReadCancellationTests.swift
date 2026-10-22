import XCTest
import ChecklistIPC
@testable import ChecklistApp
@testable import ChecklistCore

@MainActor final class ReadCancellationTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL
        let preferences: UserDefaults
        let router: CommandRouter
        let owner = Caller(role: "owner", installation: "read-cancel", projectIDs: [])
        var project = "", task = "", group = ""
        var hold: ((String, [String: Any]) -> Bool)?
        var held: CheckedContinuation<[String: Any], Error>?
        var reply: [String: Any] = [:]
        var calls: [(String, [String: Any])] = []
        var waitError: Error?
        var readsFail = false
        init(_ preferences: UserDefaults) throws {
            self.preferences = preferences
            root = FileManager.default.temporaryDirectory.appendingPathComponent("read-cancel-" + UUID().uuidString)
            router = try CommandRouter(root: root)
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            project = try command("project_create", ["name": "Synthetic cancellation", "key_prefix": "SC", "root_path": source.path])["data"].flatMap { ($0 as? [String: Any])?["id"] } as! String
            task = try command("task_create", ["project_id": project, "title": "Synthetic ticket"])["data"].flatMap { ($0 as? [String: Any])?["id"] } as! String
            group = try command("epic_create", ["project_id": project, "name": "Synthetic Epic"])["data"].flatMap { ($0 as? [String: Any])?["id"] } as! String
            preferences.set(Page.epics.rawValue, forKey: "lastPage")
        }
        func command(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var p = params
            if !CommandReply.readMethods.contains(method) { p["command_id"] = UUID().uuidString }
            return try router.handle(method: method, params: p, caller: owner)
        }
        func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            calls.append((method, params))
            if hold?(method, params) == true {
                hold = nil
                reply = method == "changes_wait" ? ["changed": true, "event_cursor": "late"] : try command(method, params)
                return try await withCheckedThrowingContinuation { held = $0 }
            }
            if method == "changes_wait" {
                if let waitError { throw waitError }
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw CancellationError()
            }
            if readsFail { throw OfflineBannerTests.Down() }
            return try command(method, params)
        }
        func release(_ error: Error? = nil) {
            guard let held else { return }; self.held = nil
            if let error { held.resume(throwing: error) } else { held.resume(returning: reply) }
        }
        func store() -> ChecklistStore {
            ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false,
                desktopAlerts: DesktopAlertCoordinator(sink: CancellationAlertSink()), requestTransport: { [self] in try await transport($0, $1) })
        }
        func cleanup() { release(); try? FileManager.default.removeItem(at: root) }
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Bounded cancellation fixture did not settle", file: file, line: line)
        throw CancellationError()
    }
    private func health(_ store: ChecklistStore) -> [String] {
        [String(store.connected), String(store.connectionAttempted), store.lastServiceFailure ?? "nil"]
    }
    func testRefreshAndSnapshotCancellationPreserveEveryHealthTuple() async throws {
        for initial in ["unknown", "healthy", "outage"] {
            for snapshot in [false, true] {
                for outcome in ["success", "failure", "cancellation"] {
                    let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
                    let store = f.store()
                    if initial == "healthy" { await store.refresh() }
                    if initial == "outage" { f.readsFail = true; await store.ensureFullSnapshot(); f.readsFail = false }
                    let before = health(store), rows = store.workspaceRows.map(\.id)
                    store.saveNote(f.task, text: "exact unsent é")
                    f.hold = { method, _ in method == (snapshot ? "snapshot" : "workspace_page") }
                    let read = Task { if snapshot { await store.ensureFullSnapshot() } else { await store.refresh() } }
                    try await until { f.held != nil }
                    if outcome != "cancellation" { read.cancel() }
                    f.release(outcome == "success" ? nil : outcome == "failure" ? OfflineBannerTests.Down() as Error : CancellationError())
                    await read.value
                    XCTAssertEqual(health(store), before, "\(initial) / \(snapshot) / \(outcome)")
                    XCTAssertNil(store.error); XCTAssertFalse(store.workspaceLoading)
                    XCTAssertEqual(store.workspaceRows.map(\.id), rows)
                    XCTAssertFalse(store.fullSnapshotAvailable, "A canceled snapshot never installs")
                    XCTAssertEqual(store.noteDrafts[f.task], "exact unsent é")
                    if initial == "unknown" { XCTAssertFalse(store.showsOfflineBanner) }
                    if initial == "outage" { XCTAssertTrue(store.showsOfflineBanner) }
                }
            }
        }
    }
    func testLiveWaitLateRepliesAndErrorsCannotInstallOrRetryAfterCancellation() async throws {
        for failure in [false, true] {
            let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
            let store = f.store()
            f.hold = { method, _ in method == "changes_wait" }
            let live = Task { await store.startLiveUpdates() }
            try await until { f.held != nil }
            let before = health(store), calls = f.calls.count, rows = store.workspaceRows.map(\.id)
            live.cancel(); f.release(failure ? OfflineBannerTests.Down() : nil); await live.value
            XCTAssertEqual(health(store), before); XCTAssertEqual(f.calls.count, calls)
            XCTAssertEqual(store.workspaceRows.map(\.id), rows); XCTAssertNil(store.error)
        }
    }
    func testLiveOrdinaryAndRetryPausesPreserveHealthOnCancellation() async throws {
        for retry in [false, true] {
            let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
            let store = f.store(); store.liveWaitPause = 30_000_000_000; store.liveRetryPause = 30_000_000_000
            f.hold = { method, _ in method == "changes_wait" }
            let live = Task { await store.startLiveUpdates() }
            try await until { f.held != nil }
            f.reply = ["changed": false]
            f.release(retry ? OfflineBannerTests.Down() : nil)
            // Main-actor settling confirms the loop has processed the wait and entered its pause.
            try await Task.sleep(nanoseconds: 30_000_000)
            let before = health(store), calls = f.calls.count
            XCTAssertEqual(store.showsOfflineBanner, retry)
            live.cancel(); await live.value
            XCTAssertEqual(health(store), before); XCTAssertEqual(f.calls.count, calls)
        }
    }
    func testTransportCancellationWhileLiveTaskActiveUsesNormalPacing() async throws {
        let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
        let store = f.store(); store.liveWaitPause = 30_000_000_000
        f.waitError = CancellationError()
        let live = Task { await store.startLiveUpdates() }
        try await until { f.calls.contains { $0.0 == "changes_wait" } }
        let before = health(store)
        for _ in 0..<20 { await Task.yield() }
        live.cancel(); await live.value
        XCTAssertEqual(health(store), before)
        XCTAssertEqual(f.calls.filter { $0.0 == "changes_wait" }.count, 1, "An active-task CancellationError enters the normal pause")
        XCTAssertEqual(f.calls.filter { $0.0 == "workspace_page" }.count, 1, "No outage recovery read")
    }
    func testSelectedPagesAndGroupCatchPathsRetireNeutralCancellation() async throws {
        let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected }
        store.open(.task(f.task)); try await until { store.selectedTicketCurrent(f.task) }
        let before = health(store)
        store.saveNote(f.task, text: "draft survives reads")
        for level in ["ui", "ui_records", "ui_history"] {
            f.hold = { method, params in method == "task_context" && params["detail_level"] as? String == level }
            if level == "ui" { store.retrySelectedTicket() }
            else if level == "ui_records" { store.loadFullSelectedRecord(f.task) }
            else { store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)), family: "manifest") }
            try await until { f.held != nil }; f.release(CancellationError())
            try await until { !store.selectedTicketLoading && !store.selectedRecordsLoading && !store.recordHistoryLoading }
            XCTAssertNil(store.selectedTicketError); XCTAssertNil(store.selectedRecordsError); XCTAssertNil(store.recordHistoryError)
        }
        store.open(.group(f.group)); try await until { store.selectedOther != nil }
        let group = try XCTUnwrap(store.selectedOther)
        for surface in ["record", "epic_tasks", "epic_candidates"] {
            f.hold = { method, params in method == "workspace_page" && params["surface"] as? String == surface }
            if surface == "record" { store.retryOtherDetail() }
            else if surface == "epic_tasks" { store.loadGroupTasks(group, closed: false) }
            else { store.loadGroupCandidates(group, closed: false) }
            try await until { f.held != nil }; f.release(CancellationError())
            try await until { !store.otherDetailLoading && !store.groupTaskLoading && !store.groupCandidateLoading }
            XCTAssertNil(store.otherDetailError); XCTAssertNil(store.groupTaskError); XCTAssertNil(store.groupCandidateError)
            XCTAssertEqual(store.selectedOther?.id, f.group, "Canceled detail refresh keeps the accepted record")
        }
        XCTAssertEqual(health(store), before); XCTAssertEqual(store.noteDrafts[f.task], "draft survives reads")
    }
    func testCanceledOldSelectedAndTicketReadsCannotClearReplacementLoading() async throws {
        let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
        f.preferences.set(Page.tasks.rawValue, forKey: "lastPage")
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected && !store.ticketPageLoading }
        store.open(.task(f.task)); try await until { store.selectedTicketCurrent(f.task) }
        for selected in [false, true] {
            f.hold = { method, params in selected ? method == "task_context" && params["detail_level"] as? String == "ui" : method == "task_list" }
            var oldRead: Task<Void, Never>?
            if selected { store.retrySelectedTicket() } else { oldRead = Task { await store.refresh() } }
            try await until { f.held != nil }
            let old = try XCTUnwrap(f.held); f.held = nil
            f.hold = { method, params in selected ? method == "task_context" && params["detail_level"] as? String == "ui" : method == "task_list" }
            var newRead: Task<Void, Never>?
            if selected { store.retrySelectedTicket() } else {
                oldRead?.cancel()
                newRead = Task { await store.refresh() }
            }
            try await until { f.held != nil }
            old.resume(throwing: OfflineBannerTests.Down())
            await oldRead?.value
            // Let the canceled selected task catch while its replacement remains in transport.
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(selected ? store.selectedTicketLoading : store.ticketPageLoading)
            XCTAssertNil(selected ? store.selectedTicketError : store.ticketPageError)
            f.release(); await newRead?.value
            try await until { selected ? store.selectedTicketCurrent(f.task) : !store.ticketPageLoading }
        }
    }

    func testTicketAndOverviewCatchPathsRetainAcceptedPages() async throws {
        let f = try Fixture(isolatedDefaults("ReadCancellation").preferences); defer { f.cleanup() }
        f.preferences.set(Page.tasks.rawValue, forKey: "lastPage")
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.connected && !store.ticketPageLoading }
        let count = store.ticketPageShownCount, before = health(store)
        f.hold = { method, _ in method == "task_list" }
        let read = Task { await store.refresh() }
        try await until { f.held != nil }; f.release(CancellationError()); await read.value
        XCTAssertFalse(store.ticketPageLoading); XCTAssertNil(store.ticketPageError); XCTAssertEqual(store.ticketPageShownCount, count)
        store.select(.overview, project: nil)
        try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        for focused in [false, true] {
            if focused {
                let calls = f.calls.count
                store.overviewFocus = "requests"
                try await until { f.calls.count > calls && store.overviewObservations.values.allSatisfy { !$0.loading } }
            }
            f.hold = { method, _ in method == "workspace_page" }
            let refresh = Task { await store.refresh() }
            try await until { f.held != nil }; f.release(CancellationError()); await refresh.value
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading && $0.error == nil && $0.page != nil })
        }
        XCTAssertEqual(health(store), before)
    }
}

@MainActor private final class CancellationAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Read cancellation must not alert") }
    func remove(_ identifiers: [String]) {}
}
