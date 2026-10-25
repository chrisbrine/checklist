import XCTest
@testable import ChecklistApp

final class RecordOrderingTests: XCTestCase {
    func testFractionalOffsetsInvalidDatesAndCustomTimestampKeepOrdering() {
        let records = [
            Record(values:["id":"bad","started_at":"invalid"]),
            Record(values:["id":"plain","started_at":"2026-10-24T10:00:00Z"]),
            Record(values:["id":"fractional","started_at":"2026-10-24T10:00:00.125Z"]),
            Record(values:["id":"offset","started_at":"2026-10-24T12:00:01+02:00"])
        ]
        XCTAssertEqual(RecordOrdering.newestFirst(records,timestamp:"started_at").map(\.id),["offset","fractional","plain","bad"])
    }
    func testCoarseChronologicalTiesUseInputPositionAndOrdinaryTiesUseIDs() {
        let records = ["z","a","m"].map {Record(values:["id":$0,"created_at":"2026-10-24T10:00:00Z"])}
        XCTAssertEqual(RecordOrdering.newestFirst(records,chronologicalInput:true).map(\.id),["m","a","z"])
        XCTAssertEqual(RecordOrdering.newestFirst(records).map(\.id),["z","m","a"])
    }
    func testConcurrentTimestampParsingKeepsExactResults() {
        let records = [
            Record(values:["id":"earlier","created_at":"2026-10-24T10:00:00Z"]),
            Record(values:["id":"later","created_at":"2026-10-24T10:00:00.500Z"])
        ]
        let lock = NSLock();var failures = 0
        DispatchQueue.concurrentPerform(iterations:64) { _ in
            if RecordOrdering.newestFirst(records).map(\.id) != ["later","earlier"] {lock.lock();failures += 1;lock.unlock()}
        }
        XCTAssertEqual(failures,0)
    }
    func testFiftyCoarseMessagesSortWithinFrameBudget() {
        let records = (0..<50).map {Record(values:["id":"message-\($0)","created_at":"2026-10-24T10:00:00Z"])}
        let start = ProcessInfo.processInfo.systemUptime
        let ordered = RecordOrdering.newestFirst(records,chronologicalInput:true)
        let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
        print("P9-r5 fifty_coarse_message_order_ms=\(ms)")
        XCTAssertEqual(ordered.map(\.id),records.reversed().map(\.id))
        XCTAssertLessThan(ms,300,"Sorting a bounded conversation must leave room for its native frame")
    }
}
