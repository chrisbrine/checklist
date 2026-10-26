import XCTest
import ChecklistIPC
@testable import ChecklistApp
@testable import ChecklistCore

/// CL-177: deterministic deadlines and late replies, without waiting thirty seconds or using a live store.
@MainActor final class OverviewReadRecoveryTests: XCTestCase {
    private let surfaces = ["completed_since", "human_tasks", "needs_active", "needs_done_today", "needs_pickup", "needs_quiet", "needs_recovery", "needs_review", "recent_reviews", "requests"]
    @MainActor private final class Fixture {
        struct Call {
            let params: [String: Any]
            var surface: String { params["surface"] as? String ?? "" }
        }
        struct Held {
            let call: Call
            let continuation: CheckedContinuation<[String: Any], Error>
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overview-recovery-" + UUID().uuidString)
        let preferences: UserDefaults
        var calls: [Call] = [], held: [Held] = []
        var waitCursors: [String?] = []
        var holdNextWait = false
        var heldWait: CheckedContinuation<[String: Any], Error>?
        var hold = false, combinedError: Error?, failingSurface: String?
        var readVersion = "overview-fixture"
        var active = 0, maximumActive = 0
        init(_ preferences: UserDefaults) { self.preferences = preferences; preferences.set(Page.overview.rawValue, forKey: "lastPage") }
        func page(_ params: [String: Any]) -> [String: Any] {
            let surface = params["surface"] as! String, project = params["project_id"] as? String ?? "p"
            let suffix = params["cursor"] as? String ?? params["since"] as? String ?? "first"
            return ["workspace_version": 1, "surface": surface, "record_id": "", "rows": [["id": "\(project)-\(surface)-\(suffix)", "project_id": project]],
                    "total": 37, "needs_you_count": 91, "has_more": true, "next_cursor": "next-\(surface)", "previous_cursor": NSNull(),
                    "projects": [["id": "p"], ["id": "q"]], "service": ["store_incarnation": "store", "read_version": readVersion], "content_cursor": "content-\(surface)"]
        }
        func reply(_ call: Call) -> [String: Any] {
            if call.surface != "overview" { return page(call.params) }
            var groups: [String: [String: Any]] = [:]
            for surface in ["completed_since", "human_tasks", "needs_active", "needs_done_today", "needs_pickup", "needs_quiet", "needs_recovery", "needs_review", "recent_reviews", "requests"] {
                var params = call.params; params["surface"] = surface
                if surface != "completed_since" { params.removeValue(forKey: "since") }
                groups[surface] = page(params)
            }
            return ["groups": groups, "service": ["store_incarnation":"store", "read_version":readVersion], "event_cursor": "combined-coverage"]
        }
        func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            if method == "changes_wait" {
                waitCursors.append(params["cursor"] as? String)
                if holdNextWait {
                    holdNextWait = false
                    return try await withCheckedThrowingContinuation { heldWait = $0 }
                }
                try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError()
            }
            if method == "project_list" { return ["projects": [["id": "p"], ["id": "q"]]] }
            XCTAssertEqual(method, "workspace_page")
            let call = Call(params: params); calls.append(call)
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if hold { return try await withCheckedThrowingContinuation { held.append(Held(call: call, continuation: $0)) } }
            if call.surface == "overview", let combinedError { throw combinedError }
            if call.surface == failingSurface { throw ChecklistError("DENIED", "Synthetic surface denied") }
            return reply(call)
        }
        func release(_ index: Int = 0, error: Error? = nil) {
            let read = held.remove(at: index)
            if let error { read.continuation.resume(throwing: error) }
            else { read.continuation.resume(returning: fixtureReply(reply(read.call))) }
        }
        func store() -> ChecklistStore {
            ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                desktopAlerts: DesktopAlertCoordinator(sink: RecoveryAlertSink()), requestTransport: { [self] in try await transport($0, $1) })
        }
        func releaseWait(error: Error) {
            let wait = heldWait; heldWait = nil; wait?.resume(throwing: error)
        }
        func cleanup() { releaseWait(error: CancellationError()); while !held.isEmpty { release(error: CancellationError()) }; try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() -> Fixture { Fixture(isolatedDefaults("OverviewRecovery").preferences) }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Overview fixture did not settle", file: file, line: line); throw CancellationError()
    }
    private var timeout: Error { CommandReply.unknown(commandID: nil, reason: "reply_timeout") }
    private func drain(_ f: Fixture, store: ChecklistStore) async throws {
        for _ in 0..<20 {
            if f.held.isEmpty && store.overviewObservations.values.allSatisfy({ !$0.loading }) { return }
            try await until { !f.held.isEmpty || store.overviewObservations.values.allSatisfy { !$0.loading } }
            if !f.held.isEmpty { f.release() }
            await Task.yield()
        }
        XCTFail("More than the bounded ten surface reads")
    }
    func testWatchdogDefersCombinedOverviewThroughTimeoutAndSequentialFallback() async throws {
        let f = fixture(); f.hold = true
        let store = f.store()
        var now: TimeInterval = 1802.7
        store.liveNow = { now }
        var notices: [String] = []
        store.overviewLoadLog = { notices.append($0) }
        // Unknown coverage owns a full combined read, as initial navigation does.
        let read = Task { await store.applyChangeCoverage(["event_cursor":"held-coverage"]) }
        defer { read.cancel(); store.stopWindowReads(); f.cleanup() }
        try await until { f.held.count == 1 }
        XCTAssertEqual(f.calls.map(\.surface), ["overview"])
        now += 1.5
        var tickFinished = false
        let tick = Task { await store.checkLiveFreshness(selected:false); tickFinished = true }
        defer { tick.cancel() }
        try await until { tickFinished || f.calls.count > 1 }
        XCTAssertEqual(f.calls.count, 1, "The watchdog must preserve the current combined request")
        XCTAssertTrue(tickFinished, "Deferral returns without awaiting the held transport")
        guard tickFinished, f.calls.count == 1 else { return }
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.loading && $0.error == nil })

        now += 28.5 // The transport now supplies its typed 30-second timeout.
        f.release(error:timeout)
        try await until { f.held.count == 1 }
        XCTAssertEqual(f.calls.map(\.surface), ["overview",surfaces[0]])
        // The service remains stopped until 40 seconds. Do not restart the
        // first fallback attempt (or turn the fallback into concurrent lanes).
        now += 10
        tickFinished = false
        let fallbackTick = Task { await store.checkLiveFreshness(selected:false); tickFinished = true }
        defer { fallbackTick.cancel() }
        try await until { tickFinished || f.calls.count > 2 }
        XCTAssertTrue(tickFinished)
        XCTAssertEqual(f.calls.count, 2)
        guard tickFinished, f.calls.count == 2 else { return }
        for (index,surface) in surfaces.enumerated() {
            try await until { f.held.count == 1 }
            XCTAssertEqual(f.held[0].call.surface, surface)
            f.release()
            try await until { store.overviewObservations[surface]?.page != nil }
            XCTAssertEqual(store.overviewObservations[surface]?.page?.total, 37)
            XCTAssertEqual(store.overviewObservations[surface]?.rows.count, 1)
            XCTAssertEqual(f.calls.count, min(index + 3, 11))
        }
        let accepted = await read.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(f.maximumActive, 1)
        XCTAssertEqual(f.calls.map(\.surface), ["overview"] + surfaces)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading && $0.error == nil })
        XCTAssertEqual(notices.filter { $0.hasPrefix("combined ") }.count, 1)
        XCTAssertTrue(notices[0].contains("request=1") && notices[0].contains("outcome=timeout"))
        let attempts = notices.filter { $0.hasPrefix("attempt ") }
        XCTAssertEqual(attempts.count, 10)
        for (line,surface) in zip(attempts,surfaces) {
            XCTAssertTrue(line.contains("surface=\(surface) attempt=1 mode=fallback outcome=installed rows=1 total=37"))
        }
        XCTAssertTrue(notices.last?.contains("outcome=complete attempts=10 installed=10 failed=0") == true)
    }

    func testCachedOverviewReturnRestoresMatchingGroupsSynchronously() async throws {
        let f = fixture(); defer { f.cleanup() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        let original = store.overviewObservations["needs_pickup"]!.rows.map(\.id)
        store.select(.overview, project:"q")
        try await until { store.overviewObservations["needs_pickup"]?.page?.query.project == "q" }
        f.hold = true
        let start = ProcessInfo.processInfo.systemUptime
        store.select(.overview)
        XCTAssertEqual(store.overviewObservations["needs_pickup"]!.rows.map(\.id), original)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
        try await drain(f, store:store)
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 3)
    }

    func testNativeAppearanceDoesNotReplaceCombinedFastPathWithTenSingles() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }
        store.beginOverviewVisit() // SwiftUI onAppear follows the initial loader.
        await Task.yield()
        while !f.held.isEmpty { f.release(); await Task.yield() }
        try await until { store.overviewObservations.values.allSatisfy { !$0.loading } }
        XCTAssertEqual(f.calls.map(\.surface), ["overview"])
    }

    func testFastCombinedReadKeepsTenExactPagesAndOneRequest() async throws {
        let f = fixture(); defer { f.cleanup() }; let store = f.store()
        await store.refresh()
        XCTAssertEqual(f.calls.map(\.surface), ["overview"])
        for surface in surfaces {
            let page = try XCTUnwrap(store.overviewObservations[surface]?.page)
            var params = f.calls[0].params; params["surface"] = surface
            if surface != "completed_since" { params.removeValue(forKey: "since") }
            let expected = f.page(params)
            XCTAssertEqual(page.rows.map(\.id), (expected["rows"] as! [[String: String]]).map { $0["id"]! })
            XCTAssertEqual(page.total, 37); XCTAssertEqual(page.next, "next-\(surface)")
            XCTAssertEqual(page.query.limit, surface == "human_tasks" ? 1 : surface == "recent_reviews" ? 60 : surface == "completed_since" ? 20 : 5)
        }
        XCTAssertEqual(store.needsCount, 91, "Global sidebar count is never an Overview group total")

    }
    /// Parses OverviewLoad notices ("kind key=value ...") of one kind.
    private func notices(_ logs: [String], _ kind: String) -> [[String: String]] {
        logs.filter { $0.hasPrefix(kind + " ") }.map { line in
            Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst().map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1); return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            })
        }
    }
    func testTimeoutNoticesShowOneCombinedRequestAndOneSequentialAttemptPerDueSurface() async throws {
        let f = fixture(); defer { f.cleanup() }; f.combinedError = timeout; let store = f.store()
        var logs: [String] = []; store.overviewLoadLog = { logs.append($0) }
        await store.refresh()
        let combined = notices(logs, "combined"), attempts = notices(logs, "attempt"), settled = notices(logs, "fallback_settled")
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?["outcome"], "timeout"); XCTAssertEqual(combined.first?["request"], "1"); XCTAssertEqual(combined.first?["surfaces"], "10")
        XCTAssertEqual(attempts.map { $0["surface"] ?? "" }, surfaces, "Exactly one sequential attempt per due surface")
        for attempt in attempts {
            XCTAssertEqual(attempt["visit"], combined.first?["visit"]); XCTAssertEqual(attempt["attempt"], "1"); XCTAssertEqual(attempt["mode"], "fallback")
            XCTAssertEqual(attempt["outcome"], "installed"); XCTAssertEqual(attempt["rows"], "1"); XCTAssertEqual(attempt["total"], "37")
        }
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?["outcome"], "complete"); XCTAssertEqual(settled.first?["attempts"], "10")
        XCTAssertEqual(settled.first?["installed"], "10"); XCTAssertEqual(settled.first?["failed"], "0")
        XCTAssertEqual(logs.count, 12); XCTAssertTrue(logs.first?.hasPrefix("combined ") == true); XCTAssertTrue(logs.last?.hasPrefix("fallback_settled ") == true)
        XCTAssertEqual(f.calls.map(\.surface), ["overview"] + surfaces, "Notices match the transport calls")
        XCTAssertFalse(logs.joined().contains("-first") || logs.joined().contains("p-"), "Notices are content-free")
        // A later refresh in the same visit stays sequential: second attempts, never a second combined request.
        logs = []; await store.refresh()
        XCTAssertEqual(notices(logs, "combined").count, 0)
        XCTAssertEqual(notices(logs, "attempt").map { $0["attempt"] ?? "" }, Array(repeating: "2", count: surfaces.count))
        XCTAssertEqual(notices(logs, "fallback_settled").map { $0["outcome"] ?? "" }, ["complete"])
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 1)
    }
    func testFastCombinedNoticeIsOneRequestWithoutFallbackAndOtherOutcomesStartNone() async throws {
        let f = fixture(); defer { f.cleanup() }; let store = f.store()
        var logs: [String] = []; store.overviewLoadLog = { logs.append($0) }
        await store.refresh()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(notices(logs, "combined").first?["outcome"], "success"); XCTAssertEqual(notices(logs, "combined").first?["request"], "1")
        XCTAssertEqual(f.calls.map(\.surface), ["overview"])
        for (error, outcome) in [(ChecklistError("DENIED", "denied") as Error, "error:DENIED"), (CancellationError() as Error, "canceled")] {
            let f = fixture(); defer { f.cleanup() }; f.combinedError = error; let store = f.store()
            var logs: [String] = []; store.overviewLoadLog = { logs.append($0) }
            await store.refresh()
            XCTAssertEqual(logs.count, 1, outcome); XCTAssertEqual(notices(logs, "combined").first?["outcome"], outcome)
            XCTAssertEqual(f.calls.map(\.surface), ["overview"])
        }
    }
    func testFailedFallbackSurfaceNoticeAndPartialSettlement() async throws {
        let f = fixture(); defer { f.cleanup() }; f.combinedError = timeout; f.failingSurface = "needs_active"; let store = f.store()
        var logs: [String] = []; store.overviewLoadLog = { logs.append($0) }
        await store.refresh()
        XCTAssertEqual(notices(logs, "combined").map { $0["outcome"] ?? "" }, ["timeout"])
        let attempts = notices(logs, "attempt")
        XCTAssertEqual(attempts.map { $0["surface"] ?? "" }, surfaces)
        XCTAssertTrue(attempts.allSatisfy { $0["attempt"] == "1" })
        for attempt in attempts {
            if attempt["surface"] == "needs_active" {
                XCTAssertEqual(attempt["outcome"], "error:DENIED"); XCTAssertEqual(attempt["rows"], "none"); XCTAssertEqual(attempt["total"], "none")
            } else { XCTAssertEqual(attempt["outcome"], "installed") }
        }
        let settled = notices(logs, "fallback_settled")
        XCTAssertEqual(settled.count, 1); XCTAssertEqual(settled.first?["outcome"], "partial")
        XCTAssertEqual(settled.first?["installed"], "9"); XCTAssertEqual(settled.first?["failed"], "1")
        XCTAssertNotNil(store.overviewObservations["needs_active"]?.error)
    }
    func testTimeoutPublishesEachPageImmediatelyAndReadsOnlyOneSurfaceAtATime() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store()
        let read = Task { await store.refresh() }
        try await until { f.held.count == 1 }; f.release(error: timeout)
        for (index, surface) in surfaces.enumerated() {
            try await until { f.held.count == 1 }
            XCTAssertEqual(f.held[0].call.surface, surface)
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.error == nil }, "The combined timeout never publishes an error wall")
            for earlier in surfaces.prefix(index) { XCTAssertEqual(store.overviewObservations[earlier]?.page?.total, 37) }
            f.release()
        }
        await read.value
        XCTAssertEqual(f.calls.map(\.surface), ["overview"] + surfaces)
        XCTAssertEqual(f.maximumActive, 1); XCTAssertEqual(store.needsCount, 91)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading && $0.error == nil })
    }
    func testLiveWaitTimeoutDuringFallbackDoesNotRepeatCompletedSurfaces() async throws {
        for finishesDuringPause in [false, true] {
            let f = fixture(); defer { f.cleanup() }; f.holdNextWait = true
            let store = f.store(); store.liveRetryPause = finishesDuringPause ? 100_000_000 : 0
            let live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { f.heldWait != nil }
            let before = f.calls.count
            f.hold = true
            let read = Task { await store.refresh() }
            try await until { f.held.count == 1 }; f.release(error: timeout)
            for surface in surfaces.prefix(8) {
                try await until { f.held.count == 1 }
                XCTAssertEqual(f.held[0].call.surface, surface)
                f.release()
            }
            try await until { f.held.count == 1 }
            XCTAssertEqual(f.held[0].call.surface, "recent_reviews")
            f.releaseWait(error: timeout) // The same stopped service also timed out its long poll.
            try await until { store.lastServiceFailure != nil }
            XCTAssertTrue(surfaces.prefix(8).allSatisfy { store.overviewObservations[$0]?.page != nil },
                "A failed long poll supplies no new version that could invalidate accepted pages")
            if finishesDuringPause { f.hold = false }
            try await drain(f, store: store); await read.value
            try await until { f.waitCursors.count == 2 }
            XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface), ["overview"] + surfaces,
                "Reconnect must finish the owned fallback instead of restarting its eight completed surfaces")
            XCTAssertEqual(f.maximumActive, 1)
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading && $0.error == nil })
            XCTAssertTrue(store.connected); XCTAssertNil(store.error)
            XCTAssertEqual(f.waitCursors.last!, "combined-coverage", "Reconnect cannot skip unseen change coverage")
        }
    }
    func testLiveWaitRecoveryKeepsVersionFenceAndRepairsOnlyPagesBeforeTheCommit() async throws {
        let f = fixture(); defer { f.cleanup() }; f.holdNextWait = true
        let store = f.store(); store.liveRetryPause = 0
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.heldWait != nil }
        let before = f.calls.count; f.hold = true
        let read = Task { await store.refresh() }
        try await until { f.held.count == 1 }; f.release(error: timeout)
        try await until { f.held.count == 1 }; f.release() // completed_since precedes the real commit.
        try await until { f.held.count == 1 }
        f.releaseWait(error: timeout)
        try await until { store.lastServiceFailure != nil }
        f.readVersion = "commit-during-reconnect"
        f.release() // human_tasks learns the commit while recovery joins the same loader.
        try await until { f.held.count == 1 }
        XCTAssertNil(store.overviewObservations["completed_since"]?.page, "Known old content must disappear immediately")
        try await drain(f, store: store); await read.value
        try await until { f.waitCursors.count == 2 }
        XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface), ["overview"] + surfaces + ["completed_since"])
        XCTAssertEqual(f.maximumActive, 1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading && $0.error == nil })
    }
    func testLiveCoverageAndScopeErrorsStillReplacePendingFallback() async throws {
        for code in ["CURSOR_RESET", "DENIED"] {
            let f = fixture(); defer { f.cleanup() }; f.holdNextWait = true
            let store = f.store(); store.liveRetryPause = 0
            let live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            try await until { f.heldWait != nil }
            let before = f.calls.count; f.hold = true
            let read = Task { await store.refresh() }
            try await until { f.held.count == 1 }; f.release(error: timeout)
            try await until { f.held.count == 1 }; f.release()
            try await until { f.held.count == 1 }
            f.releaseWait(error: ChecklistError(code, "Synthetic lost scope or coverage"))
            try await until { f.held.count == 2 }
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page == nil })
            f.release() // The obsolete human_tasks reply cannot install into the reset scope.
            await read.value
            try await drain(f, store: store)
            try await until { f.waitCursors.count == 2 }
            XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface), ["overview"] + Array(surfaces.prefix(2)) + surfaces)
            XCTAssertEqual(f.waitCursors.last!, code == "CURSOR_RESET" ? "content-completed_since" : "combined-coverage")
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading && $0.error == nil })
        }
    }
    func testCancelLiveRecoveryRetiresFallbackWithoutStartingRemainingSurfaces() async throws {
        let f = fixture(); defer { f.cleanup() }; f.holdNextWait = true
        let store = f.store(); store.liveRetryPause = 0
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.heldWait != nil }
        let before = f.calls.count; f.hold = true
        let read = Task { await store.refresh() }
        try await until { f.held.count == 1 }; f.release(error: timeout)
        try await until { f.held.count == 1 }; f.release()
        try await until { f.held.count == 1 }
        f.releaseWait(error: timeout)
        try await until { store.lastServiceFailure != nil }
        for _ in 0..<20 { await Task.yield() }
        f.hold = false; live.cancel(); f.release()
        await live.value; await read.value
        XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface), ["overview"] + Array(surfaces.prefix(2)))
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading && $0.error == nil })
        XCTAssertEqual(f.waitCursors.count, 1)
    }
    func testFallbackLearningCommittedVersionDoesNotRestartItsPendingSurfaces() async throws {
        let f = fixture();defer {f.cleanup()};let store = f.store()
        await store.refresh()
        f.readVersion = "after-committed-change";f.combinedError = timeout
        let before = f.calls.count
        await store.refresh()
        // A token change discovered by the first fallback page must not schedule
        // another Overview loader behind the sequential one already in progress.
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface),["overview"] + surfaces)
        XCTAssertEqual(f.maximumActive,1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading && $0.error == nil })
    }
    func testCommitMidwayThroughFallbackRepairsOnlyInvalidatedCompletedPages() async throws {
        let f = fixture();defer {f.cleanup()};let store = f.store()
        await store.refresh();f.hold = true
        let before = f.calls.count, read = Task { await store.refresh() }
        try await until {f.held.count == 1};f.release(error:timeout)
        try await until {f.held.count == 1};f.release() // completed_since at the older version
        try await until {f.held.count == 1}
        XCTAssertEqual(f.held[0].call.surface,"human_tasks")
        f.readVersion = "commit-during-fallback";f.release()
        try await drain(f,store:store);await read.value
        XCTAssertEqual(Array(f.calls.dropFirst(before)).map(\.surface),["overview"] + surfaces + ["completed_since"])
        XCTAssertEqual(f.maximumActive,1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy {$0.page != nil && !$0.loading && $0.error == nil})
    }
    func testOneFallbackFailureSettlesAndExplicitRetryOnlyReadsThatSurface() async throws {
        let f = fixture(); defer { f.cleanup() }; f.combinedError = timeout; f.failingSurface = "needs_active"
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.calls.count == 11 && store.overviewObservations.values.allSatisfy { !$0.loading } }
        XCTAssertNotNil(store.overviewObservations["needs_active"]?.error)
        XCTAssertEqual(store.overviewObservations.values.filter { $0.page != nil }.count, 9)
        store.scheduleOverviewNeeds(); await Task.yield()
        XCTAssertEqual(f.calls.count, 11, "A settled failure is not retried automatically")
        f.failingSurface = nil; store.scheduleOverviewNeeds(only: "needs_active", force: true)
        try await until { f.calls.count == 12 && store.overviewObservations["needs_active"]?.page != nil }
        XCTAssertEqual(f.calls.last?.surface, "needs_active"); XCTAssertNil(store.overviewObservations["needs_active"]?.error)
    }
    func testTimeoutRefreshRetainsAcceptedRowsAndIsolatesAStaleSurface() async throws {
        let f = fixture(); defer { f.cleanup() }; let store = f.store()
        await store.refresh()
        let original = store.overviewObservations.mapValues { $0.rows.map(\.id) }
        f.hold = true
        let read = Task { await store.refresh() }; try await until { f.held.count == 1 }; f.release(error: timeout)
        try await until { f.held.count == 1 }
        for surface in surfaces {
            XCTAssertEqual(store.overviewObservations[surface]!.rows.map(\.id), original[surface])
            XCTAssertNil(store.overviewObservations[surface]!.error)
        }
        f.release(error: ChecklistError("DENIED", "Synthetic digest failure"))
        try await until { f.held.count == 1 }
        XCTAssertEqual(store.overviewObservations["completed_since"]!.rows.map(\.id), original["completed_since"])
        XCTAssertNotNil(store.overviewObservations["completed_since"]!.error)
        XCTAssertEqual(SourceState.of([store.overviewObservations["completed_since"]], offline: false), .stale)
        try await drain(f, store: store); await read.value
        XCTAssertEqual(store.overviewObservations.values.filter { $0.error != nil }.count, 1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading })
    }
    func testOnlyTypedReadTimeoutTriggersFallback() async throws {
        let errors: [Error] = [ChecklistError("DENIED", "reply timeout"), TicketPageError.invalid("combined"),
            CommandReply.unknown(commandID: nil, reason: "connection_ended"),
            CommandReply.unknown(commandID: "mutation", reason: "reply_timeout"), CancellationError()]
        for error in errors {
            let f = fixture(); defer { f.cleanup() }; f.combinedError = error; let store = f.store()
            await store.refresh()
            XCTAssertEqual(f.calls.map(\.surface), ["overview"])
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading })
            XCTAssertEqual(store.overviewObservations.values.filter { $0.error != nil }.count, error is CancellationError ? 0 : 10)
            if error is CancellationError { XCTAssertFalse(store.connectionAttempted) }
        }
        // A successful but malformed combined envelope also settles without a fallback.
        let f = fixture(); defer { f.cleanup() }
        var calls = 0
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: f.root), preferences: f.preferences, restorePendingCommand: false,
            desktopAlerts: DesktopAlertCoordinator(sink: RecoveryAlertSink()), requestTransport: { _, _ in calls += 1; return ["groups": ["requests": ["invalid": true]]] })
        await store.refresh(); XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading && $0.error != nil })
    }
    func testCanceledCombinedAndFallbackRepliesRetireWithoutStartingMoreReads() async throws {
        for fallback in [false, true] {
            let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store()
            let read = Task { await store.refresh() }; try await until { !f.held.isEmpty }
            if fallback { f.release(error: timeout); try await until { !f.held.isEmpty } }
            let calls = f.calls.count; read.cancel(); f.release(error: timeout); await read.value
            try await until { store.overviewObservations.values.allSatisfy { !$0.loading } }
            XCTAssertEqual(f.calls.count, calls); XCTAssertFalse(store.connectionAttempted)
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.error == nil })
        }
    }
    func testRetryDuringCombinedReadPreservesAllPendingSurfacesAndFencesOldCleanup() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }
        store.scheduleOverviewNeeds(only: "needs_active", force: true)
        try await until { f.held.count == 2 }
        f.release(error: timeout) // Obsolete combined error may not select fallback or clear new pending work.
        await Task.yield(); XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.loading && $0.error == nil })
        try await drain(f, store: store)
        XCTAssertEqual(f.calls.map(\.surface), ["overview"] + surfaces)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading })
    }
    func testRetryDuringFallbackKeepsPendingWorkAndDoesNotOverwriteNewerPage() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }; f.release(error: timeout)
        try await until { f.held.count == 1 }; f.release() // Digest accepted, human_tasks is now pending.
        try await until { f.held.count == 1 }
        store.moveOverviewPage("completed_since", cursor: "new-page")
        try await until { f.held.count == 2 }
        XCTAssertEqual(f.held[1].call.params["cursor"] as? String, "new-page")
        f.release(1); try await until { f.held.count == 2 }
        f.release() // Old human_tasks success arrives while replacement human_tasks is held.
        await Task.yield(); XCTAssertTrue(store.overviewObservations["human_tasks"]!.loading)
        try await drain(f, store: store)
        XCTAssertTrue(store.overviewObservations["completed_since"]!.rows[0].id.hasSuffix("new-page"))
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading })
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 1)
    }
    func testFocusReturnRefreshAndLiveCoverageKeepSequentialModeAndCoverageCursor() async throws {
        let f = fixture(); defer { f.cleanup() }; f.combinedError = timeout
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.calls.count == 11 && store.overviewObservations.values.allSatisfy { !$0.loading } }
        try await until { f.waitCursors.count == 1 }
        store.overviewFocus = "needs_pickup"
        try await until { store.overviewObservations["needs_pickup"]?.page?.query.limit == 50 }
        XCTAssertEqual(f.calls.last?.params["limit"] as? Int, 50)
        store.moveOverviewPage("needs_pickup", cursor: "page-two")
        try await until { store.overviewObservations["needs_pickup"]!.rows[0].id.hasSuffix("page-two") }
        store.overviewFocus = nil
        try await until { store.overviewObservations["needs_pickup"]?.page?.query.limit == 5 }
        await store.refresh()
        await store.applyChangeCoverage(["event_cursor": "covered-events", "coverage": ["schema_version": 2, "complete": true, "reset": false,
            "changes": [["project_id": "p", "families": ["tasks"], "all_tasks": true]]]])
        await store.refresh()
        live.cancel(); await live.value
        let resumed = Task { await store.startLiveUpdates() }; defer { resumed.cancel() }
        try await until { f.waitCursors.count == 2 }
        XCTAssertEqual(f.waitCursors.last!, "covered-events", "Fallback page cursors cannot skip the accepted event interval")
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 1)
        XCTAssertEqual(store.needsCount, 91)
        store.endOverviewVisit(); store.beginOverviewVisit(); await store.refresh()
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 2, "A fresh visit restores the combined fast path")
    }
    func testShowAllDuringFallbackRetiresHiddenGroupsAndReturnLoadsThem() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true
        let store = f.store(), live = Task { await store.startLiveUpdates() }; defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }; f.release(error: timeout); try await until { f.held.count == 1 }
        store.overviewFocus = "needs_pickup"; try await until { f.held.count == 2 }
        f.release(); await Task.yield()
        XCTAssertFalse(store.overviewObservations["completed_since"]!.loading, "Hidden pending work is explicitly retired")
        try await drain(f, store: store)
        XCTAssertEqual(store.overviewObservations["needs_pickup"]?.page?.query.limit, 50)
        store.overviewFocus = nil; try await drain(f, store: store)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading })
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 1)
    }
    func testProjectSwitchFencesCombinedReplyAndResetsFastMode() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true
        let store = f.store(), live = Task { await store.startLiveUpdates() }; defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }
        store.select(.overview, project: "q"); try await until { f.held.count == 2 }
        f.release(); await Task.yield()
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page == nil && $0.loading })
        f.release(); try await until { store.overviewObservations.values.allSatisfy { !$0.loading } }
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page?.query.project == "q" && $0.rows.first?.string("project_id") == "q" })
        XCTAssertEqual(f.calls.map(\.surface), ["overview", "overview"])
        f.hold = false; f.combinedError = timeout; await store.refresh()
        store.projectID = "p"; try await until { f.calls.last?.params["project_id"] as? String == "p" }
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 4)
    }
    func testDigestClearFencesOldTimestampAndFinishesOtherPendingGroups() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true
        let store = f.store(); store.beginOverviewVisit()
        let live = Task { await store.startLiveUpdates() }; defer { live.cancel(); store.stopWindowReads() }
        try await until { f.held.count == 1 }; f.release(error: timeout); try await until { f.held.count == 1 }
        let oldSince = f.held[0].call.params["since"] as? String
        store.clearOverviewDigest(); try await until { f.held.count == 2 }
        XCTAssertNotEqual(oldSince, f.held[1].call.params["since"] as? String)
        f.release(1); try await until { f.held.count == 2 }
        let newRows = store.overviewObservations["completed_since"]!.rows.map(\.id)
        f.release(); await Task.yield()
        XCTAssertEqual(store.overviewObservations["completed_since"]!.rows.map(\.id), newRows)
        try await drain(f, store: store)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading })
        XCTAssertEqual(f.calls.filter { $0.surface == "overview" }.count, 1)
    }
    func testSupersededCoverageCannotAdvanceItsOldInterval() async throws {
        let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store()
        let old = Task { await store.applyChangeCoverage(["event_cursor": "obsolete-coverage"]) }
        try await until { f.held.count == 1 }
        let replacement = Task { await store.refresh() }; try await until { f.held.count == 2 }
        f.release(1); await replacement.value
        f.release(); _ = await old.value
        XCTAssertTrue(store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading })
        f.hold = false
        let live = Task { await store.startLiveUpdates() }; defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitCursors.count == 1 }
        XCTAssertEqual(f.waitCursors.last!, "combined-coverage"); XCTAssertNotEqual(f.waitCursors.last!, "obsolete-coverage")
    }
    func testWindowCloseRetiresRefreshAndCoverageOwnedLoaders() async throws {
        for coverage in [false, true] {
            let f = fixture(); defer { f.cleanup() }; f.hold = true; let store = f.store()
            let read = Task { if coverage { await store.applyChangeCoverage(["event_cursor": "late"]) } else { await store.refresh() } }
            try await until { f.held.count == 1 }; store.stopWindowReads(); f.release(error: timeout); await read.value
            XCTAssertEqual(f.calls.count, 1); XCTAssertFalse(store.connectionAttempted)
            XCTAssertTrue(store.overviewObservations.values.allSatisfy { !$0.loading && $0.page == nil && $0.error == nil })
            f.hold = false
            let live = Task { await store.startLiveUpdates() }; defer { live.cancel(); store.stopWindowReads() }
            try await until { f.waitCursors.count == 1 }
            XCTAssertEqual(f.waitCursors.last!, "combined-coverage", "The closed loader never installed its late coverage cursor")
        }
    }
}

@MainActor private final class RecoveryAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("An Overview read never sends an alert") }
    func remove(_ identifiers: [String]) {}
}
