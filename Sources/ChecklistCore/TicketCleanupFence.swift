import Foundation
import GRDB

/// A per-attempt TEMP index on the sole writer. Transactional triggers index only
/// writes made during preparation, including direct SQL and deletions. Unrelated
/// write volume consumes no retained Swift graph. A fixed TEMP budget fails
/// closed rather than retaining an unbounded change/reference journal.
/// TEMP storage is connection-local/rebuildable, not a durable schema migration.
struct TicketCleanupChanges {
    static let rowLimit = 32768
    static let byteLimit = 8 * 1024 * 1024
    static func install(_ db: Database) throws {
        try db.execute(sql:"""
            CREATE TEMP TABLE ticket_cleanup_changes(kind INTEGER,position INTEGER,id BLOB,project BLOB,type TEXT,PRIMARY KEY(kind,position,id)) WITHOUT ROWID;
            CREATE INDEX temp.ticket_cleanup_changed_id ON ticket_cleanup_changes(kind,id);
            CREATE INDEX temp.ticket_cleanup_changed_type ON ticket_cleanup_changes(type);
            CREATE TEMP TABLE ticket_cleanup_edges(target BLOB,held INTEGER,PRIMARY KEY(target,held)) WITHOUT ROWID;
            CREATE TEMP TABLE ticket_cleanup_uncertain(reason TEXT PRIMARY KEY) WITHOUT ROWID;
            """)
        try db.execute(sql:"CREATE TEMP TABLE ticket_cleanup_budget(units INTEGER,bytes INTEGER); INSERT INTO ticket_cleanup_budget VALUES(0,0)")
        for (table,key,size) in [("edges","target=NEW.target AND held=NEW.held","length(NEW.target)"),
                                 ("changes","kind=NEW.kind AND position=NEW.position AND id=NEW.id","length(NEW.id)+COALESCE(length(NEW.project),0)+COALESCE(length(NEW.type),0)")] {
            let exceeded = "units>=\(rowLimit) OR bytes+(\(size))>\(byteLimit)"
            try db.execute(sql:"""
                CREATE TEMP TRIGGER ticket_cleanup_bound_\(table) BEFORE INSERT ON ticket_cleanup_\(table)
                WHEN NOT EXISTS(SELECT 1 FROM ticket_cleanup_\(table) WHERE \(key)) BEGIN
                    INSERT INTO ticket_cleanup_uncertain SELECT 'change index budget' FROM ticket_cleanup_budget WHERE \(exceeded) ON CONFLICT DO NOTHING;
                    SELECT RAISE(IGNORE) FROM ticket_cleanup_budget WHERE \(exceeded);
                END;
                CREATE TEMP TRIGGER ticket_cleanup_count_\(table) AFTER INSERT ON ticket_cleanup_\(table) BEGIN
                    UPDATE ticket_cleanup_budget SET units=units+1,bytes=bytes+(\(size));
                END;
                """)
        }
        for (table,kind,id,payload) in [("records",0,"id","data"),("events",1,"id","data"),("commands",2,"command_id","result"),("metadata",3,"key","value")] {
            for action in ["INSERT","UPDATE","DELETE"] {
                let aliases = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"]
                var sql = ""
                for row in aliases {
                    let project = kind < 2 ? "CAST(\(row).project_id AS BLOB)" : "NULL"
                    let type = kind == 0 ? "\(row).type" : "NULL"
                    sql += "INSERT INTO ticket_cleanup_changes VALUES(\(kind),\(row).rowid,CAST(\(row).\(id) AS BLOB),\(project),\(type)) ON CONFLICT DO NOTHING;"
                }
                if action != "DELETE",kind < 3 {
                    let valid = "typeof(NEW.\(payload))='text' AND length(CAST(NEW.\(payload) AS BLOB))<=1048576 AND json_valid(NEW.\(payload))"
                    let json = "CASE WHEN \(valid) THEN NEW.\(payload) ELSE '{}' END"
                    // An unchanged reference in project policy is already in the
                    // snapshot. Counter-only updates must not reintroduce it as a
                    // new hold. Selected record identities remain guarded above.
                    let prior = kind == 0 && action == "UPDATE" ? "CASE WHEN NEW.type='project' AND OLD.type='project' AND json_valid(OLD.data) THEN OLD.data ELSE '{}' END" : "'{}'"
                    sql += """
                        INSERT INTO ticket_cleanup_uncertain SELECT 'changed payload limit or invalid JSON' WHERE NOT (\(valid)) ON CONFLICT DO NOTHING;
                        INSERT INTO ticket_cleanup_edges
                        SELECT target,\(kind == 0 ? "CASE WHEN NEW.type='storage_hold' THEN 1 ELSE 0 END" : "0") FROM (
                            SELECT CAST(j.atom AS BLOB) target FROM json_tree(\(json)) j WHERE j.type='text'
                            UNION SELECT CAST(j.key AS BLOB) FROM json_tree(\(json)) j WHERE typeof(j.key)='text'
                            EXCEPT SELECT CAST(j.atom AS BLOB) FROM json_tree(\(prior)) j WHERE j.type='text'
                            EXCEPT SELECT CAST(j.key AS BLOB) FROM json_tree(\(prior)) j WHERE typeof(j.key)='text'
                        ) WHERE true ON CONFLICT DO NOTHING;
                        """
                    if kind == 1 {sql += "INSERT INTO ticket_cleanup_edges SELECT CAST(NEW.entity_id AS BLOB),0 WHERE NEW.entity_id IS NOT NULL ON CONFLICT DO NOTHING;"}
                }
                try db.execute(sql:"CREATE TEMP TRIGGER ticket_cleanup_\(table)_\(action.lowercased()) AFTER \(action) ON main.\(table) BEGIN " + sql + " END")
            }
        }
    }
    static func remove(_ db: Database) throws {
        for table in ["records","events","commands","metadata"] {
            for action in ["insert","update","delete"] {try db.execute(sql:"DROP TRIGGER IF EXISTS temp.ticket_cleanup_\(table)_\(action)")}
        }
        try db.execute(sql:"DROP TABLE IF EXISTS temp.ticket_cleanup_edges; DROP TABLE IF EXISTS temp.ticket_cleanup_changes; DROP TABLE IF EXISTS temp.ticket_cleanup_uncertain; DROP TABLE IF EXISTS temp.ticket_cleanup_budget")
    }
}

