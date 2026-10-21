import XCTest
@testable import ChecklistCore

extension PlaytestBundleTests {
    /// The owner GUI has distinct read paths from a worker's compact context.
    /// Exercise the composed evidence through those exact routes and wire JSON.
    func testOwnerEvidenceReadsReturnSerializableSelectedRecordsAndPreviewHolds() throws {
        let project = try combinedProject(), fixture = try combinedSubmission(project)
        let tid = (fixture.submission["task"] as! JSON)["id"]!
        let selected = try call("task_context", ["task_id":tid, "detail_level":"ui"])
        let records = try call("task_context", ["task_id":tid, "detail_level":"ui_records", "selected_context_cursor":selected["context_cursor"]!])
        let collections = try XCTUnwrap(records["collections"] as? JSON)
        XCTAssertEqual(records["complete"] as? Bool, true)
        XCTAssertNotNil(collections["evidence_measure_history"] as? JSON)
        let manifest = try XCTUnwrap((collections["manifests"] as? [JSON])?.first)
        XCTAssertNotNil((manifest["evidence"] as? JSON)?["playtest_bundle"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(selected))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(records))
        let preview = try call("attachment_read", ["project_id":project["id"]!, "attachment_id":fixture.screenshot["id"]!, "representation":"original"])
        XCTAssertEqual(preview["sha256"] as? String, fixture.screenshot["sha256"] as? String)
        XCTAssertNotNil(preview["url"] as? String)
        let hold = try XCTUnwrap(preview["read_hold_id"] as? String)
        XCTAssertEqual(try call("attachment_read_release", ["project_id":project["id"]!, "read_hold_id":hold])["state"] as? String, "released")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(preview))
    }
}
