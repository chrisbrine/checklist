import ChecklistTestSupport
import Foundation
import GRDB
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

    func testTypeAdoptionRejectsNullMetadataAndRollsBack() throws {
        try assertTypeAdoptionRejectsMalformedTarget(field: "metadata", value: NSNull())
    }

    func testTypeAdoptionRejectsMissingOrWrongMandatoryTargetFields() throws {
        for field in ["title", "metadata"] {
            let malformed: [Any?] = field == "title" ? [nil, NSNull(), true, 7, [:]] : [nil, true, 7, "metadata", []]
            for value in malformed {
                try assertTypeAdoptionRejectsMalformedTarget(field: field, value: value)
            }
        }
    }

    private func assertTypeAdoptionRejectsMalformedTarget(field: String, value: Any?) throws {
        let checks = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let type = try f.type(checks.schema()), round = try f.round(type), item = try f.item(round)
        _ = try checks.revise(f, type, checks.schema(), rubric: "Changed rubric")
        let target = try XCTUnwrap(item["draft_target"] as? JSON)
        try replaceTargetField(f, target: target, field: field, value: value)
        let typeID = try XCTUnwrap(type["id"] as? String), roundID = try XCTUnwrap(round["id"] as? String)
        let beforeType = try f.record(typeID, "media_review_type"), beforeRound = try f.record(roundID, "media_round")
        let before = try f.allState()
        checks.checkError("CANONICAL_RECORD_INVALID") { try f.adoptType(type) }
        XCTAssertEqual(try f.allState(), before, "Failed adoption must roll back all records, events and commands")
        let afterType = try f.record(typeID, "media_review_type"), afterRound = try f.record(roundID, "media_round")
        XCTAssertEqual(afterType["adopted_revision_id"] as? String, beforeType["adopted_revision_id"] as? String)
        XCTAssertEqual(int(afterType, "revision"), int(beforeType, "revision"))
        XCTAssertEqual(int(afterRound, "revision"), int(beforeRound, "revision"))
        XCTAssertEqual(strings(afterRound, "attention_ids"), strings(beforeRound, "attention_ids"))
        XCTAssertTrue(try f.rows("media_context_attention").isEmpty)
    }

    func testTypeAdoptionToleratesLegacyMetadataShapeIncompatibility() throws {
        let checks = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let type = try f.type(checks.schema()), round = try f.round(type), item = try f.item(round)
        let proposed = try checks.revise(f, type, checks.schema(), rubric: "Changed rubric")
        let target = try XCTUnwrap(item["draft_target"] as? JSON)
        // The required payload remains an object; an old unrecognized key cannot be normalized as a schema ID.
        try replaceTargetField(f, target: target, field: "metadata", value: ["": "legacy value"])
        let roundID = try XCTUnwrap(round["id"] as? String), beforeRound = try f.record(roundID, "media_round")
        let adopted = try f.adoptType(type)
        XCTAssertEqual(adopted["adopted_revision_id"] as? String, proposed["draft_revision_id"] as? String)
        XCTAssertEqual(int(adopted, "revision"), int(proposed, "revision") + 1)
        let afterRound = try f.record(roundID, "media_round")
        XCTAssertEqual(int(afterRound, "revision"), int(beforeRound, "revision") + 1)
        XCTAssertEqual(strings(afterRound, "attention_ids").count, 1)
        XCTAssertEqual(try f.rows("media_context_attention").count, 1)
    }

    func testMaterialReferenceAdoptionPropagatesMalformedApprovedTargetWithoutMutation() throws {
        let checks = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let type = try f.type(checks.schema()), source = try f.round(type)
        _ = try f.item(source)
        _ = try f.publish(source)
        try f.acceptEach(source)
        let accepted = try f.get(source), acceptedItems = try XCTUnwrap(accepted["items"] as? [JSON])
        let acceptedItem = try XCTUnwrap(acceptedItems.first), target = try XCTUnwrap(acceptedItem["published_target"] as? JSON)
        let decision = try XCTUnwrap(acceptedItem["decision"] as? JSON)
        let destination = try f.round(type), item = try f.item(destination), published = try f.publish(destination)
        let publishedItems = try XCTUnwrap(published["items"] as? [JSON]), publishedItem = try XCTUnwrap(publishedItems.first)
        let manifest = try XCTUnwrap(published["manifest"] as? JSON)
        var params = f.observation(published)
        params["manifest_id"] = manifest["id"]; params["manifest_digest"] = manifest["digest"]
        params["item_id"] = item["id"]; params["expected_item_revision"] = publishedItem["revision"]
        params["reference_target_id"] = target["id"]; params["reference_decision_id"] = decision["id"]
        params["reference_slot_id"] = "text"; params["slot_id"] = "text"
        try replaceTargetField(f, target: target, field: "metadata", value: NSNull())
        let before = try f.allState()
        checks.checkError("CANONICAL_RECORD_INVALID") { try f.call("media_material_reference_adopt", params) }
        XCTAssertEqual(try f.allState(), before)
    }

    private func replaceTargetField(_ f: MediaRoundTests.Fixture, target: JSON, field: String, value: Any?) throws {
        var malformed = target
        malformed[field] = value
        let targetID = try XCTUnwrap(target["id"] as? String)
        // Inject only the malformed payload in this disposable fixture, retaining its canonical envelope and references.
        try f.router.dbQueue.write { db in
            try db.execute(sql: "UPDATE records SET data = ? WHERE id = ? AND type = 'media_item_target'",
                           arguments: [try jsonString(malformed), targetID])
        }
    }

}
