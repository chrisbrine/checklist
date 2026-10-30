import XCTest
import Foundation
import CryptoKit
import GRDB
import ChecklistTestSupport
@testable import ChecklistCore

final class StorageBackupManifestIndexTests: XCTestCase {
    func testNewestCompletedGenerationPrecedesOlderCopiesWithoutChangingMembership() throws {
        let key = StorageBackupRetentionIndex.key(path:"objects/example",sha:String(repeating:"a",count:64),size:1)
        let bytes = Data(SHA256.hash(data:key))
        let old = StorageBackupManifestIndex.Lookup.Generation(bytes:bytes,count:1,path:"/old/snapshot",manifest:String(repeating:"b",count:64))
        let newest = StorageBackupManifestIndex.Lookup.Generation(bytes:bytes,count:1,path:"/new/snapshot",manifest:String(repeating:"c",count:64))
        let lookup = StorageBackupManifestIndex.Lookup(generations:[old,newest],legacy:nil)
        XCTAssertTrue(lookup.containsOriginal(key));XCTAssertTrue(lookup.hasIndependentCopy(key))
        XCTAssertEqual(Array(lookup.copies(for:key)).map(\.path),[newest.path,old.path])
        XCTAssertEqual(lookup.manifests.count,2)
    }

    func testCleanupIndexPrefersNewestReceiptOverLexicalPathOrder() throws {
        let f = try StorageFixture(),project = try f.project(),task = try f.task(project),router = f.router!
        let original = f.workspace.appendingPathComponent("generation-order.txt")
        try Data("shared generation payload".utf8).write(to:original)
        let attachment = try f.call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":original.path])["data"] as! JSON
        let older = f.base.appendingPathComponent("z-older",isDirectory:true),newest = f.base.appendingPathComponent("a-newest",isDirectory:true)
        for destination in [older,newest] {_ = try router.handle(method:"backup_create",params:["command_id":uuid(),"path":destination.path],caller:f.owner)}
        let path = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let key = StorageBackupRetentionIndex.key(path:path,sha:attachment["sha256"] as! String,size:(attachment["size"] as! NSNumber).int64Value)
        let index = try router.dbQueue.read {try router.ticketCleanupBackupRetentionIndex($0,objects:[])}
        XCTAssertTrue(index.containsOriginal(key));XCTAssertTrue(index.hasIndependentCopy(key))
        XCTAssertEqual(Array(try XCTUnwrap(index.cleanupLookup).copies(for:key)).map(\.path),[newest.path,older.path])
        XCTAssertEqual(index.copyManifests.count,2)
    }

