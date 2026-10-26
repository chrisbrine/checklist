import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class MediaIntakeStoredRecordTests: XCTestCase {
    func testCaptureRejectsNullImportCommandWithoutChangingCanonicalState() throws {
        let checks = MediaFrozenIntakeTests(), f = try MediaFrozenIntakeTests.Fixture()
        let round = try f.round(f.type(checks.imageSchema()))
        let source = try checks.source(f, "corrupt-command.png")
        let preview = try checks.preview(f, round, [source])
        let intake = try checks.confirm(f, preview)
        let rows = try XCTUnwrap(intake["rows"] as? [JSON])
        var row = try XCTUnwrap(rows.first)
        let rowID = try XCTUnwrap(row["id"] as? String)
        row["import_command_id"] = NSNull()
        // Corrupt only the owned fixture payload, retaining the envelope and plan relationships.
        try f.router.dbQueue.write { db in
            try db.execute(sql: "UPDATE records SET data = ? WHERE id = ? AND type = 'media_intake_row'",
                           arguments: [try jsonString(row), rowID])
        }
        let before = try f.allState()
        let command = uuid()
        checks.checks.checkError("CANONICAL_RECORD_INVALID") { try checks.capture(f, intake, command: command) }
        XCTAssertEqual(try f.allState(), before, "No row, intake, chunk, event or command result may change")
        // Existing file preparation journals its original intent before capture. This recovery fence
        // may survive rejection; it grants no domain mutation or successful command receipt.
        let pending = try f.router.dbQueue.read { db -> JSON in
            let key = try f.router.pendingStorageCommandKey(principal: f.worker.principal, command: command)
            let raw = try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [key]))
            return jsonObject(raw)
        }
        XCTAssertEqual(pending["kind"] as? String, "media_intake_capture")
        XCTAssertFalse((pending["intent_digest"] as? String ?? "").isEmpty)
        XCTAssertTrue(try f.rows("media_intake_chunk").isEmpty)
        XCTAssertTrue(try f.rows("attachment").isEmpty)
        let after = try f.record(rowID, "media_intake_row")
        XCTAssertEqual(int(after, "revision"), int(row, "revision"))
        XCTAssertEqual(after["capture_state"] as? String, row["capture_state"] as? String)
        XCTAssertNil(after["capture_error"])
        let intakeID = try XCTUnwrap(intake["id"] as? String)
        XCTAssertEqual(int(try f.record(intakeID, "media_intake"), "revision"), int(intake, "revision"))
    }

    func testCaptureStillRecordsExpectedUnavailableSourcePerRow() throws {
        let checks = MediaFrozenIntakeTests(), f = try MediaFrozenIntakeTests.Fixture()
        let round = try f.round(f.type(checks.imageSchema()))
        let source = try checks.source(f, "unavailable-source.png")
        let preview = try checks.preview(f, round, [source])
        let intake = try checks.confirm(f, preview)
        let path = try XCTUnwrap(source["path"] as? String)
        try FileManager.default.removeItem(atPath: path)
        let result = try checks.capture(f, intake)
        let rows = try XCTUnwrap(result["rows"] as? [JSON]), row = try XCTUnwrap(rows.first)
        let captureError = try XCTUnwrap(row["capture_error"] as? JSON)
        XCTAssertEqual(row["capture_state"] as? String, "failed")
        XCTAssertEqual(captureError["code"] as? String, "FILE_ACCESS_REQUIRED")
        XCTAssertEqual(result["state"] as? String, "partial")
        XCTAssertEqual(int(result, "revision"), int(intake, "revision") + 1)
        XCTAssertEqual(try f.rows("media_intake_chunk").count, 1)
        XCTAssertTrue(try f.rows("attachment").isEmpty)
    }
}
