import XCTest
import MCP
@testable import ChecklistCLI

final class JSONOutputTests: XCTestCase {
    private let controls = String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! }))

    private func strictlyParse(_ write: (FileHandle) throws -> Void) throws -> Data {
        // Python's default strict parser rejects literal U+0000...U+001F in strings.
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import json,sys; print(json.dumps(json.load(sys.stdin),ensure_ascii=True))"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try write(input.fileHandleForWriting)
        try input.fileHandleForWriting.close()
        let parsed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return parsed
    }

    private func strictlyParse(_ bytes: Data) throws -> Data {
        try strictlyParse { $0.write(bytes) }
    }

    func testCLIResultWriterPipesEveryControlCharacterToStrictParser() throws {
        let text = controls + "quotes \" slash / backslash \\ literal \\u0000 é 🧪" + String(repeating: "context ", count: 2000) + controls
        let value: Value = .object([controls: .array([.string(text), .null, .bool(true), .int(42), .double(1.5)])])
        // Pipe the exact writer used by checklist call into an independent strict parser,
        // without native enrollment, Keychain access or a live service mutation.
        let parsed = try strictlyParse { try ChecklistCommand.printJSON(value, to: $0) }
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: parsed), value)
    }

    func testGuardEscapesRawControlsInKeysAndNestedValuesWithoutChangingFormattingOrEscapes() throws {
        let raw = Data(("{\n\t\"" + controls + "\": [\"prefix \\\" \\\\ \\n \\u001f " + controls + " é🧪\"]\r\n}").utf8)
        let safe = JSONOutput.escapingStringControls(raw)
        let parsed = try JSONSerialization.jsonObject(with: strictlyParse(safe)) as! [String: [String]]
        XCTAssertEqual(parsed[controls], ["prefix \" \\ \n \u{1f} " + controls + " é🧪"])
        XCTAssertTrue(String(decoding: safe, as: UTF8.self).hasPrefix("{\n\t"))
        XCTAssertTrue(String(decoding: safe, as: UTF8.self).hasSuffix("\r\n}"))
        XCTAssertEqual(JSONOutput.escapingStringControls(safe), safe)
    }

    func testGuardPreservesAlreadyValidJSONIncludingScalarResults() throws {
        for value: Value in [.null, .bool(false), .int(1), .double(1.25), .string(controls), .array([]), .object([:])] {
            let bytes = try JSONEncoder().encode(value)
            XCTAssertEqual(JSONOutput.escapingStringControls(bytes), bytes)
            XCTAssertEqual(try JSONDecoder().decode(Value.self, from: strictlyParse(bytes)), value)
        }
    }
}
