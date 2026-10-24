import XCTest
import SwiftUI
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
            return try router.handle(method: method, params: appFixtureTaskInput(router,method:method,input:p), caller: owner)
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
    func testIndependentSettingsReadsSurviveScreenCacheInvalidation() async throws {
        for method in ["storage_status", "restore_preview", "ticket_cleanup_receipts"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var held: CheckedContinuation<[String:Any],Error>?
            let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root), preferences:isolatedDefaults("IndependentSettingsReads").preferences, restorePendingCommand:false,
                desktopAlerts:DesktopAlertCoordinator(sink:CancellationAlertSink()), requestTransport: { _, _ in
                    try await withCheckedThrowingContinuation { held = $0 }
                })
            var current = true
            let read = Task { try await store.request(method, ifCurrent:{ current }) }
            try await until { held != nil }
            store.data = ["service":["store_incarnation":"new-screen-generation"]]
            held?.resume(returning:["accepted":method])
            do {
                let reply = try await read.value
                XCTAssertEqual(reply["accepted"] as? String,method)
            } catch { XCTFail("An unrelated screen invalidation cancelled \(method): \(error)") }
            current = false
        }
    }

    func testSupersededSettingsReplyIsRejectedBeforeItCanAffectContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var held: CheckedContinuation<[String:Any],Error>?
        let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root), preferences:isolatedDefaults("SupersededSettingsRead").preferences, restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:CancellationAlertSink()), requestTransport:{ _, _ in
                try await withCheckedThrowingContinuation { held = $0 }
            })
        var current = true
        let read = Task { try await store.request("storage_status",ifCurrent:{ current }) }
        try await until { held != nil };current = false
        held?.resume(returning:["accepted":"obsolete"])
        do { _ = try await read.value;XCTFail("Superseded settings reply must be retired") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    /// CL-224: use actual readers and a mounted sidebar, including refreshes that
    /// retain an existing page. An idle changes_wait must never keep the spinner on.
    func testFooterReplacesOnlyRefreshForInitialAndManualPageLoads() async throws {
        for page in [Page.tasks, .archived, .overview, .needsYou, .epics, .activity] {
            let f = try Fixture(isolatedDefaults("FooterLoads").preferences); defer { f.cleanup() }
            f.preferences.set(page.rawValue, forKey: "lastPage")
            let method = [Page.tasks, .archived].contains(page) ? "task_list" : "workspace_page"
            f.hold = { name, _ in name == method }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            let host = NSHostingView(rootView: SidebarView().environmentObject(store).defaultAppStorage(f.preferences).frame(width: 224, height: 700))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 224, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Synthetic Checklist held-load footer (offscreen)"
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await until { f.held != nil }
            try await assertFooter(host, loading: true, context: "initial \(page)")
            f.release()
            try await until { f.calls.contains { $0.0 == "changes_wait" } }
            try await assertFooter(host, loading: false, context: "idle \(page)")
            for quiet in [false, true] {
                f.hold = { name, _ in name == method }
                let refresh = Task { await store.refresh(quiet: quiet) } // Cmd-R uses the default false.
                try await until { f.held != nil }
                try await assertFooter(host, loading: true, context: "refresh \(page), quiet=\(quiet)")
                f.release(); await refresh.value
                try await assertFooter(host, loading: false, context: "settled \(page), quiet=\(quiet)")
            }
        }
    }
    func testFooterRestoresRefreshAfterPageFailureOrCancellation() async throws {
        for page in [Page.tasks, .overview, .needsYou] {
            for failure in [OfflineBannerTests.Down() as Error, CancellationError()] {
                let f = try Fixture(isolatedDefaults("FooterReadEnd").preferences); defer { f.cleanup() }
                f.preferences.set(page.rawValue, forKey: "lastPage")
                let store = f.store(), live = Task { await store.startLiveUpdates() }
                defer { live.cancel(); store.stopWindowReads() }
                try await until { f.calls.contains { $0.0 == "changes_wait" } }
                let host = NSHostingView(rootView: SidebarView().environmentObject(store).defaultAppStorage(f.preferences).frame(width: 224, height: 700))
                let method = page == .tasks ? "task_list" : "workspace_page"
                f.hold = { name, _ in name == method }
                let refresh = Task { await store.refresh() }
                try await until { f.held != nil }
                try await assertFooter(host, loading: true, context: "held \(page) \(failure)")
                f.release(failure); await refresh.value
                try await assertFooter(host, loading: false, context: "ended \(page) \(failure)")
            }
        }
    }
    func testFooterIgnoresUnfinishedReadsAfterLeavingTheirPage() async throws {
        for initial in [Page.tasks, .needsYou] {
            let f = try Fixture(isolatedDefaults("FooterOffscreenRead").preferences); defer { f.cleanup() }
            f.preferences.set(initial.rawValue, forKey: "lastPage")
            f.hold = { name, _ in name == (initial == .tasks ? "task_list" : "workspace_page") }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            let host = NSHostingView(rootView: SidebarView().environmentObject(store).defaultAppStorage(f.preferences).frame(width: 224, height: 700))
            try await until { f.held != nil }
            try await assertFooter(host, loading: true, context: "before navigation \(initial)")
            store.select(initial == .tasks ? .needsYou : .tasks)
            try await until { initial == .tasks ? store.workspacePageLoaded && !store.workspaceLoading : store.preparedTicketWorkspace != nil && !store.ticketPageLoading }
            XCTAssertNotNil(f.held, "The obsolete request is deliberately still pending")
            try await assertFooter(host, loading: false, context: "after navigation \(initial)")
            f.release()
        }
    }
    func testFooterTracksMediaRefreshOnlyWhenMediaIsVisible() async throws {
        for visible in [false, true] {
            let f = try Fixture(isolatedDefaults("FooterMediaLoad").preferences); defer { f.cleanup() }
            f.preferences.set(Page.tasks.rawValue, forKey: "lastPage")
            f.preferences.set(f.project, forKey: "lastProject")
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { f.calls.contains { $0.0 == "changes_wait" } }
            if visible {
                store.select(.media, project: f.project)
                try await until { store.workspacePageLoaded && !store.workspaceLoading }
            }
            let host = NSHostingView(rootView: SidebarView().environmentObject(store).defaultAppStorage(f.preferences).frame(width: 224, height: 700))
            f.hold = { name, _ in name == "media_navigation" }
            let media = Task { await store.mediaReview.connect(store: store) }
            try await until { f.held != nil }
            try await assertFooter(host, loading: visible, context: "held media, visible=\(visible)")
            f.release(); await media.value
            try await until { !store.ticketPageLoading && !store.workspaceLoading }
            try await assertFooter(host, loading: false, context: "settled media, visible=\(visible)")
        }
    }
    private func assertFooter(_ host: NSView, loading: Bool, context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes(_ object: NSObject, depth: Int = 0) -> [NSObject] {
            guard depth < 30 else { return [] }
            return [object] + (attribute(object, "accessibilityChildren") as? [NSObject] ?? []).flatMap { nodes($0, depth: depth + 1) }
        }
        let elements = nodes(host)
        let buttons = elements.filter { attribute($0, "accessibilityRole") as? String == "AXButton" }
        let labels = buttons.compactMap { attribute($0, "accessibilityLabel") as? String }
        XCTAssertEqual(labels.contains("Refresh service"), !loading, context, file: file, line: line)
        XCTAssertTrue(labels.contains("Checklist Settings"), context, file: file, line: line)
        func progressViews(_ view: NSView) -> [NSProgressIndicator] {
            (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap { progressViews($0) }
        }
        XCTAssertEqual(!progressViews(host).isEmpty, loading, context, file: file, line: line)
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
