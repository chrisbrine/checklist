import Foundation
import GRDB

/// CL-344: a TEMP journal on the sole writer of every records-table write made
/// while an archive cleanup reference scan reads its snapshot. It keeps changed
/// identities and the text atoms of new payloads; an invalid payload or a full
/// journal leaves an unknown marker that refuses. Changed payloads and retained
/// index bytes are bounded before parsing/copying on the writer. TEMP storage is
/// connection-local and rebuildable, not a durable schema migration.
struct ArchiveCleanupScanJournal {
    static let rowLimit = 262_144
    static let byteLimit = 8 * 1024 * 1024
    static let payloadByteLimit = 1024 * 1024
    static func install(_ db: Database,activity: CleanupJournalActivity = .init()) throws {
        try remove(db)
        activity.register(db,name:"archive_cleanup_observing")
        try db.execute(sql:"""
            CREATE TEMP TABLE archive_cleanup_scan_changes(seq INTEGER PRIMARY KEY,id BLOB,atom BLOB);
            CREATE UNIQUE INDEX temp.archive_cleanup_scan_changed_id ON archive_cleanup_scan_changes(id,atom);
            CREATE INDEX temp.archive_cleanup_scan_changed_atom ON archive_cleanup_scan_changes(atom);
            CREATE UNIQUE INDEX temp.archive_cleanup_scan_unique_atom ON archive_cleanup_scan_changes(atom) WHERE id IS NULL AND atom IS NOT NULL;
            CREATE TEMP TABLE archive_cleanup_scan_budget(units INTEGER,bytes INTEGER);
            INSERT INTO archive_cleanup_scan_budget VALUES(0,0);
            """)
        let size = "COALESCE(length(NEW.id),0)+COALESCE(length(NEW.atom),0)"
        let exceeded = "units>=\(rowLimit) OR bytes+(\(size))>\(byteLimit)"
        // A BEFORE INSERT guard is evaluated for every copied atom, including
        // atoms from one INSERT SELECT. A scalar MAX(seq) subquery cannot supply
        // that guarantee. Deduplicate exact bytes before charging the budget.
        try db.execute(sql:"""
            CREATE TEMP TRIGGER archive_cleanup_scan_bound BEFORE INSERT ON archive_cleanup_scan_changes
            WHEN (NEW.id IS NOT NULL OR NEW.atom IS NOT NULL)
                AND NOT EXISTS(SELECT 1 FROM archive_cleanup_scan_changes WHERE id IS NEW.id AND atom IS NEW.atom) BEGIN
                INSERT INTO archive_cleanup_scan_changes(id,atom)
                    SELECT NULL,NULL FROM archive_cleanup_scan_budget WHERE (\(exceeded))
                    AND NOT EXISTS(SELECT 1 FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NULL);
                SELECT RAISE(IGNORE) FROM archive_cleanup_scan_budget WHERE \(exceeded);
            END;
            CREATE TEMP TRIGGER archive_cleanup_scan_count AFTER INSERT ON archive_cleanup_scan_changes
            WHEN NEW.id IS NOT NULL OR NEW.atom IS NOT NULL BEGIN
                UPDATE archive_cleanup_scan_budget SET units=units+1,bytes=bytes+(\(size));
            END;
            """)
        let open = "NOT EXISTS(SELECT 1 FROM archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NULL)"
        // CASE guarantees oversize/nontext input never reaches json_valid or
        // json_tree. Legacy receipt settlement may rewrite up to 16 MiB at once.
        let valid = "CASE WHEN typeof(NEW.data)='text' AND length(CAST(NEW.data AS BLOB))<=\(payloadByteLimit) THEN json_valid(NEW.data) ELSE 0 END"
        for action in ["INSERT","UPDATE","DELETE"] {
            var sql = ""
            for row in action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"] {
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) VALUES(CAST(\(row).id AS BLOB),CAST(\(row).type AS BLOB)) ON CONFLICT DO NOTHING;"
            }
            if action != "DELETE" {
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) SELECT NULL,NULL WHERE NOT (\(valid)) AND \(open);"
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) SELECT NULL,CAST(j.atom AS BLOB) FROM json_tree(CASE WHEN \(open) THEN CASE WHEN \(valid) THEN NEW.data ELSE '{}' END ELSE '{}' END) j WHERE j.type='text' ON CONFLICT DO NOTHING;"
            }
            try db.execute(sql:"CREATE TEMP TRIGGER archive_cleanup_scan_records_\(action.lowercased()) AFTER \(action) ON main.records WHEN archive_cleanup_observing() BEGIN " + sql + " END")
        }
    }
    static func remove(_ db: Database) throws {
        for action in ["insert","update","delete"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.archive_cleanup_scan_records_\(action)")}
        try db.execute(sql:"DROP TABLE IF EXISTS temp.archive_cleanup_scan_changes")
        try db.execute(sql:"DROP TABLE IF EXISTS temp.archive_cleanup_scan_budget")
    }
}

