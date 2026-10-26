import Foundation
import XCTest
@testable import ChecklistApp

enum CheckFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}
let sha = String(repeating: "a", count: 64)
var task: Record { Record(values: ["id": "task", "project_id": "project", "current_manifest_id": "M2"]) }
func file(_ id: String, target: String? = nil, attempt: String? = nil) -> [String: Any] {
    var record: [String: Any] = ["id": id, "task_id": "task", "project_id": "project", "name": "results.xml", "path": "/managed/\(id).md", "mode": "managed", "availability": "available", "sha256": sha, "size": 100, "author": "reviewer", "revision": 1]
    if let target { record["target_manifest_id"] = target }
    if let attempt { record["review_attempt_id"] = attempt }
    return record
}
func manifest(_ id: String, time: String, artifactIDs: [String]) -> [String: Any] {
    ["id": id, "task_id": "task", "project_id": "project", "created_at": time,
     "evidence": ["artifact_refs": artifactIDs.map { ["artifact_id": $0, "sha256": sha] }]]
}
func projected(files: [[String: Any]] = [], M2refs: [String] = ["A2"], attempts: [[String: Any]] = []) -> TestResultEvidenceProjection {
    let data: [String: Any] = [
        "manifests": [manifest("M0", time: "2026-10-17T10:00:00Z", artifactIDs: ["A0"]),
                      manifest("M1", time: "2026-10-17T11:00:00Z", artifactIDs: []),
                      manifest("M2", time: "2026-10-17T12:00:00Z", artifactIDs: M2refs)],
        "attachments": [file("A0"), file("A1", target: "M1", attempt: "R1"), file("A2")] + files,
        "attempts": [["id": "R1", "phase": "review", "manifest_id": "M1", "task_id": "task", "project_id": "project"]] + attempts,
        "reviews": [] // The M1 reviewer upload exists before any verdict/evidence ref.
    ]
    return TestResultEvidenceProjection(review: ReviewProjection(task: task, project: nil, data: data))
}
var checks: [(String, () throws -> Void)] { [
    ("Unused M1 reviewer result stays bound before a verdict and compares to M0", {
        let projection = projected()
        let oldRows = projection.artifacts(in: "M1")
        try require(oldRows.count == 1 && oldRows[0].file.id == "A1", "Exact reviewer upload must be visible under M1 without verdict refs")
        let row = oldRows[0]
        try require(row.manifestID == "M1" && row.reviewAttemptID == "R1" && row.unavailable == nil, "Target, attempt and available original remain intact")
        try require(!projection.artifacts(in: nil).contains { $0.file.id == "A1" }, "M1 reviewer upload must never become unsubmitted under M2")
        try require(!projection.artifacts(in: "M2").contains { $0.file.id == "A1" }, "M2 must not relabel M1 reviewer bytes")
        try require(projection.previous(for: row)?.file.id == "A0", "M1 comparison must go back to M0, never forward to current M2")
        guard let current = projection.artifacts(in: "M2").first else { throw CheckFailure.failed("Missing M2") }
        try require(projection.previous(for: current)?.file.id == "A1", "M2 can compare to the actual previous M1 reviewer report")
    }),
    ("Genuine unsubmitted upload remains distinct from reviewer evidence", {
        let projection = projected(files: [file("new-upload")])
        let rows = projection.artifacts(in: nil)
        try require(rows.count == 1 && rows[0].file.id == "new-upload" && rows[0].manifestID == nil && rows[0].reviewAttemptID == nil, "Only genuine new upload is unsubmitted")
        try require(projection.previous(for: rows[0])?.file.id == "A2", "New upload may compare to current submitted target")
    }),
    ("A later reference cannot override service-recorded reviewer target", {
        let projection = projected(M2refs: ["A2", "A1"])
        try require(projection.artifacts(in: "M2").map { $0.file.id } == ["A2"], "Conflicting later ref cannot move reviewer evidence")
        let rows = projection.artifacts(in: "M1")
        try require(rows.count == 1 && rows[0].reviewAttemptID == "R1" && projection.previous(for: rows[0])?.manifestID == "M0", "Original binding and chronology are retained")
    }),
    ("Incomplete and conflicting reviewer metadata never falls into unsubmitted", {
        let extra = [file("missing-attempt", target: "M1"), file("missing-target", attempt: "R1"), file("unknown-target", target: "M9", attempt: "R9"), file("conflict", target: "M1", attempt: "wrong")]
        let wrong: [String: Any] = ["id": "wrong", "phase": "review", "manifest_id": "M2", "task_id": "task", "project_id": "project"]
        let projection = projected(files: extra, attempts: [wrong])
        try require(projection.artifacts(in: nil).isEmpty, "Malformed/unknown reviewer binding is not an unsubmitted upload")
        let bad = projection.artifacts(in: "M1").filter { $0.file.id != "A1" }
        try require(bad.count == 2 && bad.allSatisfy { $0.unavailable != nil && projection.previous(for: $0) == nil }, "Known-target binding conflicts stay unavailable without comparison")
        try require(projection.artifacts(in: "M9").isEmpty, "Unknown manifest does not invent a target")
        let unknown = TestResultArtifact(file: Record(values: extra[2]), expectedSHA256: sha, manifestID: "M9", reviewAttemptID: "R9", bindingProblem: nil)
        try require(projection.previous(for: unknown) == nil, "Missing historical target never falls forward to M2")
    }),
    ("Service target attribution survives bounded attempt-history loading", {
        let projection = projected(files: [file("older-reviewer", target: "M0", attempt: "not-loaded")])
        guard let row = projection.artifacts(in: "M0").first(where: { $0.file.id == "older-reviewer" }) else { throw CheckFailure.failed("Reviewer target disappeared with older attempt") }
        try require(row.manifestID == "M0" && row.reviewAttemptID == "not-loaded" && row.bindingProblem == nil, "Missing loaded attempt is not evidence that immutable service binding vanished")
        try require(!projection.artifacts(in: nil).contains { $0.file.id == row.file.id }, "History paging cannot relabel evidence")
        try require(projection.previous(for: row) == nil, "Oldest target has no later-target comparison")
    })
] }

final class TestResultEvidenceProjectionTests: XCTestCase {
    func testUnusedM1ReviewerResultStaysBoundBeforeAVerdictAndComparesToM0() throws { try checks[0].1() }
    func testGenuineUnsubmittedUploadRemainsDistinctFromReviewerEvidence() throws { try checks[1].1() }
    func testALaterReferenceCannotOverrideServiceRecordedReviewerTarget() throws { try checks[2].1() }
    func testIncompleteAndConflictingReviewerMetadataNeverFallsIntoUnsubmitted() throws { try checks[3].1() }
    func testServiceTargetAttributionSurvivesBoundedAttemptHistoryLoading() throws { try checks[4].1() }
}
