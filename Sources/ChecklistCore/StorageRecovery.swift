import Foundation
import GRDB
import Darwin

/// `originals` is historical verified-backup accounting, not current bytes or
/// physical allocation. Cleanup separately pins exact manifests and payloads.
/// Construct once for a scoped projection or prepared batch, never per item.
struct StorageBackupRetentionIndex {
    let originals: Set<Data>
    let root: URL
    // Cleanup derives these only from completed self-contained backup receipts.
    // Historical accounting indexes intentionally leave them empty.
    var copyPaths: [Data:[URL]] = [:]
    var copyManifests: [String:String] = [:]
    var checkedCopies: Set<Data> = []
    var copyFailures: [Data:String] = [:]
    var verifiedRoots: [String:StorageObjectFiles] = [:]
    var manifestFailures: [String:String] = [:]
    var verifiedCopies: [Data:TicketCleanupBackupCopy] = [:]
    var verifiedManifests: [String:TicketObjectRemovalVerification] = [:]
    var unavailableManifests: Set<String> = []
    var cleanupLookup: StorageBackupMembershipLookup?
    var cleanupFailureReason: String?
    /// Additional observation metadata only; the shared receipt cache is separate.
    var cleanupRetainedBytes: Int {cleanupLookup?.retainedBytes ?? 0}
    func containsOriginal(_ key: Data) -> Bool {cleanupLookup?.containsOriginal(key) ?? originals.contains(key)}
    func hasIndependentCopy(_ key: Data) -> Bool {
        if let cleanupLookup {return cleanupLookup.hasIndependentCopy(key)}
        return copyPaths[key]?.isEmpty == false
    }
    mutating func verifyCopy(for object: JSON,check: () throws -> Void = {}) {
        guard let path = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {return}
        let key = Self.key(path:path,sha:sha,size:size)
        checkedCopies.insert(key)
        let paths = cleanupLookup?.copies(for:key) ?? AnySequence((copyPaths[key] ?? []).sorted {a,b in
            let localA = a.path.hasPrefix(root.path + "/"),localB = b.path.hasPrefix(root.path + "/")
            return localA != localB ? localA : a.path < b.path
        })
        for path in paths {
            if unavailableManifests.contains(path.path) {
                if copyFailures[key].map(TicketCleanupCopyFailure.isTransient) != true {
                    copyFailures[key] = manifestFailures[path.path] ?? "backup_copy_unverified:MANIFEST_UNAVAILABLE"
                }
                continue
            }
            do {
                // Two reusable generation roots bound idle pins. Active copies
                // retain their exact root even if its cache entry is evicted.
                if verifiedRoots[path.path] == nil {
                    if verifiedRoots.count >= 2,let evicted = verifiedRoots.keys.sorted().first {
                        verifiedRoots.removeValue(forKey:evicted)
                        verifiedManifests.removeValue(forKey:evicted)
                    }
                    verifiedRoots[path.path] = try StorageObjectFiles(root:path,pinRootForGates:true)
                }
                if verifiedManifests[path.path] == nil,let expected = copyManifests[path.path] {
                    verifiedManifests[path.path] = try TicketObjectRemovalVerification(root:path,relative:"manifest.json",sha256:expected,backupUse:true,check:check)
                }
                guard let manifest = verifiedManifests[path.path] else {throw StorageSnapshotFailure.incomplete}
                verifiedCopies[key] = try TicketCleanupBackupCopy(root:path,object:object,manifest:manifest,pinnedRoot:verifiedRoots[path.path],check:check)
                copyFailures.removeValue(forKey:key);return
            } catch {
                let reason = TicketCleanupCopyFailure.reason(error)
                // A transient failure outranks a bad alternative: another turn
                // may verify that alternative without a new backup generation.
                if copyFailures[key] == nil || TicketCleanupCopyFailure.isTransient(reason) {copyFailures[key] = reason}
                if verifiedManifests[path.path] == nil && !TicketCleanupCopyFailure.isTransient(reason) {
                    unavailableManifests.insert(path.path);manifestFailures[path.path] = reason
                    verifiedRoots.removeValue(forKey:path.path)
                }
                continue
            }
        }
    }
    /// Count available low-numbered slots, rather than assuming the shell's
    /// much higher limit. Ignore slots above 4096 conservatively. Keep 32 for
    /// normal service traffic plus enough for the next no-follow root walk,
    /// payload/original/manifest opens and temporary directory descriptors.
    var descriptorAdmissionReserve: Int {
        // Generation paths already belong to this immutable observation; do not
        // enumerate the lazy candidate-copy alternatives merely to budget FDs.
        let depth = copyManifests.keys.reduce(0) {max($0,$1.split(separator:"/").count)}
        return 32 + (depth == 0 ? 64 : min(64,depth)) + 12
    }
    func hasDescriptorBudget(reserving reserve: Int) -> Bool {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE,&limits) == 0 else {return false}
        let ceiling = Int(min(limits.rlim_cur,4096))
        let available = (0..<ceiling).reduce(0) {$0 + (fcntl(Int32($1),F_GETFD) < 0 && errno == EBADF ? 1 : 0)}
        return available >= reserve
    }
    static func key(path: String,sha: String,size: Int64) -> Data {
        // CL-355: byte-identical to jsonString (sorted keys, unescaped slashes) for
        // printable ASCII without quote or backslash; every other string uses it.
        func plain(_ value: String) -> Bool { value.utf8.allSatisfy {$0 >= 0x20 && $0 < 0x7F && $0 != 0x22 && $0 != 0x5C} }
        guard plain(path),plain(sha) else {return Data((try! jsonString(["path":path,"sha256":sha,"size":size])).utf8)}
        return Data(("{\"path\":\"" + path + "\",\"sha256\":\"" + sha + "\",\"size\":" + String(size) + "}").utf8)
    }
    static func referenceKey(path: String,sha: String,size: Int64) -> Data { Data((try! jsonString(["path":path,"sha256":sha,"size":size])).utf8) }
    func knownRetainedLogicalBytes(for attachment: JSON) -> Int64 {
        guard attachment["mode"] as? String == "managed",let path = attachment["path"] as? String,let sha = attachment["sha256"] as? String,
              let number = attachment["size"] as? NSNumber,number.int64Value >= 0,
              let relative = try? ManagedPaths.relative(path,family:"objects",root:root),
              containsOriginal(Self.key(path:relative,sha:sha,size:number.int64Value)) else {return 0}
        return number.int64Value
    }
}

