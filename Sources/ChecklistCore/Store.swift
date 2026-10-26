import Foundation
import ChecklistProviders
import GRDB
import CryptoKit

public final class CommandRouter: @unchecked Sendable {
    let epicReferenceIndex = EpicReferenceIndex()
    let readSnapshotCache = ReadSnapshotCache()
    let dbQueue: DatabaseQueue
    /// Read-only connections for pure reads (CL-72). Nil when the store cannot open them;
    /// reads then use the writer path.
    let readers: DatabasePool?
    let cursorKey: SymmetricKey
    var lastRoutinePrune: Date?
    var workHealthScanPosition: Int64 = 0
    private let preparationLock = NSLock()
    let root: URL
    private let gateFiles: StorageObjectFiles
    let managedCapturePaths: [Data:String]
    let incarnation: String
    let providerPlugins: ProviderPluginRegistry
    let cliCommand: String
    let serviceLease: StorageServiceLease?
    let storageAdmission = StorageAdmission()
    var taskReferenceFrame: TaskReferenceFrame?
    var managedAttachmentPreparation: ManagedAttachmentPreparation?
    var managedImportRecoveryFailures: [Data:Int] = [:]
    var managedImportMaintenanceAfterRow: Int64 = 0
    var storageMaintenanceFallbackFailures = 0
    private let maintenanceStateLock = NSLock()
    private var routineRetry: Date?
    private var cleanupRetry: Date?
    private var cleanupYield: Date?
    var ticketCleanupLifecycleTurn = true // Serialized maintenance lane only.
    private var cleanupFailure: String?
    var storageMaintenanceRetryAt: Date? {
        get {maintenanceStateLock.withLock {routineRetry}}
        set {maintenanceStateLock.withLock {routineRetry = newValue}}
    }
    var ticketCleanupRetryAt: Date? {
        get {maintenanceStateLock.withLock {cleanupRetry}}
        set {maintenanceStateLock.withLock {cleanupRetry = newValue}}
    }
    var ticketCleanupYieldAt: Date? {
        get {maintenanceStateLock.withLock {cleanupYield}}
        set {maintenanceStateLock.withLock {cleanupYield = newValue}}
    }
    var ticketCleanupFailure: String? {
        get {maintenanceStateLock.withLock {cleanupFailure}}
        set {maintenanceStateLock.withLock {cleanupFailure = newValue}}
    }
    // Owned only by the serialized maintenance lane; retries a failed startup pool.
    var ticketCleanupReaders: DatabasePool?
    var ticketCleanupNeedsReader = false
    var ticketCleanupPreparingProject: String?
    let ticketCleanupMaintenanceLock = NSLock()
    // One command's prepared files (CL-71) and the captures it created (CL-70). Set and
    // cleared inside the serialized writer; preparation itself never reads them.
    private var preparationStorage = CommandPreparation()
    var commandPreparation: CommandPreparation {
        get { preparationLock.lock(); defer { preparationLock.unlock() }; return preparationStorage }
        set { preparationLock.lock(); preparationStorage = newValue; preparationLock.unlock() }
    }
    var inlineSourceCaptures: [PendingSourceCapture] = []
    var consumedSourceCaptures: Set<String> = []
    var exportPublications: [ExportPublication] = []
    public init(root: URL, serviceLease: StorageServiceLease? = nil, cliCommand: String = "/Applications/Checklist.app/Contents/MacOS/checklist", providerPlugins: ProviderPluginRegistry = .bundled) throws {
        let root = StoreDirectory.anchoredRoot(root)
        self.root = root
        self.serviceLease = serviceLease
        self.cliCommand = cliCommand
        self.providerPlugins = providerPlugins
        let opened: StorageBootstrap.Opened
        do { opened = try StorageBootstrap.open(root:root,serviceLease:serviceLease,prepareDatabase:Self.installTicketSearchFunctions) }
        catch { StoreRecovery.recordFailure(root:root,error:error);throw error }
        let gateFiles = try StorageObjectFiles(root:root,pinRootForGates:true)
        self.gateFiles = gateFiles
        self.managedCapturePaths = try opened.queue.read { try ManagedPathRelocation.captureBindings($0, root: root) }
        self.dbQueue = opened.queue
        self.incarnation = opened.incarnation
        self.cursorKey = (try? ArchiveStorageGate.withExclusive(root: root,files:gateFiles) { _ in try opened.queue.write { db in try SealedCursor.storeKey(db) } }) ?? SymmetricKey(size: .bits256)
        var readerConfiguration = Configuration()
        readerConfiguration.readonly = true
        readerConfiguration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db); try Self.installTicketSearchFunctions(db)
            try db.execute(sql:"PRAGMA busy_timeout=5000")
        }
        self.readers = try? DatabasePool(path: root.appendingPathComponent("checklist.sqlite").path, configuration: readerConfiguration)
        // Authority reconciliation must commit even when unrelated maintenance is broken.
        do {
            try ArchiveStorageGate.withExclusive(root: root,files:gateFiles) { _ in
                try dbQueue.write { db in try self.interruptSourceExecutionsAfterRestart(db) }
            }
        } catch {
            throw CoreError("RECOVERY_REQUIRED", "Cannot establish source-process restart fences. Preserve the store and reconcile recovery before work resumes.")
        }
        try storageAdmission.openAfterBootstrap()
        do {
            let startupLease = try storageAdmission.acquire()
            defer { startupLease.finish() }
            try ArchiveStorageGate.withExclusive(root: root,files:gateFiles) { permit in
                try dbQueue.writeWithoutTransaction { db in
                    // CL-70: files left by commands that never committed, before any new command.
                    try? self.sweepPendingSourceCaptures(db)
                    try? self.sweepPendingExports(db)
                    try? self.sweepAbandonedManagedImports(db)
                    _ = self.performStorageMaintenance(db, permit: permit)
                    _ = self.pruneRoutineRecordsIfDue(db)
                }
            }
        } catch {
            storageMaintenanceFallbackFailures = 2
            storageMaintenanceRetryAt = Date().addingTimeInterval(60)
        }
        try dbQueue.writeWithoutTransaction { try epicReferenceIndex.install($0) }
    }
    static let canonicalRecordColumns = "id,project_id,type,revision,data,CAST(id AS BLOB) AS _envelope_id_bytes,CAST(project_id AS BLOB) AS _envelope_project_id_bytes,CAST(type AS BLOB) AS _envelope_type_bytes,CAST(data AS BLOB) AS _envelope_data_bytes"
    // CASE guards every JSON operation. A foreign malformed payload is never
    // decoded/evaluated merely because SQL chooses another predicate order.
    static let sessionProjectCandidate = """
        (project_id = CAST(? AS TEXT) OR CASE WHEN json_valid(data) THEN
            CASE WHEN json_type(data,'$.project_ids')='array' THEN
                EXISTS(SELECT 1 FROM json_each(data,'$.project_ids') grant_project
                       WHERE grant_project.type='text' AND grant_project.value = CAST(? AS TEXT) COLLATE BINARY)
            ELSE 0 END ELSE 0 END)
        """
    func record(_ db: Database, _ id: String, type: String? = nil) throws -> JSON {
        let query = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id = CAST(? AS TEXT)" + (type == nil ? "" : " AND type = CAST(? AS TEXT)")
        let arguments = type.map { StatementArguments([Data(id.utf8), Data($0.utf8)]) } ?? StatementArguments([Data(id.utf8)])
        let values = try readSnapshotCache.records(db,key:["record",id,type]) {try Row.fetchAll(db,sql:query,arguments:arguments)}
        guard let value = values.first else { throw CoreError("NOT_FOUND", "This record is not available.") }
        return value
    }
    func records(_ db: Database, type: String, project: String? = nil) throws -> [JSON] {
        // The project catalog is small, but a type-only table scan touches every
        // large retained history payload on a cold store. Enumerate its rowids
        // from the existing narrow scope index, then load only those records.
        let catalog = type == "project" && project == nil
        var query = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE " + (catalog
            ? "rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type = CAST(? AS TEXT))"
            : "type = CAST(? AS TEXT)")
        var arguments: [DatabaseValueConvertible] = [Data(type.utf8)]
        if let project {
            if type == "session" { query += " AND " + Self.sessionProjectCandidate; arguments += [Data(project.utf8),Data(project.utf8)] }
            else { query += " AND project_id = CAST(? AS TEXT)"; arguments.append(Data(project.utf8)) }
        }
        return try readSnapshotCache.records(db,key:["records",type,project]) {
            try Row.fetchAll(db,sql:query + " ORDER BY rowid",arguments:StatementArguments(arguments))
        }
    }
    /// A pure read runs on a read-only connection; a write there asks for the writer path.
    func requireWriter(_ db: Database) throws {
        if db.configuration.readonly { throw CoreError("WRITER_REQUIRED", "This read needs the writer path.") }
    }
    func save(_ db: Database, _ value: JSON, type: String) throws {
        try requireWriter(db)
        let incoming = try GRDBRecordEnvelopeAdapter.incoming(value,type:type)
        guard case .text(let id) = incoming.id else { throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.jsonIdentity)) }
        let previous = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id = CAST(? AS TEXT)",arguments:[Data(id.utf8)])
        let envelope = try GRDBRecordEnvelopeAdapter.compareSave(incoming:incoming,previous:previous)
        guard case .text(let raw) = incoming.data else { throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData)) }
        let referenceWrite = try prepareTaskReferenceWrite(db,previous:previous,next:envelope)
        try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),?,CAST(? AS TEXT)) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,type=excluded.type,revision=excluded.revision,data=excluded.data",arguments:[Data(envelope.id.utf8),envelope.projectID.map { Data($0.utf8) },Data(envelope.type.utf8),envelope.revision,Data(raw.utf8)])
        recordTaskReferenceWrite(referenceWrite)
        if type == "task",let pid = envelope.projectID,let statusID = value["status_id"] as? String,
           let prior = previous.map({ jsonObject($0["data"]) }),prior["status_id"] as? String != statusID,
           (try? record(db,statusID,type:"status"))?["category"] as? String == "done" {
            // Commit a recovery wake with the Done transition. Startup or the
            // background pump admits the usual durable byte job; no unlink here.
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?, '0'), (?, '0')",arguments:["ticket-cleanup-cursor:" + pid,"ticket-cleanup-next:" + pid])
        }
    }
    func event(_ db: Database, caller: Caller, project: String?, entity: String?, kind: String, data: JSON = [:]) throws {
        try requireWriter(db)
        var data = data
        if Self.ticketStatusEventKinds.contains(kind), let entity, let task = try? record(db,entity,type:"task") {
            data["to_status_id"] = task["status_id"]
            data["actor_display"] = author(db,caller)
        }
        if let entity, let named = try? record(db,entity), named["title"] != nil || named["kind"] as? String == "triage" || named["kind"] as? String == "epic" {
            data["subject"] = ["id":entity,"key":named["key"] ?? NSNull(),"title":named["title"] ?? named["name"] ?? ""]
        }
        for field in ["triage_id","epic_id","from_epic_id","to_epic_id"] {
            if let id = data[field] as? String,let group = try? record(db,id,type:"group") { data[String(field.dropLast(3)) + "_key"] = group["key"] ?? "";data[String(field.dropLast(3)) + "_name"] = group["name"] ?? "" }
        }
        try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),?, ?,CAST(? AS TEXT))",arguments:[Data(uuid().utf8),project.map {Data($0.utf8)},entity.map {Data($0.utf8)},Data(caller.principal.utf8),kind,now(),Data((try jsonString(data)).utf8)])
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
        guard caller.isOwner || caller.projectIDs.contains(where: { EnvelopeStorageIdentity.equal($0,pid) }) else { throw CoreError("FORBIDDEN", "This project is outside the connection grant.") }
        let project = try record(db,pid,type:"project")
        try assistantPermission(caller,pid,"read")
        if !caller.isOwner,let sid = caller.sessionID {
            // A named session must exist in this project. A missing record fails closed;
            // it never skips the execution-domain check.
            let session: JSON
            do { session = try scoped(db,sid,pid,type:"session") }
            catch let error as CoreError where error.code == "NOT_FOUND" { throw CoreError("FORBIDDEN","This connection has no registered session in this project.") }
            guard !bool(session,"restore_quarantined") else {throw CoreError("CONNECTION_REVOKED","Restored sessions require fresh native identity revalidation.")}
            if session["execution_domain"] != nil || caller.executionDomain != nil {
                guard let domain = caller.executionDomain,session["execution_domain"] as? String == domain else { throw CoreError("FORBIDDEN","This connection does not match its verified host execution domain.") }
            }
        }
        if caller.role == "worker" {
            guard let path = caller.workspace, let root = project["root_path"] as? String, !root.isEmpty, containsPath(root,canonical(path)) else { throw CoreError("ROOT_MISMATCH", "The worker's actual workspace is not bound to this project.") }
        }
        if write && bool(project,"archived") { throw CoreError("PROJECT_ARCHIVED", "Restore the project before changing it.") }
        return pid
    }
    func scoped(_ db: Database, _ id: String, _ project: String, type: String) throws -> JSON {
        var query = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id = CAST(? AS TEXT) AND type = CAST(? AS TEXT) AND "
        var arguments: [DatabaseValueConvertible] = [Data(id.utf8),Data(type.utf8)]
        if type == "session" { query += Self.sessionProjectCandidate; arguments += [Data(project.utf8),Data(project.utf8)] }
        else { query += "project_id = CAST(? AS TEXT)"; arguments.append(Data(project.utf8)) }
        let values = try readSnapshotCache.records(db,key:["scoped",id,project,type]) {try Row.fetchAll(db,sql:query,arguments:StatementArguments(arguments))}
        guard let value = values.first else { throw CoreError("NOT_FOUND", "This record is not available in this project.") }
        return value
    }
    func task(_ db: Database, _ p: JSON, _ pid: String) throws -> JSON {
        if let id = p["task_id"] as? String ?? p["id"] as? String { return try scoped(db,id,pid,type:"task") }
        if let key = p["key"] as? String {
            let matches = try readSnapshotCache.records(db,key:["task-key",pid,key]) {
                try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='task' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.key')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid LIMIT 2",arguments:[Data(pid.utf8),Data(key.utf8)])
            }
            guard matches.count <= 1 else {throw CoreError("AMBIGUOUS_TASK","More than one ticket uses this display key. Select its stable internal ID.")}
            if let match = matches.first {return match}
        }
        throw CoreError("NOT_FOUND", "Select a task in this project.")
    }
    func author(_ db: Database, _ c: Caller) -> String {
        if c.isOwner { return "You" }
        if let sid = c.sessionID, let s = try? record(db,sid,type:"session") { return s["label"] as? String ?? c.role.capitalized }
        return c.role.capitalized
    }
    /// CL-72: a sealed cursor needs no stored row, so no method grows the cursors table.
    func cursor(_ db: Database, caller: Caller, scope: String, sequence specifiedSequence: Int? = nil) throws -> String {
        let sequence = try specifiedSequence ?? Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events") ?? 0
        return try SealedCursor.seal(sequence:sequence,created:Date().timeIntervalSince1970,binding:SealedCursor.binding(principal:caller.principal,scope:scope,incarnation:incarnation),key:cursorKey)
    }
    func cursorSequence(_ db: Database, _ p: JSON, caller: Caller, scope: String) throws -> Int {
        guard let token = p["cursor"] as? String else { return 0 }
        if token.hasPrefix(SealedCursor.prefix) {
            guard let sequence = SealedCursor.open(token,binding:SealedCursor.binding(principal:caller.principal,scope:scope,incarnation:incarnation),key:cursorKey) else { throw CoreError("CURSOR_RESET","Refresh this authorized view before continuing.") }
            return sequence
        }
        // A row issued before sealed cursors stays valid until it expires and is pruned.
        guard let row = try Row.fetchOne(db,sql:"SELECT sequence,created_at,typeof(principal) AS ptype,typeof(scope) AS stype,typeof(incarnation) AS itype,CAST(principal AS BLOB) AS pbytes,CAST(scope AS BLOB) AS sbytes,CAST(incarnation AS BLOB) AS ibytes FROM cursors WHERE token=CAST(? AS TEXT) COLLATE BINARY",arguments:[Data(token.utf8)]),
              row["ptype"] as String == "text",row["stype"] as String == "text",row["itype"] as String == "text",
              row["pbytes"] as Data == Data(caller.principal.utf8),row["sbytes"] as Data == Data(scope.utf8),row["ibytes"] as Data == Data(incarnation.utf8),
              case .int64(let sequence) = (row["sequence"] as DatabaseValue).storage,sequence >= 0,
              let created = Double.fromDatabaseValue(row["created_at"]),created.isFinite,
              Date().timeIntervalSince1970 >= created,Date().timeIntervalSince1970 - created < 86400 else {throw CoreError("CURSOR_RESET","Refresh this authorized view before continuing.")}
        return Int(sequence)
    }
    public func handle(method: String, params: [String: Any], caller: Caller) throws -> [String: Any] {
        // Validation, preparation and owner projection also bridge Foundation
        // objects outside the SQL callbacks. Bound their lifetime on this thread.
        try autoreleasepool {try handleCommand(method:method,params:params,caller:caller)}
    }
    private func handleCommand(method: String, params: [String: Any], caller: Caller) throws -> [String: Any] {
        guard ["owner","worker","assistant"].contains(caller.role), !caller.installation.isEmpty else { throw CoreError("FORBIDDEN", "An authenticated connection is required.") }
        guard let encoded = try? JSONSerialization.data(withJSONObject:params), encoded.count <= 2_000_000 else { throw CoreError("INVALID_INPUT", "Command input is too large or invalid.") }
        try validateInput(method,params,caller)
        // CL-116 native owner media boundary prepares outside the ordinary writer.
        if Self.mediaOwnerMethods.contains(method) {
            do {
                let value = try executeMediaOwnerChannel(method:method,params:params,caller:caller)
                var reply: JSON = ["data":value]
                if !Self.mediaOwnerReads.contains(method) {reply["command_id"] = params["command_id"]}
                return reply
            } catch let error as DatabaseError {
                if let command = params["command_id"] as? String {throw storageOutcomeFailure(error,command:command)}
                throw error
            }
        }
        let operationLease = try storageAdmission.acquire()
        defer { operationLease.finish() }
        if Self.storageRestoreMethods.contains(method) {return try executeStorageRestore(method:method,params:params,caller:caller)}
        if Self.projectImportMethods.contains(method) {return try executeProjectImport(method:method,params:params,caller:caller)}
        // CL-72: a pure read runs on a read-only connection, without the object gate or the
        // writer. A read that turns out to write (for example a first cleanup preview) runs
        // again on the writer path below.
        if Self.pureReadMethods.contains(method),let readers {
            do { return ownerManagedPathProjection(try executePureRead(readers,method:method,params:params,caller:caller),caller:caller) }
            catch let error where Self.needsWriter(error) {}
        }
        // A crash-left export reserves its intent before any command's file preparation.
        // The shared transaction guard checks it again under the object gate.
        if !Self.readMethods.contains(method),let command = params["command_id"] as? String {
            try ArchiveStorageGate.withExclusive(root:root,files:gateFiles) { _ in
                try requirePendingExportIntent(command:command,digest:hash(Data((method + (try jsonString(params))).utf8)),caller:caller)
            }
        }
        if method == "backup_create" {
            do { return try executeStorageBackup(params:params,caller:caller) }
            catch let error as DatabaseError {
                guard let command = params["command_id"] as? String else {throw error}
                throw storageOutcomeFailure(error,command:command)
            }
        }
        // CL-71: large file and git work runs before the object gate and the SQL writer.
        var preparation = try prepareCommandFiles(method:method,params:params,caller:caller)
        if method == "human_request_answer" { preparation.humanRequestFiles = try prepareHumanRequestAnswerFiles(params:params,caller:caller) }
        defer { finishHumanAnswerImportStages(preparation.humanRequestFiles?.imports.values.map(\.params) ?? [],caller:caller) }
        var createdCaptures = preparation.pending, publishedExports: [ExportPublication] = []
        defer { finishSourceCaptures(createdCaptures); finishExportPublications(publishedExports) }
        let managedImport: ManagedAttachmentPreparation?
        do { managedImport = try prepareManagedAttachmentImport(method:method,params:params,caller:caller,access:managedImportAccessOutsideWriter()) }
        catch {
            try? ArchiveStorageGate.withExclusive(root: root,files:gateFiles) { _ in try dbQueue.writeWithoutTransaction { db in try self.recordManagedImportPreparationFailure(db,method:method,params:params,caller:caller,error:error) } }
            throw error
        }
        return try ArchiveStorageGate.withExclusive(root: root,files:gateFiles) { permit in
        return try dbQueue.writeWithoutTransaction { db in try autoreleasepool {
            // Decode/encode temporaries belong to this command, including its
            // post-commit maintenance and notices. Drain on the writer's thread;
            // a pool on the calling service queue cannot guarantee that lifetime.
            self.commandPreparation = preparation; self.inlineSourceCaptures = []; self.consumedSourceCaptures = []; self.exportPublications = []
            defer { createdCaptures += self.inlineSourceCaptures; publishedExports += self.exportPublications; self.commandPreparation = CommandPreparation(); self.inlineSourceCaptures = []; self.consumedSourceCaptures = []; self.exportPublications = [] }
            if method == "export_project" {
                do { return try self.executeProjectExport(db,params,caller,permit:permit) }
                catch let error as DatabaseError {
                    guard let command = params["command_id"] as? String else { throw error }
                    throw self.storageOutcomeFailure(error,command:command)
                }
            }
            self.managedAttachmentPreparation = managedImport
            defer { self.managedAttachmentPreparation = nil }
            var output: JSON = [:]
            do { try self.withValidatedDomainTransaction(db) {
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
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                        guard (row["digest"] as String) == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID was already used with different input.") }
                        output = jsonObject(row["result"])
                        if Self.isPrunedResult(output) { throw Self.expiredCommandError(command) }
                        output["replayed"] = true
                        if ["work_claim","work_child_accept","work_handoff_accept","work_takeover"].contains(method),var d = output["data"] as? JSON,let aid = d["id"] as? String,var a = try? self.record(db,aid,type:"attempt"),a["state"] as? String == "active",a["principal"] as? String == caller.principal,a["incarnation"] as? String == self.incarnation,a["session_authorization_generation"] as? String == (try self.callerSessionGeneration(db,caller,project:a["project_id"] as! String)) {
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
            } } catch {
                // The failed read transaction has rolled back. Persist only its
                // bounded availability observation in a separate transaction.
                try? self.persistManagedAttachmentReadFailure(db,method:method,params:params,caller:caller,error:error)
                if let observation = error as? ManagedOriginalReadFailure { throw observation.failure }
                if let databaseError = error as? DatabaseError, let command = params["command_id"] as? String {
                    throw self.storageOutcomeFailure(databaseError,command:command)
                }
                throw error
            }
            // Unused-Epic deletion promises to preserve every unrelated row,
            // including on receipt replay. Defer ordinary maintenance to another
            // command or startup instead of coupling it to this narrow deletion.
            var maintenanceWarning: StorageMaintenanceWarning?
            if method != "epic_delete" {
                maintenanceWarning = self.performStorageMaintenance(db, permit: permit)
                _ = self.pruneRoutineRecordsIfDue(db)
            }
            do {output = try self.addingTicketObjectDeletionReceipt(db,output:output)}
            catch {maintenanceWarning = maintenanceWarning ?? .retryPending}
            // Dynamic recipient notices are not part of the durable command outcome.
            // Replayed commands observe current pending deliveries without replaying an answer.
            do { output = try self.addingHumanAnswerNotices(db,output:output,params:params,caller:caller) }
            catch { output = self.addingHumanAnswerNoticeFailure(output,caller:caller) }
            return self.ownerManagedPathProjection(self.addingStorageMaintenanceNotice(output, warning: maintenanceWarning),caller:caller)
        }}
    }
    }
    /// Closes the read-only connections before the writer, so the writer's close can
    /// checkpoint the WAL as the store's last connection.
    public func closeStore() throws {
        epicReferenceIndex.stop()
        try ticketCleanupReaders?.close()
        try readers?.close()
        try dbQueue.close()
    }
    /// Every read method starts on the read-only connections (finding 2a41447f). A read that
    /// writes (an owner's original read issues a reader hold; an availability repair or a
    /// cleanup preview saves a record) or a failed managed-original read, whose observation
    /// must be recorded, runs again on the writer path.
    static let pureReadMethods: Set<String> = readMethods
    static func needsWriter(_ error: Error) -> Bool {
        if error is ManagedOriginalReadFailure { return true }
        if let error = error as? CoreError { return ["WRITER_REQUIRED","DOMAIN_TRANSACTION_REQUIRED"].contains(error.code) }
        if let error = error as? DatabaseError { return error.resultCode == .SQLITE_READONLY }
        return false
    }
    func executePureRead(_ readers: DatabasePool,method: String,params: [String: Any],caller: Caller) throws -> [String: Any] {
        try readers.read { db in try readSnapshotCache.withSnapshot(db,caller:caller) {
            if !caller.isOwner,let pid = params["project_id"] as? String {
                _ = try self.scope(db,["project_id":pid],caller)
                if caller.role == "assistant" { try self.assistantPermission(caller,pid,["message_ack","assistant_inbox"].contains(method) ? "receive_messages" : "read") }
            }
            let data = try self.dispatch(db,method:method,p:params,c:caller)
            var output: JSON = ["data":data,"event_cursor":try self.cursor(db,caller:caller,scope:try self.authorizationScope(db,caller))]
            do { output = try self.addingHumanAnswerNotices(db,output:output,params:params,caller:caller) }
            catch { output = self.addingHumanAnswerNoticeFailure(output,caller:caller) }
            return output
        }}
    }
    /// CL-70: after the command, a capture that a committed record names loses only its
    /// marker; any other capture this command wrote is removed.
    func finishSourceCaptures(_ captures: [PendingSourceCapture]) {
        guard !captures.isEmpty else { return }
        try? dbQueue.read { db in _ = self.discardUncommittedSourceCaptures(db, captures) }
    }
    static let readMethods: Set<String> = mediaOwnerReads.union(["import_preview","import_receipt_get","restore_preview","ticket_cleanup_receipts","work_health_get","cleanup_job_get","cleanup_job_list","workspace_page","service_info","tool_catalog","snapshot","changes_wait","delivery_pending","storage_status","diagnostics_summary","project_list","project_resolve","project_settings_get","policy_get","taxonomy_get","task_get","task_list","task_context","session_list","session_inbox","assistant_inbox","assistant_projects","message_delivery_list","history_list","attachment_list","attachment_read","attachment_cleanup_preview","agent_resolve","triage_list","epic_list","development_status","policy_preview","relation_list","review_batch_inputs","batch_get","batch_list","source_execution_get","review_prepare","review_context"])
}
