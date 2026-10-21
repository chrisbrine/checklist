import XCTest
@testable import ChecklistApp

final class TicketUndoTests: XCTestCase {
    func testUndoRequiresExactRevisionNoClaimsAndRetainedBytes() throws {
        let result: [String:Any] = ["id":"ticket","project_id":"project","revision":3,"cleaned_original_count":0]
        let undo = try XCTUnwrap(TicketUndo.archive(result,action:"archive"))
        XCTAssertEqual(undo.parameters["action"] as? String,"unarchive")
        XCTAssertEqual(undo.parameters["expected_revision"] as? Int,3)
        XCTAssertTrue(undo.available(task:Record(values:result),files:[]))
        XCTAssertFalse(undo.available(task:Record(values:result.merging(["id":"another-ticket"]) {_,new in new}),files:[]))
        XCTAssertFalse(undo.available(task:Record(values:result.merging(["revision":4]) {_,new in new}),files:[]))
        XCTAssertFalse(undo.available(task:Record(values:result.merging(["active_attempt_id":"new-claim"]) {_,new in new}),files:[]))
        XCTAssertFalse(undo.available(task:Record(values:result.merging(["active_verification_request_id":"review"]) {_,new in new}),files:[]))
        XCTAssertFalse(undo.available(task:Record(values:result),files:[Record(values:["id":"file","availability":"original_cleaned"])]))
    }
    func testTrashInverseAndReopenDoneDoNotInventCompletion() throws {
        let result: [String:Any] = ["id":"ticket","project_id":"project","revision":3,"cleaned_original_count":0]
        XCTAssertEqual(try XCTUnwrap(TicketUndo.archive(result,action:"trash")).parameters["action"] as? String,"restore")
        XCTAssertNil(TicketUndo.transition(result,previous:Record(values:["id":"ticket","status_category":"done"])))
        XCTAssertNotNil(TicketUndo.transition(result,previous:Record(values:["id":"ticket","project_id":"project","status_category":"canceled","status_id":"canceled-status"])))
    }
}
