import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// Opt-in bounded experiment on an explicitly supplied owned copy, never a default store.
final class ImportStoreCopyQualificationTests: XCTestCase {
    func testOwnedCopyStartupPreviewAndThreeMinuteTraffic() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_IMPORT_QUALIFICATION_ROOT"],let output = env["CHECKLIST_IMPORT_QUALIFICATION_OUTPUT"] else {throw XCTSkip("Select an owned ws2/store-copies root and evidence output explicitly.")}
        let root = URL(fileURLWithPath:path).standardizedFileURL
        guard root.path.contains("/ws2/store-copies/") else {throw CoreError("QUALIFICATION_REFUSED","Use only the assigned private copy.")}
        let owner = Caller(role:"owner",installation:"CL21-owned-copy",projectIDs:[])
        let start = ProcessInfo.processInfo.systemUptime
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router.closeStore()}
        var result: JSON = ["startup_seconds":ProcessInfo.processInfo.systemUptime-start,"root":root.path]
        let target = try router.dbQueue.read {db in try Row.fetchOne(db,sql:"SELECT id,project_id FROM records WHERE type='task' LIMIT 1")!}
        let tid: String = target["id"],pid: String = target["project_id"]
        let source = root.deletingLastPathComponent().appendingPathComponent("synthetic-import")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("{\"format\":\"synthetic-board/1\",\"meta\":{\"exported_at\":\"2026-01-02T12:00:00Z\"},\"items\":[{\"id\":\"DEMO-1\",\"title\":\"Synthetic preview\",\"state\":\"parked\"}],\"events\":[]}".utf8).write(to:source.appendingPathComponent("bundle.json"))
        let previewStart = ProcessInfo.processInfo.systemUptime
        do {_ = try router.handle(method:"import_preview",params:["project_id":pid,"path":source.path,"source_format":"synthetic-board/1","source_namespace":"synthetic-qualification","command_id":UUID().uuidString],caller:owner);result["preview_supported"] = true}
        catch let e as CoreError where ["UNSUPPORTED_METHOD","FORBIDDEN"].contains(e.code) {result["preview_supported"] = false;result["preview_code"] = e.code}
        result["preview_seconds"] = ProcessInfo.processInfo.systemUptime-previewStart
        func sample() -> JSON {
            var vm = task_vm_info_data_t(),count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
            let rc = withUnsafeMutablePointer(to:&vm) {p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
            var u = rusage();getrusage(RUSAGE_SELF,&u)
            return ["time":ProcessInfo.processInfo.systemUptime,"phys_footprint":rc == KERN_SUCCESS ? vm.phys_footprint : 0,"cpu_seconds":Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1_000_000]
        }
        let lock = NSLock(),group = DispatchGroup(),origin = ProcessInfo.processInfo.systemUptime
        var calls: [JSON] = [],samples: [JSON] = [sample()],failures: [String] = []
        for lane in 0..<4 {
            group.enter();DispatchQueue.global().async {
                defer {group.leave()}
                for index in 0..<90 {
                    let due = origin + Double(index*2),delay = due-ProcessInfo.processInfo.systemUptime
                    if delay > 0 {Thread.sleep(forTimeInterval:delay)}
                    let before = sample(),method = lane == 3 ? "task_get" : "message_send"
                    do {
                        var p: JSON = ["project_id":pid,"task_id":tid]
                        if lane != 3 {p["command_id"] = UUID().uuidString;p["body"] = "CL-21 owned-copy synthetic traffic lane \(lane) sequence \(index)";p["kind"] = "note"}
                        _ = try router.handle(method:method,params:p,caller:owner)
                        let after = sample()
                        lock.lock();calls.append(["lane":lane,"index":index,"wall_seconds":(after["time"] as! Double)-(before["time"] as! Double),"process_cpu_interval_seconds":(after["cpu_seconds"] as! Double)-(before["cpu_seconds"] as! Double)]);lock.unlock()
                    } catch {lock.lock();failures.append(String(describing:error));lock.unlock();return}
                }
            }
        }
        for index in 1...18 {let delay = origin+Double(index*10)-ProcessInfo.processInfo.systemUptime;if delay>0 {Thread.sleep(forTimeInterval:delay)};samples.append(sample())}
        group.wait();result["calls"] = calls;result["samples"] = samples;result["failures"] = failures;result["duration_seconds"] = ProcessInfo.processInfo.systemUptime-origin
        result["cpu_per_completed_call"] = ((samples.last!["cpu_seconds"] as! Double)-(samples.first!["cpu_seconds"] as! Double))/Double(max(1,calls.count))
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:output))
        XCTAssertEqual(calls.count,360);XCTAssertTrue(failures.isEmpty)
    }
}
