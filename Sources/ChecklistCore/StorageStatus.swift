import Foundation
import GRDB
import Darwin

/// A file-allocation observation, not a claim about exclusive blocks or space
/// recovered by deleting a pathname. APFS extents may be shared across inodes.
enum StorageCopyUsage {
    static func measure(_ files: StorageObjectFiles, paths: [String], budget: StorageSnapshotBudget) throws -> JSON {
        let files = try StorageObjectFiles(copying:files)
        var logical: Int64 = 0, allocated: Int64 = 0, inodes = Set<String>()
        for path in paths.sorted() {
            try budget.check()
            let (parent,name) = try files.parent(path)
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) == 0,
                  [S_IFREG,S_IFLNK].contains(info.st_mode & S_IFMT),info.st_size >= 0,info.st_blocks >= 0 else {throw StorageSnapshotFailure.io}
            logical = try budget.adding(Int64(info.st_size),to:logical)
            if inodes.insert("\(info.st_dev):\(info.st_ino)").inserted {
                let bytes = Int64(info.st_blocks).multipliedReportingOverflow(by:512)
                let sum = allocated.addingReportingOverflow(bytes.partialValue)
                guard !bytes.overflow,!sum.overflow else {throw StorageSnapshotFailure.limit}
                allocated = sum.partialValue
            }
        }
        try files.finishWalk()
        return ["logical_bytes":logical,"allocated_file_bytes":allocated,"file_count":paths.count,
                "measured_at":now(),"scope":"verified_copy_files_excluding_directories",
                "exclusive_physical_bytes":NSNull(),"physical_reclaimable_bytes":NSNull(),
                "shared_extents":"not_deduplicated","availability":"not_rechecked"]
    }
}

extension CommandRouter {
    func storageStatus(_ db: Database,caller: Caller) throws -> JSON {
        try owner(caller)
        // Stream validated envelopes rather than retaining every attachment body.
        var originals: Int64 = 0
        let attachments = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='attachment'")
        while let row = try attachments.next() {
            try autoreleasepool {
                let value = try GRDBRecordEnvelopeAdapter.decode(row).object
                if value["mode"] as? String == "managed",value["availability"] as? String == "available" {
                    let sum = originals.addingReportingOverflow(Int64(int(value,"size")))
                    guard !sum.overflow else {throw StoreRecovery.required("storage_usage_receipt_invalid")}
                    originals = sum.partialValue
                }
            }
        }
        func summary(_ key: String) throws -> Any {
            if let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) {return jsonObject(raw)}
            if key == "storage-last-verified-backup" {
                // CL-343: newest receipt first, one row per check; never json_valid over every receipt.
                // Receipts are only inserted, so rowid order is their recording order.
                for rowid in try Int64.fetchAll(db,sql:"SELECT rowid FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY rowid DESC") {
                    if let raw = try String.fetchOne(db,sql:"SELECT json_object('kind','backup','operation_id',json_extract(value,'$.operation_id'),'verified_at',json_extract(value,'$.known_at'),'manifest_sha256',json_extract(value,'$.manifest_sha256'),'usage',NULL,'verification','legacy_complete_receipt') FROM metadata WHERE rowid=? AND key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete'",arguments:[rowid]) {return jsonObject(raw)}
                }
            }
            if key == "storage-last-verified-rehearsal",let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'") {
                let legacy = jsonObject(raw)
                if bool(legacy,"protected") {return ["kind":"preupgrade_database_migration","path":legacy["path"] ?? NSNull(),"manifest_sha256":legacy["manifest_sha256"] ?? NSNull(),"verification":"migration_rehearsal_committed","verified_at":NSNull(),"usage":NSNull()] as JSON}
            }
            return NSNull()
        }
        var logical: Int64 = 0, allocated: Int64 = 0, observed = 0
        let rows = try Row.fetchCursor(db,sql:"SELECT value FROM metadata WHERE key GLOB 'storage-copy-usage:*'")
        while let row = try rows.next() {
            let value = jsonObject(row["value"])
            guard let bytes = value["logical_bytes"] as? NSNumber,let blocks = value["allocated_file_bytes"] as? NSNumber,
                  bytes.int64Value >= 0,blocks.int64Value >= 0 else {throw StoreRecovery.required("storage_usage_receipt_invalid")}
            let l = logical.addingReportingOverflow(bytes.int64Value),a = allocated.addingReportingOverflow(blocks.int64Value)
            guard !l.overflow,!a.overflow else {throw StoreRecovery.required("storage_usage_receipt_invalid")}
            logical = l.partialValue;allocated = a.partialValue;observed += 1
        }
        let backups = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'") ?? 0
        let measuredBackups = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'storage-copy-usage:backup:*'") ?? 0
        let usage: JSON = ["observed_copy_count":observed,"unmeasured_backup_count":max(0,backups-measuredBackups),
            "logical_bytes_at_verification":observed == 0 ? NSNull() : logical as Any,
            "allocated_file_bytes_at_verification":observed == 0 ? NSNull() : allocated as Any,
            "exclusive_physical_bytes":NSNull(),"physical_reclaimable_bytes":NSNull(),
            "scope":"recorded_backup_and_restore_copies_excluding_staging_and_unrecorded_copies",
            "availability":"not_rechecked","shared_extents":"not_deduplicated_across_copies"]
        return ["database_path":root.appendingPathComponent("checklist.sqlite").path,"managed_bytes":originals,
                "managed_bytes_scope":"available_original_attachment_records_logical_lengths",
                "cleanup_enabled":true,"restore_supported":true,
                "last_verified_backup":try summary("storage-last-verified-backup"),
                "last_verified_rehearsal":try summary("storage-last-verified-rehearsal"),"retained_usage":usage]
    }
    func recordStorageCopyObservation(_ db: Database,key: String,summary: JSON) throws {
        let record = StoredRecord(summary,family:"storage_copy_observation")
        let operationID = try record.string("operation_id")
        let usage = try record.object("usage")
        let sql = "INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        try db.execute(sql:sql,arguments:["storage-last-verified-" + key,try jsonString(summary)])
        let kind = key == "backup" ? "backup" : "restore"
        try db.execute(sql:sql,arguments:["storage-copy-usage:" + kind + ":" + operationID,try jsonString(usage)])
    }
}
