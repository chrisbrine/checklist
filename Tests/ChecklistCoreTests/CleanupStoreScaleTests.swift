import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class CleanupStoreScaleTests: XCTestCase {
    private let media = MediaRoundDeletionTests()
    private let intake = MediaFrozenIntakeTests()
    private let tickets = MediaRoundResultTests()
    private let fillerCount = 100_001

    func testDeletionAndTicketCleanupAboveFormerStoreRowLimit() throws {
        try QualificationSuite.requireEnabled()
        let fixture = try MediaFrozenIntakeTests.Fixture()
        let router = try XCTUnwrap(fixture.router)
        try media.trash(fixture)
        let round = try fixture.round(fixture.type(intake.imageSchema()))
        let sources = try [intake.source(fixture, "cleanup-first.png", 1), intake.source(fixture, "cleanup-second.png", 2)]
        _ = try intake.capture(fixture, intake.confirm(fixture, intake.preview(fixture, round, sources)))
        let canceled = try media.cancel(fixture, round)
        XCTAssertEqual(canceled["state"] as? String, "canceled")
        let roundID = try XCTUnwrap(round["id"] as? String)
        let roundInput = try media.input(fixture, round)
        let attachments = try fixture.rows("attachment")
        XCTAssertEqual(attachments.count, 2)
        let originalPaths = try attachments.map {
            try XCTUnwrap(router.ownerManagedPathProjection($0, caller: fixture.owner)["path"] as? String)
        }
        XCTAssertTrue(originalPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })

        let manual = try tickets.task(fixture)
        let manualID = try XCTUnwrap(manual["id"] as? String)
        let note = try tickets.call(fixture, "message_send", ["task_id": manualID, "body": "Synthetic purge content"])
        let noteID = try XCTUnwrap(note["id"] as? String)
        let manualCurrent = try fixture.record(manualID, "task")
        let trashed = try tickets.call(fixture, "task_archive", ["task_id": manualID, "expected_revision": manualCurrent["revision"]!, "action": "trash"])
        let purgeInput: JSON = ["task_id": manualID, "expected_revision": trashed["revision"]!]
        let done = try tickets.task(fixture)
        let doneID = try XCTUnwrap(done["id"] as? String)
        let evidence = fixture.workspace.appendingPathComponent("cleanup-evidence.txt")
        try Data("Done evidence outside the managed root".utf8).write(to: evidence)
        let evidenceAttachment = try tickets.call(fixture, "attachment_add", ["task_id": doneID, "path": evidence.path, "mode": "managed_copy"])
        let evidenceID = try XCTUnwrap(evidenceAttachment["id"] as? String)
        let evidencePath = try XCTUnwrap(evidenceAttachment["path"] as? String)
        let other = try XCTUnwrap(try tickets.task(fixture)["id"] as? String)

        let lateEvent = uuid(), lateCommand = uuid(), fillerPrincipal = "synthetic-cleanup-history"
        try seed(fixture, other: other, round: roundID, lateEvent: lateEvent, lateCommand: lateCommand, principal: fillerPrincipal)
        let loadBeforeMedia = try load()
        let (deleted, mediaWriter, _) = try measureWriter(router) { try media.worker(fixture, "media_round_delete", roundInput) }
        let loadAfterMedia = try load()
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        let counts = try XCTUnwrap(deleted["counts"] as? [String: Int])
        XCTAssertEqual(counts["media_round"], 1)
        XCTAssertEqual(counts["media_item"], 2)
        XCTAssertEqual(counts["attachment"], 2)
        let mediaPreparation = try XCTUnwrap(deleted["preparation_seconds"] as? Double)
        XCTAssertFalse(mediaWriter.isEmpty)
        print("CL516_MEDIA preparation_seconds=\(mediaPreparation) writer_transaction_seconds=\(mediaWriter) load_before=\(loadBeforeMedia) load_after=\(loadAfterMedia)")

        let mediaReceiptID = try XCTUnwrap(deleted["byte_deletion_receipt_id"] as? String)
        let mediaReceipt = try fixture.record(mediaReceiptID, "storage_job")
        let mediaObjects = try XCTUnwrap(mediaReceipt["objects"] as? [JSON])
        let evidenceObjects = try router.readForPreparation { db in
            try router.ticketObjectDeletionObjects(db, owned: [("attachment", try router.record(db, evidenceID, type: "attachment"))])
        }
        _ = try ticketCleanupBackupTemplate(router, objects: mediaObjects + evidenceObjects)
        _ = try router.runTicketObjectDeletionCohort()
        let completed = try fixture.record(mediaReceiptID, "storage_job")
        let originals = try XCTUnwrap(completed["objects"] as? [JSON]).filter { $0["representation"] as? String == "original" }
        XCTAssertEqual(originals.count, 2)
        for object in originals {
            XCTAssertEqual(object["state"] as? String, "removed")
            XCTAssertEqual(object["moved_to_trash"] as? Bool, true)
            let destination = try XCTUnwrap(object["trash_path"] as? String)
            XCTAssertTrue(destination.hasPrefix(try XCTUnwrap(router.ticketCleanupTrashRoot).path + "/"))
            XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf: URL(fileURLWithPath: destination))), object["sha256"] as? String)
        }
        XCTAssertTrue(originalPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        let report = try media.worker(fixture, "media_round_deletion_get", ["round_id": roundID])
        XCTAssertEqual(report["counts"] as? [String: Int], counts)
        XCTAssertEqual(report["cleanup_state"] as? String, "completed")
        XCTAssertEqual((report["files"] as? [JSON])?.filter { $0["representation"] as? String == "original" && $0["status"] as? String == "moved" }.count, 2)
        try router.dbQueue.read { db in
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT 1 FROM records WHERE id=?", arguments: [roundID]))
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT 1 FROM events WHERE id=?", arguments: [lateEvent]))
            let result = try XCTUnwrap(String.fetchOne(db, sql: "SELECT result FROM commands WHERE principal=? AND command_id=?", arguments: [fillerPrincipal, lateCommand]))
            XCTAssertTrue(CommandRouter.isPrunedResult(jsonObject(result)))
        }

        let preview = try tickets.call(fixture, "task_purge_preview", purgeInput)
        let digest = try XCTUnwrap(preview["digest"] as? String)
        let purged = try tickets.call(fixture, "task_purge", purgeInput.merging(["preview_digest": digest]) { _, new in new })
        XCTAssertEqual((purged["task"] as? JSON)?["purged"] as? Bool, true)
        XCTAssertThrowsError(try fixture.record(noteID, "message")) { error in
            XCTAssertEqual((error as? CoreError)?.code, "NOT_FOUND")
        }

        let time = Date()
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                var task = try router.record(db, doneID, type: "task")
                task["status_id"] = try router.status(db, fixture.project, "done")["id"]
                task["updated_at"] = ISO8601DateFormatter().string(from: time)
                try router.save(db, router.revised(task), type: "task")
                try router.saveTicketCleanupRetries(db, project: fixture.project, entries: [doneID: TicketCleanupRetry(at: time)])
                return .commit
            }
        }
        let loadBeforeCleanup = try load()
        var cleanupPreparation: TimeInterval?
        let (_, cleanupWriter, cleanupLane) = try measureWriter(router) {
            try router.ticketCleanupMaintenanceLock.withLock {
                try router.withTicketCleanupPreparation({ db in
                    let began = ProcessInfo.processInfo.systemUptime
                    defer { cleanupPreparation = ProcessInfo.processInfo.systemUptime - began }
                    return try router.prepareTicketLifecycleCleanup(db, at: time)
                }) { db, _, prepared in
                    try router.commitTicketLifecycleCleanup(db, prepared: prepared, at: time)
                }
            }
        }
        let loadAfterCleanup = try load()
        let cleanupSeconds = try XCTUnwrap(cleanupPreparation)
        XCTAssertFalse(cleanupWriter.isEmpty)
        XCTAssertFalse(cleanupLane.isEmpty)
        print("CL516_DONE preparation_seconds=\(cleanupSeconds) writer_transaction_seconds=\(cleanupWriter) writer_lane_seconds=\(cleanupLane) load_before=\(loadBeforeCleanup) load_after=\(loadAfterCleanup)")

        let doneReceiptID = try router.dbQueue.read { db in
            XCTAssertEqual(try router.ticketCleanupRetryEntries(db, project: fixture.project).count, 0, "The exact Done wake should be consumed without a limit retry")
            return try XCTUnwrap(String.fetchOne(db, sql: "SELECT id FROM records WHERE type='storage_job' AND json_extract(data,'$.cause')='done_evidence' AND json_extract(data,'$.task_id')=?", arguments: [doneID]))
        }
        _ = try router.runTicketObjectDeletionCohort()
        XCTAssertEqual(try fixture.record(doneReceiptID, "storage_job")["state"] as? String, "completed")
        XCTAssertEqual(try fixture.record(evidenceID, "attachment")["availability"] as? String, "original_cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidencePath))
        XCTAssertFalse(bool(try fixture.record(doneID, "task"), "purged"))
        let backingRows = try router.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM records") }
        XCTAssertGreaterThan(try XCTUnwrap(backingRows), 100_000)
        print("CL516_SCALE final_records=\(try XCTUnwrap(backingRows)) unrelated_jobs=\(fillerCount) unrelated_project_events=\(fillerCount) unrelated_commands=\(fillerCount) done_retries_before=1 done_retries_after=0")
    }

    private func seed(_ fixture: MediaFrozenIntakeTests.Fixture, other: String, round: String, lateEvent: String, lateCommand: String, principal: String) throws {
        let ids = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?), " +
            "ids(id) AS (SELECT printf('00000000-0000-0000-0000-%012d',i) FROM n) "
        try fixture.router.dbQueue.write { db in
            try db.execute(sql: ids + """
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT id,?,'storage_job',1,json_object('id',id,'project_id',?,'revision',1,'kind','ticket_object_delete',
                    'cause','done_evidence','task_id',?,'state','completed','objects',json('[]'),'cleanup_policy_version',2) FROM ids
                """, arguments: [fillerCount, fixture.project, fixture.project, other])
            try db.execute(sql: ids + """
                INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
                SELECT id,?,?,'fixture','task_updated','2026-01-01T00:00:00Z','{}' FROM ids
                """, arguments: [fillerCount, fixture.project, other])
            try db.execute(sql: ids + """
                INSERT INTO commands(principal,command_id,digest,result)
                SELECT ?,id,'synthetic-unchanged-intent','{"data":{"unrelated":true}}' FROM ids
                """, arguments: [fillerCount, principal])
            try db.execute(sql: """
                INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
                VALUES (?,?,?,'fixture','media_item_created','2026-01-01T00:00:00Z',json_object('round_id',?))
                """, arguments: [lateEvent, fixture.project, other, round])
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,'synthetic-late-media-intent',json_object('data',json_object('round_id',?)))", arguments: [principal, lateCommand, round])
        }
    }

    /// Time the real writer transaction through COMMIT. For lifecycle cleanup,
    /// also time the final writer phase from the data-version check through the
    /// committed preparation-state write. A preparation-only state write before
    /// the read scan does not qualify. Trace state stays on the writer queue.
    private func measureWriter<T>(_ router: CommandRouter, _ execute: () throws -> T) rethrows -> (T, [TimeInterval], [TimeInterval]) {
        var began: TimeInterval?, holds: [TimeInterval] = []
        var versionCheck: TimeInterval?, committed = false, cleanupLanes: [TimeInterval] = []
        router.dbQueue.writeWithoutTransaction { db in
            db.trace(options: [.statement, .profile]) { event in
                switch event {
                case .statement(let statement) where statement.sql == "PRAGMA data_version":
                    versionCheck = ProcessInfo.processInfo.systemUptime
                    committed = false
                case .statement(let statement) where statement.sql.hasPrefix("BEGIN IMMEDIATE"):
                    began = ProcessInfo.processInfo.systemUptime
                case .profile(let statement, _) where statement.sql.hasPrefix("COMMIT"):
                    if let start = began {
                        holds.append(ProcessInfo.processInfo.systemUptime - start)
                        committed = true
                    }
                    began = nil
                case .profile(let statement, _) where committed && statement.sql == "INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)":
                    if let start = versionCheck,
                       statement.expandedSQL.hasPrefix("INSERT OR REPLACE INTO metadata(key,value) VALUES ('ticket-cleanup-preparation:") {
                        cleanupLanes.append(ProcessInfo.processInfo.systemUptime - start)
                        versionCheck = nil
                    }
                default:
                    break
                }
            }
        }
        defer { router.dbQueue.writeWithoutTransaction { $0.trace(nil) } }
        let value = try execute()
        return router.dbQueue.writeWithoutTransaction { _ in (value, holds, cleanupLanes) }
    }

    private func load() throws -> String {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        child.arguments = ["-n", "vm.loadavg"]
        child.standardOutput = output
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
