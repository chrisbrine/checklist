import XCTest
@testable import ChecklistApp

/// Two NEW affected state controls, prepared only; no execution claimed.
final class SelectedEventHistoryTests: XCTestCase {
    private let page: [String:Any] = ["events":[["id":"old-event"]],"has_more":true,"next_cursor":"X-cursor"]
    func testSameTicketStoreChangeDropsInstalledHistoryAndLateReply() throws {
        var state = SelectedEventHistory();let x = state.begin(store:"X")
        XCTAssertTrue(try state.receive(page,for:x,currentStore:"X"));XCTAssertEqual(state.nextCursor,"X-cursor")
        XCTAssertNil(state.records(in:"Y"),"A different selected store cannot display old installed events before observation cleanup")
        let late = state.begin(store:"X");state.observe(store:"Y")
        XCTAssertNil(state.records);XCTAssertNil(state.nextCursor);XCTAssertFalse(state.loading)
        let y = state.begin(store:"Y");XCTAssertNil(y.cursor)
        XCTAssertFalse(try state.receive(page,for:late,currentStore:"Y"));XCTAssertNil(state.records)
        XCTAssertTrue(try state.receive(["events":[["id":"new-event"]],"has_more":false,"next_cursor":"Y-cursor"],for:y,currentStore:"Y"))
        XCTAssertEqual(state.records?.map(\.id),["new-event"])
    }
    func testCursorResetStartsFreshWhileOrdinaryFailureRetainsValidCursor() throws {
        var state = SelectedEventHistory();let first = state.begin(store:"X")
        try state.receive(page,for:first,currentStore:"X")
        let later = state.begin(store:"X");XCTAssertEqual(later.cursor,"X-cursor")
        state.fail(later,resetCursor:false);XCTAssertEqual(state.nextCursor,"X-cursor");XCTAssertNotNil(state.records)
        let invalid = state.begin(store:"X");state.fail(invalid,resetCursor:true)
        XCTAssertNil(state.nextCursor);XCTAssertNil(state.records)
        XCTAssertNil(state.begin(store:"X").cursor,"Retry after reset must not send the invalid cursor again")
    }
}
