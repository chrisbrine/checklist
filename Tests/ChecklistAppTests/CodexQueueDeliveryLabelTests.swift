import XCTest
@testable import ChecklistApp

final class CodexQueueDeliveryLabelTests: XCTestCase {
    func testWaitingLabelPreservesAcknowledgmentFencesAndReplies() {
        func label(_ state: String, replied: Bool = false) -> String {
            var fields: [String:Any] = ["state":state,"route_receipt":["reason_code":"queue_occupied","open_result":"exited_zero"]]
            if replied { fields["reply_message_id"] = "reply" }
            return DeliveryLabels.receipt(delivery:Record(values:fields))
        }
        XCTAssertEqual(label("queued"),"Waiting for earlier Codex queue item")
        XCTAssertEqual(label("unavailable"),"Waiting for earlier Codex queue item")
        XCTAssertEqual(label("acknowledged"),"Acknowledged")
        XCTAssertEqual(label("fenced"),"Not delivered: this conversation was disconnected")
        XCTAssertEqual(label("queued",replied:true),"Replied")
    }
}
