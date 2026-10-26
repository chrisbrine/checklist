import ChecklistTestSupport
import Foundation
import XCTest
@testable import ChecklistCore

final class MediaStoredRecordTests: XCTestCase {
    func testMalformedMediaReferencesThrowWithoutInventingFields() throws {
        let fixture = try StorageFixture(fast:true)
        let router = try XCTUnwrap(fixture.router)
        let malformed: [JSON] = [[:], ["id":"retained"]]
        for record in malformed {
            XCTAssertThrowsError(try router.mediaRef("media_review_context", record)) { error in
                XCTAssertEqual((error as? CoreError)?.code, "CANONICAL_RECORD_INVALID")
            }
        }
    }

    func testOpenMediaReferenceRetainsLegacyDynamicValues() throws {
        let fixture = try StorageFixture(fast:true)
        let router = try XCTUnwrap(fixture.router)
        let reference = try router.mediaRef("media_review_context", [
            "id":"retained", "revision":NSNull(), "future_field":"retained only in source"
        ])
        XCTAssertEqual(reference["id"] as? String, "retained")
        XCTAssertTrue(reference["revision"] is NSNull)
        XCTAssertNil(reference["future_field"])
    }

    func testMalformedRoundRelationshipsThrowAtTypedProjection() throws {
        let fixture = try StorageFixture(fast:true)
        let router = try XCTUnwrap(fixture.router)
        let malformed: [JSON] = [[:], ["project_id":NSNull()], ["project_id":17], ["project_id":true]]
        for record in malformed {
            XCTAssertThrowsError(try router.dbQueue.read { db in
                try router.mediaRoundParts(db, record)
            }) { error in
                XCTAssertEqual((error as? CoreError)?.code, "CANONICAL_RECORD_INVALID")
            }
        }
    }
}
