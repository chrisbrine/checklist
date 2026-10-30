import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

/// Exercises the shipped starter and the worker intake mapping values without a native service.
@MainActor final class MediaAnimationTakeStarterTests: XCTestCase {
    func starter() throws -> MediaReviewSchema {
        try MediaReviewSchema.parse(MediaTypeSettings.schema(title:"Animation takes",starter:"animation_video"))
    }
    func id(_ value:String) throws -> MediaReviewID { try MediaReviewID(value) }
    func testStarterDeclaresIdentityOptionalAnnotationsAndPerItemTiming() throws {
        let schema = try starter()
        XCTAssertEqual(schema.fields.map(\.id.rawValue),["character","animation_label","direction","take","hint","frame_rate"])
        XCTAssertEqual(schema.fields.filter(\.required).map(\.id.rawValue),["character","animation_label","direction"])
        XCTAssertEqual(schema.fields.first {$0.id.rawValue == "animation_label"}?.label,"Action")
        XCTAssertEqual(schema.fields.first {$0.id.rawValue == "direction"}?.choices.map(\.rawValue),["N","NE","E","SE","S","SW","W","NW"])
        XCTAssertEqual(schema.fields.first {$0.id.rawValue == "hint"}?.kind,.longText)
        XCTAssertTrue(schema.layout.loop);XCTAssertNil(schema.layout.frameRate)
        XCTAssertEqual(schema.layout.frameRateFieldID?.rawValue,"frame_rate")
        let list = MediaReviewModel.defaultList(MediaTypeSettings.schema(title:"Animation takes",starter:"animation_video"))
        XCTAssertEqual(list["group_by"] as? [String],["character","animation_label"])
    }
    func testCheckedInAnimationTakeTypeMatchesNativeStarter() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("examples/media-animation-takes.json"))
        let example = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? MediaValues)
        let native = MediaTypeSettings.schema(title:"Animation takes",starter:"animation_video")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:example,options:.sortedKeys),try JSONSerialization.data(withJSONObject:native,options:.sortedKeys))
        XCTAssertNoThrow(try MediaReviewSchema.parse(example))
    }
    func testWorkerColumnsMapEightDirectionsAndOptionalTakeHintRate() throws {
        let schema = try starter(),fields = ["character","animation_label","direction","take","hint","frame_rate"]
        let plan = try MediaIntakePlan.parse(["input":"explicit_metadata","assignments":fields.map { ["field_id":$0,"source":["kind":"column","column_id":$0]] }],schema:schema)
        let directions = ["N","NE","E","SE","S","SW","W","NW"]
        let rows = try directions.enumerated().map { index,direction in
            MediaIntakeSourceRow(id:try id("row-\(index)"),sourceIndex:index,stem:nil,columns:try zip(fields,["hero","walk",direction,"take02","Game timing",String([4,8,12][index % 3])]).map { .init(id:try id($0.0),value:$0.1) })
        }
        let mapped = try plan.map(rows,schema:schema)
        XCTAssertEqual(mapped.count,8);XCTAssertTrue(mapped.allSatisfy {$0.diagnostics.isEmpty})
        for (index,row) in mapped.enumerated() {
            XCTAssertEqual(row.metadata[try id("character")],.text("hero"))
            XCTAssertEqual(row.metadata[try id("animation_label")],.text("walk"))
            XCTAssertEqual(row.metadata[try id("direction")],.choice(try id(directions[index])))
            XCTAssertEqual(row.metadata[try id("take")],.text("take02"))
            XCTAssertEqual(row.metadata[try id("hint")],.text("Game timing"))
            XCTAssertEqual(row.metadata[try id("frame_rate")],.number(Double([4,8,12][index % 3])))
        }
    }
    func testWorkerFilenameMappingNeedsOnlyRequiredIdentityAndRejectsBadDirection() throws {
        let schema = try starter(),fields = ["character","animation_label","direction"]
        let plan = try MediaIntakePlan.parse(["input":"selected_files","assignments":fields.enumerated().map { ["field_id":$0.element,"source":["kind":"stem_token","delimiter":"__","index":$0.offset]] }],schema:schema)
        let sources = try ["hero__idle__N","hero__idle__sideways"].enumerated().map {
            MediaIntakeSourceRow(id:try id("file-\($0.offset)"),sourceIndex:$0.offset,stem:$0.element,columns:[])
        }
        let mapped = try plan.map(sources,schema:schema)
        XCTAssertTrue(mapped[0].diagnostics.isEmpty);XCTAssertNil(mapped[0].metadata[try id("frame_rate")])
        XCTAssertEqual(mapped[1].diagnostics.map(\.reason),[.invalidValue])
    }
}
