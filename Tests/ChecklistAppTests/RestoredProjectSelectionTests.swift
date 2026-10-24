import ChecklistTestSupport
import XCTest
import ChecklistIPC
@testable import ChecklistApp
@testable import ChecklistCore

@MainActor final class RestoredProjectSelectionTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL, router: CommandRouter, preferences: UserDefaults
        let owner = Caller(role: "owner", installation: "restored-project", projectIDs: [])
        var calls: [(String, [String: Any])] = []
        var scopedFailures: [String] = []
        var enteredWait = false
        var failInitialPage = false
        var snapshotError: Error?
        var catalogError: Error?
        var catalogReply: [String: Any]?
        var holdCatalog = false
        var heldCatalog: CheckedContinuation<[String: Any], Error>?
        init(_ preferences: UserDefaults) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("restored-project-" + UUID().uuidString)
            router = try TestStore.router(root: root)
            self.preferences = preferences
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func command(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var params = params
            if !CommandReply.readMethods.contains(method) { params["command_id"] = UUID().uuidString }
            return try router.handle(method: method, params: appFixtureTaskInput(router,method:method,input:params), caller: owner)
        }
        func existingProject(archived: Bool) throws -> String {
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let project = try command("project_create", ["name": "Kept project", "key_prefix": "KP", "root_path": workspace.path])["data"] as! [String: Any]
            let id = project["id"] as! String
            if archived { _ = try command("project_archive", ["project_id": id, "expected_revision": project["revision"]!, "archived": true]) }
            return id
        }
        func store(page: Page, project: String) -> ChecklistStore {
            preferences.set(page.rawValue, forKey: "lastPage"); preferences.set(project, forKey: "lastProject")
            return ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: preferences,
                restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: RestoredProjectAlertSink()), requestTransport: { [self] method, params in
                    calls.append((method, params))
                    if method == "changes_wait" {
                        enteredWait = true
                        try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError()
                    }
                    if method == "workspace_page", failInitialPage { failInitialPage = false; throw OfflineBannerTests.Down() }
                    if method == "snapshot", let snapshotError { throw snapshotError }
                    if method == "project_list" {
                        if let catalogError { throw catalogError }
                        if holdCatalog { return try await withCheckedThrowingContinuation { heldCatalog = $0 } }
                        if let catalogReply { return catalogReply }
                    }
                    do { return try command(method, params) }
                    catch {
                        if params["project_id"] != nil, let error = error as? CoreError { scopedFailures.append(error.code) }
                        throw error
                    }
                })
        }
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Bounded startup did not reach the expected read boundary")
        throw CancellationError()
    }
    func testMissingRestoredProjectReconnectsAgainstReplacementStore() async throws {
        for page in [Page.tasks, .epics, .overview, .media] {
            let f = try Fixture(isolatedDefaults("RestoredProjectSelection").preferences); defer { f.cleanup() }
            let store = f.store(page: page, project: UUID().uuidString)
            store.saveNote("old-ticket", text: "Keep this original draft")
            let live = Task { await store.startLiveUpdates() }
            try await until { f.enteredWait }
            live.cancel(); await live.value; store.stopWindowReads()
            XCTAssertTrue(store.connected, "Restored \(page) must not label a responsive replacement store offline")
            XCTAssertNil(store.projectID); XCTAssertNil(f.preferences.string(forKey: "lastProject"))
            XCTAssertEqual(store.page, page == .media ? .tasks : page)
            XCTAssertFalse(store.showsOfflineBanner); XCTAssertNil(store.lastServiceFailure)
            XCTAssertEqual(store.noteDrafts["old-ticket"], "Keep this original draft")
            XCTAssertEqual(f.calls.filter { $0.0 == "project_list" }.count, 1)
            XCTAssertTrue(f.scopedFailures.contains("NOT_FOUND"), "The real scoped router rejects the vanished project")
        }
    }
    func testExistingAndArchivedProjectsSurviveAnInitialReadFailure() async throws {
        for archived in [false, true] {
            let f = try Fixture(isolatedDefaults("RestoredProjectSelection").preferences); defer { f.cleanup() }
            let id = try f.existingProject(archived: archived)
            f.failInitialPage = true
            let store = f.store(page: .epics, project: id), live = Task { await store.startLiveUpdates() }
            try await until { f.enteredWait }
            live.cancel(); await live.value; store.stopWindowReads()
            XCTAssertEqual(store.projectID, id); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), id)
            XCTAssertEqual(store.page, .epics)
            XCTAssertEqual(f.calls.first { $0.0 == "project_list" }?.1["include_archived"] as? Bool, true)
            await store.refresh()
            XCTAssertTrue(store.connected)
        }
    }
    func testFailedCanceledOrMalformedCatalogCannotClearSavedSelection() async throws {
        for kind in ["offline", "canceled", "malformed"] {
            let f = try Fixture(isolatedDefaults("RestoredProjectSelection").preferences); defer { f.cleanup() }
            if kind == "malformed" { f.catalogReply = ["data": ["projects": [["name": "Missing identity"]]]] }
            else { f.catalogError = kind == "offline" ? OfflineBannerTests.Down() : CancellationError() }
            let id = UUID().uuidString, store = f.store(page: .media, project: id)
            let live = Task { await store.startLiveUpdates() }
            try await until { f.enteredWait }
            live.cancel(); await live.value; store.stopWindowReads()
            XCTAssertEqual(store.projectID, id); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), id)
            XCTAssertEqual(store.page, .media)
        }
    }
    func testLateCatalogCannotOverrideNavigationOrCanceledStartup() async throws {
        for cancel in [false, true] {
            let f = try Fixture(isolatedDefaults("RestoredProjectSelection").preferences); defer { f.cleanup() }
            f.holdCatalog = true
            let id = UUID().uuidString, store = f.store(page: .media, project: id)
            let live = Task { await store.startLiveUpdates() }
            try await until { f.heldCatalog != nil }
            if cancel { live.cancel() } else { store.select(.overview) }
            f.heldCatalog?.resume(returning: ["data": ["projects": [[String: Any]]()]]); f.heldCatalog = nil
            if !cancel { try await until { f.enteredWait }; live.cancel() }
            await live.value; store.stopWindowReads()
            XCTAssertEqual(store.projectID, cancel ? id : nil)
            XCTAssertEqual(store.page, cancel ? .media : .overview)
        }
    }
    func testReviewerRealCatalogFailureRecordsItsConcreteCause() async throws {
        let f = try Fixture(isolatedDefaults("W4-catalog-cause").preferences); defer { f.cleanup() }
        f.catalogError = ChecklistError("SERVICE_UNAVAILABLE", "Catalog connection refused for reviewer check")
        let id = UUID().uuidString, store = f.store(page: .epics, project: id)
        store.saveNote("old-ticket", text: "Keep café\nexact draft")
        let live = Task { await store.startLiveUpdates() }
        try await until { f.enteredWait }
        live.cancel(); await live.value; store.stopWindowReads()
        XCTAssertTrue(f.scopedFailures.contains("NOT_FOUND"))
        XCTAssertFalse(store.connected); XCTAssertTrue(store.connectionAttempted); XCTAssertTrue(store.showsOfflineBanner)
        XCTAssertNil(store.error, "An outage uses the banner, never a repeated alert")
        XCTAssertEqual(store.projectID, id); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), id)
        XCTAssertEqual(store.noteDrafts["old-ticket"], "Keep café\nexact draft")
        XCTAssertTrue(store.lastServiceFailure?.contains("Catalog connection refused for reviewer check") == true,
                      "Acceptance 1 requires a truthful last error when the catalog failure is real; actual=\(String(describing:store.lastServiceFailure))")
    }
    func testCatalogErrorsRecordOutageAndHealthyRefreshClearsIt() async throws {
        for kind in ["transport", "service", "reply"] {
            let f = try Fixture(isolatedDefaults("RestoredProjectCatalogError").preferences); defer { f.cleanup() }
            let failure = ChecklistError("SERVICE_UNAVAILABLE", "Catalog service unavailable")
            if kind == "reply" { f.catalogReply = ["error": ["code": failure.code, "message": failure.message]] }
            else { f.catalogError = kind == "transport" ? OfflineBannerTests.Down() : failure }
            let expected = kind == "transport" ? "Connection refused" : failure.localizedDescription
            let id = UUID().uuidString, store = f.store(page: .media, project: id)
            store.saveNote("old-ticket", text: "Keep café\nexact draft")
            let live = Task { await store.startLiveUpdates() }
            try await until { f.enteredWait }
            live.cancel(); await live.value
            XCTAssertEqual(store.lastServiceFailure, expected)
            XCTAssertFalse(store.connected); XCTAssertTrue(store.connectionAttempted); XCTAssertTrue(store.showsOfflineBanner)
            XCTAssertNotNil(store.writeBlockReason); XCTAssertNil(store.error)
            XCTAssertEqual(store.projectID, id); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), id)
            XCTAssertEqual(store.page, .media); XCTAssertEqual(store.noteDrafts["old-ticket"], "Keep café\nexact draft")
            store.select(.epics)
            await store.refresh()
            XCTAssertTrue(store.connected); XCTAssertFalse(store.showsOfflineBanner); XCTAssertNil(store.lastServiceFailure)
            store.stopWindowReads()
        }
    }

    func testCatalogCancellationLeavesExistingHealthUntouched() async throws {
        for priorOutage in [false, true] {
            for result in ["cancellation", "lateError", "lateSuccess"] {
                let cancelTask = result != "cancellation"
                let f = try Fixture(isolatedDefaults("RestoredProjectCatalogCancellation").preferences); defer { f.cleanup() }
                let id = UUID().uuidString, store = f.store(page: .media, project: id)
                store.saveNote("old-ticket", text: "Keep café\nexact draft")
                if priorOutage {
                    f.snapshotError = OfflineBannerTests.Down()
                    await store.ensureFullSnapshot()
                }
                f.holdCatalog = true
                let live = Task { await store.startLiveUpdates() }
                try await until { f.heldCatalog != nil }
                let connected = store.connected, attempted = store.connectionAttempted, banner = store.showsOfflineBanner, failure = store.lastServiceFailure
                if cancelTask { live.cancel() }
                // Even a real transport error after caller cancellation is lifecycle evidence only.
                if result == "lateSuccess" { f.heldCatalog?.resume(returning: ["data": ["projects": [[String: Any]]()]]) }
                else { f.heldCatalog?.resume(throwing: cancelTask ? OfflineBannerTests.Down() : CancellationError()) }
                f.heldCatalog = nil
                if !cancelTask { try await until { f.enteredWait }; live.cancel() }
                await live.value; store.stopWindowReads()
                XCTAssertEqual(store.connected, connected); XCTAssertEqual(store.connectionAttempted, attempted)
                XCTAssertEqual(store.showsOfflineBanner, banner); XCTAssertEqual(store.lastServiceFailure, failure)
                XCTAssertEqual(store.projectID, id); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), id)
                XCTAssertEqual(store.page, .media); XCTAssertEqual(store.noteDrafts["old-ticket"], "Keep café\nexact draft")
                XCTAssertNil(store.error)
            }
        }
    }

    func testSupersededCatalogResultLeavesHealthAndSelectionUntouched() async throws {
        for replacement in ["project", "page", "window", "healthyRead"] {
            for fails in [false, true] {
                let f = try Fixture(isolatedDefaults("RestoredProjectCatalogSuperseded").preferences); defer { f.cleanup() }
                let id = try f.existingProject(archived: false)
                f.failInitialPage = true; f.holdCatalog = true
                let store = f.store(page: .epics, project: id)
                store.saveNote("old-ticket", text: "Keep café\nexact draft")
                let live = Task { await store.startLiveUpdates() }
                try await until { f.heldCatalog != nil }
                switch replacement {
                case "project": store.select(.epics); await store.refresh()
                case "page": store.select(.activity, project: id); await store.refresh()
                case "window": store.stopWindowReads()
                default: await store.refresh()
                }
                let connected = store.connected, attempted = store.connectionAttempted, banner = store.showsOfflineBanner, failure = store.lastServiceFailure
                let project = store.projectID, page = store.page
                if fails { f.heldCatalog?.resume(throwing: ChecklistError("SERVICE_UNAVAILABLE", "Obsolete catalog failure")) }
                else { f.heldCatalog?.resume(returning: ["data": ["projects": [[String: Any]]()]]) }
                f.heldCatalog = nil
                try await until { f.enteredWait }
                live.cancel(); await live.value; store.stopWindowReads()
                XCTAssertEqual(store.connected, connected, replacement); XCTAssertEqual(store.connectionAttempted, attempted, replacement)
                XCTAssertEqual(store.showsOfflineBanner, banner, replacement); XCTAssertEqual(store.lastServiceFailure, failure, replacement)
                XCTAssertEqual(store.projectID, project, replacement); XCTAssertEqual(f.preferences.string(forKey: "lastProject"), project, replacement)
                XCTAssertEqual(store.page, page, replacement); XCTAssertEqual(store.noteDrafts["old-ticket"], "Keep café\nexact draft")
                XCTAssertNil(store.error)
            }
        }
    }
}

@MainActor private final class RestoredProjectAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Startup reconciliation must not alert") }
    func remove(_ identifiers: [String]) {}
}
