import XCTest
import ChecklistDomain
import ChecklistApplication

final class TicketCaptureTests: XCTestCase {
    private func state(existingKeys: Set<String> = []) -> TicketCaptureState {
        TicketCaptureState(projectID: "project", keyPrefix: "CL", nextNumber: 98,
                           existingKeys: existingKeys, queuedStatusID: "queued-status",
                           ticketID: "ticket", timestamp: "2026-10-26T15:00:00Z")
    }

    func testCapturePreservesExactInputAndStartsDraftQueued() throws {
        let input = TicketCaptureInput(title: "  Fix café\n", kind: .bug, tagIDs: ["tag"])
        let before = state()
        let result = try TicketCapture.plan(input, state: before)
        XCTAssertEqual(result.input, input)
        XCTAssertEqual(result.state, before)
        XCTAssertEqual(result.key, "CL-98")
        XCTAssertEqual(result.nextNumber, 99)
        XCTAssertEqual(result.readiness, "draft")
        XCTAssertEqual(result.statusCategory, .queued)
        XCTAssertNil(input.requestedKey)
        XCTAssertEqual(before.nextNumber, 98)
        XCTAssertTrue(before.existingKeys.isEmpty)
    }

    func testCustomKeyStillAdvancesCounterExactlyOnce() throws {
        let result = try TicketCapture.plan(
            TicketCaptureInput(title: "Capture", kind: .work, requestedKey: "CUSTOM-7"), state: state())
        XCTAssertEqual(result.key, "CUSTOM-7")
        XCTAssertEqual(result.nextNumber, 99)
        XCTAssertEqual(result.state.nextNumber, 98)
    }

    func testTitleLimitCountsUTF8BytesAndRejectsBlank() throws {
        try TicketCapture.validateTitle(String(repeating: "é", count: 1000))
        try TicketCapture.validateTitle(String(repeating: "a", count: 2000))
        for title in ["", " \t\n", String(repeating: "é", count: 1001),
                      String(repeating: "a", count: 2001)] {
            XCTAssertThrowsError(try TicketCapture.validateTitle(title)) { error in
                XCTAssertEqual(error as? TicketCaptureFailure, .invalidTitle)
            }
        }
    }

    func testDefaultAndCustomKeyCollisionsRejectWithoutChangingObservation() {
        let before = state(existingKeys: ["CL-98", "CUSTOM-7"])
        for requestedKey: String? in [nil, "CUSTOM-7"] {
            XCTAssertThrowsError(try TicketCapture.plan(
                TicketCaptureInput(title: "Capture", kind: .work, requestedKey: requestedKey), state: before)) { error in
                XCTAssertEqual(error as? TicketCaptureFailure, .keyConflict)
            }
        }
        XCTAssertEqual(before.nextNumber, 98)
        XCTAssertEqual(before.existingKeys, ["CL-98", "CUSTOM-7"])
    }
}
