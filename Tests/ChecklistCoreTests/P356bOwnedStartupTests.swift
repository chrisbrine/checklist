import XCTest
import Foundation
import Darwin
import GRDB
import CryptoKit
@testable import ChecklistCore

/// Explicit opt-in qualification of an owned, already cloned production store.
/// It neither creates a store fixture nor changes historical jobs or receipts.
final class P356bOwnedStartupTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        let handle: FileHandle
        var running = true
        var reads = 0, notes = 0
        var errors: [String] = []
        var lookups: [Double] = []
        init(_ url: URL) throws {
            _ = FileManager.default.createFile(atPath:url.path,contents:nil)
            handle = try FileHandle(forWritingTo:url)
        }
        deinit {try? handle.close()}
        private func openDescriptorCount() -> Int {(0..<256).reduce(0) {$0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0)}}
        func emit(_ input: JSON) {
            // Serial, bounded instrumentation must not consume production FDs.
            lock.lock();defer {lock.unlock()}
            autoreleasepool {
                let before = openDescriptorCount()
                var load = "UNAVAILABLE",loadFailure: String?
                do {
                    let process = Process(),pipe = Pipe()
                    let errorOutput = try FileHandle(forWritingTo:URL(fileURLWithPath:"/dev/null"))
                    defer {try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close();try? errorOutput.close()}
                    process.executableURL = URL(fileURLWithPath:"/usr/sbin/sysctl")
                    process.arguments = ["-n","vm.loadavg"]
                    process.standardOutput = pipe;process.standardError = errorOutput
                    try process.run();process.waitUntilExit()
                    try? pipe.fileHandleForWriting.close()
                    load = String(data:try pipe.fileHandleForReading.readToEnd() ?? Data(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                    if process.terminationStatus != 0 || load.isEmpty {loadFailure = "sysctl exit=\(process.terminationStatus), empty=\(load.isEmpty)";load = "UNAVAILABLE"}
                } catch {loadFailure = String(describing:error)}
                if let loadFailure {errors.append("load instrumentation: " + loadFailure)}
                var value = input
                value["uptime"] = ProcessInfo.processInfo.systemUptime
                value["load_command"] = "sysctl -n vm.loadavg";value["load"] = load
                value["load_error"] = loadFailure as Any? ?? NSNull()
                value["open_descriptors_before_load"] = before
                value["open_descriptors_after_load"] = openDescriptorCount()
                if let bytes = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]) {try? handle.write(contentsOf:bytes + Data([10]));try? handle.synchronize()}
            }
        }
        func active() -> Bool {lock.lock();defer {lock.unlock()};return running}
        func stop() {lock.lock();running = false;lock.unlock()}
        func traffic(_ note: Bool,seconds: Double,error: String? = nil) {
            lock.lock();if note {notes += 1} else {reads += 1};if let error {errors.append(error)};lock.unlock()
            emit(["event":note ? "synthetic_private_note" : "concurrent_task_get","seconds":seconds,"error":error as Any? ?? NSNull()])
        }
        func lookup(_ seconds: Double,parsed: Int) {
            lock.lock();lookups.append(seconds);lock.unlock()
            emit(["event":"backup_lookup","seconds":seconds,"legacy_receipts_parsed":parsed])
        }
        func summary() -> JSON {lock.lock();defer {lock.unlock()};return ["reads":reads,"notes":notes,"errors":errors,"lookup_count":lookups.count,"maximum_lookup_seconds":lookups.max() as Any? ?? NSNull(),"lookups_under_one_second":!lookups.isEmpty && lookups.allSatisfy {$0 < 1}]}
    }
    private func save(_ value: JSON,_ url: URL) throws {try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
    private func exists(_ url: URL) -> Bool {var info = stat();return lstat(url.path,&info) == 0}
    private func size(_ url: URL) throws -> Int64 {(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.int64Value ?? -1}
    private func digest(_ url: URL) throws -> (String,Int64) {
        let input = try FileHandle(forReadingFrom:url);defer {try? input.close()}
        var sha = SHA256(),count: Int64 = 0
        while let bytes = try input.read(upToCount:1_048_576),!bytes.isEmpty {sha.update(data:bytes);count += Int64(bytes.count)}
        return (StorageObjectFiles.hex(sha.finalize()),count)
    }
    private func readStore<T>(_ root: URL,_ body: (Database)throws->T) throws -> T {
        var config = Configuration();config.readonly = true
        config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let queue = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:config)
        defer {try? queue.close()};return try queue.read(body)
    }
    /// Typed framing preserves every original stored byte, NULL and integer.
    private func families(_ db: Database) throws -> [JSON] {
        try String.fetchAll(db,sql:"SELECT DISTINCT type FROM records ORDER BY CAST(type AS BLOB)").map {family in
            var sha = SHA256(),count = 0
            func feed(_ bytes: Data) {var length = UInt64(bytes.count).bigEndian;withUnsafeBytes(of:&length) {sha.update(data:Data($0))};sha.update(data:bytes)}
            let rows = try Row.fetchCursor(db,sql:"SELECT CAST(id AS BLOB) id,CAST(project_id AS BLOB) project,CAST(type AS BLOB) family,revision,CAST(data AS BLOB) payload FROM records WHERE type=? ORDER BY CAST(id AS BLOB)",arguments:[family])
            while let row = try rows.next() {
                feed(Data([255]));feed(row["id"] as Data)
                if let project: Data = row["project"] {feed(Data([1]));feed(project)} else {feed(Data([0]))}
                feed(row["family"] as Data)
                var revision = (row["revision"] as Int64).bigEndian
                withUnsafeBytes(of:&revision) {feed(Data($0))}
                feed(row["payload"] as Data);count += 1
            }
            return ["family":family,"count":count,"sha256":StorageObjectFiles.hex(sha.finalize())]
        }
    }
    private func receipts(_ db: Database,root: URL? = nil) throws -> JSON {
        let rows = try Row.fetchAll(db,sql:"SELECT key,length(CAST(value AS BLOB)) bytes,json_extract(value,'$.format') format,json_extract(value,'$.object_count') objects,json_extract(value,'$.historical_catalog.path') catalog,json_extract(value,'$.summary.verification') verification FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")
        let entries = try rows.map {row -> JSON in
            try autoreleasepool {
                let key: String = row["key"]
                let raw = try XCTUnwrap(Data.fetchOne(db,sql:"SELECT CAST(value AS BLOB) FROM metadata WHERE key=?",arguments:[key]))
                var value: JSON = ["key":key,"bytes":row["bytes"] as Int64,"raw_sha256":ChecklistCore.hash(raw),"format":row["format"] as Int? as Any? ?? NSNull(),"objects":row["objects"] as Int? as Any? ?? NSNull(),"catalog":row["catalog"] as String? as Any? ?? NSNull(),"verification":row["verification"] as String? as Any? ?? NSNull()]
                if let root,let path: String = row["catalog"] {
                    guard path.hasPrefix("objects/backup-catalogs/"),!path.split(separator:"/").contains("..") else {throw CoreError("QUALIFICATION_CATALOG_PATH","Historical catalog must be managed under the owned root.")}
                    let actual = try digest(root.appendingPathComponent(path))
                    value["historical_raw_sha256"] = actual.0;value["historical_raw_bytes"] = actual.1
                }
                return value
            }
        }
        return ["count":rows.count,"historical_count":rows.filter {($0["catalog"] as String?) != nil}.count,"manifest_count":rows.filter {($0["catalog"] as String?) == nil}.count,"total_receipt_bytes":rows.reduce(Int64(0)) {$0 + ($1["bytes"] as Int64)},"receipts":entries]
    }
    private func jobs(_ router: CommandRouter) throws -> [JSON] {
        try router.readForPreparation {db in try Row.fetchAll(db,sql:"SELECT id,revision,json_extract(data,'$.task_id') task,json_extract(data,'$.cause') cause,json_extract(data,'$.state') state,json_extract(data,'$.summary') summary FROM records WHERE type='storage_job' AND json_extract(data,'$.kind')='ticket_object_delete' ORDER BY CAST(id AS BLOB)").map {row in ["id":row["id"] as String,"revision":row["revision"] as Int64,"task_id":row["task"] as String? ?? "","cause":row["cause"] as String? ?? "","state":row["state"] as String? ?? "","summary":jsonObject(row["summary"] as String? ?? "{}")]}}
    }
    private func removed(_ router: CommandRouter) throws -> [String:JSON] {
        try router.readForPreparation {db in
            var result: [String:JSON] = [:]
            let rows = try Row.fetchCursor(db,sql:"SELECT r.id,j.value FROM records r,json_each(r.data,'$.objects') j WHERE r.type='storage_job' AND json_extract(r.data,'$.kind')='ticket_object_delete' AND json_extract(j.value,'$.state')='removed'")
            while let row = try rows.next() {var value = jsonObject(row["value"] as String);let id: String = row["id"];value["receipt_id"] = id;result[id + ":" + (value["relative_path"] as? String ?? "")] = value}
            return result
        }
    }
    func testInstrumentationDoesNotAccumulateDescriptors() throws {
        let temporary = URL(fileURLWithPath:"/private/tmp",isDirectory:true).resolvingSymlinksInPath()
        let source = URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true).resolvingSymlinksInPath()
        guard source.pathComponents.count > temporary.pathComponents.count,source.pathComponents.starts(with:temporary.pathComponents) else {throw XCTSkip("Instrumentation regression requires the explicitly assigned private source copy.")}
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE,&limit) == 0,limit.rlim_cur == 256 else {throw XCTSkip("Run instrumentation descriptor regression under ulimit -n 256.")}
        let directory = source.appendingPathComponent(".local/p356b-evidence",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let output = directory.appendingPathComponent("instrumentation-descriptors-" + uuid() + ".jsonl")
        let log = try Log(output)
        func countFDs() -> Int {(0..<256).reduce(0) {$0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0)}}
        var padding: [Int32] = [];defer {for fd in padding {Darwin.close(fd)}}
        while countFDs() < 98 {
            let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else {throw CoreError("QUALIFICATION_DESCRIPTOR_BASELINE","Could not pad instrumentation descriptor baseline.")}
            padding.append(fd)
        }
        let baseline = countFDs()
        XCTAssertEqual(baseline,98)
        let background = DispatchGroup();background.enter()
        DispatchQueue.global(qos:.utility).async {
            defer {background.leave()}
            for index in 0..<100 {autoreleasepool {log.emit(["event":"instrumentation_descriptor_regression","iteration":index])}}
        }
        background.wait()
        let finalCount = countFDs()
        let rows = try Data(contentsOf:output).split(separator:10).map {try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0)) as? JSON)}
        XCTAssertEqual(rows.count,100)
        XCTAssertTrue(rows.allSatisfy {$0["load"] as? String != "UNAVAILABLE" && $0["load_error"] is NSNull},"Each requested sysctl observation must succeed.")
        let before = rows.compactMap {$0["open_descriptors_before_load"] as? Int},after = rows.compactMap {$0["open_descriptors_after_load"] as? Int}
        XCTAssertEqual(before.count,100);XCTAssertEqual(after.count,100)
        XCTAssertLessThanOrEqual(before.max() ?? Int.max,baseline+4,"Descriptors must not accumulate between logger emissions.")
        XCTAssertLessThanOrEqual(after.max() ?? Int.max,baseline+12,"The live logger subprocess must have a fixed descriptor bound.")
        XCTAssertLessThanOrEqual(finalCount,baseline+4,"One hundred background emissions must release their temporary descriptors.")
        XCTAssertTrue((log.summary()["errors"] as? [String] ?? []).isEmpty)
        try save(["log":output.path,"emissions":rows.count,"nofile":limit.rlim_cur,"baseline_descriptors":baseline,"final_descriptors":finalCount,"maximum_before_load":before.max() as Any? ?? NSNull(),"maximum_after_load":after.max() as Any? ?? NSNull(),"errors":log.summary()["errors"] ?? NSNull()],output.appendingPathExtension("summary.json"))
    }
    func testExplicitOwnedQualification() throws {
        try qualify(ProcessInfo.processInfo.environment)
    }
    func testManifestEquippedStartupAndDrain() throws {
        try parallelCase(folder:"with-manifests",mode:"startup-drain")
    }
    func testManifestMissingStartup() throws {
        try parallelCase(folder:"without-manifests",mode:"startup")
    }
    private func parallelCase(folder: String,mode: String) throws {
        var env = ProcessInfo.processInfo.environment
        guard env["CHECKLIST_P356B_PARALLEL"] == "1",let parent = env["CHECKLIST_P356B_PARENT"],let prefix = env["CHECKLIST_P356B_OUTPUT"] else {throw XCTSkip("Explicit parallel owned-copy qualification required.")}
        env["CHECKLIST_P356B_ROOT"] = parent + "/" + folder
        env["CHECKLIST_P356B_OUTPUT"] = prefix + "-" + folder + ".json"
        env["CHECKLIST_P356B_MODE"] = mode
        try qualify(env)
    }
    private func qualify(_ env: [String:String]) throws {
        guard let rawRoot = env["CHECKLIST_P356B_ROOT"],let rawSnapshot = env["CHECKLIST_P356B_SNAPSHOT"],let rawOutput = env["CHECKLIST_P356B_OUTPUT"],let mode = env["CHECKLIST_P356B_MODE"],["startup","startup-drain","drain","backup","backup-drain-backup","backup-drain","drain-retention"].contains(mode) else {throw XCTSkip("Explicit owned P356b root, snapshot, output and startup|startup-drain|drain|backup|backup-drain-backup mode required.")}
        let root = URL(fileURLWithPath:rawRoot,isDirectory:true).resolvingSymlinksInPath(),snapshot = URL(fileURLWithPath:rawSnapshot,isDirectory:true).resolvingSymlinksInPath(),output = URL(fileURLWithPath:rawOutput).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath:"/private/tmp",isDirectory:true).resolvingSymlinksInPath()
        func inside(_ child: URL,_ parent: URL) -> Bool {child.pathComponents.count > parent.pathComponents.count && child.pathComponents.starts(with:parent.pathComponents)}
        guard inside(root,temporary),inside(snapshot,temporary),root != snapshot else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Only a separate private temporary runtime and immutable snapshot may be used.")}
        let permittedEvidence = URL(fileURLWithPath:env["CHECKLIST_P356B_EVIDENCE"] ?? "/private/tmp",isDirectory:true)
        guard inside(output,temporary) || inside(output,permittedEvidence) else {throw CoreError("QUALIFICATION_OUTPUT_REQUIRED","Output must be private temporary or the assigned P356b evidence folder.")}
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(".p356b-owned-copy.json"))) as? JSON)
        let manifestBytes = try Data(contentsOf:snapshot.appendingPathComponent("manifest.json")),manifestSHA = ChecklistCore.hash(manifestBytes)
        guard marker["purpose"] as? String == "P356b-owned-copy",(marker["snapshot"] as? String).map({URL(fileURLWithPath:$0,isDirectory:true).resolvingSymlinksInPath().pathComponents}) == snapshot.pathComponents,marker["manifest_sha256"] as? String == manifestSHA else {throw CoreError("QUALIFICATION_MARKER_REQUIRED","Exact owned runtime marker and immutable snapshot binding required.")}
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:manifestBytes)
        var limit = rlimit();guard getrlimit(RLIMIT_NOFILE,&limit) == 0,limit.rlim_cur == 256 else {throw CoreError("QUALIFICATION_NOFILE_REQUIRED","Run the actual owned-copy path under ulimit -n 256.")}
        var padding: [Int32] = [];defer {for fd in padding {Darwin.close(fd)}}
        func countFDs() -> Int {(0..<256).reduce(0) {$0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0)}}
        let log = try Log(output.appendingPathExtension("jsonl"))
        let openBefore = countFDs()
        while countFDs() < 98 {let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC);guard fd >= 0 else {throw CoreError("QUALIFICATION_DESCRIPTOR_BASELINE","Could not pad descriptor baseline.")};padding.append(fd)}
        log.emit(["event":"qualification_begin","mode":mode,"root":root.path,"snapshot":snapshot.path,"manifest_sha256":manifestSHA,"nofile":limit.rlim_cur,"open_descriptors_before_padding":openBefore,"padding_count":padding.count,"open_descriptors_after_padding":countFDs(),"production_snapshot_budget_seconds":StorageSnapshotBudget.productionSeconds])
        let beforeStart = ProcessInfo.processInfo.systemUptime
        let before = try readStore(root) {db -> JSON in ["schema":try Int.fetchOne(db,sql:"PRAGMA user_version") ?? -1,"families":try families(db),"receipts":try receipts(db,root:root)]}
        let dbBefore = try size(root.appendingPathComponent("checklist.sqlite"))
        try save(before,output.appendingPathExtension("before.json"))
        log.emit(["event":"before_inventory","seconds":ProcessInfo.processInfo.systemUptime-beforeStart,"database_bytes":dbBefore])
        StorageBootstrap.qualificationObserve = {phase,seconds in log.emit(["event":"bootstrap_phase","phase":phase,"seconds":seconds])}
        StorageBackupReceiptMigration.observe = {phase,seconds in log.emit(["event":"schema5_phase","phase":phase,"seconds":seconds])}
        defer {StorageBootstrap.qualificationObserve = nil;StorageBackupReceiptMigration.observe = nil}
        let startup = ProcessInfo.processInfo.systemUptime
        let router: CommandRouter
        let qualificationTrash = root.appendingPathComponent("qualification-trash",isDirectory:true)
        if mode != "drain-retention" {try FileManager.default.createDirectory(at:qualificationTrash,withIntermediateDirectories:true)}
        do {router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root),automaticBackupRetentionTrashRoot:qualificationTrash)}
        catch {
            let seconds = ProcessInfo.processInfo.systemUptime-startup
            let failure: JSON = ["mode":mode,"status":"FAIL","startup_seconds":seconds,"database_before_bytes":dbBefore,"before":before,"error":String(describing:error),"error_details":(error as? CoreError)?.details ?? [:]]
            try save(failure,output)
            log.emit(["event":"startup_failed","seconds":seconds,"error":String(describing:error),"error_details":(error as? CoreError)?.details ?? [:]])
            throw error
        }
        defer {try? router.closeStore()}
        let startupSeconds = ProcessInfo.processInfo.systemUptime-startup,dbAfter = try size(root.appendingPathComponent("checklist.sqlite"))
        log.emit(["event":"startup_complete","seconds":startupSeconds,"database_before_bytes":dbBefore,"database_after_bytes":dbAfter,"database_saved_bytes":dbBefore-dbAfter])
        let afterStart = ProcessInfo.processInfo.systemUptime
        let after = try router.readForPreparation {db -> JSON in ["schema":try Int.fetchOne(db,sql:"PRAGMA user_version") ?? -1,"families":try families(db),"receipts":try receipts(db,root:root),"integrity_check":try String.fetchAll(db,sql:"PRAGMA integrity_check")]}
        let beforeFamilies = before["families"] as? [JSON] ?? [],afterFamilies = after["families"] as? [JSON] ?? []
        let unchanged = try jsonString(["families":beforeFamilies]) == jsonString(["families":afterFamilies])
        let originalReceipts = ((before["receipts"] as? JSON)?["receipts"] as? [JSON] ?? [])
        let originalSHA = Dictionary(originalReceipts.compactMap {value -> (String,String)? in guard let key = value["key"] as? String,let sha = (value["historical_raw_sha256"] as? String) ?? (value["raw_sha256"] as? String) else {return nil};return (key,sha)},uniquingKeysWith:{$1})
        let historicalProofs = ((after["receipts"] as? JSON)?["receipts"] as? [JSON] ?? []).filter {$0["historical_raw_sha256"] is String}.map {value -> JSON in let key = value["key"] as? String ?? "",actual = value["historical_raw_sha256"] as? String ?? "";return ["key":key,"original_raw_sha256":originalSHA[key] as Any? ?? NSNull(),"historical_raw_sha256":actual,"historical_bytes":value["historical_raw_bytes"] ?? NSNull(),"exact_original_raw_json_preserved":originalSHA[key] == actual]}
        var report: JSON = ["mode":mode,"startup_seconds":startupSeconds,"database_before_bytes":dbBefore,"database_after_bytes":dbAfter,"database_saved_bytes":dbBefore-dbAfter,"before":before,"after":after,"all_record_families_unchanged":unchanged,"record_family_count":beforeFamilies.count,"fixture_mutations":0,"automatic_retention_scope":"Copied original confirmation is never rebound or minted; automatic pruning remains ineligible if its source_root differs."]
        report["historical_catalog_raw_proofs"] = historicalProofs
        report["all_historical_catalog_raw_bytes_exact"] = historicalProofs.allSatisfy {$0["exact_original_raw_json_preserved"] as? Bool == true}
        try save(report,output);log.emit(["event":"after_inventory","seconds":ProcessInfo.processInfo.systemUptime-afterStart,"family_count":beforeFamilies.count,"all_record_families_unchanged":unchanged,"integrity_check":after["integrity_check"] ?? NSNull(),"receipts":after["receipts"] ?? NSNull()])
        XCTAssertEqual(after["schema"] as? Int,5)
        XCTAssertEqual(after["integrity_check"] as? [String],["ok"])
        XCTAssertTrue(historicalProofs.allSatisfy {$0["exact_original_raw_json_preserved"] as? Bool == true},"Every historical catalog must retain the original receipt's exact raw JSON bytes.")
        if mode == "startup" || mode == "startup-drain" || mode == "backup-drain-backup" {XCTAssertEqual(beforeFamilies.count,37);XCTAssertTrue(unchanged,"Every original record family's exact source bytes must survive startup; see before/after hashes.");if mode == "startup" {return}}
        if mode == "backup" || mode == "backup-drain" {
            let label = env["CHECKLIST_P356B_BACKUP_LABEL"] ?? "backup"
            guard ["backup","backup_after_drain"].contains(label) else {throw StorageSnapshotFailure.invalidFixture}
            try backup(router,root:root,output:output,log:log,report:&report,label:label,confirmRetention:env["CHECKLIST_P356B_CONFIRM_RETENTION_FIXTURE"] == "1")
            if mode == "backup-drain" {try drain(router,root:root,snapshot:snapshot,manifest:manifest,output:output,log:log,report:&report,environment:env)}
            return
        }
        if mode == "backup-drain-backup" {
            try backup(router,root:root,output:output,log:log,report:&report,label:"backup_before_drain",confirmRetention:false)
            var drainEnvironment = env
            if drainEnvironment["CHECKLIST_P356B_DRAIN_SECONDS"] == nil {drainEnvironment["CHECKLIST_P356B_DRAIN_SECONDS"] = "600"}
            try drain(router,root:root,snapshot:snapshot,manifest:manifest,output:output,log:log,report:&report,environment:drainEnvironment)
            try backup(router,root:root,output:output,log:log,report:&report,label:"backup_after_drain",confirmRetention:env["CHECKLIST_P356B_CONFIRM_RETENTION_FIXTURE"] == "1")
            return
        }
        try drain(router,root:root,snapshot:snapshot,manifest:manifest,output:output,log:log,report:&report,environment:env)
        if mode == "drain-retention" {
            try FileManager.default.createDirectory(at:qualificationTrash,withIntermediateDirectories:true)
            let began = ProcessInfo.processInfo.systemUptime
            let recovery = router.applyAutomaticBackupRetention(after:nil)
            let seconds = ProcessInfo.processInfo.systemUptime-began
            report["automatic_retention_recovery"] = recovery
            report["automatic_retention_recovery_seconds"] = seconds
            report["automatic_retention_scope"] = "Bounded recovery of the existing durably due completed backup under the earlier private simulated owner confirmation; no new confirmation or manual prune."
            log.emit(["event":"automatic_retention_recovery","seconds":seconds,"reply":recovery])
            try save(report,output)
            XCTAssertEqual(recovery["status"] as? String,"complete")
        }
    }
    private func backup(_ router: CommandRouter,root: URL,output: URL,log: Log,report: inout JSON,label: String,confirmRetention: Bool) throws {
        let fixtureOwner = Caller(role:"owner",installation:"p356b-simulated-core-owner-fixture",projectIDs:[])
        var phase: JSON = ["phase":label,"fixture_confirmation_requested":confirmRetention]
        let originalKeys = try router.readForPreparation {try String.fetchAll($0,sql:"SELECT key FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")}
        let settingsBefore = try router.handle(method:"backup_retention_get",params:[:],caller:fixtureOwner)
        phase["retention_before"] = settingsBefore
        log.emit(["event":"retention_before","phase":label,"reply":settingsBefore,"provenance":"simulated_core_owner_fixture_read; no native app channel used"])
        if confirmRetention {
            let policyCommand = uuid(),policyStarted = ProcessInfo.processInfo.systemUptime
            let policyReply = try router.handle(method:"backup_retention_set",params:["command_id":policyCommand,"newest_count":3,"daily_days":3],caller:fixtureOwner)
            phase["retention_fixture_policy_reply"] = policyReply
            phase["retention_fixture_provenance"] = "Simulated in-process core owner fixture, explicitly selected for the marked private runtime only. This is not a native owner confirmation or live-installation consent. The inherited confirmation was not manually rebound; the supported command created a new fixture-local receipt."
            phase["fixture_mutations"] = 1
            report["fixture_mutations"] = (report["fixture_mutations"] as? Int ?? 0) + 1
            report["automatic_retention_scope"] = "Explicit synthetic core-owner fixture confirmation on the owned private copy. Native owner flow and live automatic-pruning consent remain NOT SHOWN."
            log.emit(["event":"retention_fixture_policy_set","phase":label,"seconds":ProcessInfo.processInfo.systemUptime-policyStarted,"command_id":policyCommand,"reply":policyReply,"provenance":phase["retention_fixture_provenance"]!])
        }
        let settingsAfter = try router.handle(method:"backup_retention_get",params:[:],caller:fixtureOwner)
        phase["retention_after_fixture_setup"] = settingsAfter
        report[label] = phase;try save(report,output)
        log.emit(["event":"retention_after_fixture_setup","phase":label,"reply":settingsAfter,"provenance":"simulated_core_owner_fixture_read; no native app channel used"])
        let began = ProcessInfo.processInfo.systemUptime
        let command = ProcessInfo.processInfo.environment["CHECKLIST_P356B_RESUME_BACKUP_COMMAND"] ?? uuid()
        guard UUID(uuidString:command) != nil else {throw StorageSnapshotFailure.invalidFixture}
        let destination = root.appendingPathComponent("backups/snapshot-" + command,isDirectory:true)
        log.emit(["event":"backup_create_begin","phase":label,"command_id":command,"destination":destination.path])
        do {
            let reply = try router.handle(method:"backup_create",params:["command_id":command,"path":destination.path,"reason":"P356b explicitly owned copied-store qualification " + label],caller:fixtureOwner)
            phase["backup_create_reply"] = reply;phase["backup_create_seconds"] = ProcessInfo.processInfo.systemUptime-began
            if confirmRetention {XCTAssertEqual((reply["backup_retention"] as? JSON)?["status"] as? String,"complete","Automatic retention must actually complete; backup success alone is insufficient.")}
            log.emit(["event":"backup_create_complete","phase":label,"seconds":phase["backup_create_seconds"]!,"reply":reply])
            let finalSettings = try router.handle(method:"backup_retention_get",params:[:],caller:fixtureOwner)
            phase["retention_after_backup"] = finalSettings
            let finalKeys = try router.readForPreparation {try String.fetchAll($0,sql:"SELECT key FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")}
            phase["original_receipt_count"] = originalKeys.count;phase["final_receipt_count"] = finalKeys.count
            phase["all_preexisting_receipts_retained"] = Set(originalKeys).isSubset(of:Set(finalKeys))
            if label == "backup_before_drain" {XCTAssertTrue(Set(originalKeys).isSubset(of:Set(finalKeys)),"The pre-drain backup must retain all original backup receipts.")}
            log.emit(["event":"retention_after_backup","phase":label,"reply":finalSettings,"original_receipt_count":originalKeys.count,"final_receipt_count":finalKeys.count,"all_preexisting_receipts_retained":phase["all_preexisting_receipts_retained"]!,"provenance":"simulated_core_owner_fixture_read; no native app channel used"])
        } catch {
            phase["backup_create_error"] = String(describing:error);report[label] = phase
            log.emit(["event":"backup_create_failed","phase":label,"seconds":ProcessInfo.processInfo.systemUptime-began,"error":String(describing:error)])
            try save(report,output);throw error
        }
        report[label] = phase
        if label == "backup" {for (key,value) in phase {report[key] = value}}
        try save(report,output)
    }
    private func drain(_ router: CommandRouter,root: URL,snapshot: URL,manifest: StorageSnapshotManifest,output: URL,log: Log,report: inout JSON,environment: [String:String]) throws {
        let cache = StorageBackupAccountingCache.shared(root:root)
        cache.cleanupLookupObserver = {seconds,parsed in log.lookup(seconds,parsed:parsed)}
        defer {cache.cleanupLookupObserver = nil}
        let initialJobs = try jobs(router),initialRemoved = try removed(router)
        let presentBefore = Set(manifest.objects.map {$0.descriptor.relativePath}.filter {exists(root.appendingPathComponent($0))})
        let task = try router.readForPreparation {db -> JSON in let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT t.id,t.project_id FROM records t JOIN records s ON s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND s.type='status' AND json_extract(s.data,'$.category') NOT IN ('done','canceled') ORDER BY t.rowid LIMIT 1"));return ["project_id":row["project_id"] as String,"task_id":row["id"] as String]}
        let traffic = DispatchGroup();traffic.enter()
        DispatchQueue.global(qos:.utility).async {
            defer {traffic.leave()}
            let owner = Caller(role:"owner",installation:"p356b-private-qualification",projectIDs:[])
            var count = 0
            while log.active() {
                autoreleasepool {
                let began = ProcessInfo.processInfo.systemUptime
                do {_ = try router.handle(method:"task_get",params:task,caller:owner);log.traffic(false,seconds:ProcessInfo.processInfo.systemUptime-began)} catch {log.traffic(false,seconds:ProcessInfo.processInfo.systemUptime-began,error:String(describing:error))}
                if count % 3 == 0 {
                    var params = task;params["command_id"] = uuid();params["body"] = "[Synthetic private-copy qualification] P356b note traffic"
                    let note = ProcessInfo.processInfo.systemUptime
                    do {_ = try router.handle(method:"message_send",params:params,caller:owner);log.traffic(true,seconds:ProcessInfo.processInfo.systemUptime-note)} catch {log.traffic(true,seconds:ProcessInfo.processInfo.systemUptime-note,error:String(describing:error))}
                }
                }
                count += 1;Thread.sleep(forTimeInterval:1)
            }
        }
        defer {log.stop();traffic.wait()}
        let duration = min(1800,max(1,Double(environment["CHECKLIST_P356B_DRAIN_SECONDS"] ?? "1800") ?? 1800))
        let began = ProcessInfo.processInfo.systemUptime
        var turns: [JSON] = [],prior = try jsonString(["jobs":initialJobs]),unchanged = 0,reason = "duration_bound"
        while ProcessInfo.processInfo.systemUptime-began < duration {
            guard let deadline = try router.nextArchiveCleanupDeadline() else {reason = "no_deadline";break}
            let wait = max(0,deadline.timeIntervalSinceNow)
            log.emit(["event":"production_rest","wait_seconds":wait,"turn":turns.count])
            let available = max(0,duration-(ProcessInfo.processInfo.systemUptime-began))
            let endsDuringRest = wait >= available
            var remaining = min(wait,available)
            while remaining > 0 {let pause = min(30,remaining);Thread.sleep(forTimeInterval:pause);remaining -= pause}
            if endsDuringRest {reason = "duration_bound_during_production_rest";break}
            log.emit(["event":"maintenance_turn_begin","index":turns.count,"load_scope":"Start of the parent turn; child phase timings use this and the completion sysctl samples."])
            let tick = ProcessInfo.processInfo.systemUptime
            var failure: String?,observations: [JSON] = [],dropped = 0
            do {try router.runStorageMaintenance(observe:{value in
                // Never spawn sysctl or flush evidence while the production writer is held.
                if observations.count < 100_000 {var event = value;event["observed_uptime"] = ProcessInfo.processInfo.systemUptime;observations.append(event)} else {dropped += 1}
            })} catch {failure = String(describing:error)}
            let seconds = ProcessInfo.processInfo.systemUptime-tick,state = try jobs(router),signature = try jsonString(["jobs":state])
            unchanged = signature == prior ? unchanged+1 : 0;prior = signature
            let turn: JSON = ["index":turns.count,"seconds":seconds,"error":failure as Any? ?? NSNull(),"unchanged_job_state_count":unchanged]
            turns.append(turn);log.emit(turn.merging(["event":"maintenance_turn_complete","observations":observations,"dropped_observations":dropped,"load_scope":"End of the parent turn; child phase timing loads are bracketed by this and maintenance_turn_begin."]) {_,new in new})
            try save(["turns":turns,"elapsed_seconds":ProcessInfo.processInfo.systemUptime-began],output.appendingPathExtension("turns.json"))
            if unchanged >= 2 {reason = "unchanged_twice";break}
        }
        log.stop();traffic.wait()
        let wall = ProcessInfo.processInfo.systemUptime-began,finalRemoved = try removed(router)
        let byPath = Dictionary(manifest.objects.map {($0.descriptor.relativePath,$0)},uniquingKeysWith:{$1})
        let proofStarted = ProcessInfo.processInfo.systemUptime
        var proofs: [JSON] = []
        for key in finalRemoved.keys.sorted() where initialRemoved[key] == nil {
            let object = finalRemoved[key]!,path = try XCTUnwrap(object["relative_path"] as? String),entry = try XCTUnwrap(byPath[path]),backup = snapshot.appendingPathComponent("managed").appendingPathComponent(path)
            let expectedSHA = try XCTUnwrap(object["sha256"] as? String),expectedSize = try XCTUnwrap(object["size"] as? NSNumber).int64Value
            let actual: (String,Int64)
            if entry.descriptor.kind == "symlink" {let bytes = Data(try FileManager.default.destinationOfSymbolicLink(atPath:backup.path).utf8);actual = (ChecklistCore.hash(bytes),Int64(bytes.count))} else {actual = try digest(backup)}
            let passed = entry.sha256 == expectedSHA && entry.size == expectedSize && actual.0 == expectedSHA && actual.1 == expectedSize && presentBefore.contains(path) && !exists(root.appendingPathComponent(path))
            let proof: JSON = ["relative_path":path,"receipt_id":object["receipt_id"] ?? NSNull(),"expected_sha256":expectedSHA,"expected_size":expectedSize,"backup_sha256":actual.0,"backup_size":actual.1,"passed":passed]
            proofs.append(proof);XCTAssertTrue(passed,"Every newly removed original requires an exact independently copied backup payload.")
        }
        let proofSeconds = ProcessInfo.processInfo.systemUptime-proofStarted
        log.emit(["event":"independent_removed_payload_hashes","seconds":proofSeconds,"files":proofs.count])
        let remaining = try router.readForPreparation {db in
            try Row.fetchAll(db,sql:"SELECT json_extract(j.value,'$.state') state,json_extract(j.value,'$.reasons') reasons,count(*) count,sum(json_extract(j.value,'$.size')) bytes FROM records r,json_each(r.data,'$.objects') j WHERE r.type='storage_job' AND json_extract(r.data,'$.kind')='ticket_object_delete' AND json_extract(j.value,'$.state') IN ('pending','retained') GROUP BY state,reasons ORDER BY state,reasons").map {row -> JSON in ["state":row["state"] as String? ?? "","reasons_json":row["reasons"] as String? ?? "[]","count":row["count"] as Int,"bytes":row["bytes"] as Int64? ?? 0]}
        }
        let physicalFiles = Set(proofs.compactMap {$0["relative_path"] as? String}).count
        let rate = Double(physicalFiles)*60/wall
        report["remaining_pending_and_holds"] = remaining
        report["drain_rate_scope"] = "Production maintenance, production rests and concurrent private note/read traffic; excludes subsequent independent backup payload hashes, whose time is reported separately."
        report["independent_proof_hash_seconds"] = proofSeconds
        report["drain"] = ["seconds":wall,"requested_seconds":duration,"stop_reason":reason,"production_rests_bypassed":false,"initial_turn_override":false,"turns":turns,"new_removals":proofs.count,"unique_removed_files":physicalFiles,"files_removed_per_minute":rate,"responsiveness":log.summary(),"initial_jobs":initialJobs,"final_jobs":try jobs(router),"proofs":proofs]
        try save(report,output)
        log.emit(["event":"drain_complete","seconds":wall,"new_removals":proofs.count,"files_removed_per_minute":rate,"stop_reason":reason,"traffic":log.summary()])
        XCTAssertGreaterThan(proofs.count,0)
        XCTAssertGreaterThanOrEqual(rate,122)
        XCTAssertTrue((log.summary()["errors"] as? [String] ?? []).isEmpty)
        XCTAssertTrue(log.summary()["lookups_under_one_second"] as? Bool ?? false)
    }
}
