import Foundation
import GRDB
import Darwin

/// Trusted app only. Materializes a new, separately published data root; it never
/// replaces an open store, imports credentials or revives restored authority.
extension CommandRouter {
    static let storageRestoreMethods: Set<String> = ["restore_preview","restore_create"]

    func executeStorageRestore(method: String,params: JSON,caller: Caller,budget: StorageSnapshotBudget = .production()) throws -> JSON {
        try owner(caller)
        if method == "restore_create",let command = params["command_id"] as? String {
            let digest = hash(Data((method + (try jsonString(params))).utf8))
            if let replay = try dbQueue.read({db -> JSON? in
                guard let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) else {return nil}
                guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This original command belongs to another intent.")}
                let result = jsonObject(row["result"])
                if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                return result.merging(["replayed":true]) {_,new in new}
            }) {return replay}
        }
        let source = URL(fileURLWithPath:try text(params,"path"),isDirectory:true).standardizedFileURL
        do {
            let files = try StorageObjectFiles(root:source)
            let (manifest,manifestDigest) = try autoreleasepool {
                let bytes = try files.read("manifest.json",maximum:budget.maximumManifestBytes)
                return (try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes),hash(bytes))
            }
            guard let operation = UUID(uuidString:manifest.operationID) else {throw StorageSnapshotFailure.incomplete}
            let digest = try autoreleasepool {try StorageSnapshot.verify(files,operation:operation,budget:budget)}
            guard digest == manifestDigest else {throw StorageSnapshotFailure.sourceChanged}
            // Older schemas need the separately protected migration path before
            // restore. Never apply an unqualified schema rewrite during restore.
            guard manifest.schema == 3 else {throw CoreError("RESTORE_SCHEMA_UNSUPPORTED","Restore requires a current-format backup. Qualify an upgrade on a separate copy first.")}
            if method == "restore_preview" {
                var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
                let database = try DatabaseQueue(path:source.appendingPathComponent("database.sqlite").path,configuration:config)
                defer {try? database.close()}
                let projects = try database.read {db in try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='project' ORDER BY id").map {row -> JSON in
                    let value = try GRDBRecordEnvelopeAdapter.decode(row).object
                    return ["id":value["id"]!,"name":value["name"] ?? "","archived":value["archived"] ?? false]
                }}
                let families: [String:Int]
                if let captured = manifest.recordFamilies {families = captured}
                else {families = try database.read {try StorageSnapshot.recordFamilyCounts($0)}}
                return ["data":["manifest_sha256":digest,"path":source.path,"schema":manifest.schema,"store_id":manifest.storeID,"source_root":manifest.sourceRoot,"captured_at":manifest.capturedAt as Any? ?? NSNull(),"verified_at":now(),"record_families":families,"projects":Array(projects.prefix(200)),"project_count":projects.count,"managed_files":manifest.objects.count,"managed_bytes":manifest.objects.reduce(Int64(0)) {$0 + $1.size},"unavailable":manifest.unavailable.map {["authority":$0.authority,"reason":$0.reason]},"external_references":manifest.externalReferences,"destination_parent":root.appendingPathComponent("restore").path,"existing_store_preserved":true,"authority":"new_incarnation_recovery_required"]]
            }
            guard try text(params,"manifest_sha256",max:64) == digest else {throw CoreError("RESTORE_PREVIEW_CHANGED","The backup changed after preview. Preview it again before restoring.")}
            return try StorageSnapshotRetention.withCapture(root:root) { _ in
                try createRestoredCopy(params:params,caller:caller,source:files,manifest:manifest,manifestSHA:digest,budget:budget)
            }
        } catch let error as DatabaseError {
            if let command = params["command_id"] as? String {throw storageOutcomeFailure(error,command:command)}
            throw error
        } catch let error as CoreError {throw error}
        catch {
            throw CoreError("RESTORE_INVALID_BACKUP","Restore could not verify or publish the complete backup. The existing store and backup are preserved.",details:["command_outcome":"rejected"])
        }
    }

    private func createRestoredCopy(params: JSON,caller: Caller,source: StorageObjectFiles,manifest: StorageSnapshotManifest,manifestSHA: String,budget: StorageSnapshotBudget) throws -> JSON {
        let command = try text(params,"command_id",max:100)
        guard UUID(uuidString:command) != nil else {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        let intent = hash(Data(("restore_create" + (try jsonString(params))).utf8))
        let key = try pendingStorageCommandKey(principal:caller.principal,command:command)
        let suffix = hash(Data((key + root.path).utf8)).prefix(32)
        let name = "restored-" + suffix, stageName = ".restore-staging-" + suffix
        let parentURL = root.appendingPathComponent("restore",isDirectory:true)
        let destination = parentURL.appendingPathComponent(name,isDirectory:true)
        let replay: JSON? = try ArchiveStorageGate.withExclusive(root:root) { _ in
            try dbQueue.write { db in
                try requirePendingCommandIntent(db,command:command,digest:intent,caller:caller)
                if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                    guard row["digest"] as String == intent else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID belongs to another intent.")}
                    let result = jsonObject(row["result"])
                    if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                    return result.merging(["replayed":true]) {_,new in new}
                }
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try jsonString(["kind":"restore_create","intent_digest":intent,"state":"pending"])])
                return nil
            }
        }
        if let replay {return replay}
        let (fd,_) = try StorageObjectFiles(root:root).parent("restore/.parent",create:true);Darwin.close(fd)
        let parent = try StorageObjectFiles(root:parentURL)
        let receiptName = "restore-receipt.json"
        let receipt: JSON
        if FileManager.default.fileExists(atPath:destination.path) {
            let existing = try StorageObjectFiles(root:destination).read(receiptName,maximum:16_384)
            receipt = try JSONSerialization.jsonObject(with:existing) as? JSON ?? [:]
            guard receipt["intent_digest"] as? String == intent,receipt["principal"] as? String == caller.principal,
                  receipt["manifest_sha256"] as? String == manifestSHA else {throw CoreError("RESTORE_TARGET_MISMATCH","The retained restore belongs to another original intent.")}
            try verifyRestoredPublication(destination,receipt:receipt,manifest:manifest,budget:budget)
            do {try parent.synchronizePublicationDirectory()}
            catch {throw CoreError("OUTCOME_UNKNOWN","Restore publication needs reconciliation with the original command.",details:["command_id":command,"command_outcome":"unknown"])}
        } else {
            // An interrupted unpublished attempt is retained for diagnosis. A
            // retry prepares a new complete candidate, never a partially used root.
            if FileManager.default.fileExists(atPath:parentURL.appendingPathComponent(stageName).path) {
                try parent.publish(stageName,as:".restore-incomplete-" + uuid())
            }
            let stage = try parent.makeDirectory(stageName, batchSynchronization: true)
            var databaseBudget = budget;databaseBudget.maximumObjectBytes = budget.maximumBytes
            _ = try source.copy("database.sqlite",to:stage,expected:manifest.databaseSHA256,budget:databaseBudget,targetPath:"checklist.sqlite")
            for object in manifest.objects {
                try budget.check()
                let descriptor = object.descriptor
                if descriptor.kind == "file" {
                    let copied = try source.copy("managed/" + descriptor.relativePath,to:stage,expected:object.sha256,budget:budget,targetPath:descriptor.relativePath,executable:descriptor.executable)
                    guard copied.1 == object.size else {throw StorageSnapshotFailure.sourceChanged}
                } else {
                    guard try source.linkTarget("managed/" + descriptor.relativePath) == descriptor.linkTarget,let target = descriptor.linkTarget else {throw StorageSnapshotFailure.sourceChanged}
                    try stage.writeLink(descriptor.relativePath,target:target)
                }
            }
            try stage.synchronizeCopiedDirectories(budget:budget)
            receipt = try fenceRestoredAuthority(stage:stage,params:params,caller:caller,manifest:manifest,manifestSHA:manifestSHA,intent:intent,budget:budget)
            try stage.writeNew(receiptName,bytes:Data((try jsonString(receipt)).utf8))
            try stage.synchronizeOwnedFile("checklist.sqlite")
            try budget.check()
            try budget.observe("restore_before_publish")
            do {try parent.publish(stageName,as:name) {try budget.observe("restore_published_before_flush")}}
            catch {throw CoreError("OUTCOME_UNKNOWN","Restore publication is uncertain. Preserve the original command and check its result before retrying.",details:["command_id":command,"command_outcome":"unknown"])}
        }
        let summary: JSON
        do {
            let files = try StorageObjectFiles(root:destination)
            let usage = try StorageCopyUsage.measure(files,paths:["checklist.sqlite",StoreIdentityReceipt.fileName,receiptName] + manifest.objects.map {$0.descriptor.relativePath},budget:budget)
            summary = ["kind":"restore_copy","operation_id":command,"path":destination.path,"source_root":manifest.sourceRoot,
                "store_id":manifest.storeID,"captured_at":manifest.capturedAt as Any? ?? NSNull(),"verified_at":now(),
                "manifest_sha256":manifestSHA,"verification":"copy_integrity_and_authority_fencing","native_startup_verified":false,"usage":usage]
        } catch {
            throw CoreError("OUTCOME_UNKNOWN","The restored copy was published but its usage receipt needs reconciliation. Preserve the original command.",details:["command_id":command,"command_outcome":"unknown"])
        }
        return try ArchiveStorageGate.withExclusive(root:root) { _ in
            try dbQueue.write { db in
                try requirePendingCommandIntent(db,command:command,digest:intent,caller:caller)
                if let raw = try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {return jsonObject(raw).merging(["replayed":true]) {_,new in new}}
                let data: JSON = ["path":destination.path,"status":"complete","manifest_sha256":manifestSHA,"store_incarnation":receipt["incarnation"]!,"existing_store_preserved":true,"dispatch":"quarantined"]
                let output: JSON = ["data":data,"command_id":command]
                try event(db,caller:caller,project:nil,entity:nil,kind:"restore_copy_created",data:data)
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,intent,try jsonString(output)])
                try recordStorageCopyObservation(db,key:"rehearsal",summary:summary)
                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key])
                return output
            }
        }
    }

    private func fenceRestoredAuthority(stage: StorageObjectFiles,params: JSON,caller: Caller,manifest: StorageSnapshotManifest,manifestSHA: String,intent: String,budget: StorageSnapshotBudget) throws -> JSON {
        var config = Configuration();config.prepareDatabase {db in try SchemaMigrations.installStorageCollation(db);try db.execute(sql:"PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON")}
        let copy = try DatabaseQueue(path:StorageBootstrap.writableURI(stage.root.appendingPathComponent("checklist.sqlite")),configuration:config)
        defer {try? copy.close()}
        let incarnation = uuid()
        let receipt: JSON = ["format":1,"state":"complete","command_id":params["command_id"]!,"principal":caller.principal,"intent_digest":intent,"manifest_sha256":manifestSHA,"source_store_id":manifest.storeID,"incarnation":incarnation,"restored_at":now(),"dispatch":"quarantined"]
        let identity = try copy.write {db -> StoreIdentityReceipt in
            guard case .current(let old) = try SchemaMigrations.inspect(db),old.logical_store_id == manifest.storeID,old.schema_revision == 3 else {throw StorageSnapshotFailure.incomplete}
            let identity = StoreIdentityReceipt(format_version:1,logical_store_id:old.logical_store_id,incarnation:incarnation,database_generation:1,schema_revision:3,state:"ready")
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='incarnation'",arguments:[incarnation])
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try identity.encoded(),as:UTF8.self)])
            try db.execute(sql:"DELETE FROM cursors")
            try db.execute(sql:"DELETE FROM metadata WHERE key='cursor_seal_key'")
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES ('restore_receipt',?)",arguments:[try jsonString(receipt)])
            let rows = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type IN ('session','attempt','task','delivery','group','handoff','delegation','task_session','recipient_target','ordinary_mention_plan')")
            // Update in place with canonical validation; stable IDs, revisions,
            // historical actors and all immutable evidence remain in this store.
            while let row = try rows.next() {
                try budget.check()
                try autoreleasepool {
                var value = try GRDBRecordEnvelopeAdapter.decode(row).object
                let type: String = row["type"]
                switch type {
                case "session":
                    value["state"] = "revoked";value["authorization_generation"] = uuid();value["grant_generation"] = uuid();value["restore_quarantined"] = true
                    value["assistant_grants"] = [:] as JSON
                    for key in ["native_endpoint","native_binding","execution_domain","token_hash"] {value.removeValue(forKey:key)}
                case "attempt" where value["state"] as? String == "active":
                    value["recovery_required"] = true;value["recovery_reason"] = "restored_store";value.removeValue(forKey:"token_hash")
                case "task" where value["active_attempt_id"] != nil || value["active_verification_request_id"] != nil:
                    value["recovery_required"] = true
                case "delivery" where !["acknowledged","addressed"].contains(value["state"] as? String ?? ""):
                    value["restore_prior_state"] = value["state"];value["state"] = "quarantined";value["push_state"] = "quarantined";value["restore_incarnation"] = incarnation
                case "group" where value["orchestration"] != nil:
                    value["restore_prior_orchestration"] = value.removeValue(forKey:"orchestration")
                case "handoff","delegation","recipient_target","ordinary_mention_plan","task_session":
                    value["restore_quarantined"] = true
                default:return
                }
                let envelope = try GRDBRecordEnvelopeAdapter.incoming(value,type:type)
                _ = try GRDBRecordEnvelopeAdapter.compareSave(incoming:envelope,previous:row)
                try db.execute(sql:"UPDATE records SET data=? WHERE id=CAST(? AS TEXT)",arguments:[try jsonString(value),Data((value["id"] as! String).utf8)])
                }
            }
            _ = try SchemaMigrations.inspect(db)
            return identity
        }
        try copy.read {db in
            guard try String.fetchOne(db,sql:"PRAGMA integrity_check") == "ok" else {throw StorageSnapshotFailure.incomplete}
            // Prove the relocated candidate's complete managed-file closure too.
            _ = try StorageSnapshotAuthority.inventory(db,root:stage.root,budget:budget,retainedExists:{try stage.regularOrLinkExists($0)})
        }
        try copy.close()
        try stage.writeNew(StoreIdentityReceipt.fileName,bytes:identity.encoded())
        var verified = receipt
        verified["database_sha256"] = try stage.digest("checklist.sqlite",budget:budget).0
        return verified
    }
    private func verifyRestoredPublication(_ destination: URL,receipt: JSON,manifest: StorageSnapshotManifest,budget: StorageSnapshotBudget) throws {
        let files = try StorageObjectFiles(root:destination)
        guard let sha = receipt["database_sha256"] as? String,
              try files.digest("checklist.sqlite",budget:budget).0 == sha else {throw StorageSnapshotFailure.sourceChanged}
        let identity = try StoreIdentityReceipt.decode(files.read(StoreIdentityReceipt.fileName,maximum:16_384))
        guard identity.incarnation == receipt["incarnation"] as? String,identity.logical_store_id == manifest.storeID else {throw StorageSnapshotFailure.incomplete}
        var expected: Set<String> = ["checklist.sqlite",StoreIdentityReceipt.fileName,"restore-receipt.json"]
        for object in manifest.objects {
            let path = object.descriptor.relativePath;expected.insert(path)
            if object.descriptor.kind == "file" {
                guard try files.digest(path,budget:budget) == (object.sha256,object.size) else {throw StorageSnapshotFailure.sourceChanged}
            } else {
                guard try files.linkTarget(path) == object.descriptor.linkTarget else {throw StorageSnapshotFailure.sourceChanged}
            }
        }
        guard try files.listedFiles(budget:budget) == expected else {throw StorageSnapshotFailure.incomplete}
    }

}
