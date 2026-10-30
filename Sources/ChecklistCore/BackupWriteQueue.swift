import Foundation
import Dispatch
import Darwin
import GRDB

/// The condition protects admission, ordering and receipts. The worker receives
/// immutable encoded commands; no SQLite writer or object-gate work runs under this lock.
/// Accepted intents are fsynced separately from the live SQLite writer, so the
/// short consistent-copy lease cannot delay their acceptance.
final class BackupWriteQueue: @unchecked Sendable {
    private struct Intent: Codable, Sendable {
        let sequence: UInt64
        let key: String
        let digest: String
        let command: String
        let project: String?
        let method: String
        let params: Data
        let caller: Caller
        let authorizationGeneration: String?
        let incarnation: String
        let root: String
    }
    private struct Receipt: Codable, Sendable {
        let sequence: UInt64
        let key: String
        let digest: String
        let command: String
        let project: String?
        let method: String
        let error: Data?
        let incarnation: String
        let root: String
    }
    enum Admission {
        case run
        case reply(JSON)
    }
    enum Status {
        case reply(JSON)
        case applied(digest: String,method: String)
    }
    private let condition = NSCondition()
    private let immediateContextKey = "ChecklistBackupImmediate-" + UUID().uuidString
    private let worker = DispatchQueue(label:"org.checklist.backup-writes",qos:.userInitiated,autoreleaseFrequency:.workItem)
    private let generation = UUID().uuidString.lowercased()
    private var revision: UInt64 = 0
    private var backupActive = false
    private var finishedBackups: UInt64 = 0
    private var captureLocked = false
    private var draining = false
    private var runningWrites = 0
    private var nextSequence: UInt64 = 1
    private var pending: [Intent] = []
    private var receipts: [String:Receipt] = [:]
    private var recoveryRequired = false
    private var waitingForRetention = false
    private var files: StorageObjectFiles?
    private var incarnation = ""
    private var root = ""
    private var observer: (@Sendable () -> Void)?
    private var operationLeases: [String:StorageOperationLease] = [:]

