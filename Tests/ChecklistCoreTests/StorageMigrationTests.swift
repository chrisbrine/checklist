import XCTest
import Foundation
import Darwin
import GRDB
import CryptoKit
@testable import ChecklistCore

final class StorageMigrationTests: XCTestCase {
    func testRetainedDomainCopyQualifiesCatalogSnapshotAndMigration() throws {
        guard let selected = ProcessInfo.processInfo.environment["CHECKLIST_STORAGE_COMPATIBILITY_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly prepared, owned read-only retained-domain copy.")
        }
        let base = URL(fileURLWithPath:selected,isDirectory:true).standardizedFileURL
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("ownership.json"))) as! JSON
        let fixtureID = try XCTUnwrap(marker["fixture_id"] as? String)
        guard UUID(uuidString:fixtureID) != nil,base.lastPathComponent == "CL19-compatibility-" + fixtureID,
              marker["purpose"] as? String == "CL19-readonly-retained-domain-compatibility",
              marker["copy"] as? String == "retained.sqlite" else {throw CoreError("FIXTURE_REFUSED","Explicit owned copy required.")}
        let input = base.appendingPathComponent("retained.sqlite"),inputSHA = ChecklistCore.hash(try Data(contentsOf:input))
        XCTAssertEqual(inputSHA,marker["copy_sha256"] as? String)
        let sourceRoot = URL(fileURLWithPath:try XCTUnwrap(marker["source_root"] as? String),isDirectory:true)
        let sourceFiles = try StorageObjectFiles(root:sourceRoot)
        var read = Configuration();read.readonly = true;read.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:input.path,configuration:read)
        defer {try? copy.close()}
        func conserved(_ db: Database, expectedRecords: [Int64:(data: String, revision: Int)] = [:]) throws -> String {
            var digest = SHA256()
            for table in ["metadata","records","commands","events","cursors"] {
                let names = try Row.fetchAll(db,sql:"PRAGMA table_info(" + table + ")").map {$0["name"] as String}
                let columns: [String] = ["rowid"] + names
                var selections: [String] = []
                for column in columns {
                    selections.append("typeof(" + column + ")")
                    selections.append("hex(CAST(" + column + " AS BLOB))")
                }
                let fields: String = selections.joined(separator:",")
                let predicate = table == "metadata" ? " WHERE key NOT IN ('store_identity','schema_migrations','preupgrade_snapshot','managed-capture-paths-v3')" : ""
                let rows = try Row.fetchCursor(db,sql:"SELECT rowid AS fixture_rowid," + fields + " FROM " + table + predicate + " ORDER BY rowid")
                digest.update(data:Data(table.utf8))
                while let row = try rows.next() {
                    var cells = (1..<row.count).map { row[$0] as String }
                    if table == "records", let expected = expectedRecords[row["fixture_rowid"] as Int64] {
                        for (column, kind, value) in [("data", "text", expected.data), ("revision", "integer", String(expected.revision))] {
                            let index = columns.firstIndex(of: column)!
                            cells[index * 2] = kind
                            cells[index * 2 + 1] = Data(value.utf8).map { String(format: "%02X", $0) }.joined()
                        }
                    }
                    digest.update(data:Data((cells.joined(separator:"|") + "\n").utf8))
                }
            }
            return digest.finalize().map {String(format:"%02x",$0)}.joined()
        }
        let budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime + 90,canceled:{false})
        let inspected = try copy.read {db -> (String,String,Int,StorageSnapshotInventory) in
            guard case .legacy(let incarnation) = try SchemaMigrations.inspect(db) else {throw CoreError("FIXTURE_REFUSED","Retained legacy copy required.")}
            var count = 0,plans = 0
            let rows = try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid")
            while let row = try rows.next() {
                let envelope = try GRDBRecordEnvelopeAdapter.decode(row);count += 1
                if envelope.type == "ordinary_mention_plan" {plans += 1}
            }
            XCTAssertGreaterThan(plans,0,"The observed failing retained family must be present.")
            return (incarnation,try conserved(db),count,try StorageSnapshotAuthority.inventory(db,root:sourceRoot,budget:budget,retainedExists:{try sourceFiles.regularOrLinkExists($0)}))
        }
        let run = base.appendingPathComponent("run-" + UUID().uuidString.lowercased(),isDirectory:true)
        try FileManager.default.createDirectory(at:run,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.copyItem(at:input,to:run.appendingPathComponent("checklist.sqlite"))
        var verifiedBytes:Int64 = 0
        for object in inspected.3.objects {
            try budget.check()
            let destination = run.appendingPathComponent(object.relativePath)
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if object.kind == "file" {
                // Fixture seeding reads the closed authority through no-follow
                // descriptors. Independent owned bytes avoid source hardlinks.
                let bytes = try sourceFiles.read(object.relativePath,maximum:Int(budget.maximumObjectBytes))
                if let expected = object.expectedSHA256 {XCTAssertEqual(ChecklistCore.hash(bytes),expected)}
                if let expected = object.expectedSize {XCTAssertEqual(Int64(bytes.count),expected)}
                verifiedBytes = try budget.adding(Int64(bytes.count),to:verifiedBytes)
                try bytes.write(to:destination,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:object.executable ? 0o700 : 0o600],ofItemAtPath:destination.path)
            } else {
                let target = try XCTUnwrap(object.linkTarget)
                XCTAssertEqual(try sourceFiles.linkTarget(object.relativePath),target)
                try FileManager.default.createSymbolicLink(atPath:destination.path,withDestinationPath:target)
            }
        }
        // No pre-bootstrap SQL rewrite: qualify the exact copied records through
        // the protected protocol-3 migration itself.
        let rehearsal = try DatabaseQueue(path:run.appendingPathComponent("checklist.sqlite").path,configuration:read)
        let ownedFiles = try StorageObjectFiles(root:run)
        var relocatedFields = 0, groupLabelRecords = 0
        var expectedRecords: [Int64:(data: String, revision: Int)] = [:], expectedBindings: [Data:String] = [:]
        let expectedDigest = try rehearsal.read { db -> String in
            XCTAssertEqual(try conserved(db), inspected.1, "The seeded database retains every original row and byte.")
            let plan = try ManagedPathRelocation.plan(db,root:run,budget:budget)
            let inventory = try StorageSnapshotAuthority.inventory(db,root:run,budget:budget,retainedExists:{try ownedFiles.regularOrLinkExists($0)})
            XCTAssertEqual(inventory.objects, inspected.3.objects)
            let rows = try Row.fetchAll(db,sql:"SELECT rowid,type,project_id,revision,data FROM records ORDER BY rowid")
            var expectedObjects: [Int64:JSON] = [:]
            for row in rows {
                let rowID: Int64 = row["rowid"], type: String = row["type"], raw: String = row["data"]
                var value = jsonObject(raw), fields: [(String,String)] = []
                switch type {
                case "attachment" where value["mode"] as? String == "managed": fields = [("path","objects"),("preview_path","objects")]
                case "project": fields = [("icon_path","icons")]
                case "source_capture": fields = [("snapshot_path","source-captures")]
                case "source_execution": fields = [("output_path","source-executions"),("working_directory","source-captures")]
                case "manifest":
                    if let evidence = value["evidence"] as? JSON, let capture = evidence["source_capture"] as? JSON,
                       let stored = capture["snapshot_path"] as? String,
                       let relative = try plan.decision(stored,family:"source-captures",root:run).relative { expectedBindings[Data(stored.utf8)] = relative }
                default: break
                }
                var changed = false
                for (key,family) in fields {
                    if let stored = value[key] as? String, let relative = try plan.decision(stored,family:family,root:run).relative,
                       Data(stored.utf8) != Data(relative.utf8) { value[key] = relative; changed = true; relocatedFields += 1 }
                }
                // Only declared mutable path fields may change. Immutable manifest
                // bytes, revisions, every other column and other JSON fields stay exact.
                if changed { expectedObjects[rowID] = value }
            }
            // Full startup also runs the existing CL-166 additive label backfill.
            // Predict only its declared counters, missing group keys and revision
            // increments. All other record fields and SQL cells remain conserved.
            for row in rows where row["type"] as String == "project" {
                let rowID: Int64 = row["rowid"]
                var project = expectedObjects[rowID] ?? jsonObject(row["data"] as String)
                let original = try jsonString(project)
                let projectID = project["id"] as! String
                let groups = rows.filter { $0["type"] as String == "group" && $0["project_id"] as String? == projectID }
                for kind in ["triage", "epic"] {
                    let marker = kind == "triage" ? "T" : "E", counter = "next_" + kind + "_number"
                    let groupObjects = groups.map { jsonObject($0["data"] as String) }
                    var number = try GroupKeys.next(project, groups: groupObjects, kind: kind)
                    let missing = groups.filter {
                        let group = jsonObject($0["data"] as String)
                        return group["kind"] as? String == kind && (group["key"] as? String ?? "").isEmpty
                    }.sorted {
                        let a = jsonObject($0["data"] as String), b = jsonObject($1["data"] as String)
                        let first = a["created_at"] as? String ?? "", second = b["created_at"] as? String ?? ""
                        return first.utf8.elementsEqual(second.utf8) ? (a["id"] as! String).utf8.lexicographicallyPrecedes((b["id"] as! String).utf8) : first.utf8.lexicographicallyPrecedes(second.utf8)
                    }
                    for groupRow in missing {
                        var group = jsonObject(groupRow["data"] as String)
                        group["key"] = "\(project["key_prefix"] as? String ?? "TASK")-\(marker)\(number)"
                        group["revision"] = int(group,"revision") + 1
                        expectedObjects[groupRow["rowid"] as Int64] = group
                        groupLabelRecords += 1; number += 1
                    }
                    project[counter] = number
                }
                if try jsonString(project) != original {
                    project["revision"] = int(project,"revision") + 1
                    expectedObjects[rowID] = project; groupLabelRecords += 1
                }
            }
            for (rowID, value) in expectedObjects {
                expectedRecords[rowID] = (try jsonString(value), int(value,"revision"))
            }
            return try conserved(db,expectedRecords:expectedRecords)
        }
        try rehearsal.close()
        let bootstrapStart = ProcessInfo.processInfo.systemUptime
        let lease = try StorageServiceLease(root:run),opened = try StorageBootstrap.open(root:run,serviceLease:lease)
        let (protected, migratedDigest) = try opened.queue.read {db -> (JSON,String) in
            let actualDigest = try conserved(db)
            XCTAssertEqual(actualDigest,expectedDigest)
            XCTAssertEqual(try ManagedPathRelocation.captureBindings(db,root:run),expectedBindings)
            _ = try SchemaMigrations.inspect(db)
            XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),3)
            XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            return (jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'"))), actualDigest)
        }
        try opened.queue.close()
        let generation = URL(fileURLWithPath:try XCTUnwrap(protected["path"] as? String),isDirectory:true)
        let manifestBytes = try Data(contentsOf:generation.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:manifestBytes)
        XCTAssertEqual(ChecklistCore.hash(manifestBytes),protected["manifest_sha256"] as? String)
        XCTAssertEqual(manifest.schema,0)
        XCTAssertEqual(manifest.objects.count,inspected.3.objects.count)
        XCTAssertEqual(manifest.sourceRoot,run.path)
        XCTAssertEqual(protected["protected"] as? Bool,true)
        let ready = try StoreIdentityReceipt.decode(Data(contentsOf:run.appendingPathComponent(StoreIdentityReceipt.fileName)))
        XCTAssertEqual(ready.state,"ready");XCTAssertEqual(ready.schema_revision,3);XCTAssertEqual(ready.incarnation,inspected.0)
        XCTAssertEqual(manifest.storeID,ready.logical_store_id)
        XCTAssertEqual(protected["target_migration_checksum"] as? String,SchemaMigrations.managedPathsChecksum)
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:input)),inputSHA,"The retained input copy remains unchanged.")
        let result:JSON = ["input_sha256":inputSHA,"records_decoded":inspected.2,"objects_verified":inspected.3.objects.count,"object_bytes_verified":verifiedBytes,"schema":3,"bootstrap_opened":true,"input_domain_digest":inspected.1,"expected_migrated_domain_digest":expectedDigest,"migrated_domain_digest":migratedDigest,"conservation_matches":migratedDigest == expectedDigest,"relocated_managed_path_fields":relocatedFields,"immutable_capture_bindings":expectedBindings.count,"additive_group_label_records":groupLabelRecords,"full_bootstrap_seconds":ProcessInfo.processInfo.systemUptime - bootstrapStart,"protected_manifest_sha256":ChecklistCore.hash(manifestBytes),"protected_objects":manifest.objects.count,"source_access":"read-only descriptors/bytes; independent copied fixture objects; no source SQL or filesystem writes","limit":"Real full protected snapshot/rehearsal/migration on owned relocated copy; no live restore/authority promotion or cloned service."]
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:run.appendingPathComponent("qualification-result.json"))
        print("CL19 retained-domain compatibility result: " + run.appendingPathComponent("qualification-result.json").path)
    }
    func testReleasedStoreIsRehearsedProtectedMigratedAndOldCoreRefuses() throws {
        let f = try StorageFixture(open:false),project = try f.seedReleased()
        try f.reopen()
        let pid = project["id"] as! String
        let pointer = try f.router!.dbQueue.read {db -> JSON in
            XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),3)
            _ = try SchemaMigrations.inspect(db)
            XCTAssertEqual(try f.router!.record(db,pid,type:"project")["name"] as? String,"Released storage")
            return jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")!)
        }
        let path = URL(fileURLWithPath:pointer["path"] as! String),op = UUID(uuidString:pointer["operation_id"] as! String)!
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:path.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schema,0,"Protected generation precedes baseline enrollment writes")
        let receipt = try StorageSnapshot.reconcile(parent:path.deletingLastPathComponent(),operation:op,budget:.init(deadlineUptime:ProcessInfo.processInfo.systemUptime + 10,canceled:{false}))
        XCTAssertEqual(receipt.manifestSHA256,pointer["manifest_sha256"] as? String)
        let before = try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
        let old = try f.spawn("released-open");try f.finish(old);XCTAssertEqual(old.terminationStatus,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("old-refusal").path))
        XCTAssertEqual(try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)},before)
        try f.close();try f.reopen()
        XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")["name"] as? String},"Released storage")
    }
    func testActualReleasedFinalSQLToUnlinkCannotOverlapMigration() throws {
        let f = try StorageFixture(open:false)
        // Old native startup prepares this exact owned root before taking its lock.
        try FileManager.default.createDirectory(at:f.root,withIntermediateDirectories:true)
        let child = try f.spawn("released-paused-unlink")
        defer {if child.isRunning {_ = Darwin.kill(child.processIdentifier,SIGKILL)};try? f.finish(child,seconds:3)}
        let end = ProcessInfo.processInfo.systemUptime + 20,ready = f.base.appendingPathComponent("ready")
        while !FileManager.default.fileExists(atPath:ready.path),child.isRunning,ProcessInfo.processInfo.systemUptime < end {usleep(10_000)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path),"The unchanged released cleanup did not reach its final-read seam")
        guard FileManager.default.fileExists(atPath:ready.path) else {return}
        let original = try String(contentsOf:f.base.appendingPathComponent("paused-original-path"),encoding:.utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        XCTAssertThrowsError(try StorageServiceLease(root:f.root)) {XCTAssertEqual(($0 as? CoreError)?.code,"STORE_BUSY")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(StoreIdentityReceipt.fileName).path))
        _ = Darwin.kill(child.processIdentifier,SIGKILL);try f.finish(child,seconds:3)
        XCTAssertFalse(child.isRunning);XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        try f.reopen()
        XCTAssertTrue(FileManager.default.fileExists(atPath:original),"Killed old continuation cannot execute later")
        XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"PRAGMA user_version")},3)
    }
    func testMigrationDeathBeforeAndAfterCommitRepairsForwardWithoutReplacingUserData() throws {
        for mode in ["migration-before-commit","migration-committed"] {
            let f = try StorageFixture(open:false),project = try f.seedReleased(),pid = project["id"] as! String
            let child = try f.spawn(mode);try f.finish(child,seconds:30)
            XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
            XCTAssertEqual(try String(contentsOf:f.base.appendingPathComponent("ready"),encoding:.utf8),mode)
            let preparing = try StoreIdentityReceipt.decode(Data(contentsOf:f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
            XCTAssertEqual(preparing.state,"preparing");XCTAssertEqual(preparing.schema_revision,3)
            try f.reopen()
            let ready = try StoreIdentityReceipt.decode(Data(contentsOf:f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
            XCTAssertEqual(ready.state,"ready");XCTAssertEqual(ready.logical_store_id,preparing.logical_store_id);XCTAssertEqual(ready.incarnation,preparing.incarnation)
            try f.router!.dbQueue.read {db in
                XCTAssertEqual(try f.router!.record(db,pid,type:"project")["name"] as? String,"Released storage")
                XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),3)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE id=?",arguments:[pid]),1)
                XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            }
            let task = try f.task(project),tid = task["id"] as! String
            try f.close();try f.reopen()
            XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.record($0,tid,type:"task")["title"] as? String},"Storage invariant","A later committed task survives repeated recovery; no backup restore replaces it")
        }
    }
    func testUnknownSchemaChecksumAndMissingDatabaseNeverBecomeEmptyStore() throws {
        let f = try StorageFixture(),p = try f.project(),pid = p["id"] as! String
        try f.router!.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value='[]' WHERE key='schema_migrations'")}
        try f.close()
        let db = f.root.appendingPathComponent("checklist.sqlite"),before = try Data(contentsOf:db)
        XCTAssertThrowsError(try f.reopen())
        XCTAssertEqual(try Data(contentsOf:db),before)
        // Explicit fixture repair changes only the known damaged ledger. It is
        // not a production auto-repair path or a rollback over later user writes.
        var config = Configuration();config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let q = try DatabaseQueue(path:try StorageBootstrap.writableURI(db),configuration:config)
        try q.write {try $0.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString([SchemaMigrations.ledger,SchemaMigrations.protocolLedger,SchemaMigrations.managedPathsLedger])])};try q.close()
        try f.reopen();XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")["name"] as? String},p["name"] as? String)
        try f.close();try FileManager.default.moveItem(at:db,to:f.base.appendingPathComponent("preserved.sqlite"))
        XCTAssertThrowsError(try f.reopen())
        XCTAssertFalse(FileManager.default.fileExists(atPath:db.path))
    }
}
