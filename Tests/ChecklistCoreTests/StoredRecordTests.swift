import Foundation
import XCTest
@testable import ChecklistCore

final class StoredRecordTests: XCTestCase {
    func testRequiredValueChecksPresenceWithoutChangingDynamicValue() throws {
        assertMalformed { _ = try StoredRecord([:], family: "test").requiredValue("value") }
        for value: Any in [NSNull(), true, 1, "text", ["future": true]] {
            let record = StoredRecord(["value": value], family: "test")
            let result = try record.requiredValue("value")
            XCTAssertEqual(try jsonString(["value": result]), try jsonString(["value": value]))
        }
    }

    func testMandatoryStringRejectsMissingNullAndOtherDynamicTypes() throws {
        for input: JSON in [[:], ["id": NSNull()], ["id": true], ["id": 1], ["id": []], ["id": [:]]] {
            assertMalformed { _ = try StoredRecord(input, family: "private content").string("id") }
        }
        XCTAssertEqual(try StoredRecord(["id": ""], family: "task").string("id"), "")
    }

    func testMandatoryObjectAndObjectArrayRejectMalformedValues() throws {
        for input: JSON in [[:], ["value": NSNull()], ["value": false], ["value": 1], ["value": "object"]] {
            let record = StoredRecord(input, family: "test")
            assertMalformed { _ = try record.object("value") }
            assertMalformed { _ = try record.objects("value") }
        }
        assertMalformed { _ = try StoredRecord(["value": [[:], 1]], family: "test").objects("value") }
        XCTAssertTrue(try StoredRecord(["value": [:]], family: "test").object("value").isEmpty)
        XCTAssertTrue(try StoredRecord(["value": []], family: "test").objects("value").isEmpty)
        let objects = try StoredRecord(["value": [["id": "one"]]], family: "test").objects("value")
        XCTAssertEqual(objects.first?["id"] as? String, "one")
    }

    func testTaskAndAttemptRequireTheirIdentifiers() throws {
        let task: JSON = ["id": "task", "project_id": "project"]
        let attempt: JSON = ["id": "attempt", "project_id": "project", "task_id": "task"]
        for field in ["id", "project_id"] {
            var invalid = task
            invalid.removeValue(forKey: field)
            assertMalformed { _ = try StoredTaskRecord(invalid) }
        }
        for field in ["id", "project_id", "task_id"] {
            var invalid = attempt
            invalid[field] = NSNull()
            assertMalformed { _ = try StoredAttemptRecord(invalid) }
        }
        XCTAssertEqual(try StoredTaskRecord(task).projectID, "project")
        XCTAssertEqual(try StoredAttemptRecord(attempt).taskID, "task")
    }

    func testKnownAndUnknownEnumValuesUseSharedDomainWithoutClosingRecords() throws {
        let task = try StoredTaskRecord(["id": "task", "project_id": "project", "kind": "bug"])
        XCTAssertEqual(task.kind, .bug)
        let attempt = try StoredAttemptRecord(["id": "attempt", "project_id": "project", "task_id": "task", "phase": "review"])
        XCTAssertEqual(attempt.phase, .review)
        let future = try StoredTaskRecord(["id": "task", "project_id": "project", "kind": "future", "new": ["enabled": true]])
        XCTAssertEqual(future.rawKind, "future")
        XCTAssertNil(future.kind)
        XCTAssertEqual((future.value["new"] as? JSON)?["enabled"] as? Bool, true)
        let futureAttempt = try StoredAttemptRecord(["id": "attempt", "project_id": "project", "task_id": "task", "phase": "future"])
        XCTAssertEqual(futureAttempt.rawPhase, "future")
        XCTAssertNil(futureAttempt.phase)
    }

    func testOptionalMissingNullAndWrongTypesRetainLegacyDefaults() throws {
        for extra: JSON in [[:], ["kind": NSNull(), "status_id": NSNull()], ["kind": true, "status_id": 1]] {
            let base: JSON = ["id": "task", "project_id": "project"]
            let value = base.merging(extra) { _, new in new }
            let task = try StoredTaskRecord(value)
            XCTAssertNil(task.rawKind)
            XCTAssertNil(task.kind)
            XCTAssertNil(task.statusID)
            XCTAssertEqual(try jsonString(task.value), try jsonString(value))
        }
    }

    func testOpenRecordPreservesCanonicalBytesAndBooleanNumberBridging() throws {
        let source = #"{"id":"task","kind":"future_kind","no":false,"one":1,"project_id":"project","unknown":null,"yes":true}"#
        let value = jsonObject(source)
        let task = try StoredTaskRecord(value)
        XCTAssertEqual(try jsonString(task.value), source)
        XCTAssertEqual(ChecklistCore.hash(Data(try jsonString(task.value).utf8)), ChecklistCore.hash(Data(source.utf8)))
        XCTAssertEqual(int(task.value, "yes", default: -1), 1)
        XCTAssertEqual(int(task.value, "no", default: -1), 0)
        XCTAssertTrue(bool(task.value, "one"))
        XCTAssertTrue(task.value["unknown"] is NSNull)
    }

    private func assertMalformed(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? CoreError)?.code, "CANONICAL_RECORD_INVALID", file: file, line: line)
            XCTAssertEqual((error as? CoreError)?.message, "A stored record is malformed.", file: file, line: line)
            XCTAssertTrue((error as? CoreError)?.details.isEmpty == true, file: file, line: line)
        }
    }
}
