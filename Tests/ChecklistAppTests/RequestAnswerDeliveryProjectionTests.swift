import XCTest
@testable import ChecklistApp

@MainActor final class RequestAnswerDeliveryProjectionTests: XCTestCase {
    private struct Fixture {
        var response: [String: Any] = ["id": "response", "origin": "human_ui", "form_identity": "form", "form_revision": 1]
        var omission: [String: Any] = ["message_id": "message", "project_id": "project", "recipient_role": "triage_orchestrator",
                                      "recipient_session_id": "orchestrator", "triage_id": "triage", "orchestration_id": "orchestration",
                                      "state": "not_delivered_binding_stale", "reason": "Authorization generation changed; resume is required.",
                                      "recipient_display": "Review pass", "binding_authorization_generation": "old"]
        var deliveries: [[String: Any]] = []
        var sessions: [[String: Any]] = []
        var requestChanges: [String: Any] = [:]
        var messageChanges: [String: Any] = [:]

        func projection(snapshotCurrent: Bool = true, anchors: [[String: Any]]? = nil, omissions: [[String: Any]]? = nil) -> RequestAnswerDeliveryProjection {
            var request: [String: Any] = ["id": "request", "project_id": "project", "task_id": "task", "form_identity": "form", "form_revision": 1,
                                         "responses": [response], "continuation_message_id": "message", "continuation_deliveries": anchors ?? [omission]]
            request.merge(requestChanges) { _, new in new }
            var message: [String: Any] = ["id": "message", "project_id": "project", "task_id": "task", "human_request_id": "request",
                                         "human_response_id": "response", "form_revision": 1, "origin": "human_ui", "delivery_status": "saved_for_pickup",
                                         "deliveries": deliveries, "delivery_omissions": omissions ?? [omission]]
            message.merge(messageChanges) { _, new in new }
            return RequestAnswerDeliveryProjection.make(request: Record(values: request), response: Record(values: response), messages: [Record(values: message)],
                                                        sessions: sessions.map(Record.init), snapshotCurrent: snapshotCurrent)
        }

        mutating func addRecoveryDelivery(role: String = "triage_orchestrator") {
            deliveries = [["id": "delivery", "project_id": "project", "message_id": "message", "recipient_session_id": "orchestrator",
                           "recipient_role": role, "recipient_authorization_generation": "new", "recipient_display": "Review pass", "state": "queued"]]
            sessions = [["id": "orchestrator", "project_id": "project", "role": "worker", "state": "connected", "authorization_generation": "new", "label": "Resumed review pass"]]
        }
    }

    func testBindingOmissionHasNamedNotDeliveredReceiptWithoutQueuedDelivery() {
        let projection = Fixture().projection()
        XCTAssertEqual(projection.recipients.count, 1)
        XCTAssertEqual(projection.recipients.first?.label, "Triage orchestrator · Review pass")
        XCTAssertEqual(projection.recipients.first?.receipt, "Not delivered · Triage binding needs resume")
        XCTAssertEqual(projection.summary, "Delivery status for this saved response.")
    }

    func testRecoveryKeepsHistoricalOmissionAlongsideNewGenerationDelivery() {
        var fixture = Fixture()
        fixture.addRecoveryDelivery()
        fixture.requestChanges = ["requester_session_id": "orchestrator", "requester_authorization_generation": "old"]
        let projection = fixture.projection()
        XCTAssertEqual(projection.recipients.map(\.receipt), ["Queued for agent pickup", "Not delivered when answered · Triage binding needed resume"])
        XCTAssertEqual(projection.recipients.map(\.label), ["Resumed review pass", "Triage orchestrator · Review pass"])
        XCTAssertEqual(Set(projection.recipients.map(\.id)).count, 2)
    }

    func testRequesterFallbackStillRejectsChangedGeneration() {
        var fixture = Fixture()
        fixture.addRecoveryDelivery(role: "requester")
        fixture.requestChanges = ["requester_session_id": "orchestrator", "requester_authorization_generation": "old"]
        XCTAssertEqual(fixture.projection().recipients.map(\.receipt), ["Requester connection changed; delivery status unavailable", "Not delivered · Triage binding needs resume"])
    }

