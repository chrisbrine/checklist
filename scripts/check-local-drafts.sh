#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRAFT_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checklist-local-drafts.XXXXXX")"
trap 'rm -rf "$DRAFT_CHECK_DIR"' EXIT
cat > "$DRAFT_CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }; checks += 1
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("private-drafts")
let journal = LocalDraftJournal(directory: root)
let scope = DraftScope(storeIncarnation: "store-A", projectID: "project-A", entityID: "ticket-A")
let note = StoredNoteDraft(text: "長い note\nwith unsent context", destination: "attempt-A", scope: scope)
try journal.save(note, kind: "note", key: "ticket-A")
let relaunched = LocalDraftJournal(directory: root)
let restored = try relaunched.load(StoredNoteDraft.self, kind: "note")["ticket-A"]!
check(restored.text == note.text && restored.destination == "attempt-A" && restored.scope == scope, "Relaunch must retain the unsent text, exact destination and scoped origin together")
check(scope.matches(store: "store-A", project: "project-A", entity: "ticket-A"), "Exact current scope should reconcile")
check(!scope.matches(store: "restored-store", project: "project-A", entity: "ticket-A"), "Restored store incarnation must require explicit reconciliation")
check(!scope.matches(store: "store-A", project: "project-B", entity: "ticket-A") && !scope.matches(store: "store-A", project: "project-A", entity: "ticket-B"), "Changing project or ticket must not inherit a saved draft's authority")
let edit = TaskEditDraft(title: "Unsaved title", brief: "Unsaved brief", baseRevision: 12, editing: true, hasChanges: true, scope: scope)
try journal.save(edit, kind: "edit", key: "ticket-A")
let restoredEdit = try relaunched.load(TaskEditDraft.self, kind: "edit")["ticket-A"]!
check(restoredEdit.editing && restoredEdit.hasChanges && restoredEdit.title == edit.title && restoredEdit.brief == edit.brief && restoredEdit.baseRevision == 12, "Closing/removing an overlay must retain editor state and the starting revision")
let capture = CaptureDraft(projectID: "project-A", title: "Unsent capture", brief: "Do not migrate across projects", kind: "bug", epicID: "epic-A", storeIncarnation: "store-A")
try journal.save(capture, kind: "capture", key: "project-A")
let captureB = CaptureDraft(projectID: "project-B", title: "Other capture", brief: "", kind: "work", epicID: "", storeIncarnation: "store-A")
try journal.save(captureB, kind: "capture", key: "project-B")
let captures = try relaunched.load(CaptureDraft.self, kind: "capture")
check(captures["project-A"]?.title == "Unsent capture" && captures["project-B"]?.title == "Other capture", "Project switching must retain separate capture drafts")
var answer = AnswerDraft(revision: 9); answer.formRevision = 4; answer.targetIdentity = "exact-form"; answer.values = ["approval": "approved"]; answer.explanation = "Owner explanation"
try journal.save(StoredAnswerDraft(draft: answer, scope: scope), kind: "answer", key: "request-A")
let restoredAnswer = try relaunched.load(StoredAnswerDraft.self, kind: "answer")["request-A"]!
check(restoredAnswer.draft.values == answer.values && restoredAnswer.draft.formRevision == 4 && restoredAnswer.draft.targetIdentity == "exact-form", "Answer choices must retain the exact form/target identity")
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
check(files.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600 }, "Draft files must be owner-only")
let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
check(directoryPermissions?.intValue == 0o700, "The private draft directory must be owner-only")
let blocked = root.deletingLastPathComponent().appendingPathComponent("not-a-directory")
try Data("Leave existing bytes intact".utf8).write(to: blocked)
do { try LocalDraftJournal(directory: blocked).save(note, kind: "note", key: "ticket-A"); fatalError("Failed writes cannot report Saved") }
catch { checks += 1 }
let preserved = try Data(contentsOf: blocked)
check(preserved == Data("Leave existing bytes intact".utf8), "A failed draft write must not replace unrelated existing bytes")
let noteFile = files.first { $0.lastPathComponent.hasPrefix("note-") }!
try Data("corrupted journal fixture".utf8).write(to: noteFile)
try journal.save(StoredNoteDraft(text: "Readable other note", destination: "", scope: scope), kind: "note", key: "ticket-other")
do { _ = try relaunched.load(StoredNoteDraft.self, kind: "note"); fatalError("Corrupt drafts must produce a visible recovery error") }
catch { checks += 1 }
check(FileManager.default.fileExists(atPath: noteFile.path), "A load failure must retain the corrupt file for recovery")
let recovered = try relaunched.recover(StoredNoteDraft.self, kind: "note")
check(recovered.values["ticket-other"]?.text == "Readable other note" && !recovered.errors.isEmpty, "A damaged entry must not hide other recoverable drafts")
do { try journal.save(note, kind: "../unsafe", key: "ticket-A"); fatalError("Unsafe journal namespaces must be rejected") }
catch { checks += 1 }
print("\(checks) local draft persistence checks passed")
SWIFT
xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name ChecklistIPC "$PROJECT_ROOT/Sources/ChecklistIPC/Protocol.swift" "$PROJECT_ROOT/Sources/ChecklistIPC/ChecklistInstance.swift" -emit-module-path "$DRAFT_CHECK_DIR/ChecklistIPC.swiftmodule" -o "$DRAFT_CHECK_DIR/libChecklistIPC.dylib"
IPC_LINK=(-I "$DRAFT_CHECK_DIR" -L "$DRAFT_CHECK_DIR" -lChecklistIPC -Xlinker -rpath -Xlinker "$DRAFT_CHECK_DIR")
xcrun swiftc "${IPC_LINK[@]}" "$PROJECT_ROOT/Sources/ChecklistApp/Models/Record.swift" "$PROJECT_ROOT/Sources/ChecklistApp/Support/LocalDraftPersistence.swift" "$DRAFT_CHECK_DIR/main.swift" -o "$DRAFT_CHECK_DIR/check-local-drafts"
"$DRAFT_CHECK_DIR/check-local-drafts" "$DRAFT_CHECK_DIR"
cat > "$DRAFT_CHECK_DIR/store-check.swift" <<'SWIFT'
import Foundation
import SwiftUI