/// One archive cleanup scan made on a read snapshot before the writer. The
/// writer reuses it only for the same ticket and attachment tokens, and only
/// while no write touched a scanned record or added a reference to a token.
struct PreparedArchiveCleanupScan {
    let taskID: String
    /// Attachment ids and object paths that the scan started from.
    let tokens: Set<Data>
    /// Scanned referencing records, the ticket, its attachments and the tickets they name.
    let fenceIDs: Set<Data>
    /// A new payload atom equal to one of these adds a reference to the graph.
    let targets: Set<Data>
    let rows: [JSON]
    let failure: Error?
    let generation: Int?
    /// The relevant snapshot graph, indexed before obtaining the writer.
    var index: ArchiveCleanupReferenceIndex? = nil
    /// An entry also records absence or an exact verification failure.
    var originalProofs: [ArchiveAttachmentID:Result<TicketObjectRemovalVerification?,Error>]? = nil
    var encodedFence: (ids: String, targets: String)? = nil
    var journalActivity: CleanupJournalActivity? = nil

    /// `journal: false` skips the journal: the cleanup executor already checked it
    /// in this serialized writer turn, and every later journal row is its own
    /// bookkeeping write (CL-345). Tokens and other connections are still checked.
    func validate(_ db: Database,tokens current: Set<Data>,journal: Bool = true) throws {
        func refuse(_ source: String) throws -> Never {
            throw CoreError("CLEANUP_CONCURRENT_WRITE","The archive cleanup scan is out of date: \(source) changed before the archive committed. Nothing was archived and no original was deleted; retry the archive.",
                            details:["reason":"fenced by concurrent write to " + source,"retry":true])
        }
        guard current == tokens else {try refuse("the ticket's attachments")}
        guard try Int.fetchOne(db,sql:"PRAGMA data_version") == generation else {try refuse("another store connection")}
        guard journal else {return}
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NULL)") == true {try refuse("an unindexed record payload")}
        let ids = try encodedFence?.ids ?? jsonString(["values":fenceIDs.map {String(decoding:$0,as:UTF8.self)}])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.archive_cleanup_scan_changes WHERE id IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')))",arguments:[ids]) == true {try refuse("a scanned record")}
        let atoms = try encodedFence?.targets ?? jsonString(["values":targets.map {String(decoding:$0,as:UTF8.self)}])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.archive_cleanup_scan_changes WHERE atom IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')))",arguments:[atoms]) == true {try refuse("a reference to the ticket's originals")}
    }
}

