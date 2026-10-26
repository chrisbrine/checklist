import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    func testImplementationClaimCategoryRejectsMalformedStoredProject() throws {
        let p = try project()
        var t = try ready(p)
        t["project_id"] = 42
        try router.dbQueue.read { db in
            XCTAssertThrowsError(try router.implementationClaimCategory(db, task: t))
        }
    }

    func testImplementationClaimCategoryKeepsAbsentStatusFallback() throws {
        let p = try project()
        var t = try ready(p)
        t.removeValue(forKey: "status_id")
        t["status_category"] = "future-category"
        try router.dbQueue.read { db in
            XCTAssertEqual(try router.implementationClaimCategory(db, task: t), "future-category")
            t.removeValue(forKey: "status_category")
            XCTAssertEqual(try router.implementationClaimCategory(db, task: t), "queued")
        }
    }

    func testReviewVerdictRejectsMalformedStoredProject() throws {
        try router.dbQueue.read { db in
            XCTAssertThrowsError(
                try router.recordReviewVerdict(
                    db, params: [:], attempt: [:], task: ["id": "fixture", "project_id": false],
                    reviewer: owner, actor: owner, operation: .individual))
        }
    }
    func testImageRequestRejectsMalformedStoredTaskIdentity() throws {
        try router.dbQueue.read { db in
            XCTAssertThrowsError(
                try router.requestImageInspections(
                    db, params: [:], request: ["task_id": false, "project_id": "fixture"],
                    answers: [], complete: true))
        }
    }

    func testBulkUndoRejectsDuplicateStoredReceiptRows() throws {
        let p = try project()
        let t = try ready(p)
        let projectID = try XCTUnwrap(p["id"] as? String)
        let taskID = try XCTUnwrap(t["id"] as? String)
        let original = UUID().uuidString
        let row: JSON = ["task_id": taskID]
        let receipt: JSON = ["data": [
            "kind": "task_bulk_edit", "project_id": projectID, "preview": false,
            "rows": [row, row], "changes": ["kind": "tags"],
        ]]
        try router.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",
                arguments: [owner.principal, original, "fixture", try jsonString(receipt)])
        }
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try call("task_bulk_undo", [
                "project_id": projectID, "original_command_id": original, "preview": true,
                "tasks": [["task_id": taskID, "expected_revision": t["revision"] ?? 1]],
            ])
        }
    }
    func testPendingDirectionsRejectMalformedStoredTaskIdentity() throws {
        try router.dbQueue.read { db in
            XCTAssertThrowsError(try router.hasPendingDirections(db, task: ["id": "fixture", "project_id": false]))
        }
    }

    func testKeyedVerdictImportKeepsShapeError() throws {
        assertCode("IMPORT_SHAPE_INVALID") {
            _ = try TransferBundle.verdicts(["fixture": ["review": false]], shape: "keyed-verdicts")
        }
        let rows = try TransferBundle.verdicts(["fixture": ["review": "pass", "unknown": 42]], shape: "keyed-verdicts")
        XCTAssertEqual((rows.first?["raw"] as? JSON)?["unknown"] as? Int, 42)
    }
}
