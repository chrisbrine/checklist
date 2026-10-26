import Foundation
import GRDB

public final class CommandRouter: @unchecked Sendable {
    let dbQueue: DatabaseQueue
    let root: URL
    let incarnation: String
    var storageMaintenanceFallbackFailures = 0
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("objects"), withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 5000;") }
        self.dbQueue = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: config)
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, project_id TEXT, type TEXT NOT NULL, revision INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS records_scope ON records(project_id,type);
            CREATE TABLE IF NOT EXISTS commands(principal TEXT NOT NULL, command_id TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(principal,command_id));
            CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, project_id TEXT, entity_id TEXT, actor TEXT NOT NULL, kind TEXT NOT NULL, occurred_at TEXT NOT NULL, data TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS events_scope ON events(project_id,entity_id,seq);
            CREATE TABLE IF NOT EXISTS cursors(token TEXT PRIMARY KEY, principal TEXT NOT NULL, scope TEXT NOT NULL, sequence INTEGER NOT NULL, incarnation TEXT NOT NULL, created_at REAL NOT NULL);
            """)
            if try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'incarnation'") == nil {
                try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('incarnation',?)", arguments: [uuid()])
            }
        }
        self.incarnation = try dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'")! }
        // Authority reconciliation must commit even when unrelated maintenance is broken.
        do {
            try dbQueue.write { db in try self.interruptSourceExecutionsAfterRestart(db) }
        } catch {
            throw CoreError("RECOVERY_REQUIRED", "Cannot establish source-process restart fences. Preserve the store and reconcile recovery before work resumes.")
        }
        dbQueue.writeWithoutTransaction { db in _ = self.performStorageMaintenance(db) }
    }
    func record(_ db: Database, _ id: String, type: String? = nil) throws -> JSON {
        guard let row = try Row.fetchOne(db, sql: "SELECT type,data FROM records WHERE id=?", arguments: [id]), type == nil || (row["type"] as String) == type else { throw CoreError("NOT_FOUND", "This record is not available.") }
        return jsonObject(row["data"])
    }
    func records(_ db: Database, type: String, project: String? = nil) throws -> [JSON] {
        let rows = try Row.fetchAll(db, sql: "SELECT data FROM records WHERE type=?" + (project == nil || type == "session" ? "" : " AND project_id=?") + " ORDER BY rowid", arguments: project != nil && type != "session" ? [type, project!] : [type])
        return rows.map { jsonObject($0["data"]) }.filter { project == nil || type != "session" || strings($0,"project_ids").contains(project!) || $0["project_id"] as? String == project }
    }
    func save(_ db: Database, _ value: JSON, type: String) throws {
        try db.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,type=excluded.type,revision=excluded.revision,data=excluded.data", arguments: [value["id"] as? String, value["project_id"] as? String, type, int(value, "revision", default: 1), try jsonString(value)])
    }
    func event(_ db: Database, caller: Caller, project: String?, entity: String?, kind: String, data: JSON = [:]) throws {
        try db.execute(sql: "INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES (?,?,?,?,?,?,?)", arguments: [uuid(),project,entity,caller.principal,kind,now(),try jsonString(data)])
    }
    func revised(_ record: JSON) -> JSON { var r = record; r["revision"] = int(r,"revision") + 1; r["updated_at"] = now(); return r }
    func revision(_ p: JSON, _ r: JSON) throws {
        guard p["expected_revision"] != nil else { throw CoreError("REVISION_REQUIRED", "Read the current record before editing it.") }
        guard int(p,"expected_revision") == int(r,"revision") else { throw CoreError("REVISION_CONFLICT", "This record changed. Review the current version before saving.", details: ["current_revision": int(r,"revision")]) }
    }
    func owner(_ caller: Caller) throws { guard caller.isOwner else { throw CoreError("HUMAN_CHANNEL_REQUIRED", "This operation requires the authenticated app channel.") } }
    func worker(_ caller: Caller) throws { guard caller.role == "worker" || caller.isOwner else { throw CoreError("FORBIDDEN", "Assistant connections cannot handle work or change workflow rules.") } }
    func scope(_ db: Database, _ p: JSON, _ caller: Caller, write: Bool = false) throws -> String {
        let pid = try text(p,"project_id",max:100)
        guard caller.isOwner || caller.projectIDs.contains(pid) else { throw CoreError("FORBIDDEN", "This project is outside the connection grant.") }
        let project = try record(db,pid,type:"project")
        try assistantPermission(caller,pid,"read")
        if !caller.isOwner,let sid = caller.sessionID,let session = try? scoped(db,sid,pid,type:"session"),session["execution_domain"] != nil || caller.executionDomain != nil {
            guard let domain = caller.executionDomain,session["execution_domain"] as? String == domain else { throw CoreError("FORBIDDEN","This connection does not match its verified host execution domain.") }
        }
        if caller.role == "worker" {
            guard let path = caller.workspace, let root = project["root_path"] as? String, !root.isEmpty, containsPath(root,canonical(path)) else { throw CoreError("ROOT_MISMATCH", "The worker's actual workspace is not bound to this project.") }
        }
        if write && bool(project,"archived") { throw CoreError("PROJECT_ARCHIVED", "Restore the project before changing it.") }
        return pid
    }
    func scoped(_ db: Database, _ id: String, _ project: String, type: String) throws -> JSON {
        let r = try record(db,id,type:type)
        guard (r["project_id"] as? String) == project || (type == "session" && strings(r,"project_ids").contains(project)) else { throw CoreError("NOT_FOUND", "This record is not available in this project.") }
        return r
    }
    func task(_ db: Database, _ p: JSON, _ pid: String) throws -> JSON {
        if let id = p["task_id"] as? String ?? p["id"] as? String { return try scoped(db,id,pid,type:"task") }
        if let key = p["key"] as? String, let match = try records(db,type:"task",project:pid).first(where: { ($0["key"] as? String) == key }) { return match }
        throw CoreError("NOT_FOUND", "Select a task in this project.")
    }
    func author(_ db: Database, _ c: Caller) -> String {
        if c.isOwner { return "You" }
        if let sid = c.sessionID, let s = try? record(db,sid,type:"session") { return s["label"] as? String ?? c.role.capitalized }
        return c.role.capitalized
    }
    func cursor(_ db: Database, caller: Caller, scope: String, sequence specifiedSequence: Int? = nil) throws -> String {
        let token = uuid() + uuid()
        let sequence = try specifiedSequence ?? Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events") ?? 0
        try db.execute(sql:"INSERT INTO cursors(token,principal,scope,sequence,incarnation,created_at) VALUES (?,?,?,?,?,?)",arguments:[token,caller.principal,scope,sequence,incarnation,Date().timeIntervalSince1970])
        return token
    }
    func cursorSequence(_ db: Database, _ p: JSON, caller: Caller, scope: String) throws -> Int {
        guard let token = p["cursor"] as? String else { return 0 }
        guard let row = try Row.fetchOne(db,sql:"SELECT * FROM cursors WHERE token=?",arguments:[token]), (row["principal"] as String) == caller.principal, (row["scope"] as String) == scope, (row["incarnation"] as String) == incarnation, Date().timeIntervalSince1970 - (row["created_at"] as Double) < 86400 else { throw CoreError("CURSOR_RESET", "Refresh this authorized view before continuing.") }
        return row["sequence"]
    }
    public func handle(method: String, params: [String: Any], caller: Caller) throws -> [String: Any] {
        guard ["owner","worker","assistant"].contains(caller.role), !caller.installation.isEmpty else { throw CoreError("FORBIDDEN", "An authenticated connection is required.") }
        guard let encoded = try? JSONSerialization.data(withJSONObject:params), encoded.count <= 2_000_000 else { throw CoreError("INVALID_INPUT", "Command input is too large or invalid.") }
        try validateInput(method,params,caller)
        return try dbQueue.writeWithoutTransaction { db in
            var output: JSON = [:]
            try db.inTransaction {
                if !caller.isOwner,let pid = params["project_id"] as? String {
                    _ = try self.scope(db,["project_id":pid],caller)
                    if caller.role == "assistant" {
                        let permission = method == "task_create" ? "create_drafts_on_request" : (["message_send","agent_message_send","attachment_add","attachment_update","agent_resolve"].contains(method) ? "post_notes_on_request" : (["message_ack","assistant_inbox"].contains(method) ? "receive_messages" : "read"))
                        try self.assistantPermission(caller,pid,permission)
                    }
                }
                let writes = !Self.readMethods.contains(method)
                var command = ""
                var digest = ""
                if writes {
                    command = try text(params,"command_id",max:100)
                    guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT", "command_id must be a UUID.") }
                    digest = hash(Data((method + (try jsonString(params))).utf8))
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                        guard (row["digest"] as String) == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID was already used with different input.") }
                        output = jsonObject(row["result"]); output["replayed"] = true
                        if ["work_claim","work_child_accept","work_handoff_accept"].contains(method),var d = output["data"] as? JSON,let aid = d["id"] as? String,var a = try? self.record(db,aid,type:"attempt"),a["state"] as? String == "active",a["principal"] as? String == caller.principal,a["incarnation"] as? String == self.incarnation,a["session_authorization_generation"] as? String == (try self.callerSessionGeneration(db,caller,project:a["project_id"] as! String)) {
                            let token = uuid()+uuid(); a["token_hash"] = hash(Data(token.utf8)); try self.save(db,a,type:"attempt"); d["claim_token"] = token; output["data"] = d
                        }
                        if method == "batch_claim",let data = output["data"] as? JSON { output["data"] = try self.replayBatchClaims(db,data,caller) }
                        return .commit
                    }
                }
                let membershipBefore = Self.triageStatusMethods.contains(method) && params["project_id"] is String ? try self.currentTriageMemberships(db,project:params["project_id"] as! String) : []
                var data = try self.dispatch(db,method:method,p:params,c:caller)
                if Self.triageStatusMethods.contains(method),let pid = params["project_id"] as? String { data["triage_effect"] = try self.triageCommandEffect(db,before:membershipBefore,project:pid,method:method) }
                output = ["data":data,"event_cursor":try self.cursor(db,caller:caller,scope:try self.authorizationScope(db,caller))]
                if writes {
                    output["command_id"] = command
                    var durable = output
                    if var d = durable["data"] as? JSON { d.removeValue(forKey:"claim_token"); durable["data"] = self.redactBatchClaims(d) }
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,digest,try jsonString(durable)])
                }
                return .commit
            }
            let maintenanceWarning = self.performStorageMaintenance(db)
            // Dynamic recipient notices are not part of the durable command outcome.
            // Replayed commands observe current pending deliveries without replaying an answer.
            do { output = try self.addingHumanAnswerNotices(db,output:output,params:params,caller:caller) }
            catch { output = self.addingHumanAnswerNoticeFailure(output,caller:caller) }
            return self.addingStorageMaintenanceNotice(output, warning: maintenanceWarning)
        }
    }
    static let readMethods: Set<String> = ["service_info","tool_catalog","snapshot","changes_wait","delivery_pending","storage_status","diagnostics_summary","project_list","project_resolve","project_settings_get","policy_get","taxonomy_get","task_get","task_list","task_context","session_list","session_inbox","assistant_inbox","assistant_projects","history_list","attachment_list","attachment_read","attachment_cleanup_preview","agent_resolve","triage_list","epic_list","development_status","policy_preview","relation_list","batch_get","batch_list","source_execution_get","review_prepare","review_context"]
}
