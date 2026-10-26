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
        let makeRecords: @Sendable () -> [Record] = { [
            Record(values:["id":"earlier","created_at":"2026-10-24T10:00:00Z"]),
            Record(values:["id":"later","created_at":"2026-10-24T10:00:00.500Z"])
        ]
        }
        let failures = FixtureFailureCount()
        DispatchQueue.concurrentPerform(iterations:64) { _ in
            if RecordOrdering.newestFirst(makeRecords()).map(\.id) != ["later","earlier"] { failures.increment() }
        }
        XCTAssertEqual(failures.value,0)
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

// The lock owns every read and write of the failure count.
private final class FixtureFailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
