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

    let name = "work_health_changes_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private static let rowLimit = 4096
    private static let byteLimit = 1024 * 1024
    private static let families = ["task", "attempt", "project", "group", "status"]
    private var familySQL: String { Self.families.map {"CAST('\($0)' AS BLOB)"}.joined(separator:",") }

    func install(_ db: Database) throws -> Int64 {
        try db.execute(sql:"""
            CREATE TEMP TABLE \(name)(id BLOB NOT NULL,type BLOB NOT NULL,project BLOB NOT NULL,task BLOB NOT NULL,PRIMARY KEY(id,type,project,task)) WITHOUT ROWID;
            CREATE TEMP TABLE \(name)_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),units INTEGER NOT NULL,bytes INTEGER NOT NULL,refused INTEGER NOT NULL) WITHOUT ROWID;
            INSERT INTO \(name)_state VALUES(1,0,0,0);
            CREATE TEMP TRIGGER \(name)_count AFTER INSERT ON \(name) BEGIN
                UPDATE \(name)_state SET units=units+1,bytes=bytes+length(NEW.id)+length(NEW.type)+length(NEW.project)+length(NEW.task);
            END;
            """)
        // BEFORE INSERT sees a replaced row even when recursive_triggers is OFF.
        let prior = capture("SELECT id AS source_id,type AS source_type,project_id AS source_project,data AS source_data FROM main.records WHERE id=NEW.id AND CAST(type AS BLOB) IN (\(familySQL))")
        let inserted = capture(source("NEW"))
        try db.execute(sql:"CREATE TEMP TRIGGER \(name)_insert BEFORE INSERT ON main.records BEGIN \(prior) \(inserted) END")
        // UPDATE OR REPLACE suppresses the displaced row's DELETE trigger too.
        // Ordinary same-ID updates need no extra conflict observation.
        try db.execute(sql:"CREATE TEMP TRIGGER \(name)_update_conflict BEFORE UPDATE ON main.records WHEN typeof(OLD.id)!=typeof(NEW.id) OR CAST(OLD.id AS BLOB) IS NOT CAST(NEW.id AS BLOB) BEGIN \(prior) END")
        try db.execute(sql:"CREATE TEMP TRIGGER \(name)_update AFTER UPDATE ON main.records BEGIN \(capture(source("OLD"))) \(capture(source("NEW"))) END")
        try db.execute(sql:"CREATE TEMP TRIGGER \(name)_delete AFTER DELETE ON main.records BEGIN \(capture(source("OLD"))) END")
        return try Int64.fetchOne(db,sql:"PRAGMA data_version")!
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
        guard try Int64.fetchOne(db,sql:"PRAGMA data_version") == version,
              try Int.fetchOne(db,sql:"SELECT refused FROM \(name)_state") == 0 else {return nil}
        let rows = try Row.fetchAll(db,sql:"SELECT id,type,project,task FROM \(name) ORDER BY id,type,project,task")
        guard rows.count<=Self.rowLimit else {return nil}
        let families = Set(Self.families.map {Data($0.utf8)})
        var changes: [Change] = [],bytes = 0
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
        }
        return changes
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
