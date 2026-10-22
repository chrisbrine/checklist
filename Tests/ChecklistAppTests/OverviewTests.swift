import XCTest
import ChecklistIPC
@testable import ChecklistApp
@testable import ChecklistCore

/// CL-53, CL-66, CL-67: Overview groups by need, Working now, latest verdicts, digest and Dock badge.
@MainActor final class OverviewTests: XCTestCase {
    func testWorkLinesNameTheAgentAndRecovery() {
        func row(_ work: [String: Any]) -> Record { Record(values: ["id": "t1", "key": "CL-1", "active_work": work]) }
        let ended = OverviewText.work(row(["session_state": "ended", "session_label": "Codex thread 01", "phase": "implementation"]))
        XCTAssertEqual(ended?.needsRecovery, true); XCTAssertEqual(ended?.text, "Codex thread 01 · session ended · recovery needed")
        XCTAssertEqual(OverviewText.work(row(["session_state": "unknown", "provider": "claude"]))?.needsRecovery, true, "An unknown session is not shown as working")
        XCTAssertEqual(OverviewText.work(row(["session_state": "connected", "provider": "codex", "phase": "review", "waiting_for_resource": "shared build"]))?.text,
                       "Codex · review · waiting for shared build")
        let live = OverviewText.work(row(["session_state": "connected", "session_label": "Codex thread 02", "last_checkpoint": "2026-10-20T08:00:00Z"]))
        XCTAssertEqual(live?.needsRecovery, false); XCTAssertTrue(live?.text.hasPrefix("Codex thread 02 · implementation · checkpoint ") == true)
        XCTAssertEqual(OverviewText.work(row(["session_state": "owner"]))?.text.hasPrefix("You · "), true)
        XCTAssertNil(OverviewText.work(Record(values: ["id": "t2"])))
        XCTAssertEqual(OverviewText.verdict("reject"), "Changes needed")
        XCTAssertEqual(OverviewText.byProject([Record(values: ["id": "a", "project_id": "p1"]), Record(values: ["id": "b", "project_id": "p2"]), Record(values: ["id": "c", "project_id": "p1"])]).map { $0.0 }, ["p1", "p2"])
    }

    /// Review findings 310a34a7 and 8d749ea9: a section says loading, failed or offline instead of looking empty.
    func testSectionsDistinguishLoadingFailedOfflineAndEmpty() throws {
        let loading = WorkspacePageObservation(); _ = loading.begin(WorkspacePageQuery(surface: "needs_active", project: nil))
        let failed = WorkspacePageObservation(); failed.fail(failed.begin(WorkspacePageQuery(surface: "needs_quiet", project: nil)))
        XCTAssertEqual(SourceState.of([loading], offline: false), .loading)
        XCTAssertEqual(SourceState.of([failed], offline: false), .failed)
        XCTAssertEqual(SourceState.of([failed], offline: true), .offline)
        XCTAssertEqual(SourceState.of([loading, failed], offline: false), .failed, "A failure is shown even while another source loads")
        // Recheck finding 310a34a7 / 8d749ea9: a refresh that fails over an earlier page is stale, not current.
        let cached = WorkspacePageObservation(), query = WorkspacePageQuery(surface: "recent_reviews", project: nil)
        let reply: [String: Any] = ["workspace_version": 1, "needs_you_count": 0, "surface": "recent_reviews", "record_id": "", "rows": [[String: Any]](), "total": 0, "has_more": false,
                                    "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [[String: Any]](), "service": ["store_incarnation": "s"], "content_cursor": "c"]
        XCTAssertTrue(try cached.receive(reply, query: query, generation: cached.begin(query)))
        XCTAssertEqual(SourceState.of([cached], offline: false), .loaded)
        cached.fail(cached.begin(query))
        XCTAssertNotNil(cached.page, "The earlier rows stay on screen")
        XCTAssertEqual(SourceState.of([cached], offline: false), .stale, "and say that the refresh failed")
        XCTAssertEqual(ChecklistStore.overviewTitle("recent_reviews"), "Latest review results")
        // Recheck finding 310a34a7: one source failed or still loads while another already shows entries.
        let liveRows = WorkspacePageObservation()
        XCTAssertTrue(try liveRows.receive(reply.merging(["surface": "needs_quiet"]) { $1 }, query: WorkspacePageQuery(surface: "needs_quiet", project: nil),
                                           generation: liveRows.begin(WorkspacePageQuery(surface: "needs_quiet", project: nil))))
        let missing = WorkspacePageObservation(); missing.fail(missing.begin(WorkspacePageQuery(surface: "needs_active", project: nil)))
        let partial = SourceState.of([missing, liveRows], offline: false)
        XCTAssertEqual(partial, .failed)
        XCTAssertEqual(WorkingNowStrip.partialNotice(partial), "Could not load all of who is working; some entries may be missing.")
        XCTAssertEqual(WorkingNowStrip.partialNotice(.loading), "Still loading some of who is working.")
        XCTAssertNil(WorkingNowStrip.partialNotice(.loaded))
    }

    /// Review finding 38f2054e: each Overview visit shows completions since the previous visit.
    func testEachVisitStartsTheDigestFromThePreviousVisit() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visit-" + UUID().uuidString)
        let preferences = isolatedDefaults("Visit").preferences
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = Date().addingTimeInterval(-3600); preferences.set(earlier, forKey: "overviewLastVisit")
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OverviewAlertSink()), requestTransport: { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") })
        store.beginOverviewVisit()
        XCTAssertEqual(store.overviewDigestSince, earlier)
        store.beginOverviewVisit()
        XCTAssertEqual(store.overviewDigestSince, earlier, "The start stays while this visit is shown")
        store.endOverviewVisit(); store.beginOverviewVisit()
        XCTAssertGreaterThan(store.overviewDigestSince ?? .distantPast, earlier.addingTimeInterval(3000), "The next visit starts from this one")
    }

