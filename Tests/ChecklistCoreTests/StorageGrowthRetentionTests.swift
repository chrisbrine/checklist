import Darwin
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    func testCL514OldQueuedDeliveryStillSupportsPickupReceiptAndAcknowledgment() throws {
        let project = try project(), task = try ready(project)
        let recipient = try native(project, "old-receipt-recipient", domain: "codex:514:1:0")
        _ = try claim(project, task, caller: recipient)
        let projectID = try XCTUnwrap(project["id"] as? String)
        let body = "An old unacknowledged note still needs pickup."
        let note = try call("message_send", ["project_id":projectID, "task_id":task["id"]!, "body":body])
        let delivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        let deliveryID = try XCTUnwrap(delivery["id"] as? String)
        try router.dbQueue.write { db in
            var old = try router.record(db, deliveryID, type:"delivery")
            old["created_at"] = StoredClock.shared.string(from: Date().addingTimeInterval(-365 * 86_400))
            try router.save(db, old, type:"delivery")
        }

        let receiptInput: JSON = ["project_id":projectID, "task_id":task["id"]!, "message_id":note["id"]!]
        func receipt() throws -> JSON {
            try XCTUnwrap((call("message_delivery_list", receiptInput)["deliveries"] as? [JSON])?.first)
        }
        XCTAssertEqual(try receipt()["id"] as? String, deliveryID)
        XCTAssertEqual(try receipt()["state"] as? String, "queued")
        let inbox = try call("session_inbox", ["project_id":projectID], recipient)
        let picked = try XCTUnwrap((inbox["deliveries"] as? [JSON])?.first(where: { $0["id"] as? String == deliveryID }))
        XCTAssertEqual((picked["message"] as? JSON)?["body"] as? String, body)
        XCTAssertEqual(try receipt()["state"] as? String, "queued")
        XCTAssertNil(try receipt()["acknowledged_at"])

        _ = try call("message_ack", ["project_id":projectID, "delivery_id":deliveryID, "stage":"acknowledged"], recipient)
        XCTAssertEqual(try receipt()["id"] as? String, deliveryID)
        XCTAssertEqual(try receipt()["state"] as? String, "acknowledged")
        XCTAssertNotNil(try receipt()["acknowledged_at"])
    }

    func testCL514OldSettledImportProtectsReplayAndLaterRepair() throws {
        let project = try project(), task = try ready(project), command = UUID().uuidString
        let source = directory.appendingPathComponent("original.txt")
        let originalBytes = Data("The managed copy has the original bytes.".utf8)
        try originalBytes.write(to:source)
        let input: JSON = ["project_id":project["id"]!, "task_id":task["id"]!, "path":source.path]
        let attachment = try call("attachment_add", input, command:command)
        let attachmentID = try XCTUnwrap(attachment["id"] as? String)
        let jobID = try XCTUnwrap(attachment["storage_job_id"] as? String)
        func reconcile() throws {
            try ArchiveStorageGate.withExclusive(root:router.root) { _ in
                try router.dbQueue.writeWithoutTransaction { _ = try router.reconcileManagedAttachmentImports($0) }
            }
        }
        try reconcile()
        let now = Date()
        try router.dbQueue.write { db in
            var job = try router.record(db, jobID, type:"storage_job")
            XCTAssertEqual(job["state"] as? String, "settled")
            job["created_at"] = StoredClock.shared.string(from: now.addingTimeInterval(-365 * 86_400))
            try router.save(db, job, type:"storage_job")
            let top = try XCTUnwrap(Int64.fetchOne(db, sql:"SELECT MAX(rowid) FROM commands"))
            let marks = [[now.timeIntervalSince1970 - 31 * 86_400, Double(top)]]
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks',?)",
                           arguments:[try jsonString(marks)])
        }
        let counts = try router.pruneRoutineRecords(now:now,stepBudget:60)
        XCTAssertGreaterThan(counts.commandResults, 0, "The test must actually prune unrelated old results.")
        let replay = try call("attachment_add", input, command:command)
        XCTAssertEqual(replay["id"] as? String, attachmentID)
        XCTAssertEqual(replay["storage_job_id"] as? String, jobID)

        let original = try router.managedURL(try XCTUnwrap(attachment["path"] as? String), family:"objects")
        let interrupted = directory.appendingPathComponent("interrupted-original.txt")
        try FileManager.default.moveItem(at:original, to:interrupted)
        let read: JSON = ["project_id":project["id"]!, "attachment_id":attachmentID, "representation":"original"]
        XCTAssertThrowsError(try call("attachment_read", read))
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, jobID, type:"storage_job")["state"] as? String }, "repair_required")

        try FileManager.default.moveItem(at:interrupted, to:original)
        try reconcile()
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, jobID, type:"storage_job")["state"] as? String }, "settled")
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, attachmentID, type:"attachment")["availability"] as? String }, "available")
        XCTAssertEqual(try Data(contentsOf:original), originalBytes)
    }
}

