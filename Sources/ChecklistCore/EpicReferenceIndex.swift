import Foundation
import GRDB
import SQLite3

/// Rebuildable proof on the sole writer connection. TEMP tables/triggers keep the
/// durable protocol unchanged and participate in the same transaction/rollback as
/// every record/event write, including direct SQL, import and purge paths.
final class EpicReferenceIndex {
    static let maximumPayloadBytes = 2_000_000
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private let queue = DispatchQueue(label:"org.checklist.epic-reference-index",qos:.utility)

    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer {lock.unlock()}; return stopped }

    func install(_ db: Database) throws {
        try db.execute(sql:"""
            CREATE TEMP TABLE epic_guard_refs(
                source_kind INTEGER NOT NULL, source_id BLOB NOT NULL,
                project BLOB, target BLOB NOT NULL,
                PRIMARY KEY(source_kind,source_id,target)) WITHOUT ROWID;
            CREATE INDEX temp.epic_guard_incoming ON epic_guard_refs(target,project,source_kind,source_id);
            CREATE TEMP TABLE epic_guard_members(project BLOB,epic BLOB,source_id BLOB PRIMARY KEY) WITHOUT ROWID;
            CREATE INDEX temp.epic_guard_membership ON epic_guard_members(project,epic);
            CREATE TEMP TABLE epic_guard_invalid(source_kind INTEGER,source_id BLOB,PRIMARY KEY(source_kind,source_id)) WITHOUT ROWID;
            CREATE TEMP TABLE epic_guard_progress(kind INTEGER PRIMARY KEY,position INTEGER,high_water INTEGER);
            INSERT INTO epic_guard_progress VALUES(0,NULL,(SELECT MAX(rowid) FROM main.records));
            INSERT INTO epic_guard_progress VALUES(1,NULL,(SELECT MAX(seq) FROM main.events));
            """)
        for (table,kind) in [("records",0),("events",1)] {
            for action in ["INSERT","UPDATE","DELETE"] {
                // REPLACE may skip DELETE triggers with recursive_triggers off.
                // Clear NEW as well as OLD so replaced IDs never keep stale links.
                let rows = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"]
                let cleanup = rows.map { row in
                    """
                    DELETE FROM epic_guard_refs WHERE source_kind=\(kind) AND source_id=CAST(\(row).id AS BLOB);
                    DELETE FROM epic_guard_invalid WHERE source_kind=\(kind) AND source_id=CAST(\(row).id AS BLOB);
                    \(kind == 0 ? "DELETE FROM epic_guard_members WHERE source_id=CAST(\(row).id AS BLOB);" : "")
                    """
                }.joined(separator:"\n")
                try db.execute(sql:"CREATE TEMP TRIGGER epic_guard_\(table)_\(action.lowercased()) AFTER \(action) ON main.\(table) BEGIN " + cleanup + (action == "DELETE" ? "" : Self.insertSQL(kind:kind,row:"NEW")) + " END")
            }
        }
    }

    private static func insertSQL(kind: Int,row: String,from: String = "") -> String {
        // Explicit UPSERT clauses survive the outer records UPSERT's conflict
        // policy; INSERT OR IGNORE in a trigger does not (SQLite semantics).
        let valid = "CASE WHEN typeof(\(row).data)='text' AND length(CAST(\(row).data AS BLOB))<=\(maximumPayloadBytes) THEN json_valid(\(row).data) ELSE 0 END"
        let json = "CASE WHEN \(valid) THEN \(row).data ELSE '{}' END"
        let jsonFrom = from.isEmpty ? "FROM " : from + ", "
        let membership = kind == 0 ? """
            INSERT INTO epic_guard_members(project,epic,source_id)
            SELECT CAST(\(row).project_id AS BLOB),CAST(json_extract(\(json),'$.epic_id') AS BLOB),CAST(\(row).id AS BLOB)
            \(from) WHERE \(row).type='task' AND json_type(\(json),'$.epic_id')='text'
            ON CONFLICT(source_id) DO UPDATE SET project=excluded.project,epic=excluded.epic;
            """ : """
            INSERT INTO epic_guard_refs(source_kind,source_id,project,target)
            SELECT 1,CAST(\(row).id AS BLOB),CAST(\(row).project_id AS BLOB),CAST(\(row).entity_id AS BLOB)
            \(from) WHERE \(row).entity_id IS NOT NULL ON CONFLICT(source_kind,source_id,target) DO NOTHING;
            """
        return """
            INSERT INTO epic_guard_invalid SELECT \(kind),CAST(\(row).id AS BLOB) \(from) WHERE NOT (\(valid))
            ON CONFLICT(source_kind,source_id) DO NOTHING;
            INSERT INTO epic_guard_refs(source_kind,source_id,project,target)
            SELECT \(kind),CAST(\(row).id AS BLOB),CAST(\(row).project_id AS BLOB),CAST(j.value AS BLOB)
            \(jsonFrom)json_tree(\(json)) j WHERE j.type='text' ON CONFLICT(source_kind,source_id,target) DO NOTHING;
            INSERT INTO epic_guard_refs(source_kind,source_id,project,target)
            SELECT \(kind),CAST(\(row).id AS BLOB),CAST(\(row).project_id AS BLOB),CAST(j.key AS BLOB)
            \(jsonFrom)json_tree(\(json)) j WHERE typeof(j.key)='text' ON CONFLICT(source_kind,source_id,target) DO NOTHING;
            \(membership)
            """
    }

    func requireReady(_ db: Database,router: CommandRouter) throws {
        let pending = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_progress WHERE high_water IS NOT NULL AND (position IS NULL OR position<high_water))") ?? true
        if pending {
            if isStopped {throw CoreError("EPIC_HISTORY_UNPROVEN","Legacy reference indexing could not finish within its bounded work budget. Nothing was removed; retain the Epic and request authorized diagnosis.",details:["reason":"reference_index_unavailable"])}
            start(router)
            throw CoreError("EPIC_HISTORY_UNPROVEN","Legacy reference indexing is pending in bounded background work. Nothing was removed; retry after indexing finishes.",details:["reason":"reference_index_pending"])
        }
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_invalid)") ?? true {
            throw CoreError("EPIC_HISTORY_UNPROVEN","Retained data cannot be indexed within the safe deletion budget. Nothing was removed; retain the Epic and request authorized diagnosis.",details:["reason":"reference_index_unavailable"])
        }
    }

    private func start(_ router: CommandRouter) {
        lock.lock(); defer {lock.unlock()}
        guard !started,!stopped else {return}
        started = true
        enqueue(router)
    }
    private func enqueue(_ router: CommandRouter) {
        // Each continuation is one finite page, not a timer/polling runtime.
        queue.async { [weak router,weak self] in
            guard let self,let router,!self.isStopped else {return}
            do {
                let lease = try router.storageAdmission.acquire()
                defer {lease.finish()}
                let more = try router.dbQueue.writeWithoutTransaction { db in
                    guard !self.isStopped else {return false}
                    return try self.buildPage(db)
                }
                if more {self.enqueue(router)}
            } catch {
                // No repeated retry of a failed page. Its rolled-back progress
                // leaves deletion explicitly unavailable for this connection.
                self.stop()
            }
        }
    }

    /// At most eight rows, 2 MB per payload, 50 ms of SQLite execution per page.
    /// Rowid/seq ranges and high-water marks never depend on corpus cardinality.
    @discardableResult func buildPage(_ db: Database) throws -> Bool {
        try Self.withBudget(db,seconds:0.05) {
            try db.inTransaction {
                for (table,column,kind) in [("records","rowid",0),("events","seq",1)] {
                    let state = try Row.fetchOne(db,sql:"SELECT position,high_water FROM epic_guard_progress WHERE kind=?",arguments:[kind])!
                    let position: Int64? = state["position"],high: Int64? = state["high_water"]
                    guard let high,position == nil || position!<high else {continue}
                    let lower = position == nil ? "" : "\(column)>? AND "
                    let arguments = position.map {StatementArguments([$0,high])} ?? StatementArguments([high])
                    let rows = try Row.fetchAll(db,sql:"SELECT \(column) AS position FROM main.\(table) WHERE \(lower)\(column)<=? ORDER BY \(column) LIMIT 4",arguments:arguments)
                    for row in rows {
                        let at: Int64 = row["position"]
                        // Reuse the trigger's exact indexing statements for one
                        // indexed source row. No durable bytes/rowids change.
                        try db.execute(sql:Self.insertSQL(kind:kind,row:"r",from:"FROM (SELECT * FROM main.\(table) WHERE \(column)=\(at)) r"))
                    }
                    try db.execute(sql:"UPDATE epic_guard_progress SET position=? WHERE kind=?",arguments:[rows.count<4 ? high : (rows.last!["position"] as Int64),kind])
                }
                return .commit
            }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_progress WHERE high_water IS NOT NULL AND (position IS NULL OR position<high_water))") ?? false
        }
    }

    static func budgetFailure() -> CoreError {
        CoreError("EPIC_HISTORY_UNPROVEN","Reference proof exceeded the safe execution budget. Nothing was removed; retain the Epic and request authorized diagnosis.",details:["reason":"reference_budget_exceeded"])
    }

    /// SQLite cancellation rolls back the whole deletion/page, including TEMP
    /// proof, leaving no partial history or receipt. OS scheduling/IO is separate.
    static func withBudget<T>(_ db: Database,seconds: TimeInterval,_ body: () throws -> T) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        let box = UnsafeMutablePointer<UInt64>.allocate(capacity:1)
        box.initialize(to:deadline)
        sqlite3_progress_handler(db.sqliteConnection,1000,{ context in
            guard let context else {return 1}
            return DispatchTime.now().uptimeNanoseconds >= context.assumingMemoryBound(to:UInt64.self).pointee ? 1 : 0
        },box)
        defer {sqlite3_progress_handler(db.sqliteConnection,0,nil,nil);box.deinitialize(count:1);box.deallocate()}
        do {return try body()}
        catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            throw budgetFailure()
        }
    }
}
