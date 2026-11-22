import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// CL-60: a service outage shows one offline banner, the alert does not repeat, and reconnection clears it.
@MainActor final class OfflineBannerTests: XCTestCase {
    struct Down: LocalizedError { var errorDescription: String? { "Connection refused" } }

    func testOutageShowsOneBannerAndNoRepeatedAlert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-" + UUID().uuidString)
        let preferences = isolatedDefaults("Offline").preferences
        defer { try? FileManager.default.removeItem(at: root) }
        let online = FixtureState(false)
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OfflineAlertSink()),
                                   requestTransport: { method, _ in
                                       guard online.value else { throw Down() }
                                       return method == "snapshot" ? ["data": ["service": ["store_incarnation": "offline-test"]], "event_cursor": "c1"] : [:]
                                   })
        XCTAssertFalse(store.showsOfflineBanner, "No banner before the first connection attempt")
        for _ in 0..<3 {   // the live loop retries like this every few seconds
            await store.refresh(quiet: true)
            await store.ensureFullSnapshot()
            XCTAssertNil(store.error, "An outage never raises the alert")
        }
        XCTAssertTrue(store.showsOfflineBanner)
        XCTAssertEqual(store.lastServiceFailure, "Connection refused")
        online.value = true
        await store.ensureFullSnapshot()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.showsOfflineBanner, "Reconnection clears the banner")
        XCTAssertNil(store.error)
        XCTAssertNil(store.lastServiceFailure, "Accepted reads clear the technical outage")
    }

    /// The production loop: the first read and its retry fail, then the service answers waits again with no
    /// change. The next healthy wait reloads the visible page, which reconnects and removes the banner.
    func testAHealthyUnchangedWaitAfterAnOutageReconnects() async throws {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let root = cache.appendingPathComponent("reconnect-" + UUID().uuidString)
        let preferences = isolatedDefaults("Reconnect").preferences
        defer { try? FileManager.default.removeItem(at: root) }
        let project: [String: Any] = ["id": "reconnect-project", "name": "A"]
        preferences.set(Page.epics.rawValue, forKey: "lastPage"); preferences.set(project["id"] as! String, forKey: "lastProject")
        var waits = 0, healthyWaits = 0, reads = 0
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OfflineAlertSink()),
                                   requestTransport: { method, params in
                                       if method == "changes_wait" {
                                           waits += 1
                                           if waits == 1 { throw Down() }
                                           healthyWaits += 1
                                           try await Task.sleep(nanoseconds: 5_000_000)
                                           return ["data": ["changed": false], "event_cursor": "healthy"]
                                       }
                                       reads += 1
                                       if reads <= 2 { throw Down() }   // the first read, and the retry after the failed wait
                                       if method == "project_list" { return ["data": ["projects": [project]], "event_cursor": "healthy"] }
                                       if method == "workspace_page" {
                                           return ["data": ["workspace_version": 1, "surface": params["surface"] ?? "epics", "record_id": "",
                                               "rows": [], "total": 0, "needs_you_count": 0, "has_more": false,
                                               "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [project],
                                               "service": ["store_incarnation": "reconnect-fixture"], "content_cursor": "healthy"], "event_cursor": "healthy"]
                                       }
                                       XCTFail("Unexpected reconnect read: \(method)")
                                       return [:]
                                   })
        store.liveWaitPause = 5_000_000; store.liveRetryPause = 5_000_000
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        let deadline = Date().addingTimeInterval(10)
        while !(healthyWaits >= 3 && store.connected) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(healthyWaits, 1)
        XCTAssertGreaterThan(reads, 2, "A healthy wait after the outage reloads the visible data")
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.showsOfflineBanner, "The banner goes away without a changed event or a Retry click")
        XCTAssertNil(store.error)
        XCTAssertNil(store.lastServiceFailure, "Accepted reads clear the technical outage")
    }

    func testReadinessClearsOfflineDuringAHeldReadAndBackoffStopsAtTwoSeconds() async throws {
        let clock = ReconnectClock()
        var releasePage: CheckedContinuation<[String: Any], any Error>?
        var probeTimes: [Duration] = []
        let ready = FixtureState(false)
        let journal = LocalDraftJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = ChecklistStore(draftJournal: journal, preferences: isolatedDefaults("Readiness").preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OfflineAlertSink()),
                                   requestTransport: { _, _ in
                                       try await withCheckedThrowingContinuation { releasePage = $0 }
                                   }, serviceProbe: {
                                       probeTimes.append(clock.now)
                                       if !ready.value { throw Down() }
                                   })
        store.reconnectSleep = { try await clock.sleep(for: $0) }
        let live = Task { await store.startLiveUpdates() }
        defer {
            live.cancel()
            store.stopWindowReads()
            clock.cancel()
            releasePage?.resume(throwing: CancellationError())
        }

        let pauses: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2)]
        for (index, expected) in pauses.enumerated() {
            try await until { clock.deadline != nil && releasePage != nil }
            XCTAssertEqual(clock.deadline.map { $0 - clock.now }, expected)
            clock.advance(by: expected - .milliseconds(1))
            XCTAssertEqual(probeTimes.count, index)
            clock.advance(by: .milliseconds(1))
        }
        try await until { clock.deadline != nil }
        XCTAssertTrue(store.showsOfflineBanner)
        XCTAssertEqual(store.serviceConnectionFooter, "Service disconnected")
        XCTAssertEqual(probeTimes, [.milliseconds(250), .milliseconds(750), .milliseconds(1750), .milliseconds(3750), .milliseconds(5750)])
        ready.value = true
        clock.advance(by: .seconds(2))
        try await until { store.serviceReachable }
        XCTAssertFalse(store.showsOfflineBanner)
        XCTAssertEqual(store.serviceConnectionFooter, "Service connected")
        XCTAssertFalse(store.connected, "A held page cannot yet authorize writes")
        XCTAssertNotNil(releasePage)
        XCTAssertNil(clock.deadline)
        XCTAssertEqual(probeTimes.last, .milliseconds(7750))
    }

    func testAnEstablishedWindowProbesAgainWhenItsSubscriptionFails() async throws {
        let clock = ReconnectClock()
        let preferences = isolatedDefaults("ReadinessAfterOutage").preferences
        preferences.set(Page.epics.rawValue, forKey: "lastPage")
        let journal = LocalDraftJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var releaseWait: CheckedContinuation<[String: Any], any Error>?
        var probes = 0
        let store = ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OfflineAlertSink()),
                                   requestTransport: { method, params in
                                       if method == "changes_wait" {
                                           return try await withCheckedThrowingContinuation { releaseWait = $0 }
                                       }
                                       return ["workspace_version": 1, "surface": params["surface"] ?? "epics", "record_id": "",
                                               "rows": [], "total": 0, "needs_you_count": 0, "has_more": false,
                                               "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [],
                                               "service": ["store_incarnation": "reconnect-fixture"], "content_cursor": "ready"]
                                   }, serviceProbe: { probes += 1 })
        await store.refresh()
        XCTAssertTrue(store.connected)
        store.reconnectSleep = { try await clock.sleep(for: $0) }
        let live = Task { await store.startLiveUpdates() }
        defer {
            live.cancel()
            store.stopWindowReads()
            clock.cancel()
            releaseWait?.resume(throwing: CancellationError())
        }
        try await until { releaseWait != nil }
        XCTAssertNil(clock.deadline, "A healthy window does not schedule probes")
        XCTAssertEqual(probes, 0)
        releaseWait?.resume(throwing: Down())
        releaseWait = nil

        try await until { store.showsOfflineBanner && clock.deadline != nil }
        XCTAssertEqual(clock.deadline, .milliseconds(250))
        clock.advance(by: .milliseconds(250))
        try await until { store.serviceReachable }
        XCTAssertFalse(store.showsOfflineBanner)
        XCTAssertEqual(probes, 1)
        XCTAssertNil(clock.deadline)
    }

    func testClosingWindowDiscardsInFlightReadinessReply() async throws {
        let clock = ReconnectClock()
        var releasePage: CheckedContinuation<[String: Any], any Error>?
        var releaseProbe: CheckedContinuation<Void, any Error>?
        let journal = LocalDraftJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = ChecklistStore(draftJournal: journal, preferences: isolatedDefaults("ReadinessCancellation").preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: OfflineAlertSink()),
                                   requestTransport: { _, _ in
                                       try await withCheckedThrowingContinuation { releasePage = $0 }
                                   }, serviceProbe: {
                                       try await withCheckedThrowingContinuation { releaseProbe = $0 }
                                   })
        store.reconnectSleep = { try await clock.sleep(for: $0) }
        let live = Task { await store.startLiveUpdates() }
        defer {
            live.cancel()
            store.stopWindowReads()
            clock.cancel()
            releasePage?.resume(throwing: CancellationError())
            releaseProbe?.resume(throwing: CancellationError())
        }
        try await until { clock.deadline != nil && releasePage != nil }
        clock.advance(by: .milliseconds(250))
        try await until { releaseProbe != nil }

        live.cancel()
        store.stopWindowReads()
        releaseProbe?.resume()
        releaseProbe = nil
        releasePage?.resume(throwing: CancellationError())
        releasePage = nil
        await live.value
        XCTAssertFalse(store.serviceReachable)
        XCTAssertFalse(store.connectionAttempted)
        XCTAssertNil(clock.deadline)
    }

    private func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !condition() {
            guard clock.now < deadline else { throw ReconnectTestTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct ReconnectTestTimeout: Error {}
}

@MainActor private final class ReconnectClock {
    private(set) var now: Duration = .zero
    private(set) var deadline: Duration?
    private var sleeper: CheckedContinuation<Void, any Error>?

    func sleep(for delay: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            deadline = now + delay
            sleeper = continuation
        }
    }

    func advance(by delay: Duration) {
        now += delay
        guard let deadline, now >= deadline else { return }
        self.deadline = nil
        let pending = sleeper
        sleeper = nil
        pending?.resume()
    }

    func cancel() {
        let pending = sleeper
        deadline = nil
        sleeper = nil
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor private final class OfflineAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
