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
    /// The capture start, not the completion: a file added during a capture is
    /// absent from that backup, so its job must still count as waiting.
    private func latestCompleteBackupTime(_ db: Database) throws -> String {
        try String.fetchOne(db,sql:"SELECT MAX(COALESCE(json_extract(value,'$.summary.captured_at'),json_extract(value,'$.known_at'),json_extract(value,'$.created_at'))) FROM metadata WHERE key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete'") ?? ""
    }
    private func doneEvidenceBackupsConfirmed(_ db: Database) -> Bool {
        (try? StorageAutomaticBackupRetention.isConfirmed(try backupRetentionSettings(db),root:root,incarnation:incarnation)) == true
    }
    /// Earliest time the interval allows another service backup, from metadata only.
    private func doneEvidenceBackupHold(_ db: Database) throws -> Date? {
        let format = ISO8601DateFormatter()
        let attempt = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.doneEvidenceBackupAttemptKey]).flatMap {format.date(from:$0)}
        return [format.date(from:try latestCompleteBackupTime(db)),attempt].compactMap {$0?.addingTimeInterval(Self.doneEvidenceBackupInterval)}.max()
    }
    /// For the wake plan. The job scan parses every storage job, so skip it while
    /// the interval holds; the wake at that time scans again.
    func doneEvidenceBackupWake(_ db: Database,at time: Date = Date()) throws -> Date? {
        guard doneEvidenceBackupsConfirmed(db) else {return nil}
        if let hold = try doneEvidenceBackupHold(db),hold > time {return hold}
        return try doneEvidenceBackupDeadline(db)
    }

    /// When the next service-started backup may begin; nil when no file waits for
    /// one or the retention rule has no owner confirmation on this installation.
    func doneEvidenceBackupDeadline(_ db: Database) throws -> Date? {
        guard doneEvidenceBackupsConfirmed(db) else {return nil}
        let latest = try latestCompleteBackupTime(db),format = ISO8601DateFormatter()
        guard let oldest = try String.fetchOne(db,sql:"SELECT MIN(COALESCE(json_extract(data,'$.updated_at'),json_extract(data,'$.created_at'))) FROM records WHERE " + Self.waitingDoneEvidenceSQL,arguments:[latest]),
              let waiting = format.date(from:oldest) else {return nil}
        return [waiting.addingTimeInterval(Self.doneEvidenceBackupSettle),try doneEvidenceBackupHold(db)].compactMap {$0}.max()
    }

    /// The attempt time commits first, so a refused or failed backup waits one
    /// interval and cannot repeat at the maintenance rate.
    @discardableResult
    public func startDoneEvidenceBackupIfDue(at time: Date = Date()) -> Bool {
        do {
            guard try !StorageSnapshotRetention.isActive(root:root),
                  let deadline = try readForPreparation({db -> Date? in
                      if let hold = try self.doneEvidenceBackupHold(db),hold > time {return nil}
                      return try self.doneEvidenceBackupDeadline(db)
                  }),deadline <= time else {return false}
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
    /// Tickets held for this backup need not wait for their next daily sweep. A
    /// wake failure leaves them to that sweep and never fails a finished backup.
    func wakeDoneEvidenceForBackup(_ db: Database) {
        do {try wakeHeldDoneEvidence(db)} catch {fputs("Done evidence wake deferred to the daily sweep.\n",stderr)}
    }
    private func wakeHeldDoneEvidence(_ db: Database) throws {
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
