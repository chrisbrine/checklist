import XCTest
import ChecklistContracts

final class MediaStarterCatalogTests: XCTestCase {
    func testAnimationTakesEnablesReviewInDraft() throws {
        let schema = MediaStarterCatalog.schema(title: "Animation takes", starter: "animation_video")
        let layout = try XCTUnwrap(schema["layout"] as? [String: Any])
        XCTAssertEqual(layout["review_in_draft"] as? Bool, true)
    }

    func testOtherStartersLeaveReviewInDraftAbsent() throws {
        for starter in MediaStarterCatalog.starters where starter.id != "animation_video" {
            let schema = MediaStarterCatalog.schema(title: starter.name, starter: starter.id)
            let layout = try XCTUnwrap(schema["layout"] as? [String: Any])
            XCTAssertNil(layout["review_in_draft"], starter.id)
        }
    }
}
