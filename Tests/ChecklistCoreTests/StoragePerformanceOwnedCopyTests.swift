import XCTest
import Foundation
import Darwin
@testable import ChecklistCore

/// Explicit read-only qualification of an owned live-size snapshot. No app,
/// slot, keychain or default production path is opened.
final class StoragePerformanceOwnedCopyTests: XCTestCase {
    private final class DescriptorBaseline {
        var padding: [Int32] = []
        let before: Int
        static func count() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0) } }
        init() throws {
            before = Self.count()
            while Self.count() < 98 {
                let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { throw StorageSnapshotFailure.io }
                padding.append(fd)
            }
        }
        deinit { for fd in padding { Darwin.close(fd) } }
    }
    func testIndependentVerificationOnOwnedSnapshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHECKLIST_P356_MODE"] != "backup" else { throw XCTSkip("Backup-only qualification.") }
        guard let path = env["CHECKLIST_P356_SNAPSHOT"], let output = env["CHECKLIST_P356_OUTPUT"] else { throw XCTSkip("An explicit owned snapshot and result path are required.") }
        let root = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        let owned = URL(fileURLWithPath:env["CHECKLIST_P356_OWNED_ROOT"] ?? path,isDirectory:true).resolvingSymlinksInPath()
        guard root.pathComponents.starts(with:URL(fileURLWithPath:"/private/tmp",isDirectory:true).resolvingSymlinksInPath().pathComponents),root.pathComponents.starts(with:owned.pathComponents),FileManager.default.fileExists(atPath:owned.appendingPathComponent("owner.json").path) else { throw StorageSnapshotFailure.invalidFixture }
        var limit = rlimit();XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&limit),0);XCTAssertEqual(limit.rlim_cur,256)
        let descriptorBaseline = try DescriptorBaseline();defer { withExtendedLifetime(descriptorBaseline) {} }
        func load() -> [Double] { var result = [Double](repeating:0,count:3);_ = getloadavg(&result,3);return result }
        let started = ProcessInfo.processInfo.systemUptime,startLoad = load()
        var events: [[String:Any]] = []
        var budget = StorageSnapshotBudget.production()
        budget.observe = { phase in if phase != "object_verified" { events.append(["phase":phase,"elapsed_seconds":ProcessInfo.processInfo.systemUptime-started,"load":load()]) } }
        let files = try StorageObjectFiles(root:root)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:budget.maximumManifestBytes))
        var result: [String:Any] = ["snapshot":root.path,"nofile_soft":limit.rlim_cur,"nofile_hard":limit.rlim_max,"descriptor_baseline_before":descriptorBaseline.before,"descriptor_baseline_padded":DescriptorBaseline.count(),"objects":manifest.objects.count,"database_bytes":manifest.databaseSize,"object_bytes":manifest.objects.reduce(Int64(0)) {$0 + $1.size},"load_start":startLoad]
        do {
            let sha = try StorageSnapshot.verify(files,operation:XCTUnwrap(UUID(uuidString:manifest.operationID)),budget:budget)
            result["manifest_sha256"] = sha;result["verified"] = true
        } catch { result["error"] = String(describing:error);result["verified"] = false }
        result["seconds"] = ProcessInfo.processInfo.systemUptime-started;result["load_end"] = load();result["events"] = events
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
        XCTAssertEqual(result["verified"] as? Bool,true)
        if env["CHECKLIST_P356_EXPECT_FAST"] == "1" { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,300) }
    }
    func testProtectedSnapshotCopyOnOwnedUnmigratedStore() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHECKLIST_P356_MODE"] == "backup",let path = env["CHECKLIST_P356_STORE"],let output = env["CHECKLIST_P356_OUTPUT"] else { throw XCTSkip("Requires explicit backup-mode owned runtime and output.") }
        let root = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        let owned = URL(fileURLWithPath:try XCTUnwrap(env["CHECKLIST_P356_OWNED_ROOT"]),isDirectory:true).resolvingSymlinksInPath()
        guard root.pathComponents.starts(with:owned.pathComponents),FileManager.default.fileExists(atPath:root.appendingPathComponent("owner.json").path),FileManager.default.fileExists(atPath:owned.appendingPathComponent("manifest.json").path) else { throw StorageSnapshotFailure.invalidFixture }
        var limit = rlimit();XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&limit),0);XCTAssertEqual(limit.rlim_cur,256)
        let descriptorBaseline = try DescriptorBaseline();defer { withExtendedLifetime(descriptorBaseline) {} }
        let service = try StorageServiceLease(root:root);defer {withExtendedLifetime(service) {}}
        let identity = try StoreIdentityReceipt.decode(Data(contentsOf:root.appendingPathComponent(StoreIdentityReceipt.fileName)))
        let parent = root.appendingPathComponent("backups"),operation = UUID()
        func load() -> [Double] { var result = [Double](repeating:0,count:3);_ = getloadavg(&result,3);return result }
        let started = ProcessInfo.processInfo.systemUptime,startLoad = load()
        var events: [[String:Any]] = []
        var budget = StorageSnapshotBudget.production()
        budget.observe = { phase in
            if phase != "object_copied" && phase != "object_verified" && phase != "backup_step" { events.append(["phase":phase,"elapsed_seconds":ProcessInfo.processInfo.systemUptime-started,"load":load()]) }
        }
        var result: [String:Any] = ["runtime":root.path,"operation_id":operation.uuidString.lowercased(),"nofile_soft":limit.rlim_cur,"nofile_hard":limit.rlim_max,"descriptor_baseline_before":descriptorBaseline.before,"descriptor_baseline_padded":DescriptorBaseline.count(),"production_deadline_seconds":StorageSnapshotBudget.productionSeconds,"load_start":startLoad,"scope":"Exact protected snapshot builder on owned schema4 runtime; full bootstrap/rehearsal/migration blocked by absent private historical manifests."]
        do {
            let receipt = try ArchiveStorageGate.withExclusive(root:root) { permit in
                try StorageSnapshot.build(StorageSnapshotSource(source:root,parent:parent,storeID:identity.logical_store_id,permit:permit),operation:operation,budget:budget)
            }
            let destination = parent.appendingPathComponent(StorageSnapshot.names(operation).published)
            let bytes = try Data(contentsOf:destination.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
            result["verified"] = true;result["path"] = destination.path;result["manifest_sha256"] = receipt.manifestSHA256
            result["objects"] = manifest.objects.count;result["database_bytes"] = manifest.databaseSize;result["object_bytes"] = manifest.objects.reduce(Int64(0)) {$0 + $1.size}
        } catch { result["verified"] = false;result["error"] = String(describing:budget.reporting(error)) }
        result["seconds"] = ProcessInfo.processInfo.systemUptime-started;result["load_end"] = load();result["events"] = events;result["writer_lease_seconds"] = budget.measurement.writerLeaseSeconds
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
        XCTAssertEqual(result["verified"] as? Bool,true)
        XCTAssertLessThan(budget.measurement.writerLeaseSeconds,8)
        XCTAssertLessThan(try XCTUnwrap(result["seconds"] as? Double),300)
    }

}
