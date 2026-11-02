import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// Explicit owned-copy diagnostic; never selects the installed store or an app.
final class StorageBackupMemoryOwnedCopyTests: XCTestCase {
    func testP406BackupWithRetainedSnapshots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_P406_STORE"],let output = env["CHECKLIST_P406_OUTPUT"] else {
            throw XCTSkip("Requires an explicit P321g owned runtime with cloned older backups.")
        }
        let root = URL(fileURLWithPath:path).standardizedFileURL,snapshot = root.deletingLastPathComponent()
        let temporary = URL(fileURLWithPath:"/private/tmp").resolvingSymlinksInPath()
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(".p321g-owned-copy.json"))) as? JSON)
        let marked = URL(fileURLWithPath:try XCTUnwrap(marker["snapshot"] as? String)).resolvingSymlinksInPath()
        guard root.resolvingSymlinksInPath().pathComponents.starts(with:temporary.pathComponents),marker["purpose"] as? String == "P321g-real-maintenance-owned-copy",marked.pathComponents == snapshot.resolvingSymlinksInPath().pathComponents,
              ChecklistCore.hash(try Data(contentsOf:snapshot.appendingPathComponent("manifest.json"))) == marker["manifest_sha256"] as? String else {throw StorageSnapshotFailure.invalidFixture}
        let logURL = URL(fileURLWithPath:output + ".jsonl")
        FileManager.default.createFile(atPath:logURL.path,contents:nil)
        let log = try FileHandle(forWritingTo:logURL);defer {try? log.close()}
        let started = ProcessInfo.processInfo.systemUptime
        var sequence = 0
        func emit(_ value: JSON) {
            var value = value
            var load = [Double](repeating:0,count:3);_ = getloadavg(&load,3)
            value["load"] = load;value["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime-started
            if let bytes = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? log.write(contentsOf:bytes + Data([10]));try? log.synchronize()}
        }
        func measure(_ phase: String) {
            var info = task_vm_info_data_t(),count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to:&info) {$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
            XCTAssertEqual(status,KERN_SUCCESS)
            emit(["event":phase,"pid":getpid(),"phys_footprint_bytes":info.phys_footprint,"phys_footprint_peak_bytes":info.ledger_phys_footprint_peak,"resident_bytes":info.resident_size])
            let url = URL(fileURLWithPath:output + "." + String(sequence) + "." + phase + ".footprint.txt");sequence += 1
            FileManager.default.createFile(atPath:url.path,contents:nil)
            if let handle = try? FileHandle(forWritingTo:url) {
                defer {try? handle.close()}
                let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/footprint");process.arguments = ["-p",String(getpid())]
                process.standardOutput = handle;process.standardError = handle
                do {try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)} catch {XCTFail("footprint failed: \(error)")}
            }
        }
        measure("startup_begin")
        CommandRouter.qualificationStartupObserve = {measure($0)}
        StorageBackupManifestIndex.qualificationObserve = {measure($0)}
        StorageBackupUseLease.qualificationObserve = {measure($0)}
        defer {CommandRouter.qualificationStartupObserve = nil;StorageBackupManifestIndex.qualificationObserve = nil;StorageBackupUseLease.qualificationObserve = nil}
        let trash = root.appendingPathComponent("qualification-trash")
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root),automaticBackupRetentionTrashRoot:trash)
        defer {try? router.closeStore()}
        // Foundation enumerates /private/tmp while the anchored router uses
        // /tmp. Rebuild only each listed child's URL in the enumerated base.
        // Enumeration, lstat, managed-root admission, leases and hashes stay real.
        router.qualificationBackupPruneListedURL = {base,listed in base.appendingPathComponent(listed.lastPathComponent,isDirectory:true)}
        measure("startup_end")
        // Fixture-only: map existing receipt destinations to physical owned clones.
        // source_root/store/hash remain exact manifest bindings. No job, hold,
        // pin, upgrade protection, retention count or manifest is changed.
        let rebound = try router.dbQueue.write {db -> Int in
            let keys = try String.fetchAll(db,sql:"SELECT key FROM metadata WHERE key GLOB 'backup-generation:*'")
            var count = 0
            for key in keys {
                count += try autoreleasepool {
                guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]),var value = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON,
                      value["historical_catalog"] == nil,var summary = value["summary"] as? JSON,let old = summary["path"] as? String else {return 0}
                let selected = root.appendingPathComponent("backups/" + URL(fileURLWithPath:old).lastPathComponent)
                guard FileManager.default.fileExists(atPath:selected.appendingPathComponent("manifest.json").path) else {
                    // A snapshot captured before a later real prune can refer to
                    // an already absent folder. Keep its exact bytes under a
                    // fixture-only key; it cannot exercise physical accounting.
                    emit(["event":"fixture_unavailable_receipt","key":key,"sha256":ChecklistCore.hash(Data(raw.utf8)),"original_path":old])
                    try db.execute(sql:"UPDATE metadata SET key=? WHERE key=?",arguments:["p406-unavailable:" + key,key])
                    return 0
                }
                _ = try StorageBackupReceiptLocation.manifest(value,root:root)
                summary["path"] = selected.path;value["summary"] = summary
                try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(value),key]);return 1
                }
                measure("fixture_receipt_end")
            }
            return count
        }
        XCTAssertGreaterThanOrEqual(rebound,3)
        emit(["event":"fixture_setup","rebound_receipts":rebound,"confirmation":"Test-only owner command on owned router; original counts/pins/protection retained."])
        measure("fixture_end")
        let settings = try router.dbQueue.read {try router.backupRetentionSettings($0)}
        let policy = try StorageBackupRetentionPolicy.parse(settings)
        _ = try router.executeStorageBackupPruning(method:"backup_retention_set",params:["command_id":UUID().uuidString,"newest_count":policy.newestCount,"daily_days":policy.dailyDays],caller:Caller(role:"owner",installation:"p406-owned-test",projectIDs:[]))
        let confirmed = try router.dbQueue.read {try router.backupRetentionSettings($0)}
        XCTAssertTrue(try StorageAutomaticBackupRetention.isConfirmed(confirmed,root:root,incarnation:router.incarnation))
        measure("confirmed")
        try autoreleasepool {
            let preview = try router.backupPrunePreview()
            let entries = preview["snapshots"] as? [JSON] ?? []
            guard entries.count == 10,!entries.contains(where:{($0["keep_reasons"] as? [String] ?? []).contains("outside_managed_backups")}) else {throw CoreError("QUALIFICATION_ALIAS_MISMATCH","Every owned cloned folder must be observed once inside the managed root.") }
            emit(["event":"retention_preview","snapshot_count":preview["snapshot_count"]!,"prune_count":preview["prune_count"]!,"snapshots":entries])
            measure("retention_preview_end")
        }
        measure("retention_preview_drained")
        let cache = StorageBackupAccountingCache.shared(root:root)
        try autoreleasepool {
            let result = try router.dbQueue.read {db in try cache.index(db,root:root,incarnation:router.incarnation,read:{body in try router.dbQueue.read(body)})}
            XCTAssertNotNil(result)
        }
        XCTAssertTrue(cache.waitUntilIdle())
        measure("accounting_end")
        try autoreleasepool {
            let index = try router.dbQueue.read {router.observeTicketCleanupBackupRetentionIndex($0,objects:[])}
            XCTAssertNil(index.cleanupFailureReason)
        }
        measure("cleanup_index_end")
        var budget = StorageSnapshotBudget.production()
        budget.observe = {phase in if !["object_copied","object_verified","backup_step"].contains(phase) {measure("backup_" + phase)}}
        let result = try autoreleasepool {
            try router.executeStorageBackup(params:["command_id":UUID().uuidString,"path":root.appendingPathComponent("backups/snapshot-" + UUID().uuidString.lowercased()).path],caller:Caller(role:"owner",installation:"p406-owned-test",projectIDs:[]),budget:budget)
        }
        emit(["event":"backup_reply","reply":result])
        XCTAssertEqual((result["data"] as? JSON)?["status"] as? String,"complete")
        XCTAssertEqual((result["backup_retention"] as? JSON)?["status"] as? String,"complete")
        measure("backup_end")
        try router.closeStore()
        measure("store_closed")
    }
}
