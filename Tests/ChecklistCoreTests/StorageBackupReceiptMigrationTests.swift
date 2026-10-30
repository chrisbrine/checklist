import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

final class StorageBackupReceiptMigrationTests: XCTestCase {
    private func identity(_ db: Database) throws -> StoreIdentityReceipt {
        try StoreIdentityReceipt.decode(Data(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'")).utf8))
    }
    private func downgrade(_ f: StorageFixture) throws {
        let old = try f.router!.dbQueue.write {db -> StoreIdentityReceipt in
            let old = try identity(db).withSchema(4)
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try old.encoded(),as:UTF8.self)])
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString(SchemaMigrations.ledgers(4))])
            try db.execute(sql:"PRAGMA user_version=4")
            return old
        }
        try StoreDirectory(root:f.root).publishReceipt(old.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
    }
    @discardableResult private func receipt(_ f: StorageFixture, count: Int = 3, absolute: Bool = false) throws -> (String,URL,String) {
        let operation = uuid(),path = f.root.appendingPathComponent("backups/snapshot-" + operation)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        let store = try f.router!.dbQueue.read {try identity($0)}
        let objects = (0..<count).map {i -> StorageSnapshotMaterializedObject in
            let bytes = Data("historical-\(i)".utf8),sha = ChecklistCore.hash(bytes)
            let descriptor = StorageSnapshotObject(relativePath:"objects/history/\(i)",kind:"file",expectedSHA256:sha,expectedSize:Int64(bytes.count),executable:false,linkTarget:nil,authorities:["attachment:history:\(i)"])
            return .init(descriptor:descriptor,sha256:sha,size:Int64(bytes.count))
        }
        let manifest = StorageSnapshotManifest(format:2,kind:StorageSnapshot.kind,operationID:operation,storeID:store.logical_store_id,sourceRoot:f.root.path,schema:4,databaseSHA256:String(repeating:"a",count:64),databaseSize:1,objects:objects,unavailable:[],externalReferences:[])
        let bytes = try StorageSnapshot.encoded(manifest),sha = ChecklistCore.hash(bytes)
        try bytes.write(to:path.appendingPathComponent("manifest.json"))
        let summary: JSON = ["path":path.path,"store_id":store.logical_store_id,"source_root":f.root.path,"manifest_sha256":sha,"verification":"manifest_database_managed_files","verified_at":now()]
        let value: JSON = ["format":1,"state":"complete","operation_id":operation,"manifest_sha256":sha,"summary":summary,"known_at":now(),"current_physical_verified":false,
            "objects":objects.map {["path":absolute ? f.root.path + "/" + $0.descriptor.relativePath : $0.descriptor.relativePath,"sha256":$0.sha256,"size":$0.size]}]
        let key = "backup-generation:" + operation,raw = try jsonString(value)
        try f.router!.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:[key,raw])}
        return (key,path,raw)
    }
    private func upgrade(_ f: StorageFixture) throws {
        try f.router!.dbQueue.write {db in
            try SchemaMigrations.upgradeBackupReceipts(db,identity:identity(db).withSchema(5),root:f.root,protectedSnapshot:["fresh_store":true])
        }
    }
    func testExactManifestBindingsReplaceObjectsAndPhysicalCompactionPreservesRows() throws {
        let f = try StorageFixture()
        let first = try receipt(f),second = try receipt(f,count:2,absolute:true)
        try f.router!.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value=json_remove(value,'$.summary.store_id','$.summary.source_root') WHERE key=?",arguments:[first.0])}
        try downgrade(f)
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(rowid,key,value) VALUES (100000,'unrelated-project-proof','keep exact bytes')")
            try db.execute(sql:"INSERT INTO commands(rowid,principal,command_id,digest,result) VALUES (100000,'migration-test','command','digest','{}')")
        }
        let manifestHashes = try [first.1,second.1].map {ChecklistCore.hash(try Data(contentsOf:$0.appendingPathComponent("manifest.json")))}
        try upgrade(f)
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
            for (key,_,_) in [first,second] {
                let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])),value = jsonObject(raw)
                XCTAssertNil(value["objects"]);XCTAssertEqual(value["format"] as? Int,2)
                XCTAssertNotNil(value["manifest_index"] as? JSON)
                XCTAssertEqual((value["summary"] as? JSON)?["store_id"] as? String,try identity(db).logical_store_id)
                XCTAssertEqual((value["summary"] as? JSON)?["source_root"] as? String,f.root.path)
                XCTAssertEqual(value["object_count"] as? Int,key == first.0 ? 3 : 2)
                XCTAssertGreaterThan(value["object_bytes"] as? Int ?? 0,0)
                XCTAssertLessThan(raw.utf8.count,2048)
            }
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[StorageBackupReceiptMigration.vacuumKey]),"pending")
        }
        try StorageBackupReceiptMigration.finishCompaction(f.router!.dbQueue)
        try StorageBackupReceiptMigration.finishCompaction(f.router!.dbQueue)
        try f.router!.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[StorageBackupReceiptMigration.vacuumKey]))
            XCTAssertEqual(try Int64.fetchOne(db,sql:"SELECT rowid FROM metadata WHERE key='unrelated-project-proof'"),100000)
            XCTAssertEqual(try Int64.fetchOne(db,sql:"SELECT rowid FROM commands WHERE principal='migration-test'"),100000)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='unrelated-project-proof'"),"keep exact bytes")
            XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
        }
        XCTAssertEqual(try [first.1,second.1].map {ChecklistCore.hash(try Data(contentsOf:$0.appendingPathComponent("manifest.json")))},manifestHashes)
    }
    func testMissingOrChangedManifestPreservesExactRawCatalogWithoutCopyAuthority() throws {
        for changed in [false,true] {
            let f = try StorageFixture(),first = try receipt(f),second = try receipt(f)
            try downgrade(f)
            let target = second.1.appendingPathComponent("manifest.json")
            if changed {try Data("changed".utf8).write(to:target)} else {try FileManager.default.removeItem(at:target)}
            try upgrade(f)
            let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[second.0])))}
            XCTAssertNotNil(value["historical_catalog"])
            XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),second.2)
            XCTAssertNil(try StorageBackupAccountingCache.parseReceipt(try jsonString(value),root:f.root).copy)
            let generation = try StorageBackupManifestIndex.generation(value,root:f.root)
            XCTAssertFalse(generation.independent)
            try f.router!.dbQueue.read {db in
                XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
                let valid = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[first.0])))
                XCTAssertNil(valid["historical_catalog"])
            }
        }
    }
    func testForeignAbsolutePathCannotSupplyMissingLocalManifest() throws {
        let f = try StorageFixture(),r = try receipt(f)
        let foreign = f.base.appendingPathComponent("foreign").appendingPathComponent(r.1.lastPathComponent)
        try FileManager.default.createDirectory(at:foreign.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:r.1,to:foreign)
        let original = try f.router!.dbQueue.write {db -> String in
            try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.summary.path',?) WHERE key=?",arguments:[foreign.path,r.0])
            return try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0]))
        }
        try downgrade(f);try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),original)
        XCTAssertFalse(try StorageBackupManifestIndex.generation(value,root:f.root).independent)
    }
    func testFallbackPreviewNeverInspectsForeignSnapshot() throws {
        let f = try StorageFixture(),r = try receipt(f)
        let foreign = f.base.appendingPathComponent("foreign").appendingPathComponent(r.1.lastPathComponent)
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
        try Data("must never be read".utf8).write(to:foreign.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at:r.1)
        try f.router!.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value=json_set(value,'$.summary.path',?) WHERE key=?",arguments:[foreign.path,r.0])}
        try downgrade(f);try upgrade(f)
        let preview = try f.router!.backupPrunePreview()
        let entry = try XCTUnwrap((preview["snapshots"] as? [JSON])?.first {$0["path"] as? String == foreign.path})
        XCTAssertEqual(entry["state"] as? String,"incomplete")
        XCTAssertEqual(entry["prune"] as? Bool,false)
        XCTAssertNil(entry["device"]);XCTAssertNil(entry["inode"])
        let reasons = entry["keep_reasons"] as? [String] ?? []
        XCTAssertTrue(reasons.contains("outside_managed_backups"))
        XCTAssertFalse(reasons.contains("manifest_changed"));XCTAssertFalse(reasons.contains("manifest_unavailable_or_in_use"))
        XCTAssertEqual(entry["manifest_sha256"] as? String,jsonObject(r.2)["manifest_sha256"] as? String)
    }
    func testLocalManifestRebindsForeignPathOnlyAfterExactVerification() throws {
        let f = try StorageFixture(),r = try receipt(f)
        let foreign = f.base.appendingPathComponent("foreign").appendingPathComponent(r.1.lastPathComponent)
        try f.router!.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value=json_set(value,'$.summary.path',?) WHERE key=?",arguments:[foreign.path,r.0])}
        try downgrade(f);try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertNil(value["historical_catalog"])
        XCTAssertEqual((value["summary"] as? JSON)?["path"] as? String,r.1.path)
        XCTAssertTrue(try StorageBackupManifestIndex.generation(value,root:f.root).independent)
    }
    func testForeignTraversalFallsBackToExactRawCatalogEvenWithLocalManifest() throws {
        let f = try StorageFixture(),r = try receipt(f)
        let original = try f.router!.dbQueue.write {db -> String in
            try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.summary.path',?) WHERE key=?",arguments:["/previous/../backups/" + r.1.lastPathComponent,r.0])
            return try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0]))
        }
        try downgrade(f);try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),original)
        XCTAssertFalse(try StorageBackupManifestIndex.generation(value,root:f.root).independent)
    }
    func testSymlinkedLocalManifestFallsBackWithoutFollowingIt() throws {
        let f = try StorageFixture(),r = try receipt(f)
        let manifest = r.1.appendingPathComponent("manifest.json"),foreign = f.base.appendingPathComponent("foreign.json")
        try FileManager.default.moveItem(at:manifest,to:foreign)
        try FileManager.default.createSymbolicLink(at:manifest,withDestinationURL:foreign)
        try downgrade(f);try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertNotNil(value["historical_catalog"])
        XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),r.2)
    }
    func testInterruptedCatalogPublicationNeverLeavesPartialFinalName() throws {
        for phase in ["catalog_staged","catalog_published"] {
            let f = try StorageFixture(),r = try receipt(f)
            try FileManager.default.removeItem(at:r.1)
            try downgrade(f)
            StorageBackupManifestIndex.historicalCatalogObserve = {if $0 == phase {throw StorageSnapshotFailure.canceled}}
            defer {StorageBackupManifestIndex.historicalCatalogObserve = nil}
            XCTAssertThrowsError(try upgrade(f))
            StorageBackupManifestIndex.historicalCatalogObserve = nil
            let path = f.root.appendingPathComponent("objects/backup-catalogs/" + ChecklistCore.hash(Data(r.2.utf8)) + ".json")
            if phase == "catalog_staged" {XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))}
            else {XCTAssertEqual(try Data(contentsOf:path),Data(r.2.utf8))}
            try upgrade(f)
            let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
            XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),r.2)
        }
    }
    func testSummarylessLegacyPreservesExactHistoricalCatalogWithoutCopyAuthority() throws {
        let f = try StorageFixture(),r = try receipt(f)
        try downgrade(f)
        let original = try f.router!.dbQueue.write {db -> String in
            try db.execute(sql:"UPDATE metadata SET value=json_remove(value,'$.summary') WHERE key=?",arguments:[r.0])
            return try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0]))
        }
        try FileManager.default.removeItem(at:r.1)
        try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertNil(value["objects"]);XCTAssertNil(value["summary"])
        XCTAssertEqual(value["manifest_sha256"] as? String,jsonObject(original)["manifest_sha256"] as? String)
        let catalog = try XCTUnwrap(value["historical_catalog"] as? JSON)
        let catalogBinding = try f.router!.dbQueue.read {db in try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-historical-catalog:" + (value["operation_id"] as! String)]))}
        XCTAssertEqual(catalogBinding,try jsonString(catalog),"Future snapshots discover the compact binding without parsing old full receipts.")
        let bytes = try Data(contentsOf:f.root.appendingPathComponent(try XCTUnwrap(catalog["path"] as? String)))
        XCTAssertEqual(bytes,Data(original.utf8),"The equally safe catalog preserves every original receipt byte.")
        XCTAssertEqual(ChecklistCore.hash(bytes),catalog["sha256"] as? String)
        XCTAssertEqual(value["object_count"] as? Int,3)
        XCTAssertNotNil(value["manifest_index"] as? JSON)
        XCTAssertEqual(value["current_physical_verified"] as? Bool,false)
    }
    func testManifestDoesNotAuthorizeDroppingDifferentHistoricalObjects() throws {
        let f = try StorageFixture(),r = try receipt(f)
        try downgrade(f)
        let original = try f.router!.dbQueue.write {db -> String in
            try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.objects[1].sha256',?) WHERE key=?",arguments:[String(repeating:"0",count:64),r.0])
            return try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0]))
        }
        try upgrade(f)
        let value = try f.router!.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))}
        XCTAssertNotNil(value["historical_catalog"])
        XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),original)
        XCTAssertFalse(try StorageBackupManifestIndex.generation(value,root:f.root).independent)
    }
    func testBootstrapRehearsesProtectsAndRetainsPriorProtectedSnapshot() throws {
        let f = try StorageFixture(),r = try receipt(f)
        try downgrade(f)
        let prior: JSON = ["operation_id":uuid(),"path":f.base.appendingPathComponent("prior-protected").path,"manifest_sha256":String(repeating:"b",count:64),"protected":true]
        try f.router!.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(prior)])}
        try f.close();try f.reopen()
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
            XCTAssertNil(jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))["objects"])
            let protected = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")))
            XCTAssertEqual(protected["protected"] as? Bool,true)
            XCTAssertEqual(protected["target_migration_checksum"] as? String,SchemaMigrations.backupReceiptChecksum)
            let history = try JSONSerialization.jsonObject(with:Data(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-protected-history'")).utf8)) as? [JSON]
            XCTAssertEqual(history?.first?["operation_id"] as? String,prior["operation_id"] as? String)
            let snapshot = URL(fileURLWithPath:try XCTUnwrap(protected["path"] as? String))
            var read = Configuration();read.readonly = true;read.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
            let backup = try DatabaseQueue(path:snapshot.appendingPathComponent("database.sqlite").path,configuration:read)
            defer {try? backup.close()}
            XCTAssertEqual(try backup.read {try Int.fetchOne($0,sql:"PRAGMA user_version")},4,"Rollback is the protected schema4 snapshot, not a down migration.")
            XCTAssertEqual(try backup.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])},r.2)
        }
    }
    func testCatalogProcessDeathBeforeAndAfterPublicationResumes() throws {
        for mode in ["migration-catalog-staged","migration-catalog-published"] {
            let f = try StorageFixture(),r = try receipt(f)
            try FileManager.default.removeItem(at:r.1)
            try downgrade(f);try f.close()
            let child = try f.spawn(mode);try f.finish(child,seconds:60)
            XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
            try f.reopen()
            let value = try f.router!.dbQueue.read {db in
                XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
                XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
                return jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))
            }
            XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(value,root:f.root),r.2)
        }
    }
    func testSchema5DeathBeforeAndAfterCommitRepairsWithoutLosingReceipts() throws {
        for mode in ["migration-before-commit","migration-committed"] {
            let f = try StorageFixture(),r = try receipt(f)
            try downgrade(f);try f.close()
            let child = try f.spawn(mode);try f.finish(child,seconds:60)
            XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
            let preparing = try StoreIdentityReceipt.decode(Data(contentsOf:f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
            XCTAssertEqual(preparing.schema_revision,5);XCTAssertEqual(preparing.state,"preparing")
            try f.reopen()
            let ready = try StoreIdentityReceipt.decode(Data(contentsOf:f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
            XCTAssertEqual(ready.schema_revision,5);XCTAssertEqual(ready.state,"ready")
            try f.router!.dbQueue.read {db in
                XCTAssertNil(jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[r.0])))["objects"])
                XCTAssertEqual(try Int.fetchOne(db,sql:"PRAGMA user_version"),5)
                XCTAssertNil(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[StorageBackupReceiptMigration.vacuumKey]))
                XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
            }
        }
    }
}
