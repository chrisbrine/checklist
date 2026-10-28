import XCTest
@testable import ChecklistCore

final class MediaIntakeMappingTests: XCTestCase {
    func schema() throws -> MediaReviewSchema {
        try .parse(["schema_version":1,"id":"animation","name":"Animation","fields":[
            ["id":"character","kind":"short_text","required":true], ["id":"animation_label","kind":"short_text","required":true],
            ["id":"direction","kind":"choice","required":true,"choices":["N","NE","E","SE","S","SW","W","NW"]],
            ["id":"index","kind":"number"],["id":"flag","kind":"boolean"]],"slots":[["id":"current","kind":"video"],["id":"reference","kind":"video"]],
            "layout":["kind":"video_compare","primary_slot_id":"current","reference_slot_id":"reference"]])
    }
    func id(_ s: String) throws -> MediaReviewID { try MediaReviewID(s) }
    func tokenPlan(index: Int = 0) throws -> MediaIntakePlan {
        try .parse(["input":"selected_files","candidate_grouping":"explicit_preview_only","assignments":[
            ["field_id":"character","source":["kind":"stem_token","delimiter":"__","index":index]],
            ["field_id":"animation_label","source":["kind":"stem_token","delimiter":"__","index":1]],
            ["field_id":"direction","source":["kind":"stem_token","delimiter":"__","index":2]],
            ["field_id":"index","source":["kind":"source_index"]]]],schema:schema())
    }
    func row(_ id: String, _ stem: String?, index: Int = 0, columns: [MediaIntakeColumn] = []) throws -> MediaIntakeSourceRow {
        .init(id:try self.id(id),sourceIndex:index,stem:stem,columns:columns)
    }
    func testOwnerAnimationExampleAndMissingTokens() throws {
        let results = try tokenPlan().map([row("good","hero__walk__NE__take02"),row("bad","unknown-name")],schema:schema())
        XCTAssertEqual(results[0].metadata[try id("character")],.text("hero"))
        XCTAssertEqual(results[0].metadata[try id("animation_label")],.text("walk"))
        XCTAssertEqual(results[0].metadata[try id("direction")],.choice(try id("NE")))
        XCTAssertEqual(results[0].metadata[try id("index")],.number(0));XCTAssertTrue(results[0].diagnostics.isEmpty)
        XCTAssertEqual(results[1].diagnostics.map(\.reason),[.missingValue,.missingValue])
        let empty = try tokenPlan().map([row("empty","hero____BAD")],schema:schema())[0]
        XCTAssertEqual(empty.diagnostics.map(\.reason),[.missingValue,.invalidValue])
    }
    func testLiteralTSVAndExplicitTypedColumnsReportAmbiguity() throws {
        let plan = try MediaIntakePlan.parse(["input":"tsv","assignments":[
            ["field_id":"character","source":["kind":"column","column_id":"char"]],
            ["field_id":"animation_label","source":["kind":"column","column_id":"label"]],
            ["field_id":"direction","source":["kind":"column","column_id":"dir"]],
            ["field_id":"flag","source":["kind":"column","column_id":"flag"]]]],schema:schema())
        let rows = try MediaIntakeSourceRow.tsv("char\tlabel\tdir\tflag\n=RUN()\twalk\tNE\ttrue\n",rowIDs:[id("one")])
        let result = try plan.map(rows,schema:schema())[0]
        XCTAssertTrue(result.diagnostics.isEmpty);XCTAssertEqual(result.metadata[try id("character")],.text("=RUN()"));XCTAssertEqual(result.metadata[try id("flag")],.boolean(true))
        let duplicate = try MediaIntakeSourceRow.tsv("char\tchar\tlabel\tdir\nhero\tvillain\twalk\tNE",rowIDs:[id("two")])
        XCTAssertTrue(try plan.map(duplicate,schema:schema())[0].diagnostics.contains(.init(fieldID:id("character"),reason:.ambiguousColumn)))
        XCTAssertThrowsError(try MediaIntakeSourceRow.tsv("a\nx\ty",rowIDs:[id("one")]))
        let explicit = try MediaIntakePlan.parse(["input":"explicit_metadata","assignments":[["field_id":"flag","source":["kind":"column","column_id":"flag"]]]],schema:schema())
        let typed = try explicit.map([row("e",nil,columns:[.init(id:id("flag"),value:false)])],schema:schema())[0]
        XCTAssertEqual(typed.metadata[try id("flag")],.boolean(false))
    }
    func testClosedFiniteVocabularyAndBounds() throws {
        let s = try schema()
        for kind in ["regex","expression","watcher","formula","jsonpath","remote_fetch"] {
            XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","assignments":[["field_id":"character","source":["kind":kind]]]],schema:s))
        }
        for delimiter in ["",String(repeating:"a",count:33),"\n"] { XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","assignments":[["field_id":"character","source":["kind":"stem_token","delimiter":delimiter,"index":0]]]],schema:s)) }
        for index in [-1,64,true,0.5] as [Any] { XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","assignments":[["field_id":"character","source":["kind":"stem_token","delimiter":"_","index":index]]]],schema:s)) }
        XCTAssertNoThrow(try tokenPlan(index:63))
        XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","script":"run"],schema:s))
        XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","candidate_grouping":"content_hash"],schema:s))
        let assignment: [String:Any] = ["field_id":"character","source":["kind":"stem"]]
        XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","assignments":[assignment,assignment]],schema:s))
        XCTAssertThrowsError(try MediaIntakePlan.parse(["input":"selected_files","assignments":Array(repeating:assignment,count:21)],schema:s))
        let many = try (0..<1_000).map { try row("r\($0)","hero__walk__N",index:$0) }
        XCTAssertEqual(try tokenPlan().map(many,schema:s).count,1_000)
        // CL-307: no row-count ceiling; 1,001 rows map like 1,000.
        XCTAssertEqual(try tokenPlan().map(many + [row("extra","hero__walk__N",index:1_000)],schema:s).count,1_001)
        XCTAssertThrowsError(try tokenPlan().map([row("huge",String(repeating:"x",count:4097))],schema:s))
        XCTAssertThrowsError(try MediaIntakeSourceRow.tsv(String(repeating:"x",count:4 * 1024 * 1024 + 1),rowIDs:[]))
    }
    func testByteDistinctIDsAndLiteralDelimiter() throws {
        let s = try MediaReviewSchema.parse(["schema_version":1,"id":"t","name":"T","fields":[["id":"é","kind":"short_text"],["id":"e\u{301}","kind":"short_text"]]])
        let p = try MediaIntakePlan.parse(["input":"explicit_metadata","assignments":[["field_id":"é","source":["kind":"column","column_id":"é"]],["field_id":"e\u{301}","source":["kind":"column","column_id":"e\u{301}"]]]],schema:s)
        let rows = try [row("é",nil,columns:[.init(id:id("é"),value:"A"),.init(id:id("e\u{301}"),value:"B")]),row("e\u{301}",nil)]
        let result = try p.map(rows,schema:s)
        XCTAssertEqual(result.count,2);XCTAssertEqual(result[0].metadata.count,2)
        XCTAssertEqual(result[0].metadata[try id("é")],.text("A"));XCTAssertEqual(result[0].metadata[try id("e\u{301}")],.text("B"))
        XCTAssertThrowsError(try p.map([rows[0],rows[0]],schema:s))
        let literal = try MediaIntakePlan.parse(["input":"selected_files","assignments":[["field_id":"é","source":["kind":"stem_token","delimiter":"é","index":1]]]],schema:s)
        let mapped = try literal.map([row("a","xéz"),row("b","xe\u{301}z")],schema:s)
        XCTAssertEqual(mapped[0].metadata[try id("é")],.text("z"));XCTAssertEqual(mapped[1].diagnostics.first?.reason,.missingValue)
    }
    func testFrozenRevisionPreserves200CapturedRowsAndNeverMergesSameContent() throws {
        let s = try schema(),p = try tokenPlan()
        let sources = try (0..<296).map { try row("row-\($0)","hero__walk__NE__take02",index:$0) }
        var frozen = try FrozenMediaIntake(id:id("intake"),plan:p,sources:sources,schema:s)
        for source in sources.prefix(200) { try frozen.record(.captured(id("target-\(source.sourceIndex)")),rowID:source.id) }
        try frozen.record(.failed,rowID:sources[200].id)
        let revised = try frozen.revising(plan:tokenPlan(index:1),schema:s)
        XCTAssertEqual(revised.revision,2);XCTAssertEqual(revised.remainingRowIDs.count,96);XCTAssertEqual(revised.rows.count,296)
        XCTAssertTrue(revised.rows.prefix(200).allSatisfy { $0.mappingRevision == 1 && $0.mapped.metadata[try! id("character")] == .text("hero") })
        XCTAssertTrue(revised.rows.suffix(96).allSatisfy { $0.mappingRevision == 2 && $0.mapped.metadata[try! id("character")] == .text("walk") })
        XCTAssertThrowsError(try frozen.record(.uncaptured,rowID:sources[0].id))
    }
    func testCheckedInAnimationConfigurationUsesActualHelpers() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("examples/media-intake.json"))) as! [String:Any]
        let s = try schema();XCTAssertEqual(json["type_id"] as? String,s.id.rawValue)
        let plan = try MediaIntakePlan.parse(json["intake"] as! [String:Any],schema:s)
        let mapped = try plan.map([row("selected","hero__walk__NE__take02")],schema:s)
        XCTAssertTrue(mapped[0].diagnostics.isEmpty)
        let config = try MediaListConfiguration.parse(json["list"] as! [String:Any],schema:s)
        XCTAssertEqual(config.groupBy,try [id("character"),id("animation_label")])
        let examples = try MediaHistoricalExamples.parse(json["approved_examples"] as! [String:Any],schema:s)
        XCTAssertNil(examples.request(expanded:false,projectID:try id("p"),typeID:s.id))
    }

}
