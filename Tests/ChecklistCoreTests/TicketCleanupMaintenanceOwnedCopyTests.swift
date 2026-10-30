import XCTest
import Foundation
import Darwin
import GRDB
import CryptoKit
@testable import ChecklistCore

/// Opt-in, bounded maintenance qualification. The immutable copied snapshot is
/// proof; only its separately cloned runtime is opened as a CommandRouter.
final class TicketCleanupMaintenanceOwnedCopyTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        let file: FileHandle
        var readSeconds: [Double] = []
        var readErrors: [String] = []
        var running = true
        init(_ url: URL) throws {
            FileManager.default.createFile(atPath:url.path,contents:nil)
            file = try FileHandle(forWritingTo:url)
        }
        deinit {try? file.close()}
        func emit(_ value: JSON) {
            lock.lock();defer {lock.unlock()}
            var value = value
            value["uptime"] = ProcessInfo.processInfo.systemUptime
            var loads = [Double](repeating:0,count:3);_ = getloadavg(&loads,3)
            value["load"] = loads
            var usage = rusage();_ = getrusage(RUSAGE_SELF,&usage)
            value["process_max_resident_bytes"] = usage.ru_maxrss
            if let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]) {try? file.write(contentsOf:data + Data([10]));try? file.synchronize()}
        }
        func active() -> Bool {lock.lock();defer {lock.unlock()};return running}
        func stop() {lock.lock();running = false;lock.unlock()}
        func recordRead(seconds: Double,error: String? = nil) {
            lock.lock();readSeconds.append(seconds);if let error {readErrors.append(error)};lock.unlock()
            emit(["event":"concurrent_task_get","seconds":seconds,"error":error as Any? ?? NSNull()])
        }
        func readSummary() -> JSON {
            lock.lock();defer {lock.unlock()}
            let sorted = readSeconds.sorted()
            return ["count":sorted.count,"median_seconds":sorted.isEmpty ? 0 : sorted[sorted.count/2],"max_seconds":sorted.max() ?? 0,"errors":readErrors]
        }
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) {$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private func digest(_ url: URL) throws -> (String,Int64) {
        let handle = try FileHandle(forReadingFrom:url);defer {try? handle.close()}
        var hasher = SHA256(),size: Int64 = 0
        while let bytes = try handle.read(upToCount:1024*1024),!bytes.isEmpty {size += Int64(bytes.count);hasher.update(data:bytes)}
        return (hasher.finalize().map {String(format:"%02x",$0)}.joined(),size)
    }
    private func save(_ value: JSON,_ url: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)
    }
    private func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path,&info) == 0
    }
    private func jobs(_ router: CommandRouter) throws -> [JSON] {
        try router.readForPreparation {db in
            try Row.fetchAll(db,sql:"SELECT id,revision,json_extract(data,'$.task_id') task,json_extract(data,'$.cause') cause,json_extract(data,'$.state') state,json_extract(data,'$.summary') summary FROM records WHERE type='storage_job' AND json_extract(data,'$.kind')='ticket_object_delete' AND json_extract(data,'$.cause')!='ticket_cleanup_pass' ORDER BY rowid").map {row in
                ["id":row["id"] as String,"revision":row["revision"] as Int64,"task_id":row["task"] as String? ?? "","cause":row["cause"] as String? ?? "","state":row["state"] as String? ?? "","summary":jsonObject(row["summary"] as String? ?? "{}")]
            }
        }
    }
    private func backupReceiptInventory(_ router: CommandRouter) throws -> [JSON] {
        try router.readForPreparation {db in
            var result: [JSON] = []
            let rows = try Row.fetchCursor(db,sql:"SELECT key,CAST(value AS BLOB) AS payload,length(CAST(value AS BLOB)) AS bytes,json_array_length(value,'$.objects') AS objects,json_extract(value,'$.state') AS state,json_extract(value,'$.summary.path') AS path FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")
            while let row = try rows.next() {
                autoreleasepool {
                    let payload: Data = row["payload"]
                    result.append(["key":row["key"] as String,"sha256":ChecklistCore.hash(payload),"bytes":row["bytes"] as Int64,"objects":row["objects"] as Int64? ?? 0,"state":row["state"] as String? ?? "","path":row["path"] as String? ?? ""])
                }
            }
            return result
        }
    }
    private func removed(_ router: CommandRouter) throws -> [String:JSON] {
        try router.readForPreparation {db in
            var result: [String:JSON] = [:]
            let rows = try Row.fetchCursor(db,sql:"SELECT r.id,j.value FROM records r,json_each(r.data,'$.objects') j WHERE r.type='storage_job' AND json_extract(r.data,'$.kind')='ticket_object_delete' AND json_extract(j.value,'$.state')='removed'")
            while let row = try rows.next() {
                var object = jsonObject(row["value"] as String)
                let id: String = row["id"],path = object["relative_path"] as? String ?? ""
                object["receipt_id"] = id;result[id + ":" + path] = object
            }
            return result
        }
    }

    func testP321gRealMaintenanceOnExplicitOwnedSnapshot() throws {
        let environment = ProcessInfo.processInfo.environment
        let preserveBackupReceipts = environment["CHECKLIST_P321H_PRESERVE_RECEIPTS"] == "1"
        let requireFullByteTurn = environment["CHECKLIST_P321I_REQUIRE_FULL_BYTE_TURN"] == "1"
        var descriptorLimit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&descriptorLimit),0)
        if requireFullByteTurn {XCTAssertEqual(descriptorLimit.rlim_cur,256,"Run this owned-copy qualification under ulimit -n 256.")}
        guard let rawRoot = environment["CHECKLIST_P321G_STORE"],let rawOutput = environment["CHECKLIST_P321G_OUTPUT"],let phase = environment["CHECKLIST_P321G_PHASE"], ["baseline","after"].contains(phase) else {throw XCTSkip("Select explicit P321g runtime, output and baseline|after phase.")}
        let root = URL(fileURLWithPath:rawRoot,isDirectory:true).resolvingSymlinksInPath(),snapshot = root.deletingLastPathComponent()
        let temporary = URL(fileURLWithPath:"/private/tmp",isDirectory:true).resolvingSymlinksInPath().path
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(".p321g-owned-copy.json"))) as? JSON)
        let markedSnapshot = URL(fileURLWithPath:try XCTUnwrap(marker["snapshot"] as? String),isDirectory:true).resolvingSymlinksInPath()
        func path(_ url: URL) -> String {url.standardizedFileURL.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))}
        guard root.pathComponents.starts(with:URL(fileURLWithPath:temporary,isDirectory:true).pathComponents),marker["purpose"] as? String == "P321g-real-maintenance-owned-copy",path(markedSnapshot) == path(snapshot) else {throw CoreError("QUALIFICATION_COPY_REQUIRED","An explicitly cloned, marked runtime is required.",details:["root":root.path,"temporary":temporary,"snapshot":snapshot.path,"marked_snapshot":markedSnapshot.path])}
        let output = URL(fileURLWithPath:rawOutput),manifestData = try Data(contentsOf:snapshot.appendingPathComponent("manifest.json"))
        let manifestSHA = ChecklistCore.hash(manifestData)
        XCTAssertEqual(manifestSHA,marker["manifest_sha256"] as? String)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:manifestData)
        let log = try Log(output.appendingPathExtension("jsonl"))
        log.emit(["event":"startup_begin","phase":phase,"runtime":root.path,"snapshot":snapshot.path,"nofile_soft":descriptorLimit.rlim_cur,"nofile_hard":descriptorLimit.rlim_max])
        let startup = ProcessInfo.processInfo.systemUptime
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router.closeStore()}
        log.emit(["event":"startup_end","seconds":ProcessInfo.processInfo.systemUptime-startup])
        if !preserveBackupReceipts {
            // Fixture-only metadata redirection. Historical objects/accounting remain
            // unchanged; no old external backup path can be opened by cleanup.
            let localObjects: [JSON] = manifest.objects.map {["path":$0.descriptor.relativePath,"sha256":$0.sha256,"size":$0.size]}
            let fixtureReceipt: JSON = ["format":1,"state":"complete","operation_id":manifest.operationID,"manifest_sha256":manifestSHA,"known_at":now(),"current_physical_verified":false,"objects":localObjects,"summary":["kind":"backup","path":snapshot.path,"verification":"manifest_database_managed_files","manifest_sha256":manifestSHA,"source_root":manifest.sourceRoot,"store_id":manifest.storeID,"captured_at":manifest.capturedAt as Any? ?? NSNull()]]
            try router.dbQueue.writeWithoutTransaction {db in
                try db.inSavepoint {
                    try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.summary.path',?,'$.current_physical_verified',json('false')) WHERE key GLOB 'backup-generation:*'",arguments:[root.appendingPathComponent("unavailable-historical-backup").path])
                    try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + manifest.operationID,try jsonString(fixtureReceipt)])
                    return .commit
                }
            }
            log.emit(["event":"fixture_setup","existing_backup_paths_redirected":true,"owned_snapshot_receipt_added":true,"manifest_sha256":manifestSHA,"manifest_objects":manifest.objects.count,"job_state_mutations":0])
        } else {
            log.emit(["event":"fixture_setup","existing_backup_paths_redirected":false,"owned_snapshot_receipt_added":false,"all_receipt_bytes_preserved":true,"manifest_sha256":manifestSHA,"manifest_objects":manifest.objects.count,"job_state_mutations":0])
        }
        var diagnostic: JSON = [:]
        let backupReceiptsBefore = preserveBackupReceipts ? try backupReceiptInventory(router) : []
        if preserveBackupReceipts {
            let diagnosticObjects: [JSON] = manifest.objects.prefix(40133).map {["relative_path":$0.descriptor.relativePath,"sha256":$0.sha256,"size":$0.size]}
            let diagnosticStart = ProcessInfo.processInfo.systemUptime
            diagnostic = try router.readForPreparation {db in
                let receipts = backupReceiptsBefore
                var value: JSON = ["candidate_objects":diagnosticObjects.count,"candidate_source":"First 40,133 exact descriptors of immutable copied completed-backup manifest; diagnostic only, no receipt writes.","receipts":receipts,"receipt_count":receipts.count,"receipt_bytes":receipts.reduce(Int64(0)) {$0 + ($1["bytes"] as? Int64 ?? 0)},"receipt_objects":receipts.reduce(Int64(0)) {$0 + ($1["objects"] as? Int64 ?? 0)},"limit_bytes":TicketCleanupBatchInventory.byteLimit]
                do {
                    let coldBefore = Self.residentBytes()
                    let index = try router.ticketCleanupBackupRetentionIndex(db,objects:diagnosticObjects)
                    value["result"] = "available";value["cleanup_retained_bytes"] = index.cleanupRetainedBytes
                    value["cold_cache_and_lookup_rss_before"] = coldBefore;value["cold_cache_and_lookup_rss_after"] = Self.residentBytes()
                    let warmBefore = Self.residentBytes(),warmStart = ProcessInfo.processInfo.systemUptime
                    let warm = try router.ticketCleanupBackupRetentionIndex(db,objects:diagnosticObjects)
                    var retained = 0,independent = 0,warmPeak = max(warmBefore,Self.residentBytes())
                    for (offset,object) in diagnosticObjects.enumerated() {
                        autoreleasepool {
                            let key = StorageBackupRetentionIndex.key(path:object["relative_path"] as! String,sha:object["sha256"] as! String,size:(object["size"] as! NSNumber).int64Value)
                            if warm.containsOriginal(key) {retained += 1}
                            if warm.hasIndependentCopy(key) {independent += 1}
                        }
                        if offset % 256 == 0 {warmPeak = max(warmPeak,Self.residentBytes())}
                    }
                    let warmAfter = Self.residentBytes(),warmGrowth = warmAfter > warmBefore ? warmAfter-warmBefore : 0
                    warmPeak = max(warmPeak,warmAfter)
                    let sampledPeakGrowth = warmPeak > warmBefore ? warmPeak-warmBefore : 0
                    value["retained_key_count"] = retained;value["independent_copy_key_count"] = independent
                    value["warm_lookup_seconds"] = ProcessInfo.processInfo.systemUptime-warmStart
                    value["warm_lookup_retained_bytes"] = warm.cleanupRetainedBytes;value["warm_lookup_rss_before"] = warmBefore;value["warm_lookup_rss_after"] = warmAfter;value["warm_lookup_rss_growth"] = warmGrowth
                    value["warm_lookup_sampled_peak_rss"] = warmPeak;value["warm_lookup_sampled_peak_rss_growth"] = sampledPeakGrowth;value["warm_lookup_rss_sample_interval_keys"] = 256
                    value["memory_scope"] = "Additional cleanup observation descriptors are charged separately from the existing shared per-receipt cache; warmed RSS delta includes lookup creation and 40,133 one-key membership observations, excludes fixture/cold cache construction. Resident bytes sampled after lookup creation and every 256 membership observations; unsampled transient peaks are not measured."
                    XCTAssertGreaterThan(warmBefore,0,"A failed resident-memory read cannot prove the bound.")
                    XCTAssertGreaterThan(warmAfter,0)
                    XCTAssertLessThanOrEqual(warm.cleanupRetainedBytes,TicketCleanupBatchInventory.byteLimit)
                    XCTAssertLessThanOrEqual(warmGrowth,UInt64(TicketCleanupBatchInventory.byteLimit))
                    XCTAssertLessThanOrEqual(sampledPeakGrowth,UInt64(TicketCleanupBatchInventory.byteLimit))
                } catch let error as CoreError {
                    value["result"] = "error";value["error_code"] = error.code;value["error_message"] = error.message;value["error_details"] = error.details
                } catch {value["result"] = "error";value["error"] = String(describing:error)}
                return value
            }
            diagnostic["seconds"] = ProcessInfo.processInfo.systemUptime-diagnosticStart
            diagnostic["event"] = "explicit_backup_index_diagnostic";log.emit(diagnostic)
            try save(diagnostic,output.appendingPathExtension("index-diagnostic.json"))
        }
        let initialJobs = try jobs(router),initialRemoved = try removed(router)
        let presentBefore = Set(manifest.objects.map {$0.descriptor.relativePath}.filter {entryExists(root.appendingPathComponent($0))})
        try save(["jobs":initialJobs],output.appendingPathExtension("before.json"))
        // This one disclosed initial state selects the pending installed byte
        // turn. Subsequent alternation, backoff and rest remain production code.
        let startByte = environment["CHECKLIST_P321G_START_BYTE"] != "0"
        if startByte {router.ticketCleanupLifecycleTurn = false}
        if requireFullByteTurn {XCTAssertTrue(startByte)}
        let trafficTask = try router.readForPreparation {db -> JSON in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT t.id,t.project_id FROM records t JOIN records s ON s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND s.type='status' AND json_extract(s.data,'$.category') NOT IN ('done','canceled') ORDER BY t.rowid LIMIT 1"))
            return ["project_id":row["project_id"] as String,"task_id":row["id"] as String]
        }
        var baselineDescriptors: [Int32] = []
        defer {for descriptor in baselineDescriptors {Darwin.close(descriptor)}}
        var descriptorBaseline: JSON = [:]
        if requireFullByteTurn {
            func countOpenDescriptors() -> Int {
                (0..<Int(descriptorLimit.rlim_cur)).reduce(0) {$0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0)}
            }
            let before = countOpenDescriptors()
            while countOpenDescriptors() < 98 {
                let descriptor = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else {throw CoreError("QUALIFICATION_BASELINE_UNAVAILABLE","Could not pad the owned fixture's descriptor baseline.",details:["errno":errno])}
                baselineDescriptors.append(descriptor)
            }
            let after = countOpenDescriptors()
            descriptorBaseline = ["open_before":before,"open_after":after,"dev_null_padding":baselineDescriptors.count,"target":98]
            log.emit(["event":"descriptor_baseline","measurement":descriptorBaseline])
            XCTAssertGreaterThanOrEqual(after,98)
        }
        let traffic = DispatchGroup();traffic.enter()
        DispatchQueue.global(qos:.utility).async {
            defer {traffic.leave()}
            let owner = Caller(role:"owner",installation:"p321g-owned-copy",projectIDs:[])
            while log.active() {
                let began = ProcessInfo.processInfo.systemUptime
                do {_ = try router.handle(method:"task_get",params:trafficTask,caller:owner);log.recordRead(seconds:ProcessInfo.processInfo.systemUptime-began)}
                catch {log.recordRead(seconds:ProcessInfo.processInfo.systemUptime-began,error:String(describing:error))}
                Thread.sleep(forTimeInterval:1)
            }
        }
        defer {log.stop();traffic.wait()}
        let maxTurns = min(3,max(1,Int(environment["CHECKLIST_P321G_TURNS"] ?? "2") ?? 2)),maxWait = max(0,Double(environment["CHECKLIST_P321G_MAX_WAIT"] ?? "60") ?? 60)
        var turns: [JSON] = [],prior = try jsonString(initialJobs),unchanged = 0,stopReason = "turn_bound",maintenanceSeconds = 0.0
        let started = ProcessInfo.processInfo.systemUptime
        if requireFullByteTurn {XCTAssertEqual(maxTurns,1)}
        var observations: [JSON] = []
        for index in 0..<maxTurns {
            let deadline = try router.nextArchiveCleanupDeadline(),wait = deadline.map {max(0,$0.timeIntervalSinceNow)} ?? 0
            log.emit(["event":"scheduled_turn","index":index,"deadline":deadline.map {ISO8601DateFormatter().string(from:$0)} as Any? ?? NSNull(),"wait_seconds":wait,"initial_byte_turn_override":index == 0 && startByte])
            guard deadline != nil else {stopReason = "no_deadline";break}
            if wait > maxWait {stopReason = "production_rest_exceeds_bounded_wait";break}
            if wait > 0 {Thread.sleep(forTimeInterval:wait)}
            let tick = ProcessInfo.processInfo.systemUptime
            var failure: String?
            do {try router.runStorageMaintenance(observe:{observations.append($0);log.emit($0)})} catch {failure = String(describing:error)}
            let seconds = ProcessInfo.processInfo.systemUptime-tick;maintenanceSeconds += seconds
            let state = try jobs(router),signature = try jsonString(state)
            unchanged = signature == prior ? unchanged+1 : 0;prior = signature
            let entry: JSON = ["index":index,"seconds":seconds,"error":failure as Any? ?? NSNull(),"unchanged_job_state_count":unchanged,"jobs":state]
            turns.append(entry);log.emit(["event":"turn_complete","index":index,"seconds":seconds,"error":failure as Any? ?? NSNull(),"unchanged_job_state_count":unchanged])
            try save(["phase":phase,"turns":turns],output)
            if unchanged >= 2 {stopReason = "unchanged_twice";break}
        }
        log.stop();traffic.wait()
        let finalJobs = try jobs(router),finalRemoved = try removed(router)
        var proofs: [JSON] = [],verified = 0
        let byPath = Dictionary(manifest.objects.map {($0.descriptor.relativePath,$0)},uniquingKeysWith:{$1})
        for key in finalRemoved.keys.sorted() where initialRemoved[key] == nil {
            let object = finalRemoved[key]!,path = try XCTUnwrap(object["relative_path"] as? String),descriptor = try XCTUnwrap(byPath[path])
            let expectedSHA = try XCTUnwrap(object["sha256"] as? String),expectedSize = try XCTUnwrap(object["size"] as? NSNumber).int64Value
            XCTAssertEqual(descriptor.sha256,expectedSHA);XCTAssertEqual(descriptor.size,expectedSize)
            let backupURL = snapshot.appendingPathComponent("managed").appendingPathComponent(path)
            let actual: (String,Int64)
            if descriptor.descriptor.kind == "symlink" {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath:backupURL.path),bytes = Data(target.utf8)
                actual = (ChecklistCore.hash(bytes),Int64(bytes.count))
            } else {actual = try digest(backupURL)}
            XCTAssertEqual(actual.0,expectedSHA);XCTAssertEqual(actual.1,expectedSize)
            XCTAssertTrue(presentBefore.contains(path),"A newly removed object existed before maintenance")
            XCTAssertFalse(entryExists(root.appendingPathComponent(path)))
            var proof = object;proof["backup_path"] = backupURL.path;proof["backup_sha256"] = actual.0;proof["backup_size"] = actual.1;proof["original_existed_before"] = presentBefore.contains(path);proof["original_missing_after"] = !entryExists(root.appendingPathComponent(path))
            proofs.append(proof);verified += 1
        }
        let wall = ProcessInfo.processInfo.systemUptime-started
        var report: JSON = ["phase":phase,"runtime":root.path,"snapshot":snapshot.path,"manifest_sha256":manifestSHA,"nofile_soft":descriptorLimit.rlim_cur,"nofile_hard":descriptorLimit.rlim_max,"initial_byte_turn_override":startByte,"production_rest_bypassed":false,"max_turns":maxTurns,"max_wait_seconds":maxWait,"stop_reason":stopReason,"seconds":wall,"maintenance_seconds":maintenanceSeconds,"new_removals":proofs.count,"backup_proofs_verified":verified,"files_removed_per_minute":wall > 0 ? Double(proofs.count)*60/wall : 0,"turns":turns,"final_jobs":finalJobs,"responsiveness":log.readSummary(),"fixture_limits":[preserveBackupReceipts ? "All original backup-generation receipts and physical backup paths preserved, no receipt added." : "Existing backup receipt paths redirected to an owned nonexistent directory; one owned copied-snapshot receipt added through router writer before maintenance.","No fixture writes to tickets, jobs, cleanup cursors, retries, holds or turn rest.","Initial byte turn optionally selected to reproduce the installed pending byte turn; subsequent turn alternation and deadlines run unchanged.","Post-run independent proof hashes each newly removed backup payload; production deletion path supplies pre-unlink verification.","Preserve mode keeps every original receipt byte/path; diagnostic lookup warms the process cache before measured maintenance.","Snapshot-local maintenance uses the copied existing jobs without fixture job mutations.","Maintenance turn count and maximum individual scheduling wait are bounded; this is not a complete cleanup sweep."]]
        if preserveBackupReceipts {
            let backupReceiptsAfter = try backupReceiptInventory(router)
            let unchanged = try jsonString(backupReceiptsBefore) == jsonString(backupReceiptsAfter)
            report["backup_receipts_before"] = backupReceiptsBefore;report["backup_receipts_after"] = backupReceiptsAfter;report["all_original_backup_receipt_sha256_unchanged"] = unchanged
            XCTAssertEqual(backupReceiptsBefore.count,marker["receipt_count"] as? Int);XCTAssertTrue(unchanged,"Every original backup receipt byte and path must remain exact.")
        }
        let candidateObservations = observations.filter {$0["phase"] as? String == "candidates"}
        let decisions = observations.filter {$0["phase"] as? String == "decision"}.compactMap {$0["turn"] as? String}
        report["candidate_admissions"] = candidateObservations
        report["maintenance_decisions"] = decisions
        report["full_byte_turn_required"] = requireFullByteTurn
        report["descriptor_baseline"] = descriptorBaseline
        if requireFullByteTurn {
            XCTAssertEqual(turns.count,1)
            XCTAssertEqual(decisions,["deletion"],"Qualification must contain one production byte turn.")
            XCTAssertGreaterThanOrEqual(proofs.count,256,"One descriptor-bounded byte turn must make at least 256 independently verified removals.")
            XCTAssertTrue(candidateObservations.allSatisfy {($0["failures"] as? JSON ?? [:]).isEmpty})
        }
        report["responsiveness_scope"] = "Concurrent task_get traffic covers scheduled real maintenance turns and production waits; excludes startup, raw receipt inventory hashes and the separate cold/warm index diagnostic."
        report["backup_index_diagnostic"] = diagnostic
        report["all_original_backup_receipts_preserved"] = preserveBackupReceipts
        if let legacyID = environment["CHECKLIST_P321G_LEGACY_ID"] {
            report["legacy_head"] = finalJobs.first {$0["id"] as? String == legacyID} as Any? ?? NSNull()
        }
        try save(report,output);try save(["proofs":proofs],output.appendingPathExtension("proofs.json"))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:snapshot.appendingPathComponent("manifest.json"))),manifestSHA)
        XCTAssertEqual(verified,proofs.count)
        let reads = log.readSummary()
        XCTAssertTrue((reads["errors"] as? [String] ?? []).isEmpty)
        XCTAssertGreaterThan(reads["count"] as? Int ?? 0,0)
        if phase == "after" {
            XCTAssertGreaterThan(proofs.count,0,"A passing fixed-path qualification requires actual verified removals")
            if let legacyID = environment["CHECKLIST_P321G_LEGACY_ID"] {
                let legacy = try XCTUnwrap(finalJobs.first {$0["id"] as? String == legacyID})
                XCTAssertEqual(legacy["state"] as? String,"completed","The selected legacy head must settle")
            }
            if preserveBackupReceipts {XCTAssertEqual(diagnostic["result"] as? String,"available","The large lookup must fit despite all original backup copies.")}
        }
    }
}