    func testCompactDescriptorLimitRefusesBeforeMissingKeyFilesAreOpened() throws {
        let f = try StorageFixture(),sha = String(repeating:"a",count:64)
        try f.router!.dbQueue.write {db in
            for i in 0..<11 {
                let receipt: JSON = ["format":2,"state":"complete","object_count":1_000_000,
                    "manifest_index":["path":"backups/.indexes/missing-\(i).keys","sha256":sha,"count":1_000_000],
                    "manifest_sha256":sha,"summary":["path":"/private/tmp/absent-snapshot-\(i)","verification":"manifest_database_managed_files","manifest_sha256":sha]]
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + uuid(),try jsonString(receipt)])
            }
        }
        try f.router!.dbQueue.read {db in
            XCTAssertThrowsError(try StorageBackupManifestIndex.warm(db,root:f.root)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
            XCTAssertThrowsError(try StorageBackupAccountingCache.shared(root:f.root).cleanupIndex(db,root:f.root,incarnation:uuid(),limit:64 * 1024 * 1024)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
        }
    }

    func testGenerationLimitRefusesBeforeReadingInvalidReceiptHeaders() throws {
        let f = try StorageFixture()
        try f.router!.dbQueue.write {db in
            for _ in 0..<1025 {try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + uuid(),"not json"])}
        }
        try f.router!.dbQueue.read {db in
            XCTAssertThrowsError(try StorageBackupManifestIndex.warm(db,root:f.root)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
            XCTAssertThrowsError(try StorageBackupAccountingCache.shared(root:f.root).cleanupIndex(db,root:f.root,incarnation:uuid(),limit:64 * 1024 * 1024)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
        }
    }

    func testCompactBackupUsesManifestForAccountingCleanupAndRestore() throws {
        let f = try StorageFixture(),project = try f.project(),task = try f.task(project),router = f.router!
        let original = f.workspace.appendingPathComponent("indexed.txt")
        try Data("independent backup payload".utf8).write(to:original)
        let attachment = try f.call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":original.path])["data"] as! JSON
        let destination = f.base.appendingPathComponent("compact-backup")
        _ = try router.handle(method:"backup_create",params:["command_id":uuid(),"path":destination.path],caller:f.owner)
        let receipt = try router.dbQueue.read {db in jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key GLOB 'backup-generation:*'")))}
        XCTAssertEqual(receipt["format"] as? Int,2);XCTAssertNil(receipt["objects"])
        let manifest = try StorageBackupManifestIndex.manifest(receipt,root:f.root)
        XCTAssertEqual(receipt["object_count"] as? Int,manifest.objects.count)
        let path = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let object: JSON = ["relative_path":path,"sha256":attachment["sha256"]!,"size":attachment["size"]!,"kind":"file"]
        let key = StorageBackupRetentionIndex.key(path:path,sha:attachment["sha256"] as! String,size:(attachment["size"] as! NSNumber).int64Value)
        var index = try router.dbQueue.read {try router.ticketCleanupBackupRetentionIndex($0,objects:[object])}
        XCTAssertTrue(index.containsOriginal(key));XCTAssertTrue(index.hasIndependentCopy(key))
        index.verifyCopy(for:object)
        XCTAssertNotNil(index.verifiedCopies[key]);XCTAssertNil(index.copyFailures[key])
        let accounting = try router.dbQueue.read {try router.storageBackupAccounting($0)}
        XCTAssertTrue(try XCTUnwrap(accounting).containsOriginal(key))
        XCTAssertEqual(try router.dbQueue.read {try router.storageBackupRetentionIndex($0).containsOriginal(key)},true)
        let preview = try router.handle(method:"restore_preview",params:["path":destination.path],caller:f.owner)
        XCTAssertEqual((preview["data"] as? JSON)?["managed_files"] as? Int,manifest.objects.count)
        let restored = try router.handle(method:"restore_create",params:["command_id":uuid(),"path":destination.path,"manifest_sha256":(preview["data"] as! JSON)["manifest_sha256"]!],caller:f.owner)
        XCTAssertEqual((restored["data"] as? JSON)?["status"] as? String,"complete")
    }

    func testHistoricalCatalogSurvivesBackupRestoreWithoutGrantingCopyAuthority() throws {
        let f = try StorageFixture(),router = f.router!,operation = uuid()
        let object: JSON = ["path":f.root.path + "/objects/old/payload","sha256":String(repeating:"a",count:64),"size":17]
        let raw = try jsonString(["format":1,"state":"complete","operation_id":operation,"manifest_sha256":String(repeating:"b",count:64),"objects":[object]])
        let prepared = try StorageBackupManifestIndex.prepareHistorical(root:f.root,raw:raw)
        var receipt = jsonObject(raw);receipt.removeValue(forKey:"objects");receipt["format"] = 2
        receipt.merge(prepared) {_,new in new}
        try router.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?),(?,?)",arguments:["backup-generation:" + operation,try jsonString(receipt),"backup-historical-catalog:" + operation,try jsonString(prepared["historical_catalog"] as! JSON)])
        }
        let key = StorageBackupRetentionIndex.key(path:"objects/old/payload",sha:String(repeating:"a",count:64),size:17)
        let index = try router.dbQueue.read {try router.ticketCleanupBackupRetentionIndex($0,objects:[])}
        XCTAssertTrue(index.containsOriginal(key));XCTAssertFalse(index.hasIndependentCopy(key));XCTAssertTrue(index.copyManifests.isEmpty)
        let destination = f.base.appendingPathComponent("catalog-backup")
        _ = try f.call("backup_create",["path":destination.path])
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        let catalog = prepared["historical_catalog"] as! JSON,path = catalog["path"] as! String
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.relativePath == path})
        XCTAssertEqual(try String(contentsOf:destination.appendingPathComponent("managed/" + path),encoding:.utf8),raw)
        let preview = try f.call("restore_preview",["path":destination.path])["data"] as! JSON
        let restored = try f.call("restore_create",["path":destination.path,"manifest_sha256":preview["manifest_sha256"]!])["data"] as! JSON
        let restoredRoot = URL(fileURLWithPath:restored["path"] as! String)
        XCTAssertEqual(try StorageBackupManifestIndex.historicalRaw(receipt,root:restoredRoot),raw)
        let rebuilt = try StorageBackupManifestIndex.generation(receipt,root:restoredRoot)
        let lookup = StorageBackupManifestIndex.Lookup(generations:[rebuilt],legacy:nil)
        XCTAssertTrue(lookup.containsOriginal(key));XCTAssertFalse(lookup.hasIndependentCopy(key))
    }

    func testBinaryLookupMatchesManifestAndRejectsChangedIndex() throws {
        let f = try StorageFixture(),root = f.router!.root
        let sha = String(repeating:"c",count:64)
        let paths = ["objects/a", "objects/caf\u{e9}", "objects/quote\"slash\\"]
        let objects = paths.enumerated().map {index,path in
            StorageSnapshotMaterializedObject(descriptor:.init(relativePath:path,kind:"file",expectedSHA256:sha,expectedSize:Int64(index),executable:false,linkTarget:nil,authorities:[]),sha256:sha,size:Int64(index))
        }
        let manifest = StorageSnapshotManifest(format:1,kind:StorageSnapshot.kind,operationID:uuid(),storeID:uuid(),sourceRoot:root.path,schema:SchemaMigrations.currentSchema,databaseSHA256:sha,databaseSize:0,objects:objects,unavailable:[],externalReferences:[])
        let descriptor = try StorageBackupManifestIndex.prepare(root:root,manifest:manifest,manifestSHA256:sha)
        let value: JSON = ["format":2,"state":"complete","manifest_index":descriptor,"manifest_sha256":sha,"summary":["path":"/private/tmp/only-a-descriptor","source_root":root.path,"verification":"manifest_database_managed_files","manifest_sha256":sha]]
        let generation = try StorageBackupManifestIndex.generation(value,root:root)
        let lookup = StorageBackupManifestIndex.Lookup(generations:[generation],legacy:nil)
        for (index,path) in paths.enumerated() {XCTAssertTrue(lookup.containsOriginal(StorageBackupRetentionIndex.key(path:path,sha:sha,size:Int64(index))))}
        XCTAssertFalse(lookup.containsOriginal(StorageBackupRetentionIndex.key(path:paths[0],sha:sha,size:99)))
        let file = root.appendingPathComponent(descriptor["path"] as! String)
        try Data(repeating:0,count:paths.count*32).write(to:file)
        XCTAssertThrowsError(try StorageBackupManifestIndex.generation(value,root:root))
    }
}
