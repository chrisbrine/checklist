import XCTest
@testable import ChecklistCore

final class EnvelopeLexicalScanTests: XCTestCase {
    private func decode(_ raw: String, id: String = "record", project: String = "p", revision: Int64 = 1) throws -> DecodedEnvelope {
        try CanonicalEnvelope.decode(EnvelopeRow(columns: [
            "id": .text(id), "project_id": .text(project), "type": .text("message"),
            "revision": .integer(revision), "data": .text(raw)
        ]))
    }

    private func refuses(_ raw: String, reason: EnvelopeFailure.Reason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(raw), file: file, line: line) {
            XCTAssertEqual(($0 as? EnvelopeFailure)?.reason, reason, file: file, line: line)
        }
    }

    func testEscapedTopLevelEnvelopeKeysStillDetectDuplicates() {
        let duplicates = [
            #"{"id":"record","\u0069d":"record","project_id":"p","revision":1}"#,
            #"{"id":"record","project_id":"p","project_\u0069d":"p","revision":1}"#,
            #"{"id":"record","project_id":"p","revision":1,"revis\u0069on":1}"#,
            #"{"id":"record","nested":[{"id":"nested","revision":2}],"project_id":"p","revision":1,"\u0072evision":1}"#
        ]
        for raw in duplicates { refuses(raw, reason: .duplicateEnvelopeField) }
    }

    func testEscapedEnvelopeKeysDecodeNormally() throws {
        let value = try decode(#"{"\u0069d":"record","project_\u0069d":"p","revis\u0069on":1}"#)
        XCTAssertEqual(value.id, "record")
        XCTAssertEqual(value.projectID, "p")
        XCTAssertEqual(value.revision, 1)
    }

    func testNestedContainersAndEscapedQuotesDoNotHideFollowingEnvelopeFields() throws {
        let raw = #"{"nested":[{"body":"quotes: \" and slash: \\ and brackets: } ] { [","nested":[null,false,1.5,{"id":"nested","project_id":"other","revision":2}]}],"body":"é 🍎 \u0000","id":"record","project_id":"p","revision":1}"#
        let value = try decode(raw)
        XCTAssertEqual(value.object["body"] as? String, "é 🍎 \0")
        XCTAssertEqual(value.revision, 1)
    }

    func testUnrelatedAndNestedDuplicateKeysRemainAllowed() throws {
        let raw = #"{"id":"record","project_id":"p","revision":1,"body":"before","body":"after","nested":{"id":"first","id":"last","revision":2,"revision":3}}"#
        let value = try decode(raw)
        XCTAssertEqual(value.id,"record");XCTAssertEqual(value.projectID,"p");XCTAssertEqual(value.revision,1)
        // The existing Foundation parser owns unrelated duplicate value choice;
        // the envelope contract only requires that these keys remain allowed.
        XCTAssertTrue(["before","after"].contains(value.object["body"] as? String ?? ""))
    }

    func testMalformedJSONStillFailsCompleteValidation() {
        let invalid = [
            #"{"id":"record","project_id":"p","revision":1,"nested":[}"#,
            #"{"id":"record","project_id":"p","revision":1,"nested":{"body":"unterminated}}"#,
            #"{"id":"record","project_id":"p","revision":1,,"body":"x"}"#,
            #"{"id":"record","project_id":"p","revision":1,"body":"\q"}"#,
            #"{"id":"record","project_id":"p","revision":1} trailing"#,
            "{\"id\":\"record\",\"project_id\":\"p\",\"revision\":1,\"body\":\"literal\0nul\"}"
        ]
        for raw in invalid { refuses(raw, reason: .jsonObject) }
    }

    func testExactRevisionSpellingIsRetainedThroughValueSkip() throws {
        for token in ["1", "1.0", "1e0", "10e-1", "0.1e1"] {
            XCTAssertEqual(try decode("{\"id\":\"record\",\"project_id\":\"p\",\"revision\":\(token)}").revision, 1)
        }
        for token in ["1.00000000000000001", "1.000000000000000001e0", "true", "false", "0", "-1", "1.5", "9223372036854775808"] {
            refuses("{\"id\":\"record\",\"project_id\":\"p\",\"revision\":\(token)}", reason: .jsonRevision)
        }
    }

    func testStorageIdentityFastPathIsByteExactForNULUnicodeAndLargeValues() {
        let long = String(repeating:"source-captures/é\0",count:16_384)
        let copied = String(decoding:Array(long.utf8),as:UTF8.self)
        let pairs: [(String,String,Bool)] = [
            ("","",true),("","x",false),("same","same",true),("same","Same",false),
            ("é","e\u{301}",false),("x\0a","x\0b",false),("🍎\0é","🍎\0é",true),
            (long,copied,true),(long + "a",copied + "b",false)
        ]
        for (a,b,expected) in pairs {
            XCTAssertEqual(EnvelopeStorageIdentity.equal(a,b),expected)
            XCTAssertEqual(EnvelopeSQLValue.text(a) == EnvelopeSQLValue.text(b),expected)
        }
        XCTAssertTrue(EnvelopeStorageIdentity.equal(nil,nil))
        XCTAssertFalse(EnvelopeStorageIdentity.equal(nil,Optional("")))
    }

    func testUnicodeAndEscapedNULAreNotCStringTerminators() throws {
        let raw = #"{"body":"before\u0000é🍎after","id":"récord\u0000🍎","project_id":"prøject\u0000é","revision":1}"#
        let value = try decode(raw, id: "récord\0🍎", project: "prøject\0é")
        XCTAssertEqual(value.object["body"] as? String, "before\0é🍎after")
        XCTAssertEqual(value.id.utf8.elementsEqual("récord\0🍎".utf8), true)
    }
}
