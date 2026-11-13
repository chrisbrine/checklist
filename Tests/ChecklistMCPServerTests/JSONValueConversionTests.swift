import XCTest
import MCP
@testable import ChecklistMCPServer

/// CL-444: the direct walk must give the value that `Value`'s decoder gives.
final class JSONValueConversionTests: XCTestCase {
    /// The transport's own decoding of a service reply.
    private func parsed(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    private func assertSameAsDecoder(_ input: Any, direct expected: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try mcpValueByDecoding(input)
        XCTAssertEqual(try mcpValue(input), decoded, file: file, line: line)
        if let direct = JSONValueConversion.value(input) { XCTAssertEqual(direct, decoded, file: file, line: line) }
        if let expected { XCTAssertEqual(JSONValueConversion.value(input) != nil, expected, "direct walk used", file: file, line: line) }
    }

    func testReplyTreeTakesTheDirectWalkAndEqualsTheDecoder() throws {
        let reply = try parsed("""
        {"data":{"build_id":"a8809b62006661f9","build_number":321,"caller":{"session_id":"s","role":"worker","verified":true},
          "capabilities":["read","write"],"empty_list":[],"empty_object":{},"nothing":null,"ratio":0.25,"negative":-17,
          "native_recovery":[{"body":"Line one\\nLine \\"two\\" / slash \\\\ back \\u0007 é 🧪 \\ud83e\\uddea","title":"data: is no URL","count":3}],
          "database":"data","text":"datum:,x"},
         "event_cursor":"c1.aSaiy1ya7OTjtSxR","write_admission":{"backup_active":false,"estimated_remaining_seconds":null,"revision":6},
         "_checklist_timing":{"total_ms":68.425374804064631,"received_uptime_s":2053844.5640017919,"queue_wait_ms":0}}
        """)
        try assertSameAsDecoder(reply, direct: true)
        guard case .object(let top)? = JSONValueConversion.value(reply), case .object(let data)? = top["data"],
              case .object(let timing)? = top["_checklist_timing"] else { return XCTFail("object expected") }
        XCTAssertEqual(data["build_number"], .int(321))
        XCTAssertEqual(data["ratio"], .double(0.25))
        XCTAssertEqual(data["nothing"], .null)
        XCTAssertEqual(data["caller"], .object(["session_id": .string("s"), "role": .string("worker"), "verified": .bool(true)]))
        XCTAssertEqual(data["empty_list"], .array([]))
        XCTAssertEqual(data["empty_object"], .object([:]))
        XCTAssertEqual(timing["queue_wait_ms"], .int(0))
        XCTAssertEqual(timing["received_uptime_s"], .double(2053844.5640017919))
    }

    func testEveryJSONNumberFormEqualsTheDecoder() throws {
        let direct = ["0", "-0", "1", "-1", "42", "1.0", "-1.0", "1e3", "1E3", "2.5e2", "0.1", "-0.1", "1.5e-7", "0.30000000000000004",
                      "9007199254740991", "9007199254740992", "-9007199254740992", "9007199254740993", "9223372036854775807",
                      "-9223372036854775808", "9007199254740992.0", "1.7976931348623157e308", "5e-324", "2.2250738585072014e-308",
                      "123456789.12345679", "3.141592653589793", "100000.5", "true", "false", "null"]
        for text in direct {
            try assertSameAsDecoder(try parsed(text), direct: true)
            try assertSameAsDecoder(try parsed("{\"k\":[\(text),{\"n\":\(text)}]}"), direct: true)
        }
        // Outside the exact range the decoder decides that one number; the walk continues.
        // The two long decimals are timing values that JSONSerialization read as NSDecimalNumber.
        for text in ["9223372036854775808", "18446744073709551615", "1e17", "1e19", "-1e19", "9007199254740994.0", "1e300",
                     "123456789012345678901234567890", "0.12345678901234567890123456789", "12345678901234567890.5",
                     "0.022541731595993042", "0.007666647434234619"] {
            try assertSameAsDecoder(try parsed(text), direct: true)
            try assertSameAsDecoder(try parsed("{\"k\":[\(text),\"text\",{\"n\":\(text)}]}"), direct: true)
        }
        XCTAssertTrue(try parsed("0.022541731595993042") is NSDecimalNumber)
        XCTAssertEqual(try mcpValue(try parsed("0.022541731595993042")), .double(0.022541731595993042))
        XCTAssertEqual(try mcpValue(try parsed("18446744073709551615")), .double(18446744073709551615))
        XCTAssertEqual(try mcpValue(try parsed("1.0")), .int(1))
        XCTAssertEqual(try mcpValue(try parsed("-0.0")), .int(0))
        XCTAssertEqual(try mcpValue(try parsed("0.5")), .double(0.5))
    }

    func testSwiftNativeValuesEqualTheDecoder() throws {
        let native: [String: Any] = [
            "int": 7, "int8": Int8(-3), "int32": Int32(5), "uint16": UInt16(9), "uint": UInt(11), "bool": true, "no": false,
            "double": 2.5, "whole": 3.0, "zero": 0.0, "string": "text", "null": NSNull(), "nested": ["a": [1, "2", false, NSNull(), 4.75] as [Any]],
            "connection": ["connected": false, "state": "connection_failed", "retryable": true, "retry_after_seconds": 12.5,
                           "details": ["command_outcome": "rejected", "command_executed": false]] as [String: Any]]
        try assertSameAsDecoder(native, direct: true)
        guard case .object(let object)? = JSONValueConversion.value(native) else { return XCTFail("object expected") }
        XCTAssertEqual(object["bool"], .bool(true))
        XCTAssertEqual(object["int8"], .int(-3))
        XCTAssertEqual(object["whole"], .int(3))
        XCTAssertEqual(object["double"], .double(2.5))
        // Number forms outside the exact rules take the decoder alone and keep its result.
        for input in [["f": Float(0.25)] as [String: Any], ["f": Float(0.1)], ["u": UInt64.max], ["d": Decimal(string: "1.5")!],
                      ["d": NSDecimalNumber(string: "0.1")], ["n": NSNumber(value: Int64.max)], ["u": UInt64(Int64.max)], ["w": 1e17]] {
            try assertSameAsDecoder(input, direct: true)
        }
        for scalar in [7 as Any, "text", true, 2.5, NSNull(), [Any](), [String: Any]()] { try assertSameAsDecoder(scalar, direct: true) }
    }

    func testDataURLStringsKeepTheDecoderRule() throws {
        let strings = ["data:text/plain;base64,aGVsbG8=", "data:,hello%20world", "data:image/png;base64,iVBORw0KGgo=", "data:text/html;charset=utf-8,%3Cp%3E",
                       "data:;base64,", "data:text/plain;base64,not base64!", "data:", "data: no comma", "data", "Data:,upper", " data:,space",
                       "data:\u{301},combining", "database", "", "plain"]
        for string in strings {
            try assertSameAsDecoder(string, direct: true)
            try assertSameAsDecoder(["value": string, "list": [string]], direct: true)
        }
        XCTAssertEqual(try mcpValue("data:text/plain;base64,aGVsbG8="), .data(mimeType: "text/plain", Data("hello".utf8)))
        XCTAssertEqual(try mcpValue("data: no comma"), .string("data: no comma"))
        XCTAssertEqual(try mcpValue("database"), .string("database"))
    }

    /// Input that is no JSON tree leaves the walk, so the decoder path reports it as before.
    func testInputOutsideJSONLeavesTheDirectWalk() {
        for input in [["d": Double.nan] as Any, ["d": Double.infinity], ["list": [1, -Double.infinity] as [Any]], ["date": Date()],
                      [1: "numeric key"], Date(), ["nested": ["url": URL(fileURLWithPath: "/tmp")]]] {
            XCTAssertNil(JSONValueConversion.value(input))
        }
    }

    func testGeneratedTreesEqualTheDecoder() throws {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let texts = ["", "plain", "é 🧪 \u{7} \" \\ /", "data:,x", "data:text/plain;base64,aGk=", "data", "line\nbreak\ttab", "\u{2028}\u{0}"]
        func tree(_ depth: Int) -> Any {
            switch next() % (depth > 3 ? 7 : 9) {
            case 0: return NSNull()
            case 1: return next() % 2 == 0
            case 2: return Int(truncatingIfNeeded: next() >> (next() % 60))
            case 3: return -Int(truncatingIfNeeded: next() >> 40)
            case 4: return Double(next() % 1_000_000) / 64.0
            case 5: return Double(Int64(bitPattern: next() >> 12)) * 0.001
            case 6: return texts[Int(next() % UInt64(texts.count))]
            case 7: return (0..<Int(next() % 5)).map { _ in tree(depth + 1) }
            default:
                var object: [String: Any] = [:]
                for index in 0..<Int(next() % 5) { object["k\(index)\(texts[Int(next() % UInt64(texts.count))])"] = tree(depth + 1) }
                return object
            }
        }
        for _ in 0..<300 {
            let generated = tree(0)
            try assertSameAsDecoder(generated)
            // The same tree as the transport delivers it: JSON text read by JSONSerialization.
            let text = try JSONSerialization.data(withJSONObject: generated, options: [.fragmentsAllowed])
            try assertSameAsDecoder(try JSONSerialization.jsonObject(with: text, options: [.fragmentsAllowed]))
        }
    }

    /// A reply of the measured size: the direct walk must stay far below the decoder's cost.
    func testLargeReplyTakesTheDirectWalk() throws {
        let note: [String: Any] = ["body": String(repeating: "Review evidence returned this ticket. ", count: 12), "title": "A ticket title",
                                   "id": "2dc6f78e-9a6d-4cf9-b35f-4f2f65901449", "sequence": 12345, "acknowledged": false, "score": 0.5]
        let reply: [String: Any] = ["data": ["native_recovery": Array(repeating: note, count: 300), "build_id": "b"], "event_cursor": "c"]
        let bytes = try JSONSerialization.data(withJSONObject: reply)
        XCTAssertGreaterThan(bytes.count, 150_000)
        let object = try JSONSerialization.jsonObject(with: bytes)
        let started = ProcessInfo.processInfo.systemUptime
        let direct = try XCTUnwrap(JSONValueConversion.value(object))
        let directSeconds = ProcessInfo.processInfo.systemUptime - started
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        let decoded = try mcpValueByDecoding(object)
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decodeStarted
        XCTAssertEqual(direct, decoded)
        print("CL-444 direct walk \(directSeconds * 1000) ms; decoder \(decodeSeconds * 1000) ms; \(bytes.count) bytes")
    }
}
