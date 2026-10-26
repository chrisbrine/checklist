import XCTest
import GRDB
@testable import ChecklistApp
@testable import ChecklistCore

/// Opt-in model timing on an explicitly selected read-only database clone. No XPC or GUI claim.
@MainActor final class OwnedStoreScreenCacheTests: XCTestCase {
    func testRealBackupColdOverviewAndCachedNavigation() async throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_ONLY_DATABASE"],
              let pid = ProcessInfo.processInfo.environment["CHECKLIST_READ_BENCHMARK_PROJECT_ID"] else {
            throw XCTSkip("Requires an explicitly selected private backup copy and project")
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChecklistSyntheticTests/P9-r1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let router = try CommandRouter(root: root.appendingPathComponent("router"))
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            CommandRouter.installTicketSearchFunctions(db)
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        defer { try? pool.close(); try? router.closeStore(); try? FileManager.default.removeItem(at: root) }
        let owner = Caller(role: "owner", installation: "P9-r1-read-only", projectIDs: [])
        let preferences = isolatedDefaults("OwnedScreenCache").preferences
        preferences.set(Page.overview.rawValue, forKey: "lastPage")
        // Freeze the same digest scope in before/after Core and App fixtures.
        preferences.set(ISO8601DateFormatter().date(from:"2026-10-22T00:00:00Z")!, forKey:"overviewLastVisit")
        var calls: [String] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory:root.appendingPathComponent("drafts")),
            preferences: preferences, restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:OwnedStoreAlertSink()), requestTransport: { method, params in
                if method == "changes_wait" { try await Task.sleep(nanoseconds:30_000_000_000); throw CancellationError() }
                calls.append(method + ":" + (params["surface"] as? String ?? ""))
                let requestWire = try JSONSerialization.data(withJSONObject: params)
                let replyWire = try await Task.detached {
                    let request = try JSONSerialization.jsonObject(with: requestWire) as! [String: Any]
                    let reply = try router.executePureRead(pool, method:method, params:request, caller:owner)
                    return try JSONSerialization.data(withJSONObject: reply)
                }.value
                return try JSONSerialization.jsonObject(with: replyWire) as! [String: Any]
            })
        var load = [Double](repeating:0, count:3); getloadavg(&load, 3)
        let start = ProcessInfo.processInfo.systemUptime
        let live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        func settled(_ predicate: () -> Bool) async throws {
            for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(nanoseconds:5_000_000) }
            XCTFail("Owned-copy model read did not settle"); throw CancellationError()
        }
        try await settled { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
        let cold = ProcessInfo.processInfo.systemUptime - start
        print("P9-r1 App cold_overview_ms=\(cold*1000) load=\(load) calls=\(calls)")
        XCTAssertLessThan(cold, 1)
        XCTAssertEqual(calls, ["workspace_page:overview"])
        let original = store.overviewObservations["needs_pickup"]!.rows.map(\.id)
        store.endOverviewVisit() // Native onDisappear advances the next visit's digest scope.
        store.select(.tasks, project:pid)
        try await settled { store.preparedTicketWorkspace != nil && !store.ticketPageLoading }
        let tickets = store.ticketPageMatchedCount
        store.select(.epics, project:pid)
        try await settled { store.workspacePageLoaded && !store.workspaceLoading }
        let epics = store.workspaceRows.map(\.id)
        let ticketStart = ProcessInfo.processInfo.systemUptime
        store.select(.tasks, project:pid)
        XCTAssertEqual(store.ticketPageMatchedCount,tickets)
        XCTAssertNotNil(store.preparedTicketWorkspace)
        let cachedTicket = ProcessInfo.processInfo.systemUptime - ticketStart
        print("P9-r1 App cached_ticket_return_ms=\(cachedTicket*1000)")
        XCTAssertLessThan(cachedTicket,0.3)
        let other = try XCTUnwrap(store.activeProjects.first { $0.id != pid }?.id)
        store.select(.tasks, project:other)
        try await settled { store.preparedTicketWorkspace != nil && !store.ticketPageLoading && store.projectID == other }
        let switchStart = ProcessInfo.processInfo.systemUptime
        store.select(.tasks, project:pid)
        XCTAssertEqual(store.ticketPageMatchedCount,tickets)
        XCTAssertNotNil(store.preparedTicketWorkspace)
        let cachedSwitch = ProcessInfo.processInfo.systemUptime - switchStart
        print("P9-r1 App cached_project_switch_ms=\(cachedSwitch*1000)")
        XCTAssertLessThan(cachedSwitch,0.3)
        let epicStart = ProcessInfo.processInfo.systemUptime
        store.select(.epics, project:pid)
        XCTAssertEqual(store.workspaceRows.map(\.id),epics)
        let cachedEpic = ProcessInfo.processInfo.systemUptime - epicStart
        print("P9-r1 App cached_epic_return_ms=\(cachedEpic*1000)")
        XCTAssertLessThan(cachedEpic,0.3)
        let overviewStart = ProcessInfo.processInfo.systemUptime
        store.select(.overview)
        XCTAssertEqual(store.overviewObservations["needs_pickup"]!.rows.map(\.id),original)
        XCTAssertNil(store.overviewObservations["completed_since"]!.page, "The new digest cannot reuse the old timestamp's rows")
        let cachedOverview = ProcessInfo.processInfo.systemUptime - overviewStart
        print("P9-r1 App cached_overview_return_ms=\(cachedOverview*1000)")
        XCTAssertLessThan(cachedOverview,0.3)
        try await settled { store.overviewObservations.values.allSatisfy { $0.page != nil && !$0.loading } }
    }
}

@MainActor private final class OwnedStoreAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Read-only model timing never sends alerts") }
    func remove(_ identifiers:[String]) {}
}
