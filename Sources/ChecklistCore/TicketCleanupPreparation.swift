import Foundation
import GRDB

struct TicketCleanupPreparedPass: TicketCleanupPrepared {
    let fence: TicketCleanupFence
    let project: JSON
    let selection: JSON
    let plans: [String:TicketPurgePlan]
    let expiredCommands: [String:[Row]]
    var itemFences: [String:TicketCleanupFence] = [:]
}
struct TicketCleanupPreparedDeletion: TicketCleanupPrepared {
    let fence: TicketCleanupFence
    let receipt: JSON
    let reactivated: Bool
    let backupGenerationRow: Int64
    let references: TicketObjectDeletionReferenceIndex
    let backup: StorageBackupRetentionIndex?
    let mediaAuthorityComplete: Bool
    let candidatePaths: Set<String>
    let verifications: [String:TicketObjectRemovalVerification]
    let verificationFailures: [String:Error]
}

extension CommandRouter {
    /// Observe only bounded changed rows on the writer; preparation stays on the
    /// separate lane. Relevant changes refuse safely and arm a durable backoff.
    func withTicketCleanupPreparation<T: TicketCleanupPrepared>(_ prepare: (Database) throws -> T?,continuing: ((Database,T) throws -> T?)? = nil,commit: (Database,ArchiveStoragePermit,T) throws -> Void) throws {
        if ticketCleanupRetryAt.map({$0 > Date()}) ?? false {return}
        ticketCleanupPreparingProject = nil
        do {
            if (readers == nil || ticketCleanupNeedsReader) && ticketCleanupReaders == nil {
                var configuration = Configuration();configuration.readonly = true
                configuration.prepareDatabase {db in
                    try SchemaMigrations.installStorageCollation(db);Self.installTicketSearchFunctions(db)
                    try db.execute(sql:"PRAGMA busy_timeout=5000")
                }
                do {ticketCleanupReaders = try DatabasePool(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)}
                catch {throw CoreError("CLEANUP_READ_LANE_UNAVAILABLE","Cleanup is deferred until a separate read lane can open.")}
            }
            guard let readers = ticketCleanupNeedsReader ? ticketCleanupReaders : (readers ?? ticketCleanupReaders) else {throw CoreError("CLEANUP_READ_LANE_UNAVAILABLE","Cleanup needs a separate read lane.")}
            let generation = try dbQueue.writeWithoutTransaction {db -> Int? in
                try db.inSavepoint {try TicketCleanupChanges.install(db);return .commit}
                return try Int.fetchOne(db,sql:"PRAGMA data_version")
            }
            defer {try? dbQueue.writeWithoutTransaction {try TicketCleanupChanges.remove($0)}}
            var prepared: T
            do {guard let value = try readers.read({db in try autoreleasepool {try prepare(db)}}) else {
                if let project = ticketCleanupPreparingProject {try dbQueue.writeWithoutTransaction {db in
                    var state = try self.ticketCleanupPreparationState(db,project:project);state["state"] = "idle"
                    try self.saveTicketCleanupPreparationState(db,project:project,state:state)
                }}
                return
            };prepared = value}
            catch is DatabaseError {
                ticketCleanupNeedsReader = true
                try? ticketCleanupReaders?.close();ticketCleanupReaders = nil
                throw CoreError("CLEANUP_READ_LANE_UNAVAILABLE","Cleanup will retry a separate read lane; bytes retained.")
            }
            while true {
                try ArchiveStorageGate.withExclusive(root:root) {permit in
                    try dbQueue.writeWithoutTransaction {db in
                        try autoreleasepool {
                            guard try Int.fetchOne(db,sql:"PRAGMA data_version") == generation else {throw CoreError("CLEANUP_CONCURRENT_WRITE","An external writer changed the cleanup snapshot.")}
                            guard try !StorageSnapshotRetention.isActive(root:root) else {throw CoreError("BACKUP_CAPTURE_ACTIVE","Cleanup deferred for a backup capture.")}
                            prepared = try prepared.revalidated(db,router:self)
                            try commit(db,permit,prepared)
                            var state = try self.ticketCleanupPreparationState(db,project:prepared.fence.projectID)
                            state["state"] = bool(state,"attempt_refused") ? "deferred" : "committed";state["committed_at"] = now()
                            if !bool(state,"attempt_refused") {state["next_attempt_at"] = NSNull()}
                            try self.saveTicketCleanupPreparationState(db,project:prepared.fence.projectID,state:state)
                            self.ticketCleanupRetryAt = nil;self.ticketCleanupFailure = nil
                        }
                    }
                }
                guard let continuing,let next = try readers.read({db in try autoreleasepool {try continuing(db,prepared)}}) else {break}
                prepared = next
            }
        } catch {
            let retry = Date().addingTimeInterval(60),reason = (error as? CoreError)?.details["reason"] as? String ?? (error as? CoreError)?.code ?? "CLEANUP_PREPARATION_UNAVAILABLE"
            if (error as? CoreError)?.code != "CLEANUP_CONCURRENT_WRITE" {ticketCleanupRetryAt = retry;ticketCleanupFailure = reason}
            if let project = ticketCleanupPreparingProject {try dbQueue.writeWithoutTransaction {db in
                var state = try self.ticketCleanupPreparationState(db,project:project)
                state["state"] = "deferred";state["last_failed_at"] = now();state["last_failure_reason"] = reason;state["next_attempt_at"] = ISO8601DateFormatter().string(from:retry)
                try self.saveTicketCleanupPreparationState(db,project:project,state:state)
            }}
            // A fenced attempt is an expected refusal, never a successful pass.
            if (error as? CoreError)?.code != "CLEANUP_CONCURRENT_WRITE" {throw error}
        }
    }
    func beginTicketCleanupPreparation(project: String) throws {
        ticketCleanupPreparingProject = project
        try dbQueue.writeWithoutTransaction {db in
            var state = try self.ticketCleanupPreparationState(db,project:project)
            state["attempted_at"] = now();state["state"] = "preparing";state["attempt_count"] = int(state,"attempt_count") + 1;state.removeValue(forKey:"attempt_refused")
            try self.saveTicketCleanupPreparationState(db,project:project,state:state)
        }
    }
    func recordTicketCleanupPreparationRefusal(project: String,reason: String) throws {
        try dbQueue.writeWithoutTransaction {db in try self.recordTicketCleanupPreparationRefusal(db,project:project,reason:reason)}
    }
    func recordTicketCleanupPreparationRefusal(_ db: Database,project: String,reason: String) throws {
        var state = try ticketCleanupPreparationState(db,project:project)
        state["attempt_refused"] = true;state["last_failed_at"] = now();state["last_failure_reason"] = reason
        state["next_attempt_at"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(60))
        try saveTicketCleanupPreparationState(db,project:project,state:state)
    }
    func ticketCleanupProjectRetry(_ db: Database,project: String) throws -> Date? {
        (try ticketCleanupPreparationState(db,project:project)["next_attempt_at"] as? String).flatMap {ISO8601DateFormatter().date(from:$0)}
    }
    func ticketCleanupPreparationState(_ db: Database,project: String) throws -> JSON {
        jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-preparation:" + project]) ?? "{}")
    }
    private func saveTicketCleanupPreparationState(_ db: Database,project: String,state: JSON) throws {
        try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-preparation:" + project,try jsonString(state)])
    }
    func scheduleTicketCleanupRest(since started: Date,at time: Date = Date()) {
        let rest = time.addingTimeInterval(max(0.05,time.timeIntervalSince(started) * 4))
        let projectRetry = try? dbQueue.read {db -> Date? in
            guard let project = self.ticketCleanupPreparingProject else {return nil}
            return try self.ticketCleanupProjectRetry(db,project:project)
        }
        // An explicit refusal retry is already a rest deadline. Long failed
        // preparations must not hide that durable wake behind a longer yield.
        ticketCleanupYieldAt = max(time,[rest,projectRetry,ticketCleanupRetryAt].compactMap {$0}.min() ?? rest)
    }
    func runTicketLifecycleCleanup(at time: Date = Date()) throws {
        ticketCleanupMaintenanceLock.lock();defer {ticketCleanupMaintenanceLock.unlock()}
        try withTicketCleanupPreparation({try self.prepareTicketLifecycleCleanup($0,at:time)}) {db,_,prepared in
            try self.commitTicketLifecycleCleanup(db,prepared:prepared,at:time)
        }
    }
    func prepareTicketObjectDeletion(_ db: Database) throws -> TicketCleanupPreparedDeletion? {
        guard let raw = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='storage_job' AND (" + Self.ticketObjectDeletionReadySQL + ") AND NOT EXISTS(SELECT 1 FROM metadata m WHERE m.key='ticket-cleanup-preparation:'||records.project_id AND json_valid(m.value) AND json_extract(m.value,'$.next_attempt_at')>?) ORDER BY rowid LIMIT 1",arguments:[now()]) else {return nil}
        var receipt = try GRDBRecordEnvelopeAdapter.decode(raw).object
        let reactivated = receipt["state"] as? String == "completed"
        if reactivated {
            var objects = receipt["objects"] as? [JSON] ?? []
            for index in objects.indices where objects[index]["state"] as? String == "retained" {
                let reasons = Set(objects[index]["reasons"] as? [String] ?? [])
                if !reasons.isEmpty,reasons.isSubset(of:Self.ticketObjectDeletionRetryReasons) {objects[index]["state"] = "pending";objects[index].removeValue(forKey:"reasons")}
            }
            receipt["objects"] = objects;receipt["state"] = "pending";receipt["summary"] = Self.ticketObjectDeletionSummary(objects)
        }
        let backupGenerationRow = try ticketCleanupBackupGenerationRow(db)
        if receipt["cause"] as? String == "task_purge" {receipt["cleanup_policy_version"] = 2}
        try beginTicketCleanupPreparation(project: (try StoredRecord(receipt, family: "receipt").string("project_id")))
        let inventory = try ticketCleanupInventory(db,receipt:receipt)
        let graph = try ticketCleanupDeletionReferences(db,receipt:receipt,inventory:inventory)
        let historicalOwners = receipt["cause"] as? String == "done_evidence" ? Set((receipt["owned_record_fingerprints"] as? [String:String] ?? [:]).keys.map {Data($0.utf8)}) : []
        let references = try TicketObjectDeletionReferenceIndex(graph,tokens:inventory.tokens,historicalOwners:historicalOwners)
        var backup = try? ticketCleanupBackupRetentionIndex(db,objects:receipt["objects"] as? [JSON] ?? [])
        let mediaComplete = (try? ticketCleanupValidateMediaAuthority(db)) != nil
        let fence = try TicketCleanupFence(
            db, inventory: inventory, project: (try StoredRecord(receipt, family: "receipt").string("project_id")),
            ids: [
                (try StoredRecord(receipt, family: "receipt").string("id")), (try StoredRecord(receipt, family: "receipt").string("task_id")),
                (try StoredRecord(receipt, family: "receipt").string("project_id")),
            ])
        return try prepareTicketObjectDeletionCandidates(db,receipt:receipt,reactivated:reactivated,backupGenerationRow:backupGenerationRow,references:references,backup:&backup,mediaComplete:mediaComplete,fence:fence)
    }