    func restore(root: URL,incarnation: String,admission: StorageAdmission) throws {
        condition.lock();defer {condition.unlock()}
        self.files = try StorageObjectFiles(root:root)
        self.incarnation = incarnation;self.root = root.path
        guard try files!.directoryExists("backup-write-queue") else {return}
        let directory = root.appendingPathComponent("backup-write-queue",isDirectory:true)
        let names = try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted()
        for name in names {
            // Command-operation admissions were validated and reconciled before
            // this restore. A failed retirement cannot turn them into FIFO work.
            if name.range(of:"^operation-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.intent$",options:.regularExpression) != nil {continue}
            // Unknown names are never followed or discarded as queue authority.
            if name.range(of:"^\\.pending-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression) != nil {continue} // Unacknowledged interrupted publication.
            guard name.range(of:"^[0-9]{20}-[a-f0-9]{64}\\.(intent|result)$",options:.regularExpression) != nil else {
                throw StoreRecovery.required("backup_write_queue_invalid")
            }
            let bytes = try files!.read("backup-write-queue/" + name,maximum:4_100_000)
            if name.hasSuffix(".result") {
                let receipt = try JSONDecoder().decode(Receipt.self,from:bytes)
                guard receipt.root == self.root,receipt.incarnation == incarnation,
                      name == self.name(receipt.sequence,receipt.key,"result") else {throw StoreRecovery.required("backup_write_queue_identity")}
                receipts[receipt.key] = receipt;nextSequence = max(nextSequence,receipt.sequence + 1)
            } else {
                let intent = try JSONDecoder().decode(Intent.self,from:bytes)
                guard intent.root == self.root,intent.incarnation == incarnation,
                      name == self.name(intent.sequence,intent.key,"intent"),
                      intent.key == Self.key(intent.caller,intent.command),
                      intent.digest == hash(Data((intent.method + String(decoding:intent.params,as:UTF8.self)).utf8)) else {throw StoreRecovery.required("backup_write_queue_identity")}
                pending.append(intent);nextSequence = max(nextSequence,intent.sequence + 1)
            }
        }
        pending.removeAll {intent in receipts[intent.key].map {$0.sequence >= intent.sequence} ?? false}
        pending.sort {$0.sequence < $1.sequence}
        for intent in pending {operationLeases[intent.key] = try admission.acquire()}
    }

    private static func key(_ caller: Caller,_ command: String) -> String {hash(Data((caller.principal + "\0" + command).utf8))}
    private func name(_ sequence: UInt64,_ key: String,_ suffix: String) -> String {String(format:"%020llu",sequence) + "-" + key + "." + suffix}
    private func write<T: Encodable>(_ value: T,sequence: UInt64,key: String,suffix: String) throws {
        guard let files else {throw StoreRecovery.required("backup_write_queue_not_ready")}
        let temporary = ".pending-" + UUID().uuidString.lowercased()
        try files.writeNew("backup-write-queue/" + temporary,bytes:try StorageSnapshot.encoded(value))
        let (directory,final) = try files.parent("backup-write-queue/" + name(sequence,key,suffix))
        defer {Darwin.close(directory)}
        guard renameatx_np(directory,temporary,directory,final,UInt32(RENAME_EXCL)) == 0,fsync(directory) == 0 else {throw StorageSnapshotFailure.failed("renameatx_np",path:"backup-write-queue/" + final,root:files.root.path)}
    }
    private func removeIntent(_ intent: Intent) throws {
        guard let files else {throw StoreRecovery.required("backup_write_queue_not_ready")}
        let (directory,name) = try files.parent("backup-write-queue/" + name(intent.sequence,intent.key,"intent"))
        defer {Darwin.close(directory)}
        guard (unlinkat(directory,name,0) == 0 || errno == ENOENT),fsync(directory) == 0 else {throw StorageSnapshotFailure.failed("unlinkat",path:"backup-write-queue/" + name,root:files.root.path)}
    }

    func status() -> JSON {
        condition.lock();defer {condition.unlock()};return statusLocked()
    }
    private func statusLocked(queued: Bool = false) -> JSON {
        let queuedWork = draining || !pending.isEmpty
        let locked = captureLocked || queuedWork || recoveryRequired
        let reason = recoveryRequired ? "backup_queue_recovery_required" : captureLocked || waitingForRetention ? "backup_in_progress" : queuedWork ? "backup_queue_draining" : ""
        let message = recoveryRequired ? "Accepted writes are retained for storage recovery." : waitingForRetention ? "Accepted writes are queued until backup retention is released." : captureLocked ? "Writes are locked and queued while a backup captures the database." : queuedWork ? "Accepted writes are being applied in arrival order." : ""
        return ["backup_active":backupActive,"locked":locked,"queued":queued || !pending.isEmpty,"reason":reason,"message":message,
                "estimated_remaining_seconds":NSNull(),"generation":generation,"revision":revision]
    }
    private func queuedReply(_ command: String) -> JSON {
        ["command_id":command,"command_outcome":"queued","write_admission":statusLocked(queued:true),
         "data":["state":"queued","queued":true,"status_method":"command_status","command_id":command]]
    }

    func setObserver(_ observer: @escaping @Sendable () -> Void) {condition.lock();self.observer = observer;condition.unlock()}
    private func notify() {condition.lock();let callback = observer;condition.unlock();callback?()}

    /// Pre-upgrade accepted UUIDs remain owned by this journal, including their
    /// original intent, generation and direct worker/replay behavior.
    func hasReservedCommand(params: JSON,caller: Caller) -> Bool {
        guard let command = params["command_id"] as? String else {return false}
        let key = Self.key(caller,command)
        condition.lock();defer {condition.unlock()}
        return receipts[key] != nil || pending.contains {$0.key == key}
    }

    func admit(method: String,params: JSON,caller: Caller,admission: StorageAdmission,authorization: () throws -> String?) throws -> Admission {
        condition.lock();defer {condition.unlock()}
        if Thread.current.threadDictionary[immediateContextKey] as? Bool == true {runningWrites += 1;return .run}
        if !captureLocked,!draining,!recoveryRequired,pending.isEmpty,receipts.isEmpty {runningWrites += 1;return .run}
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        let key = Self.key(caller,command)
        if !captureLocked,!draining,!recoveryRequired,pending.isEmpty,receipts[key] == nil {runningWrites += 1;return .run}
        let encoded = Data((try jsonString(params)).utf8),digest = hash(Data((method + String(decoding:encoded,as:UTF8.self)).utf8))
        if let intent = pending.first(where:{$0.key == key}) {
            guard intent.digest == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This queued command ID belongs to another original intent.")}
            return .reply(queuedReply(command))
        }
        if let receipt = receipts[key] {
            guard receipt.digest == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This queued command ID belongs to another original intent.")}
            if let bytes = receipt.error,let error = try JSONSerialization.jsonObject(with:bytes) as? JSON {
                _ = try authorization()
                throw CoreError(error["code"] as? String ?? "COMMAND_FAILED",error["message"] as? String ?? "The accepted command failed.",details:error["details"] as? JSON ?? [:])
            }
        }
        // Completed original retries use the normal domain replay path, which
        // revalidates authority and refreshes still-current claim tokens. If a
        // new capture is locked, that replay itself joins the FIFO queue.
        guard captureLocked || draining || recoveryRequired || !pending.isEmpty else {runningWrites += 1;return .run}
        let authorizationGeneration = try authorization()
        let intent = Intent(sequence:nextSequence,key:key,digest:digest,command:command,project:params["project_id"] as? String,
                            method:method,params:encoded,caller:caller,authorizationGeneration:authorizationGeneration,incarnation:incarnation,root:root)
        // Never acknowledge acceptance until the complete original intent and its
        // order are durable. A filesystem failure remains an honest admission error.
        let lease = try admission.acquire()
        do {try write(intent,sequence:intent.sequence,key:key,suffix:"intent")}
        catch {lease.finish();throw error}
        operationLeases[key] = lease
        pending.append(intent);nextSequence += 1;revision += 1
        return .reply(queuedReply(command))
    }
    func finishWrite() {condition.lock();runningWrites -= 1;condition.broadcast();condition.unlock()}
    func admitWithoutQueue() -> Bool {
        condition.lock();defer {condition.unlock()}
        guard Thread.current.threadDictionary[immediateContextKey] as? Bool == true || (!captureLocked && !draining && !recoveryRequired && pending.isEmpty) else {return false}
        runningWrites += 1;return true
    }
    /// Read fallbacks have no durable command identity. Never queue them or
    /// fabricate a reader hold/observation; the caller retries after admission opens.
    /// Count successful admission atomically so capture cannot overtake the read.
    func admitWriterDependentRead() -> Admission {
        condition.lock();defer {condition.unlock()}
        guard Thread.current.threadDictionary[immediateContextKey] as? Bool == true || (!captureLocked && !draining && !recoveryRequired && pending.isEmpty) else {
            return .reply(["data":["state":"locked","queued":false,"retry_required":true],
                           "write_admission":statusLocked()])
        }
        runningWrites += 1;return .run
    }
    func withImmediateAccess<T>(_ body: () throws -> T) rethrows -> T? {
        guard admitWithoutQueue() else {return nil}
        defer {finishWrite()}
        let previous = Thread.current.threadDictionary[immediateContextKey]
        Thread.current.threadDictionary[immediateContextKey] = true
        defer {if let previous {Thread.current.threadDictionary[immediateContextKey] = previous} else {Thread.current.threadDictionary.removeObject(forKey:immediateContextKey)}}
        return try body()
    }

    func beginCapture() throws {
        condition.lock()
        guard !backupActive else {condition.unlock();throw CoreError("BACKUP_IN_PROGRESS","A backup is already in progress.")}
        backupActive = true;captureLocked = true;revision += 1
        condition.unlock();notify();condition.lock()
        // Earlier admitted writes finish before the copy begins. Incoming writes
        // append durable intents while this wait releases the condition lock.
        while runningWrites > 0 {condition.wait()}
        condition.unlock()
    }
    func endCapture(router: CommandRouter) {
        condition.lock();captureLocked = false;revision += 1;condition.unlock()
        resume(router:router)
        notify()
    }
    func endBackup(router: CommandRouter) {
        condition.lock();backupActive = false;captureLocked = false;waitingForRetention = false;finishedBackups += 1;revision += 1;condition.unlock()
        resume(router:router)
        notify()
    }
    func resume(router: CommandRouter) {
        condition.lock()
        guard !captureLocked,!draining,!pending.isEmpty,!recoveryRequired,!waitingForRetention else {condition.unlock();return}
        draining = true;revision += 1;condition.unlock()
        worker.async { [self,router] in drain(router:router) }
    }
    private func drain(router: CommandRouter) {
        while true {
            condition.lock()
            guard !captureLocked,let intent = pending.first,let admitted = operationLeases[intent.key] else {draining = false;revision += 1;condition.broadcast();condition.unlock();notify();return}
            let completedBeforeAttempt = finishedBackups
            condition.unlock()
            let result: JSON
            do {
                let params = try JSONSerialization.jsonObject(with:intent.params) as? JSON ?? [:]
                // Actual command validation and current session/project/workflow
                // authority run again; a queued envelope grants no new authority.
                let generation = try router.backupWriteAuthorization(params:params,caller:intent.caller)
                guard generation == intent.authorizationGeneration else {throw CoreError("CONNECTION_REVOKED","The queued command's session authorization changed before application.")}
                result = try router.storageAdmission.withContinuation(admitted) {
                    try router.executeBackupQueuedWrite(method:intent.method,params:params,caller:intent.caller)
                }
            } catch let error as CoreError {
                if ["BACKUP_IN_PROGRESS","BACKUP_CAPTURE_ACTIVE"].contains(error.code) {
                    condition.lock()
                    if backupActive {
                        waitingForRetention = true;draining = false;revision += 1;condition.unlock();notify();return
                    }
                    // Retention may release between the failed operation and
                    // this catch. Retry once in the new completed-backup epoch;
                    // an unchanged external hold preserves the intent for recovery.
                    if finishedBackups != completedBeforeAttempt {condition.unlock();continue}
                    recoveryRequired = true;draining = false;revision += 1;condition.unlock();notify();return
                }
                if ["STORAGE_DRAINING","STORAGE_NOT_READY","OUTCOME_UNKNOWN"].contains(error.code) || error.details["command_outcome"] as? String == "unknown" {
                    condition.lock();recoveryRequired = true;draining = false;revision += 1;condition.unlock();notify();return
                }
                result = ["command_id":intent.command,"error":error.dictionary]
            }
            catch {
                condition.lock();recoveryRequired = true;draining = false;revision += 1;condition.unlock();notify();return
            }
            do {
                // Successful semantic results remain exclusively in the ordinary
                // command journal, so its expiry/purge also governs status reads.
                // This sidecar keeps only precommit rejection details.
                let error = try result["error"].map {try JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys])}
                let receipt = Receipt(sequence:intent.sequence,key:intent.key,digest:intent.digest,command:intent.command,project:intent.project,
                                      method:intent.method,error:error,incarnation:incarnation,root:root)
                try write(receipt,sequence:receipt.sequence,key:receipt.key,suffix:"result")
                // Receipt publication precedes removing the original intent. A
                // crash in between recognizes the receipt and cannot apply twice.
                try removeIntent(intent)
                condition.lock();receipts[intent.key] = receipt;pending.removeFirst();operationLeases.removeValue(forKey:intent.key);revision += 1;condition.unlock();admitted.finish();notify()
            } catch {
                condition.lock();recoveryRequired = true;draining = false;revision += 1;condition.unlock();notify();return
            }
        }
    }

    func result(command: String,project: String?,caller: Caller) throws -> Status {
        condition.lock();defer {condition.unlock()}
        let key = Self.key(caller,command)
        if let intent = pending.first(where:{$0.key == key}) {
            guard caller.isOwner || project == intent.project else {throw CoreError("FORBIDDEN","The queued command is outside this project.")}
            return .reply(["state":"queued","command_id":command,"queued":true])
        }
        guard let receipt = receipts[key] else {return .reply(["state":"unknown","command_id":command])}
        guard caller.isOwner || project == receipt.project else {throw CoreError("FORBIDDEN","The queued command is outside this project.")}
        if let bytes = receipt.error {return .reply(["state":"failed","command_id":command,"error":try JSONSerialization.jsonObject(with:bytes)])}
        return .applied(digest:receipt.digest,method:receipt.method)
    }
}

