import XCTest
@testable import ChecklistCore

final class MediaItemFrameRateSchemaTests: XCTestCase {
    func schema(field: [String:Any] = ["id":"fps","kind":"number","material":true],layout: [String:Any]? = nil) -> [String:Any] {
        ["schema_version":1,"id":"video","name":"Video", "fields":[field],
         "slots":[["id":"video","kind":"video","material":true]],
         "layout":layout ?? ["kind":"video_compare","primary_slot_id":"video","loop":true,"frame_rate_field_id":"fps"]]
    }
    func testRateFieldNamesDeclaredMaterialNumberAndIsVideoOnly() throws {
        let parsed = try MediaReviewSchema.parse(schema())
        XCTAssertEqual(parsed.layout.frameRateFieldID?.rawValue,"fps")
        XCTAssertNil(parsed.layout.frameRate)
        for field in [["id":"different","kind":"number"],["id":"fps","kind":"short_text"],["id":"fps","kind":"number","material":false]] as [[String:Any]] {
            XCTAssertThrowsError(try MediaReviewSchema.parse(schema(field:field)))
        }
        XCTAssertThrowsError(try MediaReviewSchema.parse(schema(layout:["kind":"video_compare","primary_slot_id":"video","frame_rate":12,"frame_rate_field_id":"fps"])))
        XCTAssertThrowsError(try MediaReviewSchema.parse(schema(layout:["kind":"generic","frame_rate_field_id":"fps"])))
        var image = schema(layout:["kind":"image_compare","primary_slot_id":"video","frame_rate_field_id":"fps"])
        image["slots"] = [["id":"video","kind":"image"]]
        XCTAssertThrowsError(try MediaReviewSchema.parse(image))
    }
    func testPerItemRateAcceptsOnlyBoundedFiniteNumericValues() throws {
        let parsed = try MediaReviewSchema.parse(schema()),id = try MediaReviewID("fps")
        for rate in [1.0,4,8,12,23.976,240] { XCTAssertEqual(try parsed.validateValue(rate,fieldID:id),.number(rate)) }
        for invalid in [0,-1,240.01,Double.infinity,Double.nan,true,"8"] as [Any] { XCTAssertThrowsError(try parsed.validateValue(invalid,fieldID:id)) }
        let generic = try MediaReviewSchema.parse(schema(layout:["kind":"video_compare","primary_slot_id":"video"]))
        XCTAssertEqual(try generic.validateValue(241,fieldID:id),.number(241),"Only the declared playback field has the fps constraint")
    }
    func testRateFieldRoleChangesMaterialDefinitionAndLoopStillDoesNot() throws {
        let parsed = try MediaReviewSchema.parse(schema()),slot = try MediaReviewID("video")
        let first = try parsed.materialDefinition(usedFieldIDs:[],presentSlotIDs:[slot])
        var raw = schema()
        raw["layout"] = ["kind":"video_compare","primary_slot_id":"video","frame_rate_field_id":"fps"]
        XCTAssertEqual(first,try MediaReviewSchema.parse(raw).materialDefinition(usedFieldIDs:[],presentSlotIDs:[slot]))
        raw["layout"] = ["kind":"video_compare","primary_slot_id":"video"]
        XCTAssertNotEqual(first,try MediaReviewSchema.parse(raw).materialDefinition(usedFieldIDs:[],presentSlotIDs:[slot]))
    }
}
