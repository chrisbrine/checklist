import Foundation
import GRDB
import Darwin
import CoreFoundation

/// Advisory cross-process use of the immutable manifest. Nothing is added to a
/// snapshot: read-only backup volumes remain usable. Every supported pruner takes
/// the exclusive lease before moving its directory; proof/restore take shared.
final class StorageBackupUseLease {
    let files: StorageObjectFiles
    private let descriptor: Int32
    private let identity: stat
    init(root: URL,exclusive: Bool = false,pinnedFiles: StorageObjectFiles? = nil) throws {
        let files = try pinnedFiles ?? StorageObjectFiles(root:root,pinRootForGates:true)
        let fd = openat(files.descriptor,"manifest.json",O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {throw CoreError("BACKUP_USE_UNAVAILABLE","The backup manifest cannot be opened safely.",details:["posix_errno":errno])}
        do {
            var info = stat()
            guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG else {throw StorageSnapshotFailure.incomplete}
            while flock(fd,(exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
                if errno == EINTR {continue}
                if errno == EWOULDBLOCK {throw CoreError("BACKUP_IN_USE","This snapshot is in use; it was retained.")}
                throw CoreError("BACKUP_USE_UNAVAILABLE","The backup use lease cannot be acquired.",details:["posix_errno":errno])
            }
            try files.requireNamedRoot(files.root)
            var named = stat()
            guard fstatat(files.descriptor,"manifest.json",&named,AT_SYMLINK_NOFOLLOW) == 0,
                  TicketObjectRemovalVerification.same(info,named) else {throw StorageSnapshotFailure.sourceChanged}
            self.files = files;descriptor = fd;identity = info
        } catch {Darwin.close(fd);throw error}
    }
    deinit {Darwin.close(descriptor)}
    func requireCurrent() throws {
        try files.requireNamedRoot(files.root)
        var actual = stat()
        guard fstatat(files.descriptor,"manifest.json",&actual,AT_SYMLINK_NOFOLLOW) == 0,
              TicketObjectRemovalVerification.same(identity,actual) else {throw StorageSnapshotFailure.sourceChanged}
    }
    func manifestSHA256() throws -> String {
        let bytes = try files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
        try requireCurrent();return hash(bytes)
    }
}

struct StorageBackupRetentionPolicy {
    let newestCount: Int
    let dailyDays: Int
    static let proposed = StorageBackupRetentionPolicy(newestCount:5,dailyDays:7)
    var json: JSON {["newest_count":newestCount,"daily_days":dailyDays,"daily_timezone":"UTC","automatic_prune":false]}
    static func parse(_ value: JSON) throws -> StorageBackupRetentionPolicy {
        func count(_ key: String,_ fallback: Int,_ maximum: Int) throws -> Int {
            guard let raw = value[key] else {return fallback}
            guard let n = raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= 0,n.doubleValue <= Double(maximum) else {throw CoreError("INVALID_INPUT","\(key) must be an integer from 0 through \(maximum).")}
            return n.intValue
        }
        let newest = try count("newest_count",5,1000),days = try count("daily_days",7,366)
        guard newest > 0 else {throw CoreError("INVALID_INPUT","Keep at least the newest snapshot.")}
        return .init(newestCount:newest,dailyDays:days)
    }
    /// Newest complete snapshot in each UTC calendar day including today and the
    /// preceding dailyDays-1 days. Future timestamps are conservatively retained.
    func reasons(_ snapshots: [(path:String,date:String)],at date: Date,preferredPath: String? = nil) -> [String:[String]] {
        let formatter = ISO8601DateFormatter()
        let ordered = snapshots.sorted {
            let left = formatter.date(from:$0.date) ?? .distantPast,right = formatter.date(from:$1.date) ?? .distantPast
            if left == right,let preferredPath,($0.path == preferredPath || $1.path == preferredPath) {return $0.path == preferredPath}
            return left == right ? $0.path < $1.path : left > right
        }
        var result: [String:[String]] = [:],days = Set<String>(),complete = 0
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let today = calendar.startOfDay(for:date),lower = calendar.date(byAdding:.day,value:1-dailyDays,to:today)!
        for snapshot in ordered {
            guard let captured = formatter.date(from:snapshot.date) else {result[snapshot.path,default:[]].append("unknown_capture_time");continue}
            if complete < newestCount {result[snapshot.path,default:[]].append("newest")}
            complete += 1
            if captured > date {result[snapshot.path,default:[]].append("future_capture_time")}
            let day = calendar.startOfDay(for:captured),key = String(day.timeIntervalSince1970)
            if dailyDays > 0,day >= lower,day <= today,days.insert(key).inserted {result[snapshot.path,default:[]].append("daily")}
        }
        return result
    }
}

extension CommandRouter {
    static let storageBackupPruningMethods: Set<String> = ["backup_retention_get","backup_retention_set","backup_pin","backup_prune_preview","backup_prune"]
    /// Test seam is an explicit owned directory, never the user's Trash. Production
    /// uses the filesystem's appropriate Trash and atomic same-volume rename only.
    func executeStorageBackupPruning(method: String,params: JSON,caller: Caller,trashRoot: URL? = nil,automaticTrigger: String? = nil,observe: (String) throws -> Void = {_ in}) throws -> JSON {
        if automaticTrigger != nil {
            guard method == "backup_prune",caller.principal == Self.automaticBackupRetentionCaller.principal else {throw CoreError("FORBIDDEN","Automatic backup retention is an internal service operation.")}
        } else {try owner(caller)}
        if method == "backup_retention_get" {return ["data":try dbQueue.read {db -> JSON in
            var settings = try backupRetentionSettings(db)
            if let last = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-automatic-prune-last'") {settings["last_automatic_prune"] = jsonObject(last)}
            settings["automatic_prune_history"] = try automaticBackupRetentionHistory(db)
            return settings
        }]}
        if method == "backup_prune_preview" {return ["data":try backupPrunePreview(includeUnrecorded:bool(params,"include_unrecorded"))]}
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        let digest = hash(Data((method + (try jsonString(params))).utf8))
        do {return try ArchiveStorageGate.withExclusive(root:root) { _ in
            if let replay = try dbQueue.read({try backupPruneReplay($0,command:command,digest:digest,caller:caller)}) {return replay}
            if method == "backup_retention_set" || method == "backup_pin" {
                return try dbQueue.write {db in
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                    var settings = try backupRetentionSettings(db)
                    if method == "backup_retention_set" {
                        let policy = try StorageBackupRetentionPolicy.parse(params)
                        settings.merge(policy.json) {_,new in new}
                        settings["owner_confirmed"] = true
                        settings["automatic_prune"] = true
                        let confirmation: JSON = ["principal":caller.principal,"command_id":command,"confirmed_at":now(),"source":"authenticated_app","source_root":root.path,"incarnation":incarnation]
                        settings["owner_confirmation"] = confirmation
                        try fenceForeignAutomaticRetentionIntent(db,confirmation:confirmation)
                    } else {
                        let path = URL(fileURLWithPath:try text(params,"path"),isDirectory:true).standardizedFileURL
                        try requireManagedBackupPath(path)
                        guard let pinned = params["pinned"] as? NSNumber,CFGetTypeID(pinned) == CFBooleanGetTypeID() else {throw CoreError("INVALID_INPUT","pinned must be a boolean.")}
                        let retire: Bool
                        if let raw = params["retire_upgrade_protection"] {
                            guard let n = raw as? NSNumber,CFGetTypeID(n) == CFBooleanGetTypeID(),!n.boolValue || !pinned.boolValue else {throw CoreError("INVALID_INPUT","retire_upgrade_protection requires pinned:false.")}
                            retire = n.boolValue
                        } else {retire = false}
                        var pins = settings["pins"] as? [JSON] ?? []
                        pins.removeAll {pin in
                            guard let original = pin["path"] as? String else {return false}
                            return StorageBackupProtectionAliases.paths(original,root:root).contains(path.path)
                        }
                        if pinned.boolValue {
                            let lease = try StorageBackupUseLease(root:path),sha = try lease.manifestSHA256()
                            pins.append(["path":path.path,"manifest_sha256":sha])
                        }
                        if retire,let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-protected-history'") {
                            guard var history = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [JSON] else {throw StoreRecovery.required("backup_protected_history_invalid")}
                            history.removeAll {entry in
                                guard let original = entry["path"] as? String else {return false}
                                return StorageBackupProtectionAliases.paths(original,root:root).contains(path.path)
                            }
                            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='backup-protected-history'",arguments:[try jsonString(history)])
                        }
                        // Current preupgrade_snapshot and prepared upgrade are
                        // deliberately independent: this retires history only.
                        settings["pins"] = pins
                    }
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-retention-settings',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(settings)])
                    try event(db,caller:caller,project:nil,entity:nil,kind:method,data:settings)
                    return try backupPruneFinish(db,command:command,digest:digest,caller:caller,data:settings)
                }
            }
            try StorageSnapshotRetention.requireNoCapture(root:root)
            let journalKey = "backup-prune-intent:" + hash(Data((caller.principal + command).utf8))
            var journal = try dbQueue.read {db -> JSON? in
                guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[journalKey]) else {return nil}
                let value = jsonObject(raw)
                guard value["digest"] as? String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This prune command belongs to another intent.")}
                return value
            }
            if journal == nil {
                let preview = try backupPrunePreview(includeUnrecorded:bool(params,"include_unrecorded"),retainingOperation:automaticTrigger)
                guard try text(params,"preview_sha256",max:64) == preview["preview_sha256"] as? String else {throw CoreError("BACKUP_PRUNE_PREVIEW_CHANGED","Review a fresh backup prune preview before applying it.")}
                guard bool(preview,"owner_confirmed") else {throw CoreError("BACKUP_RETENTION_UNCONFIRMED","The owner must confirm the retention setting before pruning.")}
                let candidates = (preview["snapshots"] as? [JSON] ?? []).filter {bool($0,"prune")}
                var entries: [JSON] = []
                let trash: URL?
                if candidates.isEmpty {trash = nil}
                else if let trashRoot {trash = trashRoot}
                else {trash = try FileManager.default.url(for:.trashDirectory,in:.userDomainMask,appropriateFor:root,create:true)}
                if let trash {
                    let parent = try StorageObjectFiles(root:trash)
                    // A pre-intent crash may leave this owned empty Trash
                    // container. Its random identity never blocks original retry.
                    let name = "Checklist-backups-" + command + "-" + uuid()
                    let owned = try parent.makeDirectory(name)
                    let marker: JSON = ["principal":caller.principal,"digest":digest,"source_root":root.path]
                    try owned.writeNew("prune-owner.json",bytes:Data((try jsonString(marker)).utf8))
                    try parent.synchronizePublicationDirectory()
                    for (index,candidate) in candidates.enumerated() {
                        var entry = candidate
                        entry["trash_path"] = owned.root.appendingPathComponent(String(index) + "-" + URL(fileURLWithPath:candidate["path"] as! String).lastPathComponent).path
                        entries.append(entry)
                    }
                }
                journal = ["digest":digest,"entries":entries,"created_at":now()]
                try dbQueue.write {db in
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:[journalKey,try jsonString(journal!)])
                    let pendingKey = try self.pendingStorageCommandKey(principal:caller.principal,command:command)
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[pendingKey,try jsonString(["kind":"backup_prune","intent_digest":digest,"state":"pending"])])
                }
                try observe("prune_intent_committed")
            }
            let pendingKey = try pendingStorageCommandKey(principal:caller.principal,command:command)
            try dbQueue.write {db in
                try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[pendingKey,try jsonString(["kind":"backup_prune","intent_digest":digest,"state":"pending"])])
            }
            var moved: [JSON] = [],retained: [JSON] = []
            // A crash releases the object gate. Pins, upgrade protection and the
            // owner's rule may change before original retry. Recheck every source
            // still present; already moved exact inodes must finish reconciliation.
            let current = try backupPrunePreview(includeUnrecorded:bool(params,"include_unrecorded"),retainingOperation:automaticTrigger)
            let decisions = Dictionary(uniqueKeysWithValues:(current["snapshots"] as? [JSON] ?? []).map {($0["path"] as! String,$0)})
            for entry in journal!["entries"] as? [JSON] ?? [] {
                let path = entry["path"] as! String
                var info = stat()
                if lstat(path,&info) == 0,decisions[path].map({!bool($0,"prune")}) ?? true {
                    var kept = entry;kept["reason"] = "current_retention_protection"
                    kept["keep_reasons"] = decisions[path]?["keep_reasons"] ?? ["no_current_prune_authority"]
                    retained.append(kept);continue
                }
                do {try moveBackupToTrash(entry);try moveBackupIndexToTrash(entry);moved.append(entry);try observe("prune_snapshot_moved")}
                catch let error as CoreError where error.code == "BACKUP_IN_USE" {var kept = entry;kept["reason"] = "in_use";retained.append(kept)}
            }
            return try dbQueue.write {db in
                try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                for entry in moved {
                    if let key = entry["generation_key"] as? String,!key.isEmpty {
                        // The durable intent binds an exact manifest, path and row.
                        // Do not retire a replacement record under an old plan.
                        if let raw = try String.fetchOne(db,sql:"SELECT json_object('manifest',json_extract(value,'$.manifest_sha256'),'path',json_extract(value,'$.summary.path')) FROM metadata WHERE key=?",arguments:[key]) {
                            let actual = jsonObject(raw)
                            guard actual["manifest"] as? String == entry["manifest_sha256"] as? String,actual["path"] as? String == entry["path"] as? String else {throw CoreError("BACKUP_PRUNE_RECORD_CHANGED","The moved snapshot's receipt changed; preserve this prune command for reconciliation.")}
                            try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key])
                        }
                        if let operation = entry["operation_id"] as? String {
                            try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:["storage-copy-usage:backup:" + operation])
                            try db.execute(sql:"DELETE FROM metadata WHERE key='storage-last-verified-backup' AND json_extract(value,'$.operation_id')=?",arguments:[operation])
                        }
                    }
                }
                var data: JSON = ["status":"complete","moved_to_trash":moved,"retained_in_use":retained.filter {$0["reason"] as? String == "in_use"},"retained_snapshots":retained,"moved_count":moved.count,"physical_space_freed":NSNull(),"trash_requires_owner_emptying":true]
                if let automaticTrigger {
                    data["origin"] = "automatic_backup_retention"
                    data["trigger_operation_id"] = automaticTrigger
                    data["command_id"] = command
                    data["occurred_at"] = now()
                    data["owner_confirmation"] = (current["settings"] as? JSON)?["owner_confirmation"] ?? NSNull()
                }
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:["backup-pruned:" + command,try jsonString(data)])
                try db.execute(sql:"DELETE FROM metadata WHERE key IN (?,?)",arguments:[journalKey,pendingKey])
                try event(db,caller:caller,project:nil,entity:nil,kind:"backup_pruned",data:data)
                return try backupPruneFinish(db,command:command,digest:digest,caller:caller,data:data)
            }
        }} catch {
            if method == "backup_prune" {
                let key = "backup-prune-intent:" + hash(Data((caller.principal + command).utf8))
                let pending = (try? dbQueue.read {db in
                    guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) else {return false}
                    return jsonObject(raw)["digest"] as? String == digest
                }) ?? true // An unreadable journal cannot establish rejection.
                if pending {
                    throw CoreError("OUTCOME_UNKNOWN","Backup pruning needs reconciliation. Keep the original command and check the last change before starting another prune.",details:["command_id":command,"command_outcome":"unknown","reason":"backup_prune_intent_pending","underlying_error":(error as? CoreError)?.code ?? "BACKUP_PRUNE_IO"])
                }
            }
            throw error
        }
    }
    private func backupPruneReplay(_ db: Database,command: String,digest: String,caller: Caller) throws -> JSON? {
        guard let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) else {return nil}
        guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID already belongs to another intent.")}
        let result = jsonObject(row["result"])
        if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
        return result.merging(["replayed":true]) {_,new in new}
    }
    private func backupPruneFinish(_ db: Database,command: String,digest: String,caller: Caller,data: JSON) throws -> JSON {
        let output: JSON = ["data":data,"command_id":command]
        try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,digest,try jsonString(output)])
        return output
    }
    func backupRetentionSettings(_ db: Database) throws -> JSON {
        if let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-retention-settings'") {
            guard let value = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON,
                  let pins = value["pins"] as? [JSON],
                  let confirmed = value["owner_confirmed"] as? NSNumber,CFGetTypeID(confirmed) == CFBooleanGetTypeID(),
                  pins.allSatisfy({pin in
                      guard let path = pin["path"] as? String,path.hasPrefix("/"),let sha = pin["manifest_sha256"] as? String else {return false}
                      return sha.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil
                  }), (try? StorageBackupRetentionPolicy.parse(value)) != nil else {throw StoreRecovery.required("backup_retention_settings_invalid")}
            var settings = value
            // Pre-automatic rules remain manual until the owner explicitly saves
            // the rule through the trusted app with automatic retention disclosed.
            settings["automatic_prune"] = try StorageAutomaticBackupRetention.isConfirmed(value,root:root,incarnation:incarnation)
            return settings
        }
        return StorageBackupRetentionPolicy.proposed.json.merging(["pins":[] as [JSON],"owner_confirmed":false]) {_,new in new}
    }
    private func requireManagedBackupPath(_ path: URL) throws {
        let prefix = root.appendingPathComponent("backups").path + "/"
        guard path.path.hasPrefix(prefix) else {throw CoreError("BACKUP_PRUNE_PATH_REFUSED","Only snapshots inside this installation's backups folder can be pruned.")}
        let parts = String(path.path.dropFirst(prefix.count)).split(separator:"/").map(String.init)
        let direct = parts.count == 1 || parts.count == 2 && parts[0].hasPrefix("qualification-")
        let name = parts.last ?? ""
        let snapshot = name.hasPrefix("snapshot-") || [".snapshot-failed-",".snapshot-incomplete-",".snapshot-staging-"].contains {name.hasPrefix($0)}
        guard direct,snapshot else {throw CoreError("BACKUP_PRUNE_PATH_REFUSED","Only named snapshot folders directly in backups or its qualification folder can be pruned.")}
    }
    func backupPrunePreview(includeUnrecorded: Bool = false,at date: Date = Date(),retainingOperation: String? = nil) throws -> JSON {
        let (settings,receipts,protected,historical) = try dbQueue.read {db -> (JSON,[JSON],Set<String>,Set<String>) in
            let settings = try backupRetentionSettings(db)
            let rows = try Row.fetchAll(db,sql:"SELECT key,json_object('operation_id',json_extract(value,'$.operation_id'),'state',json_extract(value,'$.state'),'manifest_sha256',json_extract(value,'$.manifest_sha256'),'summary',json_extract(value,'$.summary'),'historical_catalog',json_extract(value,'$.historical_catalog')) AS header FROM metadata WHERE key GLOB 'backup-generation:*'")
            var protected = Set<String>(),historical = Set<String>()
            for key in ["preupgrade_snapshot","backup-protected-history"] {
                if let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) {
                    guard let value = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) else {throw StoreRecovery.required("backup_protected_history_invalid")}
                    let values: [JSON]
                    if key == "preupgrade_snapshot" {
                        guard let snapshot = value as? JSON else {throw StoreRecovery.required("backup_protected_history_invalid")}
                        values = [snapshot]
                    } else {
                        guard let history = value as? [JSON] else {throw StoreRecovery.required("backup_protected_history_invalid")}
                        values = history
                    }
                    for v in values where v["protected"] != nil {
                        guard let flag = v["protected"] as? NSNumber,CFGetTypeID(flag) == CFBooleanGetTypeID() else {throw StoreRecovery.required("backup_protected_history_invalid")}
                        if flag.boolValue {
                            guard let path = v["path"] as? String,path.hasPrefix("/") else {throw StoreRecovery.required("backup_protected_history_invalid")}
                            let aliases = StorageBackupProtectionAliases.paths(path,root:root)
                            protected.formUnion(aliases)
                            if key == "backup-protected-history" {historical.formUnion(aliases)}
                        }
                    }
                }
            }
            return (settings,rows.map {var value = jsonObject($0["header"]);value["generation_key"] = $0["key"] as String;return value},protected,historical)
        }
        let policy = try StorageBackupRetentionPolicy.parse(settings)
        var snapshots: [String:JSON] = [:]
        for receipt in receipts {
            guard let summary = receipt["summary"] as? JSON,let path = summary["path"] as? String else {continue}
            let complete = !(receipt["historical_catalog"] is JSON) && !URL(fileURLWithPath:path,isDirectory:true).lastPathComponent.hasPrefix(".") && receipt["state"] as? String == "complete" && summary["verification"] as? String == "manifest_database_managed_files" && summary["manifest_sha256"] as? String == receipt["manifest_sha256"] as? String
            snapshots[path] = ["path":path,"state":complete ? "complete" : "incomplete","manifest_sha256":receipt["manifest_sha256"] ?? NSNull(),"operation_id":receipt["operation_id"] ?? "","generation_key":receipt["generation_key"]!,"captured_at":summary["captured_at"] ?? NSNull(),"usage":summary["usage"] ?? NSNull()]
        }
        let parent = root.appendingPathComponent("backups")
        if FileManager.default.fileExists(atPath:parent.path) {
            let files = try StorageObjectFiles(root:parent,pinRootForGates:true)
            func scan(_ base: URL,_ depth: Int) throws {
                for url in try FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:nil) {
                    var info = stat()
                    guard lstat(url.path,&info) == 0,info.st_mode & S_IFMT == S_IFDIR else {continue}
                    if url.lastPathComponent.hasPrefix("qualification-"),depth == 0 {try scan(url,1);continue}
                    guard url.lastPathComponent.hasPrefix("snapshot-") || url.lastPathComponent.hasPrefix(".snapshot-") else {continue}
                    if snapshots[url.path] == nil {snapshots[url.path] = ["path":url.path,"state":"unrecorded_or_incomplete","generation_key":"","operation_id":"","captured_at":NSNull(),"manifest_sha256":NSNull()]}
                }
            }
            try files.requireNamedRoot(parent);try scan(parent,0);try files.requireNamedRoot(parent)
        }
        // A prepared upgrade is protected before its database migration commits.
        let storeFiles = try StorageObjectFiles(root:root)
        if try storeFiles.regularOrLinkExists(StorageUpgradePreparation.receiptName) {
            let bytes = try storeFiles.read(StorageUpgradePreparation.receiptName,maximum:16_384)
            guard let value = try? JSONSerialization.jsonObject(with:bytes) as? JSON,let operation = value["operation"] as? String,UUID(uuidString:operation) != nil else {throw StoreRecovery.required("backup_prepared_protection_invalid")}
            let path = parent.appendingPathComponent("snapshot-" + operation.lowercased()).path
            protectedInsert(path,into:&snapshots)
        }
        let eligible = snapshots.values.filter {$0["state"] as? String == "complete"}.compactMap {value -> (path:String,date:String)? in
            guard let path = value["path"] as? String,let time = value["captured_at"] as? String else {return nil};return (path,time)
        }
        let preferred = snapshots.values.first {retainingOperation != nil && $0["operation_id"] as? String == retainingOperation}?["path"] as? String
        let kept = policy.reasons(eligible,at:date,preferredPath:preferred),pins = settings["pins"] as? [JSON] ?? []
        var pinnedPaths = Set<String>()
        for pin in pins {
            if let path = pin["path"] as? String {pinnedPaths.formUnion(StorageBackupProtectionAliases.paths(path,root:root))}
        }
        var output: [JSON] = []
        for path in snapshots.keys.sorted() {
            var snapshot = snapshots[path]!,reasons = kept[path] ?? []
            snapshot["historical_upgrade_protection"] = historical.contains(path)
            if let retainingOperation,snapshot["operation_id"] as? String == retainingOperation {reasons.append("completed_backup_trigger")}
            let managed = (try? requireManagedBackupPath(URL(fileURLWithPath:path,isDirectory:true))) != nil
            if !managed {reasons.append("outside_managed_backups")}
            if protected.contains(path) || bool(snapshot,"upgrade_prepared") {reasons.append("protected_upgrade")}
            if pinnedPaths.contains(path) {reasons.append("owner_pinned")}
            if snapshot["state"] as? String != "complete",!includeUnrecorded {reasons.append("unrecorded_or_incomplete")}
            if snapshot["state"] as? String == "complete",snapshot["captured_at"] is NSNull {reasons.append("unknown_capture_time")}
            // Historical/foreign paths are display provenance, never I/O authority.
            if managed {
                var info = stat()
                if lstat(path,&info) != 0 || info.st_mode & S_IFMT != S_IFDIR {reasons.append("missing_or_changed")}
                else {snapshot["device"] = Int64(info.st_dev);snapshot["inode"] = UInt64(info.st_ino)}
                // Missing manifests cannot receive a use lease or become candidates.
                if let lease = try? StorageBackupUseLease(root:URL(fileURLWithPath:path,isDirectory:true)),let sha = try? lease.manifestSHA256() {
                    if let expected = snapshot["manifest_sha256"] as? String,expected != sha {reasons.append("manifest_changed")}
                    snapshot["manifest_sha256"] = sha
                } else {reasons.append("manifest_unavailable_or_in_use")}
            }
            snapshot["keep_reasons"] = reasons;snapshot["prune"] = reasons.isEmpty
            output.append(snapshot)
        }
        let body: JSON = ["settings":settings,"owner_confirmed":bool(settings,"owner_confirmed"),"include_unrecorded":includeUnrecorded,"snapshots":output,"snapshot_count":output.count,"prune_count":output.filter {bool($0,"prune")}.count,"retained_count":output.filter {!bool($0,"prune")}.count,"physical_space_freed":NSNull()]
        return body.merging(["preview_sha256":hash(Data((try jsonString(body)).utf8))]) {_,new in new}
    }
    private func protectedInsert(_ path: String,into snapshots: inout [String:JSON]) {
        if snapshots[path] != nil {snapshots[path]!["upgrade_prepared"] = true}
    }
    private func moveBackupIndexToTrash(_ entry: JSON) throws {
        guard let digest = entry["manifest_sha256"] as? String,digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {return}
        let files = try StorageObjectFiles(root:root),relative = "backups/.indexes/" + digest + ".keys"
        guard try files.regularOrLinkExists(relative) else {return} // Derived and regenerable.
        let (parent,name) = try files.parent(relative);defer {Darwin.close(parent)}
        let destination = URL(fileURLWithPath:entry["trash_path"] as! String).deletingLastPathComponent()
        let trash = try StorageObjectFiles(root:destination),target = digest + ".keys"
        var info = stat()
        guard fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) == 0,info.st_mode & S_IFMT == S_IFREG else {throw CoreError("BACKUP_PRUNE_INDEX_CHANGED","The derived backup index changed; retry the original prune command.")}
        // An already moved index reconciles normally. If a concurrent reader
        // regenerated it meanwhile, retain that derived duplicate conservatively.
        if try trash.regularOrLinkExists(target) {return}
        guard renameatx_np(parent,name,trash.descriptor,target,UInt32(RENAME_EXCL)) == 0,fsync(parent) == 0 else {throw CoreError("BACKUP_PRUNE_IO","The derived backup index could not be moved to Trash.",details:["posix_errno":errno])}
        try trash.synchronizePublicationDirectory()
    }
    private func moveBackupToTrash(_ entry: JSON) throws {
        let source = URL(fileURLWithPath:entry["path"] as! String),destination = URL(fileURLWithPath:entry["trash_path"] as! String)
        try requireManagedBackupPath(source)
        var sourceInfo = stat()
        let present = lstat(source.path,&sourceInfo) == 0
        let location = present ? source : destination
        let lease = try StorageBackupUseLease(root:location,exclusive:true)
        var info = stat()
        guard fstat(lease.files.descriptor,&info) == 0,Int64(info.st_dev) == (entry["device"] as? NSNumber)?.int64Value,UInt64(info.st_ino) == (entry["inode"] as? NSNumber)?.uint64Value,
              try lease.manifestSHA256() == entry["manifest_sha256"] as? String else {throw CoreError("BACKUP_PRUNE_SOURCE_CHANGED","The snapshot changed; preserve the original prune command for reconciliation.")}
        if !present {return} // Exact moved inode and manifest reconcile a crash after rename.
        let parent = try StorageObjectFiles(root:source.deletingLastPathComponent()),trash = try StorageObjectFiles(root:destination.deletingLastPathComponent())
        try lease.requireCurrent()
        guard renameatx_np(parent.descriptor,source.lastPathComponent,trash.descriptor,destination.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else {throw CoreError("BACKUP_PRUNE_IO","Snapshot could not be moved atomically to the same-volume Trash; it was retained.",details:["posix_errno":errno])}
        try parent.synchronizePublicationDirectory();try trash.synchronizePublicationDirectory()
    }
}
