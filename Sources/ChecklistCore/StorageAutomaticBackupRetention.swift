import Foundation
import CoreFoundation
import GRDB

/// Confirmation is written by backup_retention_set on the authenticated owner
/// channel, or by backup_retention_apply_answer from the owner's own recorded
/// answer. A legacy manual rule is not consent to automatic Trash moves.
enum StorageAutomaticBackupRetention {
    static let answerRefused = "BACKUP_RETENTION_ANSWER_REFUSED"
    private static func validSource(_ receipt: JSON) -> Bool {
        switch receipt["source"] as? String {
        case "authenticated_app":return true
        case "owner_answer":return UUID(uuidString:receipt["request_id"] as? String ?? "") != nil && UUID(uuidString:receipt["response_id"] as? String ?? "") != nil
        default:return false
        }
    }
    static func isConfirmed(_ settings: JSON,root: URL? = nil,incarnation: String? = nil) throws -> Bool {
        guard let raw = settings["automatic_prune"] else {return false}
        guard let enabled = raw as? NSNumber,CFGetTypeID(enabled) == CFBooleanGetTypeID() else {throw StoreRecovery.required("backup_retention_confirmation_invalid")}
        guard enabled.boolValue else {return false}
        guard let owner = settings["owner_confirmed"] as? NSNumber,CFGetTypeID(owner) == CFBooleanGetTypeID(),owner.boolValue,
              let receipt = settings["owner_confirmation"] as? JSON,
              validSource(receipt),
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

extension StorageBackupRetentionPolicy {
    /// The owner's words state the rule: "Newest N, plus one per day for D days",
    /// optionally followed by one parenthetical note. Anything else states no rule.
    static func stated(in value: String) -> StorageBackupRetentionPolicy? {
        let line = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern:#"^Newest ([1-9][0-9]{0,3}), plus one per day for ([1-9][0-9]{0,2}) days?( \([^()\n]*\))?$"#),
              let match = regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
              let first = Range(match.range(at:1),in:line),let second = Range(match.range(at:2),in:line),
              let newest = Int(line[first]),let days = Int(line[second]),newest <= 1000,days <= 366 else {return nil}
        return .init(newestCount:newest,dailyDays:days)
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

    /// An agent names the owner's answer and the service reads the rule from it,
    /// so an agent cannot choose the numbers. The generic write path supplies the
    /// project grant check, command receipt and replay.
    func backupRetentionApplyAnswer(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        guard c.role != "assistant" else {throw CoreError("FORBIDDEN","Only an enrolled worker can apply an owner answer.")}
        func refuse(_ reason: String,_ message: String) -> CoreError {CoreError(StorageAutomaticBackupRetention.answerRefused,message,details:["reason":reason])}
        let askAgain = "Ask the owner with a new request, or the owner can save a rule in Settings."
        let pid = try text(p,"project_id"),requestID = try text(p,"request_id",max:100),responseID = try text(p,"response_id",max:100)
        guard let request = try? scoped(db,requestID,pid,type:"request") else {throw refuse("request_not_in_project","This request is not in this project. Check project_id and request_id.")}
        guard let response = (request["responses"] as? [JSON] ?? []).first(where:{$0["id"] as? String == responseID}) else {throw refuse("response_not_on_request","This response does not belong to this request. Check response_id.")}
        guard response["origin"] as? String == "human_ui" else {throw refuse("response_not_from_owner","This response did not come from the owner in the app. " + askAgain)}
        guard bool(response,"complete"),["answered","send"].contains(response["action"] as? String ?? ""),request["state"] as? String == "answered" else {throw refuse("answer_not_complete","This response is not a complete answer on an answered request. Wait for the owner's answer, or ask again.")}
        guard int(response,"form_revision",default:1) == int(request,"form_revision",default:1) else {throw refuse("answer_for_old_form","This response answers an older form of the request. " + askAgain)}
        guard (request["responses"] as? [JSON] ?? []).last(where:{bool($0,"complete")})?["id"] as? String == responseID else {throw refuse("answer_superseded","The owner gave a later answer on this request. Use the latest response.")}
        let questions = request["questions"] as? [JSON] ?? []
        var stated: [(newest:Int,days:Int)] = []
        for answer in response["answers"] as? [JSON] ?? [] {
            guard let question = questions.first(where:{$0["id"] as? String == answer["question_id"] as? String}) else {continue}
            let options = question["options"] as? [JSON] ?? []
            var words = (answer["option_ids"] as? [String] ?? []).compactMap {id in options.first(where:{$0["id"] as? String == id})?["label"] as? String}
            if let custom = answer["custom_text"] as? String {words.append(custom)}
            for word in words {
                if let rule = StorageBackupRetentionPolicy.stated(in:word),!stated.contains(where:{$0.newest == rule.newestCount && $0.days == rule.dailyDays}) {stated.append((rule.newestCount,rule.dailyDays))}
            }
        }
        guard stated.count == 1,let rule = stated.first else {throw refuse(stated.isEmpty ? "no_rule_in_answer" : "more_than_one_rule","The owner's answer must state one rule in the form \"Newest N, plus one per day for D days\", with N from 1 to 1000 and D from 1 to 366. " + askAgain)}
        guard let answeredAt = response["created_at"] as? String,let answered = ISO8601DateFormatter().date(from:answeredAt) else {throw refuse("answer_time_unknown","This response has no readable answer time. " + askAgain)}
        var settings = try backupRetentionSettings(db)
        func summary(_ confirmedAt: Any?,alreadyApplied: Bool) -> JSON {
            var value: JSON = ["status":"rule_confirmed_from_answer","newest_count":rule.newest,"daily_days":rule.days,"daily_timezone":"UTC","rule_source":"owner_answer","request_id":requestID,"response_id":responseID,"answered_at":answeredAt,"already_applied":alreadyApplied]
            if let confirmedAt {value["confirmed_at"] = confirmedAt}
            return value
        }
        if let current = settings["owner_confirmation"] as? JSON {
            if current["source"] as? String == "owner_answer",current["response_id"] as? String == responseID {
                guard current["source_root"] as? String == root.path,current["incarnation"] as? String == incarnation else {throw refuse("answer_from_other_installation","This answer was applied in another installation or before a restore, so it does not carry over. " + askAgain)}
                return summary(current["confirmed_at"],alreadyApplied:true)
            }
            // A new command ID must not bring back an answer the owner already replaced.
            if let raw = current["answered_at"] as? String ?? current["confirmed_at"] as? String,let newer = ISO8601DateFormatter().date(from:raw),answered <= newer {
                throw refuse("newer_rule_exists","The owner set the current rule after this answer, so the current rule stays. " + askAgain)
            }
        }
        let confirmedAt = now(),command = try text(p,"command_id",max:100)
        let confirmation: JSON = ["principal":c.principal,"command_id":command,"confirmed_at":confirmedAt,"source":"owner_answer","project_id":pid,"task_id":request["task_id"] ?? NSNull(),"request_id":requestID,"response_id":responseID,"answered_at":answeredAt,"source_root":root.path,"incarnation":incarnation]
        settings.merge(StorageBackupRetentionPolicy(newestCount:rule.newest,dailyDays:rule.days).json) {_,new in new}
        settings["owner_confirmed"] = true
        settings["automatic_prune"] = true
        settings["owner_confirmation"] = confirmation
        try fenceForeignAutomaticRetentionIntent(db,confirmation:confirmation)
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-retention-settings',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(settings)])
        let result = summary(confirmedAt,alreadyApplied:false)
        try event(db,caller:c,project:pid,entity:request["task_id"] as? String,kind:"backup_retention_answer_applied",data:result)
        return result
    }

    /// An agent reads whether the rule applies and whether the last prune ran. The
    /// reply has no folder path and no request or response ID, because the rule and
    /// its history belong to the installation and can come from another project.
    func backupRetentionStatus(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        guard c.role != "assistant" else {throw CoreError("FORBIDDEN","Only an enrolled worker can read the retention state.")}
        if !c.isOwner {_ = try scope(db,p,c)}
        let settings = try backupRetentionSettings(db),confirmation = settings["owner_confirmation"] as? JSON
        func metadata(_ key: String) throws -> String? {try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])}
        var value: JSON = ["newest_count":settings["newest_count"] ?? NSNull(),"daily_days":settings["daily_days"] ?? NSNull(),"daily_timezone":"UTC","owner_confirmed":bool(settings,"owner_confirmed"),"automatic_prune":bool(settings,"automatic_prune"),"rule_source":confirmation?["source"] ?? NSNull(),"confirmed_at":confirmation?["confirmed_at"] ?? NSNull(),"pin_count":(settings["pins"] as? [JSON] ?? []).count]
        var last: JSON = [:]
        if let raw = try metadata("backup-automatic-prune-last") {
            let result = jsonObject(raw)
            for key in ["status","moved_count","error_code","underlying_error","posix_errno","occurred_at","trigger_operation_id"] {if let item = result[key] {last[key] = item}}
            if let retained = result["retained_snapshots"] as? [JSON] {last["retained_count"] = retained.count}
        }
        value["last_result"] = last.isEmpty ? NSNull() : last
        value["last_error"] = last["underlying_error"] ?? last["error_code"] ?? NSNull()
        value["moved_count"] = last["moved_count"] ?? NSNull()
        value["retry_due"] = try metadata("backup-automatic-prune-due") != nil
        value["prune_pending"] = try metadata("backup-automatic-prune-pending") != nil
        value["history"] = try automaticBackupRetentionHistory(db).map {$0.filter {!["request_id","response_id"].contains($0.key)}}
        return value
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
            SELECT id,occurred_at,json_object('status',json_extract(data,'$.status'),'moved_count',json_extract(data,'$.moved_count'),'error_code',json_extract(data,'$.error_code'),'underlying_error',json_extract(data,'$.underlying_error'),'posix_errno',json_extract(data,'$.posix_errno'),'trigger_operation_id',json_extract(data,'$.trigger_operation_id'),'command_id',json_extract(data,'$.command_id'),'newest_count',json_extract(data,'$.newest_count'),'daily_days',json_extract(data,'$.daily_days'),'request_id',json_extract(data,'$.request_id'),'response_id',json_extract(data,'$.response_id')) AS summary
            FROM events WHERE (kind IN ('backup_pruned','backup_retention_deferred') AND json_extract(data,'$.origin')='automatic_backup_retention') OR kind='backup_retention_answer_applied' ORDER BY seq DESC LIMIT 20
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
            for key in ["underlying_error","posix_errno"] {if let value = (error as? CoreError)?.details[key] {data[key] = value}}
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
