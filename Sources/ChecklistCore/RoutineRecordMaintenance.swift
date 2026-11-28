import Foundation
import GRDB

extension CommandRouter {
    /// The only state carried across service wakes is the retry batch size.
    /// Age proof lives in metadata and every apply is independently atomic.
    public struct RoutinePruneTurn: Sendable {
        public let nextDelay: TimeInterval
        public let counts: [String: Int]
    }

    public func runRoutinePruneTurn(batchLimit: inout Int) throws -> RoutinePruneTurn {
        batchLimit = max(1, min(Self.pruneBatch, batchLimit))
        let counts = try pruneRoutineRecords(batchLimit: batchLimit)
        if counts.budgetStops > 0 && counts.commandResults == 0 {
            batchLimit = max(1, batchLimit / 2)
        } else if counts.commandResults == batchLimit {
            batchLimit = min(Self.pruneBatch, batchLimit * 2)
        }
        let delay: TimeInterval
        if counts.budgetStops > 0 { delay = 5 }
        else if counts.commandResults > 0 || counts.cursors == Self.cursorPruneBatch ||
                  counts.cleanupPreviews == Self.pruneBatch || counts.attachmentReadResults == Self.attachmentReadPruneBatch { delay = 2 }
        else { delay = Self.routinePruneInterval }
        return RoutinePruneTurn(nextDelay: delay, counts: [
            "cursors": counts.cursors, "command_results": counts.commandResults,
            "cleanup_previews": counts.cleanupPreviews, "attachment_read_results": counts.attachmentReadResults,
            "budget_stops": counts.budgetStops
        ])
    }

    @discardableResult
    func pruneRoutineRecords(now: Date = Date(), stepBudget: TimeInterval = CommandRouter.routinePruneStepBudget,
                             batchLimit: Int = CommandRouter.pruneBatch, beforeCommandApply: (() throws -> Void)? = nil) throws -> PruneCounts {
        let lease = try storageAdmission.acquire()
        defer { lease.finish() }
        let reader = try openMaintenanceReader()
        defer { try? reader.close() }
        var counts = PruneCounts()
        func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
        func apply(_ label: String, _ body: (Database) throws -> Int) throws -> Int {
            let changed = try withMaintenanceWriter(label: label, deadline: .init(seconds: stepBudget)) { db, deadline in
                try deadline.transaction(db) { try body(db) }
            }
            if changed == nil { counts.budgetStops += 1 }
            return changed ?? 0
        }

        let time = now.timeIntervalSince1970
        // The mark commits separately and cannot be lost on an interrupted apply.
        let refreshed = try withMaintenanceWriter(label: "routine_prune_retention_mark") { db, deadline in
            try deadline.transaction(db) { try commandRetentionCutoff(db, now: time) }
        }
        if refreshed == nil { counts.budgetStops += 1 }
        let cutoff = try refreshed ?? reader.read { try commandRetentionCutoff($0, now: time, refresh: false) }

        counts.cursors = try apply("routine_prune_cursors") { db in
            try db.execute(sql: "DELETE FROM cursors WHERE rowid IN (SELECT rowid FROM cursors WHERE created_at < ? LIMIT ?)",
                           arguments: [time - Self.cursorRowRetention, Self.cursorPruneBatch])
            return db.changesCount
        }
        if let cutoff {
            if let fence = try routinePruneFence(cutoff: cutoff) {
                let rows = try reader.read { db in
                    try Int64.fetchAll(db, sql: Self.prunableCommandResultsSQL + " LIMIT ?",
                                       arguments: [cutoff, Self.prunedResult, batchLimit])
                }
                if !rows.isEmpty {
                    try beforeCommandApply?()
                    counts.commandResults = try apply("routine_prune_command_results") { db in
                        guard try Self.routinePruneToken(db) == fence else { throw MaintenanceStepDeferred() }
                        try db.execute(sql: "UPDATE commands SET result=? WHERE rowid IN (\(placeholders(rows.count)))",
                                       arguments: StatementArguments([Self.prunedResult]) + StatementArguments(rows))
                        return db.changesCount
                    }
                }
            } else { counts.budgetStops += 1 }
        }

        let previewCutoff = StoredClock.shared.string(from: now.addingTimeInterval(-Self.cleanupPreviewRetention))
        let previewSelection = RoutineCanonicalRecordRetirement.cleanupPreview.selectionSQL
        let previews = try reader.read { db in
            try Int64.fetchAll(db, sql: previewSelection + " LIMIT ?", arguments: [previewCutoff, Self.pruneBatch])
        }
        if !previews.isEmpty {
            counts.cleanupPreviews = try apply("routine_prune_cleanup_previews") { db in
                // Re-evaluate eligibility for only the selected row IDs. A preview
                // refreshed during the reader scan keeps its current lease.
                let sql = previewSelection + " AND p.rowid IN (\(placeholders(previews.count)))"
                try db.execute(sql: "DELETE FROM records WHERE rowid IN (\(sql))",
                               arguments: StatementArguments([previewCutoff]) + StatementArguments(previews))
                return db.changesCount
            }
        }
        let receipts = try reader.read { try legacyAttachmentReadPruneRows($0) }
        if !receipts.isEmpty {
            counts.attachmentReadResults = try apply("routine_prune_attachment_read_results") {
                try pruneAttachmentReadResults($0, rows: receipts)
            }
        }
        return counts
    }

