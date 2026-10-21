import XCTest
@testable import ChecklistApp

final class WorkspaceWindowIsolationTests: XCTestCase {
    private var defaults: IsolatedDefaults!
    @MainActor private func state(_ identity: WorkspaceWindowIdentity, storage: WorkspaceWindowStorage) -> WorkspaceWindowState {
        return WorkspaceWindowState(identity: identity, storage: storage) { journal, preferences, memory in
            ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false,
                           desktopAlerts: DesktopAlertCoordinator(sink: WindowIsolationAlertSink()),
                           requestTransport: { _, _ in throw NSError(domain: "UnexpectedWindowTestRequest", code: 1) },
                           navigationMemory: memory, pendingCommandKey: identity.pendingCommandKey)
        }
    }
    private func storage() throws -> WorkspaceWindowStorage {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistWindowIsolation-" + id)
        defaults = isolatedDefaults("WindowIsolationTests")
        let prefix = defaults.suiteName
        return WorkspaceWindowStorage(journalBaseDirectory: root,
                                      primaryPreferences: defaults.preferences,
                                      preferencesSuitePrefix: prefix,
                                      workspacePreferences: defaults.childPreferences)
    }
    private func clean(_ storage: WorkspaceWindowStorage) {
        try? FileManager.default.removeItem(at: storage.journalBaseDirectory)
    }

    @MainActor func testTwoWindowsKeepSameTicketDraftsSelectionAndNavigationIndependent() throws {
        let storage = try storage(), id = UUID()
        defer { clean(storage) }
        let primary = state(.primary, storage: storage), other = state(.workspace(id), storage: storage)
        XCTAssertTrue(primary.store.navigationMemory === primary.navigationMemory)
        XCTAssertTrue(other.store.navigationMemory === other.navigationMemory)
        XCTAssertFalse(primary.navigationMemory === other.navigationMemory)
        for window in [primary, other] { window.store.data = ["service": ["store_incarnation": "synthetic-store"]] }
        primary.store.select(.tasks, project: "project-a")
        other.store.select(.tasks, project: "project-b")
        primary.store.open(.task("same-ticket"))
        other.store.open(.task("same-ticket"))
        primary.store.search = "primary filter"
        other.store.search = "other filter"
        primary.store.saveNote("same-ticket", text: "primary unsent note")
        other.store.saveNote("same-ticket", text: "other unsent note")
        let firstGeneration = primary.navigationMemory.navigationGeneration
        primary.navigationMemory.entries["task:same-ticket"] = .init(scrollOffsets: [.init(x: 0, y: 90)])
        other.store.open(.request("other-request"))
        other.store.goBack()
        other.store.closeDetail()
        XCTAssertEqual(primary.store.detail, .task("same-ticket"))
        XCTAssertEqual(primary.store.projectID, "project-a")
        XCTAssertTrue(primary.navigationMemory.owns(key: "task:same-ticket", generation: firstGeneration))
        XCTAssertEqual(primary.navigationMemory.entries["task:same-ticket"]?.scrollOffsets.first?.y, 90)
        XCTAssertNil(other.navigationMemory.entries["task:same-ticket"])
        XCTAssertEqual(primary.preferences.dictionary(forKey: "taskFilters:project-a")?["search"] as? String, "primary filter")
        XCTAssertNil(primary.preferences.dictionary(forKey: "taskFilters:project-b"))
        XCTAssertEqual(other.preferences.dictionary(forKey: "taskFilters:project-b")?["search"] as? String, "other filter")
        XCTAssertEqual(try primary.journal.recover(StoredNoteDraft.self, kind: "note").values["same-ticket"]?.text, "primary unsent note")
        XCTAssertEqual(try other.journal.recover(StoredNoteDraft.self, kind: "note").values["same-ticket"]?.text, "other unsent note")
        XCTAssertEqual(primary.journal.directory, storage.journalBaseDirectory, "The primary must keep the existing journal location")
        XCTAssertNotEqual(primary.identity.frameAutosaveName, other.identity.frameAutosaveName)
        XCTAssertNotEqual(primary.identity.pendingCommandKey, other.identity.pendingCommandKey)
    }

    @MainActor func testRestoredWindowUUIDRecoversOnlyItsOwnPreferencesAndJournal() throws {
        let storage = try storage(), id = UUID(), unrelatedID = UUID()
        defer { clean(storage) }
        let primary = state(.primary, storage: storage)
        primary.store.saveNote("same-ticket", text: "legacy primary note")
        do {
            let window = state(.workspace(id), storage: storage)
            window.store.select(.activity, project: "other-project")
            window.store.open(.request("restored-request"))
            window.store.saveNote("same-ticket", text: "window-specific note")
            window.preferences.set(false, forKey: "sidebarVisible")
            window.preferences.set("storage", forKey: "settingsSection")
        }
        let restored = state(.workspace(id), storage: storage), unrelated = state(.workspace(unrelatedID), storage: storage)
        XCTAssertEqual(restored.store.page, .activity)
        XCTAssertEqual(restored.store.projectID, "other-project")
        XCTAssertEqual(restored.store.detail, .request("restored-request"))
        XCTAssertEqual(restored.store.noteDrafts["same-ticket"], "window-specific note")
        XCTAssertEqual(restored.preferences.object(forKey: "sidebarVisible") as? Bool, false)
        XCTAssertEqual(restored.preferences.string(forKey: "settingsSection"), "storage")
        XCTAssertEqual(primary.store.noteDrafts["same-ticket"], "legacy primary note")
        XCTAssertTrue((unrelated.store.noteDrafts["same-ticket"] ?? "").isEmpty)
        XCTAssertNil(unrelated.preferences.string(forKey: "lastProject"))
        XCTAssertNil(unrelated.preferences.string(forKey: "settingsSection"))
    }

    @MainActor func testClosingWindowOwnerReleasesStoreAndNavigationMemory() throws {
        let storage = try storage(), id = UUID()
        defer { clean(storage) }
        weak var store: ChecklistStore?
        weak var memory: DetailItemNavigationMemory?
        autoreleasepool {
            let window = state(.workspace(id), storage: storage)
            store = window.store; memory = window.navigationMemory
            window.store.stopWindowReads()
        }
        XCTAssertNil(store, "No application-wide Store may retain a closed secondary window")
        XCTAssertNil(memory, "The navigation cache belongs to that window's lifetime")
    }

    @MainActor func testLastWorkspaceIdentityMakesClosedWindowDraftReachable() throws {
        let storage = try storage(), id = UUID()
        defer { clean(storage) }
        XCTAssertNil(storage.lastWorkspaceID)
        do {
            let window = state(.workspace(id), storage: storage)
            window.store.saveNote("ticket", text: "unsent before window close")
            window.store.open(.request("window-request"))
        }
        _ = state(.primary, storage: storage)
        let remembered = try XCTUnwrap(storage.lastWorkspaceID)
        XCTAssertEqual(remembered, id, "Opening the primary must not replace the recoverable workspace ID")
        let reopened = state(.workspace(remembered), storage: storage)
        XCTAssertEqual(reopened.store.noteDrafts["ticket"], "unsent before window close")
        XCTAssertEqual(reopened.store.detail, .request("window-request"))
    }

    func testLegacyCaptureRecoversAndCreatedTaskReceiptSurvivesJournalRecovery() throws {
        struct OldCapture: Codable {
            let projectID: String, title: String, brief: String, kind: String, epicID: String, storeIncarnation: String
        }
        let storage = try storage()
        defer { clean(storage) }
        let journal = LocalDraftJournal(directory: storage.journalBaseDirectory)
        try journal.save(OldCapture(projectID: "p", title: "Unsent", brief: "Brief", kind: "work", epicID: "", storeIncarnation: "s"), kind: "capture", key: "capture")
        var capture = try XCTUnwrap(journal.recover(CaptureDraft.self, kind: "capture").values["capture"])
        XCTAssertNil(capture.createdTaskID, "Old owner journals must remain readable")
        XCTAssertNil(capture.createCommandID)
        capture.createdTaskID = "already-created-task"
        capture.createCommandID = "original-create-command"
        try journal.save(capture, kind: "capture", key: "capture")
        let recovered = try XCTUnwrap(journal.recover(CaptureDraft.self, kind: "capture").values["capture"])
        XCTAssertEqual(recovered.createdTaskID, "already-created-task")
        XCTAssertEqual(recovered.createCommandID, "original-create-command")
    }
}

@MainActor private final class WindowIsolationAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { throw NSError(domain: "UnexpectedWindowTestAlert", code: 1) }
    func send(_ alert: DesktopAlert) async throws { throw NSError(domain: "UnexpectedWindowTestAlert", code: 2) }
    func remove(_ identifiers: [String]) {}
}
