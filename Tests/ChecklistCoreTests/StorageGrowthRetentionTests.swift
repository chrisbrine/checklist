import Darwin
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

// The fixed selector from before CL-514 introduced the canonical retirement allowlist.
private let previousCleanupPreviewSelection = """
    SELECT p.rowid FROM records p
    LEFT JOIN records t ON t.type='task' AND t.id=CASE WHEN json_valid(p.data) THEN json_extract(p.data,'$.task_id') END
    WHERE p.type='cleanup_preview' AND CASE WHEN json_valid(p.data) THEN
      (t.id IS NULL OR json_extract(p.data,'$.task_revision') <> CASE WHEN json_valid(t.data) THEN json_extract(t.data,'$.revision') END
       OR COALESCE(json_extract(p.data,'$.created_at'),'9999') < ?)
    ELSE 0 END
    """

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
        let oldTime = StoredClock.shared.string(from: Date().addingTimeInterval(-365 * 86_400))
        try router.dbQueue.write { db in
            var old = try router.record(db, deliveryID, type:"delivery")
            old["created_at"] = oldTime
            try router.save(db, old, type:"delivery")
            for (offset, variant) in [
                ["state":"delivered", "delivered_at":oldTime],
                ["recipient_authorization_generation":"earlier-generation", "owner_disconnect_ref":"historical-disconnect"],
                ["state":"quarantined", "restore_incarnation":"earlier-incarnation"],
                ["push_state":"delivery_uncertain"],
                ["message_id":UUID().uuidString]
            ].enumerated() {
                var copy = old
                copy["id"] = UUID().uuidString
                copy["revision"] = offset + 1
                for (key, value) in variant { copy[key] = value }
                try router.save(db, copy, type:"delivery")
            }
        }

        let receiptInput: JSON = ["project_id":projectID, "task_id":task["id"]!, "message_id":note["id"]!]
        let inboxInput: JSON = ["project_id":projectID]
        func receipt() throws -> JSON {
            try XCTUnwrap((call("message_delivery_list", receiptInput)["deliveries"] as? [JSON])?.first)
        }
        func storedDeliveries() throws -> [Data] {
            try router.dbQueue.read { try Data.fetchAll($0, sql:"SELECT CAST(data AS BLOB) FROM records WHERE type='delivery' ORDER BY rowid") }
        }
        let beforeReceipts = try call("message_delivery_list", receiptInput)
        let beforeInbox = try call("session_inbox", inboxInput, recipient)
        let beforeStored = try storedDeliveries()
        let receipts = try XCTUnwrap(beforeReceipts["deliveries"] as? [JSON])
        XCTAssertEqual(receipts.count, 5, "The missing-message record remains stored even though this note cannot project it.")
        XCTAssertEqual(Set(receipts.compactMap { $0["state"] as? String }), ["queued", "delivered", "fenced", "quarantined"])
        XCTAssertTrue(receipts.allSatisfy { $0["acknowledged_at"] == nil })
        let inboxRows = try XCTUnwrap(beforeInbox["deliveries"] as? [JSON])
        XCTAssertEqual(inboxRows.count, 3)
        let picked = try XCTUnwrap(inboxRows.first(where: { $0["id"] as? String == deliveryID }))
        XCTAssertEqual((picked["message"] as? JSON)?["body"] as? String, body)

        _ = try call("attachment_cleanup_preview", ["project_id":projectID, "task_id":task["id"]!])
        let counts = try router.pruneRoutineRecords(now:Date().addingTimeInterval(2 * 86_400), stepBudget:60)
        XCTAssertEqual(counts.cleanupPreviews, 1, "Run the actual retirement path with a positive control.")
        XCTAssertEqual(try storedDeliveries(), beforeStored)
        XCTAssertEqual(try jsonString(call("message_delivery_list", receiptInput)), try jsonString(beforeReceipts))
        XCTAssertEqual(try jsonString(call("session_inbox", inboxInput, recipient)), try jsonString(beforeInbox))
        XCTAssertEqual(try receipt()["id"] as? String, deliveryID)
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
        let beforeReplay = try call("attachment_add", input, command:command)
        func storedJob() throws -> String {
            try router.dbQueue.read { try jsonString(router.record($0, jobID, type:"storage_job")) }
        }
        let beforeJob = try storedJob()
        let counts = try router.pruneRoutineRecords(now:now,stepBudget:60)
        XCTAssertGreaterThan(counts.commandResults, 0, "The test must actually prune unrelated old results.")
        let replay = try call("attachment_add", input, command:command)
        XCTAssertEqual(try jsonString(replay), try jsonString(beforeReplay))
        XCTAssertEqual(try storedJob(), beforeJob)
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

