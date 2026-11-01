import Foundation
import GRDB

/// CL-393: a live file leaves only when a completed backup holds its bytes, so
/// Done evidence needs a backup to follow it. The service starts one when bytes
/// wait, within the owner-confirmed retention rule, and no more often than the interval.
extension CommandRouter {
    static let doneEvidenceBackupInterval: TimeInterval = 7200
    /// Lets tickets that close together share one backup.
    static let doneEvidenceBackupSettle: TimeInterval = 900
    private static let doneEvidenceBackupAttemptKey = "done-evidence-backup-attempt"
    static let doneEvidenceBackupInstallation = "storage"

    private static let waitingDoneEvidenceSQL = """
        rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='storage_job') AND json_valid(data)
        AND json_extract(data,'$.kind')='ticket_object_delete' AND json_extract(data,'$.cause')='done_evidence' AND json_extract(data,'$.state')='completed'
        AND COALESCE(json_extract(data,'$.updated_at'),json_extract(data,'$.created_at'))>?
        AND EXISTS(SELECT 1 FROM json_each(data,'$.objects') object,json_each(object.value,'$.reasons') reason WHERE json_extract(object.value,'$.state')='retained' AND reason.value='backup_required')
        """
    private func latestCompleteBackupTime(_ db: Database) throws -> String {
        try String.fetchOne(db,sql:"SELECT MAX(COALESCE(json_extract(value,'$.known_at'),json_extract(value,'$.created_at'))) FROM metadata WHERE key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete'") ?? ""
    }

    /// When the next service-started backup may begin; nil when no file waits for
    /// one or the retention rule has no owner confirmation on this installation.
    func doneEvidenceBackupDeadline(_ db: Database) throws -> Date? {
        guard let confirmed = try? StorageAutomaticBackupRetention.isConfirmed(try backupRetentionSettings(db),root:root,incarnation:incarnation),confirmed else {return nil}
        let latest = try latestCompleteBackupTime(db),format = ISO8601DateFormatter()
        guard let oldest = try String.fetchOne(db,sql:"SELECT MIN(COALESCE(json_extract(data,'$.updated_at'),json_extract(data,'$.created_at'))) FROM records WHERE " + Self.waitingDoneEvidenceSQL,arguments:[latest]),
              let waiting = format.date(from:oldest) else {return nil}
        let attempt = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.doneEvidenceBackupAttemptKey]).flatMap {format.date(from:$0)}
        return [waiting.addingTimeInterval(Self.doneEvidenceBackupSettle),format.date(from:latest)?.addingTimeInterval(Self.doneEvidenceBackupInterval),attempt?.addingTimeInterval(Self.doneEvidenceBackupInterval)].compactMap {$0}.max()
    }

    /// The attempt time commits first, so a refused or failed backup waits one
    /// interval and cannot repeat at the maintenance rate.
    @discardableResult
    public func startDoneEvidenceBackupIfDue(at time: Date = Date()) -> Bool {
        do {
            guard try !StorageSnapshotRetention.isActive(root:root),
                  let deadline = try readForPreparation({try self.doneEvidenceBackupDeadline($0)}),deadline <= time else {return false}
            try dbQueue.writeWithoutTransaction {db in
                try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:[Self.doneEvidenceBackupAttemptKey,ISO8601DateFormatter().string(from:time)])
            }
            _ = try handle(method:"backup_create",params:["command_id":uuid(),"reason":"Done ticket files wait for a backup"],caller:Caller(role:"owner",installation:Self.doneEvidenceBackupInstallation,projectIDs:[]))
            return true
        } catch {
            fputs("Done evidence backup deferred; its durable state was retained.\n",stderr)
            return false
        }
    }

    /// Runs in the backup receipt transaction, before the new generation exists.
    /// Tickets held for this backup need not wait for their next daily sweep.
    func wakeDoneEvidenceForBackup(_ db: Database) throws {
        let rows = try Row.fetchAll(db,sql:"SELECT DISTINCT project_id,json_extract(data,'$.task_id') AS task_id FROM records WHERE " + Self.waitingDoneEvidenceSQL,arguments:[try latestCompleteBackupTime(db)])
        let clock = Date()
        for (project,group) in Dictionary(grouping:rows,by:{$0["project_id"] as String? ?? ""}) where !project.isEmpty {
            var retries = try ticketCleanupRetryEntries(db,project:project)
            for row in group {if let task: String = row["task_id"] {retries[task] = TicketCleanupRetry(at:clock)}}
            try saveTicketCleanupRetries(db,project:project,entries:retries)
            let previous = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + project]) ?? "0") ?? 0
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + project,String(min(previous,clock.timeIntervalSince1970))])
        }
    }
}
