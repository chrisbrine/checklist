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
    /// Deferred infrastructure failures get a one-shot retry. Per-object failure
    /// suspension still requires the existing explicit retry authority.
    func performStorageMaintenance(_ db: Database, permit: ArchiveStoragePermit) -> StorageMaintenanceWarning? {
        do {
            if try StorageSnapshotRetention.isActive(root:root) {return .backupCapture}
            if let retry = storageMaintenanceRetryAt,retry > Date() {return .retryPending}
            let importWarning = try reconcileManagedAttachmentImports(db)
            try processArchiveCleanupJobs(db, permit: permit, nowMS: Int64(Date().timeIntervalSince1970 * 1000))
            storageMaintenanceFallbackFailures = 0
            storageMaintenanceRetryAt = nil
            return importWarning
        } catch {
            storageMaintenanceFallbackFailures = min(storageMaintenanceFallbackFailures + 1, 2)
            storageMaintenanceRetryAt = Date().addingTimeInterval(60)
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

/// Commands may refresh the schedule more often than its minimum timer delay.
/// Preserve an already armed earlier wake so read traffic cannot starve it.
public struct StorageMaintenanceWakePlan {
    public private(set) var deadline: Date?
    public init() {}
    @discardableResult public mutating func update(_ next: Date?) -> Bool {
        if let current = deadline,let next,current <= next {return false}
        if deadline == nil && next == nil {return false}
        deadline = next;return true
    }
    public mutating func fired() {deadline = nil}
}
