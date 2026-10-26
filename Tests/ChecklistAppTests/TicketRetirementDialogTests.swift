import XCTest
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class TicketRetirementDialogTests: XCTestCase {
    private let task = Record(values: ["id": "ticket", "project_id": "project", "revision": 3])
    private func scope(epoch: UUID = UUID(), store: String = "store", readable: Bool = true) -> ArchiveConfirmationState.Scope {
        .init(task: task, store: store, settingsRevision: 2, epoch: epoch, readable: readable)
    }
    private var preview: [String: Any] {
        ["project_id": "project", "task_id": "ticket", "task_revision": 3, "settings_revision": 2,
         "cleanup_preview_id": "exact-preview", "clean_bytes": 0, "retained_bytes": 3009188,
         "holds": [["reasons": ["sharedLiveReference"]]], "budget_excess_bytes": 0]
    }

    func testSelectionAndClosedSheetNeverReadRetention() async {
        let state = ArchiveConfirmationState()
        var calls = 0
        for current in [scope(), scope(), scope(store: "another-store"), scope(readable: false)] {
            await state.load(current) { calls += 1; return self.preview }
        }
        XCTAssertFalse(state.presented)
        XCTAssertEqual(calls, 0, "Ticket selection and epoch changes must not prefetch retention")
    }

    func testClosingSheetDiscardsReplyBeforeDisappearanceCleanup() async {
        let state = ArchiveConfirmationState(), current = scope()
        let started = expectation(description: "archive read started")
        var pending: CheckedContinuation<[String: Any], Error>?
        state.present()
        let read = Task { await state.load(current) {
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        } }
        await fulfillment(of: [started])
        state.presented = false
        pending?.resume(returning: fixtureReply(preview)); await read.value
        XCTAssertNil(state.preview(for: current))
        XCTAssertNil(state.failure(for: current))
    }

    func testArchivePresentsBeforeReadStartsAndEveryOpeningUsesAFreshRead() async throws {
        let state = ArchiveConfirmationState(), current = scope()
        let started = expectation(description: "clicked archive preview started")
        var pending: CheckedContinuation<[String: Any], Error>?
        var calls = 0
        state.present()
        XCTAssertTrue(state.presented, "Presentation must happen before requesting retention")
        XCTAssertNil(state.preview(for: current), "Loading must never look like zero retained bytes")
        XCTAssertEqual(calls, 0)
        let read = Task { await state.load(current) {
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        } }
        await fulfillment(of: [started])
        XCTAssertTrue(state.presented, "A slow service must not gate presentation")
        XCTAssertNil(state.preview(for: current))
        pending?.resume(returning: fixtureReply(preview))
        await read.value
        let loaded = try XCTUnwrap(state.preview(for: current))
        XCTAssertEqual(loaded["cleanup_preview_id"] as? String, "exact-preview")
        XCTAssertEqual(loaded["retained_bytes"] as? Int, 3009188)
        XCTAssertTrue(ArchiveConfirmationState.description(loaded).contains("shared live reference"))
        state.presented = false; state.present()
        XCTAssertNil(state.preview(for: current), "Reopening cannot reuse old retention")
        await state.load(current) { calls += 1; return self.preview }
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(state.preview(for: current))
    }

    func testServiceChangesInvalidateBeforeReloadAndLateRepliesCannotReplaceCurrentPreview() async throws {
        let state = ArchiveConfirmationState(), first = scope(), next = scope()
        let started = expectation(description: "old observation started")
        var pending: CheckedContinuation<[String: Any], Error>?
        state.present()
        let read = Task { await state.load(first) {
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        } }
        await fulfillment(of: [started])
        state.invalidate()
        XCTAssertTrue(state.presented)
        XCTAssertNil(state.preview(for: next))
        XCTAssertNotEqual(ArchiveConfirmationState.LoadKey(scope: first, presented: true, retry: first.epoch),
                          ArchiveConfirmationState.LoadKey(scope: next, presented: true, retry: first.epoch),
                          "An open sheet must reload when the epoch changes")
        var fresh = preview; fresh["cleanup_preview_id"] = "new-observation"
        await state.load(next) { fresh }
        pending?.resume(returning: fixtureReply(preview)); await read.value
        XCTAssertEqual(state.preview(for: next)?["cleanup_preview_id"] as? String, "new-observation")
        XCTAssertNil(state.preview(for: first))
        XCTAssertNil(state.preview(for: scope(store: "restored-store")))
        XCTAssertNil(state.preview(for: scope(readable: false)))
    }

    func testArchiveFailureAndRevisionMismatchCannotEnableConfirmationAndRetryCanRecover() async {
        let state = ArchiveConfirmationState(), current = scope()
        state.present()
        await state.load(current) { throw ChecklistError("SERVICE_UNAVAILABLE", "Offline") }
        XCTAssertTrue(state.presented); XCTAssertNil(state.preview(for: current))
        XCTAssertNotNil(state.failure(for: current))
        for field in ["task_id", "project_id", "task_revision", "settings_revision"] {
            var mismatch = preview
            mismatch[field] = field.hasSuffix("revision") ? 99 : "different"
            await state.load(current) { mismatch }
            XCTAssertNil(state.preview(for: current), field)
            XCTAssertNotNil(state.failure(for: current), field)
        }
        await state.load(current) { preview }
        XCTAssertNotNil(state.preview(for: current)); XCTAssertNil(state.failure(for: current))
    }

    func testLeavingTicketOrCancelingReadDiscardsItsReplyAndUnreadableScopeMakesNoCall() async {
        let state = ArchiveConfirmationState(), current = scope()
        let started = expectation(description: "read started")
        var pending: CheckedContinuation<[String: Any], Error>?
        state.present()
        let read = Task { await state.load(current) {
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        } }
        await fulfillment(of: [started])
        state.cancel(); read.cancel()
        pending?.resume(returning: fixtureReply(preview)); await read.value
        XCTAssertFalse(state.presented); XCTAssertNil(state.preview(for: current))
        state.present()
        await state.load(scope(readable: false)) { XCTFail("No read while selection/offline state is unresolved"); return self.preview }
        XCTAssertNil(state.preview(for: current))
    }

    func testForeignServiceCoverageInvalidatesRetentionWithoutStartingAPreviewRead() async throws {
        let defaults = isolatedDefaults("ArchiveCoverage")
        defaults.preferences.set(Page.tasks.rawValue, forKey: "lastPage")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-coverage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: defaults.preferences,
                                   restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: ArchiveCoverageAlertSink()), requestTransport: { method, _ in
            calls.append(method); return [:]
        })
        let before = store.archivePreviewEpoch
        await store.applyChangeCoverage(["coverage": ["schema_version": 2, "complete": true, "reset": false,
            "changes": [["project_id": "foreign-project", "families": ["attachments"], "all_tasks": false, "task_ids": ["another-ticket"]]]]])
        XCTAssertNotEqual(store.archivePreviewEpoch, before)
        XCTAssertTrue(calls.isEmpty, "Invalidation alone must not add speculative service reads")
    }

    func testEveryActionHasTheRightTitleAndConfirmButtonBeforeTyping() {
        let expected: [(TicketRetirementAction, String, String, String)] = [
            (.cancel, "Cancel ticket", "Cancel ticket", "Reason for canceling"),
            (.trash, "Move ticket to Trash", "Move to Trash", "Reason for moving to Trash"),
            (.reopen, "Reopen ticket", "Reopen ticket", "Reason for reopening")
        ]
        XCTAssertEqual(Set(expected.map { $0.0 }), Set(TicketRetirementAction.allCases))
        for (action, title, confirm, prompt) in expected {
            let sheet = TicketRetirementReasonSheet(action: action, busy: false, connected: true) { _ in
                XCTFail("Building the dialog must not perform the action")
            }
            // These immutable values are the dialog's Text, Button and TextField inputs.
            // No appearance callback or reason-field edit is needed to populate them.
            XCTAssertEqual(sheet.title, title)
            XCTAssertEqual(sheet.confirmLabel, confirm)
            XCTAssertEqual(sheet.reasonPrompt, prompt)
            if action == .reopen {
                XCTAssertTrue(sheet.explanation.contains("returns to Queued"))
            } else {
                XCTAssertTrue(sheet.explanation.contains("Active work must be released"))
            }
        }
    }
}

@MainActor private final class ArchiveCoverageAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { XCTFail("No notification access in archive coverage test"); return .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { XCTFail("No notification permission request"); return false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("No notifications in archive coverage test") }
    func remove(_ identifiers: [String]) { XCTFail("No notifications in archive coverage test") }
}
