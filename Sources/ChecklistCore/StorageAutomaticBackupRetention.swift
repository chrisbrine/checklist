import Foundation
import CoreFoundation
import GRDB

/// Confirmation is written only by backup_retention_set on the authenticated
/// owner channel. A legacy manual rule is not consent to automatic Trash moves.
enum StorageAutomaticBackupRetention {
    static func isConfirmed(_ settings: JSON,root: URL? = nil,incarnation: String? = nil) throws -> Bool {
        guard let raw = settings["automatic_prune"] else {return false}
        guard let enabled = raw as? NSNumber,CFGetTypeID(enabled) == CFBooleanGetTypeID() else {throw StoreRecovery.required("backup_retention_confirmation_invalid")}
        guard enabled.boolValue else {return false}
        guard let owner = settings["owner_confirmed"] as? NSNumber,CFGetTypeID(owner) == CFBooleanGetTypeID(),owner.boolValue,
              let receipt = settings["owner_confirmation"] as? JSON,
              receipt["source"] as? String == "authenticated_app",
              let principal = receipt["principal"] as? String,!principal.isEmpty,
              let command = receipt["command_id"] as? String,UUID(uuidString:command) != nil,
              let confirmed = receipt["confirmed_at"] as? String,ISO8601DateFormatter().date(from:confirmed) != nil,
              let source = receipt["source_root"] as? String,source.hasPrefix("/"),
              let generation = receipt["incarnation"] as? String,!generation.isEmpty else {throw StoreRecovery.required("backup_retention_confirmation_invalid")}
        // A restored or seeded installation does not inherit automatic authority
        // from the source installation's trusted owner confirmation.
        if let root,source != root.path {return false}
        if let incarnation,generation != incarnation {return false}
        return true
    }

    static func command(root: URL,incarnation: String,trigger: String) -> String {
        let chars = Array(hash(Data((root.path + "\n" + incarnation + "\n" + trigger).utf8)).prefix(32))
        return String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
    }
}

extension CommandRouter {
    static var automaticBackupRetentionCaller: Caller {Caller(role:"storage_service",installation:"backup-retention",projectIDs:[])}

    /// Called inside the successful backup receipt/protected-ready transaction,
    /// closing the process-kill window before the post-commit retention hook.
    /// Malformed or unconfirmed retention cannot reject a verified backup.
    static func enqueueAutomaticBackupRetention(_ db: Database,root: URL,incarnation: String,operation: String) throws {
        let confirmed: Bool
        do {
            guard UUID(uuidString:operation) != nil,
                  let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-retention-settings'"),
                  let settings = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON else {return}
            _ = try StorageBackupRetentionPolicy.parse(settings)
            confirmed = try StorageAutomaticBackupRetention.isConfirmed(settings,root:root,incarnation:incarnation)
        } catch {return}
        guard confirmed else {return}
        let due: JSON = ["source_root":root.path,"incarnation":incarnation,"trigger_operation_id":operation,"queued_at":now()]
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-automatic-prune-due',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(due)])
    }

