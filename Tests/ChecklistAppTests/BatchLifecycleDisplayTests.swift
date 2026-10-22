import XCTest
@testable import ChecklistApp

final class BatchLifecycleDisplayTests: XCTestCase {
    func testPreparationAndLegacySummaryNeverSayStartedOrClaimed() {
        for lifecycle in [nil,"prepared"] as [String?] {
            var values: [String:Any] = ["id":"b","created_at":"preparation"]
            values["lifecycle"] = lifecycle
            let display = BatchLifecycleDisplay(Record(values:values))
            XCTAssertEqual(display.label,"Prepared");XCTAssertEqual(display.date,"preparation");XCTAssertEqual(display.reason,"")
        }
    }
    func testDiscardUsesDispositionDateAndRetainsReason() {
        let display = BatchLifecycleDisplay(Record(values:["id":"b","lifecycle":"discarded","created_at":"prepare","disposition":["created_at":"discard","reason":"Superseded plan"]]))
        XCTAssertEqual(display.label,"Discarded");XCTAssertEqual(display.date,"discard");XCTAssertEqual(display.reason,"Superseded plan")
    }
    func testClaimUsesDispatchDateWithoutInventingOneForLegacyAttempts() {
        let display = BatchLifecycleDisplay(Record(values:["id":"b","lifecycle":"claimed","created_at":"prepare","dispatch":["created_at":"claim"]]))
        XCTAssertEqual(display.label,"Claimed");XCTAssertEqual(display.date,"claim")
        XCTAssertEqual(BatchLifecycleDisplay(Record(values:["id":"b","lifecycle":"claimed","created_at":"prepare"])).date,"")
    }
}
