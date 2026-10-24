import XCTest
import Foundation
import Security
import Darwin
import ChecklistIPC
import GRDB
import ChecklistBridges
import ChecklistProviders
@testable import ChecklistCore
@testable import ChecklistService

final class CallOverheadTests: XCTestCase {
    /// Opt-in measurements; reads signatures, never contacts the installed service.
    func testNativeSignatureBaseline() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_SIGNATURE_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in ten-call signature microbenchmark")
        }
        let cli = URL(fileURLWithPath: "/Applications/Checklist.app/Contents/MacOS/checklist")
        var processes: [pid_t] = [], pid = getpid()
        for _ in 0..<16 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd), bsd.pbi_uid == getuid() else { break }
            processes.append(pid)
            let parent = pid_t(bsd.pbi_ppid)
            if parent <= 1 || parent == pid { break }; pid = parent
        }
        for pid in processes { print("CL-262 ancestor pid=\(pid) identifier=\(Self.legacySigningInfo(pid)?[kSecCodeInfoIdentifier as String] ?? "unsigned")") }
        var times: [Double] = [], optimized: [Double] = []
        let cache = NativeCodeIdentity()
        for _ in 0..<10 {
            var start = ProcessInfo.processInfo.systemUptime
            XCTAssertNotNil(ClientBuildIdentity.executable(cli))
            for pid in processes { _ = Self.legacySigningInfo(pid) }
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            start = ProcessInfo.processInfo.systemUptime
            XCTAssertNotNil(cache.executable(cli))
            for pid in processes { _ = cache.signingInfo(pid) }
            optimized.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        print("CL-262 baseline signature_ms=\(times) median_ms=\(times.sorted()[5]) ancestry_count=\(processes.count) load=\(load)")
        print("CL-262 optimized signature_ms=\(optimized) median_ms=\(optimized.sorted()[5])")
    }

    /// Production read dispatch on an immutable backup database, never startup on it.
    func testReadOnlyBackupServiceCosts() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_OVERHEAD_READ_ONLY_DATABASE"],
              let pid = ProcessInfo.processInfo.environment["CHECKLIST_OVERHEAD_PROJECT_ID"] else {
            throw XCTSkip("Requires an explicitly selected private backup copy and its project ID")
        }
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root: fixture)
        defer { try? router.closeStore(); try? FileManager.default.removeItem(at: fixture) }
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0); CommandRouter.installTicketSearchFunctions($0) }
        let pool = try DatabasePool(path: path, configuration: configuration); defer { try? pool.close() }
        let owner = Caller(role: "owner", installation: "CL-262-read-only", projectIDs: [])
        let sessionsReply = try router.executePureRead(pool, method:"session_list", params:["project_id":pid], caller:owner)
        let sessions = try XCTUnwrap((sessionsReply["data"] as? [String:Any])?["sessions"] as? [[String:Any]])
        let session = try XCTUnwrap(sessions.first { $0["role"] as? String == "worker" && !["ended","revoked"].contains($0["state"] as? String ?? "") })
        let worker = Caller(role:"worker", installation:session["installation"] as? String ?? "benchmark", projectIDs:[pid], sessionID:session["id"] as? String, workspace:session["workspace"] as? String, executionDomain:session["execution_domain"] as? String)
        var load = [Double](repeating:0,count:3); getloadavg(&load,3)
        print("CL-262 read-only database=\(path) sessions=\(sessions.count) load=\(load)")
        var inspectionTimes: [Double] = []
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            for session in sessions {
                guard let provider = session["provider"] as? String, let sid = session["id"] as? String,
                    let plugin = ProviderPluginRegistry.bundled.plugin(provider,requiring:.registryClosure),
                    let domain = session["execution_domain"] as? String,
                    let parsed = NativeLifecycleRegistration(provider:provider,sessionID:sid,executionDomain:domain,registryPath:nil),
                    let path = plugin.nativeHost?.registryPath(processID:parsed.processID),
                    let registration = NativeLifecycleRegistration(provider:provider,sessionID:sid,executionDomain:domain,registryPath:path) else { continue }
                _ = NativeLifecycleInspector.inspect(registration)
            }
            inspectionTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        print("CL-262 lifecycle ms=\(inspectionTimes) median_ms=\(inspectionTimes.sorted()[5])")
        for (method,caller,params) in [("session_list",owner,["project_id":pid]),("tool_catalog",worker,[:]),("service_info",worker,[:]),("delivery_pending",Caller(role:"owner",installation:"native-bridge",projectIDs:[]),[:])] {
            var times: [Double] = [], sizes: [Int] = []
            for _ in 0..<10 {
                let start = ProcessInfo.processInfo.systemUptime
                let reply = try router.executePureRead(pool,method:method,params:params,caller:caller)
                sizes.append(try JSONSerialization.data(withJSONObject:reply,options:[.sortedKeys]).count)
                times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            print("CL-262 read-only method=\(method) ms=\(times) median_ms=\(times.sorted()[5]) bytes=\(sizes)")
        }
    }

    static func legacySigningInfo(_ pid: pid_t) -> [String: Any]? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}
