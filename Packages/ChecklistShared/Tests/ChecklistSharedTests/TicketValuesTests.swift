import XCTest
import ChecklistDomain
import ChecklistContracts
import ChecklistApplication

final class TicketValuesTests: XCTestCase {
    func testStableWireValues() {
        XCTAssertEqual(TicketKind.wireValues, ["work", "bug", "asset", "playtest", "question"])
        XCTAssertEqual(TicketStatusCategory.wireValues, ["queued", "active", "review", "blocked", "parked", "done", "canceled"])
        XCTAssertEqual(AttemptPhase.wireValues, ["implementation", "review"])
        XCTAssertEqual(WorkflowRole.wireValues, ["coordinator", "implementer", "reviewer"])
        XCTAssertEqual(CallerRole.wireValues, ["owner", "worker", "reviewer", "assistant"])
        XCTAssertNil(TicketKind(rawValue: "future"))
        XCTAssertNil(TicketStatusCategory(rawValue: "cancelled"))
        XCTAssertNil(AttemptPhase(rawValue: "worker"))
        XCTAssertEqual(AttemptPhase.review.workflowRole, .reviewer)
        XCTAssertEqual(AttemptPhase.implementation.workflowRole, .implementer)
    }
}
