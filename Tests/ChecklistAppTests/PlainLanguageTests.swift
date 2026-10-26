import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// CL-55: plain main-flow text; IDs, hashes, revisions and raw records only in Technical details.
final class PlainLanguageTests: XCTestCase {
    func testEveryDeliveryStateHasAPlainLabel() {
        let states = ["queued", "pending", "saved", "saved_for_pickup", "transport_written", "transport_accepted", "transport_receipt",
                      "provider_accepted", "acknowledged", "addressed", "held", "held_for_approval", "refused", "failed", "uncertain",
                      "delivery_uncertain", "expired", "unavailable", "ended", "canceled", "cancelled", "revoked", "fenced"]
        for state in states {
            let label = DeliveryLabels.receipt(state)
            XCTAssertFalse(label.contains("_"), state)
            XCTAssertNotEqual(label, "Delivery status unavailable", "\(state) needs its own label")
        }
        XCTAssertEqual(DeliveryLabels.receipt("transport_written"), "Transport accepted")
        // The service writes delivery_uncertain when a native write was lost (ChecklistCore Catalog delivery_record).
        XCTAssertEqual(DeliveryLabels.receipt("delivery_uncertain"), "Delivery outcome uncertain")
        for state in ["queued", "saved_for_pickup", "provider_accepted", "transport_written", "held_for_approval", "refused", "failed",
                      "delivery_uncertain", "unavailable", "canceled", "cancelled"] {
            XCTAssertNotEqual(RequestAnswerDeliveryProjection.stateLabel(state), "Delivery status unavailable", "\(state) needs its own answer receipt label")
        }
        XCTAssertEqual(RequestAnswerDeliveryProjection.stateLabel("delivery_uncertain"), "Delivery outcome uncertain")
        XCTAssertEqual(DeliveryLabels.receipt("some_future_state"), "Delivery status unavailable")
    }

    func testNoteReceiptDistinguishesDisconnectedAndPickupStates() {
        XCTAssertEqual(DeliveryLabels.receipt("fenced"), "Not delivered: this conversation was disconnected")
        XCTAssertEqual(DeliveryLabels.receipt("saved_for_pickup"), "Saved for pickup")
        XCTAssertEqual(DeliveryLabels.receipt("queued"), "Queued for agent pickup")
        XCTAssertEqual(DeliveryLabels.receipt("acknowledged"), "Acknowledged")
    }

    func testSavedResponseKeepsFencedReceiptAfterAllowAndReconnect() {
        let response = Record(values: ["id": "response", "origin": "human_ui", "form_identity": "form", "form_revision": 1])
        let request = Record(values: ["id": "request", "project_id": "project", "task_id": "task", "form_identity": "form", "form_revision": 1,
                                      "responses": [response.values], "continuation_message_id": "message"])
        let delivery: [String: Any] = ["id": "delivery", "project_id": "project", "message_id": "message", "recipient_session_id": "session",
                                       "recipient_authorization_generation": "old", "state": "fenced"]
        let message = Record(values: ["id": "message", "project_id": "project", "task_id": "task", "human_request_id": "request",
                                      "human_response_id": "response", "form_revision": 1, "origin": "human_ui", "deliveries": [delivery]])
        for (state, generation) in [("revoked", "disconnect"), ("revoked", "allow"), ("connected", "new")] {
            let session = Record(values: ["id": "session", "project_id": "project", "role": "worker", "state": state, "authorization_generation": generation])
            let receipt = RequestAnswerDeliveryProjection.make(request: request, response: response, messages: [message], sessions: [session], snapshotCurrent: true)
            XCTAssertEqual(receipt.recipients.map(\.receipt), ["Not delivered: this conversation was disconnected"], "\(state), \(generation)")
        }
    }

    func testTimestampsWithAndWithoutFractionalSecondsShowAsRelativeTime() {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T06:00:00Z")!
        for value in ["2026-10-20T05:50:52Z", "2026-10-20T05:50:52.123Z"] {
            let text = RelativeTimeFormatterCache().string(from: value, now: now, locale: Locale(identifier: "en_US"))
            XCTAssertNotEqual(text, value)
            XCTAssertFalse(text.contains("T05"), text)
        }
    }

