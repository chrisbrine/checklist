import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageSnapshotCapacityTests: XCTestCase {
    private final class Fixture {
        let base: URL, root: URL
        let router: CommandRouter
        let owner = Caller(role: "owner", installation: "snapshot-capacity-fixture", projectIDs: [])
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("CL163-" + UUID().uuidString)
            root = base.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            router = try CommandRouter(root: root)
        }
        deinit { try? router.closeStore(); try? FileManager.default.removeItem(at: base) }
        func save(_ value: JSON, _ type: String) throws {
            try router.dbQueue.writeWithoutTransaction { db in
                try router.withValidatedDomainTransaction(db) { try router.save(db, value, type: type); return .commit }
            }
        }
        func capture(_ files: [JSON]) throws -> JSON {
            let path = root.appendingPathComponent("source-captures/project/capture/source")
            let value: JSON = ["id": "capture", "project_id": "project", "revision": 1, "snapshot_path": path.path, "files": files]
            try save(value, "source_capture")
            return value
        }
        func build(_ operation: UUID, _ budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
            let identity = try router.dbQueue.read { db in try StoreIdentityReceipt.decode(Data(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='store_identity'")!.utf8)) }
            return try ArchiveStorageGate.withExclusive(root: root) { permit in
                try StorageSnapshot.build(StorageSnapshotSource(source: root, parent: base, storeID: identity.logical_store_id, permit: permit), operation: operation, budget: budget)
            }
        }
        func ownerBackup(_ name: String, command: String = UUID().uuidString) throws -> JSON {
            try router.handle(method: "backup_create", params: ["path": base.appendingPathComponent(name).path, "command_id": command], caller: owner)
        }
    }

    func testProductionCapacityAndSharedDeadlineHaveMeasuredHeadroom() throws {
        let before = ProcessInfo.processInfo.systemUptime, budget = StorageSnapshotBudget.production()
        XCTAssertEqual(budget.maximumBytes, 8 * 1_073_741_824)
        XCTAssertEqual(budget.maximumObjects, 500_000)
        XCTAssertEqual(budget.maximumManifestBytes, 128 * 1_048_576)
        XCTAssertEqual(budget.maximumObjectBytes, 524_288_000)
        XCTAssertEqual(budget.maximumRecords, 100_000)
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThanOrEqual(budget.deadlineUptime, before + 1_800)
        XCTAssertLessThanOrEqual(budget.deadlineUptime, after + 1_800)
        // The observed durable-copy time alone exceeds both old production deadlines.
        var clock: TimeInterval = 0
        var simulated = StorageSnapshotBudget(deadlineUptime: 1_800, canceled: { false })
        simulated.uptime = { clock }
        clock = 564; XCTAssertNoThrow(try simulated.check())
        clock = 1_800; XCTAssertThrowsError(try simulated.check()) { error in
            guard case StorageSnapshotFailure.deadline = error else { return XCTFail("\(error)") }
        }
        simulated = StorageSnapshotBudget(deadlineUptime: .infinity, canceled: { true })
        XCTAssertThrowsError(try simulated.check())
        XCTAssertThrowsError(try budget.adding(Int64.max, to: 1))
    }

    func testDeadlineAtCompletedSQLiteStepAndBeforePublicationRetainsStage() throws {
        for boundary in ["backup_done", "before_publish"] {
            let f = try Fixture(), operation = UUID()
            var clock: TimeInterval = 0
            var budget = StorageSnapshotBudget(deadlineUptime: 1, canceled: { false })
            budget.uptime = { clock }
            budget.observe = { if $0 == boundary { clock = 1 } }
            XCTAssertThrowsError(try f.build(operation, budget)) { error in
                XCTAssertEqual((error as? CoreError)?.code, "BACKUP_DEADLINE_EXCEEDED")
                XCTAssertEqual((error as? CoreError)?.details["reason"] as? String, "snapshot_deadline")
            }
            let names = StorageSnapshot.names(operation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(names.published).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(names.staging + "/intent.json").path))
            if boundary == "before_publish" {
                // Same-operation explicit retry verifies and publishes the intact stage.
                let receipt = try StorageSnapshot.resumeStaging(parent: f.base, operation: operation, publicationName: names.published, budget: .production())
                XCTAssertNotNil(receipt)
            }
        }
    }

    func testOwnerCapacityFailureMeasuresAllFilesAndPreservesStoreAndEarlierBackup() throws {
        let f = try Fixture()
        let earlier = try f.ownerBackup("earlier")
        let earlierSHA = (earlier["data"] as! JSON)["manifest_sha256"] as! String
        let source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let size: Int64 = 450 * 1_048_576
        var files: [JSON] = []
        for i in 0..<20 {
            let name = "sparse-\(i)"
            let fd = Darwin.open(source.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(ftruncate(fd, off_t(size)), 0); Darwin.close(fd)
            files.append(["path": name, "kind": "file", "sha256": String(repeating: "0", count: 64), "size": size])
        }
        _ = try f.capture(files)
        let command = UUID().uuidString
        XCTAssertThrowsError(try f.ownerBackup("over-limit", command: command)) { error in
            guard let e = error as? CoreError else { return XCTFail("\(error)") }
            XCTAssertEqual(e.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(e.details["measured_objects"] as? Int, 20)
            XCTAssertGreaterThanOrEqual(e.details["measured_bytes"] as? Int64 ?? 0, 20 * size)
            XCTAssertTrue(e.message.contains("20 managed objects"))
            XCTAssertTrue(e.message.contains("bytes"))
            XCTAssertTrue(e.message.contains("Keep the store and existing backups"))
            XCTAssertTrue(e.message.contains("Do not delete retained captures or attachments"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("over-limit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 20)
        XCTAssertEqual(try StorageObjectFiles(root: f.base.appendingPathComponent("earlier")).digest("manifest.json", budget: .production()).0, earlierSHA)
        XCTAssertEqual(try f.router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM commands WHERE command_id=?", arguments: [command]) }, 0)
        XCTAssertEqual(try f.router.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
    }

    func testObjectAndManifestLimitsStillRefuseWithActionableCounts() throws {
        let f = try Fixture()
        let source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("retained".utf8), sha = StorageObjectFiles.sha(bytes)
        for name in ["a", "b"] { try bytes.write(to: source.appendingPathComponent(name)) }
        _ = try f.capture(["a", "b"].map { ["path": $0, "kind": "file", "sha256": sha, "size": bytes.count] })
        for kind in ["objects", "manifest"] {
            var budget = StorageSnapshotBudget.production()
            if kind == "objects" { budget.maximumObjects = 1 } else { budget.maximumManifestBytes = 128 }
            let operation = UUID()
            XCTAssertThrowsError(try f.build(operation, budget)) { error in
                let e = error as? CoreError
                XCTAssertEqual(e?.code, "BACKUP_CAPACITY_EXCEEDED")
                XCTAssertEqual(e?.details["measured_objects"] as? Int, 2)
                XCTAssertGreaterThan(e?.details["measured_bytes"] as? Int64 ?? 0, 0)
                XCTAssertNotNil(e?.details["next_step"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(StorageSnapshot.names(operation).published).path))
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a")), bytes)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("b")), bytes)
    }

    func testDuplicateContentSharesOnlyBackupBytesAndLegacyRestoreStillWorks() throws {
        let f = try Fixture(), source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let bytes = Data("retained duplicate".utf8), sha = StorageObjectFiles.sha(bytes)
        for name in ["a", "b"] { try bytes.write(to:source.appendingPathComponent(name)) }
        _ = try f.capture(["a", "b"].map { ["path":$0,"kind":"file","sha256":sha,"size":bytes.count] })
        let operation = UUID(), receipt = try f.build(operation,.production())
        let backup = f.base.appendingPathComponent(StorageSnapshot.names(operation).published)
        let a = backup.appendingPathComponent("managed/source-captures/project/capture/source/a")
        let b = backup.appendingPathComponent("managed/source-captures/project/capture/source/b")
        var original = stat(), first = stat(), second = stat()
        XCTAssertEqual(lstat(source.appendingPathComponent("a").path,&original),0)
        XCTAssertEqual(lstat(a.path,&first),0);XCTAssertEqual(lstat(b.path,&second),0)
        XCTAssertEqual(first.st_ino,second.st_ino);XCTAssertNotEqual(first.st_ino,original.st_ino)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        let current = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:manifestURL))
        XCTAssertEqual(current.format,2);XCTAssertEqual(current.objects.count,2)
        XCTAssertEqual(try StorageSnapshot.reconcile(parent:f.base,operation:operation,budget:.production()).manifestSHA256,receipt.manifestSHA256)
        // Exercise a genuine format-1 generation through full verification and
        // disposable restore, including independent duplicate destination inodes.
        let legacy = StorageSnapshotManifest(format:1,kind:current.kind,operationID:current.operationID,storeID:current.storeID,sourceRoot:current.sourceRoot,schema:current.schema,databaseSHA256:current.databaseSHA256,databaseSize:current.databaseSize,objects:current.objects,unavailable:current.unavailable,externalReferences:current.externalReferences,recordFamilies:current.recordFamilies,tableRows:current.tableRows,capturedAt:current.capturedAt)
        try StorageSnapshot.encoded(legacy).write(to:manifestURL)
        let intentURL = backup.appendingPathComponent("intent.json")
        var intent = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:intentURL));intent["format"] = "1"
        try StorageSnapshot.encoded(intent).write(to:intentURL)
        let preview = try f.router.handle(method:"restore_preview",params:["path":backup.path],caller:f.owner)["data"] as! JSON
        let restored = try f.router.handle(method:"restore_create",params:["path":backup.path,"manifest_sha256":preview["manifest_sha256"]!,"command_id":UUID().uuidString],caller:f.owner)["data"] as! JSON
        let restoredRoot = URL(fileURLWithPath:restored["path"] as! String)
        let restoredA = restoredRoot.appendingPathComponent("source-captures/project/capture/source/a")
        let restoredB = restoredRoot.appendingPathComponent("source-captures/project/capture/source/b")
        XCTAssertEqual(try Data(contentsOf:restoredA),bytes);XCTAssertEqual(try Data(contentsOf:restoredB),bytes)
        XCTAssertEqual(lstat(restoredA.path,&first),0);XCTAssertEqual(lstat(restoredB.path,&second),0)
        XCTAssertNotEqual(first.st_ino,second.st_ino)
        try Data("corrupt".utf8).write(to:a)
        XCTAssertThrowsError(try StorageSnapshot.reconcile(parent:f.base,operation:operation,budget:.production()))
    }

    func testDuplicateExpectedHashDoesNotHideChangedSourceBytes() throws {
        let f = try Fixture(), source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let bytes = Data("same".utf8), sha = StorageObjectFiles.sha(bytes)
        for name in ["a", "b"] { try bytes.write(to:source.appendingPathComponent(name)) }
        _ = try f.capture(["a", "b"].map { ["path":$0,"kind":"file","sha256":sha,"size":bytes.count] })
        var budget = StorageSnapshotBudget.production(),copied = false
        budget.observe = { boundary in
            if boundary == "object_copied", !copied { copied = true; try Data("evil".utf8).write(to:source.appendingPathComponent("b")) }
        }
        XCTAssertThrowsError(try f.build(UUID(),budget)) { error in
            guard case StorageSnapshotFailure.sourceChanged = error else { return XCTFail("\(error)") }
        }
    }

    func testUnavailableOrSaturatedHardLinksFallBackToVerifiedIndependentCopies() throws {
        for code in [ENOTSUP, EMLINK, EPERM] {
            let f = try Fixture(), source = f.root.appendingPathComponent("source-captures/project/capture/source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            let bytes = Data("same retained content".utf8), sha = StorageObjectFiles.sha(bytes)
            for name in ["a","b"] {try bytes.write(to:source.appendingPathComponent(name))}
            _ = try f.capture(["a","b"].map {["path":$0,"kind":"file","sha256":sha,"size":bytes.count]})
            var budget = StorageSnapshotBudget.production()
            budget.linkFile = {_,_,_,_ in errno = code;return -1}
            let op = UUID();_ = try f.build(op,budget)
            let backup = f.base.appendingPathComponent(StorageSnapshot.names(op).published)
            var a=stat(),b=stat()
            XCTAssertEqual(lstat(backup.appendingPathComponent("managed/source-captures/project/capture/source/a").path,&a),0)
            XCTAssertEqual(lstat(backup.appendingPathComponent("managed/source-captures/project/capture/source/b").path,&b),0)
            XCTAssertNotEqual(a.st_ino,b.st_ino)
            XCTAssertNoThrow(try StorageSnapshot.reconcile(parent:f.base,operation:op,budget:.production()))
        }
    }

    func testInterruptedDirectoryBarrierCannotPublishOrResumeWithoutCommitManifest() throws {
        let f=try Fixture(),op=UUID()
        var budget=StorageSnapshotBudget.production()
        budget.observe = {if $0 == "directories_synchronized" {throw StorageSnapshotFailure.io}}
        XCTAssertThrowsError(try f.build(op,budget))
        let names=StorageSnapshot.names(op)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent(names.published).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent(names.staging+"/manifest.json").path))
        XCTAssertNil(try StorageSnapshot.resumeStaging(parent:f.base,operation:op,publicationName:names.published,budget:.production()))
    }

    func testMoreThanThirtyThousandObjectsAndEightMiBManifestRoundTripWithoutPruning() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(), source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("retained evidence".utf8), sha = StorageObjectFiles.sha(bytes)
        try bytes.write(to: source.appendingPathComponent("original"))
        var files: [JSON] = [["path": "original", "kind": "file", "sha256": sha, "size": bytes.count]]
        // Captured links exercise the same inventory/count/manifest/publication
        // path without 30k costly full device flushes of identical test bytes.
        for i in 0..<30_001 {
            let name = "retained-\(i)-" + String(repeating: "x", count: 80)
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent(name).path, withDestinationPath: "original")
            files.append(["path": name, "kind": "symlink", "target": "original", "sha256": StorageObjectFiles.sha(Data("original".utf8))])
        }
        let capture = try f.capture(files)
        // Duplicate evidence authority must survive alongside the standalone
        // capture; an open review's retained manifest is never a pruning hint.
        try f.save(["id": "retained-manifest", "project_id": "project", "revision": 1, "evidence": ["source_capture": capture]], "manifest")
        try f.save(["id": "open-review", "project_id": "project", "revision": 1, "manifest_id": "retained-manifest", "state": "open"], "review_request")
        let backup = try f.ownerBackup("large")
        let data = try XCTUnwrap(backup["data"] as? JSON), operation = try XCTUnwrap(UUID(uuidString: data["operation_id"] as! String))
        let directory = f.base.appendingPathComponent("large"), manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertGreaterThan(manifestData.count, 8_388_608)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: manifestData)
        XCTAssertEqual(manifest.objects.count, 30_002)
        XCTAssertTrue(manifest.objects.allSatisfy { $0.descriptor.authorities.count == 2 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 30_002)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("original")), bytes)
        // Both owner receipt reads, crash-style lost-SQL-receipt reconciliation,
        // and a fresh exact inventory/digest pass must accept the large manifest.
        let receipt = try StorageSnapshot.reconcile(parent: f.base, operation: operation, publicationName: "large", budget: .production())
        XCTAssertEqual(receipt.manifestSHA256, data["manifest_sha256"] as? String)
        try f.router.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM commands WHERE command_id=?", arguments: [backup["command_id"] as! String])
            try db.execute(sql: "DELETE FROM metadata WHERE key=?", arguments: ["backup-generation:" + operation.uuidString.lowercased()])
        }
        let recovered = try f.ownerBackup("large", command: backup["command_id"] as! String)
        XCTAssertEqual((recovered["data"] as? JSON)?["manifest_sha256"] as? String, receipt.manifestSHA256)
        // Changing even one captured file must still fail full verification.
        try Data("changed".utf8).write(to: directory.appendingPathComponent("managed/" + manifest.objects.first { $0.descriptor.kind == "file" }!.descriptor.relativePath))
        XCTAssertThrowsError(try StorageSnapshot.reconcile(parent: f.base, operation: operation, publicationName: "large", budget: .production()))
        print("CL163 capacity fixture: objects=\(manifest.objects.count) manifest_bytes=\(manifestData.count)")
    }
}
