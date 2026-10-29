import ChecklistTestSupport
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

    /// CL-338: during a known store upgrade every Overview section and group card names the upgrade stage
    /// and estimate, never the reconnect or load-error text; without an upgrade every branch keeps its text.
    func testKnownUpgradeReplacesReconnectAndLoadErrorTextInEveryOverviewBranch() throws {
        let upgrade = try XCTUnwrap(StorageUpgradeStatus(stage: "final_migration", estimatedRemainingSeconds: 90))
        let query = WorkspacePageQuery(surface: "needs_active", project: nil)
        let reply: [String: Any] = ["workspace_version": 1, "needs_you_count": 0, "surface": "needs_active", "record_id": "", "rows": [[String: Any]](), "total": 0, "has_more": false,
                                    "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [[String: Any]](), "service": ["store_incarnation": "s"], "content_cursor": "c"]
        let loading = WorkspacePageObservation(); _ = loading.begin(query)
        let failed = WorkspacePageObservation(); failed.fail(failed.begin(query))
        let loaded = WorkspacePageObservation(); XCTAssertTrue(try loaded.receive(reply, query: query, generation: loaded.begin(query)))
        let stale = WorkspacePageObservation(); XCTAssertTrue(try stale.receive(reply, query: query, generation: stale.begin(query))); stale.fail(stale.begin(query))
        XCTAssertNotNil(stale.page); XCTAssertNotNil(stale.error)
        let generic = ["when Checklist reconnects", "Could not load", "Could not refresh", "Refresh to load"]
        func upgradeText(_ text: String, _ subject: String) {
            XCTAssertEqual(text, subject + " after the upgrade. " + upgrade.summary)
            XCTAssertTrue(text.contains("Applying the verified store migration") && text.contains("about 2 minutes"), text)
            for phrase in generic { XCTAssertFalse(text.contains(phrase), text) }
        }
        let sections: [(String, (SourceState) -> SourcePlaceholder)] = [("Working now loads", WorkingNowStrip.placeholder), ("Review results load", LatestReviewResults.placeholder), ("The digest loads", CompletionDigest.placeholder)]
        for offline in [false, true] {
            for observation in [loading, failed, stale, nil] as [WorkspacePageObservation?] {
                let state = SourceState.of([observation], offline: offline, upgrade: upgrade)
                XCTAssertEqual(state, .upgrading(upgrade), "Every unloaded or failed source names the known upgrade")
                for (subject, placeholder) in sections {
                    guard case .text(let text) = placeholder(state) else { return XCTFail("\(subject): \(placeholder(state))") }
                    upgradeText(text, subject)
                }
                if observation?.page == nil {
                    guard case .text(let text)? = OverviewGroupSection.placeholder(observation, offline: offline, upgrade: upgrade) else { return XCTFail("group card") }
                    upgradeText(text, "This group loads")
                } else {
                    XCTAssertNil(OverviewGroupSection.placeholder(observation, offline: offline, upgrade: upgrade), "Retained rows stay visible under the stale notice")
                }
            }
            XCTAssertEqual(SourceState.of([loaded], offline: offline, upgrade: upgrade), .loaded, "A current page is not hidden by the upgrade")
            XCTAssertNil(OverviewGroupSection.placeholder(loaded, offline: offline, upgrade: upgrade))
        }
        // Rows on screen while another source waits or a refresh failed: the notices name the upgrade too.
        let partial = SourceState.of([loading, loaded], offline: true, upgrade: upgrade)
        XCTAssertEqual(WorkingNowStrip.partialNotice(partial), "Some entries load after the upgrade. " + upgrade.summary)
        XCTAssertEqual(SourceState.of([stale], offline: true, upgrade: upgrade).upgrade, upgrade, "Stale reviews show StaleNotice(upgrade:)")
        XCTAssertEqual(OverviewUpgradeText.stale(upgrade), "Showing the last loaded results. They refresh after the upgrade. " + upgrade.summary)
        // Without an upgrade: a real outage keeps the reconnect text and other failures keep Retry.
        XCTAssertEqual(OverviewGroupSection.placeholder(loading, offline: true, upgrade: nil), .text("This group loads when Checklist reconnects."))
        XCTAssertEqual(OverviewGroupSection.placeholder(loading, offline: false, upgrade: nil), .loading)
        XCTAssertEqual(OverviewGroupSection.placeholder(failed, offline: true, upgrade: nil), .failure("Could not load this page. Refresh to load it again; drafts are kept."))
        XCTAssertEqual(OverviewGroupSection.placeholder(failed, offline: false, upgrade: nil), .failure("Could not load this page. Refresh to load it again; drafts are kept."))
        XCTAssertNil(OverviewGroupSection.placeholder(stale, offline: true, upgrade: nil))
        XCTAssertEqual(SourceState.of([failed], offline: true, upgrade: nil), .offline)
        XCTAssertEqual(SourceState.of([stale], offline: true, upgrade: nil), .stale)
        XCTAssertEqual(WorkingNowStrip.placeholder(.offline), .text("Working now loads when Checklist reconnects."))
        XCTAssertEqual(WorkingNowStrip.placeholder(.failed), .failure("Could not load who is working now."))
        XCTAssertEqual(WorkingNowStrip.placeholder(.stale), .failure("Could not load who is working now."))
        XCTAssertEqual(WorkingNowStrip.placeholder(.loading), .loading)
        XCTAssertEqual(WorkingNowStrip.placeholder(.loaded), .text("No agent is working on a ticket now."))
        XCTAssertEqual(LatestReviewResults.placeholder(.offline), .text("Review results load when Checklist reconnects."))
        XCTAssertEqual(LatestReviewResults.placeholder(.failed), .failure("Could not load the latest review results."))
        XCTAssertEqual(LatestReviewResults.placeholder(.stale), .failure("Could not load the latest review results."))
        XCTAssertEqual(LatestReviewResults.placeholder(.loading), .loading)
        XCTAssertEqual(LatestReviewResults.placeholder(.loaded), .text("No review results yet."))
        XCTAssertEqual(CompletionDigest.placeholder(.offline), .text("The digest loads when Checklist reconnects."))
        XCTAssertEqual(CompletionDigest.placeholder(.failed), .failure("Could not load the completed tickets."))
        XCTAssertEqual(CompletionDigest.placeholder(.stale), .failure("Could not load the completed tickets."))
        XCTAssertEqual(CompletionDigest.placeholder(.loading), .loading)
        XCTAssertEqual(CompletionDigest.placeholder(.loaded), .loading)
        XCTAssertEqual(WorkingNowStrip.partialNotice(.offline), "Some entries load when Checklist reconnects.")
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
        let router = try TestStore.router(root: root), owner = Caller(role: "owner", installation: "overview-fixture", projectIDs: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        func command(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var params = params
            if !CommandReply.readMethods.contains(method) && params["command_id"] == nil { params["command_id"] = UUID().uuidString }
            return try router.handle(method: method, params: appFixtureTaskInput(router,method:method,input:params), caller: owner)
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
