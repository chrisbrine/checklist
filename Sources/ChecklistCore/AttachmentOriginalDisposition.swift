import Foundation
import GRDB

struct AttachmentOriginalLoss {
    let sha256: String
    let size: Int64
    let foundAt: String

    init(_ attachment: JSON, foundAt: String) throws {
        guard let sha256 = attachment["sha256"] as? String,
              sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              let size = try? ArchiveCleanupJob.integer(attachment["size"]), size >= 0,
              StoredClock.shared.date(from:foundAt) != nil else {
            throw StorageSnapshotFailure.unsupportedAuthority
        }
        self.sha256 = sha256
        self.size = size
        self.foundAt = foundAt
    }

    var json: JSON { ["last_known_sha256":sha256,"last_known_size":size,"found_at":foundAt] }

    static func recorded(in attachment: JSON) throws -> Self? {
        guard let raw = attachment["original_loss"] else {return nil}
        guard let record = raw as? JSON, Set(record.keys) == ["last_known_sha256","last_known_size","found_at"],
              let foundAt = record["found_at"] as? String,
              attachment["mode"] as? String == "managed", attachment["availability"] as? String == "original_missing" else {
            throw StorageSnapshotFailure.unsupportedAuthority
        }
        let loss = try Self(attachment,foundAt:foundAt)
        guard record["last_known_sha256"] as? String == loss.sha256,
              (try? ArchiveCleanupJob.integer(record["last_known_size"])) == loss.size else {
            throw StorageSnapshotFailure.unsupportedAuthority
        }
        return loss
    }
}

extension CommandRouter {
    static let originalCleanupPending = "original_cleanup_pending"

    func attachmentReferencesToObject(_ db: Database, relative: String) throws -> [JSON] {
        let absolute = root.appendingPathComponent(relative).path
        let rows = try managedImportStageReferences?.attachmentRows(db,absolute:absolute,relative:relative)
            ?? ManagedImportStageReferences.scanAttachmentRows(db,absolute:absolute,relative:relative)
        guard rows.count < 129 else {
            throw CoreError("CLEANUP_REFERENCE_LIMIT","Too many attachment references share this path; bytes retained.")
        }
        return try rows.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"attachment").object}
    }

    /// Called after verifying the named original, with the same gate and
    /// serial writer reservation held until unlink and outcome accounting.
    func commitOriginalRemovalFence(_ db: Database, relative: String, sha256: String, size: Int64,
                                    retiring: Set<String>, receiptID: String, deadline: MaintenanceDeadline?) throws {
        guard relative.hasPrefix("objects/") else {return}
        try deadline?.check()
        let pathReferences = try attachmentReferencesToObject(db,relative:relative)
        var changed: [JSON] = []
        for var attachment in pathReferences {
            try deadline?.check()
            guard attachment["mode"] as? String == "managed" else {continue}
            if try AttachmentOriginalLoss.recorded(in:attachment) != nil {
                throw CoreError("CLEANUP_LOSS_RECORD_RETAINED","The attachment's recovery bytes and preview are retained.")
            }
            guard let path = attachment["path"] as? String,
                  try ManagedPaths.relative(path,family:"objects",root:root) == relative else {continue}
            if attachment["availability"] as? String == Self.originalCleanupPending {
                guard attachment["original_removal_receipt_id"] as? String == receiptID else {
                    throw CoreError("CLEANUP_ORIGINAL_ALREADY_MARKED","Another cleanup owns this original; bytes retained.")
                }
                continue
            }
            guard attachment["availability"] as? String == "available" else {continue}
            let id = try StoredRecord(attachment,family:"attachment").string("id")
            guard retiring.contains(id), attachment["sha256"] as? String == sha256,
                  try ArchiveCleanupJob.integer(attachment["size"]) == size else {
                throw CoreError("CLEANUP_ORIGINAL_STILL_REFERENCED","An available attachment still owns this original; bytes retained.")
            }
            attachment["availability"] = Self.originalCleanupPending
            attachment["original_removal_receipt_id"] = receiptID
            changed.append(self.revised(attachment))
        }
        guard !changed.isEmpty else {return}
        try withValidatedDomainTransaction(db,deadline:deadline) {
            for value in changed {try save(db,value,type:"attachment")}
            return .commit
        }
    }

    func recordOriginalRemovalOutcome(_ attachment: inout JSON, receiptID: String, removed: Bool) throws {
        let marked = attachment["availability"] as? String == Self.originalCleanupPending
            && attachment["original_removal_receipt_id"] as? String == receiptID
        attachment["availability"] = removed ? "original_cleaned" : "original_missing"
        attachment.removeValue(forKey:"availability_error")
        attachment.removeValue(forKey:"original_removal_receipt_id")
        if marked && !removed {
            // The earlier attempt verified this exact original and committed
            // the mark. A retry can prove absence but cannot claim the unlink.
            attachment["original_loss"] = try AttachmentOriginalLoss(attachment,foundAt:now()).json
        }
    }
}