extension CommandRouter {
    func storageOutcomeFailure(_ databaseError: DatabaseError, command: String) -> CoreError {
        let failure = CoreError("OUTCOME_UNKNOWN","Storage could not establish this command's committed outcome. Preserve its original ID and intent for reconciliation.",details:["command_id":command,"command_outcome":"unknown","reason":"database_write_or_commit_failed","sqlite_result_code":databaseError.resultCode.rawValue])
        StoreRecovery.recordFailure(root:root,error:failure)
        return failure
    }
    /// Full decode of every receipt. CL-343: never on a request path; reads use
    /// storageBackupAccounting, which shares receiptKeys with this reference.
    func storageBackupRetentionIndex(_ db: Database) throws -> StorageBackupRetentionIndex {
        var originals: Set<Data> = []
        let rows = try String.fetchCursor(db,sql:"SELECT value FROM metadata WHERE key GLOB 'backup-generation:*'")
        while let raw = try rows.next() { originals.formUnion(try StorageBackupAccountingCache.receiptKeys(raw,root:root)) }
        return .init(originals:originals,root:root)
    }
    /// CL-343 request path: reads only the receipt fingerprint. Nil while the
    /// process-wide index is cold or rebuilding off the request path ("unavailable").
    func storageBackupAccounting(_ db: Database) throws -> StorageBackupRetentionIndex? {
        try StorageBackupAccountingCache.shared(root:root).index(db,root:root,incarnation:incarnation) { [weak self] body in
            guard let self else { throw CoreError("STORE_CLOSED","The store closed before backup accounting was built.") }
            if let readers = self.readers { try readers.read(body) } else { try self.dbQueue.read(body) }
        }
    }
    /// Pending namespace is the authenticated principal plus original UUID,
    /// never kind/project/digest. It cannot become a competing command owner.
    func pendingStorageCommandKey(principal: String, command: String) throws -> String {
        "storage-command:" + hash(Data((try jsonString(["principal":principal,"command_id":command])).utf8))
    }
    func requirePendingStorageCommand(_ db: Database, command: String, digest: String, caller: Caller) throws {
        let key = try pendingStorageCommandKey(principal:caller.principal,command:command)
        if let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) {
            guard let pending = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON,
                  pending["intent_digest"] as? String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT","This original command ID already belongs to another storage operation.") }
        }
    }

    private func authorizeStorageBackup(_ db: Database,params: JSON,caller: Caller) throws {
        if caller.isOwner { return }
        try worker(caller)
        let pid = try scope(db,params,caller,write:true)
        try requireAgentEditAuthority(db,project:record(db,pid,type:"project"),caller:caller)
    }
    private func storageBackupDestination(params: JSON,caller: Caller,command: String) throws -> URL {
        if caller.isOwner,params["path"] != nil {
            return URL(fileURLWithPath:try text(params,"path"),isDirectory:true).standardizedFileURL
        }
        let label = try text(params,"qualification_name",max:64,required:false)
        guard label.isEmpty || label.range(of:"^[A-Za-z0-9_-]{1,64}$",options:.regularExpression) != nil else {
            throw CoreError("INVALID_INPUT","qualification_name uses at most 64 letters, numbers, underscores or hyphens.")
        }
        let relative = "backups/" + (label.isEmpty ? "" : "qualification-" + label + "/")
        let files = try StorageObjectFiles(root:root)
        let (fd,_) = try files.parent(relative + ".parent",create:true);Darwin.close(fd)
        return root.appendingPathComponent(relative + "snapshot-" + command.lowercased(),isDirectory:true)
    }

    /// Admitted by handle, but never occupies its serial writer during copying.
    /// An explicit budget is an internal fixture seam, not a service callback.
    func executeStorageBackup(params: JSON, caller: Caller, budget: StorageSnapshotBudget = .production()) throws -> JSON {
        do {
            try dbQueue.read { try authorizeStorageBackup($0,params:params,caller:caller) }
            try backupWrites.beginCapture()
            defer {backupWrites.endBackup(router:self)}
            var budget = budget
            let observe = budget.observe
            budget.observe = { event in
                if event == "capture_released" {self.backupWrites.endCapture(router:self)}
                try observe(event)
            }
            var result = try StorageSnapshotRetention.withCapture(root:root) { retention in
                try createStorageBackup(params:params,caller:caller,budget:budget,retention:retention)
            }
            if let data = result["data"] as? JSON,let operation = data["operation_id"] as? String {
                result["backup_retention"] = applyAutomaticBackupRetention(after:operation)
            }
            return result
        } catch {
            let reported = budget.reporting(error)
            quarantineFailedBackupPublication(params:params,caller:caller,error:reported)
            guard let failure = reported as? StorageSnapshotFailure else {throw reported}
            let code: String, message: String
            switch failure {
            case .invalidFixture, .unsupportedAuthority:
                code = "BACKUP_INVALID_INVENTORY"; message = "Backup could not validate the complete managed-file inventory. Keep the store and existing backups and report this failure."
            case .sourceChanged:
                code = "BACKUP_SOURCE_CHANGED"; message = "Required backup data changed or did not match its recorded checksum. Check original availability before retrying."
            case .incomplete:
                code = "BACKUP_INCOMPLETE"; message = "Backup is incomplete. A required file or completed snapshot is unavailable. Keep the store and existing backups."
            case .io,.systemCall:
                code = "BACKUP_IO_ERROR"; message = "Backup could not read or copy every required file, or write its destination. Check original availability and destination access before retrying."
            case .canceled:
                code = "BACKUP_CANCELED"; message = "Backup was canceled before completion. Existing data and backups are retained."
            case .publicationUncertain:
                throw CoreError("OUTCOME_UNKNOWN","Backup publication could not be confirmed. Check the last change using the original command before retrying.",details:["command_id":params["command_id"] ?? "","command_outcome":"unknown","reason":"backup_publication_uncertain"])
            case .limit, .freeSpace, .deadline: throw reported // Converted by the shared budget above.
            }
            // CL-362: the path and errno stay in the reply and the log. This command
            // ID is finished (a rejected operation stays failed), so every retry uses a new one.
            let report = StorageFailureReport(failure)
            report.log()
            var details = report.details
            details["command_outcome"] = "rejected"
            details["next_step"] = report.backupNextStep
            let cause = report.system == nil ? "" : " " + report.explanation
            throw CoreError(code,message + cause + " " + report.backupNextStep,details:details)
        }
    }
    private func createStorageBackup(params: JSON,caller: Caller,budget: StorageSnapshotBudget,retention: StorageSnapshotRetention) throws -> JSON {
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT","command_id must be a UUID.") }
        let digest = hash(Data(("backup_create" + (try jsonString(params))).utf8))
        let destination = try storageBackupDestination(params:params,caller:caller,command:command)
        let key = try pendingStorageCommandKey(principal:caller.principal,command:command)
        let (identity, operation, replay) = try ArchiveStorageGate.withExclusive(root:root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                try authorizeStorageBackup(db,params:params,caller:caller)
                guard let identityRaw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'") else {throw StoreRecovery.required("missing_migration_identity")}
                let identity = try StoreIdentityReceipt.decode(Data(identityRaw.utf8))
                // Parent ownership remains principal+UUID in this store; physical stage
                // names additionally bind store incarnation/root, avoiding collisions
                // between independently owned stores using the same owner command UUID.
                let physical = try jsonString(["parent":key,"store_id":identity.logical_store_id,"incarnation":identity.incarnation,"source_root":root.path])
                let seed = hash(Data(physical.utf8)), chars = Array(seed.prefix(32))
                let operationText = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
                let operation = UUID(uuidString:operationText)!
                var replay: JSON?
                try withValidatedDomainTransaction(db) {
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                        guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT","This command ID already belongs to another original intent.") }
                        replay = jsonObject(row["result"])
                        if Self.isPrunedResult(replay ?? [:]) { throw Self.expiredCommandError(command) }
                        return .commit
                    }
                    let pending: JSON = ["kind":"backup_create","intent_digest":digest,"operation_id":operation.uuidString.lowercased(),"state":"pending"]
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try jsonString(pending)])
                    return .commit
                }
                return (identity, operation, replay)
            }
        }
        if var replay { replay["replayed"] = true;return replay }
        guard destination.path != root.standardizedFileURL.path,
              !destination.path.hasPrefix(root.standardizedFileURL.path + "/objects/"),
              !destination.path.hasPrefix(root.standardizedFileURL.path + "/source-captures/") else { throw CoreError("INVALID_INPUT","Choose a separate backup destination.") }
        let parent = destination.deletingLastPathComponent(), name = destination.lastPathComponent
        func commitBackup(_ receipt: StorageSnapshotReceipt) throws -> JSON {
            let prepared = try prepareStorageBackupReceipt(destination:destination,receipt:receipt,identity:identity,budget:budget)
            return try ArchiveStorageGate.withExclusive(root:root) { permit in
                try dbQueue.writeWithoutTransaction { db in
                    try self.commitStorageBackupReceipt(db,params:params,caller:caller,permit:permit,command:command,digest:digest,key:key,destination:destination,receipt:receipt,identity:identity,generation:prepared.generation,summary:prepared.summary,projectIDs:prepared.projectIDs)
                }
            }
        }
        let receipt: StorageSnapshotReceipt
        do {
            // A previously published generation after lost SQL receipt is
            // reconciled under the original UUID and full manifest verification.
            let parentFiles = try StorageObjectFiles(root:parent,folderAccess:budget.folderAccess)
            let exists = try parentFiles.directoryExists(name)
            if exists {
                _ = try self.currentBackupManifest(destination,identity:identity,folderAccess:budget.folderAccess)
                receipt = try StorageSnapshot.reconcile(parent:parent,operation:operation,publicationName:name,budget:budget)
            } else {
                let stage = parent.appendingPathComponent(StorageSnapshot.names(operation).staging)
                if try parentFiles.directoryExists(stage.lastPathComponent) {
                    let staged = try StorageObjectFiles(root:stage,folderAccess:budget.folderAccess)
                    if try staged.regularOrLinkExists("intent.json") {
                        let bytes = try staged.read("intent.json",maximum:16_384)
                        guard let intent = try JSONSerialization.jsonObject(with:bytes) as? [String:String],
                              intent["store_id"]?.utf8.elementsEqual(identity.logical_store_id.utf8) == true,
                              intent["source_root"]?.utf8.elementsEqual(self.root.path.utf8) == true else {throw CoreError("BACKUP_TARGET_MISMATCH","The retained backup stage belongs to another store or source root.")}
                    }
                    if let recovered = try StorageSnapshot.resumeStaging(parent:parent,operation:operation,publicationName:name,budget:budget) {
                        receipt = recovered
                        return try commitBackup(receipt)
                    }
                }
                receipt = try StorageSnapshot.buildOnline(source:root,parent:parent,storeID:identity.logical_store_id,
                    publicationName:name,operation:operation,budget:budget,retention:retention)
            }
        } catch {
            // Best effort error metadata cannot turn an unsuccessful copy into
            // success, and may itself fail on a full or inaccessible volume.
            try? ArchiveStorageGate.withExclusive(root:root) { _ in
                try dbQueue.writeWithoutTransaction { db in
                    try self.withValidatedDomainTransaction(db) {
                        try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(["kind":"backup_create","intent_digest":digest,"operation_id":operation.uuidString.lowercased(),"state":"incomplete","error_code":"BACKUP_INCOMPLETE"]),key]);return .commit
                    }
                }
            }
            throw budget.reporting(error)
        }
        return try commitBackup(receipt)
    }
    private func currentBackupManifest(_ directory: URL,identity: StoreIdentityReceipt,folderAccess: StorageFolderAccess = .init()) throws -> StorageSnapshotManifest {
        let bytes = try StorageObjectFiles(root:directory,folderAccess:folderAccess).read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        guard manifest.storeID.utf8.elementsEqual(identity.logical_store_id.utf8),manifest.sourceRoot.utf8.elementsEqual(root.path.utf8) else {throw CoreError("BACKUP_TARGET_MISMATCH","This backup belongs to another logical store or source root.")}
        return manifest
    }
    private func prepareStorageBackupReceipt(destination: URL,receipt: StorageSnapshotReceipt,identity: StoreIdentityReceipt,budget: StorageSnapshotBudget) throws -> (generation: String,summary: JSON,projectIDs: [String]) {
        let manifestBytes = try StorageObjectFiles(root:destination).read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
        guard hash(manifestBytes) == receipt.manifestSHA256 else {throw StorageSnapshotFailure.sourceChanged}
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:manifestBytes)
        guard manifest.storeID.utf8.elementsEqual(identity.logical_store_id.utf8),manifest.sourceRoot.utf8.elementsEqual(root.path.utf8) else {throw CoreError("BACKUP_TARGET_MISMATCH","This backup belongs to another logical store or source root.")}
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:config)
        var projectIDs: [String] = []
        do {
            try copy.read { db in
                projectIDs = try String.fetchAll(db,sql:"SELECT id FROM records WHERE type='project' ORDER BY id")
                guard case .current(let captured) = try SchemaMigrations.inspect(db),
                      captured.logical_store_id.utf8.elementsEqual(identity.logical_store_id.utf8),
                      captured.incarnation.utf8.elementsEqual(identity.incarnation.utf8) else {throw CoreError("BACKUP_TARGET_MISMATCH","This captured database belongs to another store generation.")}
            }
            try copy.close()
        } catch {try? copy.close();throw error}
        let manifestIndex = try StorageBackupManifestIndex.prepare(root:root,manifest:manifest,manifestSHA256:receipt.manifestSHA256)
        let files = try StorageObjectFiles(root:destination)
        let usage = try StorageCopyUsage.measure(files,paths:["database.sqlite","manifest.json","intent.json"] + manifest.objects.map {"managed/" + $0.descriptor.relativePath},budget:budget)
        let summary: JSON = ["kind":"backup","operation_id":receipt.operationID.uuidString.lowercased(),"path":destination.path,
            "source_root":manifest.sourceRoot,"store_id":manifest.storeID,"captured_at":manifest.capturedAt as Any? ?? NSNull(),
            "verified_at":now(),"verification":"manifest_database_managed_files","manifest_sha256":receipt.manifestSHA256,"usage":usage,
            "writer_lease_seconds":budget.measurement.writerLeaseSeconds > 0 ? budget.measurement.writerLeaseSeconds as Any : NSNull()]
        let generation: JSON = ["summary":summary,"format":2,"state":"complete","operation_id":receipt.operationID.uuidString.lowercased(),"manifest_sha256":receipt.manifestSHA256,"known_at":now(),"current_physical_verified":false,"object_count":manifest.objects.count,"object_bytes":manifest.objects.reduce(Int64(0)) {$0 + $1.size},"manifest_index":manifestIndex]
        _ = try StorageBackupManifestIndex.generation(generation,root:root)
        return (try jsonString(generation),summary,projectIDs)
    }
    private func commitStorageBackupReceipt(_ db: Database,params: JSON,caller: Caller,permit: ArchiveStoragePermit,command: String,digest: String,key: String,destination: URL,receipt: StorageSnapshotReceipt,identity: StoreIdentityReceipt,generation: String,summary: JSON,projectIDs: [String]) throws -> JSON {
        try permit.requireRoot(root)
        guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'"),
              try StoreIdentityReceipt.decode(Data(raw.utf8)) == identity else {throw CoreError("BACKUP_TARGET_MISMATCH","The store generation changed during backup.")}
        var output: JSON = [:]
        try withValidatedDomainTransaction(db) {
            try authorizeStorageBackup(db,params:params,caller:caller)
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
            let data: JSON = ["path":destination.path,"format":"checklist-store-snapshot","manifest_sha256":receipt.manifestSHA256,"operation_id":receipt.operationID.uuidString.lowercased(),"restore_supported":true,"status":"complete","writer_lease_seconds":summary["writer_lease_seconds"] ?? NSNull()]
            try event(db,caller:caller,project:params["project_id"] as? String,entity:nil,kind:"backup_created",data:["origin":caller.isOwner ? "human_ui" : "agent","session_id":caller.sessionID ?? "","command_id":command,"operation_id":receipt.operationID.uuidString.lowercased(),"manifest_sha256":receipt.manifestSHA256,"captured_at":summary["captured_at"] ?? NSNull(),"verified_at":summary["verified_at"] ?? NSNull(),"project_ids":caller.isOwner ? projectIDs : [],"reason":try text(params,"reason",max:4000,required:false)])
            output = ["data":data,"command_id":command,"event_cursor":try self.cursor(db,caller:caller,scope:self.authorizationScope(db,caller))]
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,digest,try jsonString(output)])
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + receipt.operationID.uuidString.lowercased(),generation])
            try recordStorageCopyObservation(db,key:"backup",summary:summary)
            try Self.enqueueAutomaticBackupRetention(db,root:root,incarnation:identity.incarnation,operation:receipt.operationID.uuidString.lowercased())
            try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key]);return .commit
        }
        let warning = performStorageMaintenance(db,permit:permit)
        do { output = try addingHumanAnswerNotices(db,output:output,params:params,caller:caller) }
        catch { output = addingHumanAnswerNoticeFailure(output,caller:caller) }
        return addingStorageMaintenanceNotice(output,warning:warning)
    }

    /// One bounded native-service continuation. The service schedules the next
    /// actual job deadline; this creates no model runtime or polling loop.
    public func runStorageMaintenance() throws {try runStorageMaintenance(observe:nil)}

    /// Internal diagnostic seam; production and owned-copy checks share this path.
    func runStorageMaintenance(observe: ((JSON) -> Void)?) throws {
        let maintenanceStarted = ProcessInfo.processInfo.systemUptime
        observe?(["phase":"entry","lifecycle_turn":ticketCleanupLifecycleTurn])
        defer {observe?(["phase":"return","seconds":ProcessInfo.processInfo.systemUptime-maintenanceStarted,"lifecycle_turn":ticketCleanupLifecycleTurn,"yield_until":ticketCleanupYieldAt?.timeIntervalSince1970 as Any? ?? NSNull(),"retry_until":ticketCleanupRetryAt?.timeIntervalSince1970 as Any? ?? NSNull()])}
        let lease = try storageAdmission.acquire();defer { lease.finish() }
        ticketCleanupMaintenanceLock.lock();defer {ticketCleanupMaintenanceLock.unlock()}
        if try StorageSnapshotRetention.isActive(root:root) {observe?(["phase":"paused","reason":"snapshot_retention"]);return}
        if !(ticketCleanupRetryAt.map {$0 > Date()} ?? false) && !(ticketCleanupYieldAt.map {$0 > Date()} ?? false) {
            let started = Date()
            var prepared = false
            defer {
                // A busy cleanup backlog must yield CPU as well as the writer.
                // Charge all preparation wall time, including refused work. The
                // existing one-shot wake supplies four times that duration as rest.
                if prepared || ticketCleanupPreparingProject != nil {
                    scheduleTicketCleanupRest(since:started)
                }
            }
            // A refused preparation still consumed this turn. Give the other
            // queue its next opportunity after the existing retry/rest deadline.
            defer {ticketCleanupLifecycleTurn.toggle()}
            do {
                func lifecycle() throws {
                    observe?(["phase":"decision","turn":"lifecycle"])
                    try withTicketCleanupPreparation({db in
                        let result = try self.prepareTicketLifecycleCleanup(db);prepared = result != nil;return result
                    }) {db,_,value in try self.commitTicketLifecycleCleanup(db,prepared:value,at:Date())}
                }
                func deletion() throws {
                    observe?(["phase":"decision","turn":"deletion"])
                    prepared = try self.runTicketObjectDeletionCohort(observe:observe)
                }
                // Fair turns: a large admitted byte job cannot starve a newly
                // due settings/startup/Done pass, nor can passes starve unlinks.
                if ticketCleanupLifecycleTurn {try lifecycle();if !prepared {try deletion()}}
                else {try deletion();if !prepared {try lifecycle()}}
            } catch {
                observe?(["phase":"failure","code":(error as? CoreError)?.code ?? "CLEANUP_PREPARATION_UNAVAILABLE","error":String(describing:error)])
                dbQueue.writeWithoutTransaction {_ in
                    self.ticketCleanupRetryAt = Date().addingTimeInterval(60)
                    self.ticketCleanupFailure = self.ticketCleanupFailure ?? (error as? CoreError)?.code ?? "CLEANUP_PREPARATION_UNAVAILABLE"
                }
                throw error
            }
        }
        // CL-345: the archive cleanup reference scan reads a snapshot before the
        // object gate and the writer; the executor's transactions check its fence.
        let archiveScan = (storageMaintenanceRetryAt.map {$0 > Date()} ?? false) ? nil : prepareArchiveCleanupJobScan(nowMS:archiveCleanupNowMS())
        defer {finishArchiveCleanupScan(archiveScan)}
        try ArchiveStorageGate.withExclusive(root:root) { permit in
            dbQueue.writeWithoutTransaction { _ = self.performStorageMaintenance($0,permit:permit,archiveScan:archiveScan) }
        }
    }
}

