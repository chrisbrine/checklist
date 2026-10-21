import Foundation
import GRDB

extension CommandRouter {
    static let archiveCleanupGraceMS: Int64 = 30_000
    func archiveCleanupNowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    func archiveRetentionConfiguration(_ project: JSON) throws -> ArchiveRetentionConfiguration {
        do { return try .parse(project["archive_storage"]) }
        catch { throw CoreError("STORAGE_SETTINGS_INVALID", "Archive storage settings need repair; no original was deleted.") }
    }
    /// A separate canonical settings edit uses the same project/settings revisions.
    /// It cannot apply workflow policy or overwrite another settings field.
    func archiveStorageSettingsCommand(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c,write:true)
        var project = try record(db,pid,type:"project"); try revision(p,project)
        guard try ArchiveCleanupJob.integer(p["settings_revision"]) == ArchiveCleanupJob.integer(project["settings_revision"]) else {
            throw CoreError("REVISION_CONFLICT", "Project settings changed. Reload before saving archive storage.")
        }
        let configuration: ArchiveRetentionConfiguration
        do { configuration = try .parse(p["archive_storage"]) }
        catch { throw CoreError("INVALID_INPUT", "Supply a complete storage preset, positive whole-byte threshold and nonnegative whole-byte budget.") }
        project["archive_storage"] = configuration.jsonValue
        let (next,overflow) = try ArchiveCleanupJob.integer(project["settings_revision"]).addingReportingOverflow(1)
        guard !overflow else { throw CoreError("INVALID_INPUT", "Settings revision is exhausted.") }
        project["settings_revision"] = next; project = revised(project)
        try save(db,project,type:"project")
        try event(db,caller:c,project:pid,entity:pid,kind:"archive_storage_settings_changed")
        return project
    }

    func archiveRetentionFacts(_ db: Database,task: JSON,considerArchiving: Bool = false,currentGraph: [JSON]? = nil) throws -> [ArchiveAttachmentFact] {
        let attachments = try scopedTaskRows(db,type:"attachment",task:task).filter { !bool($0,"unlinked") }
        guard !attachments.isEmpty else { return [] }
        let graph = try currentGraph ?? archiveCleanupRelevantReferenceRows(db,attachments:attachments)
        let index = try ArchiveCleanupReferenceIndex(graph)
        return try attachments.map { a in
            let mode: ArchiveAttachmentFact.Mode = a["mode"] as? String == "managed" ? .managed : .externalReference
            let availability: ArchiveAttachmentFact.Availability = a["availability"] as? String == "available" ? .available : (a["availability"] as? String == "original_cleaned" ? .originalCleaned : .missing)
            let holds = try completeArchiveCleanupHolds(db,attachment:a,task:task,considerArchiving:considerArchiving,currentGraph:graph,currentIndex:index)
            return try .init(id:a["id"] as! String,logicalOriginalBytes:ArchiveCleanupJob.integer(a["size"]),mode:mode,availability:availability,protectionReasons:Set(holds.map { ArchiveProtectionReason(rawValue:$0.rawValue) ?? .otherAuthoritativeHold }))
        }
    }
    func archiveRetentionPreview(_ db: Database,task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,tid = task["id"] as! String,project = try record(db,pid,type:"project")
        let config = try archiveRetentionConfiguration(project)
        let plan = try ArchiveRetentionPlanner.make(configuration:config,facts:archiveRetentionFacts(db,task:task,considerArchiving:true))
        guard plan.selected.count <= ArchiveCleanupJob.maximumItems else { throw CoreError("CLEANUP_JOB_TOO_LARGE", "This ticket exceeds the bounded cleanup selection. Keep its originals; no cleanup was queued.") }
        let previewID = uuid()
        let originals: [JSON] = try plan.selected.map { item in
            let a = try scoped(db,item.id.text,pid,type:"attachment")
            return ["attachment_id":item.id.text,"sha256":a["sha256"]!,"logical_bytes":item.logicalBytes,"attachment_revision":a["revision"]!]
        }
        let basis: JSON = ["project_id":pid,"task_id":tid,"task_revision":task["revision"]!,"settings_revision":project["settings_revision"]!,"preview_id":previewID,"originals":originals]
        let value: JSON = ["id":uuid(),"project_id":pid,"task_id":tid,"record_type":"cleanup_preview","revision":1,"cleanup_preview_id":previewID,"task_revision":task["revision"]!,"settings_revision":project["settings_revision"]!,"archive_storage":config.jsonValue,"cleanup_job_plan_sha256":hash(Data(try jsonString(basis).utf8)),"attachment_ids":plan.selected.map { $0.id.text },"clean_bytes":plan.selectedLogicalBytes,"retained_bytes":plan.retainedLogicalBytes,"held_bytes":plan.protectedLogicalBytes,"budget_excess_bytes":plan.retainedBudgetExcessBytes,"holds":plan.protected.map { ["attachment_id":$0.id.text,"logical_bytes":$0.logicalBytes,"reasons":$0.reasons.map(\.rawValue)] },"grace_seconds":Self.archiveCleanupGraceMS / 1000,"physical_reclamation":"unmeasured","backup_retained_physical_bytes":NSNull(),"reason":"Only eligible managed originals are queued, with a 30-second Undo window. Current references and holds are checked again before deletion. Logical bytes are not measured physical savings."]
        // CL-72: a repeated preview of the same ticket revision, settings and plan reuses the
        // existing record instead of adding one per call.
        var basisWithoutID = basis; basisWithoutID.removeValue(forKey:"preview_id")
        let fingerprint = hash(Data(try jsonString(basisWithoutID).utf8))
        if let existing = try records(db,type:"cleanup_preview",project:pid).first(where: { cleanupJobEqual($0["task_id"],tid) && $0["plan_fingerprint"] as? String == fingerprint && int($0,"task_revision") == int(task,"revision") && int($0,"settings_revision") == int(project,"settings_revision") }) { return existing }
        var stored = value; stored["plan_fingerprint"] = fingerprint; stored["created_at"] = now()
        try save(db,stored,type:"cleanup_preview"); return stored
    }
    /// Called before the archive mutation, in that command's transaction.
    func queueArchiveRetentionCleanup(_ db: Database,task: JSON,previewID: String?,caller: Caller) throws {
        let project = try record(db,task["project_id"] as! String,type:"project")
        let plan = try ArchiveRetentionPlanner.make(configuration:archiveRetentionConfiguration(project),facts:archiveRetentionFacts(db,task:task,considerArchiving:true))
        guard !plan.selected.isEmpty else { return }
        guard let previewID else { throw CoreError("CLEANUP_PREVIEW_REQUIRED", "Read the current storage summary before archiving with cleanup.") }
        let nowMS = archiveCleanupNowMS()
        _ = try enqueueArchiveCleanupJob(db,task:task,settingsRevision:ArchiveCleanupJob.integer(project["settings_revision"]),previewID:previewID,plan:plan,nowMS:nowMS,notBeforeMS:nowMS + Self.archiveCleanupGraceMS,caller:caller)
    }
}
