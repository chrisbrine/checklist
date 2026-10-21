import XCTest
@testable import ChecklistApp

final class TicketPurgePreviewTests: XCTestCase {
    let ticket = Record(values:["id":"ticket","project_id":"project","revision":3,"title":"Example"])
    var reply: [String:Any] {["can_purge":true,"digest":"preview-token","impact":["task_id":"ticket","project_id":"project","expected_revision":3,"removed_record_count":5,"shared_record_count":2,"history_events":8,"managed_attachment_count":1,"managed_attachment_logical_bytes":120,"known_backup_count":2,"known_backup_observed_times":["2026-10-20T10:00:00Z"]]]}
    func testPreviewBindsExactTicketRevisionAndDigestForOwnerConfirmation() throws {
        let value = try TicketPurgePreview(reply:reply,ticket:ticket,incarnation:"store")
        XCTAssertEqual(value.parameters["task_id"] as? String,"ticket")
        XCTAssertEqual(value.parameters["expected_revision"] as? Int,3)
        XCTAssertEqual(value.parameters["preview_digest"] as? String,"preview-token")
        XCTAssertEqual(value.removed,5);XCTAssertEqual(value.shared,2)
        XCTAssertEqual(value.backups,2);XCTAssertTrue(value.creationTimes.isEmpty)
        var bad = reply;var impact = bad["impact"] as! [String:Any];impact["expected_revision"] = 4;bad["impact"] = impact
        XCTAssertThrowsError(try TicketPurgePreview(reply:bad,ticket:ticket,incarnation:"store"))
        impact["expected_revision"] = 3;impact["task_id"] = "another-ticket";bad["impact"] = impact
        XCTAssertThrowsError(try TicketPurgePreview(reply:bad,ticket:ticket,incarnation:"store"))
    }
    func testOnlyTrashOffersPermanentDeletionAndRequiresDestructiveConfirmation() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/ChecklistApp/Views")
        let files = try FileManager.default.contentsOfDirectory(at:views,includingPropertiesForKeys:nil).filter {$0.pathExtension == "swift"}
        let senders = try files.filter {try String(contentsOf:$0,encoding:.utf8).contains("store.run(\"task_purge\",")}
        XCTAssertEqual(senders.map(\.lastPathComponent),["TrashTicketsView.swift"])
        let source = try String(contentsOf:views.appendingPathComponent("TrashTicketsView.swift"),encoding:.utf8)
        XCTAssertTrue(source.contains(".confirmationDialog(\"Delete this ticket permanently?\""))
        XCTAssertTrue(source.contains("Button(\"Delete permanently\",role:.destructive)"))
    }
}
