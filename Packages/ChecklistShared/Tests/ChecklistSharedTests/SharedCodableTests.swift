import Foundation
import XCTest
import ChecklistDomain

final class SharedCodableTests: XCTestCase {
    private func checkWireValues<T: RawRepresentable & Codable & Equatable>(
        _ values: [T], file: StaticString = #filePath, line: UInt = #line
    ) throws where T.RawValue == String {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let encoded = try encoder.encode(value)
            XCTAssertEqual(encoded, Data("\"\(value.rawValue)\"".utf8), file: file, line: line)
            XCTAssertEqual(try decoder.decode(T.self, from: encoded), value, file: file, line: line)
        }
        for invalid in ["\"future_value\"", "null", "true", "1", "{}"] {
            XCTAssertThrowsError(try decoder.decode(T.self, from: Data(invalid.utf8)), file: file, line: line)
        }
    }

    func testEverySharedEnumPreservesStringWireEncodingAndRejectsUnknownValues() throws {
        try checkWireValues(TicketKind.allCases)
        try checkWireValues(TicketStatusCategory.allCases)
        try checkWireValues(AttemptPhase.allCases)
        try checkWireValues(WorkflowRole.allCases)
        try checkWireValues(CallerRole.allCases)
    }
}
