import XCTest
import SwiftUI
import ChecklistIPC
@testable import ChecklistApp

/// Only fake transports, in-memory command persistence and synthetic native UI.
@MainActor final class BackupWriteAdmissionTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-admission-" + UUID().uuidString)
        let defaults = IsolatedDefaults("BackupAdmission")
        var saved: String?
        var removals = 0
        var calls: [(String, [String: Any])] = []
        var locked = true
        var generation = "synthetic-service"
        var revision = 1
        var queuedID: String?
        var statusState = "queued"
        var statusResult: [String: Any]?
        var retryOriginal = false
        var holdStatus = true
        var heldStatus: CheckedContinuation<[String: Any], Never>?
        var heldRead: CheckedContinuation<[String: Any], Never>?
        var holdRead = false
        var admission: [String: Any] {
            var values: [String: Any] = ["generation": generation, "revision": revision, "locked": locked, "queued": locked,
             "backup_active": locked, "reason": locked ? "backup_in_progress" : "",
             "message": locked ? "A backup is in progress. Writes are locked and queued." : "",
             "estimated_remaining_seconds": NSNull()]
            if locked { values["estimated_remaining_seconds"] = 2.4 }
            return values
        }
        func status() -> [String: Any] {
            var data: [String: Any] = ["state": statusState]
            if let statusResult { data["result"] = statusResult }
            if retryOriginal { data["retry_original"] = true }
            return ["data": data, "write_admission": admission]
        }
        func request(_ method: String, _ params: [String: Any]) async -> [String: Any] {
            calls.append((method, params))
            if method == "command_status" {
                if holdStatus { return await withCheckedContinuation { heldStatus = $0 } }
                return status()
            }
            if method == "service_info" {
                if holdRead { return await withCheckedContinuation { heldRead = $0 } }
                return ["data": ["store_incarnation": "synthetic-backup-store"], "write_admission": admission]
            }
            if !CommandReply.readMethods.contains(method), let command = params["command_id"] as? String {
                if retryOriginal, queuedID == command, statusState == "applied" {
                    return ["command_id": command, "data": ["attempt_id": "synthetic-attempt", "claim_token": "refreshed-token"], "write_admission": admission]
                }
                queuedID = command
                return ["command_id": command, "command_outcome": "queued", "write_admission": admission,
                        "data": ["state": "queued", "queued": true, "status_method": "command_status", "command_id": command]]
            }
            return ["data": [:], "write_admission": admission]
        }
        func store() -> ChecklistStore {
            let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: defaults.preferences,
                restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: BackupAdmissionNoAlerts()),
                requestTransport: { [self] in await request($0, $1) }, navigationMemory: DetailItemNavigationMemory(),
                pendingCommandPersistence: .init(read: { [self] _ in saved }, save: { [self] value, _ in saved = value },
                    remove: { [self] _ in saved = nil; removals += 1 }))
            store.data = ["service": ["store_incarnation": "synthetic-backup-store"]]
            store.connected = true; store.queuedCommandPause = 1_000_000
            return store
        }
        func releaseStatus() { let reply = status(); heldStatus?.resume(returning: reply); heldStatus = nil }
        func cleanup() { try? defaults.clean(); try? FileManager.default.removeItem(at: root) }
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Synthetic queue observation did not settle")
    }

    func testReadsShowBackupReasonAndEstimateThenClearLockWithoutOffline() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let store = f.store(); defer { store.stopWindowReads() }
        let info = try await store.request("service_info")
        XCTAssertEqual(info["store_incarnation"] as? String, "synthetic-backup-store")
        XCTAssertTrue(store.connected); XCTAssertFalse(store.showsOfflineBanner)
        XCTAssertTrue(store.showsWriteAdmissionBanner)
        XCTAssertEqual(store.writeAdmission?.reason, "backup_in_progress")
        XCTAssertEqual(store.writeAdmission?.estimateText, "Estimated wait: about 3 seconds.")
        f.locked = false; f.revision += 1
        _ = try await store.request("service_info")
        XCTAssertFalse(store.showsWriteAdmissionBanner)
        XCTAssertTrue(store.connected); XCTAssertNil(store.lastServiceFailure)
    }

    func testQueuedMutationKeepsSavedCommandAndDraftUntilOriginalResultApplies() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let store = f.store(); defer { store.stopWindowReads() }
        var draft = "Preserved draft", completed: [String: Any]?
        store.run("media_round_create", ["project_id": "p", "title": draft], success: "Saved", completion: { completed = $0; draft = "" })
        try await settle { f.heldStatus != nil }
        let command = try XCTUnwrap(f.queuedID)
        XCTAssertTrue(store.busy); XCTAssertEqual(store.pendingCommandID, command)
        XCTAssertTrue(store.pendingMutationQueued); XCTAssertNotNil(f.saved); XCTAssertEqual(f.removals, 0)
        XCTAssertEqual(draft, "Preserved draft"); XCTAssertNil(completed)
        XCTAssertTrue(store.showsWriteAdmissionBanner); XCTAssertFalse(store.showsOfflineBanner)
        XCTAssertEqual(f.calls.filter { $0.0 == "media_round_create" }.count, 1)
        XCTAssertEqual(f.calls.first { $0.0 == "command_status" }?.1["project_id"] as? String, "p")
        f.locked = false; f.revision += 1; f.statusState = "applied"
        f.statusResult = ["command_id": command, "data": ["id": "synthetic-round", "title": "Preserved draft"]]
        f.releaseStatus()
        try await settle { !store.busy }
        XCTAssertEqual(completed?["id"] as? String, "synthetic-round"); XCTAssertEqual(draft, "")
        XCTAssertNil(f.saved); XCTAssertEqual(f.removals, 1); XCTAssertNil(store.pendingCommandID)
        XCTAssertFalse(store.hasPendingMutation); XCTAssertTrue(store.queuedCommandIDs.isEmpty)
        XCTAssertFalse(store.showsWriteAdmissionBanner); XCTAssertNil(store.error)
    }

    func testUnknownQueuedStatusRetainsRecoveryAndDoesNotCompleteDraft() async throws {
        let f = Fixture(); defer { f.cleanup() }; f.holdStatus = false; f.statusState = "unknown"
        let store = f.store(); defer { store.stopWindowReads() }
        var completed = false
        store.run("media_round_create", ["project_id": "p", "title": "Draft"], completion: { _ in completed = true })
        try await settle { !store.busy }
        XCTAssertFalse(completed); XCTAssertTrue(store.hasPendingMutation)
        XCTAssertNotNil(f.saved); XCTAssertEqual(f.removals, 0)
        XCTAssertNotNil(store.error); XCTAssertFalse(store.showsOfflineBanner)
    }

    func testAppliedClaimReplaysExactOriginalCommandToRefreshRedactedToken() async throws {
        let f = Fixture(); defer { f.cleanup() }; f.retryOriginal = true
        let store = f.store(); defer { store.stopWindowReads() }
        let params: [String: Any] = ["project_id": "p", "task_id": "synthetic-ticket", "command_id": UUID().uuidString]
        let claim = Task { try await store.request("work_claim", params) }
        try await settle { f.heldStatus != nil }
        f.statusState = "applied"; f.locked = false; f.revision += 1; f.releaseStatus()
        let applied = try await claim.value
        XCTAssertEqual(applied["claim_token"] as? String, "refreshed-token")
        let claims = f.calls.filter { $0.0 == "work_claim" }
        XCTAssertEqual(claims.count, 2)
        for request in claims {
            XCTAssertEqual(request.1["command_id"] as? String, params["command_id"] as? String)
            XCTAssertEqual(request.1["task_id"] as? String, "synthetic-ticket")
        }
        XCTAssertTrue(store.queuedCommandIDs.isEmpty); XCTAssertFalse(store.showsOfflineBanner)
    }

    func testQuickCaptureKeepsOwnedScreenshotUntilQueuedAttachmentApplies() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let staging = f.root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let screenshot = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let bytes = Data("Synthetic screenshot bytes".utf8); try bytes.write(to: screenshot)
        let journal = LocalDraftJournal(directory: f.root.appendingPathComponent("drafts"))
        let model = QuickCaptureModel(journal: journal, preferences: f.defaults.preferences, stagingDirectory: staging,
            rawTransport: { method, params in
                if method == "task_create" { return ["command_id": params["command_id"]!, "data": ["id": "synthetic-ticket", "key": "S-1"]] }
                return await f.request(method, params)
            })
        model.queuedCommandPause = 1_000_000
        model.draft.projectID = "p"; model.draft.epicID = "e"; model.draft.title = "Keep screenshot"
        model.draft.files = [.init(path: screenshot.path, ownedStaging: true, commandID: UUID().uuidString)]
        let sending = Task { await model.send() }
        try await settle { f.heldStatus != nil }
        XCTAssertEqual(model.state, .sending)
        XCTAssertEqual(try Data(contentsOf: screenshot), bytes)
        XCTAssertFalse(try XCTUnwrap(model.draft.files.first).attached)
        XCTAssertEqual(model.writeAdmission?.reason, "backup_in_progress")
        let saved = try XCTUnwrap(journal.load(QuickCaptureDraft.self, kind: QuickCaptureModel.journalKind)["draft"])
        XCTAssertEqual(saved.files.first?.path, screenshot.path); XCTAssertFalse(saved.files.first?.attached ?? true)
        f.locked = false; f.revision += 1; f.statusState = "applied"
        f.statusResult = ["command_id": f.queuedID!, "data": ["id": "synthetic-attachment"]]
        f.releaseStatus(); await sending.value
        XCTAssertEqual(model.state, .captured(key: "S-1", taskID: "synthetic-ticket", projectID: "p"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: screenshot.path))
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(f.calls.filter { $0.0 == "attachment_add" }.count, 1)
    }

    func testInvalidOriginalHumanAnswerResultCannotClearRecovery() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let store = f.store(); defer { store.stopWindowReads() }
        var completed = false
        store.run("human_request_answer", ["project_id": "p", "request_id": "request"], completion: { _ in completed = true })
        try await settle { f.heldStatus != nil }
        f.statusState = "applied"
        f.statusResult = ["command_id": f.queuedID!, "data": ["state": "answered", "id": "request"]]
        f.releaseStatus()
        try await settle { !store.busy }
        XCTAssertFalse(completed); XCTAssertTrue(store.hasPendingMutation)
        XCTAssertNotNil(f.saved); XCTAssertEqual(f.removals, 0)
    }

    func testLateOldAdmissionCannotReinstateFinishedLockOrReplaceRestartedService() async throws {
        for restart in [false, true] {
            let f = Fixture(); defer { f.cleanup() }
            let store = f.store(); defer { store.stopWindowReads() }
            _ = try await store.request("service_info")
            let oldAdmission = f.admission
            f.holdRead = true
            let old = Task { try await store.request("service_info") }
            try await settle { f.heldRead != nil }
            f.holdRead = false; f.locked = false; f.revision = 2
            if restart { f.generation = "replacement-service"; f.revision = 1 }
            _ = try await store.request("service_info")
            f.heldRead?.resume(returning: ["data": ["store_incarnation": "synthetic-backup-store"], "write_admission": oldAdmission]); f.heldRead = nil
            _ = try await old.value
            XCTAssertFalse(store.showsWriteAdmissionBanner)
            XCTAssertEqual(store.writeAdmission?.generation, f.generation)
        }
    }

    func testNativeBannerExposesLockedReasonAndEstimate() async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface(); defer { restoreAX() }
        let f = Fixture(); defer { f.cleanup() }
        let state = try XCTUnwrap(WriteAdmissionState(f.admission))
        let host = NSHostingView(rootView: WriteAdmissionBanner(state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 650, height: 150), styleMask: [], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist backup admission check (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let facts = ["Writes are locked and queued", "A backup is in progress.", "Estimated wait: about 3 seconds."]
        try await AXProbe.until {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded()
            return facts.allSatisfy(AXProbe.text(host).contains)
        }
        let text = AXProbe.text(host)
        for fact in facts { XCTAssertTrue(text.contains(fact), fact) }
        XCTAssertFalse(text.contains("offline"))
    }
}

@MainActor private final class BackupAdmissionNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("No alerts in the backup admission fixture") }
    func remove(_ identifiers: [String]) {}
}
