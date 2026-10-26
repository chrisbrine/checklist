import Foundation
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testTypedDirectionConsumersRejectMalformedStoredIdentity() throws {
        for malformed: Any in [NSNull(), true, 42, ["unexpected": "object"]] {
            assertCode("CANONICAL_RECORD_INVALID") {
                try router.dbQueue.read { db in
                    try router.validateHumanGateDirection(
                        db, request: ["task_id": malformed, "project_id": "project"], params: [:], caller: owner
                    )
                }
            }
            assertCode("CANONICAL_RECORD_INVALID") {
                _ = try router.dbQueue.read { db in
                    try router.relevantHandlerRecipients(db, task: ["id": "task", "project_id": malformed])
                }
            }
        }
    }

    func testTypedDeliveryConsumerRejectsMalformedStoredMessageIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.dbQueue.read { db in
                try router.queueDirectionDeliveries(db, message: ["id": NSNull(), "project_id": "project"], recipients: [])
            }
        }
    }

    func testTypedPolicyConsumerRejectsMalformedStoredProjectIdentity() throws {
        let worker = Caller(role: "worker", installation: "synthetic", projectIDs: [], sessionID: "synthetic-worker")
        assertCode("CANONICAL_RECORD_INVALID") {
            try router.dbQueue.read { db in
                try router.validatePolicySelection(
                    db, project: ["id": 42], task: [:], caller: worker, phase: "implementation", policy: [:]
                )
            }
        }
    }

    func testTypedPrerequisiteProjectionRejectsMalformedStoredIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.projectedPrerequisites(task: ["id": NSNull()], relations: [],
                taskLookup: {_ in [:]}, statusLookup: {_ in [:]})
        }
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.projectedPrerequisites(task: ["id": "task"],
                relations: [["id": 42, "source_task_id": "task", "relation": "depends_on", "state": "unresolved"]],
                taskLookup: {_ in [:]}, statusLookup: {_ in [:]})
        }
    }

    func testTypedCanonicalRedirectRejectsMalformedStoredTargetIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.projectedCanonicalTaskID(task: ["id": "task", "duplicate_of_task_id": "target"],
                taskLookup: {_ in ["id": NSNull()]})
        }
    }

    func testTypedReviewConsumersRejectMalformedStoredIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.dbQueue.read { db in
                try router.applyFindings(db, params: [:], task: ["id": "task", "project_id": "project"],
                    attempt: ["gate": true, "manifest_id": "manifest"], reviewID: "review", verdict: "reject", caller: owner)
            }
        }
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try router.dbQueue.read { db in
                try router.normalizedReviewChecks(db, [:], task: ["project_id": NSNull()])
            }
        }
    }

    func testMalformedDirectionWaiverReturnsErrorWithoutWritingDisposition() throws {
        let project = try self.project()
        let projectID = try XCTUnwrap(project["id"] as? String)
        let messageID = uuid()
        let malformed: JSON = ["id": messageID, "project_id": projectID, "origin": "human_ui", "requires_action": true,
            "body": "Synthetic malformed direction", "revision": 1, "created_at": now()]
        try router.dbQueue.write { try router.save($0, malformed, type: "message") }
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try call("direction_waive", ["project_id": projectID, "message_id": messageID,
                "expected_revision": 1, "reason": "Synthetic corruption regression"])
        }
        try router.dbQueue.read { db in
            XCTAssertEqual(try jsonString(router.record(db, messageID, type: "message")), try jsonString(malformed))
            XCTAssertTrue(try router.records(db, type: "direction_disposition", project: projectID).isEmpty)
        }
    }

    func testMalformedTransitionStatusNameRollsBackTaskAndHistory() throws {
        let project = try self.project()
        let projectID = try XCTUnwrap(project["id"] as? String)
        let task = try self.task(project)
        let taskID = try XCTUnwrap(task["id"] as? String)
        var targetID = ""
        try fixtureDomainTransaction { db in
            var target = try router.status(db, projectID, "blocked")
            targetID = try XCTUnwrap(target["id"] as? String)
            target.removeValue(forKey: "name")
            try router.save(db, target, type: "status")
        }
        let before = try router.dbQueue.read { db in
            try jsonString(router.record(db, taskID, type: "task"))
        }
        let history = try call("history_list", ["project_id": projectID, "task_id": taskID])
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try call("task_transition", ["project_id": projectID, "task_id": taskID,
                "expected_revision": task["revision"] ?? 1, "target_status_id": targetID])
        }
        XCTAssertEqual(try router.dbQueue.read { try jsonString(router.record($0, taskID, type: "task")) }, before)
        let afterHistory = try call("history_list", ["project_id": projectID, "task_id": taskID])
        XCTAssertEqual(try jsonString(afterHistory.filter { $0.key != "next_cursor" }),
            try jsonString(history.filter { $0.key != "next_cursor" }))
    }

}


extension HumanGateDirectionTests {
    func testMalformedStoredGateAttachmentIdentityReturnsErrorWithoutGateWrites() throws {
        let value = try fixture()
        for missingKey in ["target_attachment_id", "target_sha256"] {
            let observed = try context(value)
            let params = try approval(value, context: observed)
            var malformed = value.request
            malformed.removeValue(forKey: missingKey)
            let requestID = try XCTUnwrap(value.request["id"] as? String)
            try router.dbQueue.write { try router.save($0, malformed, type: "request") }
            let before = try state(value)
            assertCode("CANONICAL_RECORD_INVALID") {
                _ = try router.dbQueue.write { db in
                    try router.recordHumanGate(db, request: router.record(db, requestID, type: "request"),
                        answers: [["question_id": "approve", "result": "approved"]], responseID: uuid(), params: params, caller: owner)
                }
            }
            XCTAssertEqual(try state(value), before)
            try router.dbQueue.write { try router.save($0, value.request, type: "request") }
        }
    }
}