extension CommandRouter {
    public var writeAdmissionStatus: [String:Any] {backupWrites.status()}
    public func observeWriteAdmission(_ observer: @escaping @Sendable () -> Void) {backupWrites.setObserver(observer)}
    func backupWriteAuthorization(params: JSON,caller: Caller) throws -> String? {
        guard !caller.isOwner,params["project_id"] != nil else {return nil}
        return try readForPreparation {try self.backupWriteAuthorization($0,params:params,caller:caller)}
    }
    func backupWriteAuthorization(_ db: Database,params: JSON,caller: Caller) throws -> String? {
        guard !caller.isOwner,params["project_id"] != nil else {return nil}
        let project = try scope(db,params,caller)
        let generation = try callerSessionGeneration(db,caller,project:project)
        if let sessionID = caller.sessionID {
            let session = try scoped(db,sessionID,project,type:"session")
            guard session["installation"] as? String == caller.installation,session["role"] as? String == caller.role else {throw CoreError("CONNECTION_REVOKED","The queued command no longer matches this session registration.")}
            if caller.role == "assistant",let grants = session["assistant_grants"] as? [String:[String:Bool]],grants != caller.assistantGrants {throw CoreError("CONNECTION_REVOKED","The assistant's project grants changed before application.")}
        }
        return generation
    }
    func addingWriteAdmission(_ result: JSON) -> JSON {var result = result;if result["write_admission"] == nil {result["write_admission"] = backupWrites.status()};return result}
    func backupCommandStatus(params: JSON,caller: Caller) throws -> JSON {
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        _ = try backupWriteAuthorization(params:params,caller:caller)
        switch try backupWrites.result(command:command,project:params["project_id"] as? String,caller:caller) {
        case .reply(let result):return ["data":result]
        case .applied(let digest,let method):
            let result = try readForPreparation {db -> JSON in
                guard let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) else {throw Self.expiredCommandError(command)}
                guard (row["digest"] as String) == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","The queued command journal no longer matches its original intent.")}
                let result = jsonObject(row["result"])
                guard !Self.isPrunedResult(result) else {throw Self.expiredCommandError(command)}
                // Media's journal stores its semantic payload; the native owner
                // boundary supplies the wire envelope during ordinary execution.
                if Self.mediaOwnerMethods.contains(method) || Self.mediaWorkerMethods.contains(method) {return ["data":result,"command_id":command]}
                return result
            }
            return ["data":["state":"applied","command_id":command,"result":result,
                            "retry_original":["work_claim","work_child_accept","work_handoff_accept","work_takeover","batch_claim"].contains(method)]]
        }
    }
}
