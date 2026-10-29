import XCTest
import ChecklistIPC

final class OperationReplyTests: XCTestCase {
    private let commandID = UUID().uuidString
    private let operationID = UUID().uuidString

    private func receipt(method: String = "backup_create", state: String = "queued") -> [String: Any] {
        ["command_id": commandID, "command_outcome": "accepted", "data": [
            "operation_id": operationID, "command_id": commandID, "method": method,
            "state": state, "status_method": "operation_get"]]
    }

    private func decode(_ reply: [String: Any], method: String = "backup_create", command: String? = nil) throws -> [String: Any] {
        try CommandReply.decode(JSONSerialization.data(withJSONObject: reply), method: method, commandID: command)
    }

    func testAcceptedOperationIsValidatedForWritesAndReadsWithoutCallerCommandID() throws {
        for method in ["backup_create", "attachment_cleanup_preview"] {
            for state in ["queued", "running", "succeeded", "failed"] {
                let reply = try decode(receipt(method: method, state: state), method: method,
                                       command: method == "backup_create" ? commandID : nil)
                XCTAssertEqual(reply["command_outcome"] as? String, "accepted")
                XCTAssertNil((reply["data"] as? [String: Any])?["result"])
            }
        }
    }

    func testMalformedAcceptanceNeverBecomesSemanticSuccess() throws {
        for field in ["operation_id", "command_id", "method", "state", "status_method"] {
            var reply = receipt(), data = reply["data"] as! [String: Any]
            data.removeValue(forKey: field); reply["data"] = data
            XCTAssertThrowsError(try decode(reply, command: commandID), field) {
                XCTAssertTrue(CommandReply.shouldRetainPending(after: $0))
            }
        }
        for (field, value) in [("operation_id", "not-a-uuid"), ("command_id", UUID().uuidString),
                               ("method", "restore_create"), ("state", "applied"), ("status_method", "command_status")] {
            var reply = receipt(), data = reply["data"] as! [String: Any]
            data[field] = value; reply["data"] = data
            XCTAssertThrowsError(try decode(reply, command: commandID), field)
        }
        var missingIdentity = receipt(); missingIdentity.removeValue(forKey: "command_id")
        XCTAssertThrowsError(try decode(missingIdentity, method: "backup_create"))
        var missingOutcome = receipt(); missingOutcome.removeValue(forKey: "command_outcome")
        XCTAssertThrowsError(try decode(missingOutcome, command: commandID))
        XCTAssertThrowsError(try decode(receipt(), command: UUID().uuidString))
    }

    func testMalformedReadAcceptanceIsInvalidResponseAndOperationObservationRemainsReadData() throws {
        var malformed = receipt(method: "attachment_cleanup_preview")
        malformed["command_id"] = "invalid"
        XCTAssertThrowsError(try decode(malformed, method: "attachment_cleanup_preview")) {
            XCTAssertEqual(($0 as? ChecklistError)?.code, "INVALID_RESPONSE")
        }
        let observed: [String: Any] = ["data": receipt()["data"]!]
        XCTAssertNotNil(try decode(observed, method: "operation_get")["data"])
        XCTAssertNotNil(try decode(observed, method: "command_status")["data"])
    }
}
