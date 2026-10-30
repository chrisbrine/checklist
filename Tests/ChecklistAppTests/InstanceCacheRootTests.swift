import XCTest
@testable import ChecklistIPC
@testable import ChecklistApp

final class InstanceCacheRootTests: XCTestCase {
    private let windowID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!

    func testLiveHumanClaimServiceKeepsFormerName() throws {
        for environment in [[:], ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"]] {
            XCTAssertEqual(try ChecklistInstance(environment: environment).humanClaimService, "Checklist.HumanClaim")
        }
    }

    func testLiveAndEverySlotHaveDistinctHumanClaimServices() throws {
        var services: Set<String> = [try ChecklistInstance(environment: [:]).humanClaimService]
        for slot in 1...4 {
            let service = try ChecklistInstance(slotValue: slot, environment: [:]).humanClaimService
            XCTAssertEqual(service, "Checklist.Test\(slot).HumanClaim")
            XCTAssertTrue(services.insert(service).inserted)
        }
        XCTAssertEqual(services.count, 5)
    }

    func testLiveWorkspacePreferenceSuiteKeepsFormerName() throws {
        for environment in [[:], ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"]] {
            let live = try ChecklistInstance(environment: environment)
            XCTAssertEqual(live.workspacePreferencesSuitePrefix, "Checklist.Workspace")
            XCTAssertEqual(WorkspaceWindowStorage.application(for: live).suiteName(for: windowID),
                           "Checklist.Workspace.abcdef01-2345-6789-abcd-ef0123456789")
        }
        XCTAssertEqual(WorkspaceWindowStorage.application.suiteName(for: windowID),
                       "Checklist.Workspace.abcdef01-2345-6789-abcd-ef0123456789")
    }

    func testSameWindowUUIDHasDistinctPreferenceSuitesInLiveAndEverySlot() throws {
        let live = try ChecklistInstance(environment: [:])
        var names: Set<String> = [WorkspaceWindowStorage.application(for: live).suiteName(for: windowID)]
        for slot in 1...4 {
            let instance = try ChecklistInstance(slotValue: slot, environment: [:])
            XCTAssertEqual(instance.workspacePreferencesSuitePrefix, "Checklist.Test\(slot).Workspace")
            let name = WorkspaceWindowStorage.application(for: instance).suiteName(for: windowID)
            XCTAssertEqual(name, "Checklist.Test\(slot).Workspace.abcdef01-2345-6789-abcd-ef0123456789")
            XCTAssertTrue(names.insert(name).inserted)
        }
        XCTAssertEqual(names.count, 5)
    }

    @MainActor func testSlotWorkspaceStateRequestsInstanceSuiteUsingInjectedPreferences() throws {
        let instance = try ChecklistInstance(slotValue: 3, environment: [:])
        let defaults = isolatedDefaults("InstanceWorkspace")
        var storage = WorkspaceWindowStorage.application(for: instance)
        XCTAssertEqual(storage.journalBaseDirectory, LocalDraftJournal.directory(for: instance))
        storage.journalBaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage.primaryPreferences = defaults.preferences
        let naming = storage
        var requestedNames: [String] = []
        storage.workspacePreferences = { id in
            requestedNames.append(naming.suiteName(for: id))
            return defaults.childPreferences(id)
        }
        let state = WorkspaceWindowState(identity: .workspace(windowID), storage: storage) { journal, preferences, memory in
            ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false,
                           desktopAlerts: DesktopAlertCoordinator(sink: InstancePreferencesAlertSink()),
                           requestTransport: { _, _ in throw NSError(domain: "UnexpectedInstancePreferencesRequest", code: 1) },
                           navigationMemory: memory,
                           pendingCommandPersistence: PendingCommandPersistence(
                            read: { _ in XCTFail("Unexpected pending-command read"); return nil },
                            save: { _, _ in XCTFail("Unexpected pending-command save") },
                            remove: { _ in XCTFail("Unexpected pending-command removal") }))
        }
        defer { state.store.stopWindowReads() }
        XCTAssertEqual(requestedNames, ["Checklist.Test3.Workspace.abcdef01-2345-6789-abcd-ef0123456789"])
        XCTAssertTrue(state.preferences === defaults.childPreferences(windowID))
        XCTAssertEqual(storage.lastWorkspaceID, windowID)
        XCTAssertEqual(state.journal.directory, storage.journalBaseDirectory.appendingPathComponent("Windows/abcdef01-2345-6789-abcd-ef0123456789", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.journalBaseDirectory.path))
    }

    func testLiveCacheAndAppDefaultsKeepFormerPaths() throws {
        let former = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for environment in [[:], ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"]] {
            let live = try ChecklistInstance(environment: environment)
            XCTAssertEqual(live.cachesRoot, former)
            XCTAssertEqual(live.cachesRoot.absoluteString, former.absoluteString)
        }
        XCTAssertNil(ChecklistInstance.current.slot)
        XCTAssertEqual(CaptureAttachment.staging, former.appendingPathComponent("ChecklistAttachmentDrafts", isDirectory: true))
        XCTAssertEqual(AuthorizedPreviewFile.defaultExternalWorkingCopyBase, former)
        XCTAssertEqual(AuthorizedPreviewFile.defaultExternalWorkingCopyBase.appendingPathComponent("Checklist/OpenCopies", isDirectory: true),
                       former.appendingPathComponent("Checklist/OpenCopies", isDirectory: true))
    }

    func testEverySlotCacheIsInsideItsFolderOutsideDataAndSeparateFromLive() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let live = try ChecklistInstance(environment: [:])
        var roots: [URL] = []
        for slot in 1...4 {
            let instance = try ChecklistInstance(slotValue: slot, environment: ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"])
            let folder = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-\(slot)", isDirectory: true)
            XCTAssertEqual(instance.cachesRoot, folder.appendingPathComponent("caches", isDirectory: true))
            XCTAssertEqual(instance.cachesRoot.deletingLastPathComponent(), folder)
            XCTAssertTrue(try ChecklistInstance.rootsOverlap(instance.cachesRoot, folder))
            XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, instance.root))
            XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, live.cachesRoot))
            for other in roots {
                XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, other))
            }
            roots.append(instance.cachesRoot)
        }
    }
}

@MainActor private final class InstancePreferencesAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { throw NSError(domain: "UnexpectedInstancePreferencesAlert", code: 1) }
    func send(_ alert: DesktopAlert) async throws { throw NSError(domain: "UnexpectedInstancePreferencesAlert", code: 2) }
    func remove(_ identifiers: [String]) {}
}
