import Foundation
import Darwin
import GRDB
@testable import ChecklistCore
@testable import StorageReleasedCoreFixture
import SQLite3

// Test-only executable. There is no default/live store path and no environment
// redirect: every invocation must name an owned, UUID-marked disposable root.
final class ReleasedTraceContext {
    let ready: URL
    var database: OpaquePointer?
    init(ready: URL) {self.ready = ready}
}
let args = CommandLine.arguments
func fail(_ code: Int32) -> Never { exit(code) }
guard args.count >= 4, let markerID = UUID(uuidString:args[2]) else { fail(64) }
let base = URL(fileURLWithPath:args[1],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
guard base.lastPathComponent == "CL19-storage-" + markerID.uuidString.lowercased(),
      let data = try? Data(contentsOf:base.appendingPathComponent("ownership.json")),
      let marker = try? JSONSerialization.jsonObject(with:data) as? [String:String],
      marker == ["fixture_id":markerID.uuidString.lowercased(),"purpose":"CL19-storage-failure"] else { fail(65) }
let mode = args[3], root = base.appendingPathComponent("store",isDirectory:true)
do {
    if mode == "backup-retention-held" {
        try StorageSnapshotRetention.withCapture(root:root) { _ in
            try Data(mode.utf8).write(to:base.appendingPathComponent("ready"))
            while true {pause()}
        }
        fail(3)
    }
    if mode == "recovery-refusal" {
        do {
            let lease = try StorageServiceLease(root:root)
            _ = try ChecklistCore.CommandRouter(root:root,serviceLease:lease);fail(4)
        } catch {
            let state = StorageRecoveryReply(error:error)
            let info = state.response(to:Data("{\"method\":\"service_info\"}".utf8))
            let denied = state.response(to:Data("{\"method\":\"project_create\",\"params\":{\"command_id\":\"not-an-authority\"}}".utf8))
            try info.write(to:base.appendingPathComponent("recovery-info.json"))
            try denied.write(to:base.appendingPathComponent("recovery-refusal.json"));exit(0)
        }
    }
    if mode == "migration-before-commit" || mode == "migration-committed" {
        let lease = try StorageServiceLease(root:root)
        _ = try StorageBootstrap.open(root:root,serviceLease:lease,observe:{ boundary in
            let selected: Bool
            switch boundary {
            case .upgradeBeforeCommit:selected = mode == "migration-before-commit"
            case .upgradeCommitted:selected = mode == "migration-committed"
            }
            if selected {
                try? Data(mode.utf8).write(to:base.appendingPathComponent("ready"))
                _ = Darwin.kill(getpid(),SIGKILL);_exit(99)
            }
        })
        fail(3)
    }
    if mode == "released-open" {
        _ = try StorageReleasedCoreFixture.CommandRouter(root:root);fail(2)
    }
    if mode == "released-create" {
        guard args.count >= 5,UUID(uuidString:args[4]) != nil,
              var params = try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("command.json"))) as? [String:Any] else { fail(67) }
        params["command_id"] = args[4]
        let old = try StorageReleasedCoreFixture.CommandRouter(root:root)
        let owner = StorageReleasedCoreFixture.Caller(role:"owner",installation:"storage-fixture",projectIDs:[])
        let result = try old.handle(method:"project_create",params:params,caller:owner)
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:base.appendingPathComponent("legacy-result.json"));exit(0)
    }
    if mode == "released-paused-unlink" {
        // Exact released native service lock precedes exact released Core. SQLite
        // trace observes its real final preview write, outside the semantic TX,
        // immediately before the unchanged old cleanup code calls removeItem.
        let fd = open(root.appendingPathComponent("service.lock").path,O_CREAT | O_RDWR,0o600)
        guard fd >= 0,flock(fd,LOCK_EX | LOCK_NB) == 0 else { fail(66) }
        let old = try StorageReleasedCoreFixture.CommandRouter(root:root)
        let caller = StorageReleasedCoreFixture.Caller(role:"owner",installation:"released-probe",projectIDs:[])
        func oldCall(_ method: String,_ input: [String:Any]) throws -> [String:Any] {
            var p = input;p["command_id"] = UUID().uuidString.lowercased()
            return try old.handle(method:method,params:p,caller:caller)["data"] as! [String:Any]
        }
        let project = try oldCall("project_create",["name":"Old unlink seam","key_prefix":"OU","root_path":base.appendingPathComponent("workspace").path])
        let task = try oldCall("task_create",["project_id":project["id"]!,"title":"Owned original"])
        let original = base.appendingPathComponent("old-original.bin")
        try Data(repeating:0x41,count:21 * 1024 * 1024).write(to:original)
        let attachment = try oldCall("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":original.path])
        try Data((attachment["path"] as! String).utf8).write(to:base.appendingPathComponent("paused-original-path"))
        let preview = try oldCall("attachment_cleanup_preview",["project_id":project["id"]!,"task_id":task["id"]!])
        let context = ReleasedTraceContext(ready:base.appendingPathComponent("ready"))
        try old.dbQueue.writeWithoutTransaction { db in
            context.database = db.sqliteConnection
            let rc = sqlite3_trace_v2(db.sqliteConnection,UInt32(SQLITE_TRACE_PROFILE),{ _, ptr, statement, _ in
                guard let ptr,let statement else {return 0}
                let value = Unmanaged<ReleasedTraceContext>.fromOpaque(ptr).takeUnretainedValue()
                guard sqlite3_get_autocommit(value.database) != 0,
                      let raw = sqlite3_expanded_sql(OpaquePointer(statement)) else {return 0}
                let sql = String(cString:raw);sqlite3_free(raw)
                if sql.hasPrefix("INSERT INTO records"),sql.contains("cleanup_preview") {
                    try? Data("released-final-preview-committed-before-unlink".utf8).write(to:value.ready)
                    raise(SIGSTOP)
                }
                return 0
            },Unmanaged.passUnretained(context).toOpaque())
            guard rc == SQLITE_OK else {throw NSError(domain:"OwnedTrace",code:Int(rc))}
        }
        _ = try oldCall("task_archive",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        // Reaching here means the intended trace seam was never observed.
        fail(3)
    }
    let lease = try StorageServiceLease(root:root)
    let router = try ChecklistCore.CommandRouter(root:root,serviceLease:lease)
    let owner = ChecklistCore.Caller(role:"owner",installation:"storage-fixture",projectIDs:[])
    guard args.count >= 5,let command = UUID(uuidString:args[4]) else { fail(67) }
    let input = try Data(contentsOf:base.appendingPathComponent("command.json"))
    guard var params = try JSONSerialization.jsonObject(with:input) as? [String:Any] else { fail(68) }
    params["command_id"] = command.uuidString.lowercased()
    if mode == "import-finalized" || mode == "import-commit" {
        try router.dbQueue.write { db in
            db.add(function:DatabaseFunction("storage_probe_kill",argumentCount:0,pure:false) { _ in
                _ = Darwin.kill(getpid(),SIGKILL);_exit(99)
            })
            if mode == "import-finalized" {
                try db.execute(sql:"CREATE TEMP TRIGGER crash_import_finalized AFTER UPDATE ON records WHEN NEW.type='storage_job' AND json_extract(NEW.data,'$.state')='finalized' BEGIN SELECT storage_probe_kill();END")
            } else {
                try db.execute(sql:"CREATE TEMP TRIGGER crash_import_receipt AFTER INSERT ON commands BEGIN SELECT storage_probe_kill();END")
            }
        }
        _ = try router.handle(method:"attachment_add",params:params,caller:owner)
        fail(3)
    }
    if mode == "note-committed" {
        _ = try router.handle(method:"message_send",params:params,caller:owner)
        try Data("committed-before-external-reply".utf8).write(to:base.appendingPathComponent("ready"))
        _ = Darwin.kill(getpid(),SIGKILL);fail(99)
    }
    fail(69)
} catch {
    if mode == "released-open" {
        // Old Core must refuse, not reach its first public command/mutation.
        try? Data(String(describing:type(of:error)).utf8).write(to:base.appendingPathComponent("old-refusal"));exit(0)
    }
    fputs("StorageCrashProbe failed before its selected boundary.\n",stderr);exit(70)
}
