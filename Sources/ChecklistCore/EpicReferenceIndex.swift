import Foundation
import os
import GRDB
import SQLite3

/// Rebuildable proof on the sole writer connection. TEMP tables/triggers keep the
/// durable protocol unchanged and participate in the same transaction/rollback as
/// every record/event write, including direct SQL, import and purge paths.
final class EpicReferenceIndex: Sendable {
    static let maximumPayloadBytes = 2_000_000
    private struct Lifecycle: Sendable { var started = false; var stopped = false }
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())
    // Only the utility worker (or the component fixture) owns a prepared slice.
    // Never acquire this lock while holding the writer connection.
    private struct Work: Sendable { var decoder: DatabaseQueue?; var prepared: Prepared? }
    private let work = OSAllocatedUnfairLock(initialState: Work())
    private struct Source: Sendable {
        let kind: Int,position: Int64,id: Data,project: Data?,type: String?,entity: Data?,payload: Data?
    }
    private struct Prepared: Sendable {
        let source: Source,targets: [Data],epic: Data?,invalid: String?
        var offset = 0
    }
    private let queue = DispatchQueue(label:"org.checklist.epic-reference-index",qos:.utility)

    func stop() { lifecycle.withLock { $0.stopped = true } }
    private var isStopped: Bool { lifecycle.withLock { $0.stopped } }

    func install(_ db: Database) throws {
        try db.execute(sql:"""
            CREATE TEMP TABLE epic_guard_refs(
                source_kind INTEGER NOT NULL, source_id BLOB NOT NULL,
                project BLOB, target BLOB NOT NULL,
                PRIMARY KEY(source_kind,source_id,target)) WITHOUT ROWID;
            CREATE INDEX temp.epic_guard_incoming ON epic_guard_refs(target,project,source_kind,source_id);
            CREATE TEMP TABLE epic_guard_members(project BLOB,epic BLOB,source_id BLOB PRIMARY KEY) WITHOUT ROWID;
            CREATE INDEX temp.epic_guard_membership ON epic_guard_members(project,epic);
            CREATE TEMP TABLE epic_guard_invalid(source_kind INTEGER,source_id BLOB,reason TEXT NOT NULL,PRIMARY KEY(source_kind,source_id)) WITHOUT ROWID;
            CREATE TEMP TABLE epic_guard_touched(source_kind INTEGER,source_id BLOB,PRIMARY KEY(source_kind,source_id)) WITHOUT ROWID;
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
                    INSERT INTO epic_guard_touched VALUES(\(kind),CAST(\(row).id AS BLOB)) ON CONFLICT DO NOTHING;
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
            INSERT INTO epic_guard_invalid SELECT \(kind),CAST(\(row).id AS BLOB),'invalid_payload' \(from) WHERE NOT (\(valid))
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
            start(router)
            throw CoreError("EPIC_HISTORY_UNPROVEN","Legacy reference indexing is pending in bounded background work. Nothing was removed; retry after indexing finishes.",details:["reason":"reference_index_pending"])
        }
        if let row = try Row.fetchOne(db,sql:"SELECT source_kind,source_id,reason FROM epic_guard_invalid ORDER BY source_kind,source_id LIMIT 1") {
            let id: Data = row["source_id"],kind: Int = row["source_kind"]
            let name = String(data:id,encoding:.utf8) ?? id.map {String(format:"%02x",$0)}.joined()
            throw CoreError("EPIC_HISTORY_UNPROVEN","Retained \(kind == 0 ? "record" : "event") \(name) has an invalid or over-2-MB payload. Nothing was removed; repair the named source through an authorized command.",details:["reason":"reference_index_unavailable","source_kind":kind == 0 ? "record" : "event","source_id":name,"payload_reason":row["reason"] as String])
        }
    }

    private func start(_ router: CommandRouter) {
        let shouldStart = lifecycle.withLock { state in
            guard !state.started,!state.stopped else { return false }
            state.started = true; return true
        }
        if shouldStart { enqueue(router) }
    }
    private func enqueue(_ router: CommandRouter) {
        // Each continuation is one finite page, not a timer/polling runtime.
        queue.async { [weak router,weak self] in
            guard let self,let router,!self.isStopped else {return}
            do {
                let lease = try router.storageAdmission.acquire()
                defer {lease.finish()}
                if try self.buildPage(router) {self.enqueue(router)}
            } catch {
                // Infrastructure failure does not poison the connection. Leave
                // committed progress intact; a later request may restart work.
                self.lifecycle.withLock { $0.started = false }
            }
        }
    }

    private func hasPending(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_progress WHERE high_water IS NOT NULL AND (position IS NULL OR position<high_water))") ?? true
    }

    private func nextSource(_ db: Database) throws -> Source? {
        for (table,column,kind) in [("records","rowid",0),("events","seq",1)] {
            let state = try Row.fetchOne(db,sql:"SELECT position,high_water FROM epic_guard_progress WHERE kind=?",arguments:[kind])!
            let position: Int64? = state["position"],high: Int64? = state["high_water"]
            guard let high,position == nil || position!<high else {continue}
            let lower = position == nil ? "" : "\(column)>? AND "
            let arguments = position.map {StatementArguments([$0,high])} ?? StatementArguments([high])
            if let row = try Row.fetchOne(db,sql:"""
                SELECT \(column) AS position,CAST(id AS BLOB) AS id,CAST(project_id AS BLOB) AS project,
                \(kind == 0 ? "type" : "NULL") AS type,\(kind == 1 ? "CAST(entity_id AS BLOB)" : "NULL") AS entity,
                CASE WHEN typeof(data)='text' AND length(CAST(data AS BLOB))<=\(Self.maximumPayloadBytes) THEN CAST(data AS BLOB) END AS payload
                FROM main.\(table) WHERE \(lower)\(column)<=? ORDER BY \(column) LIMIT 1
                """,arguments:arguments) {
                return Source(kind:kind,position:row["position"],id:row["id"],project:row["project"],type:row["type"],entity:row["entity"],payload:row["payload"])
            }
            try db.execute(sql:"UPDATE epic_guard_progress SET position=? WHERE kind=?",arguments:[high,kind])
        }
        return nil
    }

    private func prepare(_ source: Source, work: inout Work) throws -> Prepared {
        // Parse at most 2 MB on a separate in-memory SQLite connection, using the
        // same JSON semantics as the live triggers. No writer/coordinator is held
        // during large payload parsing, traversal or target deduplication.
        guard let payload = source.payload else {return Prepared(source:source,targets:[],epic:nil,invalid:"payload_type_or_size")}
        if work.decoder == nil {work.decoder = try DatabaseQueue()}
        return try work.decoder!.read { db in
            guard try Bool.fetchOne(db,sql:"SELECT json_valid(CAST(? AS TEXT))",arguments:[payload]) == true else {
                return Prepared(source:source,targets:[],epic:nil,invalid:"malformed_json")
            }
            var targets = Set<Data>()
            if let entity = source.entity {targets.insert(entity)}
            let cursor = try Row.fetchCursor(db,sql:"SELECT type,typeof(key) AS key_type,CAST(value AS BLOB) AS value,CAST(key AS BLOB) AS key FROM json_tree(CAST(? AS TEXT))",arguments:[payload])
            while let row = try cursor.next() {
                if row["type"] as String == "text" {targets.insert(row["value"] as Data)}
                if row["key_type"] as String == "text" {targets.insert(row["key"] as Data)}
            }
            let epic = source.type == "task" ? try Data.fetchOne(db,sql:"SELECT CAST(json_extract(CAST(? AS TEXT),'$.epic_id') AS BLOB) WHERE json_type(CAST(? AS TEXT),'$.epic_id')='text'",arguments:[payload,payload]) : nil
            return Prepared(source:source,targets:Array(targets),epic:epic,invalid:nil)
        }
    }

    /// A page commits at most 64 references/rows and yields after 50 ms, always
    /// allowing one finite unit to make progress even on a descheduled host.
    /// Budget exhaustion retains the next offset, rather than rolling back the
    /// whole row forever. Only this background worker reads legacy payloads.
    @discardableResult func buildPage(_ router: CommandRouter,seconds: TimeInterval = 0.05) throws -> Bool {
        return try work.withLock { work in
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            var units = 0
            while !isStopped && units<64 && (units == 0 || ProcessInfo.processInfo.systemUptime<deadline) {
                if work.prepared == nil {
                    guard let source = try router.dbQueue.writeWithoutTransaction({try nextSource($0)}) else {return false}
                    work.prepared = try prepare(source,work:&work)
                }
                let item = work.prepared!,source = item.source
                var offset = item.offset,done = false,applied = 0
                try router.dbQueue.writeWithoutTransaction { db in
                    try db.inTransaction {
                        // A live trigger has already replaced all proof for any source
                        // changed since startup. Never append a stale prepared slice,
                        // even after same-revision SQL UPDATE, REPLACE or deletion.
                        let touched = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_touched WHERE source_kind=? AND source_id=?)",arguments:[source.kind,source.id]) ?? true
                        if !touched {
                            if let invalid = item.invalid {
                                try db.execute(sql:"INSERT INTO epic_guard_invalid VALUES (?,?,?) ON CONFLICT DO NOTHING",arguments:[source.kind,source.id,invalid])
                            } else {
                                while offset<item.targets.count && units+applied<64 && (applied == 0 || ProcessInfo.processInfo.systemUptime<deadline) {
                                    try db.execute(sql:"INSERT INTO epic_guard_refs VALUES (?,?,?,?) ON CONFLICT DO NOTHING",arguments:[source.kind,source.id,source.project,item.targets[offset]])
                                    offset += 1;applied += 1
                                }
                                if offset == item.targets.count,let epic = item.epic {
                                    try db.execute(sql:"INSERT INTO epic_guard_members VALUES (?,?,?) ON CONFLICT(source_id) DO UPDATE SET project=excluded.project,epic=excluded.epic",arguments:[source.project,epic,source.id])
                                }
                            }
                        }
                        done = touched || item.invalid != nil || offset == item.targets.count
                        if done {try db.execute(sql:"UPDATE epic_guard_progress SET position=? WHERE kind=?",arguments:[source.position,source.kind])}
                        return .commit
                    }
                }
                // Publish the slice offset only after its transaction commits.
                if done {work.prepared = nil} else {work.prepared!.offset = offset}
                units += max(1,applied)
            }
            return try router.dbQueue.read {try hasPending($0)}
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
