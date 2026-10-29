import Foundation
import GRDB

/// CL-344: a TEMP journal on the sole writer of every records-table write made
/// while an archive cleanup reference scan reads its snapshot. It keeps changed
/// identities and the text atoms of new payloads; an invalid payload or a full
/// journal leaves an unknown marker that refuses. TEMP storage is
/// connection-local and rebuildable, not a durable schema migration.
struct ArchiveCleanupScanJournal {
    static let rowLimit = 262_144
    static func install(_ db: Database) throws {
        try remove(db)
        try db.execute(sql:"""
            CREATE TEMP TABLE archive_cleanup_scan_changes(seq INTEGER PRIMARY KEY,id BLOB,atom BLOB);
            CREATE INDEX temp.archive_cleanup_scan_changed_id ON archive_cleanup_scan_changes(id);
            CREATE INDEX temp.archive_cleanup_scan_changed_atom ON archive_cleanup_scan_changes(atom);
            """)
        let open = "(SELECT COALESCE(MAX(seq),0) FROM archive_cleanup_scan_changes)<\(rowLimit)"
        let valid = "typeof(NEW.data)='text' AND json_valid(NEW.data)"
        for action in ["INSERT","UPDATE","DELETE"] {
            var sql = ""
            for row in action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"] {
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) VALUES(CAST(\(row).id AS BLOB),CAST(\(row).type AS BLOB));"
            }
            if action != "DELETE" {
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) SELECT NULL,NULL WHERE NOT (\(valid)) OR NOT \(open);"
                sql += "INSERT INTO archive_cleanup_scan_changes(id,atom) SELECT NULL,CAST(j.atom AS BLOB) FROM json_tree(CASE WHEN \(valid) THEN NEW.data ELSE '{}' END) j WHERE j.type='text' AND \(open);"
            }
            try db.execute(sql:"CREATE TEMP TRIGGER archive_cleanup_scan_records_\(action.lowercased()) AFTER \(action) ON main.records BEGIN " + sql + " END")
        }
    }
    static func remove(_ db: Database) throws {
        for action in ["insert","update","delete"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.archive_cleanup_scan_records_\(action)")}
        try db.execute(sql:"DROP TABLE IF EXISTS temp.archive_cleanup_scan_changes")
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

    func validate(_ db: Database,tokens current: Set<Data>) throws {
        func refuse(_ source: String) throws -> Never {
            throw CoreError("CLEANUP_CONCURRENT_WRITE","The archive cleanup scan is out of date: \(source) changed before the archive committed. Nothing was archived and no original was deleted; retry the archive.",
                            details:["reason":"fenced by concurrent write to " + source,"retry":true])
        }
        guard current == tokens else {try refuse("the ticket's attachments")}
        guard try Int.fetchOne(db,sql:"PRAGMA data_version") == generation else {try refuse("another store connection")}
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.archive_cleanup_scan_changes WHERE id IS NULL AND atom IS NULL)") == true {try refuse("an unindexed record payload")}
        let ids = try jsonString(["values":fenceIDs.map {String(decoding:$0,as:UTF8.self)}])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.archive_cleanup_scan_changes WHERE id IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')))",arguments:[ids]) == true {try refuse("a scanned record")}
        let atoms = try jsonString(["values":targets.map {String(decoding:$0,as:UTF8.self)}])
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
        var installed = false
        do {
            let generation = try dbQueue.writeWithoutTransaction {db -> Int? in
                try db.inSavepoint {try ArchiveCleanupScanJournal.install(db);return .commit}
                return try Int.fetchOne(db,sql:"PRAGMA data_version")
            }
            installed = true
            let scan = try readers.read {db -> PreparedArchiveCleanupScan? in
                let task = try self.task(db,p,pid),tid = try StoredRecord(task,family:"task").string("id")
                let attachments = try self.scopedTaskRows(db,type:"attachment",task:task).filter {!bool($0,"unlinked")}
                guard !attachments.isEmpty else {return nil}
                let tokens = try self.archiveCleanupTokens(attachments)
                do {
                    let graph = try self.archiveCleanupRelevantReferenceGraph(db,attachments:attachments)
                    var fence = graph.selected.union(tokens);fence.insert(Data(tid.utf8))
                    for row in graph.rows where graph.selected.contains(Data((row["id"] as? String ?? "").utf8)) {
                        if let linked = row["task_id"] as? String {fence.insert(Data(linked.utf8))}
                    }
                    return .init(taskID:tid,tokens:tokens,fenceIDs:fence,targets:graph.selected.union(tokens),rows:graph.rows,failure:nil,generation:generation)
                } catch is DatabaseError {
                    return .init(taskID:tid,tokens:tokens,fenceIDs:[],targets:[],rows:[],failure:CoreError("CLEANUP_READ_LANE_UNAVAILABLE","Archive cleanup could not read a store snapshot. Nothing was archived; retry."),generation:generation)
                } catch {
                    return .init(taskID:tid,tokens:tokens,fenceIDs:[],targets:[],rows:[],failure:error,generation:generation)
                }
            }
            if let scan {archiveCleanupScanObserver?();return scan}
        } catch {}
        if installed {try? dbQueue.writeWithoutTransaction {try ArchiveCleanupScanJournal.remove($0)}}
        archiveCleanupScanLock.unlock()
        return nil
    }
    func finishArchiveCleanupScan(_ scan: PreparedArchiveCleanupScan?) {
        guard scan != nil else {return}
        try? dbQueue.writeWithoutTransaction {try ArchiveCleanupScanJournal.remove($0)}
        archiveCleanupScanLock.unlock()
    }
    /// Inside the command's writer transaction: the prepared rows after a cheap
    /// fence check, or nil when this command prepared no scan for the ticket.
    func preparedArchiveCleanupRows(_ db: Database,task: JSON,attachments: [JSON]) throws -> [JSON]? {
        guard !db.configuration.readonly,db.isInsideTransaction,let scan = commandPreparation.archiveCleanupScan,cleanupJobEqual(task["id"],scan.taskID) else {return nil}
        if let failure = scan.failure {throw failure}
        try scan.validate(db,tokens:archiveCleanupTokens(attachments))
        return scan.rows
    }
}