    func testDisconnectedSnapshotQualifiesOmissionAsLastKnown() {
        let projection = Fixture().projection(snapshotCurrent: false)
        XCTAssertEqual(projection.recipients.first?.receipt, "Last known · Not delivered · Triage binding needs resume")
        XCTAssertTrue(projection.summary.contains("disconnected"))
    }

    func testOmissionRequiresScopedStoredFactsAndNoDeliveryIdentity() {
        let invalid: [[String: Any]] = [["project_id": "other"], ["message_id": "other"], ["recipient_role": "handler"],
                                      ["recipient_session_id": ""], ["triage_id": ""], ["orchestration_id": ""],
                                      ["binding_authorization_generation": ""], ["reason": ""], ["state": "queued"], ["id": "fabricated-delivery"]]
        for changes in invalid {
            var fixture = Fixture()
            fixture.omission.merge(changes) { _, new in new }
            let projection = fixture.projection()
            XCTAssertFalse(projection.recipients.isEmpty, "\(changes)")
            XCTAssertTrue(projection.recipients.allSatisfy { $0.receipt == "Delivery status unavailable" }, "\(changes)")
        }
    }

    func testLatestOmissionChecksEveryContinuationAnchorFact() {
        let fixture = Fixture()
        for field in ["message_id", "project_id", "recipient_role", "recipient_session_id", "triage_id", "orchestration_id", "reason", "binding_authorization_generation"] {
            var anchor = fixture.omission
            anchor[field] = "different"
            let projection = fixture.projection(anchors: [anchor])
            XCTAssertTrue(projection.recipients.allSatisfy { $0.receipt == "Delivery status unavailable" }, field)
        }
        XCTAssertEqual(fixture.projection(anchors: []).recipients.first?.receipt, "Delivery status unavailable")
        XCTAssertEqual(fixture.projection(omissions: []).recipients.first?.receipt, "Delivery status unavailable")
        var fabricatedDeliveryAnchor = fixture.omission
        fabricatedDeliveryAnchor["id"] = "fabricated-delivery"
        XCTAssertEqual(fixture.projection(anchors: [fabricatedDeliveryAnchor]).recipients.first?.receipt, "Delivery status unavailable")
    }

    func testOlderResponseUsesItsOwnStoredOmissionAfterRequestHasNewerAnswer() {
        var fixture = Fixture()
        var newer = fixture.response
        newer["id"] = "newer-response"
        fixture.requestChanges = ["responses": [fixture.response, newer], "continuation_message_id": "newer-message", "continuation_deliveries": []]
        XCTAssertEqual(fixture.projection().recipients.map(\.receipt), ["Not delivered · Triage binding needs resume"])
    }

    func testDuplicateOmissionFactsDoNotProduceTrustedReceipts() {
        let fixture = Fixture()
        let projection = fixture.projection(omissions: [fixture.omission, fixture.omission])
        XCTAssertEqual(projection.recipients.map(\.receipt), ["Delivery status unavailable", "Delivery status unavailable"])
        XCTAssertEqual(Set(projection.recipients.map(\.id)).count, 2)
        XCTAssertEqual(fixture.projection(anchors: [fixture.omission, fixture.omission]).recipients.first?.receipt, "Delivery status unavailable")
    }

    func testOmissionCannotBeAttachedToAnotherResponseOrTicket() {
        let changes: [[String: Any]] = [["task_id": "other"], ["human_response_id": "other"], ["human_request_id": "other"], ["form_revision": 2]]
        for change in changes {
            var fixture = Fixture()
            fixture.messageChanges = change
            let projection = fixture.projection()
            XCTAssertTrue(projection.recipients.isEmpty, "\(change)")
            XCTAssertTrue(projection.summary.contains("unavailable"), "\(change)")
        }
    }
}
