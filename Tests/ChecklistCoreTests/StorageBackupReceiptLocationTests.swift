import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class StorageBackupReceiptLocationTests: XCTestCase {
    private struct Receipt {
        let value: JSON
        let manifest: StorageSnapshotManifest
        let local: URL
        let foreign: URL
        let key: Data
    }
    private func receipt(_ f: StorageFixture, sameInstance: Bool = false) throws -> Receipt {
        let operation = uuid(), store = uuid(), payload = Data("receipt-location-payload".utf8)
        let source = sameInstance ? f.root.path : f.base.appendingPathComponent("previous-store").path
        let object = StorageSnapshotMaterializedObject(descriptor: .init(relativePath: "objects/history/payload", kind: "file", expectedSHA256: ChecklistCore.hash(payload), expectedSize: Int64(payload.count), executable: false, linkTarget: nil, authorities: []), sha256: ChecklistCore.hash(payload), size: Int64(payload.count))
        let manifest = StorageSnapshotManifest(format: 2, kind: StorageSnapshot.kind, operationID: operation, storeID: store, sourceRoot: source, schema: SchemaMigrations.currentSchema, databaseSHA256: String(repeating: "a", count: 64), databaseSize: 1, objects: [object], unavailable: [], externalReferences: [])
        let bytes = try StorageSnapshot.encoded(manifest), digest = ChecklistCore.hash(bytes)
        let local = f.root.appendingPathComponent("backups/snapshot-" + operation, isDirectory: true)
        let foreign = sameInstance ? f.base.appendingPathComponent("intentional-external-backup", isDirectory: true) : f.base.appendingPathComponent("foreign/snapshot-" + operation, isDirectory: true)
        for path in [local, foreign] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try bytes.write(to: path.appendingPathComponent("manifest.json"))
        }
        let descriptor = try StorageBackupManifestIndex.prepare(root: f.root, manifest: manifest, manifestSHA256: digest)
        let value: JSON = ["format": 2, "state": "complete", "operation_id": operation, "manifest_sha256": digest, "object_count": 1, "object_bytes": payload.count, "manifest_index": descriptor,
                           "summary": ["path": foreign.path, "source_root": source, "store_id": store, "manifest_sha256": digest, "verification": "manifest_database_managed_files"]]
        return Receipt(value: value, manifest: manifest, local: local, foreign: foreign, key: StorageBackupRetentionIndex.key(path: object.descriptor.relativePath, sha: object.sha256, size: object.size))
    }
    private func removeIndex(_ value: JSON, root: URL) throws {
        let descriptor = try XCTUnwrap(value["manifest_index"] as? JSON)
        try FileManager.default.removeItem(at: root.appendingPathComponent(try XCTUnwrap(descriptor["path"] as? String)))
    }

    func testCopiedCompactReceiptRebuildsMissingIndexFromExactLocalManifestDespiteCorruptForeign() throws {
        let f = try StorageFixture(), r = try receipt(f)
        try Data("corrupt foreign manifest must never be opened".utf8).write(to: r.foreign.appendingPathComponent("manifest.json"))
        try removeIndex(r.value, root: f.root)
        let generation = try StorageBackupManifestIndex.generation(r.value, root: f.root)
        XCTAssertEqual(generation.path, r.local.path)
        XCTAssertTrue(generation.independent)
        let lookup = StorageBackupManifestIndex.Lookup(generations: [generation], legacy: nil)
        XCTAssertEqual(Array(lookup.copies(for: r.key)).map(\.path), [r.local.path])
        XCTAssertTrue(lookup.hasIndependentCopy(r.key))
        let parsed = try StorageBackupAccountingCache.parseReceipt(try jsonString(r.value), root: f.root)
        XCTAssertEqual(parsed.copy?.path, r.local.path)
        XCTAssertEqual(parsed.keys, [r.key])
        XCTAssertEqual(try StorageBackupManifestIndex.manifest(r.value, root: f.root).operationID, r.manifest.operationID)
    }

    func testAbsentLocalManifestNeverFallsBackToValidForeignAndStoreStillOpens() throws {
        let f = try StorageFixture(), r = try receipt(f)
        try removeIndex(r.value, root: f.root)
        try FileManager.default.removeItem(at: r.local)
        try f.router!.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?)", arguments: ["backup-generation:" + r.manifest.operationID, try jsonString(r.value)])
        }
        try f.router!.dbQueue.read { db in
            XCTAssertThrowsError(try StorageBackupManifestIndex.warm(db, root: f.root))
        }
        XCTAssertThrowsError(try StorageBackupAccountingCache.parseReceipt(try jsonString(r.value), root: f.root))
        try f.close()
        try f.reopen() // Startup catches the unavailable accelerator; tickets stay accessible.
        XCTAssertNotNil(f.router)
        XCTAssertEqual(try f.router!.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, SchemaMigrations.currentSchema)
        try f.router!.dbQueue.read { db in
            XCTAssertThrowsError(try StorageBackupManifestIndex.warm(db, root: f.root))
        }
        XCTAssertEqual(try Data(contentsOf: r.foreign.appendingPathComponent("manifest.json")), try StorageSnapshot.encoded(r.manifest))
    }

    func testRetainedIndexSelectsOnlyLocalCopyDescriptor() throws {
        let f = try StorageFixture(), r = try receipt(f)
        try FileManager.default.removeItem(at: r.local)
        let generation = try StorageBackupManifestIndex.generation(r.value, root: f.root)
        XCTAssertEqual(generation.path, r.local.path)
        let lookup = StorageBackupManifestIndex.Lookup(generations: [generation], legacy: nil)
        XCTAssertEqual(Array(lookup.copies(for: r.key)).map(\.path), [r.local.path])
        XCTAssertNil(lookup.manifests[r.foreign.path])
        XCTAssertEqual(lookup.manifests[r.local.path], r.value["manifest_sha256"] as? String)
        XCTAssertThrowsError(try StorageBackupManifestIndex.manifest(r.value, root: f.root))
    }

    func testSameInstanceIntentionalExternalBackupRemainsUsable() throws {
        let f = try StorageFixture(), r = try receipt(f, sameInstance: true)
        try Data("local candidate must not replace this instance's chosen external backup".utf8).write(to: r.local.appendingPathComponent("manifest.json"))
        try removeIndex(r.value, root: f.root)
        XCTAssertEqual(try StorageBackupReceiptLocation.location(r.value, root: f.root), r.foreign)
        let generation = try StorageBackupManifestIndex.generation(r.value, root: f.root)
        XCTAssertEqual(generation.path, r.foreign.path)
        XCTAssertEqual(try StorageBackupAccountingCache.parseReceipt(try jsonString(r.value), root: f.root).copy?.path, r.foreign.path)
        XCTAssertEqual(try StorageBackupManifestIndex.manifest(r.value, root: f.root).sourceRoot, f.root.path)
    }

    func testLocalManifestStillRequiresExactSHAOperationStoreAndSourceBindings() throws {
        let f = try StorageFixture(), r = try receipt(f)
        for field in ["sha", "operation", "store", "source"] {
            var changed = r.value, summary = changed["summary"] as! JSON
            switch field {
            case "sha": changed["manifest_sha256"] = String(repeating: "c", count: 64); summary["manifest_sha256"] = changed["manifest_sha256"]
            case "operation": changed["operation_id"] = uuid()
            case "store": summary["store_id"] = uuid()
            default: summary["source_root"] = f.base.appendingPathComponent("another-source").path
            }
            changed["summary"] = summary
            XCTAssertThrowsError(try StorageBackupManifestIndex.manifest(changed, root: f.root), field)
        }
    }

    func testMissingSourceRootUsesLocalNamespaceAndUnsafeNamesRefuse() throws {
        let f = try StorageFixture(), r = try receipt(f)
        var changed = r.value, summary = changed["summary"] as! JSON
        summary.removeValue(forKey: "source_root"); changed["summary"] = summary
        XCTAssertEqual(try StorageBackupReceiptLocation.location(changed, root: f.root), r.local)
        for name in ["arbitrary-backup", "snapshot-../outside", "snapshot-" + uuid() + ".json"] {
            summary["path"] = f.base.appendingPathComponent("foreign/" + name).path; changed["summary"] = summary
            XCTAssertThrowsError(try StorageBackupReceiptLocation.location(changed, root: f.root))
        }
    }

    func testSymlinkedLocalSnapshotCannotReachValidForeignManifest() throws {
        let f = try StorageFixture(), r = try receipt(f)
        try removeIndex(r.value, root: f.root)
        try FileManager.default.removeItem(at: r.local)
        try FileManager.default.createSymbolicLink(at: r.local, withDestinationURL: r.foreign)
        XCTAssertThrowsError(try StorageBackupManifestIndex.generation(r.value, root: f.root))
    }

    func testForeignParentTraversalCannotSelectALocalSnapshot() throws {
        let f = try StorageFixture(), r = try receipt(f)
        var value = r.value, summary = value["summary"] as! JSON
        summary["path"] = "/previous/../backups/" + r.local.lastPathComponent
        value["summary"] = summary
        XCTAssertThrowsError(try StorageBackupReceiptLocation.location(value, root: f.root))
        XCTAssertThrowsError(try StorageBackupManifestIndex.manifest(value, root: f.root))
    }

    func testSourceRootEqualityUsesExactUTF8Bytes() throws {
        let root = URL(fileURLWithPath: "/private/tmp/location-\u{e9}", isDirectory: true)
        let digest = String(repeating: "a", count: 64), operation = uuid()
        XCTAssertFalse(root.path.utf8.elementsEqual(root.path.precomposedStringWithCanonicalMapping.utf8), "Fixture must use distinct canonical UTF8 spellings.")
        let value: JSON = ["state": "complete", "manifest_sha256": digest, "summary": ["path": "/foreign/snapshot-" + operation, "source_root": root.path.precomposedStringWithCanonicalMapping, "manifest_sha256": digest, "verification": "manifest_database_managed_files"]]
        XCTAssertEqual(try StorageBackupReceiptLocation.location(value, root: root), root.appendingPathComponent("backups/snapshot-" + operation, isDirectory: true))
    }
}
