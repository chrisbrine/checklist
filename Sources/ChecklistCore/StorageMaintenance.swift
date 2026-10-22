import Foundation
import GRDB

enum StorageMaintenanceWarning: Equatable {
    case retryPending
    case suspended

    var metadata: JSON {
        ["schema_version": 1, "code": "STORAGE_MAINTENANCE_DEFERRED",
         "status": self == .suspended ? "suspended" : "retry_pending"]
    }
}

extension CommandRouter {
    /// This tail is best effort only. It cannot change a committed semantic result.
    /// Error text, paths and record identities never enter the public warning.
    /// A bounded pause belongs only to this router lifetime. Normal service restart
    /// provides a fresh recovery opportunity; no durable latch exists without an
    /// owner-authorized resume boundary. Never automatically restart or poll it.
    func performStorageMaintenance(_ db: Database, permit: ArchiveStoragePermit) -> StorageMaintenanceWarning? {
        guard storageMaintenanceFallbackFailures < 2 else { return .suspended }
        do {
            let importWarning = try reconcileManagedAttachmentImports(db)
            try processTicketObjectDeletionIntents(db,permit:permit)
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