/// Qualification only. Read the stopped, explicitly seeded slot 2 through SQLite's
/// read-only connection. Never start its router, rewrite the cutoff or prune the copy.
final class StorageGrowthRetentionSlotTests: XCTestCase {
    func testCL514ObserveRetentionAuthorityOnSlotTwo() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_CL514_SLOT_TWO"] == "1" else {
            throw XCTSkip("Requires a stopped slot 2 seeded from the owned live-backup copy.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let slot = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-2", isDirectory:true)
        let database = slot.appendingPathComponent("data/checklist.sqlite")
        let metadata = slot.appendingPathComponent("slot.json")
        guard database.path == database.resolvingSymlinksInPath().path,
              metadata.path == metadata.resolvingSymlinksInPath().path,
              let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? JSON,
              marker["slot"] as? Int == 2,
              (marker["seed"] as? JSON)?["kind"] as? String == "backup" else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED", "Use the stopped slot 2 created with --seed latest-backup.")
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db) }
        let queue = try DatabaseQueue(path:database.path, configuration:configuration)
        defer { try? queue.close() }
        let observedAt = Date()
        let censusThreshold = observedAt.addingTimeInterval(-CommandRouter.commandResultRetention)
        let beforeLoad = load()
        let started = ProcessInfo.processInfo.systemUptime
        let inventory = try queue.read { db -> JSON in
            let families = try Int.fetchOne(db, sql:"SELECT COUNT(*) FROM records") ?? 0
            let imports = try Row.fetchOne(db, sql:Self.importInventorySQL)
            let deliveries = try Row.fetchOne(db, sql:Self.deliveryInventorySQL, arguments:[StoredClock.shared.string(from:censusThreshold)])
            return [
                "all_canonical_records":families,
                "imports":Self.counts(imports, columns:[
                    "settled", "linked_attachment", "parent_command", "exact_intent_digest",
                    "exact_attachment_receipt", "exact_job_receipt", "abandoned", "canceled"
                ]),
                "deliveries":Self.counts(deliveries, columns:[
                    "all_deliveries", "queued", "acknowledged", "older_unacknowledged",
                    "older_with_message", "older_without_message", "old_with_lineage", "invalid_or_unknown_age"
                ])
            ]
        }
        let inventorySeconds = ProcessInfo.processInfo.systemUptime - started
        let selectLoad = load()
        let pruneObservation = try queue.read { db in
            try self.observePruneSelector(db, now:observedAt.timeIntervalSince1970)
        }
        let observation: JSON = [
            "observed_at":StoredClock.shared.string(from:observedAt),
            "census_threshold":StoredClock.shared.string(from:censusThreshold),
            "load_before_inventory":beforeLoad, "load_before_select":selectLoad, "load_after":load(),
            "inventory_wall_seconds":inventorySeconds, "inventory":inventory,
            "base_command_prune_selector":pruneObservation
        ]
        print("CL514_RETENTION_CENSUS " + (try jsonString(observation)))
        XCTAssertGreaterThan(inventory["all_canonical_records"] as? Int ?? 0, 0)
    }

    private func load() -> [Double] {
        var values = [Double](repeating:0, count:3)
        _ = getloadavg(&values, 3)
        return values
    }

    private static func counts(_ row: Row?, columns: [String]) -> [String:Int] {
        Dictionary(uniqueKeysWithValues:columns.map { ($0, (row?[$0] as Int?) ?? 0) })
    }

    private func observePruneSelector(_ db: Database, now: TimeInterval) throws -> JSON {
        guard let raw = try String.fetchOne(db, sql:"SELECT value FROM metadata WHERE key='command_retention_marks'"),
              let marks = try? JSONDecoder().decode([[Double]].self, from:Data(raw.utf8)),
              let mark = marks.last(where: { $0.count == 2 && $0[0].isFinite && now - $0[0] >= CommandRouter.commandResultRetention && $0[1] >= 0 }),
              let cutoff = Int64(exactly:mark[1]) else { return ["status":"no_expired_retention_mark"] }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try CommandRouter.withPruneStepBudget(db, seconds:CommandRouter.routinePruneStepBudget) {
            try Int64.fetchAll(db, sql:CommandRouter.prunableCommandResultsSQL + " LIMIT ?",
                               arguments:[cutoff, CommandRouter.prunedResult, CommandRouter.pruneBatch])
        }
        return [
            "status":result == nil ? "budget_stop" : "completed",
            "candidate_count":result.map { $0.count as Any } ?? NSNull(),
            "wall_seconds":ProcessInfo.processInfo.systemUptime - started,
            "budget_seconds":CommandRouter.routinePruneStepBudget
        ]
    }

    private static let importInventorySQL = """
        WITH jobs AS (
            SELECT id,project_id,CASE WHEN json_valid(data) THEN data END AS payload
            FROM records WHERE type='storage_job'
        ), settled AS (
            SELECT id,project_id,json_extract(payload,'$.attachment_id') AS attachment,
                   json_extract(payload,'$.parent_principal') AS principal,
                   json_extract(payload,'$.parent_command_id') AS command,
                   json_extract(payload,'$.intent_digest') AS digest,
                   json_extract(payload,'$.settled_reason') AS reason
            FROM jobs WHERE json_extract(payload,'$.kind')='attachment_import' AND json_extract(payload,'$.state')='settled'
        ), links AS (
            SELECT j.*, a.id AS attachment_row,
                   CASE WHEN json_valid(a.data) THEN json_extract(a.data,'$.storage_job_id') END AS attachment_job,
                   c.command_id AS command_row,c.digest AS command_digest,
                   CASE WHEN json_valid(c.result) THEN json_extract(c.result,'$.data.id') END AS result_attachment,
                   CASE WHEN json_valid(c.result) THEN json_extract(c.result,'$.data.storage_job_id') END AS result_job
            FROM settled j
            LEFT JOIN records a ON a.id=j.attachment AND a.type='attachment' AND a.project_id=j.project_id
            LEFT JOIN commands c ON c.principal=j.principal AND c.command_id=j.command
        )
        SELECT COUNT(*) AS settled,
               COUNT(CASE WHEN attachment_row IS NOT NULL AND CAST(attachment_job AS BLOB)=CAST(id AS BLOB) THEN 1 END) AS linked_attachment,
               COUNT(command_row) AS parent_command,
               COUNT(CASE WHEN CAST(command_digest AS BLOB)=CAST(digest AS BLOB) THEN 1 END) AS exact_intent_digest,
               COUNT(CASE WHEN CAST(command_digest AS BLOB)=CAST(digest AS BLOB) AND CAST(result_attachment AS BLOB)=CAST(attachment AS BLOB) THEN 1 END) AS exact_attachment_receipt,
               COUNT(CASE WHEN CAST(command_digest AS BLOB)=CAST(digest AS BLOB) AND CAST(result_attachment AS BLOB)=CAST(attachment AS BLOB) AND CAST(result_job AS BLOB)=CAST(id AS BLOB) THEN 1 END) AS exact_job_receipt,
               COUNT(CASE WHEN reason='abandoned_without_receipt' THEN 1 END) AS abandoned,
               COUNT(CASE WHEN reason='canceled_media_staging' THEN 1 END) AS canceled
        FROM links
        """

    private static let deliveryInventorySQL = """
        WITH deliveries AS (
            SELECT project_id, CASE WHEN json_valid(data) THEN data END AS payload
            FROM records WHERE type='delivery'
        ), timings AS (
            SELECT project_id, json_extract(payload,'$.message_id') AS message,
                   json_extract(payload,'$.state') AS state,
                   julianday(json_extract(payload,'$.created_at')) AS created,
                   julianday(?) AS threshold,
                   json_extract(payload,'$.resumed_from_delivery_id') IS NOT NULL
                   OR json_extract(payload,'$.resumed_native_closure_ref') IS NOT NULL
                   OR json_extract(payload,'$.relay_skipped_for_delivery_id') IS NOT NULL AS lineage
            FROM deliveries
        ), history AS (
            SELECT t.*, m.id AS message_row
            FROM timings t LEFT JOIN records m ON m.id=t.message AND m.type='message' AND m.project_id=t.project_id
        )
        SELECT COUNT(*) AS all_deliveries,
               COUNT(CASE WHEN state='queued' THEN 1 END) AS queued,
               COUNT(CASE WHEN state IN ('acknowledged','addressed') THEN 1 END) AS acknowledged,
               COUNT(CASE WHEN created<threshold AND state NOT IN ('acknowledged','addressed') THEN 1 END) AS older_unacknowledged,
               COUNT(CASE WHEN created<threshold AND state NOT IN ('acknowledged','addressed') AND message_row IS NOT NULL THEN 1 END) AS older_with_message,
               COUNT(CASE WHEN created<threshold AND state NOT IN ('acknowledged','addressed') AND message_row IS NULL THEN 1 END) AS older_without_message,
               COUNT(CASE WHEN created<threshold AND state NOT IN ('acknowledged','addressed') AND lineage THEN 1 END) AS old_with_lineage,
               COUNT(CASE WHEN created IS NULL OR state IS NULL THEN 1 END) AS invalid_or_unknown_age
        FROM history
        """
}
