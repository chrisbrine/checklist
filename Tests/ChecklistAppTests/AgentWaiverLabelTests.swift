import XCTest
@testable import ChecklistApp

final class AgentWaiverLabelTests: XCTestCase {
    func testAgentWaiverCannotBePresentedAsOwnerAction() {
        let agent = Record(values:["id":"agent","disposition":"waived","origin":"agent"])
        let owner = Record(values:["id":"owner","disposition":"waived","origin":"human_ui"])
        let historicalOwner = Record(values:["id":"old","disposition":"waived"])
        XCTAssertEqual(ReviewProjection.findingDispositionLabel(agent),"Explicit agent waiver · not a passing check")
        XCTAssertEqual(ReviewProjection.findingDispositionLabel(owner),"Explicit owner waiver · not a passing check")
        XCTAssertEqual(ReviewProjection.findingDispositionLabel(historicalOwner),ReviewProjection.findingDispositionLabel(owner))
    }
}