final class StorageGrowthRetentionPolicyTests: XCTestCase {
    func testCL514RoutineCanonicalSelectionMatchesPreviousAcrossFamilies() throws {
        let queue = try DatabaseQueue()
        let cutoff = "2026-01-01T00:00:00.000Z"
        try queue.write { db in
            try db.execute(sql:"CREATE TABLE records(id TEXT PRIMARY KEY, type TEXT NOT NULL, data TEXT NOT NULL)")
            try db.execute(sql:"CREATE INDEX records_scope ON records(type)")
            try db.execute(sql:"INSERT INTO records VALUES ('task', 'task', '{\"revision\":1}')")
            let family = RoutineCanonicalRecordRetirement.cleanupPreview
            for recordType in [family.rawValue, "storage_job", "delivery", "unknown"] {
                for taskID in ["task", "missing"] {
                    for revision in [1, 2] {
                        for created in [nil, "2025-01-01T00:00:00.000Z", cutoff, "2026-01-02T00:00:00.000Z"] {
                            var record: JSON = ["task_id":taskID, "task_revision":revision, "kind":"attachment_import", "state":"settled"]
                            record["created_at"] = created
                            try db.execute(sql:"INSERT INTO records VALUES (?,?,?)",
                                           arguments:[UUID().uuidString, recordType, try jsonString(record)])
                        }
                    }
                }
                try db.execute(sql:"INSERT INTO records VALUES (?,?,?)", arguments:[UUID().uuidString, recordType, "{"])
            }
            let old = try Int64.fetchAll(db, sql:previousCleanupPreviewSelection, arguments:[cutoff])
            let current = try Int64.fetchAll(db, sql:family.selectionSQL, arguments:[cutoff])
            XCTAssertEqual(old.count, 13)
            XCTAssertEqual(current, old)
            for family in ["storage_job", "delivery", "unknown"] {
                XCTAssertNil(RoutineCanonicalRecordRetirement(rawValue:family))
            }
        }
    }
}

