import XCTest
import SwiftUI
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class ApplicationTerminationTests: XCTestCase {
    func testOpenWorkspaceCaptureDoesNotVetoQuit() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root),
            preferences: isolatedDefaults("Quit").preferences, restorePendingCommand: false,
            desktopAlerts: DesktopAlertCoordinator(sink: TerminationAlertSink()),
            requestTransport: { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") })
        store.saveCapture(CaptureDraft(projectID: "", title: "Keep blank", brief: "Keep note", kind: "work", epicID: "", storeIncarnation: ""))
        let window = NSWindow(contentRect: NSRect(x: -9000, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Workspace").sheet(isPresented: .constant(true)) {
            CaptureTaskView().environmentObject(store)
        })
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        let deadline = Date().addingTimeInterval(3)
        while window.attachedSheet == nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal,
                       "A durably saved capture must not silently veto the app's Quit command")
        let coordinator = CaptureTerminationCoordinator()
        coordinator.register(store)
        try await assertQuit(coordinator, saved: true)
        let restored = makeStore(root)
        restored.projectID = "last-used"
        XCTAssertEqual(restored.captureInitialProjectID, "")
        XCTAssertEqual(restored.captureDrafts[""]?.title, "Keep blank")
        XCTAssertEqual(restored.captureDrafts[""]?.brief, "Keep note")
    }

    private func makeStore(_ root: URL) -> ChecklistStore {
        ChecklistStore(draftJournal: LocalDraftJournal(directory: root),
            preferences: isolatedDefaults("QuitStore").preferences, restorePendingCommand: false,
            desktopAlerts: DesktopAlertCoordinator(sink: TerminationAlertSink()),
            requestTransport: { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") })
    }

    private func makeModel(_ root: URL) -> QuickCaptureModel {
        let preferences = isolatedDefaults("QuitPanel").preferences
        preferences.set("last-used", forKey: QuickCaptureModel.lastProjectKey)
        return QuickCaptureModel(journal: LocalDraftJournal(directory: root), preferences: preferences) { _, _ in
            XCTFail("Quit must not wait for or replay a service command")
            throw ChecklistError("SERVICE_UNAVAILABLE", "offline")
        }
    }

    private func assertQuit(_ coordinator: CaptureTerminationCoordinator, saved: Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let replied = expectation(description: "terminateLater always receives a reply")
        replied.assertForOverFulfill = true
        var replies: [Bool] = [], messages: [String] = []
        let delegate = AppDelegate(termination: coordinator, reply: { replies.append($0); replied.fulfill() }, failure: { messages.append($0) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater, file: file, line: line)
        XCTAssertTrue(replies.isEmpty, "The reply must follow the terminateLater return", file: file, line: line)
        await fulfillment(of: [replied], timeout: 4)
        XCTAssertEqual(replies, [saved], file: file, line: line)
        XCTAssertEqual(messages.count, saved ? 0 : 1, file: file, line: line)
        if !saved { XCTAssertTrue(messages[0].contains("Checklist stayed open"), file: file, line: line) }
    }

    func testOpenFloatingCaptureQuitsAndRestoresBlankTextAndFiles() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-panel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        model.draft = QuickCaptureDraft(title: "Keep title", note: "Keep note")
        let file = root.appendingPathComponent("attachment.txt")
        try Data("Keep bytes".utf8).write(to: file)
        model.attach([file])
        let panel = QuickCapturePanel(contentRect: NSRect(x: -9000, y: 0, width: 480, height: 420),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuickCaptureView(model: model, close: {}, submitDraft: {}, openTicket: { _ in }))
        panel.orderFront(nil)
        defer { panel.contentView = nil; panel.close() }
        let coordinator = CaptureTerminationCoordinator()
        coordinator.register(model)
        let start = ContinuousClock.now
        try await assertQuit(coordinator, saved: true)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        let restored = makeModel(root)
        XCTAssertEqual(restored.draft, model.draft)
        XCTAssertEqual(restored.draft.projectID, "")
        XCTAssertFalse(restored.canSend)
        XCTAssertEqual(try Data(contentsOf: file), Data("Keep bytes".utf8))
    }

    func testWorkspaceSaveErrorCancelsQuitWithReplyAndVisibleReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-error-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root) // A regular file cannot contain the journal.
        let store = makeStore(root)
        store.saveCapture(CaptureDraft(projectID: "", title: "Unsaved title", brief: "Unsaved note", kind: "work", epicID: "", storeIncarnation: ""))
        XCTAssertNotNil(store.draftSaveError("capture", ""))
        let coordinator = CaptureTerminationCoordinator()
        coordinator.register(store)
        try await assertQuit(coordinator, saved: false)
        XCTAssertEqual(store.captureDrafts[""]?.title, "Unsaved title")
    }

    func testFloatingSaveErrorCancelsQuitAndCanRetryAfterStorageRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-error-panel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let model = makeModel(root)
        model.draft = QuickCaptureDraft(title: "Unsaved title")
        XCTAssertNotNil(model.problem)
        let coordinator = CaptureTerminationCoordinator()
        coordinator.register(model)
        try await assertQuit(coordinator, saved: false)
        try FileManager.default.removeItem(at: root)
        model.draft.note = "Storage repaired"
        try await assertQuit(coordinator, saved: true)
        XCTAssertEqual(makeModel(root).draft, model.draft)
    }

    func testTimeoutRepliesOnceAndLateCompletionCannotFinishNewQuit() async throws {
        var completions: [(Bool) -> Void] = []
        let coordinator = CaptureTerminationCoordinator(timeout: 0.05, verify: { _, complete in completions.append(complete) })
        let replied = expectation(description: "Timed out quit replies")
        var replies: [Bool] = [], messages: [String] = []
        let delegate = AppDelegate(termination: coordinator, reply: { replies.append($0); replied.fulfill() }, failure: { messages.append($0) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(completions.count, 1, "Repeated Quit shares the pending check")
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("took too long"))
        let retry = expectation(description: "Retry reply")
        let retryDelegate = AppDelegate(termination: coordinator, reply: { replies.append($0); retry.fulfill() }, failure: { _ in XCTFail("Retry should succeed") })
        XCTAssertEqual(retryDelegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        completions[0](true) // The timed-out storage check eventually returned.
        completions[1](true)
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertEqual(replies, [false, true])
    }

    func testEditsDuringQuitCheckCancelThenRetrySavesTheCurrentDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-edits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        model.draft = QuickCaptureDraft(title: "Before check")
        let coordinator = CaptureTerminationCoordinator(verify: { check, complete in
            do { try check(); model.draft.title = "Edited during check"; complete(true) }
            catch { complete(false) }
        })
        coordinator.register(model)
        try await assertQuit(coordinator, saved: false)
        let retry = CaptureTerminationCoordinator()
        retry.register(model)
        try await assertQuit(retry, saved: true)
        XCTAssertEqual(makeModel(root).draft.title, "Edited during check")
    }

    func testPendingCreateAndAttachmentRecoveryDoNotWaitForServiceOnQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for created in [false, true] {
            let model = makeModel(root)
            var draft = QuickCaptureDraft(title: "Next blank draft", note: "Next note")
            draft.pendingCreate = .init(commandID: "original-command", projectID: "original-project", title: "Original", brief: "Original note")
            if created { draft.createdTaskID = "saved-ticket" }
            model.draft = draft
            let coordinator = CaptureTerminationCoordinator()
            coordinator.register(model)
            try await assertQuit(coordinator, saved: true)
            XCTAssertEqual(makeModel(root).draft, draft)
        }
    }

    func testJournalMismatchCancelsQuitInsteadOfTrustingInMemorySaveStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-mismatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        model.draft = QuickCaptureDraft(title: "Current title")
        try LocalDraftJournal(directory: root).save(QuickCaptureDraft(title: "Earlier title"), kind: QuickCaptureModel.journalKind, key: "draft")
        let coordinator = CaptureTerminationCoordinator()
        coordinator.register(model)
        try await assertQuit(coordinator, saved: false)
        XCTAssertEqual(model.draft.title, "Current title")
    }
}

@MainActor private final class TerminationAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
