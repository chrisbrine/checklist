import Foundation
import GRDB

/// A command-local TEMP journal on the service's sole writer. Like task_purge,
/// it observes intervening writes without retaining the unrelated store. Each
/// attempt has its own names, so maintenance and concurrent preparations coexist.
struct MediaRoundDeletionChanges {
    let name = "media_delete_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    func install(_ db: Database) throws -> Int64 {
        try db.execute(sql:"CREATE TEMP TABLE \(name)(kind INTEGER,id BLOB,principal TEXT NOT NULL DEFAULT '',PRIMARY KEY(kind,id,principal)) WITHOUT ROWID; CREATE TEMP TABLE \(name)_overflow(value INTEGER); CREATE TEMP TABLE \(name)_budget(units INTEGER,bytes INTEGER); INSERT INTO \(name)_budget VALUES(0,0)")
        try db.execute(sql:"""
            CREATE TEMP TRIGGER \(name)_bound BEFORE INSERT ON \(name)
            WHEN NOT EXISTS(SELECT 1 FROM \(name) WHERE kind=NEW.kind AND id=NEW.id AND principal=NEW.principal) BEGIN
                INSERT INTO \(name)_overflow SELECT 1 FROM \(name)_budget WHERE (units>=32768 OR bytes+length(NEW.id)+length(CAST(NEW.principal AS BLOB))>8388608) AND NOT EXISTS(SELECT 1 FROM \(name)_overflow);
                SELECT RAISE(IGNORE) WHERE EXISTS(SELECT 1 FROM \(name)_overflow);
            END;
            CREATE TEMP TRIGGER \(name)_count AFTER INSERT ON \(name) BEGIN
                UPDATE \(name)_budget SET units=units+1,bytes=bytes+length(NEW.id)+length(CAST(NEW.principal AS BLOB));
            END;
            """)
        for (table,kind,key) in [("records",0,"id"),("events",1,"id"),("commands",2,"command_id")] {
            for action in ["INSERT","UPDATE","DELETE"] {
                var body = ""
                for alias in action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"] {
                    let principal = kind == 2 ? "\(alias).principal" : "''"
                    body += "INSERT INTO \(name) SELECT \(kind),CAST(\(alias).\(key) AS BLOB),\(principal) WHERE NOT EXISTS(SELECT 1 FROM \(name)_overflow) ON CONFLICT DO NOTHING;"
                }
                try db.execute(sql:"CREATE TEMP TRIGGER \(name)_\(table)_\(action) AFTER \(action) ON main.\(table) BEGIN \(body) END")
            }
        }
        return try Int64.fetchOne(db,sql:"PRAGMA data_version")!
    }
    func remove(_ db: Database) throws {
        for table in ["records","events","commands"] {
            for action in ["INSERT","UPDATE","DELETE"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.\(name)_\(table)_\(action)")}
        }
        try db.execute(sql:"DROP TABLE IF EXISTS temp.\(name); DROP TABLE IF EXISTS temp.\(name)_overflow; DROP TABLE IF EXISTS temp.\(name)_budget")
    }
}

struct MediaRoundDeletionFence {
    struct Record {let revision: Int64;let digest: Data;let type: Data;let project: Data?}
    let records: [Data:Record]
    let events: [Data:Data]
    let commands: [(String,Data,Data)]
    let needles: Set<Data>
    let holdDigests: Set<Data>
    let filePaths: [String]
    let workspaceProtections: Set<Data>