extension CommandRouter {
    /// Runs before the object gate and the SQL writer. A returned scan holds
    /// archiveCleanupScanLock and the writer journal until finishArchiveCleanupScan.
    /// Nil leaves the command on its unchanged writer path (no reader, no attachment).
    func prepareArchiveCleanupScan(method: String,params p: JSON) -> PreparedArchiveCleanupScan? {
        let archive = method == "task_archive" && (p["action"] as? String ?? "archive") == "archive" && bool(p,"cleanup")
        guard archive || method == "attachment_cleanup_preview",let readers,let pid = p["project_id"] as? String else {return nil}
        archiveCleanupScanLock.lock()
        let activity = CleanupJournalActivity()
        var installed = false
        do {
            let generation = try dbQueue.writeWithoutTransaction {db -> Int? in
                let generation = try Int.fetchOne(db,sql:"PRAGMA data_version")
                try activity.install(db) {try ArchiveCleanupScanJournal.install(db,activity:activity)}
                return generation
            }
            installed = true
            let scan = try readers.read {db -> PreparedArchiveCleanupScan? in
                let task = try self.task(db,p,pid),tid = try StoredRecord(task,family:"task").string("id")
                let attachments = try self.scopedTaskRows(db,type:"attachment",task:task).filter {!bool($0,"unlinked")}
                guard !attachments.isEmpty else {return nil}
                return try self.scanArchiveCleanupSnapshot(db,taskID:tid,attachments:attachments,generation:generation)
            }
            if var scan {
                scan.journalActivity = activity
                archiveCleanupScanObserver?()
                return scan
            }
        } catch {}
        if installed {retireArchiveCleanupJournal(activity)}
        archiveCleanupScanLock.unlock()
        return nil
    }
    /// The reference scan on a read snapshot and the fence that guards its reuse.
    /// A scan failure is kept for the writer.
    func scanArchiveCleanupSnapshot(_ db: Database,taskID tid: String,attachments: [JSON],generation: Int?) throws -> PreparedArchiveCleanupScan {
        let tokens = try archiveCleanupTokens(attachments)
        do {
            let budget = ArchiveCleanupObservationBudget()
            let graph = try archiveCleanupRelevantReferenceGraph(db,attachments:attachments,budget:budget)
            var fence = graph.selected.union(tokens);fence.insert(Data(tid.utf8))
            for row in graph.index.graph where graph.selected.contains(Data((row["id"] as? String ?? "").utf8)) {
                if let linked = row["task_id"] as? String {fence.insert(Data(linked.utf8))}
            }
            let targets = graph.selected.union(tokens)
            // The streamed observation also projects unrelated tasks and reviews.
            // Only carry the reachable references and their linked tasks into the writer.
            let rows = graph.index.graph.filter { row in
                guard let id = row["id"] as? String else { return false }
                return fence.contains(Data(id.utf8))
            }
            let index = try ArchiveCleanupReferenceIndex(rows,check:budget.deadline.check)
            func encode(_ values: Set<Data>) throws -> String {
                try jsonString(["values":values.map {String(decoding:$0,as:UTF8.self)}])
            }
            let encodedFence = try (encode(fence),encode(targets))
            try budget.deadline.check()
            return .init(taskID:tid,tokens:tokens,fenceIDs:fence,targets:targets,rows:rows,
                         failure:nil,generation:generation,index:index,encodedFence:encodedFence)
        } catch is DatabaseError {
            return .init(taskID:tid,tokens:tokens,fenceIDs:[],targets:[],rows:[],failure:CoreError("CLEANUP_READ_LANE_UNAVAILABLE","Archive cleanup could not read a store snapshot. Nothing was archived; retry."),generation:generation)
        } catch {
            return .init(taskID:tid,tokens:tokens,fenceIDs:[],targets:[],rows:[],failure:error,generation:generation)
        }
    }
    /// CL-345: the cleanup executor's attachments of one job: the ticket's linked
    /// attachments and every job original that still has a record.
    func archiveCleanupJobAttachments(_ db: Database,job: ArchiveCleanupJob,task: JSON) throws -> [JSON] {
        var rows = try scopedTaskRows(db,type:"attachment",task:task).filter {!bool($0,"unlinked")}
        for item in job.items where !rows.contains(where: {cleanupJobEqual($0["id"],item.original.id.text)}) {
            if let a = try? scoped(db,item.original.id.text,job.projectID.text,type:"attachment") {rows.append(a)}
        }
        return rows
    }
    /// CL-345: runs in the service continuation before the object gate and the SQL
    /// writer. It scans the first due job's ticket on a read snapshot; the executor
    /// then only checks the fence. A returned scan holds archiveCleanupScanLock and
    /// the writer journal until finishArchiveCleanupScan.
    func prepareArchiveCleanupJobScan(nowMS: Int64,ids: [String]) -> PreparedArchiveCleanupScan? {
        guard let readers else {return nil}
        guard archiveCleanupScanLock.try() else {return nil}
        let activity = CleanupJournalActivity()
        var installed = false
        do {
            let acquired = try withMaintenanceWriter(label:"archive_cleanup.prepare") {db,deadline -> Int in
                let generation = try Int.fetchOne(db,sql:"PRAGMA data_version") ?? 0
                try activity.install(db) {
                    try ArchiveCleanupScanJournal.install(db,activity:activity)
                    try deadline.check()
                }
                return generation
            }
            guard let generation = acquired else {
                archiveCleanupScanLock.unlock()
                return nil
            }
            installed = true
            let preparation = try readers.read {db -> (PreparedArchiveCleanupScan,[(ArchiveCleanupOriginal,JSON?)])? in
                for id in ids {
                    guard let job = try? self.cleanupJobDecode(self.record(db,id,type:"cleanup_job")),nowMS >= job.notBeforeMS,job.items.contains(where: {!$0.terminal}),
                          let task = try? self.scoped(db,job.taskID.text,job.projectID.text,type:"task"),bool(task,"archived") else {continue}
                    let attachments = try self.archiveCleanupJobAttachments(db,job:job,task:task)
                    guard !attachments.isEmpty else {continue}
                    let scan = try self.scanArchiveCleanupSnapshot(db,taskID:job.taskID.text,attachments:attachments,generation:generation)
                    let cursor = try self.archiveCleanupCursor(db,job:job)
                    let start = max(0,int(cursor,"next_index")) % job.items.count
                    let originals = (0..<job.items.count).lazy.map {job.items[(start + $0) % job.items.count]}
                        .filter {!$0.terminal}.prefix(ArchiveCleanupJob.admissionStepLimit).map {item in
                            (item.original,attachments.first {self.cleanupJobEqual($0["id"],item.original.id.text)})
                        }
                    return (scan,Array(originals))
                }
                return nil
            }
            if let (prepared,originals) = preparation {
                var scan = prepared
                scan.journalActivity = activity
                // Verification can read large originals. It holds neither the
                // snapshot, SQLite writer, nor the object gate. The commit
                // rechecks the path against the held descriptor.
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                scan.originalProofs = Dictionary(uniqueKeysWithValues: originals.map {original,attachment in
                    (original.id,Result {
                        guard let attachment else {throw CoreError("CLEANUP_OBJECT_UNAVAILABLE","The original record could not be verified.")}
                        let relative = try self.archiveCleanupRelativePath(attachment)
                        return try TicketObjectRemovalVerification(root:self.root,relative:relative,sha256:original.sha256,size:original.logicalBytes,check:{
                            guard ProcessInfo.processInfo.systemUptime < deadline else {throw MaintenanceStepDeferred()}
                        })
                    })
                })
                archiveCleanupScanObserver?()
                return scan
            }
        } catch {}
        if installed {retireArchiveCleanupJournal(activity)}
        archiveCleanupScanLock.unlock()
        return nil
    }
    func finishArchiveCleanupScan(_ scan: PreparedArchiveCleanupScan?) {
        guard let activity = scan?.journalActivity else {return}
        retireArchiveCleanupJournal(activity)
        archiveCleanupScanLock.unlock()
    }

    private func retireArchiveCleanupJournal(_ activity: CleanupJournalActivity) {
        activity.stop()
        _ = try? withMaintenanceWriter(label:"archive_cleanup.prepare_remove") {db,deadline in
            try db.inSavepoint {
                try ArchiveCleanupScanJournal.remove(db)
                try deadline.check()
                return .commit
            }
        }
    }
    /// Inside the command's writer transaction: the prepared index after a cheap
    /// fence check, or nil when this command prepared no scan for the ticket.
    func preparedArchiveCleanupIndex(_ db: Database,task: JSON,attachments: [JSON]) throws -> ArchiveCleanupReferenceIndex? {
        guard !db.configuration.readonly,db.isInsideTransaction,let scan = commandPreparation.archiveCleanupScan,cleanupJobEqual(task["id"],scan.taskID) else {return nil}
        if let failure = scan.failure {throw failure}
        try scan.validate(db,tokens:archiveCleanupTokens(attachments))
        return scan.index
    }
}
