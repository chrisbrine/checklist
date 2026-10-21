import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// CL-59: a desktop alert click opens its item in the most recently active window; a removed item
/// opens the unavailable state without a crash.
@MainActor final class AlertClickTests: XCTestCase {
    private func makeStore(_ transport: @escaping (String, [String: Any]) async throws -> [String: Any]) -> (ChecklistStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alertclick-" + UUID().uuidString)
        let preferences = isolatedDefaults("AlertClick").preferences
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: AlertClickSink()), requestTransport: transport)
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    func testAClickOpensItsItemInTheMostRecentWindow() {
        let (first, cleanFirst) = makeStore { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") }; defer { cleanFirst() }
        let (second, cleanSecond) = makeStore { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") }; defer { cleanSecond() }
        let windows = DesktopAlertWindows()
        XCTAssertFalse(windows.open(.task("t1")), "No window can open the item yet")
        windows.activate(first); windows.activate(second)
        XCTAssertTrue(windows.open(.request("r1")))
        XCTAssertEqual(second.detail, .request("r1")); XCTAssertNil(first.detail)
        windows.activate(first)
        XCTAssertTrue(windows.open(.task("t1")))
        XCTAssertEqual(first.detail, .task("t1"))
        windows.remove(first)
        XCTAssertTrue(windows.open(.task("t2"))); XCTAssertEqual(second.detail, .task("t2"))
    }

    /// Review finding b8c71b09: after the last window closed, a click waits and opens in the next window.
    func testAClickAfterTheLastWindowClosedOpensInTheNextWindow() {
        let (first, cleanFirst) = makeStore { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") }; defer { cleanFirst() }
        let (next, cleanNext) = makeStore { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") }; defer { cleanNext() }
        let clicks = DesktopAlertClicks(), windows = DesktopAlertWindows(clicks: clicks)
        windows.activate(first); windows.remove(first)
        clicks.received(target: "task:t-late", identifier: "task:t-late")
        XCTAssertEqual(clicks.pending, .task("t-late"), "No window is open, so the click waits")
        windows.activate(next)
        XCTAssertNil(clicks.pending); XCTAssertEqual(next.detail, .task("t-late"))
    }

    func testARemovedTicketShowsTheUnavailableState() async throws {
        let (store, cleanup) = makeStore { method, _ in
            if method == "changes_wait" { try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() }
            if method == "task_context" { throw ChecklistError("NOT_FOUND", "This ticket does not exist.") }
            throw ChecklistError("SERVICE_UNAVAILABLE", "offline")
        }
        defer { cleanup() }
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        store.open(.task("removed-ticket"))
        for _ in 0..<300 where !store.selectedTicketMissing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.selectedTicketMissing, "A removed ticket opens the unavailable state")
        XCTAssertNil(store.selectedTask("removed-ticket"))
    }
}

@MainActor private final class AlertClickSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
