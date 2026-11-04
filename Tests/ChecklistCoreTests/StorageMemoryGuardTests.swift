import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// CL-408 round memory guard. `script/memory_guard.py` runs each test in its own
/// `swift test` process: one builds a synthetic store, the next opens it (startup)
/// and makes one backup with confirmed automatic retention. The kernel lifetime
/// peak footprint of that second process covers only XCTest, startup and the
/// backup, so earlier tests cannot change it. Without the script's environment
/// both tests skip, so a shared default run never measures process-wide memory.
final class StorageMemoryGuardTests: XCTestCase {
    private static let marker = "CL408-memory-guard"
    private let owner = Caller(role:"owner",installation:"cl408-memory-guard",projectIDs:[])

    private struct Settings {
        let base: URL
        var store: URL {base.appendingPathComponent("store",isDirectory:true)}
        var trash: URL {base.appendingPathComponent("trash",isDirectory:true)}
        var workspace: URL {base.appendingPathComponent("workspace",isDirectory:true)}
        let report: URL
        let tasks: Int
        let briefBytes: Int
        let backups: Int
        let limitBytes: UInt64
        let selfTest: String?
    }

    private func settings() throws -> Settings {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_MEMORY_GUARD_ROOT"],let report = env["CHECKLIST_MEMORY_GUARD_REPORT"] else {
            throw XCTSkip("Runs only from script/memory_guard.py, each test in its own process.")
        }
        let base = URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
        // Owned fixture folders only: the script names each one; nothing else is opened or removed.
        guard base.lastPathComponent.hasPrefix(Self.marker + "-") else {throw CoreError("INVALID_INPUT","The memory guard root must be a script-owned CL408-memory-guard-* folder.")}
        func int(_ key: String,_ fallback: Int) -> Int {env[key].flatMap(Int.init) ?? fallback}
        let limit = try XCTUnwrap(env["CHECKLIST_MEMORY_GUARD_LIMIT_MIB"].flatMap(UInt64.init),"The script states the footprint limit.")
        return Settings(base:base,report:URL(fileURLWithPath:report),tasks:int("CHECKLIST_MEMORY_GUARD_TASKS",6_000),
                        briefBytes:int("CHECKLIST_MEMORY_GUARD_BRIEF_BYTES",8_000),backups:int("CHECKLIST_MEMORY_GUARD_BACKUPS",3),
                        limitBytes:limit * 1_048_576,selfTest:env["CHECKLIST_MEMORY_GUARD_SELF_TEST"].flatMap {$0.isEmpty ? nil : $0})
    }

    private static func footprint() -> (current: UInt64,peak: UInt64) {
        var info = task_vm_info_data_t(),count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to:&info) {$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
        guard status == KERN_SUCCESS else {return (0,0)}
        return (info.phys_footprint,UInt64(max(0,info.ledger_phys_footprint_peak)))
    }

    private func ownedRemove(_ s: Settings) {
        guard ProcessInfo.processInfo.environment["CHECKLIST_RETAIN_TEST_FIXTURES"] == nil,
              FileManager.default.fileExists(atPath:s.base.appendingPathComponent("ownership.json").path) else {return}
        try? FileManager.default.removeItem(at:s.base)
    }

    private func router(_ s: Settings) throws -> CommandRouter {
        try CommandRouter(root:s.store,serviceLease:StorageServiceLease(root:s.store),automaticBackupRetentionTrashRoot:s.trash)
    }

    /// Step 1 (own process): a synthetic store of realistic size, built through
    /// ordinary commands, with older backups and owner-confirmed retention.
    func testBuildSyntheticStore() throws {
        let s = try settings()
        guard !FileManager.default.fileExists(atPath:s.base.path) else {throw CoreError("INVALID_INPUT","The memory guard root already exists; the script chooses a new one.")}
        try FileManager.default.createDirectory(at:s.workspace,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.createDirectory(at:s.trash,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["purpose":Self.marker,"ticket":"CL-408"],options:.sortedKeys).write(to:s.base.appendingPathComponent("ownership.json"))
        var built = false
        defer {if !built {ownedRemove(s)}}
        let router = try router(s)
        defer {try? router.closeStore()}
        func call(_ method: String,_ params: JSON) throws -> JSON {
            var input = params;input["command_id"] = UUID().uuidString.lowercased()
            return try XCTUnwrap(router.handle(method:method,params:input,caller:owner)["data"] as? JSON,method)
        }
        let project = try call("project_create",["name":"Memory guard","key_prefix":"MG","root_path":s.workspace.path])
        let epic = try call("epic_create",["project_id":project["id"]!,"name":"Memory guard tickets"])
        let words = ["backup","manifest","startup","record","journal","retention","snapshot","footprint","ticket","review"]
        // A few tickets go through task_create; the rest are canonical clones of
        // them with their own IDs and titles. Each command costs about 0.5 s on a
        // growing store (3,000 commands took 26 minutes), so a round cannot build
        // the whole store through commands.
        let seeded = min(s.tasks,20)
        func brief(_ index: Int) -> String {
            var text = "Synthetic CL-408 ticket \(index). ",word = index
            while text.utf8.count < s.briefBytes {text += words[word % words.count] + " \(word) ";word = (word &* 31 &+ 7) & 0x7fff_ffff}
            return text
        }
        for index in 0..<seeded {
            try autoreleasepool {
                _ = try call("task_create",["project_id":project["id"]!,"epic_id":epic["id"]!,"title":"Memory guard \(index)","brief":brief(index)])
            }
        }
        try router.dbQueue.write {db in
            let seeds = try String.fetchAll(db,sql:"SELECT id FROM records WHERE type='task' ORDER BY rowid")
            guard !seeds.isEmpty || s.tasks == 0 else {throw CoreError("INVALID_INPUT","No seed ticket exists.")}
            for index in seeded..<max(seeded,s.tasks) {
                let id = UUID().uuidString.lowercased()
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) SELECT ?,project_id,type,revision,json_set(data,'$.id',?,'$.title',?,'$.brief',?) FROM records WHERE id=?",
                               arguments:[id,id,"Memory guard \(index)",brief(index),seeds[index % seeds.count]])
            }
        }
        let backups = s.store.appendingPathComponent("backups",isDirectory:true)
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        for index in 0..<s.backups {
            _ = try call("backup_create",["path":backups.appendingPathComponent("snapshot-guard-\(index)").path])
        }
        // Keep every snapshot (no move to Trash); each later backup still hashes every retained manifest.
        _ = try router.executeStorageBackupPruning(method:"backup_retention_set",params:["command_id":UUID().uuidString.lowercased(),"newest_count":s.backups + 2,"daily_days":0],caller:owner,trashRoot:s.trash)
        try router.closeStore()
        built = true
    }

    /// Step 2 (own process): startup plus one backup with automatic retention.
    func testStartupAndBackupStayBounded() throws {
        let s = try settings()
        guard FileManager.default.fileExists(atPath:s.base.appendingPathComponent("ownership.json").path) else {throw CoreError("INVALID_INPUT","Run testBuildSyntheticStore first in its own process.")}
        defer {ownedRemove(s)}
        let begin = Self.footprint()
        let lock = NSLock()
        var events: [JSON] = []
        StorageMemoryGuardSeam.observe = {event,subject,count in lock.lock();events.append(["event":event,"subject":subject,"count":count]);lock.unlock()}
        defer {StorageMemoryGuardSeam.observe = nil}
        let started = ProcessInfo.processInfo.systemUptime
        let router = try router(s)
        defer {try? router.closeStore()}
        let startupSeconds = ProcessInfo.processInfo.systemUptime - started
        let afterStartup = Self.footprint()
        // Self-tests prove that the guard fails on each regression kind.
        var held: [Any] = []
        if s.selfTest == "whole_store_json" {
            // No seam report: only the footprint limit can catch this one.
            try router.dbQueue.read {db in
                let rows = try Row.fetchCursor(db,sql:"SELECT data FROM records")
                while let row = try rows.next() {let data: Data = row["data"];held.append(try JSONSerialization.jsonObject(with:data))}
            }
        } else if s.selfTest == "whole_manifest" {
            let older = s.store.appendingPathComponent("backups/snapshot-guard-0",isDirectory:true)
            held.append(try StorageObjectFiles(root:older).read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        } else if let mode = s.selfTest {throw CoreError("INVALID_INPUT","Unknown self-test " + mode)}
        let destination = s.store.appendingPathComponent("backups/snapshot-measure-" + UUID().uuidString.lowercased(),isDirectory:true)
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let staged = Set((try? FileManager.default.contentsOfDirectory(atPath:parent.path)) ?? []).filter {$0.hasPrefix(".snapshot-staging-")}
        let backupStarted = ProcessInfo.processInfo.systemUptime
        let result = try router.executeStorageBackup(params:["command_id":UUID().uuidString.lowercased(),"path":destination.path],caller:owner,budget:StorageSnapshotBudget.production())
        let backupSeconds = ProcessInfo.processInfo.systemUptime - backupStarted
        let heldCount = held.count;held.removeAll()
        try router.closeStore()
        let end = Self.footprint()
        StorageMemoryGuardSeam.observe = nil
        // Allowed whole manifest reads: the new backup's own manifest, in its
        // destination or in the staging folder that this backup created.
        let own = destination.resolvingSymlinksInPath().path
        let violations = events.filter {event in
            if event["event"] as? String == "whole_manifest_read" {
                let folder = URL(fileURLWithPath:event["subject"] as? String ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
                let name = folder.lastPathComponent
                let newStaging = folder.deletingLastPathComponent().path == parent.path && name.hasPrefix(".snapshot-staging-") && !staged.contains(name)
                return !(folder.path == own || newStaging)
            }
            return true
        }
        var failures: [String] = []
        if !violations.isEmpty {failures.append("structural")}
        if end.peak > s.limitBytes {failures.append("footprint")}
        let backupStatus = (result["data"] as? JSON)?["status"] as? String,retentionStatus = (result["backup_retention"] as? JSON)?["status"] as? String
        var load = [Double](repeating:0,count:3);_ = getloadavg(&load,3)
        let mib = {(value: UInt64) -> Double in (Double(value) / 1_048_576 * 10).rounded() / 10}
        let report: JSON = ["ticket":"CL-408","pid":Int(getpid()),"self_test":s.selfTest ?? NSNull(),"tasks":s.tasks,"brief_bytes":s.briefBytes,"older_backups":s.backups,
            "database_bytes":(try? FileManager.default.attributesOfItem(atPath:s.store.appendingPathComponent("checklist.sqlite").path)[.size] as? NSNumber)?.intValue ?? NSNull(),
            "limit_mib":mib(s.limitBytes),"footprint_begin_mib":mib(begin.current),"footprint_after_startup_mib":mib(afterStartup.current),
            "footprint_end_mib":mib(end.current),"peak_footprint_mib":mib(end.peak),"startup_seconds":startupSeconds,"backup_seconds":backupSeconds,
            "backup_status":backupStatus ?? NSNull(),"retention_status":retentionStatus ?? NSNull(),"self_test_held_items":heldCount,
            "manifest_reads":events.filter {$0["event"] as? String == "whole_manifest_read"}.count,"violations":violations,"failures":failures,"load":load]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:s.report)
        XCTAssertEqual(backupStatus,"complete")
        XCTAssertEqual(retentionStatus,"complete")
        XCTAssertTrue(violations.isEmpty,"Startup or backup kept whole-store records or read another manifest whole: \(violations)")
        XCTAssertLessThanOrEqual(end.peak,s.limitBytes,"Peak footprint \(mib(end.peak)) MiB is over the stated \(mib(s.limitBytes)) MiB limit.")
    }
}
