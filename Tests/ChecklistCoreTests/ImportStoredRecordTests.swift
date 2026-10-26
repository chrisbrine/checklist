import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testMalformedStoredImportSnapshotRefusesRollbackWithoutDeletingCreatedRecords() throws {
        let project = try project("Stored import", "SIR")
        let projectID = try XCTUnwrap(project["id"] as? String)
        let task = try task(project)
        let taskID = try XCTUnwrap(task["id"] as? String)
        let malformed: [Any?] = [nil, NSNull(), true, 7, "project", [Any]()]
        for previous in malformed {
            let receiptID = UUID().uuidString.lowercased()
            try router.dbQueue.write { db in
                var receipt: JSON = [
                    "id": receiptID, "project_id": projectID, "revision": 1,
                    "state": "committed", "created_ids": [taskID],
                    "post_digest": try router.importDestinationDigest(db, projectID)
                ]
                receipt["previous_project"] = previous
                try router.save(db, receipt, type: "import_receipt")
            }
            assertCode("CANONICAL_RECORD_INVALID") {
                _ = try self.call("import_rollback", [
                    "project_id": projectID, "receipt_id": receiptID, "expected_revision": 1
                ])
            }
            try router.dbQueue.read { db in
                XCTAssertEqual(try router.record(db, taskID, type: "task")["id"] as? String, taskID)
                XCTAssertEqual(try router.record(db, receiptID, type: "import_receipt")["state"] as? String, "committed")
            }
        }
    }

    func testMalformedStorageCopyObservationFailsBeforePublishingMetadata() throws {
        let malformed: [JSON] = [
            [:], ["operation_id": NSNull(), "usage": [:]], ["operation_id": true, "usage": [:]],
            ["operation_id": "operation"], ["operation_id": "operation", "usage": NSNull()]
        ]
        for summary in malformed {
            assertCode("CANONICAL_RECORD_INVALID") {
                try self.router.dbQueue.write { db in
                    try self.router.recordStorageCopyObservation(db, key: "fixture", summary: summary)
                }
            }
        }
        try router.dbQueue.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='storage-last-verified-fixture'"))
        }
    }

    func testReviewBatchSelectorRejectsMissingGateAndRetainsLegacyPresentValues() throws {
        let task: JSON = ["id": "task", "revision": 1]
        var request: JSON = ["id": "request"]
        let manifest: JSON = ["id": "manifest"]
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try self.router.reviewBatchSelector(task: task, request: request, manifest: manifest, contributors: [])
        }
        for gate: Any in [NSNull(), true, 7, "future_gate"] {
            request["gate"] = gate
            let selector = try router.reviewBatchSelector(task: task, request: request, manifest: manifest, contributors: [])
            XCTAssertEqual(try jsonString(["gate": try StoredRecord(selector, family: "selector").requiredValue("gate")]),
                           try jsonString(["gate": gate]))
        }
    }
}
