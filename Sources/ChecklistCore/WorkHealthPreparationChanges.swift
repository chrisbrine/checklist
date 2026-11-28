import Foundation
import GRDB

/// Identifier-only changes made by the sole writer while health reads its page.
/// A refused observation never refuses the domain write that caused it.
struct WorkHealthPreparationChanges {
    struct Change {
        let id: Data
        let type: Data
        let project: Data
        let task: Data
    }

    struct InstallationStep {
        let object: String?
        let sql: String
    }

    struct Snapshot {
        fileprivate let units: Int
        let changes: [Change]
        let changedIDs: Set<Data>
    }

    let name = "work_health_changes_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private static let rowLimit = 4096
    private static let byteLimit = 1024 * 1024
    private static let families = ["task", "attempt", "project", "group", "status", "tag"]
    private static let definitionSuffixes = ["", "_state", "_count", "_insert", "_update_conflict", "_update", "_delete"]
    private var familySQL: String { Self.families.map {"CAST('\($0)' AS BLOB)"}.joined(separator:",") }

    /// Construct these SQL strings before asking for the writer. Each item can
    /// commit on its own while all capture triggers remain inactive.
    var installationSteps: [InstallationStep] {
        // BEFORE INSERT sees a replaced row even when recursive_triggers is OFF.
        let prior = capture("SELECT id AS source_id,type AS source_type,project_id AS source_project,data AS source_data FROM main.records WHERE id=NEW.id AND CAST(type AS BLOB) IN (\(familySQL))")
        let inserted = capture(source("NEW"))
        let active = "(SELECT active FROM \(name)_state)=1"
        // UPDATE OR REPLACE suppresses the displaced row's DELETE trigger too.
        // Ordinary same-ID updates need no extra conflict observation.
        return [
            .init(object:name,sql:"CREATE TEMP TABLE \(name)(id BLOB NOT NULL,type BLOB NOT NULL,project BLOB NOT NULL,task BLOB NOT NULL,PRIMARY KEY(id,type,project,task)) WITHOUT ROWID"),
            .init(object:name+"_state",sql:"CREATE TEMP TABLE \(name)_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),units INTEGER NOT NULL,bytes INTEGER NOT NULL,refused INTEGER NOT NULL,active INTEGER NOT NULL) WITHOUT ROWID"),
            .init(object:nil,sql:"INSERT INTO \(name)_state VALUES(1,0,0,0,0)"),
            .init(object:name+"_count",sql:"""
                CREATE TEMP TRIGGER \(name)_count AFTER INSERT ON \(name) BEGIN
                    UPDATE \(name)_state SET units=units+1,bytes=bytes+length(NEW.id)+length(NEW.type)+length(NEW.project)+length(NEW.task);
                END
                """),
            .init(object:name+"_insert",sql:"CREATE TEMP TRIGGER \(name)_insert BEFORE INSERT ON main.records WHEN \(active) BEGIN \(prior) \(inserted) END"),
            .init(object:name+"_update_conflict",sql:"CREATE TEMP TRIGGER \(name)_update_conflict BEFORE UPDATE ON main.records WHEN \(active) AND (typeof(OLD.id)!=typeof(NEW.id) OR CAST(OLD.id AS BLOB) IS NOT CAST(NEW.id AS BLOB)) BEGIN \(prior) END"),
            .init(object:name+"_update",sql:"CREATE TEMP TRIGGER \(name)_update AFTER UPDATE ON main.records WHEN \(active) BEGIN \(capture(source("OLD"))) \(inserted) END"),
            .init(object:name+"_delete",sql:"CREATE TEMP TRIGGER \(name)_delete AFTER DELETE ON main.records WHEN \(active) BEGIN \(capture(source("OLD"))) END")
        ]
    }

