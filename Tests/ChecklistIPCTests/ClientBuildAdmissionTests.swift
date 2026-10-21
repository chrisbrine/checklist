import XCTest
@testable import ChecklistIPC

final class ClientBuildAdmissionTests: XCTestCase {
    private let current = Data([1, 2, 3])
    private let previous = Data([4, 5, 6])
    private let identifiers: Set<String> = ["org.checklist.checklist", "org.checklist.app", "org.checklist.app.test2"]

    func testOnlyCurrentHashesAdmitCommands() {
        for identifier in identifiers {
            XCTAssertEqual(ClientBuildAdmission.classify(.init(identifier: identifier, cdhash: current), currentHashes: [current], checklistIdentifiers: identifiers), .current)
            XCTAssertEqual(ClientBuildAdmission.classify(.init(identifier: identifier, cdhash: previous), currentHashes: [current], checklistIdentifiers: identifiers), .outdated)
        }
    }

    func testUnknownMissingAndOtherSlotIdentitiesAreRefused() {
        for identifier in ["unknown", "org.checklist.app.test3"] {
            XCTAssertEqual(ClientBuildAdmission.classify(.init(identifier: identifier, cdhash: previous), currentHashes: [current], checklistIdentifiers: identifiers), .refused)
        }
        XCTAssertEqual(ClientBuildAdmission.classify(nil, currentHashes: [current], checklistIdentifiers: identifiers), .refused)
        XCTAssertEqual(ClientBuildAdmission.classify(.init(identifier: "org.checklist.checklist", cdhash: Data()), currentHashes: [current], checklistIdentifiers: identifiers), .refused)
        XCTAssertEqual(ClientBuildAdmission.classify(.init(identifier: "org.checklist.checklist", cdhash: previous), currentHashes: [], checklistIdentifiers: identifiers), .refused)
    }

    func testOutdatedPeerRejectsEveryRequestWithoutACommandCapability() throws {
        let peer = OutdatedClientPeer()
        let id = UUID().uuidString
        let envelopes = try ["service_info", "tool_catalog", "task_edit", "connection_bootstrap"].map {
                try JSONSerialization.data(withJSONObject: ["method": $0, "params": ["command_id": id]])
            }
        let requests = [Data(), Data([0xff]), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] + envelopes
        for request in requests {
            var replies = 0
            var received: Data?
            peer.execute(request) { bytes in replies += 1; received = bytes }
            let bytes = try XCTUnwrap(received)
            XCTAssertThrowsError(try CommandReply.decode(bytes, method: "task_edit", commandID: id)) { failure in
                    let error = failure as? ChecklistError
                    XCTAssertEqual(error?.code, "CLIENT_OUTDATED")
                    XCTAssertEqual(error?.message, ClientUpdateRequired.message)
                    XCTAssertEqual(error?.details["command_executed"] as? Bool, false)
                    XCTAssertEqual(error?.details["command_outcome"] as? String, "rejected")
                    XCTAssertEqual(error?.details["command_id"] as? String, id)
                    XCTAssertFalse(CommandReply.shouldRetainPending(after: failure))
            }
            XCTAssertEqual(replies, 1)
        }
    }

    func testOutdatedReadAndMutationRepliesAreDefinitiveButAfterDeliveryInvalidationStaysUnknown() throws {
        let reply = try JSONSerialization.data(withJSONObject: ["error": ["code": "CLIENT_OUTDATED", "message": ClientUpdateRequired.message]])
        for method in ["service_info", "task_edit"] {
            XCTAssertThrowsError(try CommandReply.decode(reply, method: method, commandID: method == "task_edit" ? "original-id" : nil)) { failure in
                let error = failure as? ChecklistError
                XCTAssertEqual(error?.code, "CLIENT_OUTDATED")
                XCTAssertEqual(error?.details["command_executed"] as? Bool, false)
                XCTAssertEqual(error?.details["command_outcome"] as? String, "rejected")
            }
        }
        let invalidated = CommandReply.unknown(commandID: "original-id", reason: "connection_ended")
        XCTAssertEqual(invalidated.code, "OUTCOME_UNKNOWN")
        XCTAssertEqual(invalidated.details["command_id"] as? String, "original-id")
        XCTAssertTrue(CommandReply.shouldRetainPending(after: invalidated))
    }
}
