import Foundation
import GRDB

extension CommandRouter {
    func archiveCleanupRecordIfPresent(_ db: Database,_ id: String,type: String) throws -> JSON? {
        do { return try record(db,id,type:type) }
        catch let error as CoreError where error.code == "NOT_FOUND" { return nil }
    }
    func cleanupJobEqual(_ lhs: Any?,_ rhs: Any?) -> Bool {
        guard let lhs = lhs as? String,let rhs = rhs as? String else {return false}
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
    func cleanupJobDecode(_ value: JSON) throws -> ArchiveCleanupJob {
        do {return try ArchiveCleanupJob(record:value)}
        catch {throw CoreError("CLEANUP_JOB_INVALID","Cleanup job metadata needs repair. No original was deleted.")}
    }
    func cleanupJobProjection(_ job: ArchiveCleanupJob,revision: Int64,knownBackupRetainedLogicalBytes: Int64? = nil) throws -> JSON {
        let totals = try job.logicalTotals()
        var value = try job.record(revision:revision)
        value["selected_logical_original_bytes"] = totals.selected
        value["removed_logical_original_bytes"] = totals.removed
        value["already_missing_logical_original_bytes"] = totals.alreadyMissing
        value["physical_reclamation"] = "unmeasured"
        value["backup_retained_physical_bytes"] = NSNull()
        value["known_backup_retained_logical_original_bytes"] = knownBackupRetainedLogicalBytes.map { $0 as Any } ?? NSNull()
        value["backup_retention_observation"] = knownBackupRetainedLogicalBytes == nil ? "unavailable" : "verified_at_backup_current_presence_unverified"
        value["can_cancel_remaining"] = ![.canceled,.completed].contains(job.state)
        value["deletion_outcome_recorded"] = job.items.contains(where: {$0.state == .removed || $0.state == .alreadyMissing})
        value["original_restoration"] = "not_evaluated"
        return value
    }
    func nextCleanupJobRevision(_ value: JSON) throws -> Int64 {
        let old = try ArchiveCleanupJob.integer(value["revision"])
        let (next,overflow) = old.addingReportingOverflow(1)
        guard old > 0,!overflow else {throw CoreError("CLEANUP_JOB_INVALID","Cleanup job revision needs repair.")};return next
    }
    /// INTERNAL enqueue basis from a later current settings/preview adapter, never public arbitrary job data.
    /// Called inside the same validated semantic transaction as archive+its durable command receipt.
    /// No cleanup/delete/maintenance is performed here. The caller supplies a real future Undo deadline.
    func enqueueArchiveCleanupJob(_ db: Database,task: JSON,settingsRevision: Int64,previewID: String,plan: ArchiveRetentionPlan,nowMS: Int64,notBeforeMS: Int64,caller: Caller) throws -> JSON? {
        guard db.isInsideTransaction,let pid = task["project_id"] as? String,let tid = task["id"] as? String else {throw CoreError("CLEANUP_TRANSACTION_REQUIRED","Enqueue cleanup with the guarded archive transaction.")}
        _ = try scope(db,["project_id":pid],caller,write:true)
        let current = try scoped(db,tid,pid,type:"task"),project = try record(db,pid,type:"project")
        try requireAgentEditAuthority(db,project:project,caller:caller)
        guard cleanupJobEqual(current["id"],tid),cleanupJobEqual(current["project_id"],pid),try ArchiveCleanupJob.integer(current["revision"]) == ArchiveCleanupJob.integer(task["revision"]),try ArchiveCleanupJob.integer(project["settings_revision"]) == settingsRevision,current["active_attempt_id"] == nil,current["active_verification_request_id"] == nil else {throw CoreError("CLEANUP_PREVIEW_STALE","Refresh archive cleanup after the task or settings change.")}
        guard !plan.selected.isEmpty else {return nil}
        guard plan.selected.count <= ArchiveCleanupJob.maximumItems else {throw CoreError("CLEANUP_JOB_TOO_LARGE","This cleanup job exceeds its bounded object limit. No cleanup was queued.")}
        for raw in try records(db,type:"cleanup_job",project:pid) where cleanupJobEqual(raw["task_id"],tid) {
            let existing = try cleanupJobDecode(raw)
            guard [.canceled,.completed].contains(existing.state) else {throw CoreError("CLEANUP_JOB_ACTIVE","Cancel or finish the existing cleanup job before starting another.")}
        }
        let originals: [ArchiveCleanupOriginal] = try plan.selected.map {selection in
            let raw = try scoped(db,selection.id.text,pid,type:"attachment")
            guard cleanupJobEqual(raw["id"],selection.id.text),cleanupJobEqual(raw["project_id"],pid),cleanupJobEqual(raw["task_id"],tid),raw["mode"] as? String == "managed",raw["availability"] as? String == "available",let digest = raw["sha256"] as? String,try ArchiveCleanupJob.integer(raw["size"]) == selection.logicalBytes else {throw CoreError("CLEANUP_PREVIEW_STALE","An eligible managed original changed. No cleanup was queued.")}
            return try .init(id:selection.id.text,sha256:digest,logicalBytes:selection.logicalBytes,attachmentRevision:ArchiveCleanupJob.integer(raw["revision"]))
        }
        let basis: JSON = [
            "project_id": pid, "task_id": tid, "task_revision": (try StoredRecord(current, family: "current").requiredValue("revision")), "settings_revision": settingsRevision,
            "preview_id": previewID,
            "originals": originals.map { ["attachment_id": $0.id.text, "sha256": $0.sha256, "logical_bytes": $0.logicalBytes, "attachment_revision": $0.attachmentRevision] },
        ]
        let digest = hash(Data(try jsonString(basis).utf8))
        let previews = try records(db,type:"cleanup_preview",project:pid).filter {cleanupJobEqual($0["cleanup_preview_id"],previewID)}
        guard previews.count == 1,let preview = previews.first,cleanupJobEqual(preview["project_id"],pid),cleanupJobEqual(preview["task_id"],tid),try ArchiveCleanupJob.integer(preview["task_revision"]) == ArchiveCleanupJob.integer(current["revision"]),try ArchiveCleanupJob.integer(preview["settings_revision"]) == settingsRevision,preview["cleanup_job_plan_sha256"] as? String == digest else {throw CoreError("CLEANUP_PREVIEW_REQUIRED","A current settings-bound archive cleanup preview is required. No cleanup was queued.")}
        let job = try ArchiveCleanupJob(id:uuid(),projectID:pid,taskID:tid,taskRevision:ArchiveCleanupJob.integer(current["revision"]),settingsRevision:settingsRevision,previewID:previewID,planDigest:digest,enqueuedAtMS:nowMS,notBeforeMS:notBeforeMS,originals:originals)
        try save(db,job.record(revision:1),type:"cleanup_job")
        try event(db,caller:caller,project:pid,entity:tid,kind:"archive_cleanup_queued",data:["cleanup_job_id":job.id.text,"selected_logical_original_bytes":try job.logicalTotals().selected])
        return try cleanupJobProjection(job,revision:1)
    }
    /// Project-authorized metadata/cancel/retry. Router dispatch/catalog additions remain explicit merge fragments.
    /// handle owns the semantic transaction, command digest/receipt/replay and post-commit104+maintenance tail.
    func archiveCleanupJobCommand(_ db: Database,_ p: JSON,_ c: Caller,_ method: String,retryDeadline: (nowMS: Int64,notBeforeMS: Int64)? = nil) throws -> JSON {
        // Protective cancellation remains possible when the project itself is archived.
        let pid = try scope(db,p,c,write:method == "cleanup_job_retry"); try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:c)
        // Historical byte accounting grants no deletion authority. Its failure
        // must never prevent protective cancellation or invent a zero total.
        let accounting: (StorageBackupRetentionIndex,[Data:JSON])? = try? {
            let index = try storageBackupRetentionIndex(db)
            let attachments = Dictionary(
                uniqueKeysWithValues: try records(db, type: "attachment", project: pid).map { (Data(((try StoredRecord($0, family: "record").string("id"))).utf8), $0) })
            return (index,attachments)
        }()
        func projection(_ job: ArchiveCleanupJob,_ revision: Int64) throws -> JSON {
            guard let (backupIndex,attachments) = accounting else { return try cleanupJobProjection(job,revision:revision) }
            let retained = try job.items.reduce(Int64(0)) { total,item in
                guard let attachment = attachments[Data(item.original.id.text.utf8)],attachment["sha256"] as? String == item.original.sha256,
                      try ArchiveCleanupJob.integer(attachment["size"]) == item.original.logicalBytes else { return total }
                let next = total.addingReportingOverflow(backupIndex.knownRetainedLogicalBytes(for:attachment))
                guard !next.overflow else { throw CoreError("CLEANUP_JOB_INVALID","Backup logical accounting is out of range.") };return next.partialValue
            }
            return try cleanupJobProjection(job,revision:revision,knownBackupRetainedLogicalBytes:retained)
        }
        if method == "cleanup_job_list" {
            let task = try self.task(db,p,pid)
            let rows = try records(db,type:"cleanup_job",project:pid).filter { cleanupJobEqual($0["task_id"],task["id"]) }
            return ["cleanup_jobs":try rows.suffix(20).reversed().map { try projection(cleanupJobDecode($0),ArchiveCleanupJob.integer($0["revision"])) },"total_count":rows.count,"complete":rows.count <= 20]
        }
        let raw = try scoped(db,try text(p,"cleanup_job_id"),pid,type:"cleanup_job")
        var job = try cleanupJobDecode(raw)
        guard cleanupJobEqual(raw["project_id"],pid),cleanupJobEqual(job.projectID.text,pid) else {throw CoreError("NOT_FOUND","Cleanup job is not available in this project.")}
        let revision = try ArchiveCleanupJob.integer(raw["revision"])
        if method == "cleanup_job_get" {return try projection(job,revision)}
        guard db.isInsideTransaction else {throw CoreError("CLEANUP_TRANSACTION_REQUIRED","Change cleanup through its guarded command.")}
        guard p["expected_revision"] != nil else {throw CoreError("REVISION_REQUIRED","Read the current cleanup job revision before changing it.")}
        guard let expected = try? ArchiveCleanupJob.integer(p["expected_revision"]),expected > 0 else {throw CoreError("INVALID_INPUT","Cleanup revision must be a positive exact whole number.")}
        guard expected == revision else {throw CoreError("REVISION_CONFLICT","Cleanup job changed. Read its current state before retrying.")}
        switch method {
        case "cleanup_job_cancel":
            guard job.cancel() else {return try projection(job,revision)}
        case "cleanup_job_retry":
            // Deadline is a trusted service argument, never copied from arbitrary public parameters.
            let retryDeadline = retryDeadline ?? (archiveCleanupNowMS(),archiveCleanupNowMS() + Self.archiveCleanupGraceMS)
            do {try job.retry(nowMS:retryDeadline.nowMS,notBeforeMS:retryDeadline.notBeforeMS)}
            catch {throw CoreError("CLEANUP_RETRY_REFUSED","Only a suspended job can be retried with a fresh cancellation window. No original was deleted.")}
            storageMaintenanceFallbackFailures = 0
        default:throw CoreError("INVALID_INPUT","Unsupported cleanup job operation.")
        }
        let next = try nextCleanupJobRevision(raw);try save(db,job.record(revision:next),type:"cleanup_job")
        try event(db,caller:c,project:pid,entity:job.taskID.text,kind:method == "cleanup_job_retry" ? "archive_cleanup_retry_queued" : "archive_cleanup_canceled",data:["cleanup_job_id":job.id.text])
        return try projection(job,next)
    }
    /// Bounded metadata-only reuse of actual existing holds. Complete shared/build reference
    /// admission is not yet qualified, so this adapter ALWAYS supplies referencesComplete=false.
    /// It cannot authorize unlink. Future execution must recheck everything under its final object gate.
    func observeArchiveCleanupHolds(_ db: Database,projectID: String,jobID: String,attachmentIDs: [String],nowMS: Int64,caller: Caller) throws -> JSON {
        try owner(caller);_ = try scope(db,["project_id":projectID],caller)
        guard db.isInsideTransaction,attachmentIDs.count <= ArchiveCleanupJob.admissionStepLimit else {throw CoreError("CLEANUP_TRANSACTION_REQUIRED","Observe a bounded cleanup selection inside its validated transaction.")}
        let ids = try attachmentIDs.map(ArchiveAttachmentID.init);guard Set(ids).count == ids.count else {throw CoreError("INVALID_INPUT","Select distinct cleanup originals.")}
        let raw = try scoped(db,jobID,projectID,type:"cleanup_job");var job = try cleanupJobDecode(raw)
        let revision = try ArchiveCleanupJob.integer(raw["revision"])
        guard ![.canceled,.completed,.suspended].contains(job.state),nowMS >= job.notBeforeMS else {return try cleanupJobProjection(job,revision:revision)}
        let task = try scoped(db,job.taskID.text,projectID,type:"task")
        if !bool(task,"archived") {
            _ = job.cancel();let next = try nextCleanupJobRevision(raw);try save(db,job.record(revision:next),type:"cleanup_job");return try cleanupJobProjection(job,revision:next)
        }
        var facts: [ArchiveCleanupJob.Admission] = []
        for id in ids {
            guard let item = job.items.first(where: {$0.original.id == id}),!item.terminal else {throw CoreError("CLEANUP_PREVIEW_STALE","Select a current remaining cleanup original.")}
            var holds = Set<ArchiveCleanupJob.Hold>()
            do {
                let a = try scoped(db,id.text,projectID,type:"attachment")
                let size = try ArchiveCleanupJob.integer(a["size"]),attachmentRevision = try ArchiveCleanupJob.integer(a["revision"])
                if !cleanupJobEqual(a["id"],id.text) || !cleanupJobEqual(a["task_id"],job.taskID.text) || a["sha256"] as? String != item.original.sha256 || size != item.original.logicalBytes || attachmentRevision != item.original.attachmentRevision {holds.insert(.changedIdentity)}
                if a["mode"] as? String != "managed" {holds.insert(.externalOriginal)}
                if a["availability"] as? String != "available" {holds.insert(.originalUnavailable)}
                for reason in try cleanupHoldReasons(db,attachment:a,task:task) {
                    switch reason {
                    case "Keep original":holds.insert(.keepOriginal)
                    case "Active work or verification":
                        if task["active_attempt_id"] != nil {holds.insert(.activeWork)}
                        if task["active_verification_request_id"] != nil {holds.insert(.activeVerification)}
                    case "Pending human inspection":holds.insert(.pendingHumanInspection)
                    case "Current review target":holds.insert(.currentReview)
                    case "Backup capture":holds.insert(.backupCapture)
                    case "Active reader":holds.insert(.activeReader)
                    default:holds.insert(.referenceGraphUnavailable)
                    }
                }
            } catch let error as CoreError where error.code == "NOT_FOUND" {holds.insert(.originalUnavailable)}
            facts.append(.init(projectID:job.projectID,taskID:job.taskID,original:item.original,referencesComplete:false,holds:holds))
        }
        try job.observe(facts,nowMS:nowMS)
        let next = try nextCleanupJobRevision(raw);try save(db,job.record(revision:next),type:"cleanup_job")
        return try cleanupJobProjection(job,revision:next)
    }
    /// Future unarchive hook: cancel remaining objects atomically; never claim deleted bytes returned.
    func cancelArchiveCleanupForUnarchive(_ db: Database,task: JSON,caller: Caller) throws {
        // Canceling pending deletion protects files, so an authorized agent unarchive may do it too.
        guard db.isInsideTransaction,let pid = task["project_id"] as? String,let tid = task["id"] as? String else {throw CoreError("CLEANUP_TRANSACTION_REQUIRED","Cancel cleanup with the guarded unarchive transaction.")}
        try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:caller)
        _ = try scope(db,["project_id":pid],caller,write:true)
        for raw in try records(db,type:"cleanup_job",project:pid) where cleanupJobEqual(raw["task_id"],tid) {
            var job = try cleanupJobDecode(raw)
            guard job.cancel() else {continue}
            try save(db,job.record(revision:nextCleanupJobRevision(raw)),type:"cleanup_job")
            try event(db,caller:caller,project:pid,entity:tid,kind:"archive_cleanup_canceled",data:["cleanup_job_id":job.id.text])
        }
    }
}