    func testRawRecordsAndRetiredTechnicalPhrasesStayOutOfTheMainFlow() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        // "Form \u{FFFC}" is a revision number in the header; IDs and revisions belong in Technical details.
        let retired = #"(?i)\b(immutable|cursor|checksum|reconcil\w*)\b|manifest:|digest:|source_authorization_generation|target identity|technical identity|hashed evidence|^(request|target): \x{FFFC}|form \x{FFFC}"#
        var problems: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent != "TechnicalDetails.swift" && text.contains("readableJSON(") && !text.contains("static func readableJSON") {
                problems.append("\(file.lastPathComponent) shows raw JSON outside Technical details")
            }
            for value in SwiftLiterals.strings(in: text) {
                guard value.contains(" ") else { continue }
                if value.range(of: retired, options: .regularExpression) != nil { problems.append("\(file.lastPathComponent): \"\(value.prefix(80))\"") }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// Service text that carries IDs or raw records (the prepared reviewer instruction) is shown only in Technical details.
    func testPreparedReviewerInstructionStaysInTechnicalDetails() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp/Views/ReviewDetailView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("Text(instruction)"), "The instruction is not main-flow text")
        XCTAssertTrue(text.contains(#"blocks: [("Reviewer instruction", instruction)]"#))
        XCTAssertTrue(text.contains("clipboard(instruction)"), "Copy reviewer instruction stays available")
        XCTAssertEqual(TechnicalDetails([], blocks: [("Reviewer instruction", "Run checklist connect --task 6975b71e")]).blocks.count, 1)
        XCTAssertTrue(TechnicalDetails([], blocks: [("Reviewer instruction", "")]).blocks.isEmpty, "Nothing shows before the instruction is ready")
    }

    func testServiceErrorsShowWithoutCodesOrCommandJargon() {
        let readTimeout = ChecklistError("OUTCOME_UNKNOWN", "The service outcome is unknown. Reconcile the original command before retrying a mutation.")
        XCTAssertEqual(PlainError.text(readTimeout), "Checklist did not get an answer from its service in time. Try again.")
        let changeTimeout = ChecklistError("OUTCOME_UNKNOWN", "x", details: ["command_id": "c1"])
        XCTAssertTrue(PlainError.text(changeTimeout).contains("Check the last change"))
        XCTAssertEqual(PlainError.text(ChecklistError("INVALID_INPUT", "Enter a title.")), "Enter a title.")
        XCTAssertEqual(PlainError.text(ChecklistError("STORE_BUSY", "busy")), "Checklist is busy with its storage. Try again in a moment.")
        for code in ["EVIDENCE_STALE", "SOURCE_CHANGED", "REVIEW_TARGET_MISMATCH", "SOURCE_CAPTURE_INCOMPLETE"] {
            let text = ReviewProjection.plainBlocker(code) ?? ""
            XCTAssertTrue(text.hasSuffix("Submit the work again."), code)
        }
        XCTAssertNil(ReviewProjection.plainBlocker("SOMETHING_ELSE"))
        let task = Record(values: ["id": "t1", "current_manifest_id": "m1", "revision": 3,
                                   "completion_eligibility": ["task_revision": 3, "manifest_id": "m1", "eligible": false,
                                                              "blockers": [["code": "EVIDENCE_STALE", "message": "Relevant source, index or base changed. Capture and review the new target."]]]])
        let projection = ReviewProjection(task: task, project: nil, data: ["manifests": [["id": "m1", "task_id": "t1"]]])
        XCTAssertFalse(projection.completionBlockers.contains { $0.contains("Relevant source") }, "\(projection.completionBlockers)")
        XCTAssertTrue(projection.completionBlockers.contains("The project files changed after this submission. Submit the work again."))
    }

    func testAlertsAndFailuresUsePlainErrorText() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        var raw: [String] = []
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL }) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: #"(error|failure|problem|result)\s*=\s*error\.localizedDescription"#, options: .regularExpression) != nil { raw.append(file.lastPathComponent) }
        }
        XCTAssertEqual(raw, [], "Show service errors through PlainError.text")
    }
}