// Only native transport/notifications/keychain are replaced. The actual Store,
// draft models and journal run unchanged against disposable preferences/files.
final class ChecklistClient: @unchecked Sendable {
    static var calls = 0
    init(owner: Bool) {}
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        Self.calls += 1
        throw ChecklistError("OUTCOME_UNKNOWN", "Synthetic lost reply")
    }
}
enum BuildIdentity { static let current = "fixture" }
final class DiagnosticsRecorder { static let shared = DiagnosticsRecorder(); func record(_ error: String?) {} }
final class DesktopAlertCoordinator { static let shared = DesktopAlertCoordinator(); func observe(snapshot: [String: Any]) async {} }
enum HumanClaims {
    static var values: [String: String] = [:]
    static var saves = 0
    static func read(_ key: String) -> String? { values[key] }
    static func save(_ value: String, attempt: String) throws { values[attempt] = value; saves += 1 }
    static func remove(_ key: String) { values.removeValue(forKey: key) }
}
@main struct StoreDraftChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { guard value() else { fatalError(message) }; checks += 1 }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("store-drafts")
        let suite = "Checklist.DraftFixture." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let journal = LocalDraftJournal(directory: root)
        func snapshot(_ incarnation: String = "store-A", _ attempt: String = "attempt-A") -> [String: Any] {
            ["service": ["store_incarnation": incarnation], "tasks": [["id": "ticket", "project_id": "project", "active_attempt_id": attempt]], "requests": [["id": "request", "project_id": "project"]]]
        }
        let store = ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false)
        store.data = snapshot(); store.connected = true
        store.saveNote("ticket", text: "Unsent owner note")
        check(store.noteDestinations["ticket"] == "attempt-A" && store.draftSaveError("note", "ticket") == nil, "A note and its shown destination must persist together")
        store.data = snapshot("store-A", "attempt-B")
        check(store.noteDestinations["ticket"] == "attempt-A", "Live handler changes cannot silently retarget an unsent note")
        var answer = AnswerDraft(revision: 2); answer.targetIdentity = "form-A"; store.saveAnswer("request", draft: answer)
        let reopened = ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false); reopened.data = snapshot()
        check(reopened.noteDrafts["ticket"] == "Unsent owner note" && reopened.answerDrafts["request"]?.targetIdentity == "form-A", "Actual Store relaunch must restore note and answer drafts")
        reopened.data = snapshot("restored-store")
        check(reopened.noteDraftNeedsReconciliation("ticket") && reopened.answerDraftNeedsReconciliation("request", project: "project"), "A new store incarnation must not silently reuse draft destination/form authority")
        reopened.saveNote("ticket", text: "Edited while unreconciled")
        check(reopened.noteDraftNeedsReconciliation("ticket"), "Typing cannot implicitly approve a restored-store destination")
        reopened.refreshNoteDestination("ticket")
        check(!reopened.noteDraftNeedsReconciliation("ticket"), "Explicitly refreshing the destination may reconcile the retained note")
        let blocked = root.deletingLastPathComponent().appendingPathComponent("blocked-journal")
        try Data("blocked".utf8).write(to: blocked)
        let failed = ChecklistStore(draftJournal: LocalDraftJournal(directory: blocked), preferences: preferences, restorePendingCommand: false); failed.data = snapshot()
        failed.saveNote("ticket", text: "Retain in memory after failed write")
        check(failed.noteDrafts["ticket"] == "Retain in memory after failed write" && failed.draftSaveError("note", "ticket") != nil, "A failed actual Store save must retain text and expose Not saved")
        try FileManager.default.removeItem(at: blocked); failed.retryDraftSave("note", "ticket")
        check(failed.draftSaveError("note", "ticket") == nil, "Retry must report Saved only after the journal recovers")
        store.connected = false
        let priorSaves = HumanClaims.saves
        store.run("task_complete", ["project_id": "project", "task_id": "ticket"])
        check(ChecklistClient.calls == 0 && HumanClaims.saves == priorSaves && !store.hasPendingMutation, "Offline authoritative commands must neither send nor create a replayable claim/completion")
        do { _ = try await store.request("message_send", ["command_id": UUID().uuidString]); fatalError("Offline direct mutation bypassed the guard") }
        catch { check((error as? ChecklistError)?.code == "SERVICE_UNAVAILABLE" && ChecklistClient.calls == 0, "Direct attachment/note writes must respect the offline boundary") }
        let commandID = UUID().uuidString
        let pending: [String: Any] = ["method": "message_send", "params": ["command_id": commandID, "project_id": "project", "body": "pending"]]
        HumanClaims.values["pending-command"] = String(data: try JSONSerialization.data(withJSONObject: pending), encoding: .utf8)
        let uncertain = ChecklistStore(draftJournal: journal, preferences: preferences); uncertain.data = snapshot()
        uncertain.retryPendingMutation()
        check(uncertain.hasPendingMutation && ChecklistClient.calls == 0, "Offline reconciliation must retain the original command without sending")
        uncertain.connected = true; uncertain.retryPendingMutation()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(uncertain.hasPendingMutation && HumanClaims.values["pending-command"]?.contains(commandID) == true, "An unknown outcome must preserve its exact command identity for reconciliation")
        print("\(checks) Store draft/offline checks passed")
    }
}
SWIFT
xcrun swiftc -swift-version 5 -parse-as-library "${IPC_LINK[@]}" "$PROJECT_ROOT/Sources/ChecklistApp/Models/Record.swift" "$PROJECT_ROOT/Sources/ChecklistApp/Support/LocalDraftPersistence.swift" "$PROJECT_ROOT/Sources/ChecklistApp/Stores/ChecklistStore.swift" "$DRAFT_CHECK_DIR/store-check.swift" -o "$DRAFT_CHECK_DIR/check-store-drafts"
"$DRAFT_CHECK_DIR/check-store-drafts" "$DRAFT_CHECK_DIR"
