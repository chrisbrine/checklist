import ChecklistTestSupport
import XCTest
import Foundation
import Darwin
import GRDB
import CryptoKit
@testable import ChecklistCore

/// Explicit real-store qualification, excluded from normal unit runs. Every
/// writable root must descend from the independently copied snapshot's marker.
final class TicketCleanupOwnedCopyTests: XCTestCase {
    private let owner = Caller(role:"owner",installation:"cl321-owned-copy",projectIDs:[])
    private var environment: [String:String] {ProcessInfo.processInfo.environment}
    private func uptime() -> Double {ProcessInfo.processInfo.systemUptime}
    private func write(_ object: JSON,to url: URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)
    }
    private func read(_ url: URL) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? JSON)
    }
    private func call(_ router: CommandRouter,_ method: String,_ input: JSON = [:]) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = uuid()}
        return try XCTUnwrap(router.handle(method:method,params:input,caller:owner)["data"] as? JSON)
    }
    private func load() -> [Double] {
        var values = [Double](repeating:0,count:3)
        _ = getloadavg(&values,3)
        return values
    }
    private func resources() -> JSON {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF,&usage)
        let user = Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1_000_000
        let system = Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1_000_000
        return ["user_cpu_seconds":user,"system_cpu_seconds":system,"peak_resident_bytes":usage.ru_maxrss]
    }
    private func ownedBase() throws -> URL {
        guard let selected = environment["CHECKLIST_CL321_OWNED_COPY"] else {
            throw XCTSkip("Requires an explicitly owned copied backup and CHECKLIST_CL321_OWNED_COPY.")
        }
        let base = URL(fileURLWithPath:selected,isDirectory:true).resolvingSymlinksInPath()
        let marker = try read(base.appendingPathComponent("ownership.json"))
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Checklist").resolvingSymlinksInPath().path
        guard ["cl321-owned-copy","cl321-owned-copy-fb4ae90c"].contains(base.lastPathComponent),!base.path.hasPrefix(installed + "/"),base.path != installed,
              marker["purpose"] as? String == "CL321-owned-backup-cleanup-qualification",
              let snapshotName = marker["snapshot"] as? String,snapshotName.hasPrefix("snapshot-"),!snapshotName.contains("/") else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","Use the marked independent CL-321 backup copy.")
        }
        let snapshot = base.appendingPathComponent(snapshotName,isDirectory:true)
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:snapshot.appendingPathComponent("manifest.json"))),marker["source_manifest_sha256"] as? String)
        return base
    }
    private func descendant(_ raw: String,of base: URL) throws -> URL {
        let path = URL(fileURLWithPath:raw,isDirectory:true).resolvingSymlinksInPath()
        guard path.path.hasPrefix(base.path + "/") else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Qualification roots must remain owned descendants.")}
        return path
    }

    func testCleanupOnExplicitOwnedRealStoreCopy() throws {
        let base = try ownedBase()
        switch environment["CHECKLIST_CL321_PHASE"] {
        case "prepare":try prepare(base)
        case "backup":try backupPreparedCopy(base)
        case "cleanup":try cleanup(base)
        default:throw XCTSkip("Select explicit CL-321 prepare, backup or cleanup phase.")
        }
    }

    /// Diagnostic selection only: a fixed clock and unchanged owned database
    /// permit paired preparation measurements without a cleanup commit.
    func testReadOnlyLifecycleSelectionTimingOnOwnedCopy() throws {
        guard let rawTime = environment["CHECKLIST_CL321_TIMING_AT"],
              let rawOutput = environment["CHECKLIST_CL321_TIMING_OUTPUT"] else {
            throw XCTSkip("Select an explicit fixed timing clock and hand-in evidence output.")
        }
        let format = ISO8601DateFormatter()
        guard let time = format.date(from:rawTime) else {throw CoreError("QUALIFICATION_CLOCK_REQUIRED","Timing needs an ISO-8601 clock.")}
        let base = try ownedBase(),prepared = try read(base.appendingPathComponent("prepare.json"))
        guard prepared["status"] as? String == "prepared" else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Complete owned snapshot preparation first.")}
        let output = URL(fileURLWithPath:rawOutput).resolvingSymlinksInPath()
        guard rawOutput.hasPrefix("/"),output.pathExtension == "json" else {
            throw CoreError("QUALIFICATION_OUTPUT_REQUIRED","Select an explicit absolute JSON evidence output.")
        }
        let root = try descendant(try XCTUnwrap(prepared["restored_root"] as? String),of:base)
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router.closeStore()}
        func fingerprint() throws -> JSON {
            var result: JSON = [:]
            // WAL is authoritative with the database. SHM is transient reader
            // coordination and intentionally excluded from logical input bytes.
            for name in ["checklist.sqlite","checklist.sqlite-wal"] {
                let url = root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath:url.path) else {result[name] = NSNull();continue}
                let file = try FileHandle(forReadingFrom:url);defer {try? file.close()}
                var digest = SHA256(),bytes: Int64 = 0
                while let chunk = try file.read(upToCount:1024*1024),!chunk.isEmpty {digest.update(data:chunk);bytes += Int64(chunk.count)}
                result[name] = ["bytes":bytes,"sha256":digest.finalize().map {String(format:"%02x",$0)}.joined()]
            }
            return result
        }
        func logicalFingerprint() throws -> JSON {
            try router.readForPreparation {db in
                var result: JSON = [:]
                let queries = [
                    ("records","SELECT CAST(rowid AS BLOB),CAST(id AS BLOB),CAST(project_id AS BLOB),CAST(type AS BLOB),CAST(revision AS BLOB),CAST(data AS BLOB) FROM records ORDER BY rowid",["I","T","T","T","I","T"]),
                    ("events","SELECT CAST(seq AS BLOB),CAST(id AS BLOB),CAST(project_id AS BLOB),CAST(entity_id AS BLOB),CAST(actor AS BLOB),CAST(kind AS BLOB),CAST(occurred_at AS BLOB),CAST(data AS BLOB) FROM events ORDER BY seq",["I","T","T","T","T","T","T","T"]),
                    ("metadata","SELECT CAST(key AS BLOB),CAST(value AS BLOB) FROM metadata ORDER BY key",["T","T"]),
                    ("commands","SELECT CAST(rowid AS BLOB),CAST(principal AS BLOB),CAST(command_id AS BLOB),CAST(digest AS BLOB),CAST(result AS BLOB) FROM commands ORDER BY principal,command_id",["I","T","T","T","T"]),
                ]
                for (table,sql,fieldTypes) in queries {
                    var digest = SHA256(),rows: Int64 = 0,payloadBytes: Int64 = 0
                    let cursor = try Row.fetchCursor(db,sql:sql)
                    while let row = try cursor.next() {autoreleasepool {
                        // One row at a time. BLOB reads preserve embedded NUL
                        // and malformed UTF-8; schema type/length/null markers
                        // make exact field boundaries independent of decoding.
                        for index in 0..<row.count {
                            let bytes: Data? = row[index]
                            guard let bytes else {digest.update(data:Data("N;".utf8));continue}
                            digest.update(data:Data("\(fieldTypes[index])\(bytes.count):".utf8))
                            var offset = 0
                            while offset < bytes.count {
                                let end = min(bytes.count,offset+1024*1024)
                                digest.update(data:bytes[offset..<end]);offset = end
                            }
                            digest.update(data:Data(";".utf8));payloadBytes += Int64(bytes.count)
                        }
                        digest.update(data:Data("R;".utf8));rows += 1
                    }}
                    result[table] = ["rows":rows,"payload_bytes":payloadBytes,"sha256":digest.finalize().map {String(format:"%02x",$0)}.joined()]
                }
                return result
            }
        }
        let before = try fingerprint(),logicalBefore = try logicalFingerprint(),loadStart = load(),resourceStart = resources(),started = uptime()
        let projects = try router.readForPreparation {db in try router.records(db,type:"project").filter {
            if let selected = environment["CHECKLIST_CL321_TIMING_PROJECT"],
               ($0["id"] as? String).map({Data($0.utf8)}) != Data(selected.utf8) {return false}
            let settings = router.ticketCleanupSettings($0)
            return bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled")
        }}
        var measurements: [JSON] = []
        for project in projects {
            let measured = try router.readForPreparation {db -> JSON in
                var counts: [String:Int] = [:],durations: [String:Double] = [:],maximums: [String:Double] = [:]
                let phaseNames = ["selected_tickets","closed_clocks","selected_jobs","inventories","candidate_objects","backup_media","events","plans","commands","fences","final_projection"]
                var phaseIndex = 0,phaseNamesObserved: [String] = [],phaseSeconds: [Double] = []
                db.trace(options:.profile) {event in
                    guard case let .profile(statement,duration) = event else {return}
                    let sql = statement.sql.lowercased(),group: String
                    if sql.contains("storage_job"),phaseNames[min(phaseIndex,phaseNames.count-1)] == "selected_jobs" {group = "selected_jobs"}
                    else if sql.contains("backup-generation") || sql.contains("backup_summary") || sql.contains("known_backup") {group = "backup_metadata"}
                    else if sql.contains("from events") || sql.contains("join events") {group = "events"}
                    else if sql.contains("from commands") || sql.contains("join commands") {group = "commands"}
                    else if sql.contains("from records") || sql.contains("join records") {group = "corpus"}
                    else {group = "other"}
                    counts[group,default:0] += 1;durations[group,default:0] += duration
                    maximums[group] = max(maximums[group] ?? 0,duration)
                }
                defer {db.trace(options:[])}
                let tick = self.uptime()
                var previousTick = tick
                let selection = try router.ticketCleanupSelection(db,project:project,at:time,observePhase:{name in
                    let current = self.uptime()
                    phaseNamesObserved.append(name);phaseSeconds.append(current-previousTick);previousTick = current
                    if let index = phaseNames.firstIndex(of:name) {phaseIndex = index+1}
                })
                let seconds = self.uptime()-tick
                let returnOverhead = seconds-(previousTick-tick)
                if !phaseSeconds.isEmpty {phaseSeconds[phaseSeconds.count-1] += returnOverhead}
                XCTAssertEqual(phaseNamesObserved,phaseNames,"Timing needs every lifecycle phase boundary in order")
                XCTAssertEqual(phaseSeconds.reduce(0,+),seconds,accuracy:0.000001)
                let items = selection.selection["items"] as? [JSON] ?? []
                return ["project_id":project["id"]!,"selection_seconds":seconds,"derived_selection_rest_seconds":max(0.05,seconds*4),
                        "phase_seconds":zip(phaseNamesObserved,phaseSeconds).map {["phase":$0.0,"seconds":$0.1] as JSON},
                        "phase_return_overhead_seconds":returnOverhead,"phase_seconds_sum":phaseSeconds.reduce(0,+),
                        "selection_sha256":ChecklistCore.hash(try JSONSerialization.data(withJSONObject:selection.selection,options:[.sortedKeys])),
                        "scan_cursor":selection.selection["scan_cursor"]!,"next_cursor":selection.selection["next_cursor"]!,
                        "items":items.map {item -> JSON in
                            var summary: JSON = [:]
                            for key in ["task_id","task_revision","action","reason","plan_digest","purge_digest","scan_row"] {if let value = item[key] {summary[key] = value}}
                            return summary
                        },"sql_statement_counts":counts,"sql_profile_seconds":durations,"sql_max_profile_seconds":maximums]
            }
            measurements.append(measured)
        }
        let selectionSeconds = uptime()-started,logicalAfter = try logicalFingerprint(),after = try fingerprint()
        let unchanged = try jsonString(before) == jsonString(after),logicalUnchanged = try jsonString(logicalBefore) == jsonString(logicalAfter)
        let result: JSON = ["mode":"read_only_lifecycle_selection_timing","root":root.path,"fixed_time":rawTime,
                            "database_input_before":before,"database_input_after":after,"database_bytes_unchanged":unchanged,
                            "logical_database_input_before":logicalBefore,"logical_database_input_after":logicalAfter,"logical_database_input_unchanged":logicalUnchanged,
                            "logical_input_digest_format":"v2: per ordered row, each BLOB field is N; for null or schema type I/T + decimal byte length + : + exact bytes + ;, then R;. Numeric fields use SQLite decimal BLOB casts. records/events include rowid/seq; commands include rowid and order by canonical principal,command_id; metadata orders by canonical key.",
                            "selection_total_seconds":selectionSeconds,"projects":measurements,"load_start":loadStart,"load_end":load(),
                            "resources_start":resourceStart,"resources_end":resources(),"completed_at":now(),
                            "scope":"No maintenance call, command, commit, traffic or rest bypass. Selection wall time excludes startup and input fingerprints. Logical input hashes stream one row at a time outside timing; checkpoint-only file changes can be distinguished by stable logical hashes. Derived rest is four times selection wall, not a measured maintenance deadline. Phase intervals include callback overhead; final_projection includes return overhead. SQL profile durations are inclusive statement lifetimes with SQLite clock resolution, may include Swift cursor work, and are not additive with phases or wall time. SQL groups are textual/phase classifications."]
        try write(result,to:output)
        XCTAssertTrue(unchanged,"Read-only timing must preserve database and WAL bytes")
        XCTAssertTrue(logicalUnchanged,"Read-only timing must preserve records, events, metadata and commands")
        XCTAssertFalse(measurements.isEmpty,"Timing needs an enabled owned project")
        print("CL321_OWNED_TIMING seconds=\(selectionSeconds) projects=\(measurements.count) unchanged=\(unchanged) output=\(output.path)")
    }

    private func prepare(_ base: URL) throws {
        let marker = try read(base.appendingPathComponent("ownership.json"))
        let snapshot = base.appendingPathComponent(try XCTUnwrap(marker["snapshot"] as? String),isDirectory:true)
        var result: JSON = ["phase":"prepare","started_at":now(),"load_start":load(),"resources_start":resources(),"source_snapshot":snapshot.path]
        let output = base.appendingPathComponent("prepare.json")
        defer {try? write(result,to:output)}
        try write(result,to:output)
        let files = try StorageObjectFiles(root:snapshot)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        let started = uptime()
        let sha = try StorageSnapshot.verify(files,operation:try XCTUnwrap(UUID(uuidString:manifest.operationID)),budget:.production())
        result["snapshot_verification_seconds"] = uptime()-started
        result["manifest_sha256"] = sha;result["managed_paths"] = manifest.objects.count
        result["managed_logical_bytes"] = manifest.objects.reduce(Int64(0)) {$0+$1.size}
        result["record_families"] = manifest.recordFamilies ?? [:]
        print("CL321_OWNED snapshot_verified seconds=\(uptime()-started) objects=\(manifest.objects.count)")
        try write(result,to:output)
        let hostRoot = base.appendingPathComponent("host",isDirectory:true)
        let host = try TestStore.router(root:hostRoot,durable:true)
        defer {try? host.closeStore()}
        let previewStarted = uptime()
        let preview = try call(host,"restore_preview",["path":snapshot.path])
        result["restore_preview_seconds"] = uptime()-previewStarted
        result["stage"] = "initial_restore";try write(result,to:output)
        let restoreStarted = uptime()
        let restored = try call(host,"restore_create",["path":snapshot.path,"manifest_sha256":preview["manifest_sha256"]!])
        result["initial_restore_seconds"] = uptime()-restoreStarted
        result["restored_root"] = restored["path"]!;result["host_root"] = hostRoot.path
        try write(result,to:output)
        let candidateRoot = try descendant(try XCTUnwrap(restored["path"] as? String),of:base)
        let startupStarted = uptime()
        let candidate = try CommandRouter(root:candidateRoot,serviceLease:StorageServiceLease(root:candidateRoot))
        defer {try? candidate.closeStore()}
        result["candidate_startup_seconds"] = uptime()-startupStarted
        try finishOwnedBackup(candidate,result:&result,output:output)
    }

    private func finishOwnedBackup(_ candidate: CommandRouter,result: inout JSON,output: URL) throws {
        result["stage"] = "owned_backup";try write(result,to:output)
        let backupStarted = uptime()
        // The normal fixed destination also creates its owned backup parent.
        let backup = try call(candidate,"backup_create")
        result["owned_backup_seconds"] = uptime()-backupStarted;result["owned_backup"] = backup
        result["completed_at"] = now();result["load_end"] = load();result["resources_end"] = resources();result["status"] = "prepared"
        try write(result,to:output)
        print("CL321_OWNED prepared restore=\(result["initial_restore_seconds"]!) startup=\(result["candidate_startup_seconds"]!) backup=\(result["owned_backup_seconds"]!) root=\(candidate.root.path)")
    }

    /// A fixture-only backup-destination repair resumes the already qualified
    /// native restoration. It never reruns or edits the retained source copy.
    private func backupPreparedCopy(_ base: URL) throws {
        let output = base.appendingPathComponent("prepare.json")
        var result = try read(output)
        let root = try descendant(try XCTUnwrap(result["restored_root"] as? String),of:base)
        let startup = uptime()
        let candidate = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? candidate.closeStore();try? write(result,to:output)}
        result["backup_resume_started_at"] = now();result["backup_resume_load"] = load();result["backup_resume_resources_start"] = resources()
        result["backup_resume_startup_seconds"] = uptime()-startup
        try finishOwnedBackup(candidate,result:&result,output:output)
    }

    private final class Traffic: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var reads: [Double] = [],writes: [Double] = [],errors: [String] = []
        private var errorCount = 0,loadPeak = [Double](repeating:0,count:3),peakRSS: Int64 = 0
        func stop() {lock.withLock {stopped = true}}
        var running: Bool {lock.withLock {!stopped}}
        func record(read: Double? = nil,write: Double? = nil,error: String? = nil,load: [Double] = [],rss: Int64 = 0) {
            lock.withLock {
                if let read {reads.append(read)}
                if let write {writes.append(write)}
                if let error {errorCount += 1;if errors.count < 20 {errors.append(error)}}
                if load.count == 3 {loadPeak = zip(loadPeak,load).map {max($0,$1)}}
                peakRSS = max(peakRSS,rss)
            }
        }
        var summary: JSON {lock.withLock {
            func percentile(_ values: [Double],_ fraction: Double) -> Double {
                guard !values.isEmpty else {return 0}
                return values.sorted()[min(values.count-1,max(0,Int(ceil(Double(values.count)*fraction))-1))]
            }
            return ["read_count":reads.count,"write_count":writes.count,"read_max_seconds":reads.max() ?? 0,"write_max_seconds":writes.max() ?? 0,
             "read_median_seconds":percentile(reads,0.5),"write_median_seconds":percentile(writes,0.5),
             "read_p95_seconds":percentile(reads,0.95),"write_p95_seconds":percentile(writes,0.95),
             "read_p99_seconds":percentile(reads,0.99),"write_p99_seconds":percentile(writes,0.99),
             "error_count":errorCount,"errors":errors,"load_peak_samples":loadPeak,"peak_resident_bytes":peakRSS]
        }}
    }
    private struct Outcome {
        let task: String
        let path: String
        let kind: String
        let sha: String?
        let bytes: Int64
    }
    private func removed(_ router: CommandRouter) throws -> [String:Outcome] {
        try router.dbQueue.read {db in
            var result: [String:Outcome] = [:]
            let rows = try Row.fetchCursor(db,sql:"SELECT data FROM records WHERE type='storage_job' AND json_extract(data,'$.kind')='ticket_object_delete' AND json_extract(data,'$.cause') IN ('done_evidence','task_purge')")
            while let row = try rows.next() {try autoreleasepool {
                let job = jsonObject(row["data"] as String)
                for object in job["objects"] as? [JSON] ?? [] where object["state"] as? String == "removed" {
                    guard let task = job["task_id"] as? String,let path = object["relative_path"] as? String else {continue}
                    let item = Outcome(task:task,path:path,kind:object["kind"] as? String ?? "file",sha:object["sha256"] as? String,bytes:(object["size"] as? NSNumber)?.int64Value ?? 0)
                    result[task+":"+path] = item
                }
            }}
            return result
        }
    }
    private func cleanup(_ base: URL) throws {
        let qualificationStarted = uptime()
        let prepared = try read(base.appendingPathComponent("prepare.json"))
        guard prepared["status"] as? String == "prepared" else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Complete owned snapshot preparation first.")}
        let root = try descendant(try XCTUnwrap(prepared["restored_root"] as? String),of:base)
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router.closeStore()}
        let before = try removed(router),started = uptime()
        let byteOnce = environment["CHECKLIST_CL321_MODE"] == "byte_once"
        let firstNewRow = try router.dbQueue.read {try Int64.fetchOne($0,sql:"SELECT COALESCE(MAX(rowid),0) FROM records") ?? 0}
        var output: JSON = ["phase":"cleanup","stage":"sweep","started_at":now(),"load_start":load(),"resources_start":resources(),"root":root.path,
                            "startup_and_baseline_seconds":started-qualificationStarted,"processor_count":ProcessInfo.processInfo.processorCount]
        output["mode"] = byteOnce ? "byte_once" : "full_sweep"
        output["scope"] = byteOnce ? "One ordinary existing byte continuation; full-scan acceptance remains separate." : "Complete eligible scan and byte continuations."
        let outputURL = base.appendingPathComponent(byteOnce ? "byte-once-cleanup.json" : "cleanup.json")
        defer {try? write(output,to:outputURL)}
        let task = try router.dbQueue.read {db -> JSON in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT t.data FROM records t JOIN records s ON s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND s.type='status' AND json_extract(s.data,'$.category')='active' AND COALESCE(json_extract(t.data,'$.purged'),0)=0 ORDER BY t.rowid LIMIT 1"))
            return jsonObject(row["data"] as String)
        }
        let projectID = try XCTUnwrap(task["project_id"] as? String),taskID = try XCTUnwrap(task["id"] as? String)
        output["traffic_task_id"] = taskID;output["traffic_task_key"] = task["key"] ?? ""
        let readTask = try router.dbQueue.read {db -> JSON in
            guard let row = try Row.fetchOne(db,sql:"SELECT t.data FROM records t JOIN records s ON s.type='status' AND s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND t.project_id!=? AND COALESCE(json_extract(t.data,'$.purged'),0)=0 AND json_extract(s.data,'$.category') NOT IN ('done','canceled') ORDER BY t.rowid LIMIT 1",arguments:[projectID]) else {return task}
            return jsonObject(row["data"] as String)
        }
        let readProjectID = try XCTUnwrap(readTask["project_id"] as? String),readTaskID = try XCTUnwrap(readTask["id"] as? String)
        output["traffic_read_project_id"] = readProjectID;output["traffic_read_task_id"] = readTaskID
        output["traffic_cross_project_read"] = readProjectID != projectID
        let projects = try router.dbQueue.read {try router.records($0,type:"project")}.filter {
            let settings = router.ticketCleanupSettings($0)
            return bool(settings,"done_evidence_enabled") || bool(settings,"closed_purge_enabled")
        }
        // Reset each owned project's ordinary scan through its supported command;
        // no fixture SQL changes to cleanup state, canonical records or policies.
        for project in projects where !byteOnce {
            _ = try call(router,"project_settings_save",["project_id":project["id"]!,"expected_revision":project["revision"]!,"ticket_cleanup":router.ticketCleanupSettings(project)])
        }
        let ticketLabels = try router.dbQueue.read {db -> [String:JSON] in
            let selected = Set(projects.compactMap {$0["id"] as? String})
            let rows = try Row.fetchAll(db,sql:"SELECT t.id,t.project_id,json_extract(t.data,'$.key') AS ticket_key,COALESCE(json_extract(t.data,'$.purged'),0) AS purged,json_extract(s.data,'$.category') AS category FROM records t LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.type='status' WHERE t.type='task'")
            return Dictionary(uniqueKeysWithValues:rows.filter {selected.contains($0["project_id"] as String? ?? "")}.map {row in
                let category = row["category"] as String? ?? "unknown",purged = row["purged"] as Int? ?? 0
                return (row["id"] as String,["key":row["ticket_key"] as String? ?? "","project_id":row["project_id"] as String? ?? "","initial_status_category":category,"initial_purged":purged != 0,"initial_closed_candidate":purged == 0 && ["done","canceled"].contains(category)])
            })
        }
        output["initial_selected_project_count"] = projects.count;output["initial_ticket_count"] = ticketLabels.count
        output["initial_closed_candidate_count"] = ticketLabels.values.filter {bool($0,"initial_closed_candidate")}.count
        let trafficInterval = max(0.1,Double(environment["CHECKLIST_CL321_TRAFFIC_INTERVAL"] ?? "0.5") ?? 0.5)
        output["traffic_interval_seconds"] = trafficInterval
        output["traffic_scope"] = "Concurrent message_send and task_get from another project when present, on the same router while cleanup scans every enabled project."
        let traffic = Traffic(),group = DispatchGroup()
        let trafficOutput = base.appendingPathComponent(byteOnce ? "byte-once-traffic.json" : "cleanup-traffic.json")
        try write(traffic.summary,to:trafficOutput)
        group.enter()
        DispatchQueue.global(qos:.utility).async {
            defer {group.leave()}
            var sequence = 0,lastReport = ProcessInfo.processInfo.systemUptime
            while traffic.running {
                do {
                    var tick = ProcessInfo.processInfo.systemUptime
                    _ = try self.call(router,"message_send",["project_id":projectID,"task_id":taskID,"body":"CL-321 owned-copy concurrent note \(sequence)"])
                    traffic.record(write:ProcessInfo.processInfo.systemUptime-tick)
                    tick = ProcessInfo.processInfo.systemUptime
                    _ = try self.call(router,"task_get",["project_id":readProjectID,"task_id":readTaskID])
                    traffic.record(read:ProcessInfo.processInfo.systemUptime-tick)
                } catch {traffic.record(error:String(describing:error))}
                traffic.record(load:self.load(),rss:(self.resources()["peak_resident_bytes"] as? NSNumber)?.int64Value ?? 0)
                if ProcessInfo.processInfo.systemUptime-lastReport >= 10 {
                    try? self.write(traffic.summary,to:trafficOutput)
                    lastReport = ProcessInfo.processInfo.systemUptime
                }
                sequence += 1;Thread.sleep(forTimeInterval:trafficInterval)
            }
        }
        defer {traffic.stop();group.wait()}
        let rawEngine = environment["CHECKLIST_CL321_FAST_ENGINE"] == "1"
        output["production_rest_bypassed"] = rawEngine
        let limit = Double(environment["CHECKLIST_CL321_SECONDS"] ?? "900") ?? 900
        output["sweep_limit_seconds"] = limit
        var steps = 0,complete = false,peaks = load(),latest: JSON = [:],chunks: [Double] = [],pauses: [JSON] = [],observations: [JSON] = []
        var observedPasses = Set<String>()
        var priorState: String?,unchanged = 0
        if byteOnce {router.ticketCleanupLifecycleTurn = false}
        try write(output,to:outputURL)
        while uptime()-started < limit {
            if rawEngine {router.ticketCleanupYieldAt = nil}
            let chunkStarted = uptime()
            do {try autoreleasepool {try router.runStorageMaintenance()}}
            catch {output["maintenance_error"] = String(describing:error);break}
            chunks.append(uptime()-chunkStarted)
            steps += 1
            let statusStarted = uptime()
            let status = try router.readForPreparation {db -> JSON in
                var states: [JSON] = []
                for project in projects {
                    let pid = project["id"] as! String
                    let cursor = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:"+pid]) ?? "0"
                    let next = Double(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:"+pid]) ?? "0") ?? 0
                    let retries = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-retries:"+pid]) ?? "{}")
                    states.append(["project_id":pid,"cursor":cursor,"next":next,"retries":retries,"preparation":try router.ticketCleanupPreparationState(db,project:pid)])
                }
                let totals = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT SUM(CASE WHEN json_extract(data,'$.state')='pending' THEN 1 ELSE 0 END) AS pending,SUM(revision) AS revisions,SUM(COALESCE(json_extract(data,'$.summary.removed_count'),0)) AS removed_count,SUM(COALESCE(json_extract(data,'$.summary.removed_bytes'),0)) AS removed_bytes FROM records WHERE type='storage_job' AND json_extract(data,'$.kind')='ticket_object_delete'"))
                let passes = try Row.fetchAll(db,sql:"SELECT id,project_id,json_extract(data,'$.items') AS items FROM records WHERE rowid>? AND type='storage_job' AND json_extract(data,'$.cause')='ticket_cleanup_pass' ORDER BY rowid",arguments:[firstNewRow]).map {row -> JSON in
                    let items = (try JSONSerialization.jsonObject(with:Data((row["items"] as String? ?? "[]").utf8))) as? [JSON] ?? []
                    return ["receipt_id":row["id"] as String,"project_id":row["project_id"] as String? ?? "","item_count":items.count,"items":items]
                }
                return ["projects":states,"pending_jobs":totals["pending"] as Int? ?? 0,"job_revision_sum":totals["revisions"] as Int? ?? 0,"removed_count":totals["removed_count"] as Int? ?? 0,"removed_bytes":totals["removed_bytes"] as Int64? ?? 0,"new_passes":passes]
            }
            latest = status
            let newPasses = (status["new_passes"] as? [JSON] ?? []).compactMap {$0["receipt_id"] as? String}.filter {observedPasses.insert($0).inserted}
            let stepLoad = load();peaks = zip(peaks,stepLoad).map {max($0,$1)}
            observations.append(["step":steps,"elapsed_seconds":uptime()-started,"maintenance_seconds":chunks.last!,"status_observation_seconds":uptime()-statusStarted,
                                 "new_pass_receipt_ids":newPasses,"pending_jobs":status["pending_jobs"]!,"removed_count":status["removed_count"]!,"load":stepLoad,"resources":resources()])
            complete = (status["pending_jobs"] as? Int == 0) && (status["projects"] as! [JSON]).allSatisfy {($0["cursor"] as? String == "0") && (($0["retries"] as? JSON)?.isEmpty == true) && (($0["next"] as? Double ?? 0) > Date().timeIntervalSince1970+3600)}
            if steps <= 3 || steps % 10 == 0 || complete {
                output["steps"] = steps;output["seconds"] = uptime()-started;output["latest_state"] = latest;output["traffic"] = traffic.summary
                output["chunk_seconds"] = chunks;output["chunk_median_seconds"] = chunks.sorted()[chunks.count/2];output["chunk_max_seconds"] = chunks.max() ?? 0;output["load_peak_samples"] = peaks
                output["step_observations"] = observations
                try write(output,to:outputURL)
                print("CL321_OWNED step=\(steps) elapsed=\(uptime()-started) pending=\(status["pending_jobs"]!) removed=\(status["removed_count"]!) chunk=\(chunks.last!) complete=\(complete)")
            }
            if complete || byteOnce {break}
            let state = try jsonString(status)
            unchanged = state == priorState ? unchanged+1 : 0;priorState = state
            if unchanged >= 2 {
                if rawEngine {router.ticketCleanupYieldAt = nil}
                let deadline = try router.nextArchiveCleanupDeadline()
                if let deadline,deadline.timeIntervalSinceNow > 0.5,deadline.timeIntervalSinceNow < limit-(uptime()-started) {
                    let delay = deadline.timeIntervalSinceNow+0.05
                    pauses.append(["reason":"known_maintenance_deadline","seconds":delay,"state":status]);output["diagnosed_retry_pauses"] = pauses
                    let resume = uptime()+delay
                    repeat {
                        output["seconds"] = uptime()-started;output["traffic"] = traffic.summary
                        try write(output,to:outputURL)
                        Thread.sleep(forTimeInterval:min(30,max(0,resume-uptime())))
                    } while uptime() < resume
                    unchanged = 0
                } else {
                    output["stopped_for_unchanged_state"] = true;output["unchanged_state"] = status;break
                }
            }
            Thread.sleep(forTimeInterval:rawEngine ? 0.05 : 0.25)
        }
        traffic.stop();group.wait()
        try write(traffic.summary,to:trafficOutput)
        let after = try removed(router),new = after.filter {before[$0.key] == nil}.map(\.value)
        var byTicket: [String:JSON] = ticketLabels.mapValues {label in
            var value = label
            value["removed_count"] = 0;value["removed_bytes"] = Int64(0);value["scan_observations"] = 0
            value["actions"] = [String:Int]();value["reasons"] = [String:Int]()
            return value
        }
        var scanned = Set<String>()
        for receipt in latest["new_passes"] as? [JSON] ?? [] {
            for item in receipt["items"] as? [JSON] ?? [] {
                guard let id = item["task_id"] as? String else {continue}
                scanned.insert(id)
                var counts = byTicket[id] ?? ["removed_count":0,"removed_bytes":Int64(0)]
                counts["scan_observations"] = int(counts,"scan_observations")+1
                for field in ["action","reason"] {
                    var values = counts[field+"s"] as? [String:Int] ?? [:]
                    values[item[field] as? String ?? "unknown",default:0] += 1
                    counts[field+"s"] = values
                }
                byTicket[id] = counts
            }
        }
        for item in new {
            var counts = byTicket[item.task] ?? (ticketLabels[item.task] ?? [:]).merging(["removed_count":0,"removed_bytes":Int64(0)]) {_,new in new}
            counts["removed_count"] = (counts["removed_count"] as! Int)+1
            counts["removed_bytes"] = (counts["removed_bytes"] as! Int64)+item.bytes
            byTicket[item.task] = counts
        }
        output["completed_scan_and_byte_jobs"] = complete;output["seconds"] = uptime()-started;output["steps"] = steps;output["latest_state"] = latest;output["chunk_seconds"] = chunks
        let unobserved = ticketLabels.filter {bool($0.value,"initial_closed_candidate") && !scanned.contains($0.key)}.keys.sorted()
        output["scanned_ticket_count"] = scanned.count;output["unobserved_initial_closed_candidates"] = unobserved
        output["step_observations"] = observations
        output["removed_by_ticket"] = byTicket;output["newly_removed_count"] = new.count;output["newly_removed_bytes"] = new.reduce(Int64(0)) {$0+$1.bytes}
        output["newly_removed_objects"] = new.sorted {$0.task+":"+$0.path < $1.task+":"+$1.path}.map {item -> JSON in ["task_id":item.task,"relative_path":item.path,"kind":item.kind,"sha256":item.sha as Any? ?? NSNull(),"size":item.bytes]}
        output["traffic"] = traffic.summary;output["load_peak_samples"] = peaks;output["load_end"] = load();output["resources_end"] = resources()
        output["stage"] = "restore";output["sweep_finished_at"] = now()
        try write(output,to:outputURL)
        // Native restore of the pre-cleanup owned backup proves removed live
        // pathnames still restore exactly; source and backup remain untouched.
        let backup = try XCTUnwrap(prepared["owned_backup"] as? JSON)
        let backupRoot = try descendant(try XCTUnwrap(backup["path"] as? String),of:base)
        output["restore_source_backup"] = backupRoot.path;output["restore_source_manifest_sha256"] = backup["manifest_sha256"]!
        let hostRoot = try descendant(try XCTUnwrap(prepared["host_root"] as? String),of:base)
        let host = try CommandRouter(root:hostRoot,serviceLease:StorageServiceLease(root:hostRoot))
        defer {try? host.closeStore()}
        let restoreStarted = uptime()
        // The completed backup receipt supplies its verified digest. Create
        // independently verifies it again before normal candidate publication.
        let restored = try call(host,"restore_create",["path":backupRoot.path,"manifest_sha256":backup["manifest_sha256"]!])
        let restoredRoot = try descendant(try XCTUnwrap(restored["path"] as? String),of:base)
        let restoredFiles = try StorageObjectFiles(root:restoredRoot),backupFiles = try StorageObjectFiles(root:backupRoot)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:backupFiles.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        let descriptors = Dictionary(uniqueKeysWithValues:manifest.objects.map {($0.descriptor.relativePath,$0)})
        let marker = try read(base.appendingPathComponent("ownership.json"))
        let sourceRoot = base.appendingPathComponent(try XCTUnwrap(marker["snapshot"] as? String),isDirectory:true)
        let sourceFiles = try StorageObjectFiles(root:sourceRoot)
        let sourceManifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:sourceFiles.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        let sourceDescriptors = Dictionary(uniqueKeysWithValues:sourceManifest.objects.map {($0.descriptor.relativePath,$0)})
        var restoreChecks = 0,notInBackup: [String] = []
        var sourceMatches = 0
        for item in new {
            guard let object = descriptors[item.path] else {notInBackup.append(item.path);continue}
            if item.kind == "symlink" {
                XCTAssertEqual(try restoredFiles.linkTarget(item.path),object.descriptor.linkTarget)
            } else {
                XCTAssertEqual(try restoredFiles.digest(item.path,budget:.production()).0,object.sha256)
                XCTAssertEqual(object.sha256,item.sha)
                XCTAssertEqual(object.size,item.bytes)
            }
            if let source = sourceDescriptors[item.path],source.sha256 == object.sha256,source.size == object.size,source.descriptor.linkTarget == object.descriptor.linkTarget {sourceMatches += 1}
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(item.path).path))
            restoreChecks += 1
        }
        output["restore_check_seconds"] = uptime()-restoreStarted;output["restored_after_cleanup_root"] = restoredRoot.path
        output["restore_checked_removed_files"] = restoreChecks;output["removed_paths_absent_from_backup"] = notInBackup
        output["original_newest_snapshot_descriptor_matches"] = sourceMatches
        output["completed_at"] = now();output["stage"] = "completed";output["qualification_seconds"] = uptime()-qualificationStarted
        XCTAssertTrue(notInBackup.isEmpty,"Every removed object must have independent backup bytes")
        XCTAssertTrue(complete,"Owned scan/bytes did not settle within the stated finite measurement window")
        if !byteOnce {XCTAssertTrue(unobserved.isEmpty,"Every initial closed candidate must appear in an ordinary scan receipt")}
        XCTAssertGreaterThan(new.count,0,"The owned real store must demonstrate actual byte removal")
        XCTAssertEqual(sourceMatches,new.count,"Every removed descriptor must match the original newest copied snapshot")
        XCTAssertEqual(traffic.summary["error_count"] as? Int,0)
        XCTAssertGreaterThan(traffic.summary["read_count"] as? Int ?? 0,0)
        XCTAssertGreaterThan(traffic.summary["write_count"] as? Int ?? 0,0)
        print("CL321_OWNED result removed=\(new.count) bytes=\(output["newly_removed_bytes"]!) restored=\(restoreChecks) seconds=\(output["seconds"]!) traffic=\(traffic.summary)")
    }
}
