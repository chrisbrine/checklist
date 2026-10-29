import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

/// Explicit integration qualification on a complete owned snapshot copy. No
/// installed-root default, Keychain, native app or fabricated migration ledger.
final class StorageUpgradeOwnedCopyTests: XCTestCase {
    func testProtectedPreupgradePathsOnOwnedCurrentSchemaCopy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CHECKLIST_P340_OWNED_COPY"],
              let outputPath = environment["CHECKLIST_P340_RESULT"] else {
            throw XCTSkip("Requires an explicit complete owned snapshot copy and evidence output.")
        }
        let checkout = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        guard root == checkout.deletingLastPathComponent().appendingPathComponent("cl340-owned-copy"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent("source-snapshot/manifest.json").path),
              !FileManager.default.fileExists(atPath:root.appendingPathComponent("restore-host").path) else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","Use a fresh cl340-owned-copy beside the assigned checkout, with source-snapshot only.")
        }
        let output = URL(fileURLWithPath:outputPath)
        var result: JSON = ["started_at":now(),"owned_root":root.path,
            "scope":"Supported restore, online preparation, verified reuse and fresh protected bootstrap snapshot on an owned current-schema real store; no native startup/migration claim",
            "schema_falsified":false,"load_start":load(),"production_deadline_seconds":StorageSnapshotBudget.productionSeconds]
        func save() throws {try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)}
        func measure(_ stage: String,_ body: () throws -> JSON) throws -> JSON {
            result["stage"] = stage;try save()
            let started = ProcessInfo.processInfo.systemUptime,startLoad = load()
            do {
                var value = try body()
                value["seconds"] = ProcessInfo.processInfo.systemUptime-started
                value["load_start"] = startLoad;value["load_end"] = load()
                result[stage] = value;try save();return value
            } catch {
                result[stage] = ["seconds":ProcessInfo.processInfo.systemUptime-started,"error":String(describing:error),"load_start":startLoad,"load_end":load()]
                result["completed"] = false;try save();throw error
            }
        }
        try save()
        let snapshot = root.appendingPathComponent("source-snapshot")
        let manifestBytes = try Data(contentsOf:snapshot.appendingPathComponent("manifest.json"))
        let original = try JSONDecoder().decode(StorageSnapshotManifest.self,from:manifestBytes)
        result["source_manifest_sha256"] = StorageObjectFiles.sha(manifestBytes)
        result["source_objects"] = original.objects.count
        result["source_object_bytes"] = original.objects.reduce(Int64(0)) {$0 + $1.size}
        XCTAssertGreaterThan(original.objects.reduce(original.databaseSize) {$0 + $1.size},8 * 1_073_741_824)
        try save()
        let hostRoot = root.appendingPathComponent("restore-host")
        let hostLease = try StorageServiceLease(root:hostRoot)
        let host = try CommandRouter(root:hostRoot,serviceLease:hostLease)
        defer {try? host.closeStore()}
        let owner = Caller(role:"owner",installation:"P340-owned-copy-qualification",projectIDs:[])
        let restored = try measure("supported_restore") {
            let reply = try host.executeStorageRestore(method:"restore_create",params:["path":snapshot.path,
                "manifest_sha256":StorageObjectFiles.sha(manifestBytes),"command_id":uuid()],caller:owner)
            return try XCTUnwrap(reply["data"] as? JSON)
        }
        try host.closeStore()
        let store = URL(fileURLWithPath:try XCTUnwrap(restored["path"] as? String),isDirectory:true)
        result["store_root"] = store.path;try save()
        let onlineBudget = StorageSnapshotBudget.production()
        let prepared = try measure("online_preparation") {
            let reply = try StorageUpgradePreparation.prepare(root:store,requiringUpgrade:false,qualificationBudget:onlineBudget)
            XCTAssertEqual(reply["prepared"] as? Bool,true)
            return reply.merging(["free_space_sample_bytes":onlineBudget.measurement.availableBytes as Any? ?? NSNull(),
                "measured_bytes":onlineBudget.measurement.bytes,"measured_objects":onlineBudget.measurement.objects]) {_,new in new}
        }
        let identity = try StoreIdentityReceipt.decode(Data(contentsOf:store.appendingPathComponent(StoreIdentityReceipt.fileName)))
        let lease = try StorageServiceLease(root:store)
        try lease.requireRoot(store)
        var configuration = Configuration()
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let queue = try DatabaseQueue(path:StorageBootstrap.writableURI(store.appendingPathComponent("checklist.sqlite")),configuration:configuration)
        defer {try? queue.close()}
        let reused = try measure("bootstrap_reuses_online_preparation") {
            try ArchiveStorageGate.withExclusive(root:store) {permit in
                try StorageBootstrap.prepareUpgrade(queue:queue,root:store,identity:identity,permit:permit)
            }
        }
        XCTAssertEqual(reused["path"] as? String,prepared["protected_backup"] as? String)
        XCTAssertEqual(reused["prepared_online"] as? Bool,true)
        // Only this owned copy's advisory receipt is removed. The source snapshot,
        // prepared generation and actual current-schema ledger remain untouched.
        try FileManager.default.removeItem(at:store.appendingPathComponent(StorageUpgradePreparation.receiptName))
        let freshBudget = StorageSnapshotBudget.production()
        let fresh = try measure("bootstrap_fresh_protected_snapshot") {
            var value = try ArchiveStorageGate.withExclusive(root:store) {permit in
                try StorageBootstrap.prepareUpgrade(queue:queue,root:store,identity:identity,permit:permit,qualificationBudget:freshBudget)
            }
            value["free_space_sample_bytes"] = freshBudget.measurement.availableBytes as Any? ?? NSNull()
            value["measured_bytes"] = freshBudget.measurement.bytes
            value["measured_objects"] = freshBudget.measurement.objects
            return value
        }
        XCTAssertNil(fresh["prepared_online"])
        XCTAssertNotEqual(fresh["path"] as? String,reused["path"] as? String)
        for (label,value) in [("online",reused),("fresh",fresh)] {
            _ = try measure(label + "_generation_observation") {
                let generation = URL(fileURLWithPath:try XCTUnwrap(value["path"] as? String),isDirectory:true)
                let bytes = try Data(contentsOf:generation.appendingPathComponent("manifest.json"))
                let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
                let digest = StorageObjectFiles.sha(bytes)
                XCTAssertEqual(digest,value["manifest_sha256"] as? String)
                var read = Configuration();read.readonly = true
                read.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
                let database = try DatabaseQueue(path:generation.appendingPathComponent("database.sqlite").path,configuration:read)
                defer {try? database.close()}
                let facts = try database.read {db -> JSON in
                    let quick = try String.fetchOne(db,sql:"PRAGMA quick_check")
                    XCTAssertEqual(quick,"ok")
                    return ["quick_check":quick as Any? ?? NSNull(),"record_families":try StorageSnapshot.recordFamilyCounts(db),"table_rows":try StorageSnapshot.tableCounts(db)]
                }
                return facts.merging(["published_generation":generation.path,"manifest_sha256":digest,
                    "object_count":manifest.objects.count,"object_bytes":manifest.objects.reduce(Int64(0)) {$0 + $1.size},
                    "database_bytes":manifest.databaseSize,"manifest_bytes":bytes.count,
                    "logical_bytes":manifest.objects.reduce(manifest.databaseSize + Int64(bytes.count) + Int64(try Data(contentsOf:generation.appendingPathComponent("intent.json")).count)) {$0 + $1.size},
                    "builder_verified_before_and_after_publication":true]) {_,new in new}
            }
        }
        for stage in ["online_preparation","bootstrap_fresh_protected_snapshot"] {
            let measurement = try XCTUnwrap(result[stage] as? JSON)
            XCTAssertLessThan(try XCTUnwrap(measurement["seconds"] as? Double),StorageSnapshotBudget.productionSeconds)
        }
        XCTAssertEqual(try queue.read {try String.fetchOne($0,sql:"PRAGMA quick_check")},"ok")
        StorageUpgradeProgress.clear(root:store)
        result["completed"] = true;result["stage"] = "complete";result["finished_at"] = now();result["load_end"] = load()
        try save()
        print("P340_PROTECTED_UPGRADE_QUALIFICATION " + output.path)
    }

    private func load() -> JSON {
        var averages = [Double](repeating:0,count:3)
        let count = getloadavg(&averages,3)
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        return ["load_average":count == 3 ? averages : [],"active_processors":ProcessInfo.processInfo.activeProcessorCount,
            "process_cpu_seconds":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000,
            "process_maxrss_bytes":usage.ru_maxrss]
    }
}
