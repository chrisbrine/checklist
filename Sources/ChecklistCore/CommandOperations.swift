import Foundation
import Dispatch
import Darwin
import GRDB

/// Scheduling state is process-local. Acceptance lives in durable journals;
/// terminal state is canonical in SQLite. Successful replies live exclusively
/// in the ordinary command journal.
/// The service supplies its own concurrent command-operation queue, separate from
/// storage maintenance. In-process domain callers may
/// keep the synchronous router without installing a service scheduler.
final class CommandOperations: @unchecked Sendable {
    struct Job: @unchecked Sendable {
        let attempt = UUID()
        let id: String
        let params: Data
        let method: String
        let caller: Caller
        let generation: String?
        let lease: StorageOperationLease
    }
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var jobs: [String:Job] = [:]
    private var scheduled = Set<String>()
    private var recoveryRequired = Set<String>()
    private var executing = Set<String>()
    private var admissions: [String:(mutex: NSLock,users: Int)] = [:]
    private var completion: (@Sendable (String,Bool) -> Void)?
    /// A read operation's finished reply waits here, in process memory only,
    /// until backup write admission opens for its terminal-state write (CL-353 F1).
    struct Outcome {
        let output: JSON?
        let failure: CoreError?
        let purgeEpoch: String?
        let startedAt: String
    }
    private var held: [String:(attempt: UUID,outcome: Outcome)] = [:]
    /// Capture-time acceptance uses the existing private queue directory because
    /// SQLite's source writer lease is intentionally unavailable. A canonical
    /// record supersedes this metadata only when it advances beyond baseHash.
    private struct StagedAdmission {
        let operation: JSON
        let baseHash: String?
    }
    private var stagedAdmissions: [String:StagedAdmission] = [:]
    private static func admissionPath(_ id: String) -> String {"backup-write-queue/operation-" + id + ".intent"}
    func stagedAdmission(_ id: String,canonical: String?) -> JSON? {
        guard let staged = lock.withLock({stagedAdmissions[id]}) else {return nil}
        guard staged.baseHash == canonical.map({hash(Data($0.utf8))}) else {return nil}
        return staged.operation
    }
    var stagedAdmissionIDs: [String] {lock.withLock {Array(stagedAdmissions.keys)}}
    func stageAdmission(_ operation: JSON,baseHash: String?,root: URL) throws {
        let id = operation["operation_id"] as! String
        var envelope: JSON = ["root":root.path,"operation":operation]
        envelope["base_sha256"] = baseHash
        let bytes = Data((try jsonString(envelope)).utf8)
        guard bytes.count <= 2_000_000 else {throw StoreRecovery.required("command_operation_admission_invalid")}
        let files = try StorageObjectFiles(root:root),temporary = "backup-write-queue/.pending-" + uuid()
        try files.writeNew(temporary,bytes:bytes)
        let (directory,name) = try files.parent(Self.admissionPath(id))
        defer {Darwin.close(directory)}
        let temporaryName = String(temporary.split(separator:"/").last!)
        // Same-principal/UUID admission is already serialized. Replacement is
        // needed for a new recovery attempt after an earlier cleanup failure.
        guard renameat(directory,temporaryName,directory,name) == 0,fsync(directory) == 0 else {throw StorageSnapshotFailure.io}
        lock.withLock {stagedAdmissions[id] = StagedAdmission(operation:operation,baseHash:baseHash)}
    }
    func restoreAdmissions(root: URL,incarnation: String,validate: (JSON,String) throws -> Void) throws {
        let files = try StorageObjectFiles(root:root)
        guard try files.directoryExists("backup-write-queue") else {return}
        for name in try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("backup-write-queue").path) where name.hasPrefix("operation-") {
            guard name.range(of:"^operation-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.intent$",options:.regularExpression) != nil else {throw StoreRecovery.required("command_operation_admission_invalid")}
            let id = String(name.dropFirst("operation-".count).dropLast(".intent".count))
            let bytes = try files.read("backup-write-queue/" + name,maximum:2_000_000)
            guard let envelope = try JSONSerialization.jsonObject(with:bytes) as? JSON,
                  EnvelopeStorageIdentity.equal(envelope["root"] as? String,root.path),
                  let operation = envelope["operation"] as? JSON,operation["operation_id"] as? String == id,
                  EnvelopeStorageIdentity.equal(operation["incarnation"] as? String,incarnation),
                  envelope["base_sha256"] == nil || (envelope["base_sha256"] as? String)?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw StoreRecovery.required("command_operation_admission_invalid")}
            try validate(operation,id)
            lock.withLock {stagedAdmissions[id] = StagedAdmission(operation:operation,baseHash:envelope["base_sha256"] as? String)}
        }
    }
    /// Canonical state was committed first. A failed retirement is harmless:
    /// startup compares the base hash and keeps the advanced canonical record.
    func retireAdmission(_ id: String,root: URL) {
        guard lock.withLock({stagedAdmissions[id] != nil}) else {return}
        do {
            let files = try StorageObjectFiles(root:root),(directory,name) = try files.parent(Self.admissionPath(id))
            defer {Darwin.close(directory)}
            guard (unlinkat(directory,name,0) == 0 || errno == ENOENT),fsync(directory) == 0 else {throw StorageSnapshotFailure.io}
            lock.withLock {_ = stagedAdmissions.removeValue(forKey:id)}
        } catch {StoreRecovery.recordFailure(root:root,error:error)}
    }
    private var probe: ((String) -> Void)?
    let contextKey = "ChecklistCommandOperation-" + UUID().uuidString

    /// Serialize only matching caller/UUID admissions across the SQLite and
    /// legacy backup FIFO journals. Never hold the FIFO condition over SQL.
    func withAdmission<T>(principal: String,command: String?,_ body: () throws -> T) rethrows -> T {
        guard let command else {return try body()}
        let key = principal + "\0" + command
        let mutex = lock.withLock {
            let entry = admissions[key] ?? (mutex:NSLock(),users:0)
            admissions[key] = (entry.mutex,entry.users + 1)
            return entry.mutex
        }
        mutex.lock()
        defer {
            mutex.unlock()
            lock.withLock {
                if let entry = admissions[key],entry.users > 1 {admissions[key] = (entry.mutex,entry.users - 1)}
                else {admissions.removeValue(forKey:key)}
            }
        }
        return try body()
    }
    func beginExecution(_ id: String) {lock.withLock {_ = executing.insert(id)}}
    func endExecution(_ id: String) {lock.withLock {_ = executing.remove(id)}}
    func isExecuting(_ id: String) -> Bool {lock.withLock {executing.contains(id)}}
    /// True while this process executes the operation or holds its finished
    /// read reply for the terminal-state write.
    func isActive(_ id: String) -> Bool {lock.withLock {executing.contains(id) || held[id] != nil}}
    func heldOutcome(_ job: Job) -> Outcome? {lock.withLock {held[job.id].flatMap {$0.attempt == job.attempt ? $0.outcome : nil}}}
    func hold(_ job: Job,_ outcome: Outcome) {lock.withLock {held[job.id] = (job.attempt,outcome)}}
    func releaseHeld(_ id: String) {lock.withLock {_ = held.removeValue(forKey:id)}}
    /// Test seam only: called on the operation lane after the running marker
    /// and before domain execution. The service never installs it.
    var executionProbe: ((String) -> Void)? {
        get {lock.withLock {probe}}
        set {lock.withLock {probe = newValue}}
    }
    func recordRecoveryRequired(_ id: String) {lock.withLock {_ = recoveryRequired.insert(id)}}
    func needsRecovery(_ id: String) -> Bool {lock.withLock {recoveryRequired.contains(id)}}
    var enabled: Bool {lock.withLock {queue != nil}}
    func configure(queue: DispatchQueue,completion: @escaping @Sendable (String,Bool) -> Void) {
        lock.withLock {self.queue = queue;self.completion = completion}
    }
    func add(_ job: Job,router: CommandRouter) {
        lock.withLock {jobs[job.id] = job;recoveryRequired.remove(job.id);held.removeValue(forKey:job.id)}
        resume(router:router)
    }
    func resume(router: CommandRouter) {
        let pending: [(DispatchQueue,Job)] = lock.withLock {
            guard let queue else {return []}
            return jobs.values.filter {scheduled.insert($0.id).inserted}.map {(queue,$0)}
        }
        for (queue,job) in pending {
            queue.async { [self,router] in
                let finished = router.runCommandOperation(job)
                let callback = lock.withLock { () -> (@Sendable (String,Bool) -> Void)? in
                    scheduled.remove(job.id)
                    if finished,jobs[job.id]?.attempt == job.attempt {jobs.removeValue(forKey:job.id)}
                    return completion
                }
                if finished {job.lease.finish();callback?(job.method,true)}
                if router.writeAdmissionStatus["locked"] as? Bool != true {resume(router:router)}
                // A blocked job retains its admitted lease and waits for the
                // existing backup admission notification, without polling.
            }
        }
    }
}

