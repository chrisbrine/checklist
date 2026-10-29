import Foundation
import GRDB
import Darwin
import CryptoKit

/// All supported routers take this gate before entering the SQL writer. Reader
/// grants, links, backup holds and the final unlink therefore share one order.
final class ArchiveStoragePermit {
    fileprivate let files: StorageObjectFiles
    fileprivate var active = true
    fileprivate init(_ files: StorageObjectFiles) { self.files = files }
    func requireRoot(_ root: URL) throws {
        guard active,Data(files.root.path.utf8) == Data(root.standardizedFileURL.path.utf8) else { throw CoreError("STORAGE_GATE_REQUIRED", "Cleanup requires the current store's exclusive object gate.") }
    }
}
enum ArchiveStorageGate {
    static func withExclusive<T>(root: URL,files pinned: StorageObjectFiles? = nil,_ body: (ArchiveStoragePermit) throws -> T) throws -> T {
        let files: StorageObjectFiles
        if let pinned { try pinned.requireNamedRoot(root);files = pinned }
        else { files = try StorageObjectFiles(root:root) }
        let fd = openat(files.descriptor,".archive-storage.lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw CoreError("STORAGE_GATE_UNAVAILABLE", "The managed object gate cannot be opened.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_nlink == 1 else { throw CoreError("STORAGE_GATE_UNAVAILABLE", "The managed object gate is not a private regular file.") }
        while flock(fd,LOCK_EX) != 0 { if errno != EINTR { throw CoreError("STORAGE_GATE_UNAVAILABLE", "The managed object gate could not be acquired.") } }
        let permit = ArchiveStoragePermit(files)
        defer { permit.active = false;_ = flock(fd,LOCK_UN) }
        return try body(permit)
    }
}

/// A pinned, fully hashed regular file. Preparation happens on the maintenance
/// read lane. The final gate checks this exact descriptor and pathname again;
/// no content scan runs while ordinary writers wait for the object gate.
final class TicketObjectRemovalVerification {
    let root: Data
    let relative: Data
    let sha256: String
    let size: Int64
    let descriptor: Int32
    let identity: stat
    init?(root: URL,relative: String,sha256: String? = nil,size: Int64? = nil,check: () throws -> Void = {}) throws {
        let files = try StorageObjectFiles(root:root)
        let directory: Int32,name: String
        do {(directory,name) = try files.parent(relative)} catch {if StorageFolderAccess.isMissing(error) {return nil};throw error}
        defer {Darwin.close(directory)}
        let fd = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0,errno == ENOENT {return nil}
        guard fd >= 0 else {throw CoreError("CLEANUP_OBJECT_UNAVAILABLE","The original could not be opened safely.")}
        do {
            var before = stat(),after = stat()
            guard fstat(fd,&before) == 0,before.st_mode & S_IFMT == S_IFREG,(size == nil || before.st_size == size) else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Original identity changed; bytes retained.")}
            var hasher = SHA256(),buffer = [UInt8](repeating:0,count:65536),counted: Int64 = 0
            while true {
                try check()
                let count = Darwin.read(fd,&buffer,buffer.count)
                if count < 0,errno == EINTR {continue}
                guard count >= 0 else {throw CoreError("CLEANUP_OBJECT_UNAVAILABLE","Original verification failed; bytes retained.")}
                if count == 0 {break}
                counted += Int64(count)
                guard counted <= (size ?? before.st_size) else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Original size changed; bytes retained.")}
                hasher.update(data:Data(buffer.prefix(count)))
            }
            let digest = hasher.finalize().map {String(format:"%02x",$0)}.joined()
            guard counted == (size ?? before.st_size),(sha256 == nil || digest == sha256),fstat(fd,&after) == 0,Self.same(before,after) else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Original changed during verification; bytes retained.")}
            self.root = Data(root.standardizedFileURL.path.utf8);self.relative = Data(relative.utf8)
            self.sha256 = digest;self.size = counted;self.descriptor = fd;self.identity = after
        } catch {Darwin.close(fd);throw error}
    }
    deinit {Darwin.close(descriptor)}
    static func same(_ a: stat,_ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFREG && b.st_mode & S_IFMT == S_IFREG && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

extension ArchiveStoragePermit {
    /// The sole unlink path. Archive callers admit originals only; durable ticket
    /// intents also admit exact previews, capture files, sidecars and link text.
    /// No directory, followed link, external original or workspace is admitted.
    fileprivate func removeOriginal(relative: String,sha256: String,size: Int64,capturedSource: Bool = false,sourceBuildCache: Bool = false,linkTarget: String? = nil,verified: TicketObjectRemovalVerification? = nil,requirePreverified: Bool = false) throws -> Bool {
        try requireRoot(files.root)
        try StorageSnapshotRetention.requireNoCapture(root:files.root)
        let parts = try StorageObjectFiles.parts(relative)
        let source = capturedSource && parts.count >= 4 && parts[0] == "source-captures" && (parts[3] == "source" && parts.count >= 5 || parts.count == 4 && parts[3] == "manifest.json")
        let cache = sourceBuildCache && parts.count >= 3 && parts[0] == "source-build-cache" && parts[1].range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil
        guard size >= 0,sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              relative.hasPrefix("objects/") && linkTarget == nil || source || cache else { throw CoreError("CLEANUP_PATH_REFUSED", "Cleanup requires an exact managed object descriptor.") }
        let directory: Int32,name: String
        do {(directory,name) = try files.parent(relative)} catch {if StorageFolderAccess.isMissing(error) {return false};throw error}
        defer { Darwin.close(directory) }
        var originalFD: Int32 = -1
        defer {if originalFD >= 0 {Darwin.close(originalFD)}}
        if let linkTarget {
            var before = stat(),after = stat()
            if fstatat(directory,name,&before,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT {return false}
            guard before.st_mode & S_IFMT == S_IFLNK,Int64(linkTarget.utf8.count) == size,StorageObjectFiles.sha(Data(linkTarget.utf8)) == sha256 else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Captured link identity changed; bytes were retained.")}
            var buffer = [UInt8](repeating:0,count:65536)
            let count = readlinkat(directory,name,&buffer,buffer.count)
            guard count >= 0,Data(buffer.prefix(count)) == Data(linkTarget.utf8),fstatat(directory,name,&after,AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_dev == after.st_dev,before.st_ino == after.st_ino,before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Captured link changed during verification; bytes were retained.")}
        } else {
        if let verified {
            var current = stat(),entry = stat()
            guard verified.root == Data(files.root.standardizedFileURL.path.utf8),verified.relative == Data(relative.utf8),verified.sha256 == sha256,verified.size == size,
                  fstat(verified.descriptor,&current) == 0,fstatat(directory,name,&entry,AT_SYMLINK_NOFOLLOW) == 0,
                  TicketObjectRemovalVerification.same(verified.identity,current),TicketObjectRemovalVerification.same(current,entry) else {throw CoreError("CLEANUP_IDENTITY_CHANGED","Original changed after verification; bytes retained.")}
        } else {
            if requirePreverified {
                var entry = stat()
                if fstatat(directory,name,&entry,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT {return false}
                throw CoreError("CLEANUP_IDENTITY_CHANGED","Original appeared after verification; bytes retained.")
            }
        let fd = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0,errno == ENOENT { return false }
        guard fd >= 0 else { throw CoreError("CLEANUP_OBJECT_UNAVAILABLE", "The original could not be opened safely.") }
        originalFD = fd
        var before = stat();guard fstat(fd,&before) == 0,before.st_mode & S_IFMT == S_IFREG,before.st_size == size else { throw CoreError("CLEANUP_IDENTITY_CHANGED", "Original identity changed; bytes were retained.") }
        var hasher = SHA256(),buffer = [UInt8](repeating:0,count:65_536),counted: Int64 = 0
        while true {
            let n = Darwin.read(fd,&buffer,buffer.count)
            if n < 0,errno == EINTR { continue }
            guard n >= 0 else { throw CoreError("CLEANUP_OBJECT_UNAVAILABLE", "Original verification failed; bytes were retained.") }
            if n == 0 { break }
            counted += Int64(n);guard counted <= size else { throw CoreError("CLEANUP_IDENTITY_CHANGED", "Original size changed; bytes were retained.") }
            hasher.update(data:Data(buffer.prefix(n)))
        }
        let digest = hasher.finalize().map { String(format:"%02x",$0) }.joined()
        var after = stat(),entry = stat()
        guard counted == size,digest == sha256,fstat(fd,&after) == 0,fstatat(directory,name,&entry,AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev,before.st_ino == after.st_ino,before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              entry.st_mode & S_IFMT == S_IFREG,entry.st_dev == after.st_dev,entry.st_ino == after.st_ino else { throw CoreError("CLEANUP_IDENTITY_CHANGED", "Original changed during verification; bytes were retained.") }
        }
        }
        guard unlinkat(directory,name,0) == 0,fsync(directory) == 0 else { throw CoreError("CLEANUP_IO", "Cleanup needs reconciliation before its outcome can be confirmed.") }
        return true
    }
}

extension CommandRouter {
    private func archiveCleanupCursorID(_ job: ArchiveCleanupJob) -> String { "archive-cleanup-cursor:" + job.id.text }
    private func archiveCleanupIntentID(_ job: ArchiveCleanupJob,_ id: ArchiveAttachmentID) -> String { "archive-cleanup-delete:" + hash(Data((job.id.text + ":" + id.text).utf8)) }
    private func archiveCleanupRelativePath(_ attachment: JSON) throws -> String {
        guard attachment["mode"] as? String == "managed",let path = attachment["path"] as? String else { throw CoreError("CLEANUP_PATH_REFUSED", "External originals cannot be removed.") }
        return try managedRelative(path,family:"objects")
    }
    /// Internal synchronous service pump: at most eight metadata admissions and
    /// one exact original per call. The service schedules a one-shot continuation.
    /// Persisted job, cursor and deletion intent survive router/process restart.
    func processArchiveCleanupJobs(_ db: Database,permit: ArchiveStoragePermit,nowMS: Int64) throws {
        try permit.requireRoot(root)
        guard !db.isInsideTransaction else { throw CoreError("CLEANUP_TRANSACTION_REQUIRED", "Run cleanup after the semantic transaction commits.") }
        guard try !StorageSnapshotRetention.isActive(root:root) else {return}
        let ids = try String.fetchAll(db,sql:"""
            SELECT j.id FROM records j LEFT JOIN records c ON c.id=('archive-cleanup-cursor:' || j.id) AND c.type='storage_job'
            WHERE j.rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='cleanup_job') AND CASE WHEN json_valid(j.data) THEN COALESCE(json_extract(j.data,'$.not_before_ms') <= ?,1) ELSE 1 END AND CASE WHEN json_valid(j.data) THEN json_extract(j.data,'$.state') NOT IN ('completed','canceled','suspended') ELSE 1 END
            ORDER BY CASE WHEN json_valid(c.data) THEN COALESCE(json_extract(c.data,'$.checked_at_ms'),0) ELSE 0 END,j.rowid LIMIT 8
            """,arguments:[nowMS])
        var admissions = 0
        for id in ids {
            var job = try cleanupJobDecode(record(db,id,type:"cleanup_job"))
            guard nowMS >= job.notBeforeMS else { continue }
            var cursor: JSON = (try archiveCleanupRecordIfPresent(db,archiveCleanupCursorID(job),type:"storage_job")) ?? ["id":archiveCleanupCursorID(job),"project_id":job.projectID.text,"task_id":job.taskID.text,"kind":"archive_cleanup_cursor","state":"idle","revision":0,"next_index":0]
            guard cursor["kind"] as? String == "archive_cleanup_cursor",cleanupJobEqual(cursor["task_id"],job.taskID.text),cleanupJobEqual(cursor["project_id"],job.projectID.text) else { throw CoreError("CLEANUP_CURSOR_INVALID", "Cleanup cursor requires repair; originals retained.") }
            let start = max(0,int(cursor,"next_index")) % job.items.count
            for offset in 0..<job.items.count where admissions < ArchiveCleanupJob.admissionStepLimit {
                let index = (start + offset) % job.items.count,item = job.items[index]
                if item.terminal { continue }; admissions += 1
                cursor["next_index"] = (index + 1) % job.items.count;cursor["checked_at_ms"] = nowMS
                var precedingFailure: ArchiveCleanupJob.Failure?
                var precedingFailureCount = 0
                do {
                    var eligible = false
                    try withValidatedDomainTransaction(db) {
                        let raw = try self.record(db,id,type:"cleanup_job");job = try self.cleanupJobDecode(raw)
                        if let previous = job.items.first(where: {$0.original.id == item.original.id}) { precedingFailure = previous.failure;precedingFailureCount = previous.sameFailureCount }
                        let task = try self.scoped(db,job.taskID.text,job.projectID.text,type:"task")
                        if !bool(task,"archived") { _ = job.cancel();try self.save(db,job.record(revision:self.nextCleanupJobRevision(raw)),type:"cleanup_job");return .commit }
                        let a = try self.scoped(db,item.original.id.text,job.projectID.text,type:"attachment")
                        let graph = try self.archiveCleanupReferenceRows(db)
                        var holds = try self.completeArchiveCleanupHolds(db,attachment:a,task:task,currentGraph:graph)
                        let currentSize = try ArchiveCleanupJob.integer(a["size"]),currentRevision = try ArchiveCleanupJob.integer(a["revision"])
                        if !self.cleanupJobEqual(a["task_id"],job.taskID.text) || a["sha256"] as? String != item.original.sha256 || currentSize != item.original.logicalBytes || currentRevision != item.original.attachmentRevision { holds.insert(.changedIdentity) }
                        let project = try self.record(db,job.projectID.text,type:"project")
                        let plan = try ArchiveRetentionPlanner.make(configuration:self.archiveRetentionConfiguration(project),facts:self.archiveRetentionFacts(db,task:task,currentGraph:graph))
                        if !plan.selected.contains(where: {$0.id == item.original.id}) { holds.insert(.policyNoLongerSelects) }
                        try job.observe([.init(projectID:job.projectID,taskID:job.taskID,original:item.original,referencesComplete:true,holds:holds)],nowMS:nowMS)
                        if try jsonString(job.record(revision:ArchiveCleanupJob.integer(raw["revision"]))) != jsonString(raw) { try self.save(db,job.record(revision:self.nextCleanupJobRevision(raw)),type:"cleanup_job") }
                        if holds.isEmpty {
                            let relative = try self.archiveCleanupRelativePath(a),intentID = self.archiveCleanupIntentID(job,item.original.id)
                            let prior = try self.archiveCleanupRecordIfPresent(db,intentID,type:"storage_job")
                            let intent: JSON = ["id":intentID,"project_id":job.projectID.text,"task_id":job.taskID.text,"kind":"archive_cleanup_delete","state":"marked","revision":int(prior ?? [:],"revision") + 1,"cleanup_job_id":job.id.text,"attachment_id":item.original.id.text,"relative_path":relative,"sha256":item.original.sha256,"logical_bytes":item.original.logicalBytes]
                            try self.save(db,intent,type:"storage_job");eligible = true
                        }
                        return .commit
                    }
                    if eligible {
                        // Fresh complete graph inside an actual writer transaction,
                        // after the durable intent and immediately before unlink.
                        try withValidatedDomainTransaction(db) {
                            let raw = try self.record(db,id,type:"cleanup_job");job = try self.cleanupJobDecode(raw)
                            guard ![.canceled,.completed,.suspended].contains(job.state),nowMS >= job.notBeforeMS else { return .commit }
                            let task = try self.scoped(db,job.taskID.text,job.projectID.text,type:"task")
                            guard bool(task,"archived") else { return .commit }
                            var a = try self.scoped(db,item.original.id.text,job.projectID.text,type:"attachment")
                            guard try self.completeArchiveCleanupHolds(db,attachment:a,task:task).isEmpty,
                                  a["sha256"] as? String == item.original.sha256,try ArchiveCleanupJob.integer(a["revision"]) == item.original.attachmentRevision else { return .commit }
                            let relative = try self.archiveCleanupRelativePath(a)
                            let removed = try permit.removeOriginal(relative:relative,sha256:item.original.sha256,size:item.original.logicalBytes)
                            try job.recordDeletion(id:item.original.id,alreadyMissing:!removed)
                            a["availability"] = removed ? "original_cleaned" : "original_missing";a["cleanup_state"] = "complete";a["cleaned_at"] = now();a["cleanup_job_id"] = id
                            try self.save(db,self.revised(a),type:"attachment");try self.save(db,job.record(revision:self.nextCleanupJobRevision(raw)),type:"cleanup_job")
                            var intent = try self.record(db,self.archiveCleanupIntentID(job,item.original.id),type:"storage_job");intent["state"] = removed ? "removed" : "already_missing";try self.save(db,self.revised(intent),type:"storage_job")
                            try self.event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:job.projectID.text,entity:job.taskID.text,kind:removed ? "attachment_original_cleaned" : "attachment_original_missing",data:["attachment_id":item.original.id.text,"cleanup_job_id":id,"active_store_logical_bytes_removed":removed ? item.original.logicalBytes : 0,"physical_reclamation":"unmeasured","backup_retained_physical_bytes":NSNull()])
                            return .commit
                        }
                        try withValidatedDomainTransaction(db) { try self.save(db,self.revised(cursor),type:"storage_job");return .commit }
                        return
                    }
                } catch {
                    // A failure after unlink may have rolled its SQL outcome back.
                    // The durable marked intent is preserved; retry verifies absence.
                    try withValidatedDomainTransaction(db) {
                        let raw = try self.record(db,id,type:"cleanup_job");var current = try self.cleanupJobDecode(raw)
                        let code: ArchiveCleanupJob.Failure = (error as? CoreError)?.code == "CLEANUP_IDENTITY_CHANGED" ? .identityChanged : (error is DatabaseError ? .metadataUnavailable : .admissionUnavailable)
                        if ![.canceled,.completed,.suspended].contains(current.state) {
                            // Admission's ready projection clears metadata failures;
                            // preserve consecutive executor failure history explicitly.
                            let target = min(2,(precedingFailure == code ? precedingFailureCount : 0) + 1)
                            let present = current.items.first(where: {$0.original.id == item.original.id})
                            let existing = present?.failure == code ? (present?.sameFailureCount ?? 0) : 0
                            for _ in 0..<max(1,target - existing) { try current.recordFailure(id:item.original.id,code:code) }
                            try self.save(db,current.record(revision:self.nextCleanupJobRevision(raw)),type:"cleanup_job")
                        }
                        return .commit
                    }
                }
            }
            try withValidatedDomainTransaction(db) { try self.save(db,self.revised(cursor),type:"storage_job");return .commit }
            if admissions >= ArchiveCleanupJob.admissionStepLimit { break }
        }
    }
    /// Service uses a one-shot deadline, never a polling/model timer. Held work
    /// resumes on a relevant command or an expiring actual reader/backup lease.
    public func nextArchiveCleanupDeadline() throws -> Date? {
        let lease = try storageAdmission.acquire();defer {lease.finish()}
        if try StorageSnapshotRetention.isActive(root:root) {return Date().addingTimeInterval(60)}
        // Pure scheduling metadata must not occupy the writer while retained
        // storage-job JSON is inspected. Retry/yield properties are lock-backed;
        // the service coalesces a fresh plan after concurrent command activity.
        // Enumerate each family through the covering scope index before loading
        // JSON; a type-only table scan also touches unrelated retained payloads.
        return try readForPreparation { db in
            let nowMS = self.archiveCleanupNowMS()
            let deadline = try Int64.fetchOne(db,sql:"SELECT MIN(CAST(json_extract(data,'$.not_before_ms') AS INTEGER)) FROM records WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='cleanup_job') AND json_valid(data) AND json_extract(data,'$.state') IN ('queued','ready')")
            let expiry = try Double.fetchOne(db,sql:"SELECT MIN(CAST(json_extract(data,'$.expires_at') AS REAL)) FROM records WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='storage_hold') AND json_valid(data) AND json_extract(data,'$.state')='active' AND CAST(json_extract(data,'$.expires_at') AS REAL)>?",arguments:[Date().timeIntervalSince1970])
            let more = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records j,json_each(j.data,'$.items') i WHERE j.rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='cleanup_job') AND json_valid(j.data) AND json_extract(j.data,'$.state')='held' AND (json_extract(i.value,'$.state')='waiting' OR json_extract(i.value,'$.same_failure_count')=1))") ?? false
            let pendingProjects = try String.fetchAll(db,sql:"SELECT DISTINCT project_id FROM records WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='storage_job') AND (" + Self.ticketObjectDeletionReadySQL + ")")
            let deletionDeadline = try pendingProjects.map {max(Int64((try self.ticketCleanupProjectRetry(db,project:$0) ?? .distantPast).timeIntervalSince1970 * 1000),nowMS + 50)}.min()
            let lifecycle = try self.nextTicketCleanupDeadline(db)
            let retry = [self.ticketCleanupRetryAt,self.ticketCleanupYieldAt].compactMap {$0}.max().map {Int64($0.timeIntervalSince1970 * 1000)}
            let routineRetry = self.storageMaintenanceRetryAt.map {Int64($0.timeIntervalSince1970 * 1000)}
            let next = [lifecycle.map { max(Int64($0.timeIntervalSince1970 * 1000),retry ?? 0,nowMS + 50) },deletionDeadline.map {max($0,retry ?? 0)},deadline.map { max($0,routineRetry ?? 0,nowMS + 50) },expiry.map { Int64($0 * 1000) },more ? max(routineRetry ?? 0,nowMS + 1000) : nil,routineRetry].compactMap {$0}.min()
            return next.map { Date(timeIntervalSince1970:Double($0)/1000) }
        }
    }
}


extension CommandRouter {
    /// Shares archive cleanup's object gate, durable admission, final writer
    /// checks and sole verified unlink. Read-lane verification is amortized over
    /// a batch; the writer yields after 128 objects or 25 ms of object work.
    @discardableResult
    func processTicketObjectDeletionIntents(_ db: Database,permit: ArchiveStoragePermit,prepared: TicketCleanupPreparedDeletion) throws -> JSON {
        try permit.requireRoot(root)
        guard !db.isInsideTransaction else {throw CoreError("CLEANUP_TRANSACTION_REQUIRED","Run object deletion after the semantic transaction commits.")}
        guard try !StorageSnapshotRetention.isActive(root:root) else {return prepared.receipt}
        var receipt = prepared.receipt
        guard var objects = receipt["objects"] as? [JSON],objects.count <= 100000,objects.contains(where: {$0["state"] as? String == "pending"}) else {throw CoreError("CLEANUP_INTENT_INVALID","The deletion intent requires repair; bytes retained.")}
        if prepared.reactivated {
            // Publish the resumed exact intent before the first possible unlink.
            // A crash then resumes ordinary pending work, never a path sweep.
            receipt = revised(receipt)
            try withValidatedDomainTransaction(db) {try self.save(db,receipt,type:"storage_job");return .commit}
        }
        var attempted: [Int] = [],outcome = receipt
        do {
            try withValidatedDomainTransaction(db) {
                if let reason = try self.ticketCleanupDeletionBlocker(db,receipt:receipt) {
                    for i in objects.indices where objects[i]["state"] as? String == "pending" {objects[i]["state"] = "retained";objects[i]["reasons"] = [reason]}
                    outcome = try self.saveTicketObjectDeletionOutcome(db,receipt:receipt,objects:objects,backupGenerationRow:prepared.backupGenerationRow);return .commit
                }
                let references = prepared.references,mediaAuthorityComplete = prepared.mediaAuthorityComplete,backup = prepared.backup
                for i in objects.indices where objects[i]["state"] as? String == "pending" && objects[i]["kind"] as? String == "symlink" {
                    let holds = try self.ticketObjectDeletionHolds(db,object:objects[i],references:references,backup:backup,mediaAuthorityComplete:mediaAuthorityComplete)
                    if !holds.isEmpty {objects[i]["state"] = "retained";objects[i]["reasons"] = holds.sorted()}
                }
                var pendingTargets = Self.retainTicketObjectDeletionLinkTargets(&objects)
                let started = ProcessInfo.processInfo.systemUptime
                for index in objects.indices where objects[index]["state"] as? String == "pending" {
                    guard let path = objects[index]["relative_path"] as? String,prepared.candidatePaths.contains(path),!pendingTargets.contains(path) else {continue}
                    if attempted.count >= 128 || !attempted.isEmpty && ProcessInfo.processInfo.systemUptime-started >= 0.025 {break}
                    attempted.append(index)
                    let object = objects[index]
                    var result = object
                    do {
                        let holds = try self.ticketObjectDeletionHolds(db,object:object,references:references,backup:backup,mediaAuthorityComplete:mediaAuthorityComplete)
                        if !holds.isEmpty {result["state"] = "retained";result["reasons"] = holds.sorted()}
                        else {
                            guard let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value,
                                  object["kind"] as? String == "file" || object["kind"] as? String == "symlink" else {throw CoreError("CLEANUP_INTENT_INVALID","The deletion descriptor requires repair; bytes retained.")}
                            if let failure = prepared.verificationFailures[path] {throw failure}
                            let removed = try permit.removeOriginal(relative:path,sha256:sha,size:size,capturedSource:path.hasPrefix("source-captures/"),sourceBuildCache:object["representation"] as? String == "source_build_cache",linkTarget:object["link_target"] as? String,verified:prepared.verifications[path],requirePreverified:true)
                            result["state"] = removed ? "removed" : "already_missing"
                        }
                    } catch {
                        let failures = int(object,"failures") + 1,code = (error as? CoreError)?.code ?? "CLEANUP_UNAVAILABLE"
                        result["failures"] = failures;result["last_failure"] = code
                        if failures >= 2 {result["state"] = "retained";result["reasons"] = [code]}
                    }
                    objects[index] = result
                    if object["kind"] as? String == "symlink" {pendingTargets = Self.retainTicketObjectDeletionLinkTargets(&objects)}
                    try self.recordTicketCleanupAvailability(db,receipt:receipt,object:result)
                }
                _ = Self.retainTicketObjectDeletionLinkTargets(&objects)
                outcome = try self.saveTicketObjectDeletionOutcome(db,receipt:receipt,objects:objects,backupGenerationRow:prepared.backupGenerationRow)
                return .commit
            }
        } catch {
            // A failed SQL outcome never invents committed removals. Retry the
            // original intent and observe any already absent paths honestly.
            try withValidatedDomainTransaction(db) {
                objects = receipt["objects"] as? [JSON] ?? []
                for index in attempted {
                    let failures = int(objects[index],"failures") + 1,code = (error as? CoreError)?.code ?? "CLEANUP_UNAVAILABLE"
                    objects[index]["failures"] = failures;objects[index]["last_failure"] = code
                    if failures >= 2 {objects[index]["state"] = "retained";objects[index]["reasons"] = [code]}
                }
                _ = Self.retainTicketObjectDeletionLinkTargets(&objects)
                outcome = try self.saveTicketObjectDeletionOutcome(db,receipt:receipt,objects:objects,backupGenerationRow:prepared.backupGenerationRow)
                return .commit
            }
        }
        return outcome
    }

    private func saveTicketObjectDeletionOutcome(_ db: Database,receipt: JSON,objects: [JSON],backupGenerationRow: Int64) throws -> JSON {
        var receipt = receipt;receipt["objects"] = objects
        receipt["summary"] = Self.ticketObjectDeletionSummary(objects)
        receipt["state"] = objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed"
        receipt["checked_at"] = now()
        receipt = revised(receipt)
        try save(db,receipt,type:"storage_job")
        if receipt["cause"] as? String == "task_purge",let id = receipt["id"] as? String {
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-backup-seen:" + id,String(backupGenerationRow)])
        }
        if receipt["cause"] as? String == "done_evidence",receipt["state"] as? String == "completed",int(receipt,"cleanup_policy_version") < 2,let project = receipt["project_id"] as? String,let task = receipt["task_id"] as? String {
            // Old pending jobs had incomplete history-owner fingerprints. Keep
            // their outcome and wake only their ticket for a corrected plan.
            // A fresh token survives an older preparation of the same ticket.
            let clock = Date()
            var retries = try ticketCleanupRetryEntries(db,project:project)
            retries[task] = TicketCleanupRetry(at:clock)
            try saveTicketCleanupRetries(db,project:project,entries:retries)
            let previous = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + project]) ?? "0") ?? 0
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + project,String(min(previous,clock.timeIntervalSince1970))])
        }
        return receipt
    }
}