    /// The owner's direction (request a6c0bf5d): the badge is on by default and macOS asks for its permission by
    /// itself when a window opens; with the badge switched off, Checklist does not ask.
    func testTheBadgePermissionIsAskedByDefault() async throws {
        let defaults = isolatedDefaults("Badge").preferences
        defaults.set(false, forKey: DockBadge.key)
        await DockBadge.requestPermissionIfNeeded(defaults: defaults)   // returns before macOS is asked
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains(".task { await DockBadge.requestPermissionIfNeeded() }"), "A window asks macOS by itself")
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/AppSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("Allow the Dock count"), "No separate owner button is needed")
        XCTAssertTrue(settings.contains("Open Notifications settings"), "After a declined prompt, Settings says where to allow it")
    }

    func testDockBadgeShowsTheNeedsYouCountAndClearsAtZero() {
        XCTAssertNil(DockBadge.label(count: 0, enabled: true))
        XCTAssertNil(DockBadge.label(count: 4, enabled: false), "The owner can turn the badge off")
        XCTAssertEqual(DockBadge.label(count: 4, enabled: true), "4")
        XCTAssertEqual(DockBadge.label(count: 150, enabled: true), "99+")
    }

    func testOverviewReadsEveryNeedGroupAndShowAllPagesOneGroup() async throws {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let root = cache.appendingPathComponent("overview-" + UUID().uuidString)
        let preferences = isolatedDefaults("Overview").preferences
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try CommandRouter(root: root), owner = Caller(role: "owner", installation: "overview-fixture", projectIDs: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        func command(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var params = params
            if !CommandReply.readMethods.contains(method) && params["command_id"] == nil { params["command_id"] = UUID().uuidString }
            return try router.handle(method: method, params: params, caller: owner)
        }
        let project = try command("project_create", ["name": "A", "key_prefix": "A", "root_path": root.appendingPathComponent("a").path])["data"] as! [String: Any]
        let pid = project["id"] as! String
        let task = try command("task_create", ["project_id": pid, "title": "Owner question target"])["data"] as! [String: Any]
        _ = try command("human_request_create", ["project_id": pid, "task_id": task["id"]!, "title": "Pick a color", "blocking": true,
                                                  "questions": [["id": "q1", "prompt": "Which color?", "type": "text"]]])
        preferences.set(Page.overview.rawValue, forKey: "lastPage")
        var reads: [(String, Int)] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OverviewAlertSink()),
                                   requestTransport: { method, params in
                                       if method == "changes_wait" { try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() }
                                       if method == "workspace_page" { reads.append((params["surface"] as? String ?? "", params["limit"] as? Int ?? 0)) }
                                       return try command(method, params)
                                   })
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        let deadline = Date().addingTimeInterval(10)
        while (store.overviewObservations.values.contains { $0.page == nil } && Date() < deadline) { try await Task.sleep(nanoseconds: 10_000_000) }
        let surfaces = Set(reads.map(\.0))
        XCTAssertEqual(surfaces, ["overview"], "Every group's first page comes from one combined read")
        for need in ["requests", "needs_review", "needs_pickup", "needs_active", "needs_recovery", "needs_quiet", "needs_done_today", "recent_reviews", "completed_since", "human_tasks"] {
            XCTAssertNotNil(store.overviewObservations[need]?.page, need)
        }
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.overviewObservations["requests"]?.page?.total, 1)
        XCTAssertEqual(store.needsCount, 1, "Needs You counts the open request")
        XCTAssertTrue(store.projects.contains { $0.id == pid }, "The sidebar keeps its projects on Overview")
        XCTAssertEqual(store.overviewObservations["needs_review"]?.page?.query.limit, 5, "Each group shows its first rows")
        reads.removeAll()
        store.overviewFocus = "needs_pickup"
        let focusDeadline = Date().addingTimeInterval(5)
        while !reads.contains(where: { $0.0 == "needs_pickup" && $0.1 == 50 }) && Date() < focusDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(reads.contains { $0.0 == "needs_pickup" && $0.1 == 50 }, "Show all pages the one group")
        XCTAssertFalse(reads.contains { $0.0 == "needs_review" }, "Other groups wait while one group is shown in full")
    }
}

@MainActor private final class OverviewAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