extension CommandRouter {
    /// Called once by the lifecycle owner, using its existing maintenance lane.
    public func configureCommandOperations(on queue: DispatchQueue,completion: @escaping @Sendable (String,Bool) -> Void = {_,_ in}) {
        commandOperations.configure(queue:queue,completion:completion)
    }
    public func resumeCommandOperations() {commandOperations.resume(router:self)}

    func hasCommandOperation(params: JSON,caller: Caller) throws -> Bool {
        guard let command = params["command_id"] as? String else {return false}
        let id = Self.commandOperationID(principal:caller.principal,command:command)
        return try readForPreparation {try self.operationRecord($0,id:id) != nil}
    }
    static let alwaysOperationMethods: Set<String> = [
        "backup_create","restore_create","restore_preview","attachment_cleanup_preview",
        "import_preview","import_commit","import_rollback","export_project",
        "media_intake_preview","media_intake_capture","media_intake_confirm","media_round_publish","media_context_reconcile","project_icon_import",
        "task_purge_preview","task_purge","epic_delete",
        "policy_preview","policy_propose","policy_apply","status_retire","relation_import",
        "media_publication_preview","media_type_adopt","media_type_retire","media_context_approve","media_round_finish","media_round_successor"
    ]
    static let operationEvidenceMethods = sourceTargetMethods.union([
        "review_context","review_prepare","review_batch_inputs","work_takeover",
        "human_request_create","human_request_revise","task_get"
    ])
    static let operationCredentialMethods: Set<String> = ["work_claim","batch_claim","work_takeover"]
    /// Methods that needsCommandOperation routes for some inputs only. The catalog
    /// and docs/mcp-contract.md name them; CommandOperationTests checks both.
    static let conditionalOperationMethods: Set<String> = sourceCaptureMethods.union(operationEvidenceMethods)
        .union(["project_edit","project_settings_save","task_archive","attachment_read","attachment_add"])
    /// Operation methods that run as synchronous reads, without write admission.
    static var readOperationMethods: Set<String> {alwaysOperationMethods.union(conditionalOperationMethods).intersection(readMethods)}
    /// Potentially unbounded file/graph work is asynchronous. Cheap metadata and
    /// ordinary claim/edit paths stay synchronous. Planning reads no file bytes.
    func needsCommandOperation(method: String,params: JSON,caller: Caller) throws -> Bool {
        if Self.alwaysOperationMethods.contains(method) {return true}
        if ["project_edit","project_settings_save"].contains(method),params["brief"] != nil || params["pinned_decisions"] != nil {return true}
        if method == "project_settings_save",params["policy"] != nil || params["policy_proposal_id"] != nil {return true}
        if method == "task_archive" {return (params["action"] as? String ?? "archive") == "archive" && bool(params,"cleanup")}
        if method == "attachment_read" {return (params["representation"] as? String ?? "metadata") != "metadata"}
        if method == "task_get",!bool(params,"include_completion_eligibility") {return false}
        if method == "human_request_create",params["target_attachment_id"] == nil,params["review_request_id"] == nil {return false}
        if method == "attachment_add" {return params["path"] != nil || (params["source"] as? JSON)?["path"] != nil}
        if Self.sourceCaptureMethods.contains(method) {
            if !Self.referencedValues(params,key:"artifact_id").isEmpty || !Self.referencedValues(params,key:"attachment_id").isEmpty {return true}
            return ([params] + (params["members"] as? [JSON] ?? [])).contains { input in
                guard let evidence = input["evidence_manifest"] as? JSON else {return false}
                return evidence["source_capture"] != nil || evidence["artifact_refs"] != nil || evidence["playtest_bundle"] != nil
            }
        }
        guard Self.operationEvidenceMethods.contains(method),let pid = params["project_id"] as? String else {return false}
        if !Self.referencedValues(params,key:"artifact_id").isEmpty || !Self.referencedValues(params,key:"attachment_id").isEmpty || !Self.referencedValues(params,key:"source_capture_id").isEmpty {return true}
        // Completion of a release set enumerates members and their targets.
        if method == "release_set_complete" {return true}
        if method == "human_request_answer",!(params["files"] as? [JSON] ?? []).isEmpty {return true}
        return try readForPreparation {db in
            _ = try self.scope(db,params,caller)
            var taskIDs = try self.preparationTaskIDs(db,method:method,params,pid)
            if method == "task_get",let task = try? self.task(db,params,pid),let tid = task["id"] as? String {taskIDs.append(tid)}
            if ["human_request_answer","human_request_revise"].contains(method),let rid = params["request_id"] as? String,
               let request = try? self.scoped(db,rid,pid,type:"request") {
                if request["target_attachment_id"] != nil || Self.referencedValues(params,key:"target_attachment_id").isEmpty == false {return true}
                if method == "human_request_revise" {return false}
            }
            for tid in taskIDs {
                guard let task = try? self.scoped(db,tid,pid,type:"task"),let mid = task["current_manifest_id"] as? String,
                      let manifest = try? self.scoped(db,mid,pid,type:"manifest") else {continue}
                let evidence = manifest["evidence"] as? JSON ?? [:]
                if evidence["source_capture"] != nil || evidence["artifact_refs"] != nil || evidence["playtest_bundle"] != nil || !self.acceptanceArtifactRefs(evidence).isEmpty {return true}
            }
            return false
        }
    }
    static func commandOperationID(principal: String,command: String) -> String {
        let bytes = Array(hash(Data((principal + "\0" + command).utf8)).prefix(32))
        return [String(bytes[0..<8]),String(bytes[8..<12]),String(bytes[12..<16]),String(bytes[16..<20]),String(bytes[20..<32])].joined(separator:"-")
    }
    static func commandOperationKey(_ id: String) -> String {"command-operation:" + id.lowercased()}
    func operationRecord(_ db: Database,id: String) throws -> JSON? {
        let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.commandOperationKey(id)])
        guard let value = commandOperations.stagedAdmission(id,canonical:raw) ?? raw.map(jsonObject) else {return nil}
        try validateOperationRecord(value,id:id)
        return value
    }
    func validateOperationRecord(_ value: JSON,id: String) throws {
        guard value["operation_id"] as? String == id.lowercased(),let command = value["command_id"] as? String,UUID(uuidString:command) != nil,
              let principal = value["principal"] as? String,!principal.isEmpty,value["method"] is String,value["digest"] is String,value["incarnation"] is String,
              Self.commandOperationID(principal:principal,command:command) == id.lowercased(),
              ["queued","running","succeeded","failed"].contains(value["state"] as? String ?? "") else {throw StoreRecovery.required("command_operation_invalid")}
    }
    func saveOperation(_ db: Database,_ operation: JSON) throws {
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       arguments:[Self.commandOperationKey(operation["operation_id"] as! String),try jsonString(operation)])
    }
    func authorizeOperation(_ db: Database,_ operation: JSON,params: JSON,caller: Caller) throws {
        guard EnvelopeStorageIdentity.equal(operation["principal"] as? String,caller.principal) else {throw CoreError("NOT_FOUND","This operation is not available to this caller.")}
        if let pid = operation["project_id"] as? String {
            guard EnvelopeStorageIdentity.equal(params["project_id"] as? String,pid) else {throw CoreError("FORBIDDEN","The operation is outside this project.")}
        } else {try owner(caller)}
        let generation = try backupWriteAuthorization(db,params:params,caller:caller)
        guard operation["authorization_generation"] as? String == generation else {throw CoreError("CONNECTION_REVOKED","The operation's session authorization changed.")}
        guard operation["incarnation"] as? String == incarnation else {throw CoreError("OPERATION_RESTORED","This operation belongs to another store incarnation and cannot run or grant authority.")}
    }
    func operationPayload(_ db: Database,_ operation: JSON,caller: Caller) throws -> JSON {
        var value = operation
        for key in ["principal","digest","authorization_generation","incarnation","recoverable","outcome_unknown","caller","reply_write_admission","error_result_command_id"] {value.removeValue(forKey:key)}
        value["status_method"] = "operation_get"
        // A read operation that started while backup admission was closed has
        // no durable running marker; this process reports its actual state.
        if operation["state"] as? String == "queued",let id = operation["operation_id"] as? String,commandOperations.isActive(id) {value["state"] = "running"}
        if operation["state"] as? String == "succeeded" {
            let command = operation["command_id"] as! String
            guard let receipt = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) else {throw Self.expiredCommandError(command)}
            guard receipt["digest"] as String == operation["digest"] as? String else {throw CoreError("IDEMPOTENCY_CONFLICT","The operation's command receipt no longer matches its accepted intent.")}
            let result = jsonObject(receipt["result"])
            guard !Self.isPrunedResult(result) else {throw Self.expiredCommandError(command)}
            if Self.mediaOwnerMethods.contains(operation["method"] as? String ?? "") || Self.mediaWorkerMethods.contains(operation["method"] as? String ?? "") {
                var envelope: JSON = ["data":result]
                if !Self.readMethods.contains(operation["method"] as? String ?? "") {envelope["command_id"] = command}
                envelope["write_admission"] = operation["reply_write_admission"]
                value["result"] = self.ownerManagedPathProjection(envelope,caller:caller)
            } else {value["result"] = self.ownerManagedPathProjection(result,caller:caller)}
        } else if operation["state"] as? String == "failed",operation["error"] == nil,let errorCommand = operation["error_result_command_id"] as? String {
            guard errorCommand == Self.commandOperationID(principal:caller.principal,command:"error:" + (operation["operation_id"] as! String)),
                  let receipt = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,errorCommand]) else {throw Self.expiredCommandError(operation["command_id"] as! String)}
            guard receipt["digest"] as String == hash(Data(("operation-error:" + (operation["digest"] as! String)).utf8)) else {throw CoreError("IDEMPOTENCY_CONFLICT","The operation error receipt no longer matches its accepted intent.")}
            let result = jsonObject(receipt["result"])
            guard !Self.isPrunedResult(result) else {throw Self.expiredCommandError(operation["command_id"] as! String)}
            value["error"] = result["error"]
        }
        return value
    }
    func commandOperationRead(params: JSON,caller: Caller,byCommand: Bool = false) throws -> JSON? {
        let readLease = try storageAdmission.acquire();defer {readLease.finish()}
        let id: String
        if byCommand {id = Self.commandOperationID(principal:caller.principal,command:try text(params,"command_id",max:100))}
        else {
            id = try text(params,"operation_id",max:100).lowercased()
            guard UUID(uuidString:id) != nil else {throw CoreError("INVALID_INPUT","operation_id must be a UUID.")}
        }
        func read(_ db: Database,credentials: Bool = false) throws -> JSON? {
            guard let operation = try self.operationRecord(db,id:id) else {
                if byCommand {return nil}
                throw CoreError("NOT_FOUND","This operation is not available.")
            }
            try self.authorizeOperation(db,operation,params:params,caller:caller)
            if commandOperations.needsRecovery(id) {throw CoreError("OPERATION_RECOVERY_REQUIRED","The operation's final state could not be persisted. Preserve its original command ID and reconcile storage recovery before retrying.",details:["operation_id":id,"command_outcome":"unknown","reason":"operation_final_state_persistence_failed"])}
            var payload = try self.operationPayload(db,operation,caller:caller)
            let method = operation["method"] as? String ?? ""
            if credentials,var result = payload["result"] as? JSON {
                try self.withValidatedDomainTransaction(db) {
                    try self.refreshReplayedClaim(db,method:method,output:&result,caller:caller)
                    if method == "batch_claim",let data = result["data"] as? JSON {result["data"] = try self.replayBatchClaims(db,data,caller)}
                    return .commit
                }
                payload["result"] = result
            }
            return ["data":payload]
        }
        let result = try readForPreparation {try read($0)}
        if let payload = result?["data"] as? JSON,payload["state"] as? String == "succeeded",
           Self.operationCredentialMethods.contains(payload["method"] as? String ?? "") {
            guard let reply = try backupWrites.withImmediateAccess({
                let lease = try storageAdmission.acquire();defer {lease.finish()}
                return try ArchiveStorageGate.withExclusive(root:root) { _ in
                    try dbQueue.writeWithoutTransaction {try read($0,credentials:true)}
                }
            }) else {throw CoreError("BACKUP_CAPTURE_ACTIVE","The operation succeeded; credential projection waits for backup write admission. Read the same operation again.",details:["command_outcome":"unknown","operation_id":id])}
            return reply
        }
        return result
    }
    func requirePendingOperationIntent(_ db: Database,command: String,digest: String,caller: Caller) throws {
        let id = Self.commandOperationID(principal:caller.principal,command:command)
        guard let operation = try operationRecord(db,id:id) else {return}
        guard operation["digest"] as? String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID belongs to another operation intent.")}
        guard commandOperations.isExecuting(id) else {
            throw CoreError("OPERATION_PENDING","Read the original operation before applying this command.",details:["operation_id":id,"status_method":"operation_get"])
        }
    }
    func acceptCommandOperation(method: String,params input: JSON,caller: Caller) throws -> JSON {
        var params = input
        if Self.readMethods.contains(method),params["command_id"] == nil {params["command_id"] = uuid()}
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        if Self.storageRestoreMethods.contains(method) {try owner(caller)}
        let generation = try backupWriteAuthorization(params:params,caller:caller)
        let id = Self.commandOperationID(principal:caller.principal,command:command)
        let digest = hash(Data((method + (try jsonString(params))).utf8))
        let lease = try storageAdmission.acquire()
        var retained = false
        defer {if !retained {lease.finish()}}
        var schedule = false
        // Completed/pending replay is a pooled point read, independent of a
        // currently busy writer. Only explicit interrupted recovery writes again.
        if let previous = try readForPreparation({try self.operationRecord($0,id:id)}) {
            try readForPreparation {db in try self.authorizeOperation(db,previous,params:params,caller:caller)}
            guard previous["digest"] as? String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID was already accepted with different input.")}
            if previous["state"] as? String != "failed" || !bool(previous,"recoverable") {return operationAcknowledgment(previous)}
        }
        func accept(_ db: Database,persist: Bool) throws -> JSON {
                if var previous = try self.operationRecord(db,id:id) {
                    try self.authorizeOperation(db,previous,params:params,caller:caller)
                    guard previous["digest"] as? String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID was already accepted with different input.")}
                    if previous["state"] as? String == "failed",bool(previous,"recoverable") {
                        previous["state"] = "queued";previous["updated_at"] = now();previous.removeValue(forKey:"error");previous.removeValue(forKey:"finished_at")
                        previous["recoverable"] = false
                        if persist {try self.saveOperation(db,previous)};schedule = true
                    }
                    return previous
                }
                // Reserve the original UUID in the same transaction that accepts
                // the operation. No synchronous command can reuse it meanwhile.
                try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                var value: JSON = ["operation_id":id,"command_id":command,"method":method,"principal":caller.principal,
                    "caller":["role":caller.role,"installation":caller.installation,"session_id":caller.sessionID as Any? ?? NSNull()],
                    "digest":digest,"state":"queued","incarnation":self.incarnation,"created_at":now(),"updated_at":now()]
                value["project_id"] = params["project_id"];value["authorization_generation"] = generation
                if let receipt = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                    guard receipt["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID belongs to another intent.")}
                    guard !Self.isPrunedResult(jsonObject(receipt["result"])) else {throw Self.expiredCommandError(command)}
                    value["state"] = "succeeded";value["finished_at"] = now()
                } else {schedule = true}
                if persist {try self.saveOperation(db,value)}
                return value
        }
        let operation: JSON
        // Admission and the capture flag share one atomic writer count: capture
        // cannot acquire its SQLite lease between this check and the SQL write.
        if let canonical = try backupWrites.withImmediateAccess({try dbQueue.write {try accept($0,persist:true)}}) {operation = canonical}
        else {
            let staged = try readForPreparation {db -> (JSON,String?) in
                let base = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.commandOperationKey(id)])
                return (try accept(db,persist:false),base.map {hash(Data($0.utf8))})
            }
            try commandOperations.stageAdmission(staged.0,baseHash:staged.1,root:root)
            operation = staged.0
        }
        if schedule {
            let job = CommandOperations.Job(id:id,params:try JSONSerialization.data(withJSONObject:params),method:method,caller:caller,generation:generation,lease:lease)
            retained = true;commandOperations.add(job,router:self)
        }
        // Acceptance always identifies the same operation, including on replay.
        // Result bytes are read only through the status route.
        return operationAcknowledgment(operation)
    }
    func operationAcknowledgment(_ operation: JSON) -> JSON {
        var data = operation
        for key in ["principal","caller","digest","authorization_generation","incarnation","recoverable","outcome_unknown","error","reply_write_admission","error_result_command_id"] {data.removeValue(forKey:key)}
        data["status_method"] = "operation_get"
        return ["command_id":operation["command_id"]!,"command_outcome":"accepted","data":data]
    }
    func runCommandOperation(_ job: CommandOperations.Job) -> Bool {
        do {
            return try storageAdmission.withContinuation(job.lease) {
                // A backup releases admission before beginning its own capture.
                // Its brief marker and terminal publication still obey admission.
                if job.method == "backup_create" {return try performReadOperation(job)}
                // CL-353 F1: a read method runs exactly as its synchronous read:
                // read pool, no backup write admission, so a capture never waits
                // for it and it runs during a capture. A writer continuation inside
                // it keeps admitWriterDependentRead. Only the operation's own
                // running marker and terminal-state write take write admission.
                if Self.readMethods.contains(job.method) {return try performReadOperation(job)}
                return try backupWrites.withImmediateAccess {try performCommandOperation(job)} ?? false
            }
        } catch {
            // Persisting a terminal receipt can itself fail. Keep the original
            // durable running state for startup reconciliation; never invent a
            // successful/definitively failed outcome from a storage exception.
            commandOperations.releaseHeld(job.id)
            commandOperations.recordRecoveryRequired(job.id)
            StoreRecovery.recordFailure(root:root,error:error)
            return true
        }
    }
    private func performCommandOperation(_ job: CommandOperations.Job) throws -> Bool {
        guard let outcome = try executeCommandOperation(job) else {return false}
        try finishCommandOperation(job,outcome)
        return true
    }
    /// The finished read reply stays in process memory while a capture or the
    /// FIFO queue closes write admission. The job then waits for the existing
    /// admission notification, without polling, and writes only its terminal state.
    private func performReadOperation(_ job: CommandOperations.Job) throws -> Bool {
        guard let outcome = try commandOperations.heldOutcome(job) ?? executeCommandOperation(job) else {return false}
        guard try backupWrites.withImmediateAccess({try finishCommandOperation(job,outcome)}) != nil else {
            commandOperations.hold(job,outcome);return false
        }
        commandOperations.releaseHeld(job.id)
        return true
    }
    private func executeCommandOperation(_ job: CommandOperations.Job) throws -> CommandOperations.Outcome? {
        let params = try JSONSerialization.jsonObject(with:job.params) as! JSON
        // GRDB executes callbacks on its own writer/reader threads. The
        // process-local admitted execution marker spans those callbacks; public
        // handle still returns the operation for every outside same-ID replay.
        commandOperations.beginExecution(job.id)
        defer {commandOperations.endExecution(job.id)}
        let previous = Thread.current.threadDictionary[commandOperations.contextKey]
        Thread.current.threadDictionary[commandOperations.contextKey] = job.id
        defer {if let previous {Thread.current.threadDictionary[commandOperations.contextKey] = previous} else {Thread.current.threadDictionary.removeObject(forKey:commandOperations.contextKey)}}
        var output: JSON?,failure: CoreError?
        let startedAt = now()
        let purgeEpoch = try readForPreparation {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key='command-operation-purge-epoch'")}
        do {
            let generation = try backupWriteAuthorization(params:params,caller:job.caller)
            guard generation == job.generation else {throw CoreError("CONNECTION_REVOKED","The operation's session authorization changed before application.")}
            let markRunning = {
                try self.dbQueue.write {db in
                    guard var value = try self.operationRecord(db,id:job.id) else {throw CoreError("OPERATION_MISSING","The accepted operation record is missing.")}
                    try self.authorizeOperation(db,value,params:params,caller:job.caller)
                    value["state"] = "running";value["started_at"] = startedAt;value["updated_at"] = now();try self.saveOperation(db,value)
                }
            }
            if Self.readMethods.contains(job.method) || job.method == "backup_create" {
                // Never write during a capture. A read started while admission is
                // closed checks authority on the pool; status reports it as running.
                if try backupWrites.withImmediateAccess(markRunning) == nil {
                    if job.method == "backup_create" {return nil}
                    try readForPreparation {db in
                        guard let value = try self.operationRecord(db,id:job.id) else {throw CoreError("OPERATION_MISSING","The accepted operation record is missing.")}
                        try self.authorizeOperation(db,value,params:params,caller:job.caller)
                    }
                }
            } else {try markRunning()}
            commandOperations.executionProbe?(job.id)
            output = try handle(method:job.method,params:params,caller:job.caller)
        } catch let error as CoreError {failure = error}
        catch {
            let publicError = PublicErrorText.payload(error)
            var details = publicError["details"] as? JSON ?? [:]
            if publicError["code"] as? String == "COMMAND_FAILED" {details["command_outcome"] = "unknown"}
            failure = CoreError(publicError["code"] as? String ?? "COMMAND_FAILED",publicError["message"] as? String ?? "The operation could not finish.",details:details)
        }
        return CommandOperations.Outcome(output:output,failure:failure,purgeEpoch:purgeEpoch,startedAt:startedAt)
    }
    private func finishCommandOperation(_ job: CommandOperations.Job,_ outcome: CommandOperations.Outcome) throws {
        let output = outcome.output,failure = outcome.failure,purgeEpoch = outcome.purgeEpoch
        let params = try JSONSerialization.jsonObject(with:job.params) as! JSON
        let command = try text(params,"command_id",max:100)
        // Same-ID recovery acceptance must not replace the sidecar between this
        // terminal commit and retirement of the preceding attempt's admission.
        try commandOperations.withAdmission(principal:job.caller.principal,command:command) {
        try dbQueue.write {db in
                guard var value = try self.operationRecord(db,id:job.id) else {throw CoreError("OPERATION_MISSING","The accepted operation record is missing.")}
                if let output {
                    // Successful replies have one privacy/retention owner. The
                    // final transaction publishes both reply and terminal state.
                    var durable = output
                    if var data = durable["data"] as? JSON {data.removeValue(forKey:"claim_token");durable["data"] = self.redactBatchClaims(data)}
                    let existing = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[job.caller.principal,value["command_id"] as! String])
                    if let existing {
                        guard existing["digest"] as String == value["digest"] as? String else {throw CoreError("IDEMPOTENCY_CONFLICT","The operation receipt no longer matches its accepted intent.")}
                    }
                    let currentPurgeEpoch = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='command-operation-purge-epoch'")
                    // Never resurrect a reply scrubbed by a concurrent purge.
                    // Read-only operations have no semantic journal yet: retire
                    // their private snapshot if any purge crossed execution.
                    let expired = existing.map {Self.isPrunedResult(jsonObject($0["result"]))} == true || (job.method != "task_purge" && currentPurgeEpoch != purgeEpoch)
                    if expired {durable = jsonObject(Self.prunedResult)}
                    let media = Self.mediaOwnerMethods.contains(job.method) || Self.mediaWorkerMethods.contains(job.method)
                    if !media || existing == nil {
                        try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?) ON CONFLICT(principal,command_id) DO UPDATE SET result=excluded.result",
                            arguments:[job.caller.principal,value["command_id"] as! String,value["digest"] as! String,try jsonString(media && !expired ? (durable["data"] as? JSON ?? durable) : durable)])
                    } else if expired {
                        try db.execute(sql:"UPDATE commands SET result=? WHERE principal=? AND command_id=?",arguments:[Self.prunedResult,job.caller.principal,value["command_id"] as! String])
                    }
                    value["reply_write_admission"] = output["write_admission"]
                    value["state"] = "succeeded";value.removeValue(forKey:"outcome_unknown");value.removeValue(forKey:"error")
                } else if let failure {
                    let uncertain = bool(value,"outcome_unknown") || failure.code == "OUTCOME_UNKNOWN" || failure.details["command_outcome"] as? String == "unknown"
                    var error = PublicErrorText.payload(failure)
                    if uncertain {var details = failure.details;details["command_outcome"] = "unknown";error["details"] = PublicErrorText.scrubbedValue(details)}
                    // A failure may include private ticket titles/snapshots too.
                    // Its separate canonical journal slot observes purge/expiry
                    // without masquerading as the original semantic commit.
                    let errorCommand = Self.commandOperationID(principal:job.caller.principal,command:"error:" + job.id)
                    let errorDigest = hash(Data(("operation-error:" + (value["digest"] as! String)).utf8))
                    let old = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[job.caller.principal,errorCommand])
                    if let old {guard old["digest"] as String == errorDigest else {throw CoreError("IDEMPOTENCY_CONFLICT","The operation error receipt belongs to another command.")}}
                    let crossedPurge = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='command-operation-purge-epoch'") != purgeEpoch
                    let expired = crossedPurge || old.map {Self.isPrunedResult(jsonObject($0["result"]))} == true
                    let receipt: JSON = expired ? jsonObject(Self.prunedResult) : ["command_id":value["command_id"]!,"error":error]
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?) ON CONFLICT(principal,command_id) DO UPDATE SET result=excluded.result",arguments:[job.caller.principal,errorCommand,errorDigest,try jsonString(receipt)])
                    value["state"] = "failed";value["error_result_command_id"] = errorCommand;value.removeValue(forKey:"error")
                    value["recoverable"] = uncertain;value["outcome_unknown"] = uncertain
                }
                if value["started_at"] == nil {value["started_at"] = outcome.startedAt}
                value["finished_at"] = now();value["updated_at"] = now();try self.saveOperation(db,value)
        }
        commandOperations.retireAdmission(job.id,root:root)
        }
    }
    /// Runs before admission opens. Completed semantic transactions win over a
    /// lost operation acknowledgment. Other interrupted attempts fail explicitly;
    /// only exact original-intent replay can schedule reconciliation.
    func recoverCommandOperations(_ db: Database) throws {
        // The accepted metadata was flushed independently of SQLite during a
        // capture. Import it before applying the existing interruption rules.
        for id in commandOperations.stagedAdmissionIDs {
            guard let value = try operationRecord(db,id:id) else {throw StoreRecovery.required("command_operation_admission_invalid")}
            try saveOperation(db,value)
        }
        let rows = try Row.fetchCursor(db,sql:"SELECT key,value FROM metadata WHERE key GLOB 'command-operation:*'")
        while let row = try rows.next() {
            var value = jsonObject(row["value"])
            let key: String = row["key"]
            try validateOperationRecord(value,id:String(key.dropFirst("command-operation:".count)))
            guard ["queued","running"].contains(value["state"] as? String ?? "") else {continue}
            guard let principal = value["principal"] as? String,let command = value["command_id"] as? String,let digest = value["digest"] as? String else {throw StoreRecovery.required("command_operation_invalid")}
            let restored = value["incarnation"] as? String != incarnation
            if !restored,let receipt = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[principal,command]),receipt["digest"] as String == digest {
                value["state"] = "succeeded";value.removeValue(forKey:"outcome_unknown");value.removeValue(forKey:"error")
            } else {
                let running = value["state"] as? String == "running" || bool(value,"outcome_unknown")
                value["state"] = "failed";value["recoverable"] = !restored;value["outcome_unknown"] = running
                value["error"] = CoreError(restored ? "OPERATION_RESTORED" : "OPERATION_INTERRUPTED",
                    restored ? "The operation was captured in another store incarnation; it cannot resume in this restored copy." : "The service restarted before a final operation reply was recorded. Replay only the exact original command and UUID to reconcile.",
                    details:["command_id":command,"reason":restored ? "store_incarnation_changed" : "service_restarted","command_outcome":running ? "unknown" : "rejected"]).dictionary
            }
            value["finished_at"] = now();value["updated_at"] = now();try saveOperation(db,value)
        }
    }
}
