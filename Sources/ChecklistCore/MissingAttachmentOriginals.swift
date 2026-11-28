import Foundation
import GRDB

extension CommandRouter {
    func listMissingAttachmentOriginals(_ db: Database, _ params: JSON, _ caller: Caller) throws -> JSON {
        try worker(caller)
        let project = try scope(db,params,caller)
        let after = try text(params,"after_attachment_id",max:100,required:false)
        let limit = params["limit"] == nil ? 100 : (try? ArchiveCleanupJob.integer(params["limit"]))
        guard let limit, (1...200).contains(limit) else {throw CoreError("INVALID_INPUT","limit must be between 1 and 200.")}
        let files = try StorageObjectFiles(root:root,walkDirectories:true)
        let rows = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns +
            " FROM records WHERE project_id=CAST(? AS TEXT) AND type='attachment' ORDER BY id COLLATE BINARY",
            arguments:[Data(project.utf8)])
        var missing = 0, unsettled = 0, uncheckable = 0, hasMore = false
        var issues: [JSON] = []
        while let row = try rows.next() {
            try autoreleasepool {
                let record = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"attachment")
                let value = record.object
                guard value["mode"] as? String == "managed",
                      !["original_cleaned",Self.originalCleanupPending].contains(value["availability"] as? String ?? "") else {return}
                let state: String
                do {
                    let loss = try AttachmentOriginalLoss.recorded(in:value)
                    if let path = value["path"] as? String {
                        guard let relative = try ManagedPaths.relative(path,family:"objects",root:root) else {
                            throw StorageSnapshotFailure.unsupportedAuthority
                        }
                        guard try !files.regularFileExists(relative) else {return}
                    } else if loss == nil {
                        throw StorageSnapshotFailure.unsupportedAuthority
                    }
                    state = loss == nil ? "unsettled" : "settled"
                    missing += 1
                    if state == "unsettled" {unsettled += 1}
                } catch {
                    uncheckable += 1
                    state = "uncheckable"
                }
                guard after.utf8.lexicographicallyPrecedes(record.id.utf8) else {return}
                if issues.count < limit {
                    issues.append(["attachment_id":record.id,"task_id":value["task_id"] ?? NSNull(),
                                   "revision":record.revision,"state":state])
                } else {hasMore = true}
            }
        }
        try files.finishWalk()
        return ["project_id":project,"checked_at":now(),"missing_count":missing,"unsettled_count":unsettled,
                "uncheckable_count":uncheckable,"attachments":issues,
                "next_after_attachment_id":(hasMore ? issues.last?["attachment_id"] : nil) ?? NSNull()]
    }

    func settleMissingAttachmentOriginal(_ db: Database, _ params: JSON, _ caller: Caller) throws -> JSON {
        try worker(caller)
        // Storage reconciliation is also available in archived projects.
        let project = try scope(db,params,caller)
        try requireAgentEditAuthority(db,project:record(db,project,type:"project"),caller:caller)
        let id = try text(params,"attachment_id")
        var attachment = try scoped(db,id,project,type:"attachment")
        guard attachment["mode"] as? String == "managed",
              !["original_cleaned",Self.originalCleanupPending].contains(attachment["availability"] as? String ?? ""),
              let path = attachment["path"] as? String,
              let relative = try ManagedPaths.relative(path,family:"objects",root:root) else {
            throw CoreError("MANAGED_ORIGINAL_NOT_SETTLEABLE","Select a managed original with a local descriptor and no authorized cleanup.")
        }
        let files = try StorageObjectFiles(root:root)
        let present: Bool
        do { present = try files.regularFileExists(relative) }
        catch {throw CoreError("MANAGED_ORIGINAL_INSPECTION_FAILED","Checklist could not prove that the managed original is absent.")}
        guard !present else {throw CoreError("MANAGED_ORIGINAL_PRESENT","The managed original is still present.")}
        let loss: AttachmentOriginalLoss
        if let existing = try AttachmentOriginalLoss.recorded(in:attachment) {
            loss = existing
        } else {
            if let expected = params["expected_revision"] {
                guard (try? ArchiveCleanupJob.integer(expected)) != nil else {throw CoreError("INVALID_INPUT","expected_revision must be an integer.")}
                try revision(params,attachment)
            }
            loss = try AttachmentOriginalLoss(attachment,foundAt:now())
            attachment["availability"] = "original_missing"
            attachment["original_loss"] = loss.json
            attachment.removeValue(forKey:"availability_error")
            attachment = revised(attachment)
            try save(db,attachment,type:"attachment")
            try event(db,caller:caller,project:project,entity:attachment["task_id"] as? String ?? id,
                      kind:"attachment_original_loss_settled",data:["attachment_id":id,"original_loss":loss.json])
        }
        return ["project_id":project,"attachment_id":id,"task_id":attachment["task_id"] ?? NSNull(),
                "availability":"original_missing","revision":attachment["revision"] ?? NSNull(),"original_loss":loss.json]
    }
}