/// Closed, content-free reply used by the service when authoritative storage
/// cannot open. It confers no project grant, enrollment or write authority.
public struct StorageRecoveryReply: Sendable {
    public let code: String
    public let reason: String
    public init(error: Error) {
        let source = error as? CoreError
        let rawCode = source?.code ?? "STORAGE_UNAVAILABLE"
        code = rawCode.utf8.count <= 80 && rawCode.utf8.allSatisfy({(65...90).contains($0) || (48...57).contains($0) || $0 == 95}) ? rawCode : "STORAGE_UNAVAILABLE"
        let rawReason = source?.details["reason"] as? String ?? "storage_bootstrap_failed"
        reason = rawReason.utf8.count <= 120 && rawReason.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || $0 == 95}) ? rawReason : "storage_bootstrap_failed"
    }
    public func response(to request: Data) -> Data {
        let payload: [String:Any]
        if request.count <= 4 * 1024 * 1024,
           let object = try? JSONSerialization.jsonObject(with:request) as? [String:Any],object["method"] as? String == "service_info" {
            payload = ["data":["service":"checklist","state":"recovery_required","mutations_available":false,"persistent_store_open":false,"restart_required":true,"recovery":["code":code,"reason":reason]]]
        } else {
            payload = ["error":["code":"RECOVERY_REQUIRED","message":"Checklist preserved its storage and paused data access. Repair storage or install a compatible build, then restart the service.","details":["reason":reason,"storage_code":code,"restart_required":true,"command_outcome":"rejected"]]]
        }
        return (try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)) ?? Data("{\"error\":{\"code\":\"RECOVERY_REQUIRED\",\"message\":\"Storage is paused.\"}}".utf8)
    }
}


/// Durable reasons distinguish verified absence/corruption from resource errors.
/// Only these transient causes are eligible on the next ordinary byte turn.
enum TicketCleanupCopyFailure {
    static func reason(_ error: Error) -> String {
        if let core = error as? CoreError {
            if let code = core.details["posix_errno"] as? NSNumber {return "backup_copy_unverified:POSIX_" + String(code.int32Value)}
            return "backup_copy_unverified:" + core.code
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {return "backup_copy_unverified:POSIX_" + String(ns.code)}
        if let failure = error as? StorageSnapshotFailure {
            if case .systemCall(let system) = failure {return "backup_copy_unverified:POSIX_" + String(system.code)}
            return "backup_copy_unverified:" + String(describing:failure)
        }
        return "backup_copy_unverified:" + ns.domain + "_" + String(ns.code)
    }
    static func isTransient(_ reason: String) -> Bool {
        [EMFILE,ENFILE,EINTR].contains {reason == "backup_copy_unverified:POSIX_" + String($0)}
        || reason == "backup_copy_unverified:deadline"
    }
}
