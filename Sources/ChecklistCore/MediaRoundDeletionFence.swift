import Foundation
import GRDB

/// A command-local TEMP journal on the service's sole writer. Like task_purge,
/// it observes intervening writes without retaining the unrelated store. Each
/// attempt has its own names, so maintenance and concurrent preparations coexist.
struct MediaRoundDeletionChanges {
    let name = "media_delete_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    func install(_ db: Database) throws -> Int64 {
        try db.execute(sql:"CREATE TEMP TABLE \(name)(kind INTEGER,id BLOB,principal TEXT NOT NULL DEFAULT '',PRIMARY KEY(kind,id,principal)) WITHOUT ROWID; CREATE TEMP TABLE \(name)_overflow(value INTEGER); CREATE TEMP TABLE \(name)_budget(units INTEGER,bytes INTEGER,observing INTEGER); INSERT INTO \(name)_budget VALUES(0,0,1)")
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
        for (table,kind,key) in [("records",0,"id"),("events",1,"id"),("commands",2,"command_id"),("metadata",3,"key")] {
            for action in ["INSERT","UPDATE","DELETE"] {
                var body = ""
                for alias in action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"] {
                    let principal = kind == 2 ? "\(alias).principal" : "''"
                    let scope = kind == 3 ? " AND \(alias).key GLOB 'command-operation:*'" : ""
                    body += "INSERT INTO \(name) SELECT \(kind),CAST(\(alias).\(key) AS BLOB),\(principal) WHERE NOT EXISTS(SELECT 1 FROM \(name)_overflow)\(scope) ON CONFLICT DO NOTHING;"
                }
                try db.execute(sql:"CREATE TEMP TRIGGER \(name)_\(table)_\(action) AFTER \(action) ON main.\(table) WHEN (SELECT observing FROM \(name)_budget)=1 BEGIN \(body) END")
            }
        }
        return try Int64.fetchOne(db,sql:"PRAGMA data_version")!
    }
    func apply(_ db: Database,_ body: () throws -> Void) throws {
        // Our own bounded changes were planned at the current cursor. Other
        // observers still journal them, including a second project's deletion.
        try db.execute(sql:"DELETE FROM \(name); DELETE FROM \(name)_overflow; UPDATE \(name)_budget SET units=0,bytes=0,observing=0")
        try body()
        try db.execute(sql:"UPDATE \(name)_budget SET observing=1")
    }
    func remove(_ db: Database) throws {
        for table in ["records","events","commands","metadata"] {
            for action in ["INSERT","UPDATE","DELETE"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.\(name)_\(table)_\(action)")}
        }
        try db.execute(sql:"DROP TABLE IF EXISTS temp.\(name); DROP TABLE IF EXISTS temp.\(name)_overflow; DROP TABLE IF EXISTS temp.\(name)_budget")
    }

    func validateObservation(_ db: Database,writerVersion: Int64) throws {
        // Other sessions use this sole writer and are journaled. An untracked
        // external SQL writer cannot be admitted without a complete observation.
        guard try Int64.fetchOne(db,sql:"PRAGMA data_version") == writerVersion else {
            throw MediaRoundDeletionFence.changed("untracked_writer",type:"metadata",id:Data("data_version".utf8))
        }
        guard try !Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM \(name)_overflow)")! else {
            throw MediaRoundDeletionFence.changed("change_journal_overflow",type:"journal",id:Data(name.utf8))
        }
    }
}

struct MediaRoundDeletionFence: Codable {
    struct Record: Codable, Equatable {let position: Int64;let revision: Int64;let digest: Data;let type: Data;let project: Data?}

    static func record(_ db: Database,id: Data) throws -> Record? {
        guard let row = try Row.fetchOne(db,sql:"SELECT rowid position,revision,CAST(data AS BLOB) data,CAST(type AS BLOB) type,CAST(project_id AS BLOB) project FROM records WHERE id=CAST(? AS TEXT)",arguments:[id]) else {return nil}
        return .init(position:row["position"],revision:row["revision"],digest:MediaPreparationOverlay.digest(row["data"]),type:row["type"],project:row["project"])
    }
    let records: [Data:Record]
    let events: [Data:Data]
    let commands: [MediaRoundDeletionHistory.CommandIdentity:Data]
    let tokens: String
    let tasks: String
    let digests: String
    let workspaceAncestors: Set<String>
    let workspaceProtections: [Data:Data]

