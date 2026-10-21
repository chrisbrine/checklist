import XCTest
@testable import ChecklistCore

final class MediaListConfigurationTests: XCTestCase {
    let fixture = MediaIntakeMappingTests()
    func id(_ s: String) throws -> MediaReviewID { try MediaReviewID(s) }
    func testProjectionRejectsNoncanonicalMetadataTags() throws {
        let s = try fixture.schema(), direction = try id("direction")
        let config = try MediaListConfiguration.parse(["sort":[["field_id":"direction","order":"declared_choice_order"]]],schema:s)
        let wrong = MediaListItem(id:try id("a"),title:"",order:0,metadata:[direction:.text("E")])
        let north = MediaListItem(id:try id("z"),title:"",order:0,metadata:[direction:.choice(try id("N"))])
        XCTAssertThrowsError(try config.project([wrong,north],schema:s)) { error in
            XCTAssertEqual(error as? MediaSchemaError,.invalid("list.row.metadata.direction","metadata tag does not match declared field type"))
        }
        let east = MediaListItem(id:try id("a"),title:"",order:0,metadata:[direction:.choice(try id("E"))])
        XCTAssertEqual(try config.project([east,north],schema:s).compactMap { if case .item(let r) = $0 { return r.id.rawValue };return nil },["z","a"])
        let textConfig = try MediaListConfiguration.parse(["group_by":["character"]],schema:s)
        let wrongText = MediaListItem(id:try id("c"),title:"",order:0,metadata:[try id("character"):.choice(try id("hero"))])
        XCTAssertThrowsError(try textConfig.project([wrongText],schema:s))
    }
    func testTextGroupingAndSortingShareByteExactEquality() throws {
        let s = try fixture.schema(), character = try id("character")
        let rows = try ["é","e\u{301}","f","e\u{301}"].enumerated().map {
            MediaListItem(id:try id("r\($0.offset)"),title:"",order:0,metadata:[character:.text($0.element)])
        }
        let config = try MediaListConfiguration.parse(["group_by":["character"],"sort":[["field_id":"character"]]],schema:s)
        let result = try config.project(rows.reversed(),schema:s)
        let headers = result.compactMap { entry -> Data? in if case .group(_,_,.text(let v)?,_) = entry { return Data(v.utf8) };return nil }
        XCTAssertEqual(headers,[Data("e\u{301}".utf8),Data("f".utf8),Data("é".utf8)])
        XCTAssertEqual(result.compactMap { if case .item(let r) = $0 { return r.id.rawValue };return nil },["r1","r3","r2","r0"])
        XCTAssertEqual(result.compactMap { if case .group(_,_,_,let count) = $0 { return count };return nil },[2,1,1])
    }
    func testAnimationGroupsDirectionOrderStableTiesAndMissingBuckets() throws {
        let s = try fixture.schema(),p = try fixture.tokenPlan()
        let stems = ["hero__walk__E","hero__walk__N","hero__walk__NE","hero__idle__N","villain__walk__N","hero__walk__N"]
        let mapped = try p.map(stems.enumerated().map { try fixture.row("r\($0.offset)",$0.element,index:$0.offset) },schema:s)
        var rows = mapped.map { MediaListItem(id:$0.id,title:"Title",order:0,metadata:$0.metadata) }
        rows.append(.init(id:try id("missing"),title:"Missing",order:0,metadata:[:]))
        let config = try MediaListConfiguration.parse(["visible_columns":["character","animation_label","direction"],"group_by":["character","animation_label"],"sort":[["field_id":"direction","order":"declared_choice_order"]]],schema:s)
        let result = try config.project(rows.reversed(),schema:s)
        let ordered = result.compactMap { if case .item(let row) = $0 { return row.id.rawValue };return nil }
        XCTAssertEqual(ordered,["r3","r1","r5","r2","r0","r4","missing"])
        let headers = result.compactMap { entry -> String? in if case let .group(level,_,value,count) = entry { return "\(level):\(String(describing:value)):\(count)" };return nil }
        XCTAssertEqual(headers.count,7);XCTAssertEqual(headers.last,"1:nil:1")
        XCTAssertEqual(ordered,try config.project(rows,schema:s).compactMap { if case .item(let row) = $0 { return row.id.rawValue };return nil })
    }
    func testExactByteTiesAndDisplayChangesDoNotChangeMaterialDefinition() throws {
        let s = try fixture.schema(),used = Set(try ["character","animation_label","direction"].map(id)),slots = Set([try id("current")])
        let before = try s.materialDefinition(usedFieldIDs:used,presentSlotIDs:slots)
        let config = try MediaListConfiguration.parse(["sort":[["key":"title","order":"ascending"]]],schema:s)
        let rows = try ["é","e\u{301}"].map { MediaListItem(id:try id($0),title:"same",order:0,metadata:[:]) }
        let sorted = try config.project(rows,schema:s).compactMap { if case .item(let r) = $0 { return r.id };return nil }
        XCTAssertEqual(sorted,[try id("e\u{301}"),try id("é")])
        _ = try MediaListConfiguration.parse(["group_by":["direction"],"visible_columns":["direction"]],schema:s)
        let examples = try MediaHistoricalExamples.parse(["enabled":true,"match_fields":["character","animation_label","direction"]],schema:s)
        XCTAssertNil(examples.request(expanded:false,projectID:try id("p"),typeID:s.id))
        let request = try XCTUnwrap(examples.request(expanded:true,projectID:id("p"),typeID:s.id))
        XCTAssertTrue(request.displayOnly);XCTAssertTrue(request.requiresCurrentAuthorization);XCTAssertTrue(request.historicalContextLabelRequired);XCTAssertEqual(request.pageSize,8)
        XCTAssertEqual(before,try s.materialDefinition(usedFieldIDs:used,presentSlotIDs:slots))
        let reference = try MediaMaterialReference(projectID:id("p"),typeID:s.id,targetID:id("old"),sha256:String(repeating:"a",count:64),slotID:id("reference"),kind:.video,schema:s)
        XCTAssertNotEqual(before,before + reference.basisContribution)
        let changed = try MediaMaterialReference(projectID:id("p"),typeID:s.id,targetID:id("other"),sha256:String(repeating:"a",count:64),slotID:id("reference"),kind:.video,schema:s)
        XCTAssertNotEqual(reference.basisContribution,changed.basisContribution)
        XCTAssertThrowsError(try MediaMaterialReference(projectID:id("p"),typeID:s.id,targetID:id("old"),sha256:"path",slotID:id("reference"),kind:.video,schema:s))
    }
    func testListAndExampleBoundsUnknownValuesAndNoExecutableConfiguration() throws {
        let s = try MediaReviewSchema.parse(["schema_version":1,"id":"t","name":"T","fields":(0..<20).map { ["id":"f\($0)","kind":"short_text"] }])
        XCTAssertEqual(try MediaListConfiguration.parse(["visible_columns":(0..<8).map { "f\($0)" },"group_by":["f0","f1"],"sort":[["field_id":"f0"],["field_id":"f1"],["key":"title"]]],schema:s).visibleColumns.count,8)
        for raw in [["visible_columns":(0..<9).map { "f\($0)" }],["group_by":["f0","f1","f2"]],["group_by":["unknown"]],["visible_columns":["f0","f0"]],["sort":Array(repeating:["key":"title"],count:4)],["sort":[["field_id":"f0","order":"declared_choice_order"]]],["sort":[["key":"title","order":3]]],["script":"x"]] as [[String:Any]] { XCTAssertThrowsError(try MediaListConfiguration.parse(raw,schema:s)) }
        XCTAssertNoThrow(try MediaHistoricalExamples.parse(["enabled":true,"target_ids":(0..<8).map { "t\($0)" }],schema:s))
        for raw in [["enabled":true,"match_fields":["f0","f1","f2","f3"]],["enabled":true,"target_ids":(0..<9).map { "t\($0)" }],["enabled":true,"match_fields":["f0"],"target_ids":["t"]],["enabled":true,"page_size":9],["enabled":1],["enabled":true,"query":"SELECT"]] as [[String:Any]] { XCTAssertThrowsError(try MediaHistoricalExamples.parse(raw,schema:s)) }
    }
}
