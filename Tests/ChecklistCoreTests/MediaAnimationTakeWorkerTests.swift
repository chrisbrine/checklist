import XCTest
@testable import ChecklistCore

/// Public worker intake over the owned template fixture and synthetic MP4 headers.
/// This proves mapping/capture records, not native decoding or visible frame cadence.
final class MediaAnimationTakeWorkerTests: XCTestCase {
    func testWorkerCapturesEightDirectionsWithMappedTakeHintAndRate() throws {
        let helper = MediaWorkerChannelTests(),f = try MediaFrozenIntakeTests.Fixture()
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("examples/media-animation-takes.json"))) as? JSON)
        let fields=try XCTUnwrap(schema["fields"] as? [JSON])
        let type = try f.type(schema),round = try helper.round(f,type)
        let directions = ["N","NE","E","SE","S","SW","W","NW"]
        let sources: [JSON] = try directions.enumerated().map { index,direction in
            let path = f.workspace.appendingPathComponent("hero__walk__\(direction).mp4")
            try MediaPlaybackOriginalTests.movie(seconds:1,tracks:[MediaPlaybackOriginalTests.track(width:64,height:48,frames:12)]).write(to:path)
            return ["path":path.path,"columns":["character":"hero","animation_label":"walk","direction":direction,
                "take":"take02","hint":"Game timing","frame_rate":[4,8,12][index % 3]]]
        }
        let mapping: JSON = ["input":"selected_files","assignments":fields.map { ["field_id":$0["id"]!,"source":["kind":"column","column_id":$0["id"]!]] }]
        var intake = try helper.worker(f,"media_intake_preview",["round_id":round["id"]!,"sources":sources,"mapping":mapping])
        let rows = try XCTUnwrap(intake["rows"] as? [JSON])
        XCTAssertEqual(rows.count,8)
        XCTAssertTrue(rows.allSatisfy { ($0["mapping_errors"] as? [JSON] ?? []).isEmpty })
        intake = try helper.worker(f,"media_intake_revise",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,
            "resolutions":rows.map { ["row_id":$0["id"]!,"disposition":"include","slot_id":"take"] }])
        intake = try helper.capture(f,helper.confirm(f,intake))
        XCTAssertEqual(strings(intake,"committed_row_ids").count,8)
        let view = try helper.get(f,round),items = try XCTUnwrap(view["items"] as? [JSON])
        XCTAssertEqual(items.count,8)
        XCTAssertEqual(Set(items.compactMap { ($0["metadata"] as? JSON)?["direction"] as? String }),Set(directions))
        for item in items {
            let metadata = try XCTUnwrap(item["metadata"] as? JSON)
            XCTAssertEqual(metadata["character"] as? String,"hero")
            XCTAssertEqual(metadata["animation_label"] as? String,"walk")
            XCTAssertEqual(metadata["take"] as? String,"take02")
            XCTAssertEqual(metadata["hint"] as? String,"Game timing")
            XCTAssertTrue([4,8,12].contains((metadata["frame_rate"] as? NSNumber)?.intValue ?? -1))
        }
    }
}
