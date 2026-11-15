import ChecklistTestSupport
import XCTest
import Foundation
import Darwin
import GRDB
import CryptoKit
@testable import ChecklistCore

final class DeliveryLookupMigrationTests: XCTestCase {
    private func physicalPath(_ path: String) throws -> String {
        guard let physical = Darwin.realpath(path,nil) else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","The qualification directory must exist.",details:["path":path,"errno":errno])
        }
        defer {free(physical)}
        return String(cString:physical)
    }
    private func physicalOutputPath(_ output: URL) throws -> String {
        try physicalPath(output.deletingLastPathComponent().path) + "/" + output.lastPathComponent
    }
    func testQualificationPathsKeepPhysicalTmpAliasesEqual() throws {
        XCTAssertEqual(try physicalPath("/tmp"),try physicalPath("/private/tmp"))
        let alias = try physicalOutputPath(URL(fileURLWithPath:"/tmp/CL462-path-only-result.json"))
        let physical = try physicalOutputPath(URL(fileURLWithPath:"/private/tmp/CL462-path-only-result.json"))
        XCTAssertEqual(alias,physical)
        XCTAssertTrue(physical.split(separator:"/").starts(with:try physicalPath("/tmp").split(separator:"/")))
    }
    private func identity(_ db: Database) throws -> StoreIdentityReceipt {
        try StoreIdentityReceipt.decode(Data(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'")).utf8))
    }
    private func schemaFive() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:SchemaMigrations.currentSQL)
            let value = StoreIdentityReceipt(format_version:1,logical_store_id:uuid(),incarnation:uuid(),database_generation:1,schema_revision:5,state:"ready")
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('incarnation',?),('store_identity',?),('schema_migrations',?),('retained','byte-exact')",arguments:[value.incarnation,String(decoding:try value.encoded(),as:UTF8.self),try jsonString(SchemaMigrations.ledgers(5))])
            for i in 0..<48 {
                let delivery: JSON = ["id":"retained-\(i)","project_id":"project","revision":1,"message_id":"message-\(i % 7)",
                    "recipient_session_id":"session-\(i % 3)","recipient_authorization_generation":"generation-\(i % 2)","state":"queued","body":"retained\0é e\u{301}"]
                try db.execute(sql:"INSERT INTO records(rowid,id,project_id,type,revision,data) VALUES (?,?,?,'delivery',1,?)",arguments:[Int64(100+i),delivery["id"] as! String,"project",try jsonString(delivery)])
            }
            try db.execute(sql:"INSERT INTO commands(rowid,principal,command_id,digest,result) VALUES (91,'principal','command','digest','{\"retained\":true}')")
            try db.execute(sql:"INSERT INTO events(seq,id,actor,kind,occurred_at,data) VALUES (301,'event','actor','retained','2026-11-14T00:00:00Z','{}')")
            try db.execute(sql:"UPDATE sqlite_sequence SET seq=901 WHERE name='events'")
            try db.execute(sql:"INSERT INTO cursors VALUES ('cursor','principal','scope',301,?,0)",arguments:[value.incarnation])
            try db.execute(sql:"PRAGMA user_version=5")
        }
        return queue
    }
    /// Stream all retained domain columns with SQLite types and complete bytes.
    private func domainDigest(_ db: Database) throws -> String {
        var digest = SHA256()
        func feed(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of:&length) {digest.update(data:Data($0))}
            digest.update(data:bytes)
        }
        for table in ["records","commands","events","cursors","sqlite_sequence"] {
            feed(Data(table.utf8))
            let columns = ["rowid"] + (try Row.fetchAll(db,sql:"PRAGMA table_info(" + table + ")")).map {$0["name"] as String}
            let fields = columns.flatMap {["typeof(" + $0 + ")","CAST(" + $0 + " AS BLOB)"]}.joined(separator:",")
            let rows = try Row.fetchCursor(db,sql:"SELECT " + fields + " FROM " + table + " ORDER BY rowid")
            while let row = try rows.next() {
                for i in columns.indices {
                    feed(Data((row[i*2] as String).utf8))
                    feed((row[i*2+1] as Data?) ?? Data())
                }
            }
        }
        return digest.finalize().map {String(format:"%02x",$0)}.joined()
    }
    func testSchemaSixIndexesPreserveRetainedBytesAndProtectedHistory() throws {
        let queue = try schemaFive();defer {try? queue.close()}
        try queue.write { db in
            let original = try identity(db),before = try domainDigest(db)
            let prior: JSON = ["operation_id":uuid(),"protected":true,"manifest_sha256":"prior"]
            let protected: JSON = ["operation_id":uuid(),"protected":true,"manifest_sha256":"current"]
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?)",arguments:[try jsonString(prior)])
            var timings: [String] = []
            try SchemaMigrations.upgradeDeliveryLookups(db,identity:original.withSchema(6),protectedSnapshot:protected,observe:{phase,seconds in
                timings.append(phase);XCTAssertGreaterThanOrEqual(seconds,0)
            })
            XCTAssertEqual(timings,["migration.delivery-index-build"])
            XCTAssertEqual(try domainDigest(db),before)
            XCTAssertEqual(try identity(db),original.withSchema(6))
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='retained'"),"byte-exact")
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'"),try jsonString(protected))
            let history = jsonObjectArray(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-protected-history'")))
            XCTAssertEqual(try jsonString(history),try jsonString([prior]))
            XCTAssertEqual(try Int64.fetchOne(db,sql:"SELECT seq FROM sqlite_sequence WHERE name='events'"),901)
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[StorageBackupReceiptMigration.vacuumKey]))
            XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            XCTAssertThrowsError(try SchemaMigrations.upgradeDeliveryLookups(db,identity:original.withSchema(6),protectedSnapshot:protected))
            // The index expression and partial predicate are part of the checked container.
            try db.execute(sql:"DROP INDEX records_delivery_message; CREATE INDEX records_delivery_message ON records(project_id) WHERE type='delivery'")
            XCTAssertThrowsError(try SchemaMigrations.inspect(db))
        }
    }
    func testInterruptedIndexTransactionLeavesSchemaFiveIntact() throws {
        enum Stop: Error {case beforeCommit}
        let queue = try schemaFive();defer {try? queue.close()}
        let before = try queue.read {try SchemaMigrations.contentFingerprint($0)}
        XCTAssertThrowsError(try queue.write { db in
            try SchemaMigrations.upgradeDeliveryLookups(db,identity:identity(db).withSchema(6),protectedSnapshot:["fresh_store":true])
            throw Stop.beforeCommit
        })
        try queue.read { db in
            XCTAssertEqual(try SchemaMigrations.contentFingerprint(db),before)
            XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM sqlite_master WHERE name IN ('records_delivery_message','records_delivery_recipient_generation')"),0)
            _ = try SchemaMigrations.inspect(db)
        }
    }
    func testSchemaFiveStartupProtectsSourceAndRestartKeepsIndexes() throws {
        let f = try StorageFixture(),project = try f.project()
        _ = try f.task(project)
        let old = try f.router!.dbQueue.write {db -> StoreIdentityReceipt in
            let old = try identity(db).withSchema(5)
            try db.execute(sql:"DROP INDEX records_delivery_message; DROP INDEX records_delivery_recipient_generation")
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try old.encoded(),as:UTF8.self)])
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString(SchemaMigrations.ledgers(5))])
            try db.execute(sql:"PRAGMA user_version=5")
            return old
        }
        try StoreDirectory(root:f.root).publishReceipt(old.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
        let before = try f.router!.dbQueue.read {try domainDigest($0)}
        try f.close()
        let lease = try StorageServiceLease(root:f.root)
        let opened = try StorageBootstrap.open(root:f.root,serviceLease:lease)
        let fingerprint = try opened.queue.read {db -> String in
            XCTAssertEqual(try domainDigest(db),before)
            XCTAssertEqual(try identity(db),old.withSchema(6))
            let protected = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")))
            XCTAssertEqual(protected["protected"] as? Bool,true)
            XCTAssertEqual(protected["target_migration_checksum"] as? String,SchemaMigrations.deliveryLookupChecksum)
            var configuration = Configuration();configuration.readonly = true
            configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
            let backup = try DatabaseQueue(path:URL(fileURLWithPath:try XCTUnwrap(protected["path"] as? String)).appendingPathComponent("database.sqlite").path,configuration:configuration)
            defer {try? backup.close()}
            try backup.read {db in
                XCTAssertEqual(try identity(db),old)
                XCTAssertEqual(try domainDigest(db),before)
            }
            return try SchemaMigrations.contentFingerprint(db)
        }
        try opened.queue.close()
        let restarted = try StorageBootstrap.open(root:f.root,serviceLease:lease)
        defer {try? restarted.queue.close();withExtendedLifetime(lease) {}}
        XCTAssertEqual(try restarted.queue.read {try SchemaMigrations.contentFingerprint($0)},fingerprint)
    }
    func testOwnedSchemaFiveCopyQualifiesProtectedStartup() throws {
        try QualificationSuite.requireEnabled()
        let environment = ProcessInfo.processInfo.environment
        guard let selected = environment["CHECKLIST_CL462_INDEX_COPY"],let destination = environment["CHECKLIST_CL462_INDEX_RESULT"] else {
            throw XCTSkip("Requires an explicit fresh owned schema-5 copy and evidence output.")
        }
        let root = URL(fileURLWithPath:selected,isDirectory:true).resolvingSymlinksInPath()
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ChecklistQualification/r12-N",isDirectory:true).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath:destination).resolvingSymlinksInPath()
        let workspace = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        // Foundation may spell an existing workspace /tmp and a not-yet-created
        // result /private/tmp. Compare physical strings before rebuilding URLs.
        let rootPath = try physicalPath(root.path),cachePath = try physicalPath(caches.path)
        let workspacePath = try physicalPath(workspace.path),outputPath = try physicalOutputPath(output)
        guard rootPath.split(separator:"/").starts(with:cachePath.split(separator:"/")),
              outputPath.split(separator:"/").starts(with:workspacePath.split(separator:"/")),
              !outputPath.split(separator:"/").starts(with:(workspacePath + "/src").split(separator:"/")) else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","Use an owned cache copy and private-workspace evidence output.",details:[
                "root":rootPath,"allowed_cache":cachePath,"output":outputPath,"workspace":workspacePath,
                "runtime_current_directory":FileManager.default.currentDirectoryPath])
        }
        let owner = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("cl462-index-owned-copy.json"))) as? JSON
        guard owner?["purpose"] as? String == "CL462-owned-schema5-copy" else {throw CoreError("QUALIFICATION_COPY_REQUIRED","The owned copy marker is missing or wrong.")}
        func load() -> [Double] {var result = [Double](repeating:0,count:3);_ = getloadavg(&result,3);return result}
        let lease = try StorageServiceLease(root:root)
        defer {withExtendedLifetime(lease) {}}
        var read = Configuration();read.readonly = true;read.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let source = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:read)
        let sourceFacts = try source.read {db -> (StoreIdentityReceipt,String,String,Int64,Int64) in
            let value = try identity(db)
            guard value.schema_revision == 5 else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Use an unmigrated schema-5 copy.")}
            _ = try SchemaMigrations.inspect(db)
            return (value,try SchemaMigrations.contentFingerprint(db),try domainDigest(db),try Int64.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='delivery'") ?? 0,
                try Int64.fetchOne(db,sql:"SELECT COALESCE(SUM(length(CAST(data AS BLOB))),0) FROM records WHERE type='delivery'") ?? 0)
        }
        try source.close()
        var result: JSON = ["started_at":now(),"root":root.path,"source_schema":5,"target_schema":6,"source_fingerprint":sourceFacts.1,
            "retained_domain_sha256":sourceFacts.2,"delivery_count":sourceFacts.3,"delivery_json_bytes":sourceFacts.4,"load_start":load(),
            "scope":"Complete protected offline bootstrap on explicit owned schema5 copy; exact staged service launch qualification is separate."]
        var phases: [JSON] = []
        let priorObserver = StorageBootstrap.qualificationObserve
        StorageBootstrap.qualificationObserve = {phase,seconds in phases.append(["phase":phase,"seconds":seconds,"utc":now(),"load":load()])}
        defer {StorageBootstrap.qualificationObserve = priorObserver}
        let started = ProcessInfo.processInfo.systemUptime
        func save() throws {try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)}
        do {
            let opened = try StorageBootstrap.open(root:root,serviceLease:lease)
            defer {try? opened.queue.close()}
            result["bootstrap_seconds"] = ProcessInfo.processInfo.systemUptime-started
            try opened.queue.read { db in
                XCTAssertEqual(try identity(db),sourceFacts.0.withSchema(6))
                let digest = try domainDigest(db)
                XCTAssertEqual(digest,sourceFacts.2)
                result["migrated_domain_sha256"] = digest
                let protected = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")))
                XCTAssertEqual(protected["source_fingerprint"] as? String,sourceFacts.1)
                XCTAssertEqual(protected["target_migration_checksum"] as? String,SchemaMigrations.deliveryLookupChecksum)
                result["protected_backup"] = protected
                result["integrity_check"] = try String.fetchOne(db,sql:"PRAGMA integrity_check")
            }
            result["completed"] = true
        } catch {
            result["completed"] = false;result["error"] = String(describing:error)
            result["bootstrap_seconds"] = ProcessInfo.processInfo.systemUptime-started
            result["phases"] = phases;result["load_end"] = load();try save();throw error
        }
        result["phases"] = phases;result["load_end"] = load();result["finished_at"] = now();try save()
        XCTAssertTrue(phases.contains {$0["phase"] as? String == "migration.delivery-index-build"})
        XCTAssertTrue(phases.contains {$0["phase"] as? String == "protected_snapshot"})
        XCTAssertEqual(result["integrity_check"] as? String,"ok")
    }
    private func jsonObjectArray(_ raw: String) -> [JSON] {
        (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [JSON] ?? []
    }
}
