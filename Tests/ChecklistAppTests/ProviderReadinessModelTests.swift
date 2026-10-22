import XCTest
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class ProviderReadinessModelTests: XCTestCase {
    private func context(_ project: String = "project", recipient: String = "session", epoch: UUID = UUID(), store: String = "store") -> ProviderReadinessContext {
        .init(projectID: project, root: "/fixture/\(project)", taskID: "ticket", recipient: recipient, recipientLabel: "Actual handler", serviceEpoch: epoch, storeIncarnation: store, connected: true)
    }
    private func observation() -> ProviderReadinessObservation {
        ProviderSettingsObservation.observe(projectRoot: "", home: URL(fileURLWithPath: "/nonexistent-owned-fixture"), environment: [:], managedPath: "/nonexistent-owned-fixture/managed")
    }
    func testContextChangesImmediatelyHideEarlierObservation() async {
        let model = ProviderReadinessModel(), first = context()
        await model.refresh(first) { _ in self.observation() }
        XCTAssertNotNil(model.observation(for: first))
        for next in [context("other"), context(recipient: "other"), context(epoch: UUID()), context(store: "restored")] {
            XCTAssertNil(model.observation(for: next))
        }
        model.invalidate(for: nil)
        XCTAssertNil(model.observation); XCTAssertFalse(model.loading)
    }
    func testLateReplyForOldProjectCannotFillNewContext() async {
        let model = ProviderReadinessModel(), first = context(), next = context("other")
        var resume: CheckedContinuation<ProviderReadinessObservation, Never>?
        let read = Task { await model.refresh(first) { _ in await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        model.invalidate(for: next)
        resume?.resume(returning: observation()); await read.value
        XCTAssertNil(model.observation); XCTAssertEqual(model.context, next); XCTAssertFalse(model.loading)
    }
    func testLaterRefreshWinsEvenInSameContext() async {
        let model = ProviderReadinessModel(), target = context()
        var resume: CheckedContinuation<ProviderReadinessObservation, Never>?
        let read = Task { await model.refresh(target) { _ in await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        await model.refresh(target) { _ in self.observation() }
        let accepted = model.observation?.observedAt
        resume?.resume(returning: observation()); await read.value
        XCTAssertEqual(model.observation?.observedAt, accepted)
    }
    func testHostEventInvalidatesInFlightObservationWithoutAutomaticRead() async {
        let model = ProviderReadinessModel(), first = context(), afterHostHold = context()
        var resume: CheckedContinuation<ProviderReadinessObservation, Never>?
        let read = Task { await model.refresh(first) { _ in await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        model.invalidate(for: afterHostHold)
        resume?.resume(returning: observation()); await read.value
        XCTAssertNil(model.observation); XCTAssertFalse(model.loading)
        XCTAssertEqual(model.context, afterHostHold)
    }
    func testCurrentTicketHandlerIsScopedToSelectedProject() throws {
        let defaults = isolatedDefaults("ProviderReadinessModelTests")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: defaults.preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: ReadinessTestAlertSink()),
                                   requestTransport: { _, _ in throw NSError(domain: "UnexpectedReadinessTestRequest", code: 1) })
        store.data = ["projects": [["id": "p", "name": "Fixture", "root_path": "/fixture"], ["id": "other", "root_path": "/other"]],
                      "tasks": [["id": "ticket", "key": "SYN-1", "project_id": "p", "active_attempt_id": "attempt"]],
                      "attempts": [["id": "attempt", "task_id": "ticket", "session_id": "worker", "state": "active"]],
                      "sessions": [["id": "worker", "name": "Fixture worker", "provider": "claude", "role": "worker", "installation": "generation-a", "state": "live"]]]
        store.projectID = "p"
        XCTAssertEqual(store.providerReadinessContext?.root, "/fixture")
        XCTAssertEqual(store.providerReadinessContext?.recipient, "")
        XCTAssertTrue(store.providerReadinessContext?.recipientLabel.contains("no current ticket recipient") == true)
        store.detail = .task("ticket")
        XCTAssertTrue(store.providerReadinessContext?.recipient.hasPrefix("worker|generation-a|") == true)
        XCTAssertTrue(store.providerReadinessContext?.recipientLabel.contains("Fixture worker") == true)
        store.projectID = "other"
        XCTAssertEqual(store.providerReadinessContext?.recipient, "")
        store.projectID = nil
        XCTAssertNil(store.providerReadinessContext)
    }
}

@MainActor private final class ReadinessTestAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .notRequested }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { XCTFail("No permission request authorized"); return false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("No notification authorized") }
    func remove(_ identifiers: [String]) {}
}