/// Qualification only. Census the owned seed before and after one normal prune turn.
final class StorageGrowthRetentionSlotTests: XCTestCase {
    func testCL514ObserveRetentionAuthorityOnSlotTwo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHECKLIST_CL514_SLOT_TWO"] == "1" else {
            throw XCTSkip("Requires a stopped slot 2 seeded from the owned live-backup copy.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let slot = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-2", isDirectory:true)
        let root = slot.appendingPathComponent("data", isDirectory:true)
        let database = root.appendingPathComponent("checklist.sqlite")
        let metadata = slot.appendingPathComponent("slot.json")
        let ownership = slot.appendingPathComponent(".checklist-workspace.json")
        guard database.path == database.resolvingSymlinksInPath().path,
              metadata.path == metadata.resolvingSymlinksInPath().path,
              ownership.path == ownership.resolvingSymlinksInPath().path,
              let session = environment["CODEX_THREAD_ID"], !session.isEmpty,
              let owner = try JSONSerialization.jsonObject(with:Data(contentsOf:ownership)) as? JSON,
              owner["purpose"] as? String == "disposable test slot 2",
              owner["session_id"] as? String == session, owner["released"] as? Bool == false,
              let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? JSON,
              marker["slot"] as? Int == 2,
              marker["mode"] as? String == "stopped",
              (marker["tickets"] as? [String])?.contains("CL-514") == true,
              let seed = marker["seed"] as? JSON, seed["kind"] as? String == "backup",
              let beforeStart = seed["before_start"] as? JSON, let tableRows = beforeStart["table_rows"] as? [String:Int],
              let seededRecords = tableRows["records"] else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED", "Use the owned stopped slot 2 created with --seed latest-backup.")
        }
        let cli = slot.appendingPathComponent("Checklist Test 2.app/Contents/MacOS/checklist")
        let lease = try StorageServiceLease(root:root)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db) }
        let queue = try DatabaseQueue(path:database.path, configuration:configuration)
        defer { try? queue.close() }
        let unaugmented = try queue.read { db in
            try Int.fetchOne(db, sql:"SELECT COUNT(*) FROM records")
        }
        guard unaugmented == seededRecords else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED", "Use the unaugmented backup seed.")
        }
        let router = try CommandRouter(root:root, serviceLease:lease, cliCommand:cli.path)
        defer { try? router.closeStore() }
        let observedAt = Date()
        let censusThreshold = observedAt.addingTimeInterval(-CommandRouter.commandResultRetention)
        let inventoryBudget: TimeInterval = 120
        func census() throws -> JSON {
            let utc = StoredClock.shared.string(from:Date())
            let startLoad = load()
            let started = ProcessInfo.processInfo.systemUptime
            let inventory = try queue.read { db in
                try CommandRouter.withPruneStepBudget(db, seconds:inventoryBudget) { () -> JSON in
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
            }
            var result = try XCTUnwrap(inventory, "The owned-seed census must finish within its SQL budget.")
            result["utc"] = utc
            result["load"] = startLoad
            result["wall_seconds"] = ProcessInfo.processInfo.systemUptime - started
            return result
        }
        let before = try census()
        let prune = try queue.read { db -> JSON in
            let cutoff = StoredClock.shared.string(from:observedAt.addingTimeInterval(-CommandRouter.cleanupPreviewRetention))
            func previewCandidates(_ selector: String) throws -> [Int64] {
                try Int64.fetchAll(db, sql:selector + " LIMIT ?", arguments:[cutoff, CommandRouter.pruneBatch])
            }
            let (before, beforeTiming) = try measurePruneStep(db) { try previewCandidates(previousCleanupPreviewSelection) }
            let (after, afterTiming) = try measurePruneStep(db) {
                try previewCandidates(RoutineCanonicalRecordRetirement.cleanupPreview.selectionSQL)
            }
            let exactMatch: Any
            if let before, let after {
                XCTAssertEqual(after.sorted(), before.sorted())
                exactMatch = after.sorted() == before.sorted()
            } else { exactMatch = NSNull() }
            let commandTiming = try observePruneSelector(db, now:observedAt.timeIntervalSince1970)
            return [
                "previous_canonical_selection":beforeTiming,
                "current_canonical_selection":afterTiming,
                "exact_canonical_selection_match":exactMatch,
                "command_prune_selector":commandTiming
            ]
        }
        let retainedFamilies = ["storage_job", "delivery"]
        let targetFamiliesHaveNoCandidates = retainedFamilies.allSatisfy { RoutineCanonicalRecordRetirement(rawValue:$0) == nil }
        let pruneUTC = StoredClock.shared.string(from:Date())
        let pruneLoad = load()
        let pruneStarted = ProcessInfo.processInfo.systemUptime
        var limit = CommandRouter.pruneBatch
        let turn = try router.runRoutinePruneTurn(batchLimit:&limit)
        let turnSeconds = ProcessInfo.processInfo.systemUptime - pruneStarted
        let after = try census()
        let canonicalBefore = try XCTUnwrap(before["all_canonical_records"] as? Int)
        let canonicalAfter = try XCTUnwrap(after["all_canonical_records"] as? Int)
        let beforeImports = try XCTUnwrap(before["imports"] as? [String:Int])
        let afterImports = try XCTUnwrap(after["imports"] as? [String:Int])
        let beforeDeliveries = try XCTUnwrap(before["deliveries"] as? [String:Int])
        let afterDeliveries = try XCTUnwrap(after["deliveries"] as? [String:Int])
        XCTAssertEqual(afterImports, beforeImports)
        XCTAssertEqual(afterDeliveries, beforeDeliveries)
        XCTAssertEqual(canonicalBefore - canonicalAfter, turn.counts["cleanup_previews"])
        let observation: JSON = [
            "census_threshold":StoredClock.shared.string(from:censusThreshold),
            "seeded_canonical_records":seededRecords,
            "census_budget_seconds":inventoryBudget,
            "before":before, "after":after,
            "target_families":retainedFamilies,
            "settled_import_reduction":(beforeImports["settled"] ?? 0) - (afterImports["settled"] ?? 0),
            "old_unacknowledged_delivery_reduction":(beforeDeliveries["older_unacknowledged"] ?? 0) - (afterDeliveries["older_unacknowledged"] ?? 0),
            "selectors":prune,
            "routine_turn":["utc":pruneUTC, "load":pruneLoad, "wall_seconds":turnSeconds, "counts":turn.counts]
        ]
        print("CL514_RETENTION_CENSUS " + (try jsonString(observation)))
        XCTAssertTrue(targetFamiliesHaveNoCandidates)
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
              let cutoff = marks.last(where: {
                  $0.count == 2 && $0[0].isFinite && now - $0[0] >= CommandRouter.commandResultRetention && $0[1] >= 0 && Int64(exactly:$0[1]) != nil
              }).flatMap({ Int64(exactly:$0[1]) }) else {
            return ["status":"no_expired_retention_mark"]
        }
        let (_, timing) = try measurePruneStep(db) {
            try Int64.fetchAll(db, sql:CommandRouter.prunableCommandResultsSQL + " LIMIT ?",
                               arguments:[cutoff, CommandRouter.prunedResult, CommandRouter.pruneBatch])
        }
        return timing
    }

    private func measurePruneStep(_ db: Database, _ select: () throws -> [Int64]) throws -> ([Int64]?, JSON) {
        let utc = StoredClock.shared.string(from:Date())
        let startLoad = load()
        let started = ProcessInfo.processInfo.systemUptime
        let result = try CommandRouter.withPruneStepBudget(db, seconds:CommandRouter.routinePruneStepBudget, select)
        return (result, [
            "status":result == nil ? "budget_stop" : "completed",
            "utc":utc, "load":startLoad,
            "candidate_count":result.map { $0.count as Any } ?? NSNull(),
            "wall_seconds":ProcessInfo.processInfo.systemUptime - started,
            "budget_seconds":CommandRouter.routinePruneStepBudget
        ])
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
