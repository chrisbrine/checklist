import XCTest
@testable import ChecklistApp

final class StableListRowsTests: XCTestCase {
    private let task = Record(values: ["id": "task", "project_id": "project", "acceptance_revision": 2])
    func testAcceptanceReorderAndUnrelatedInsertionPreserveSemanticKeysNotOrdinals() {
        let before = StableListRows.acceptance(["A", "B"], task: task)
        let after = StableListRows.acceptance(["new", "B", "A"], task: task)
        XCTAssertEqual(before[0].id, after[2].id)
        XCTAssertEqual(before[1].id, after[1].id)
        XCTAssertEqual(after.map(\.number), [1, 2, 3])
        let revised = StableListRows.acceptance(["A"], task: Record(values: ["id": "task", "project_id": "project", "acceptance_revision": 3]))
        XCTAssertNotEqual(before[0].id, revised[0].id)
    }
    func testDuplicateAndExactByteScopeKeysDoNotCollapse() {
        let rows = StableListRows.values(["same", "other", "same"], scope: ["é"], key: { [$0] })
        let moved = StableListRows.values(["other", "same", "same"], scope: ["é"], key: { [$0] })
        XCTAssertEqual(rows[0].id, moved[1].id)
        XCTAssertEqual(rows[2].id, moved[2].id)
        XCTAssertNotEqual(rows[0].id, rows[2].id)
        XCTAssertNotEqual(rows[0].id, StableListRows.values(["same"], scope: ["e\u{301}"], key: { [$0] })[0].id)
        XCTAssertNotEqual(StableListRows.values([0], scope: ["a", "b:c"], key: { _ in [] })[0].id,
                          StableListRows.values([0], scope: ["a:b", "c"], key: { _ in [] })[0].id)
    }
    func testArtifactPolicyCheckAndRequirementUseDomainIdentityAcrossMoves() {
        let scope = Record(values: ["id": "scope", "project_id": "project"])
        let artifactA = Record(values: ["artifact_id": "a", "sha256": "h"]), artifactB = Record(values: ["artifact_id": "b", "sha256": "h"])
        XCTAssertEqual(StableListRows.artifacts([artifactA, artifactB], manifest: scope)[0].id,
                       StableListRows.artifacts([artifactB, artifactA], manifest: scope)[1].id)
        let a: [String: Any] = ["task_id": "a", "key": "DUP"], b: [String: Any] = ["task_id": "b", "key": "DUP"]
        XCTAssertNotEqual(StableListRows.policyPreview([a, b], projectID: "p")[0].id, StableListRows.policyPreview([a, b], projectID: "p")[1].id)
        let check = Record(values: ["id": "check", "label": "before", "result": "pass"])
        let edited = Record(values: ["id": "check", "label": "after", "result": "fail"])
        XCTAssertEqual(StableListRows.checks([check], review: scope)[0].id, StableListRows.checks([edited], review: scope)[0].id)
        let acceptance = Record(values: ["section": "acceptance", "requirement_id": "r", "requirement": "same"])
        let project = Record(values: ["section": "project_requirements", "requirement_id": "r", "requirement": "same"])
        XCTAssertNotEqual(StableListRows.assessments([acceptance, project], review: scope)[0].id, StableListRows.assessments([acceptance, project], review: scope)[1].id)
    }
    func testRemovedPinnedRowCannotRedirectStaleEditorToItsNeighbor() {
        var drafts = PinnedDecisionDrafts([["id": "a", "body": "first"], ["id": "b", "body": "second"]])
        let removed = drafts.rows[0].id, kept = drafts.rows[1].id
        drafts.remove(removed)
        drafts.setText("late edit", for: removed, key: "body")
        drafts.setKind(true, for: removed, kind: "bug", orderedKinds: ["work", "bug"])
        XCTAssertEqual(drafts.rows.count, 1)
        XCTAssertEqual(drafts.rows[0].id, kept)
        XCTAssertEqual(drafts.text(kept, "body"), "second")
        XCTAssertFalse(drafts.hasKind(kept, "bug"))
    }
    func testNewAndLegacyPinnedDraftIDsStayLocalAndExistingIdentityIsPreserved() {
        var drafts = PinnedDecisionDrafts(["legacy", ["id": "server", "body": "existing", "approved_by": "owner"]])
        drafts.appendEmpty()
        let local = drafts.rows[2].id
        drafts.setText("new", for: local, key: "body")
        drafts.setKind(true, for: local, kind: "bug", orderedKinds: ["work", "bug"])
        drafts.setText("", for: local, key: "title")
        XCTAssertNil(drafts.payload[0]["id"])
        XCTAssertEqual(drafts.payload[1]["id"] as? String, "server")
        XCTAssertEqual(drafts.payload[1]["approved_by"] as? String, "owner")
        XCTAssertNil(drafts.payload[2]["id"])
        XCTAssertEqual(drafts.payload[2]["body"] as? String, "new")
        XCTAssertEqual(drafts.payload[2]["task_kinds"] as? [String], ["bug"])
        XCTAssertNil(drafts.payload[2]["title"])
        XCTAssertEqual(drafts.rows[2].id, local)
    }
}