    init(_ db: Database,ids: Set<Data>,events: [String],commands: [(String,String)],needles: Set<Data>,pendingRequestTasks: Set<Data>,holdDigests: Set<Data>,filePaths: [String]) throws {
        var records: [Data:Record] = [:],history: [Data:Data] = [:],receipts: [MediaRoundDeletionHistory.CommandIdentity:Data] = [:]
        for id in ids {
            guard let seen = try Self.record(db,id:id) else {throw Self.changed("planned_record_missing",type:"record",id:id)}
            records[id] = seen
        }
        for value in events {
            let id = Data(value.utf8)
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(project_id,entity_id,actor,kind,occurred_at,data) AS BLOB) FROM events WHERE id=CAST(? AS TEXT)",arguments:[id]) else {throw Self.changed("planned_event_missing",type:"event",id:id)}
            history[id] = MediaPreparationOverlay.digest(data)
        }
        for (principal,value) in commands {
            let id = Data(value.utf8)
            guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(digest,result) AS BLOB) FROM commands WHERE principal=? AND command_id=CAST(? AS TEXT)",arguments:[principal,id]) else {throw Self.changed("planned_command_missing",type:"command",id:id)}
            receipts[.init(principal,value)] = MediaPreparationOverlay.digest(data)
        }
        self.records = records;self.events = history;self.commands = receipts
        tokens = try jsonString(needles.map {String(decoding:$0,as:UTF8.self)})
        tasks = try jsonString(pendingRequestTasks.map {String(decoding:$0,as:UTF8.self)})
        digests = try jsonString(holdDigests.map {String(decoding:$0,as:UTF8.self)})
        workspaceAncestors = CleanupWorkspaceProtection.pathAncestors(filePaths)
        workspaceProtections = try Self.protectingProjects(db,ancestors:workspaceAncestors)
    }
    static func protectingProjects(_ db: Database,ancestors: Set<String>) throws -> [Data:Data] {
        let paths = try CleanupWorkspaceProtection(db,ancestors:ancestors)
        return Dictionary(uniqueKeysWithValues:paths.signatures.map { signature in
            let separator = signature.lastIndex(of:0)!
            return (Data(signature[..<separator]),Data(signature[(separator + 1)...]))
        })
    }

    static func changed(_ check: String,type: String,id: Data) -> CoreError {
        CoreError("MEDIA_CONTEXT_CHANGED","A round record, deletion-plan row or relevant reference changed during preparation; no records changed.",details:["check":check,"record_type":type,"record_id":String(decoding:id,as:UTF8.self)])
    }

    func validate(_ db: Database,changes: MediaRoundDeletionChanges,writerVersion: Int64,afterVisibility: Bool = false) throws {
        try changes.validateObservation(db,writerVersion:writerVersion)
        guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM \(changes.name))") == true else {return}
        // Compare only changed project roots. Paths and the initial authority
        // were selected on the reader, and both lookups keep exact identities.
        let journal = try Row.fetchCursor(db,sql:"""
            SELECT kind,id,principal,CASE WHEN kind=0 THEN (
                SELECT CASE WHEN json_valid(r.data) THEN json_extract(r.data,'$.root_path') END
                  FROM records r WHERE r.id=CAST(entry.id AS TEXT) AND r.type='project'
            ) END AS workspace
            FROM \(changes.name) entry
            """)
        while let entry = try journal.next() {
            let id: Data = entry["id"], kind: Int = entry["kind"]
            switch kind {
            case 0:
                let root: String? = entry["workspace"]
                let workspace = root.flatMap {CleanupWorkspaceProtection.matchingWorkspace($0,ancestors:workspaceAncestors)}
                    .map {Data($0.utf8)}
                guard workspace == workspaceProtections[id] else {throw Self.changed("workspace_protection",type:"project",id:id)}
                guard let seen = records[id] else {continue}
                guard !afterVisibility, try Self.record(db,id:id) == seen else {
                    throw Self.changed("planned_record_changed",type:String(decoding:seen.type,as:UTF8.self),id:id)
                }
            case 1:
                guard let digest = events[id] else {continue}
                guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(project_id,entity_id,actor,kind,occurred_at,data) AS BLOB) FROM events WHERE id=CAST(? AS TEXT)",arguments:[id]),MediaPreparationOverlay.digest(data) == digest else {throw Self.changed("planned_event_changed",type:"event",id:id)}
            case 2:
                let principal: String = entry["principal"]
                guard let digest = commands[.init(principal:Data(principal.utf8),command:id)] else {continue}
                guard let data = try Data.fetchOne(db,sql:"SELECT CAST(json_array(digest,result) AS BLOB) FROM commands WHERE principal=? AND command_id=CAST(? AS TEXT)",arguments:[principal,id]),MediaPreparationOverlay.digest(data) == digest else {throw Self.changed("planned_command_changed",type:"command",id:id)}
            default: break
            }
        }
        // Match complete text atoms AND dictionary keys as in the preparation
        // stream. SQL keeps even a large unrelated changed row out of Swift.
        for (table,kind,key,payload) in [("records",0,"id","data"),("events",1,"id","data"),("commands",2,"command_id","result")] {
            let principal = kind == 2 ? " AND r.principal=c.principal" : ""
            let holds = kind == 0 ? " OR (r.type='storage_hold' AND CAST(token AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)))" : ""
            // Linked tickets only gate pending owner requests in preparation.
            // Their ordinary notes, events and receipts are not media references.
            let pending = kind == 0 ? " OR (r.type='request' AND json_extract(r.data,'$.state')='pending' AND CAST(json_extract(r.data,'$.task_id') AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)))" : ""
            let entity = kind == 1 ? " OR CAST(r.entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))" : ""
            var arguments: [DatabaseValueConvertible] = [tokens]
            if kind == 0 {arguments.append(digests);arguments.append(tasks)}
            if kind == 1 {arguments.append(tokens)}
            let sql = """
                SELECT CAST(r.\(key) AS BLOB) id,\(kind == 0 ? "r.type" : kind == 1 ? "'event'" : "'command'") type FROM \(changes.name) c JOIN \(table) r ON r.\(key)=CAST(c.id AS TEXT)\(principal)
                WHERE c.kind=\(kind) AND (NOT json_valid(r.\(payload)) OR EXISTS(
                    SELECT 1 FROM (SELECT j.atom token FROM json_tree(r.\(payload)) j WHERE j.type='text' UNION ALL SELECT j.key FROM json_tree(r.\(payload)) j WHERE typeof(j.key)='text')
                    WHERE CAST(token AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))\(holds))\(pending)\(entity)) LIMIT 1
                """
            if let row = try Row.fetchOne(db,sql:sql,arguments:StatementArguments(arguments)) {throw Self.changed("changed_reference",type:row["type"],id:row["id"])}
        }
    }
}
