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
        log.emit(["event":"startup_begin","phase":phase,"runtime":root.path,"snapshot":snapshot.path])
        let startup = ProcessInfo.processInfo.systemUptime
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router.closeStore()}
        log.emit(["event":"startup_end","seconds":ProcessInfo.processInfo.systemUptime-startup])
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
        let initialJobs = try jobs(router),initialRemoved = try removed(router)
        let presentBefore = Set(manifest.objects.map {$0.descriptor.relativePath}.filter {entryExists(root.appendingPathComponent($0))})
        try save(["jobs":initialJobs],output.appendingPathExtension("before.json"))
        // This one disclosed initial state selects the pending installed byte
        // turn. Subsequent alternation, backoff and rest remain production code.
        let startByte = environment["CHECKLIST_P321G_START_BYTE"] != "0"
        if startByte {router.ticketCleanupLifecycleTurn = false}
        let trafficTask = try router.readForPreparation {db -> JSON in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT t.id,t.project_id FROM records t JOIN records s ON s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND s.type='status' AND json_extract(s.data,'$.category') NOT IN ('done','canceled') ORDER BY t.rowid LIMIT 1"))
            return ["project_id":row["project_id"] as String,"task_id":row["id"] as String]
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
        for index in 0..<maxTurns {
            let deadline = try router.nextArchiveCleanupDeadline(),wait = deadline.map {max(0,$0.timeIntervalSinceNow)} ?? 0
            log.emit(["event":"scheduled_turn","index":index,"deadline":deadline.map {ISO8601DateFormatter().string(from:$0)} as Any? ?? NSNull(),"wait_seconds":wait,"initial_byte_turn_override":index == 0 && startByte])
            guard deadline != nil else {stopReason = "no_deadline";break}
            if wait > maxWait {stopReason = "production_rest_exceeds_bounded_wait";break}
            if wait > 0 {Thread.sleep(forTimeInterval:wait)}
            let tick = ProcessInfo.processInfo.systemUptime
            var failure: String?
            do {try router.runStorageMaintenance(observe:{log.emit($0)})} catch {failure = String(describing:error)}
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
        var report: JSON = ["phase":phase,"runtime":root.path,"snapshot":snapshot.path,"manifest_sha256":manifestSHA,"initial_byte_turn_override":startByte,"production_rest_bypassed":false,"max_turns":maxTurns,"max_wait_seconds":maxWait,"stop_reason":stopReason,"seconds":wall,"maintenance_seconds":maintenanceSeconds,"new_removals":proofs.count,"backup_proofs_verified":verified,"files_removed_per_minute":wall > 0 ? Double(proofs.count)*60/wall : 0,"turns":turns,"final_jobs":finalJobs,"responsiveness":log.readSummary(),"fixture_limits":["Existing backup receipt paths redirected to an owned nonexistent directory; one owned copied-snapshot receipt added through router writer before maintenance.","No fixture writes to tickets, jobs, cleanup cursors, retries, holds or turn rest.","Initial byte turn optionally selected to reproduce the installed pending byte turn; subsequent turn alternation and deadlines run unchanged.","Post-run independent proof hashes each newly removed backup payload; production deletion path supplies pre-unlink verification.","Maintenance turn count and maximum individual scheduling wait are bounded; this is not a complete cleanup sweep."]]
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
            let legacyID = try XCTUnwrap(environment["CHECKLIST_P321G_LEGACY_ID"])
            let legacy = try XCTUnwrap(finalJobs.first {$0["id"] as? String == legacyID})
            XCTAssertEqual(legacy["state"] as? String,"completed","The selected legacy head must settle")
        }
    }
}