    func prepareTicketObjectDeletionCandidates(_ db: Database,receipt: JSON,reactivated: Bool,backupGenerationRow: Int64,references: TicketObjectDeletionReferenceIndex,backup: inout StorageBackupRetentionIndex?,mediaComplete: Bool,fence: TicketCleanupFence) throws -> TicketCleanupPreparedDeletion {
        if Self.isLegacyDoneEvidenceDeletion(receipt) {
            return .init(fence:fence,receipt:receipt,reactivated:reactivated,backupGenerationRow:backupGenerationRow,references:references,backup:nil,mediaAuthorityComplete:mediaComplete,candidatePaths:[],verifications:[:],verificationFailures:[:])
        }
        var objects = receipt["objects"] as? [JSON] ?? []
        for i in objects.indices where objects[i]["state"] as? String == "pending" && objects[i]["kind"] as? String == "symlink" {
            let holds = try ticketObjectDeletionHolds(db,object:objects[i],references:references,backup:backup,mediaAuthorityComplete:mediaComplete)
            if !holds.isEmpty {objects[i]["state"] = "retained";objects[i]["reasons"] = holds.sorted()}
        }
        let targets = Self.retainTicketObjectDeletionLinkTargets(&objects)
        var candidates = Set<String>(),verifications: [String:TicketObjectRemovalVerification] = [:],failures: [String:Error] = [:]
        let started = ProcessInfo.processInfo.systemUptime
        // Amortize the immutable reference/backup observation across a bounded
        // batch. Stop admitting after one second; a single large object's
        // cooperative verification retains the existing sixty-second ceiling.
        for object in objects where object["state"] as? String == "pending" && !targets.contains(object["relative_path"] as? String ?? "") {
            if candidates.count >= 256 || !candidates.isEmpty && ProcessInfo.processInfo.systemUptime-started >= 1 {break}
            guard let path = object["relative_path"] as? String else {continue}
            candidates.insert(path)
            guard try ticketObjectDeletionHolds(db,object:object,references:references,backup:backup,mediaAuthorityComplete:mediaComplete).isEmpty else {continue}
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            let check = {guard ProcessInfo.processInfo.systemUptime < deadline else {throw StorageSnapshotFailure.deadline}}
            backup?.verifyCopy(for:object,check:check)
            guard try ticketObjectDeletionHolds(db,object:object,references:references,backup:backup,mediaAuthorityComplete:mediaComplete).isEmpty,
                  object["kind"] as? String == "file",let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {continue}
            do {verifications[path] = try TicketObjectRemovalVerification(root:root,relative:path,sha256:sha,size:size,check:check)} catch {failures[path] = error}
        }
        return TicketCleanupPreparedDeletion(fence:fence,receipt:receipt,reactivated:reactivated,backupGenerationRow:backupGenerationRow,references:references,backup:backup,mediaAuthorityComplete:mediaComplete,candidatePaths:candidates,verifications:verifications,verificationFailures:failures)
    }
}
