import XCTest
@testable import ChecklistApp

final class TicketKeyboardNavigationTests: XCTestCase {
    func testNavigationUsesDisplayedOrderWithoutWrapping() {
        let ids = ["third", "first", "second"]
        XCTAssertEqual(TicketKeyboardNavigation.destination(in: ids, current: "first", forward: true), "second")
        XCTAssertEqual(TicketKeyboardNavigation.destination(in: ids, current: "first", forward: false), "third")
        XCTAssertNil(TicketKeyboardNavigation.destination(in: ids, current: "second", forward: true))
        XCTAssertNil(TicketKeyboardNavigation.destination(in: ids, current: "third", forward: false))
    }
    func testMissingSelectionStartsAtTheAppropriateEnd() {
        XCTAssertNil(TicketKeyboardNavigation.destination(in: [], current: nil, forward: true))
        XCTAssertEqual(TicketKeyboardNavigation.destination(in: ["a", "b"], current: nil, forward: true), "a")
        XCTAssertEqual(TicketKeyboardNavigation.destination(in: ["a", "b"], current: "filtered-out", forward: false), "b")
    }
    func testRecordIDsKeepTheirExactBytes() {
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        XCTAssertEqual(TicketKeyboardNavigation.destination(in: [composed, decomposed, "end"], current: decomposed, forward: true), "end")
    }
    func testOnlyRenderedTicketRowsEnterOrderAndDuplicatesAreRemoved() {
        let a = Record(values: ["id": "a"]), b = Record(values: ["id": "b"])
        let rows: [TicketListRow] = [
            .init(id: .heading("Tickets"), content: .heading("Tickets", 2)),
            .init(id: .triageMember(triageID: "t", taskID: "b"), content: .triageMember(b)),
            .init(id: .request("r"), content: .request(Record(values: ["id": "r"]))),
            .init(id: .ticket("a"), content: .ticket(a)),
            .init(id: .ticket("b"), content: .ticket(b))
        ]
        XCTAssertEqual(TicketKeyboardNavigation.order(rows), ["b", "a"])
    }
}
