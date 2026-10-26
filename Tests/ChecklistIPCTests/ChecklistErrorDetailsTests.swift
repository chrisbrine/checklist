import XCTest
import Foundation
@testable import ChecklistIPC

final class ChecklistErrorDetailsTests: XCTestCase {
    func testDiagnosticSnapshotPreservesFieldsAndOwnsIndependentContainers() throws {
        let mutable = NSMutableDictionary(dictionary: ["value": "before"])
        let array = NSMutableArray(array: [mutable, NSNull(), true, 42, 3.5])
        let error = ChecklistError("BACKUP_DEADLINE_EXCEEDED", "Delayed", details: [
            "command_id": "original", "reason": "copy deadline", "nested": array,
            "large": UInt64.max, "data": Data([1, 2]), "date": Date(timeIntervalSince1970: 123),
            "url": URL(fileURLWithPath: "/tmp/diagnostic"), "uuid": UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        ])
        mutable["value"] = "after"
        array.add("added later")
        let snapshot = error.details
        let nested = try XCTUnwrap(snapshot["nested"] as? [Any])
        XCTAssertEqual(nested.count, 5)
        XCTAssertEqual((nested[0] as? [String: Any])?["value"] as? String, "before")
        XCTAssertTrue(nested[1] is NSNull)
        XCTAssertEqual(nested[2] as? Bool, true)
        XCTAssertEqual(nested[3] as? Int, 42)
        XCTAssertEqual(nested[4] as? Double, 3.5)
        XCTAssertEqual(snapshot["large"] as? UInt, UInt.max)
        XCTAssertEqual(snapshot["data"] as? Data, Data([1, 2]))
        XCTAssertEqual(snapshot["date"] as? Date, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(snapshot["url"] as? URL, URL(fileURLWithPath: "/tmp/diagnostic"))
        XCTAssertEqual(snapshot["uuid"] as? UUID, UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        XCTAssertEqual(error.errorDescription, "BACKUP_DEADLINE_EXCEEDED: Delayed Reason: copy deadline. Command ID: original.")
        var edited = error.details
        edited["command_id"] = "changed copy"
        XCTAssertEqual(error.details["command_id"] as? String, "original")
    }

    func testUnsupportedReferenceIsAnExplicitDescriptionSnapshot() {
        final class Diagnostic: CustomReflectable {
            var text = "before"
            var customMirror: Mirror { Mirror(self, children: ["text": text]) }
        }
        let object = Diagnostic()
        let expected = String(reflecting: object)
        let error = ChecklistError("FIXTURE", "Value contract", details: ["unsupported": object])
        object.text = "after"
        XCTAssertEqual(error.details["unsupported"] as? String, expected)
    }
}
