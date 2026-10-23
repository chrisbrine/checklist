import Foundation
import GRDB

enum StorageMaintenanceWarning: Equatable {
    case retryPending
    case suspended
    case backupCapture

    var metadata: JSON {
        ["schema_version": 1, "code": "STORAGE_MAINTENANCE_DEFERRED",
         "status": self == .backupCapture ? "held" : (self == .suspended ? "suspended" : "retry_pending"),
         "reason": self == .backupCapture ? "backup_capture" : "maintenance_retry"]
    }
}

extension CommandRouter {
    /// This tail is best effort only. It cannot change a committed semantic result.
    /// Error text, paths and record identities never enter the public warning.
    /// A bounded pause belongs only to this router lifetime. Normal service restart
    /// provides a fresh recovery opportunity; no durable latch exists without an
    /// owner-authorized resume boundary. Never automatically restart or poll it.
    func performStorageMaintenance(_ db: Database, permit: ArchiveStoragePermit) -> StorageMaintenanceWarning? {
        do {
            if try StorageSnapshotRetention.isActive(root:root) {return .backupCapture}
            guard storageMaintenanceFallbackFailures < 2 else { return .suspended }
            let importWarning = try reconcileManagedAttachmentImports(db)
            try processArchiveCleanupJobs(db, permit: permit, nowMS: Int64(Date().timeIntervalSince1970 * 1000))
            storageMaintenanceFallbackFailures = 0
            return importWarning
        } catch {
            storageMaintenanceFallbackFailures = min(storageMaintenanceFallbackFailures + 1, 2)
            return storageMaintenanceFallbackFailures == 2 ? .suspended : .retryPending
        }
    }

    /// Called after CL-104's live notice decoration, so neither notice replaces the other.
    func addingStorageMaintenanceNotice(_ output: JSON, warning: StorageMaintenanceWarning?) -> JSON {
        guard let warning, var data = output["data"] as? JSON else { return output }
        var checklist = data["_checklist"] as? JSON ?? [:]
        checklist["storage_maintenance"] = warning.metadata
        data["_checklist"] = checklist
        var result = output
        result["data"] = data
        return result
    }
}
