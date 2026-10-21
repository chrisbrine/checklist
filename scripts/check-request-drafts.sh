#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUEST_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checklist-request-drafts.XXXXXX")"
trap 'rm -rf "$REQUEST_CHECK_DIR"' EXIT
cat > "$REQUEST_CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

var checked = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checked += 1
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("originals")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let removed = directory.appendingPathComponent("removed.txt")
try Data("original A".utf8).write(to: removed)
var old = AnswerDraft(revision: 1)
old.formRevision = 1; old.targetIdentity = "old-form"
old.values = ["answer": "Current answer", "approval": "approved"]
old.paths = ["A": [removed.path]]
old.pathHashes = [removed.path: RequestDraftIdentity.fileHash(removed.path)!]
old.fileModes = ["A": "managed"]
old.explanations = ["A": "Original A explanation"]
old.explanation = "Keep my draft notes"
let archivedBytes = try JSONEncoder().encode(old)
let archiveKey = RequestDraftIdentity.archivedKey("request", draft: old)
let questions: [[String: Any]] = [["id": "answer", "type": "text", "required": true]]
func form(_ files: [[String: Any]]) -> Record {
    Record(values: ["id": "request", "revision": 2, "form_revision": 2, "form_identity": "new-form", "questions": questions, "file_requests": files, "form_history": [["questions": [["id": "approval", "type": "approval"]]]]])
}

// The actual review failure: A is removed, its original disappears, and the
// owner adopts the revised form. Hidden A must not disable the current Send.
try FileManager.default.removeItem(at: removed)
let removedForm = form([])
var beforeAdoption = old
check(RequestDraftIdentity.fileProblems(&beforeAdoption, fileRequests: []).isEmpty, "Removed file requests must not create hidden validation errors, even in a stale draft")
var adopted = RequestDraftIdentity.adoptingCurrentForm(old, request: removedForm)
let removedProblems = RequestDraftIdentity.fileProblems(&adopted, fileRequests: removedForm.records("file_requests"))
check(removedProblems.isEmpty && RequestDraftIdentity.isComplete(adopted, questions: removedForm.records("questions"), fileRequests: []), "Removing chosen A and deleting its original must allow answering the revised form")
check(adopted.paths.isEmpty && adopted.pathHashes.isEmpty && adopted.fileModes.isEmpty && adopted.explanations.isEmpty, "Adoption must deliberately remove obsolete selections, modes, hashes and file explanations")
check(adopted.explanation == "Keep my draft notes" && adopted.values["answer"] == "Current answer", "Current answer text and general notes must survive adoption")
check(adopted.values["approval"] == nil && adopted.formRevision == 2 && adopted.targetIdentity == "new-form", "Adoption must clear old decisions and bind the new form")
let archived = try JSONDecoder().decode(AnswerDraft.self, from: archivedBytes)
check(archiveKey.contains("form-1-old-form") && archived.paths["A"] == [removed.path] && archived.explanations["A"] == "Original A explanation" && archived.values["approval"] == "approved" && archived.explanation == old.explanation, "The identifiable archived old draft must retain the removed selection, prior choice and notes")

// Replacing A with required B must remove A without satisfying the new requirement.
let replacementFiles: [[String: Any]] = [["id": "B", "kind": "file", "required": true]]
let replacementForm = form(replacementFiles)
var replacement = RequestDraftIdentity.adoptingCurrentForm(old, request: replacementForm)
check(RequestDraftIdentity.fileProblems(&replacement, fileRequests: replacementForm.records("file_requests")).isEmpty, "Deleted obsolete A must not block a form that now renders B")
check(!RequestDraftIdentity.isComplete(replacement, questions: replacementForm.records("questions"), fileRequests: replacementForm.records("file_requests")), "Required replacement B must still require a fresh selection")
let selected = directory.appendingPathComponent("current-B.txt")
try Data("current B".utf8).write(to: selected)
replacement.paths["B"] = [selected.path]
replacement.pathHashes[selected.path] = RequestDraftIdentity.fileHash(selected.path)
check(RequestDraftIdentity.fileProblems(&replacement, fileRequests: replacementForm.records("file_requests")).isEmpty && RequestDraftIdentity.isComplete(replacement, questions: replacementForm.records("questions"), fileRequests: replacementForm.records("file_requests")), "A valid current B selection must permit answering")
try Data("changed B".utf8).write(to: selected)
check(RequestDraftIdentity.fileProblems(&replacement, fileRequests: replacementForm.records("file_requests"))[selected.path] != nil, "A changed current original must remain blocked")
try FileManager.default.removeItem(at: selected)
check(RequestDraftIdentity.fileProblems(&replacement, fileRequests: replacementForm.records("file_requests"))[selected.path] != nil, "A missing current original must remain blocked")

// A shared path remains protected when one obsolete request is removed.
let shared = directory.appendingPathComponent("shared.txt")
try Data("same original".utf8).write(to: shared)
var sharedDraft = old
sharedDraft.paths = ["A": [shared.path], "C": [shared.path]]
let sharedHash = RequestDraftIdentity.fileHash(shared.path)!
sharedDraft.pathHashes = [shared.path: sharedHash]
let sharedForm = form([["id": "C", "kind": "file", "required": true]])
sharedDraft = RequestDraftIdentity.adoptingCurrentForm(sharedDraft, request: sharedForm)
check(sharedDraft.paths["A"] == nil && sharedDraft.paths["C"] == [shared.path] && sharedDraft.pathHashes[shared.path] == sharedHash, "Removing A must retain the checksum of an original still selected for current C")
try Data("changed shared original".utf8).write(to: shared)
check(RequestDraftIdentity.fileProblems(&sharedDraft, fileRequests: sharedForm.records("file_requests"))[shared.path] != nil, "Current C must retain byte-change safety after obsolete A is removed")
print("\(checked) request draft checks passed")
SWIFT
xcrun swiftc "$PROJECT_ROOT/Sources/ChecklistApp/Models/Record.swift" "$PROJECT_ROOT/Sources/ChecklistApp/Models/RequestDraft.swift" "$REQUEST_CHECK_DIR/main.swift" -o "$REQUEST_CHECK_DIR/request-draft-check"
"$REQUEST_CHECK_DIR/request-draft-check" "$REQUEST_CHECK_DIR"
