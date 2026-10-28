import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class TicketTimestampTests: XCTestCase {
    func testSQLTimestampMatchesOriginalFractionalFirstFoundationParser() throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        let values = [
            "2026-10-28T12:34:56Z", "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z",
            "2000-02-29T23:59:59Z", "1900-02-28T00:00:00Z", "2024-02-29T00:00:00Z",
            "0001-01-01T00:00:00Z", "0000-01-01T00:00:00Z", "1582-10-04T00:00:00Z",
            "1582-10-15T00:00:00Z", "9999-12-31T23:59:59Z",
            "2026-10-28T12:34:56.001Z", "2026-10-28T12:34:56.123456789Z",
            "2026-10-28T12:34:56+00:00", "2026-10-28T12:34:56-07:00",
            "2026-10-28T12:34:56.125+05:30", "2026-10-28T12:34:56+0000",
            "2026-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2026-13-01T00:00:00Z",
            "2026-10-28T24:00:00Z", "2016-12-31T23:59:60Z", "2026-10-28T12:34:56z",
            "2026-10-28t12:34:56Z", "2026-10-28T12:34:56Z trailing", "2026-10-28",
            "", "invalid", "2026-10-28T12:34:56.Z", "2026-10-28T12:34:56\u{0}Z"
        ]
        let queue = try DatabaseQueue()
        try queue.read { db in
            CommandRouter.installTicketSearchFunctions(db)
            for value in values {
                let expected = (fractional.date(from:value) ?? standard.date(from:value) ?? .distantPast).timeIntervalSince1970
                let actual = try Double.fetchOne(db,sql:"SELECT checklist_timestamp(?)",arguments:[value])
                XCTAssertEqual(actual,expected,value.debugDescription)
                XCTAssertEqual(try Double.fetchOne(db,sql:"SELECT checklist_timestamp(?)",arguments:[value]),expected,"Cached " + value.debugDescription)
            }
            XCTAssertEqual(try Double.fetchOne(db,sql:"SELECT checklist_timestamp(NULL)"),Date.distantPast.timeIntervalSince1970)
        }
    }
}
