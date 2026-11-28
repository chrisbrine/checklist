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
    /// A command can describe a pending continuation without running it.
    func currentStorageMaintenanceWarning() -> StorageMaintenanceWarning? {
        if (try? StorageSnapshotRetention.isActive(root:root)) == true {return .backupCapture}
        guard let retry = storageMaintenanceRetryAt,retry > Date() else {return nil}
        return storageMaintenanceFallbackFailures >= 2 ? .suspended : .retryPending
    }

    /// Imports and archive cleanup take separate background admissions. The
    /// deadline is shared by the gate and the SQLite step.
    func runArchiveStorageMaintenance() throws {
        guard !(storageMaintenanceRetryAt.map {$0 > Date()} ?? false) else {return}
        guard let readers else {
            storageMaintenanceRetryAt = Date().addingTimeInterval(60)
            return
        }
        let now = archiveCleanupNowMS()
        let (importDue,archiveIDs) = try readers.read {db in
            (try self.managedImportsNeedMaintenance(db),try self.dueArchiveCleanupJobIDs(db,nowMS:now))
        }
        var importWarning: StorageMaintenanceWarning?
        var deferred = false
        do {
            if importDue {
                do {importWarning = try runManagedAttachmentImportMaintenance()}
                catch is MaintenanceStepDeferred {deferred = true}
            }
            if !archiveIDs.isEmpty {
                let scan = prepareArchiveCleanupJobScan(nowMS:now,ids:archiveIDs)
                defer {finishArchiveCleanupScan(scan)}
                let admitted = try withMaintenanceGateAndWriter(label:"archive_cleanup.execute") {db,permit,deadline in
                    try self.processArchiveCleanupJobs(db,permit:permit,nowMS:now,prepared:scan,deadline:deadline,dueIDs:archiveIDs)
                    return true
                }
                deferred = deferred || admitted != true || scan == nil
            }
            if deferred {
                storageMaintenanceRetryAt = Date().addingTimeInterval(0.25)
                return
            }
            // These counters are also changed by the explicit retry command.
            _ = try withMaintenanceWriter(label:"storage_maintenance.state") {_,_ in
                self.storageMaintenanceFallbackFailures = 0
                self.storageMaintenanceRetryAt = importWarning == nil ? nil : Date().addingTimeInterval(60)
                return true
            }
        } catch {
            _ = try? withMaintenanceWriter(label:"storage_maintenance.state") {_,_ in
                self.storageMaintenanceFallbackFailures = min(self.storageMaintenanceFallbackFailures + 1,2)
                return true
            }
            storageMaintenanceRetryAt = Date().addingTimeInterval(60)
            throw error
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
