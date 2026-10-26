import Foundation
import XCTest
@testable import ChecklistCore

/// Immutable legacy vectors: extraction must preserve these permissive wire conversions.
final class LegacyContractParityTests: XCTestCase {
    func testMissingAndNullUseIdenticalOptionalDefaults() throws {
        for input: JSON in [[:], ["value": NSNull()]] {
            XCTAssertEqual(try text(input, "value", required: false), "")
            XCTAssertEqual(int(input, "value", default: 37), 37)
            XCTAssertEqual(bool(input, "value", default: true), true)
            XCTAssertEqual(strings(input, "value"), [])
            XCTAssertThrowsError(try text(input, "value")) {
                XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT")
                XCTAssertEqual(($0 as? CoreError)?.message, "value is required.")
            }
        }
    }

    func testJSONBooleanAndNumberBridgingIsPreserved() {
        let input = jsonObject(#"{"yes":true,"no":false,"one":1,"zero":0,"two":2,"fraction":2.9,"numericText":"1"}"#)
        XCTAssertEqual(int(input, "yes", default: -1), 1)
        XCTAssertEqual(int(input, "no", default: -1), 0)
        XCTAssertEqual(int(input, "fraction", default: -1), 2)
        XCTAssertEqual(int(input, "numericText", default: -1), -1)
        XCTAssertTrue(bool(input, "yes"))
        XCTAssertFalse(bool(input, "no", default: true))
        XCTAssertTrue(bool(input, "one"))
        XCTAssertFalse(bool(input, "zero", default: true))
        XCTAssertFalse(bool(input, "two"))
        XCTAssertFalse(bool(input, "fraction"))
    }

    func testOptionalTextAndStringArraysDoNotCoerceOtherTypes() throws {
        XCTAssertEqual(try text(["value": 12], "value", required: false), "")
        XCTAssertEqual(try text(["value": " \n "], "value", required: false), " \n ")
        XCTAssertEqual(strings(["value": ["a", "雪"]], "value"), ["a", "雪"])
        XCTAssertEqual(strings(["value": ["a", 1]], "value"), [])
        XCTAssertEqual(strings(["value": "a"], "value"), [])
        XCTAssertThrowsError(try text(["value": "é"], "value", max: 1))
        XCTAssertEqual(try text(["value": "é"], "value", max: 2), "é")
    }

    func testCanonicalASCIIBytesAndDigest() throws {
        let actual = try jsonString(["z": true, "a": 1])
        XCTAssertEqual(actual, #"{"a":1,"z":true}"#)
        XCTAssertEqual(Array(actual.utf8), [123,34,97,34,58,49,44,34,122,34,58,116,114,117,101,125])
        XCTAssertEqual(ChecklistCore.hash(Data(actual.utf8)), "ac1f911be63ecec0033426a57a1b5ecabd84ba6fa00d184de4e44bb251b24f44")
    }

    func testCanonicalUnicodeSlashesEscapingAndDigest() throws {
        let actual = try jsonString(["z": NSNull(), "line": "one\ntwo\t\"quote\"\\", "a": "café/雪"])
        XCTAssertEqual(actual, #"{"a":"café/雪","line":"one\ntwo\t\"quote\"\\","z":null}"#)
        XCTAssertEqual(Array(actual.utf8), [123,34,97,34,58,34,99,97,102,195,169,47,233,155,170,34,44,34,108,105,110,101,34,58,34,111,110,101,92,110,116,119,111,92,116,92,34,113,117,111,116,101,92,34,92,92,34,44,34,122,34,58,110,117,108,108,125])
        XCTAssertEqual(ChecklistCore.hash(Data(actual.utf8)), "6c8d00e2d87a64ea82fc44519d0c3329f6f40e9ceff5c1730d8f8e488f1add5f")
    }

    func testMalformedOrNonObjectJSONFallsBackToEmptyObject() throws {
        for source in ["", "{", "null", "true", "12", "\"text\"", "[]", "[{}]"] {
            XCTAssertTrue(jsonObject(source).isEmpty, source)
        }
        XCTAssertEqual(try jsonString(jsonObject("{")), "{}")
        XCTAssertEqual(ChecklistCore.hash(Data("{}".utf8)), "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        XCTAssertThrowsError(try jsonString("scalar")) {
            XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT")
        }
    }

    func testUnknownFieldsAndEnumStringsSurviveUntypedCodec() throws {
        let source = #"{"future_field":{"enabled":true},"kind":"future_kind"}"#
        let parsed = jsonObject(source)
        XCTAssertEqual(parsed["kind"] as? String, "future_kind")
        XCTAssertEqual(try jsonString(parsed), source)
    }
}

extension CoreTests {
    func testLegacyContractParityTaskCreateRejectsUnknownKindAndIgnoresUnknownField() throws {
        let p = try project("Legacy parity", "LCP")
        XCTAssertThrowsError(try call("task_create", ["project_id": p["id"]!, "title": "Unknown kind", "kind": "future_kind"])) {
            XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT")
        }
        let created = try call("task_create", ["project_id": p["id"]!, "title": "Unknown field", "future_field": "preserve boundary"])
        XCTAssertNil(created["future_field"])
        XCTAssertEqual(created["kind"] as? String, "work")
        XCTAssertEqual(created["readiness"] as? String, "draft")
    }
}
