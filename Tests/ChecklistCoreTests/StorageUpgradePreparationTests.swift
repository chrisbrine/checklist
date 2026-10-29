import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class StorageUpgradePreparationTests: XCTestCase {
    private func oldStore(withObject: Bool = false) throws -> (StorageFixture,String?) {
        let f = try StorageFixture(),p = try f.project()
        var object: String?
        if withObject {
            let t = try f.task(p),source = f.workspace.appendingPathComponent("upgrade.bin")
            try Data("protected upgrade bytes".utf8).write(to:source)
            let attachment = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
            object = attachment["path"] as? String
        }
        let identity = try f.router!.dbQueue.write {db -> StoreIdentityReceipt in
            let current = try StoreIdentityReceipt.decode(Data((try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'"))!.utf8)).withSchema(3)
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try current.encoded(),as:UTF8.self)])
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString(SchemaMigrations.ledgers(3))])
            try db.execute(sql:"PRAGMA user_version=3")
            return current
        }
        try StoreDirectory(root:f.root).publishReceipt(identity.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
        return (f,object)
    }
    private func pointer(_ f: StorageFixture) throws -> JSON {
        try f.router!.dbQueue.read {jsonObject(try XCTUnwrap(String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key='preupgrade_snapshot'")))}
    }
    func testOnlinePreparationKeepsServiceLeaseAndSourceUntouchedAndReusesVerifiedBackup() throws {
        let (f,_) = try oldStore(withObject:true)
        let before = try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        XCTAssertEqual(prepared["expected_offline_seconds"] as? Int,90)
        XCTAssertEqual(prepared["prepared"] as? Bool,true)
        XCTAssertEqual(try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)},before)
        XCTAssertNotNil(f.lease,"Online preparation must not require stopping the old service")
        try f.close();try f.reopen()
        let actual = try pointer(f)
        XCTAssertEqual(actual["path"] as? String,prepared["protected_backup"] as? String)
        XCTAssertEqual(actual["prepared_online"] as? Bool,true)
        let op = UUID(uuidString:actual["operation_id"] as! String)!
        let verified = try StorageSnapshot.reconcile(parent:f.root.appendingPathComponent("backups"),operation:op,budget:.production())
        XCTAssertEqual(verified.manifestSHA256,actual["manifest_sha256"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("upgrade-progress.json").path))
    }
    func testChangedDatabaseTakesFreshProtectedSnapshotMatchingSwap() throws {
        let (f,_) = try oldStore()
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        try f.router!.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES('upgrade-test-later-write','retained at swap')")}
        let expected = try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
        try f.close();try f.reopen()
        let actual = try pointer(f)
        XCTAssertNotEqual(actual["path"] as? String,prepared["protected_backup"] as? String)
        XCTAssertEqual(actual["source_fingerprint"] as? String,expected)
        XCTAssertNil(actual["prepared_online"])
    }
    func testSQLAndManagedFileChangedAfterPreparationAreProtectedAtSwap() throws {
        let (f,path) = try oldStore(withObject:true)
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        let relative = try XCTUnwrap(ManagedPaths.relative(try XCTUnwrap(path),family:"objects",root:f.root))
        let changed = Data("changed managed bytes after preparation".utf8)
        try changed.write(to:f.root.appendingPathComponent(relative))
        try f.router!.dbQueue.write { db in
            var attachment = try XCTUnwrap(f.router!.records(db,type:"attachment").first)
            attachment["sha256"] = ChecklistCore.hash(changed);attachment["size"] = changed.count
            try f.router!.save(db,attachment,type:"attachment")
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES('upgrade-later-sql','written after preparation')")
        }
        let expected = try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
        try f.close();try f.reopen()
        let actual = try pointer(f)
        XCTAssertNotEqual(actual["path"] as? String,prepared["protected_backup"] as? String)
        XCTAssertNil(actual["prepared_online"])
        XCTAssertEqual(actual["source_fingerprint"] as? String,expected)
        let generation = URL(fileURLWithPath:actual["path"] as! String)
        XCTAssertEqual(try Data(contentsOf:generation.appendingPathComponent("managed/" + relative)),changed)
        var config = Configuration();config.readonly = true
        config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let protected = try DatabaseQueue(path:generation.appendingPathComponent("database.sqlite").path,configuration:config)
        defer {try? protected.close()}
        XCTAssertEqual(try protected.read {try SchemaMigrations.contentFingerprint($0)},expected)
        XCTAssertEqual(try protected.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key='upgrade-later-sql'")},"written after preparation")
        let manifest = try StorageUpgradePreparation.manifest(generation)
        let object = try XCTUnwrap(manifest.objects.first {$0.descriptor.relativePath == relative})
        XCTAssertEqual(object.sha256,ChecklistCore.hash(changed));XCTAssertEqual(object.size,Int64(changed.count))
    }
    func testFingerprintDistinguishesCompleteTextBytesAndStorageTypes() throws {
        let (f,_) = try oldStore()
        var digests: Set<String> = []
        // SQL byte literals bypass GRDB's C-string binding of embedded NULs.
        for value in ["CAST(X'610062' AS TEXT)","CAST(X'610063' AS TEXT)",
                      "CAST(X'C3A9' AS TEXT)","CAST(X'65CC81' AS TEXT)","X'610062'"] {
            let digest = try f.router!.dbQueue.write {db -> String in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES('fingerprint-bytes'," + value + ") ON CONFLICT(key) DO UPDATE SET value=excluded.value")
                return try SchemaMigrations.contentFingerprint(db)
            }
            XCTAssertTrue(digests.insert(digest).inserted)
        }
    }
    func testChangedBackupCannotReusePreparation() throws {
        let (f,_) = try oldStore(withObject:true)
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        let generation = URL(fileURLWithPath:prepared["protected_backup"] as! String)
        let manifest = try StorageUpgradePreparation.manifest(generation)
        let object = try XCTUnwrap(manifest.objects.first)
        let copy = generation.appendingPathComponent("managed/" + object.descriptor.relativePath)
        try Data(repeating:0x63,count:Int(object.size)).write(to:copy)
        try f.close();try f.reopen()
        XCTAssertNotEqual(try pointer(f)["path"] as? String,prepared["protected_backup"] as? String)
    }
    func testOnlineIdentityCaptureRejectsBackupEditedAfterSnapshotVerification() throws {
        let (f,_) = try oldStore(withObject:true)
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        let generation = URL(fileURLWithPath:prepared["protected_backup"] as! String)
        let manifest = try StorageUpgradePreparation.manifest(generation)
        let object = try XCTUnwrap(manifest.objects.first)
        try Data(repeating:0x63,count:Int(object.size)).write(to:generation.appendingPathComponent("managed/" + object.descriptor.relativePath))
        XCTAssertThrowsError(try StorageUpgradePreparation.fileIdentities(root:f.root,generation:generation,manifest:manifest,budget:.production(),verifySource:true))
    }
    func testOnlineIdentityCaptureRejectsIntentEditedAfterSnapshotVerification() throws {
        let (f,_) = try oldStore()
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        let generation = URL(fileURLWithPath:prepared["protected_backup"] as! String)
        let manifest = try StorageUpgradePreparation.manifest(generation)
        var intent = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:generation.appendingPathComponent("intent.json")))
        intent["store_id"] = UUID().uuidString.lowercased()
        try JSONEncoder().encode(intent).write(to:generation.appendingPathComponent("intent.json"))
        XCTAssertThrowsError(try StorageUpgradePreparation.fileIdentities(root:f.root,generation:generation,manifest:manifest,budget:.production(),verifySource:true))
    }
    func testSourceObjectEditWithoutDatabaseWriteCannotReusePreparation() throws {
        let (f,path) = try oldStore(withObject:true)
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        let rootFiles = try StorageObjectFiles(root:f.root)
        let relative = try ManagedPaths.relative(try XCTUnwrap(path),family:"objects",root:f.root)!
        let bytes = try rootFiles.read(relative,maximum:4096)
        try bytes.write(to:f.root.appendingPathComponent(relative)) // Same bytes; changed identity is conservative.
        try f.close();try f.reopen()
        XCTAssertNotEqual(try pointer(f)["path"] as? String,prepared["protected_backup"] as? String)
    }
    func testDeepManagedPathKeepsPreparationReusableWithBoundedDescriptorCache() throws {
        let (f,path) = try oldStore(withObject:true)
        let relative = "objects/" + Array(repeating:"nested",count:70).joined(separator:"/") + "/upgrade.bin"
        let destination = f.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let original = try XCTUnwrap(ManagedPaths.resolve(try XCTUnwrap(path),family:"objects",root:f.root))
        try FileManager.default.moveItem(at:original,to:destination)
        try f.router!.dbQueue.write {db in
            var attachment = try XCTUnwrap(f.router!.records(db,type:"attachment").first)
            attachment["path"] = relative
            try f.router!.save(db,attachment,type:"attachment")
        }
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        try f.close();try f.reopen()
        XCTAssertEqual(try pointer(f)["path"] as? String,prepared["protected_backup"] as? String)
        XCTAssertEqual(try pointer(f)["prepared_online"] as? Bool,true)
    }
    func testSymlinkedSourceAncestorCannotReusePreparation() throws {
        let (f,path) = try oldStore(withObject:true)
        _ = try StorageUpgradePreparation.prepare(root:f.root)
        let relative = try XCTUnwrap(ManagedPaths.relative(try XCTUnwrap(path),family:"objects",root:f.root))
        let parent = f.root.appendingPathComponent(relative).deletingLastPathComponent()
        let moved = parent.deletingLastPathComponent().appendingPathComponent("moved-upgrade-objects")
        try FileManager.default.moveItem(at:parent,to:moved)
        try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:moved)
        let identity = try StoreIdentityReceipt.decode(Data(contentsOf:f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
        var config = Configuration();config.readonly = true
        config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let queue = try DatabaseQueue(path:f.root.appendingPathComponent("checklist.sqlite").path,configuration:config)
        defer {try? queue.close()}
        XCTAssertThrowsError(try StorageUpgradePreparation.reusable(queue:queue,root:f.root,identity:identity))
    }
    func testWrongTargetOrMalformedPreparationFallsBackWithoutLosingStore() throws {
        let (f,_) = try oldStore()
        _ = try StorageUpgradePreparation.prepare(root:f.root)
        var receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:f.root.appendingPathComponent(StorageUpgradePreparation.receiptName))) as! JSON
        receipt["targetChecksum"] = String(repeating:"0",count:64)
        try JSONSerialization.data(withJSONObject:receipt).write(to:f.root.appendingPathComponent(StorageUpgradePreparation.receiptName))
        try f.close();try f.reopen()
        XCTAssertNil(try pointer(f)["prepared_online"])
    }
    func testMissingStoreNeedsNoPreparationOrDirectoryCreation() throws {
        let f = try StorageFixture(open:false)
        let result = try StorageUpgradePreparation.prepare(root:f.root)
        XCTAssertEqual(result["needs_upgrade"] as? Bool,false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.path))
    }
    func testCurrentStoreNeedsNoPreparation() throws {
        let f = try StorageFixture()
        let prepared = try StorageUpgradePreparation.prepare(root:f.root)
        XCTAssertEqual(prepared["needs_upgrade"] as? Bool,false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(StorageUpgradePreparation.receiptName).path))
    }
}