    init(_ db: Database,ids: Set<Data>,events: [String],commands: [(String,String)],needles: Set<Data>,holdDigests: Set<Data>,filePaths: [String]) throws {
        var records: [Data:Record] = [:],history: [Data:Data] = [:],receipts: [(String,Data,Data)] = []
        for id in ids {
            guard let row = try Row.fetchOne(db,sql:"SELECT revision,CAST(data AS BLOB) data,CAST(type AS BLOB) type,CAST(project_id AS BLOB) project FROM records WHERE id=CAST(? AS TEXT)",arguments:[id]) else {throw Self.changed("planned_record_missing",type:"record",id:id)}
            records[id] = .init(revision:row["revision"],digest:MediaPreparationOverlay.digest(row["data"]),type:row["type"],project:row["project"])
        }
        for value in events {
            let id = Data(value.utf8)
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(project_id,entity_id,kind,data) AS BLOB) FROM events WHERE id=CAST(? AS TEXT)",arguments:[id]) else {throw Self.changed("planned_event_missing",type:"event",id:id)}
            history[id] = MediaPreparationOverlay.digest(data)
        }
        for (principal,value) in commands {
            let id = Data(value.utf8)
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(digest,result) AS BLOB) FROM commands WHERE principal=? AND command_id=CAST(? AS TEXT)",arguments:[principal,id]) else {throw Self.changed("planned_command_missing",type:"command",id:id)}
            receipts.append((principal,id,MediaPreparationOverlay.digest(data)))
        }
        self.records = records;self.events = history;self.commands = receipts;self.needles = needles;self.holdDigests = holdDigests
        self.filePaths = filePaths;workspaceProtections = try Self.workspaceProtections(db,paths:filePaths)
    }
    static func changed(_ check: String,type: String,id: Data) -> CoreError {
        CoreError("MEDIA_CONTEXT_CHANGED","A round record, deletion-plan row or relevant reference changed during preparation; no records changed.",details:["check":check,"record_type":type,"record_id":String(decoding:id,as:UTF8.self)])
    }

    private static func workspaceProtections(_ db: Database,paths: [String]) throws -> Set<Data> {
        guard !paths.isEmpty else {return []}
        let targets = paths.map {URL(fileURLWithPath:$0).resolvingSymlinksInPath().standardizedFileURL.path}
        let projects = try Row.fetchCursor(db,sql:"SELECT CAST(id AS BLOB) id,json_extract(data,'$.root_path') root FROM records WHERE type='project'")
        var result = Set<Data>()
        while let row = try projects.next() {
            guard let path: String = row["root"] else {continue}
            let workspace = URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path
            if targets.contains(where:{$0 == workspace || $0.hasPrefix(workspace + "/")}) {
                var key: Data = row["id"];key.append(0);key.append(contentsOf:workspace.utf8);result.insert(key)
            }
        }
        return result
    }

    func validate(_ db: Database,changes: MediaRoundDeletionChanges,writerVersion: Int64) throws {
        // Other sessions use this sole writer and are journaled. An untracked
        // external SQL writer cannot be admitted without a complete observation.
        guard try Int64.fetchOne(db,sql:"PRAGMA data_version") == writerVersion else {throw Self.changed("untracked_writer",type:"metadata",id:Data("data_version".utf8))}
        guard try !Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM \(changes.name)_overflow)")! else {throw Self.changed("change_journal_overflow",type:"journal",id:Data(changes.name.utf8))}
        // Project counters may move with unrelated writes. Only a root that
        // starts/stops protecting a selected file changes deletion authority.
        let currentProtections = try Self.workspaceProtections(db,paths:filePaths)
        if let difference = currentProtections.symmetricDifference(workspaceProtections).sorted(by:{$0.lexicographicallyPrecedes($1)}).first {
            // Filesystem paths contain no NUL; opaque project IDs may do so.
            let separator = difference.lastIndex(of:0)!
            throw Self.changed("workspace_protection",type:"project",id:Data(difference[..<separator]))
        }
        for (id,seen) in records {
            guard let row = try Row.fetchOne(db,sql:"SELECT revision,CAST(data AS BLOB) data,CAST(type AS BLOB) type,CAST(project_id AS BLOB) project FROM records WHERE id=CAST(? AS TEXT)",arguments:[id]),
                  row["revision"] as Int64 == seen.revision,row["type"] as Data == seen.type,row["project"] as Data? == seen.project,
                  MediaPreparationOverlay.digest(row["data"]) == seen.digest else {throw Self.changed("planned_record_changed",type:String(decoding:seen.type,as:UTF8.self),id:id)}
        }
        for (id,digest) in events {
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(project_id,entity_id,kind,data) AS BLOB) FROM events WHERE id=CAST(? AS TEXT)",arguments:[id]),MediaPreparationOverlay.digest(data) == digest else {throw Self.changed("planned_event_changed",type:"event",id:id)}
        }
        for (principal,id,digest) in commands {
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(digest,result) AS BLOB) FROM commands WHERE principal=? AND command_id=CAST(? AS TEXT)",arguments:[principal,id]),MediaPreparationOverlay.digest(data) == digest else {throw Self.changed("planned_command_changed",type:"command",id:id)}
        }
        let tokens = try jsonString(needles.map {String(decoding:$0,as:UTF8.self)}),digests = try jsonString(holdDigests.map {String(decoding:$0,as:UTF8.self)})
        // Match complete text atoms AND dictionary keys as in the preparation
        // stream. SQL keeps even a large unrelated changed row out of Swift.
        for (table,kind,key,payload) in [("records",0,"id","data"),("events",1,"id","data"),("commands",2,"command_id","result")] {
            let principal = kind == 2 ? " AND r.principal=c.principal" : ""
            let holds = kind == 0 ? " OR (r.type='storage_hold' AND CAST(token AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)))" : ""
            let entity = kind == 1 ? " OR CAST(r.entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))" : ""
            var arguments: [DatabaseValueConvertible] = [tokens]
            if kind == 0 {arguments.append(digests)}
            if kind == 1 {arguments.append(tokens)}
            let sql = """
                SELECT CAST(r.\(key) AS BLOB) id,\(kind == 0 ? "r.type" : kind == 1 ? "'event'" : "'command'") type FROM \(changes.name) c JOIN \(table) r ON r.\(key)=CAST(c.id AS TEXT)\(principal)
                WHERE c.kind=\(kind) AND (NOT json_valid(r.\(payload)) OR EXISTS(
                    SELECT 1 FROM (SELECT j.atom token FROM json_tree(r.\(payload)) j WHERE j.type='text' UNION ALL SELECT j.key FROM json_tree(r.\(payload)) j WHERE typeof(j.key)='text')
                    WHERE CAST(token AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))\(holds))\(entity)) LIMIT 1
                """
            if let row = try Row.fetchOne(db,sql:sql,arguments:StatementArguments(arguments)) {throw Self.changed("changed_reference",type:row["type"],id:row["id"])}
        }
    }
}
