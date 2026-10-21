import XCTest
import Foundation
@testable import ChecklistCore

final class MediaPastePreviewTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    // Exact bytes of the installed runner's candidates.tsv, including final CRLF.
    let tsv = "title\ttext\tgroup\tcharacter\tanimation_label\tdirection\r\nFirst candidate\tCafe\u{301} 雪\tpair\tHero\twalk\tN\r\nSecond candidate\tAlternative\tpair\tHero\twalk\tNE\r\n"
    var mapping: JSON { ["input":"tsv","assignments":["character","animation_label","direction"].map { ["field_id":$0,"source":["kind":"column","column_id":$0]] as JSON }] }
    func round(_ f: Fixture) throws -> JSON {
        let schema: JSON = ["schema_version":1,"id":"server-owned","name":"Character animation images","slots":[["id":"text","kind":"text","material":true],["id":"image","kind":"image","material":true]],"fields":[["id":"character","kind":"short_text","material":true],["id":"animation_label","kind":"short_text","material":true],["id":"direction","kind":"choice","material":true,"choices":["N","NE","E","SE","S","SW","W","NW"]]],"layout":["kind":"image_compare","primary_slot_id":"image"]]
        return try f.round(f.type(schema))
    }
    func preview(_ f: Fixture,_ round: JSON,_ input: JSON) throws -> JSON {
        var p = input;p["round_id"] = round["id"]!;p["project_id"] = f.project;p["command_id"] = uuid()
        return try f.router.handle(method:"media_intake_preview",params:p,caller:f.owner)["data"] as! JSON
    }
    func testExactInstalledTSVThroughNativeOwnerHandle() throws {
        XCTAssertEqual(ChecklistCore.hash(Data(tsv.utf8)),"ea7c79d472f4601e2a278a240345781bd2a64b1a4ead1da18e2258e6815a95d1")
        let f = try Fixture(),r = try round(f)
        let intake = try preview(f,r,["tsv":tsv,"mapping":mapping])
        let rows = try XCTUnwrap(intake["rows"] as? [JSON])
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(rows.map { $0["text"] as? String },["Cafe\u{301} 雪","Alternative"])
        XCTAssertEqual(rows.map { $0["title"] as? String },["First candidate","Second candidate"])
        XCTAssertEqual(rows.map { $0["order"] as? Int },[0,1])
        XCTAssertEqual(rows.map { $0["slot_id"] as? String },["text","text"])
        XCTAssertEqual(rows.map { $0["group_id"] as? String },["pair","pair"])
        XCTAssertEqual(rows.map { $0["disposition"] as? String },["include","include"])
        for (index,row) in rows.enumerated() {
            let metadata = try XCTUnwrap(row["metadata"] as? JSON)
            XCTAssertEqual(metadata["character"] as? String,"Hero")
            XCTAssertEqual(metadata["animation_label"] as? String,"walk")
            XCTAssertEqual(metadata["direction"] as? String,index == 0 ? "N" : "NE")
            XCTAssertEqual((row["mapping_errors"] as? [JSON])?.count,0)
        }
        let groups = try XCTUnwrap(intake["groups"] as? [JSON]);XCTAssertEqual(groups.count,1)
        XCTAssertEqual(groups.first?["group_id"] as? String,"pair")
        XCTAssertEqual(groups.first?["row_ids"] as? [String],rows.map { $0["id"] as! String })
    }
    func testMalformedTSVAndMappingsRejectWithoutWriting() throws {
        let f = try Fixture(),r = try round(f)
        let lf = tsv.replacingOccurrences(of:"\r\n",with:"\n")
        let badInputs: [JSON] = [
            ["tsv":lf.replacingOccurrences(of:"\tdirection",with:"").replacingOccurrences(of:"\twalk\tN\n",with:"\twalk\n").replacingOccurrences(of:"\twalk\tNE\n",with:"\twalk\n"),"mapping":mapping],
            ["tsv":lf.replacingOccurrences(of:"\twalk\tN\n",with:"\twalk\tN\textra\n"),"mapping":mapping],
            ["tsv":lf.replacingOccurrences(of:"\twalk\tN\n",with:"\twalk\tbad\n"),"mapping":mapping],
            ["tsv":lf.replacingOccurrences(of:"Cafe\u{301} 雪",with:""),"mapping":mapping],
            ["tsv":lf.replacingOccurrences(of:"\twalk\tN\n",with:"\twalk\n"),"mapping":mapping],
            ["tsv":"title\tgroup\nMissing text\tpair\n"],
            ["tsv":"text\ttext\none\ttwo\n"],
            ["tsv":"text\nOne\n","mapping":["input":"tsv","assignments":[["field_id":"direction","source":["kind":"unknown"]]]]],
            ["text":"One","mapping":["input":"explicit_metadata","assignments":"invalid"]],
            ["text":17], ["tsv":17], ["text":"\n \n"]
        ]
        let before = try f.allState()
        for input in badInputs {
            XCTAssertThrowsError(try preview(f,r,input)) {error in
                XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT","\(error)")
                XCTAssertFalse((error as? CoreError)?.message.isEmpty ?? true)
                XCTAssertEqual(PublicErrorText.payload(error)["code"] as? String,"INVALID_INPUT")
            }
            XCTAssertEqual(try f.allState(),before,"Invalid previews must write no plan, row, event or receipt")
        }
    }
    func testLiteralPasteLineEndingsAndExplicitMetadataValidation() throws {
        let f = try Fixture(),r = try round(f)
        for input in [tsv,tsv.replacingOccurrences(of:"\r\n",with:"\n"),String(tsv.dropLast())] {
            XCTAssertEqual((try preview(f,r,["tsv":input,"mapping":mapping])["rows"] as! [JSON]).count,2)
        }
        let lines = try preview(f,r,["text":" e\u{301}\r\n\n=literal\n","mapping":["input":"explicit_metadata","assignments":[]]])
        XCTAssertEqual((lines["rows"] as! [JSON]).map {$0["text"] as! String},[" e\u{301}\r","=literal"])
        let file = f.workspace.appendingPathComponent("explicit.txt");try Data("Exact".utf8).write(to:file)
        let before = try f.allState()
        for value in [["nested":"object"],Array(repeating:"x",count:2),String(repeating:"x",count:65_537)] as [Any] {
            XCTAssertThrowsError(try preview(f,r,["sources":[["path":file.path,"columns":["character":value]]],"mapping":["input":"selected_files","assignments":[]]])) {
                XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT","\($0)")
            }
            XCTAssertEqual(try f.allState(),before)
        }
    }

}