    /// Only a new trusted confirmation may fence an inherited foreign marker.
    /// Preserve both the exact marker and the underlying prune journal: this
    /// records lost applicability, never completion of an uncertain old move.
    func fenceForeignAutomaticRetentionIntent(_ db: Database,confirmation: JSON) throws {
        for activeKey in ["backup-automatic-prune-pending","backup-automatic-prune-due"] {
            guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[activeKey]),
                  let value = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON,
                  let source = value["source_root"] as? String,source.hasPrefix("/"),
                  let generation = value["incarnation"] as? String,!generation.isEmpty,
                  source != root.path || generation != incarnation else {continue}
            let key = "backup-automatic-prune-fenced:" + hash(Data((activeKey + "\n" + raw).utf8))
            let record: JSON = ["reason":"installation_binding_changed","fenced_at":now(),"original_key":activeKey,"original_intent":value,"owner_confirmation":confirmation]
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO NOTHING",arguments:[key,try jsonString(record)])
            try db.execute(sql:"DELETE FROM metadata WHERE key=? AND value=?",arguments:[activeKey,raw])
        }
    }

    func automaticBackupRetentionHistory(_ db: Database) throws -> [JSON] {
        try Row.fetchAll(db,sql:"""
            SELECT id,occurred_at,json_object('status',json_extract(data,'$.status'),'moved_count',json_extract(data,'$.moved_count'),'error_code',json_extract(data,'$.error_code'),'trigger_operation_id',json_extract(data,'$.trigger_operation_id'),'command_id',json_extract(data,'$.command_id')) AS summary
            FROM events WHERE kind IN ('backup_pruned','backup_retention_deferred') AND json_extract(data,'$.origin')='automatic_backup_retention' ORDER BY seq DESC LIMIT 20
            """).map {row in var value = jsonObject(row["summary"]);value["id"] = row["id"] as String;value["occurred_at"] = row["occurred_at"] as String;return value}
    }

    /// Runs after the completed backup's capture lease has released. A nil trigger
    /// resolves a durably due backup or an interrupted attempt during startup.
    /// Retention failure never turns a successfully verified backup into failure.
    @discardableResult
    func applyAutomaticBackupRetention(after operation: String? = nil,trashRoot: URL? = nil,observe: (String) throws -> Void = {_ in}) -> JSON {
        automaticBackupRetentionLock.lock();defer {automaticBackupRetentionLock.unlock()}
        // The latest completed backup may replace an older due trigger while an
        // older exact prune intent still reconciles first. A conditional delete
        // below cannot consume a newer backup's concurrently committed trigger.
        let due = try? dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-due'")}
        let dueValue = due.map(jsonObject)
        let boundDue = dueValue.flatMap {value -> String? in
            guard value["source_root"] as? String == root.path,value["incarnation"] as? String == incarnation,
                  let trigger = value["trigger_operation_id"] as? String,UUID(uuidString:trigger) != nil else {return nil}
            return trigger
        }
        let trigger = operation ?? boundDue
        var result = performAutomaticBackupRetention(after:trigger,trashRoot:trashRoot,observe:observe)
        // Reconcile at most one older intent, then apply the completed trigger
        // once. This is bounded recovery, without a retry/polling loop.
        if let trigger,result["status"] as? String == "complete",let previous = result["trigger_operation_id"] as? String,previous != trigger {
            result = performAutomaticBackupRetention(after:trigger,trashRoot:trashRoot,observe:observe)
        }
        if let due,let boundDue,result["status"] as? String == "complete",result["trigger_operation_id"] as? String == boundDue {
            try? ArchiveStorageGate.withExclusive(root:root) { _ in
                try dbQueue.write {db in try db.execute(sql:"DELETE FROM metadata WHERE key='backup-automatic-prune-due' AND value=?",arguments:[due])}
            }
        }
        return result
    }

    private func performAutomaticBackupRetention(after operation: String?,trashRoot: URL?,observe: (String) throws -> Void) -> JSON {
        let caller = Self.automaticBackupRetentionCaller,pendingKey = "backup-automatic-prune-pending"
        var attempt: JSON?
        do {
            let settings = try dbQueue.read {try backupRetentionSettings($0)}
            guard try StorageAutomaticBackupRetention.isConfirmed(settings,root:root,incarnation:incarnation) else {return ["status":"unconfirmed","moved_count":0]}
            var replay: JSON?
            attempt = try ArchiveStorageGate.withExclusive(root:root) { _ -> JSON? in
                try StorageSnapshotRetention.requireNoCapture(root:root)
                if let raw = try dbQueue.read({try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[pendingKey])}) {
                    let value = jsonObject(raw)
                    guard value["source_root"] as? String == root.path,value["incarnation"] as? String == incarnation,
                          let trigger = value["trigger_operation_id"] as? String,UUID(uuidString:trigger) != nil,
                          let params = value["params"] as? JSON,
                          params["command_id"] as? String == StorageAutomaticBackupRetention.command(root:root,incarnation:incarnation,trigger:trigger),
                          params["include_unrecorded"] as? Bool == false,
                          let digest = params["preview_sha256"] as? String,digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {throw StoreRecovery.required("backup_automatic_prune_intent_invalid")}
                    return value
                }
                guard let operation else {return nil}
                guard UUID(uuidString:operation) != nil else {throw CoreError("INVALID_INPUT","A completed backup operation is required for automatic retention.")}
                let command = StorageAutomaticBackupRetention.command(root:root,incarnation:incarnation,trigger:operation)
                if let raw = try dbQueue.read({try String.fetchOne($0,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command])}) {
                    let result = jsonObject(raw)
                    guard (result["data"] as? JSON)?["trigger_operation_id"] as? String == operation else {throw StoreRecovery.required("backup_automatic_prune_receipt_invalid")}
                    replay = result["data"] as? JSON;return nil
                }
                let preview = try backupPrunePreview(retainingOperation:operation)
                guard let current = preview["settings"] as? JSON,try StorageAutomaticBackupRetention.isConfirmed(current,root:root,incarnation:incarnation) else {return nil}
                let params: JSON = ["command_id":command,"preview_sha256":preview["preview_sha256"]!,"include_unrecorded":false]
                let value: JSON = ["source_root":root.path,"incarnation":incarnation,"trigger_operation_id":operation,"params":params,"created_at":now()]
                try dbQueue.write {db in try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:[pendingKey,try jsonString(value)])}
                return value
            }
            if let replay {return replay.merging(["replayed":true]) {_,new in new}}
            guard let attempt,let params = attempt["params"] as? JSON,let trigger = attempt["trigger_operation_id"] as? String else {return ["status":"idle","moved_count":0]}
            let reply = try executeStorageBackupPruning(method:"backup_prune",params:params,caller:caller,trashRoot:trashRoot ?? automaticBackupRetentionTrashRoot,automaticTrigger:trigger,observe:observe)
            let data = reply["data"] as? JSON ?? [:]
            try ArchiveStorageGate.withExclusive(root:root) { _ in
                try dbQueue.write {db in
                    try db.execute(sql:"DELETE FROM metadata WHERE key=? AND value=?",arguments:[pendingKey,try jsonString(attempt)])
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-automatic-prune-last',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(data)])
                }
            }
            return data
        } catch {
            var data: JSON = ["status":"deferred","origin":"automatic_backup_retention","error_code":(error as? CoreError)?.code ?? "BACKUP_PRUNE_IO","occurred_at":now(),"moved_count":NSNull()]
            if let trigger = attempt?["trigger_operation_id"] {data["trigger_operation_id"] = trigger}
            // Keep an interrupted prune's exact UUID and parameters. If pruning
            // never committed its intent, the next completed backup may replan.
            try? ArchiveStorageGate.withExclusive(root:root) { _ in
                try dbQueue.write {db in
                    if let attempt,let params = attempt["params"] as? JSON,let command = params["command_id"] as? String {
                        let journal = "backup-prune-intent:" + hash(Data((caller.principal + command).utf8))
                        if try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[journal]) == nil {
                            try db.execute(sql:"DELETE FROM metadata WHERE key=? AND value=?",arguments:[pendingKey,try jsonString(attempt)])
                        }
                    }
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-automatic-prune-last',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(data)])
                    try event(db,caller:caller,project:nil,entity:nil,kind:"backup_retention_deferred",data:data)
                }
            }
            return data
        }
    }
}
