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
}

@MainActor private final class OfflineAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