struct TicketCleanupFence {
    var inventory: TicketCleanupInventory
    var recordIDs: Set<Data>
    var events: Set<Int64>
    var commands: Set<Int64>
    let projectID: String
    let projectSettings: String
    let workspaceRoots: String
    init(_ db: Database,inventory: TicketCleanupInventory,project: String,ids: [String],events: [Row] = [],commands: [Row] = []) throws {
        self.inventory = inventory;projectID = project
        recordIDs = Set((inventory.rows.filter {$0.type != "project"}.map(\.id) + ids.filter {$0 != project}).map {Data($0.utf8)})
        workspaceRoots = try Self.roots(db)
        projectSettings = try String.fetchOne(db,sql:"SELECT json_quote(json_extract(data,'$.ticket_cleanup')) FROM records WHERE id=CAST(? AS TEXT) AND type='project'",arguments:[Data(project.utf8)]) ?? "missing"
        self.events = Set(events.map {$0["seq"] as Int64})
        self.commands = Set(commands.map {$0["cleanup_row"] as Int64})
    }
    private static func roots(_ db: Database) throws -> String {
        let projects = try Row.fetchAll(db,sql:"SELECT CAST(id AS BLOB) AS id,json_quote(json_extract(data,'$.root_path')) AS root FROM records WHERE type='project' ORDER BY CAST(id AS BLOB)")
        return try jsonString(projects.map {["id":($0["id"] as Data).base64EncodedString(),"root":$0["root"] as String]})
    }
    func validate(_ db: Database) throws {
        func refuse(_ source: String) throws -> Never {throw CoreError("CLEANUP_CONCURRENT_WRITE","Fenced by concurrent write to " + source + "; bytes retained.",details:["reason":"fenced by concurrent write to " + source])}
        if let reason = try String.fetchOne(db,sql:"SELECT reason FROM ticket_cleanup_uncertain LIMIT 1") {try refuse(reason)}
        let ids = try jsonString(["values":recordIDs.map {String(decoding:$0,as:UTF8.self)}])
        if let row = try Row.fetchOne(db,sql:"SELECT id,project FROM ticket_cleanup_changes WHERE kind=0 AND id IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')) LIMIT 1",arguments:[ids]) {
            let id: Data = row["id"],scope: Data? = row["project"]
            try refuse(scope == Data(projectID.utf8) ? "record " + String(decoding:id,as:UTF8.self) : "foreign reference or authority")
        }
        let needles = try jsonString(["values":inventory.needles.map {String(decoding:$0,as:UTF8.self)}])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_edges WHERE target IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')))",arguments:[needles]) == true {try refuse("selected reference or hold")}
        let digests = try jsonString(["values":inventory.holdDigests.map {String(decoding:$0,as:UTF8.self)}])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_edges e WHERE e.held=1 AND e.target IN (SELECT CAST(value AS BLOB) FROM json_each(?,'$.values')))",arguments:[digests]) == true {try refuse("selected digest hold")}
        for prefix in inventory.prefixes {
            if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_edges WHERE target>=? AND target<?)",arguments:[Data((prefix + "/").utf8),Data((prefix + "0").utf8)]) == true {try refuse("selected object path reference")}
        }
        for (kind,positions) in [(1,events),(2,commands)] where !positions.isEmpty {
            let values = try jsonString(["values":Array(positions)])
            if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE kind=? AND position IN (SELECT value FROM json_each(?,'$.values')))",arguments:[kind,values]) == true {try refuse("selected history or command receipt")}
        }
        // Project counters/revision/timestamps are not cleanup authority. Roots
        // protect workspace files across ALL projects; only this project's
        // ticket_cleanup value controls its lifecycle policy.
        let settings = try String.fetchOne(db,sql:"SELECT json_quote(json_extract(data,'$.ticket_cleanup')) FROM records WHERE id=CAST(? AS TEXT) AND type='project'",arguments:[Data(projectID.utf8)]) ?? "missing"
        if settings != projectSettings {try refuse("project cleanup settings")}
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE type='project')") == true {
            if try Self.roots(db) != workspaceRoots {try refuse("project workspace roots")}
        }
        let authority = MediaRecordRegistry.families.sorted()
        let types = try jsonString(["values":authority])
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE type IN (SELECT value FROM json_each(?,'$.values')))",arguments:[types]) == true {try refuse("project or media authority")}
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE kind=3 AND (CAST(id AS TEXT) GLOB 'backup-generation:*' OR id=CAST('store_identity' AS BLOB) OR id=CAST(? AS BLOB) OR id=CAST(? AS BLOB)))",arguments:["ticket-cleanup-cursor:" + projectID,"ticket-cleanup-next:" + projectID]) == true {try refuse("storage metadata")}
    }
}
protocol TicketCleanupPrepared {
    var fence: TicketCleanupFence {get}
}