    func prepareStep(_ db: Database, _ step: InstallationStep, deadline: MaintenanceDeadline? = nil) throws {
        let exists: Bool?
        if let object = step.object {
            exists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.sqlite_schema WHERE name=?)",arguments:[object])
        } else {
            exists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM \(name)_state)")
        }
        guard exists != true else {return}
        // Only TEMP schema or state changes. There is no need to reserve the
        // main SQLite write lock with BEGIN IMMEDIATE for these steps.
        try withTempTransaction(db,deadline:deadline) {try db.execute(sql:step.sql)}
    }

    func install(_ db: Database) throws -> Int64 {
        for step in installationSteps {try prepareStep(db,step)}
        return try recordChanges(db,deadline:nil)
    }

    /// Reuse the writer's TEMP schema so health wakes do not repeatedly compile
    /// triggers or invalidate the SQLite statement cache used by commands.
    func start(_ db: Database) throws -> Int64 {
        if let version = try startIfPrepared(db) {return version}
        return try install(db)
    }

    func startIfPrepared(_ db: Database, deadline: MaintenanceDeadline? = nil) throws -> Int64? {
        let expected = Self.definitionSuffixes.map { name + $0 }
        let placeholders = Array(repeating:"?",count:expected.count).joined(separator:",")
        guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM temp.sqlite_schema WHERE name IN (\(placeholders))",arguments:StatementArguments(expected)) == expected.count,
              try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM \(name)_state)") == true else {return nil}
        return try recordChanges(db,deadline:deadline)
    }

    private func recordChanges(_ db: Database, deadline: MaintenanceDeadline?) throws -> Int64 {
        var version: Int64?
        try withTempTransaction(db,deadline:deadline) {
            try db.execute(sql:"DELETE FROM \(name); UPDATE \(name)_state SET units=0,bytes=0,refused=0,active=1")
            version = try Int64.fetchOne(db,sql:"PRAGMA data_version")
        }
        return version!
    }

    private func withTempTransaction(_ db: Database, deadline: MaintenanceDeadline?, _ body: () throws -> Void) throws {
        func commit() throws -> Database.TransactionCompletion {
            try deadline?.check()
            try body()
            try deadline?.check()
            return .commit
        }
        if db.isInsideTransaction {try db.inSavepoint(commit)}
        else {try db.inTransaction(.deferred,commit)}
    }

    /// At rest ordinary commands pay only the trigger's active check.
    func stop(_ db: Database) throws {
        try db.execute(sql:"UPDATE \(name)_state SET active=0")
    }

    /// The health worker checks changes before it applies any advisory state.
    /// Its own successful writes must not invalidate later candidates in the page.
    func resume(_ db: Database) throws {
        try db.execute(sql:"UPDATE \(name)_state SET active=1")
    }

    private func source(_ row: String) -> String {
        "SELECT \(row).id AS source_id,\(row).type AS source_type,\(row).project_id AS source_project,\(row).data AS source_data WHERE CAST(\(row).type AS BLOB) IN (\(familySQL))"
    }

    private func capture(_ source: String) -> String {
        // Every JSON call sees a valid object, including for malformed input.
        // SQL identifiers stay length-aware BLOBs. Refuse a JSON task identity
        // containing a NUL escape before relying on scalar extraction; the
        // multi-path result keeps its quoted JSON representation for this check.
        // NULL project/task metadata uses empty bytes.
        let safe = """
            SELECT *,CASE WHEN typeof(source_data)='text' AND json_valid(source_data)
                THEN CASE WHEN json_type(source_data)='object' THEN source_data ELSE '{}' END
                ELSE '{}' END AS payload,
                CASE WHEN typeof(source_data)='text' AND json_valid(source_data)
                THEN json_type(source_data)='object' ELSE 0 END AS valid_json
            FROM (\(source))
            """
        let candidate = """
            SELECT CAST(source_id AS BLOB) AS id,CAST(source_type AS BLOB) AS type,
                CASE WHEN source_project IS NULL THEN X'' ELSE CAST(source_project AS BLOB) END AS project,
                CASE WHEN json_type(payload,'$.task_id')='text' THEN CAST(json_extract(payload,'$.task_id') AS BLOB) ELSE X'' END AS task,
                COALESCE(typeof(source_id)='text' AND length(CAST(source_id AS BLOB))>0 AND typeof(source_type)='text'
                    AND (source_project IS NULL OR (typeof(source_project)='text' AND length(CAST(source_project AS BLOB))>0))
                    AND valid_json AND CASE WHEN json_type(payload,'$.task_id') IS NULL OR json_type(payload,'$.task_id')='null' THEN 1
                        WHEN json_type(payload,'$.task_id')='text' THEN length(CAST(json_extract(payload,'$.task_id') AS BLOB))>0 ELSE 0 END
                    AND instr(CAST(json_extract(payload,'$.task_id','$.task_id') AS BLOB),X'5c7530303030')=0
                    AND (SELECT COUNT(*) FROM json_each(payload) WHERE CAST(key AS BLOB)=CAST('task_id' AS BLOB))<=1,0) AS valid
            FROM (\(safe))
            """
        let absent = "NOT EXISTS(SELECT 1 FROM \(name) seen WHERE seen.id=c.id AND seen.type=c.type AND seen.project=c.project AND seen.task=c.task)"
        let size = "length(c.id)+length(c.type)+length(c.project)+length(c.task)"
        return """
            UPDATE \(name)_state SET refused=1 WHERE refused=0 AND EXISTS(SELECT 1 FROM (\(candidate)) c WHERE NOT c.valid);
            UPDATE \(name)_state SET refused=1 WHERE refused=0 AND EXISTS(SELECT 1 FROM (\(candidate)) c WHERE c.valid AND \(absent) AND (units>=\(Self.rowLimit) OR bytes+\(size)>\(Self.byteLimit)));
            INSERT INTO \(name)(id,type,project,task) SELECT c.id,c.type,c.project,c.task FROM (\(candidate)) c
                WHERE c.valid AND (SELECT refused=0 AND units<\(Self.rowLimit) AND bytes+\(size)<=\(Self.byteLimit) FROM \(name)_state) AND \(absent);
            """
    }

    /// Only other connections advance this writer's data_version. Its ordinary
    /// writes are instead checked through the bounded identifier journal.
    func read(_ db: Database,version: Int64) throws -> [Change]? {
        try readSnapshot(db,version:version,previous:nil)?.changes
    }

    /// Between the start and end of one observation the journal only adds
    /// distinct rows. Compare the sticky refusal flag even if the count stayed
    /// the same, and validate external writes on every candidate's transaction.
    func readSnapshot(_ db: Database,version: Int64,previous: Snapshot?) throws -> Snapshot? {
        guard try Int64.fetchOne(db,sql:"PRAGMA data_version") == version,
              let state = try Row.fetchOne(db,sql:"SELECT units,refused FROM \(name)_state"),state["refused"] as Int == 0 else {return nil}
        let units: Int = state["units"]
        if let previous,previous.units == units {return previous}
        let rows = try Row.fetchAll(db,sql:"SELECT id,type,project,task FROM \(name) ORDER BY id,type,project,task")
        guard rows.count == units,rows.count<=Self.rowLimit else {return nil}
        let families = Set(Self.families.map {Data($0.utf8)})
        var changes: [Change] = [],changedIDs = Set<Data>(),bytes = 0
        for row in rows {
            guard let id = row["id"] as Data?,let type = row["type"] as Data?,
                  let project = row["project"] as Data?,let task = row["task"] as Data?,
                  !id.isEmpty,families.contains(type) else {return nil}
            for value in [id,type,project,task] {
                guard let text = String(data:value,encoding:.utf8),Data(text.utf8)==value else {return nil}
                bytes += value.count
                guard bytes<=Self.byteLimit else {return nil}
            }
            changes.append(.init(id:id,type:type,project:project,task:task))
            changedIDs.insert(id)
        }
        return Snapshot(units:units,changes:changes,changedIDs:changedIDs)
    }

    func remove(_ db: Database) throws {
        try db.execute(sql:"""
            DROP TRIGGER IF EXISTS temp.\(name)_insert;
            DROP TRIGGER IF EXISTS temp.\(name)_update;
            DROP TRIGGER IF EXISTS temp.\(name)_update_conflict;
            DROP TRIGGER IF EXISTS temp.\(name)_delete;
            DROP TRIGGER IF EXISTS temp.\(name)_count;
            DROP TABLE IF EXISTS temp.\(name);
            DROP TABLE IF EXISTS temp.\(name)_state;
            """)
    }
}