    private struct PruneToken: Equatable {
        let protection: Int64
        let external: Int64
    }

    private static func routinePruneToken(_ db: Database) throws -> PruneToken {
        guard let protection = try Int64.fetchOne(db, sql: "SELECT generation FROM temp.checklist_prune_protection"),
              let external = try Int64.fetchOne(db, sql: "PRAGMA main.data_version") else {
            throw MaintenanceStepDeferred()
        }
        return PruneToken(protection: protection, external: external)
    }

    private func routinePruneFence(cutoff: Int64) throws -> PruneToken? {
        try withMaintenanceWriter(label: "routine_prune_protection_fence") { db, deadline in
            try deadline.transaction(db) {
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_temp_master WHERE name='checklist_prune_protection')") != true {
                    try Self.installRoutinePruneFence(db)
                }
                try db.execute(sql: "UPDATE temp.checklist_prune_protection SET cutoff=? WHERE cutoff < ?",
                               arguments: [cutoff, cutoff])
                return try Self.routinePruneToken(db)
            }
        }
    }

    private static func installRoutinePruneFence(_ db: Database) throws {
        // Invalidate plans when a new protection can affect aged results.
        // Removing a protection can leave a result for the next scan. New jobs
        // for ordinary recent commands do not force a scan of all storage jobs.
        // The journal rolls back with the writer transaction. Other SQLite
        // connections invalidate through main.data_version.
        let oldParent = "CASE WHEN old.type='storage_job' THEN " + pruneJobParentSQL("old") + " ELSE '' END"
        let newParent = "CASE WHEN new.type='storage_job' THEN " + pruneJobParentSQL("new") + " ELSE '' END"
        let cutoff = "(SELECT cutoff FROM checklist_prune_protection)"
        let canProtect = """
            CASE WHEN new.type='storage_job' THEN
              CASE WHEN NOT json_valid(new.data) THEN 1
                   ELSE EXISTS(SELECT 1 FROM main.commands c WHERE c.rowid <= \(cutoff)
                     AND c.command_id=CAST(json_extract(new.data,'$.parent_command_id') AS TEXT)
                     AND c.principal=CAST(json_extract(new.data,'$.parent_principal') AS TEXT)) END
            ELSE 0 END
            """
        let bump = "UPDATE checklist_prune_protection SET generation=generation+1;"
        try db.execute(sql: """
            CREATE TEMP TABLE checklist_prune_protection(generation INTEGER NOT NULL, cutoff INTEGER NOT NULL);
            INSERT INTO checklist_prune_protection VALUES (0, 0);
            CREATE TEMP TRIGGER checklist_prune_storage_insert AFTER INSERT ON main.records
              WHEN \(canProtect) BEGIN \(bump) END;
            CREATE TEMP TRIGGER checklist_prune_storage_update AFTER UPDATE OF type,data ON main.records
              WHEN CASE WHEN \(canProtect) THEN (\(newParent)) IS NOT (\(oldParent)) ELSE 0 END BEGIN \(bump) END;
            CREATE TEMP TRIGGER checklist_prune_command_update AFTER UPDATE ON main.commands
              WHEN MIN(old.rowid,new.rowid) <= \(cutoff) BEGIN \(bump) END;
            CREATE TEMP TRIGGER checklist_prune_command_delete AFTER DELETE ON main.commands
              WHEN old.rowid <= \(cutoff) BEGIN \(bump) END;
            CREATE TEMP TRIGGER checklist_prune_projection_insert AFTER INSERT ON main.metadata
              WHEN new.key GLOB '\(MediaRoundDeletionHistory.progressPrefix)*' BEGIN \(bump) END;
            CREATE TEMP TRIGGER checklist_prune_projection_update AFTER UPDATE OF key ON main.metadata
              WHEN new.key GLOB '\(MediaRoundDeletionHistory.progressPrefix)*' BEGIN \(bump) END;
            """)
    }
}
