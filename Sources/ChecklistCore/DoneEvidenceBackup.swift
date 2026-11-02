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
    private static let doneEvidenceBackupStatusKey = "done-evidence-backup-status"
    static let doneEvidenceBackupInstallation = "storage"

    private static let waitingDoneEvidenceSQL = """
        rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='storage_job') AND json_valid(data)
        AND json_extract(data,'$.kind')='ticket_object_delete' AND json_extract(data,'$.cause')='done_evidence' AND json_extract(data,'$.state') IN ('pending','completed')
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
        // A progressing pending job revises updated_at on every byte chunk.
        // Admission is its stable settle clock; otherwise it could never become due.
        guard let oldest = try String.fetchOne(db,sql:"SELECT MIN(CASE WHEN json_extract(data,'$.state')='pending' THEN json_extract(data,'$.created_at') ELSE COALESCE(json_extract(data,'$.updated_at'),json_extract(data,'$.created_at')) END) FROM records WHERE " + Self.waitingDoneEvidenceSQL,arguments:[latest]),
              let waiting = format.date(from:oldest) else {return nil}
        return [waiting.addingTimeInterval(Self.doneEvidenceBackupSettle),try doneEvidenceBackupHold(db)].compactMap {$0}.max()
    }

    /// Read the latest service attempt and its exact operation, including an
    /// asynchronous refusal. No command-history or backup-result scan is needed.
    func doneEvidenceBackupProjection(_ db: Database) throws -> JSON {
        let attempt = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.doneEvidenceBackupAttemptKey])
        var value = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.doneEvidenceBackupStatusKey]) ?? "{}")
        guard !value.isEmpty || attempt != nil else {return [:]}
        if value.isEmpty {value = ["state":"unknown","reason":"attempt_outcome_not_recorded"]}
        value["attempted_at"] = value["attempted_at"] ?? attempt
        if let raw = value["attempted_at"] as? String,let time = ISO8601DateFormatter().date(from:raw) {
            value["retry_not_before"] = ISO8601DateFormatter().string(from:time.addingTimeInterval(Self.doneEvidenceBackupInterval))
        }
        // Older builds saved only the attempt clock. Recover success from a
        // committed service receipt, never from an unrelated owner's backup.
        if value["state"] as? String == "unknown" || value["state"] as? String == "starting" {
            if let completed = try completedDoneEvidenceBackup(db,attempt:value) {return completed}
        }
        guard let command = value["command_id"] as? String else {return value}
        let caller = Caller(role:"owner",installation:Self.doneEvidenceBackupInstallation,projectIDs:[])
        let id = Self.commandOperationID(principal:caller.principal,command:command)
        guard let operation = try operationRecord(db,id:id) else {
            if value["operation_id"] != nil {value["state"] = "unknown";value["reason"] = "operation_state_unavailable"}
            else if value["state"] as? String == "starting" {value["state"] = "unknown";value["reason"] = "attempt_outcome_not_recorded"}
            if value["state"] as? String == "unknown" {return try completedDoneEvidenceBackup(db,attempt:value) ?? value}
            return value
        }
        value["operation_id"] = id
        let state = operation["state"] as? String ?? "unknown"
        value["state"] = state == "succeeded" ? "complete" : state
        if state == "queued",commandOperations.isActive(id) {value["state"] = "running"}
        for key in ["started_at","finished_at"] {value[key] = operation[key]}
        if state == "failed" {
            do {
                let payload = try operationPayload(db,operation,caller:caller)
                if let error = payload["error"] as? JSON {addDoneEvidenceBackupFailure(error,to:&value)}
            } catch {addDoneEvidenceBackupFailure(PublicErrorText.payload(error),to:&value)}
        }
        return value
    }
    private func completedDoneEvidenceBackup(_ db: Database,attempt: JSON) throws -> JSON? {
        guard let attempted = attempt["attempted_at"] as? String,
              ISO8601DateFormatter().date(from:attempted) != nil else {return nil}
        // Bound legacy recovery. Normal new attempts commit their status with
        // the backup receipt and need no history read.
        let rows = try Row.fetchAll(db,sql:"SELECT data FROM (SELECT kind,data FROM events WHERE project_id IS NULL AND entity_id IS NULL ORDER BY seq DESC LIMIT 128) WHERE kind='backup_created'")
        for row in rows {
            let event = jsonObject(row["data"] as String)
            guard event["origin"] as? String == "service",let command = event["command_id"] as? String,
                  attempt["command_id"] == nil || attempt["command_id"] as? String == command,
                  let captured = event["captured_at"] as? String,captured >= attempted,
                  let operation = event["operation_id"] as? String,
                  let raw = try String.fetchOne(db,sql:"SELECT json_object('state',json_extract(value,'$.state')) FROM metadata WHERE key=? AND json_valid(value)",arguments:["backup-generation:" + operation]),
                  jsonObject(raw)["state"] as? String == "complete" else {continue}
            var result = attempt
            result["state"] = "complete";result["command_id"] = command
            result["finished_at"] = event["verified_at"];result["outcome_source"] = "backup_receipt"
            result.removeValue(forKey:"reason")
            return result
        }
        return nil
    }

    /// The successful backup receipt and attempt outcome have one commit. A
    /// crash before the caller saves its return value cannot hide that success.
    func recordDoneEvidenceBackupCompletion(_ db: Database,command: String,summary: JSON) throws {
        var status = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[Self.doneEvidenceBackupStatusKey]) ?? "{}")
        guard status["command_id"] as? String == command else {return}
        status["state"] = "complete";status["finished_at"] = summary["verified_at"]
        status["outcome_source"] = "backup_receipt";status.removeValue(forKey:"reason")
        try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:[Self.doneEvidenceBackupStatusKey,try jsonString(status)])
    }

    private func addDoneEvidenceBackupFailure(_ error: JSON,to value: inout JSON) {
        value["error_code"] = error["code"]
        let details = error["details"] as? JSON ?? [:]
        for key in ["reason","next_step","command_outcome"] {value[key] = details[key]}
    }
    private func saveDoneEvidenceBackupStatus(_ value: JSON) throws {
        try dbQueue.writeWithoutTransaction {db in
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:[Self.doneEvidenceBackupStatusKey,try jsonString(value)])
        }
    }

    /// The attempt time commits first, so a refused or failed backup waits one
    /// interval and cannot repeat at the maintenance rate. Its outcome is visible
    /// without writing a separate history event or receipt.
    @discardableResult
    public func startDoneEvidenceBackupIfDue(at time: Date = Date()) -> Bool {
        do {
            guard try !StorageSnapshotRetention.isActive(root:root),
                  let deadline = try readForPreparation({db -> Date? in
                      if let hold = try self.doneEvidenceBackupHold(db),hold > time {return nil}
                      return try self.doneEvidenceBackupDeadline(db)
                  }),deadline <= time else {return false}
            let command = uuid(),attempted = ISO8601DateFormatter().string(from:time)
            var status: JSON = ["command_id":command,"attempted_at":attempted,"state":"starting"]
            try dbQueue.write {db in
                try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?),(?,?)",arguments:[Self.doneEvidenceBackupAttemptKey,attempted,Self.doneEvidenceBackupStatusKey,try jsonString(status)])
            }
            let reply: JSON
            do {
                reply = try handle(method:"backup_create",params:["command_id":command,"reason":"Done ticket files wait for a backup"],caller:Caller(role:"owner",installation:Self.doneEvidenceBackupInstallation,projectIDs:[]))
            } catch {
                status["state"] = "failed";status["finished_at"] = now()
                addDoneEvidenceBackupFailure(PublicErrorText.payload(error),to:&status)
                try saveDoneEvidenceBackupStatus(status)
                fputs("Done evidence backup deferred; its durable state was retained.\n",stderr)
                return false
            }
            if reply["command_outcome"] as? String == "accepted",let operation = reply["data"] as? JSON {
                status["state"] = operation["state"] ?? "queued";status["operation_id"] = operation["operation_id"]
            } else {status["state"] = "complete";status["finished_at"] = now()}
            // The backup's result is already known. A later status-write failure
            // must not turn its successful result into an invented backup failure.
            do {try saveDoneEvidenceBackupStatus(status)} catch {fputs("Done evidence backup status could not be updated.\n",stderr)}
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
