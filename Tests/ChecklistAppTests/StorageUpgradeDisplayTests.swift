import XCTest
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class StorageUpgradeDisplayTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-upgrade-display-" + UUID().uuidString)
        var failure: Error?, envelope: [String: Any]?
        func store(_ preferences: UserDefaults) -> ChecklistStore {
            preferences.set(Page.epics.rawValue, forKey: "lastPage")
            return ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                desktopAlerts: DesktopAlertCoordinator(sink: UpgradeDisplayAlertSink()),
                requestTransport: { [self] method, params in
                    if let failure { throw failure }
                    if let envelope { return envelope }
                    return ["workspace_version": 1, "surface": params["surface"] ?? "epics", "record_id": "", "rows": [],
                        "total": 0, "needs_you_count": 0, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(),
                        "projects": [], "service": ["store_incarnation": "synthetic-upgrade-display"], "content_cursor": "ready"]
                }, navigationMemory: DetailItemNavigationMemory(),
                pendingCommandPersistence: .init(read: { _ in nil }, save: { _, _ in }, remove: { _ in }))
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    func testInitialUpgradeShowsStageEstimateWithoutGenericOfflineBanner() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "protected_snapshot", estimatedRemainingSeconds: 900, reason: "source_changed_after_preparation"))
        fixture.failure = status.error()
        let store = fixture.store(isolatedDefaults("StorageUpgradeDisplay").preferences); defer { store.stopWindowReads() }
        await store.refresh()
        XCTAssertTrue(store.showsOfflineBanner); XCTAssertFalse(store.connected)
        XCTAssertEqual(store.storageUpgradeStatus, status)
        XCTAssertEqual(store.connectionBannerTitle, "Checklist is upgrading")
        XCTAssertTrue(store.connectionBannerMessage.contains("protected pre-upgrade backup"))
        XCTAssertTrue(store.connectionBannerMessage.contains("about 15 minutes"))
        XCTAssertTrue(store.connectionBannerMessage.contains("store changed after preparation"))
        XCTAssertTrue(store.serviceConnectionFooter.hasPrefix("Service upgrading."))
        XCTAssertTrue(store.serviceConnectionFooter.contains(status.summary))
        XCTAssertEqual(store.serviceConnectionLabel, "Upgrading. " + status.summary)
        XCTAssertEqual(store.writeBlockReason, DisabledReasons.offline(upgrade: status))
        store.run("task_edit", ["project_id": "synthetic-project", "task_id": "synthetic-ticket"])
        XCTAssertEqual(store.notice, store.serviceUnavailableReason)
        XCTAssertNil(store.error, "An upgrade is one persistent banner, not an alert loop")
    }
    func testChangedStageUpdatesAndFirstAcceptedPageClearsUpgrade() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        fixture.failure = try XCTUnwrap(StorageUpgradeStatus(stage: "migration_rehearsal", estimatedRemainingSeconds: 360)).error()
        let store = fixture.store(isolatedDefaults("StorageUpgradeRecovery").preferences); defer { store.stopWindowReads() }
        await store.refresh()
        XCTAssertTrue(store.connectionBannerMessage.contains("about 6 minutes"))
        fixture.failure = try XCTUnwrap(StorageUpgradeStatus(stage: "final_migration", estimatedRemainingSeconds: 30)).error()
        await store.refresh()
        XCTAssertEqual(store.storageUpgradeStatus?.stage, "final_migration")
        XCTAssertTrue(store.connectionBannerMessage.contains("30 seconds"))
        fixture.failure = nil
        await store.refresh()
        XCTAssertTrue(store.connected); XCTAssertFalse(store.showsOfflineBanner)
        XCTAssertNil(store.storageUpgradeStatus); XCTAssertNil(store.lastServiceFailure)
        XCTAssertEqual(store.serviceConnectionFooter, "Service connected")
        XCTAssertEqual(store.serviceConnectionLabel, "Connected")
    }
    func testGenericDisabledReasonUsesKnownUpgradeWithoutReplacingOtherReasons() throws {
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "preparation_validation", estimatedRemainingSeconds: 30))
        let actual = try XCTUnwrap(DisabledReasons.display(DisabledReasons.offline, upgrade: status))
        XCTAssertTrue(actual.contains("Checklist is upgrading")); XCTAssertTrue(actual.contains(status.summary))
        XCTAssertFalse(actual.contains("Checklist is offline"))
        XCTAssertEqual(DisabledReasons.display(DisabledReasons.saving, upgrade: status), DisabledReasons.saving)
        XCTAssertEqual(DisabledReasons.display(DisabledReasons.offline, upgrade: nil), DisabledReasons.offline)
        XCTAssertNil(DisabledReasons.display(nil, upgrade: status))
    }
    func testSavedAnswerSummaryNamesKnownUpgrade() {
        let response = Record(values: ["id": "response", "origin": "human_ui", "form_identity": "form", "form_revision": 1])
        let request = Record(values: ["id": "request", "project_id": "p", "task_id": "t", "form_identity": "form", "form_revision": 1,
                                      "responses": [response.values], "continuation_message_id": "message"])
        let delivery = ["id": "delivery", "project_id": "p", "message_id": "message", "recipient_session_id": "session",
                        "recipient_authorization_generation": "generation", "state": "acknowledged"]
        let message = Record(values: ["id": "message", "project_id": "p", "task_id": "t", "human_request_id": "request", "human_response_id": "response",
                                     "form_revision": 1, "origin": "human_ui", "deliveries": [delivery]])
        let projection = RequestAnswerDeliveryProjection.make(request: request, response: response, messages: [message], sessions: [], snapshotCurrent: false, serviceUpgrading: true)
        XCTAssertTrue(projection.summary.contains("Checklist is upgrading"))
        XCTAssertFalse(projection.summary.contains("disconnected"))
        XCTAssertEqual(projection.recipients.count, 1)
    }
    func testWireErrorKeepsUpgradeDetailsForBanner() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "preparation_validation", estimatedRemainingSeconds: 90)), failure = status.error()
        fixture.envelope = ["error": ["code": failure.code, "message": failure.message, "details": failure.details]]
        let store = fixture.store(isolatedDefaults("StorageUpgradeEnvelope").preferences); defer { store.stopWindowReads() }
        await store.refresh()
        XCTAssertEqual(store.storageUpgradeStatus, status)
        XCTAssertTrue(store.connectionBannerMessage.contains("about 2 minutes"))
    }
}

@MainActor private final class UpgradeDisplayAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { XCTFail("Upgrade display never requests notification permission"); return false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Upgrade display never sends a notification") }
    func remove(_ identifiers: [String]) {}
}
