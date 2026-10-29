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
        func ownerBackup(_ name: String, command: String = UUID().uuidString, budget: StorageSnapshotBudget) throws -> JSON {
            try router.executeStorageBackup(params: ["path": base.appendingPathComponent(name).path, "command_id": command], caller: owner, budget: budget)
        }
        /// Synthetic sizes: sparse files cost no disk blocks until copied.
        func sparseCapture(count: Int, size: Int64) throws -> URL {
            let source = root.appendingPathComponent("source-captures/project/capture/source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            var files: [JSON] = []
            for i in 0..<count {
                let name = "sparse-\(i)"
                let fd = Darwin.open(source.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0)
                XCTAssertEqual(ftruncate(fd, off_t(size)), 0); Darwin.close(fd)
                files.append(["path": name, "kind": "file", "sha256": String(repeating: "0", count: 64), "size": size])
            }
            _ = try capture(files)
            return source
        }
    }
    private struct StopBeforeCopy: Error {}
    private static let gibibyte: Int64 = 1_073_741_824

    func testV54RecordCapacityMustNotBecomeFreeSpaceRefusal() throws {
        let f = try Fixture()
        _ = try f.capture([])
        try f.save(["id": "capture2", "project_id": "project", "revision": 1,
                    "snapshot_path": f.root.appendingPathComponent("source-captures/project/capture2/source").path,
                    "files": []], "source_capture")
        var budget = StorageSnapshotBudget.production()
        budget.maximumRecords = 1
        budget.availableBytes = { _ in 400 * Self.gibibyte }
        XCTAssertThrowsError(try f.build(UUID(), budget)) { error in
            guard let e = error as? CoreError else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(e.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(e.details["reason"] as? String, "snapshot_capacity",
                           "The record count cap must keep its existing reason; 400 GiB free is sufficient.")
            XCTAssertEqual(e.details["maximum_records"] as? Int, 1)
            XCTAssertNil(e.details["required_free_bytes"])
            XCTAssertNil(e.details["available_bytes"])
        }
    }

    func testProductionCapacityAndSharedDeadlineHaveMeasuredHeadroom() throws {
        let before = ProcessInfo.processInfo.systemUptime, budget = StorageSnapshotBudget.production()
        // CL-340: no fixed byte ceiling; free space on the backup volume bounds bytes.
        XCTAssertEqual(budget.maximumBytes, .max)
        XCTAssertEqual(budget.effectiveMaximumBytes, .max)
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
            budget.availableBytes = { _ in 400 * Self.gibibyte }
            budget.uptime = { clock }
            budget.observe = { if $0 == boundary { clock = 1 } }
            XCTAssertThrowsError(try f.build(operation, budget)) { error in
                XCTAssertEqual((error as? CoreError)?.code, "BACKUP_DEADLINE_EXCEEDED")
                XCTAssertEqual((error as? CoreError)?.details["reason"] as? String, "snapshot_deadline")
                XCTAssertEqual((error as? CoreError)?.details["production_deadline_seconds"] as? Int, 1_800)
                XCTAssertNil((error as? CoreError)?.details["required_free_bytes"])
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

    func testOwnerFreeSpaceRefusalMeasuresAllFilesAndPreservesStoreAndEarlierBackup() throws {
        let f = try Fixture()
        let earlier = try f.ownerBackup("earlier")
        let earlierSHA = (earlier["data"] as! JSON)["manifest_sha256"] as! String
        let size: Int64 = 450 * 1_048_576
        let source = try f.sparseCapture(count: 20, size: size)
        let command = UUID().uuidString
        // 9 GiB of synthetic store bytes against 8 GiB free: refused before copying.
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 8 * Self.gibibyte }
        var reachedCopy = false
        budget.observe = { if $0 == "copying_objects" { reachedCopy = true } }
        XCTAssertThrowsError(try f.ownerBackup("over-limit", command: command, budget: budget)) { error in
            guard let e = error as? CoreError else { return XCTFail("\(error)") }
            XCTAssertEqual(e.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(e.details["reason"] as? String, "snapshot_free_space")
            XCTAssertEqual(e.details["measured_objects"] as? Int, 20)
            let measured = e.details["measured_bytes"] as? Int64 ?? 0, margin = e.details["free_space_margin_bytes"] as? Int64 ?? 0
            XCTAssertGreaterThanOrEqual(measured, 20 * size)
            XCTAssertEqual(margin, max(Self.gibibyte, measured / 10))
            XCTAssertEqual(e.details["required_free_bytes"] as? Int64, measured + margin)
            XCTAssertEqual(e.details["available_bytes"] as? Int64, 8 * Self.gibibyte)
            XCTAssertTrue(e.message.contains("needs at least \(measured + margin) free bytes on the backup volume"))
            XCTAssertTrue(e.message.contains("\(margin)-byte safety margin"))
            XCTAssertTrue(e.message.contains("the volume has \(8 * Self.gibibyte) free bytes"))
            XCTAssertTrue(e.message.contains("Keep the store and existing backups"))
            XCTAssertTrue(e.message.contains("Do not delete retained captures or attachments"))
        }
        XCTAssertFalse(reachedCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("over-limit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 20)
        XCTAssertEqual(try StorageObjectFiles(root: f.base.appendingPathComponent("earlier")).digest("manifest.json", budget: .production()).0, earlierSHA)
        XCTAssertEqual(try f.router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM commands WHERE command_id=?", arguments: [command]) }, 0)
        XCTAssertEqual(try f.router.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
    }

    func testStoreAboveOldEightGiBLimitPassesCapacityChecksWhenFreeSpaceAllows() throws {
        let f = try Fixture()
        _ = try f.sparseCapture(count: 20, size: 450 * 1_048_576) // 9 GiB > old 8 GiB limit
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 400 * Self.gibibyte }
        // Stop at the first durable copy: every capacity check has passed by then.
        budget.observe = { if $0 == "copying_objects" { throw StopBeforeCopy() } }
        let operation = UUID()
        XCTAssertThrowsError(try f.build(operation, budget)) { error in
            XCTAssertTrue(error is StopBeforeCopy, "\(error)")
        }
        XCTAssertGreaterThan(budget.measurement.bytes, 8 * Self.gibibyte)
        XCTAssertEqual(budget.measurement.objects, 20)
        XCTAssertEqual(budget.measurement.availableBytes, 400 * Self.gibibyte)
        XCTAssertEqual(budget.effectiveMaximumBytes, 399 * Self.gibibyte)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(StorageSnapshot.names(operation).published).path))
    }

    func testFreeSpaceBudgetUsesTheLiveStoreSizes() throws {
        // Measured on 28 Oct 2026: 8,626,903,735 bytes; about 410 GiB free.
        let measured: Int64 = 8_626_903_735
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 430_260_952 * 1_024 }
        try budget.measureFreeSpace(URL(fileURLWithPath: "/unused"))
        XCTAssertNoThrow(try budget.requireFreeSpace(forMeasured: measured))
        XCTAssertNoThrow(try budget.adding(measured + 40_000_000, to: 0))
        // The same store on a volume with only 9 GB free is refused with the needed bytes.
        XCTAssertEqual(StorageSnapshotBudget.freeSpaceMargin(for: 20 * Self.gibibyte), 2 * Self.gibibyte)
        budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 9_000_000_000 }
        try budget.measureFreeSpace(URL(fileURLWithPath: "/unused"))
        XCTAssertThrowsError(try budget.requireFreeSpace(forMeasured: measured)) { error in
            let e = error as? CoreError
            XCTAssertEqual(e?.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(e?.details["reason"] as? String, "snapshot_free_space")
            XCTAssertEqual(e?.details["required_free_bytes"] as? Int64, 9_700_645_559)
            XCTAssertEqual(e?.details["free_space_margin_bytes"] as? Int64, Self.gibibyte) // 10% is below the 1 GiB minimum
            XCTAssertTrue(e?.message.contains("needs at least 9700645559 free bytes") == true)
        }
        // Growth past the volume during copying reports free space, not a fixed limit.
        XCTAssertThrowsError(try budget.adding(9_000_000_000, to: 0)) { error in
            guard case StorageSnapshotFailure.freeSpace(let measured) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(measured, 9_000_000_000)
            let reported = budget.reporting(error) as? CoreError
            XCTAssertEqual(reported?.details["reason"] as? String, "snapshot_free_space")
            XCTAssertEqual(reported?.details["required_free_bytes"] as? Int64, measured + Self.gibibyte)
            XCTAssertEqual(reported?.details["available_bytes"] as? Int64, 9_000_000_000)
        }
        // Less than the minimum margin free: refused before any staging directory exists.
        let f = try Fixture(), operation = UUID()
        budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 512 * 1_048_576 }
        XCTAssertThrowsError(try f.build(operation, budget)) { error in
            XCTAssertEqual((error as? CoreError)?.details["reason"] as? String, "snapshot_free_space")
            XCTAssertEqual((error as? CoreError)?.details["required_free_bytes"] as? Int64, Self.gibibyte)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(StorageSnapshot.names(operation).staging).path))
    }

    func testFixedByteCeilingStillReportsSnapshotCapacity() throws {
        let f = try Fixture()
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 400 * Self.gibibyte }
        budget.maximumBytes = 1
        XCTAssertThrowsError(try f.build(UUID(), budget)) { error in
            let e = error as? CoreError
            XCTAssertEqual(e?.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(e?.details["reason"] as? String, "snapshot_capacity")
            XCTAssertEqual(e?.details["maximum_bytes"] as? Int64, 1)
            XCTAssertTrue(e?.message.contains("Limits: 1 bytes, 500000 objects") == true)
        }
    }

    func testRestoreRefusesWhenTheCopyDoesNotFitFreeSpace() throws {
        let f = try Fixture()
        let backup = f.base.appendingPathComponent("restorable")
        _ = try f.ownerBackup("restorable")
        let preview = try f.router.handle(method: "restore_preview", params: ["path": backup.path], caller: f.owner)["data"] as! JSON
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 0 }
        let params: JSON = ["path": backup.path, "manifest_sha256": preview["manifest_sha256"]!, "command_id": UUID().uuidString]
        XCTAssertThrowsError(try f.router.executeStorageRestore(method: "restore_create", params: params, caller: f.owner, budget: budget)) { error in
            XCTAssertEqual((error as? CoreError)?.details["reason"] as? String, "snapshot_free_space")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("restore").path)
            && (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("restore").path).contains { $0.hasPrefix("restored-") }) == true)
    }

    func testObjectAndManifestLimitsStillRefuseWithActionableCounts() throws {
        let f = try Fixture()
        let source = f.root.appendingPathComponent("source-captures/project/capture/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("retained".utf8), sha = StorageObjectFiles.sha(bytes)
        for name in ["a", "b"] { try bytes.write(to: source.appendingPathComponent(name)) }
        _ = try f.capture(["a", "b"].map { ["path": $0, "kind": "file", "sha256": sha, "size": bytes.count] })
        for (kind, reason, limit, maximum) in [
            ("objects", "snapshot_object_capacity", "maximum_objects", 1),
            ("manifest", "snapshot_manifest_capacity", "maximum_manifest_bytes", 128),
            ("object_bytes", "snapshot_object_bytes", "maximum_object_bytes", 1)
        ] {
            var budget = StorageSnapshotBudget.production()
            budget.availableBytes = { _ in 400 * Self.gibibyte }
            if kind == "objects" { budget.maximumObjects = maximum }
            else if kind == "manifest" { budget.maximumManifestBytes = maximum }
            else { budget.maximumObjectBytes = Int64(maximum) }
            let operation = UUID()
            XCTAssertThrowsError(try f.build(operation, budget)) { error in
                let e = error as? CoreError
                XCTAssertEqual(e?.code, "BACKUP_CAPACITY_EXCEEDED")
                XCTAssertEqual(e?.details["reason"] as? String, reason)
                XCTAssertEqual((e?.details[limit] as? NSNumber)?.intValue, maximum)
                XCTAssertEqual(e?.details["measured_objects"] as? Int, kind == "object_bytes" ? 1 : 2)
                XCTAssertGreaterThan(e?.details["measured_bytes"] as? Int64 ?? 0, 0)
                XCTAssertNotNil(e?.details["next_step"])
                XCTAssertNil(e?.details["required_free_bytes"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(StorageSnapshot.names(operation).published).path))
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a")), bytes)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("b")), bytes)
    }

    func testUndeclaredFileSizeKeepsPerFileCapacityReason() throws {
        let f = try Fixture(), bytes = Data("retained".utf8)
        let output = f.root.appendingPathComponent("source-executions/project/run/output.txt")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: output)
        try f.save(["id": "run", "project_id": "project", "revision": 1, "state": "passed",
                    "output_path": output.path, "output_sha256": StorageObjectFiles.sha(bytes)], "source_execution")
        var budget = StorageSnapshotBudget.production()
        budget.availableBytes = { _ in 400 * Self.gibibyte }
        budget.maximumObjectBytes = 1
        XCTAssertThrowsError(try f.build(UUID(), budget)) { error in
            let e = error as? CoreError
            XCTAssertEqual(e?.details["reason"] as? String, "snapshot_object_bytes")
            XCTAssertEqual(e?.details["maximum_object_bytes"] as? Int64, 1)
            XCTAssertEqual(e?.details["measured_objects"] as? Int, 1)
            XCTAssertGreaterThan(e?.details["measured_bytes"] as? Int64 ?? 0, Int64(bytes.count))
            XCTAssertNil(e?.details["required_free_bytes"])
        }
    }

    func testCopyGrowthKeepsFreeSpaceFixedByteAndPerFileCausesSeparate() throws {
        for kind in ["free_space", "fixed_bytes", "object_bytes"] {
            let f = try Fixture(), bytes = Data("retained".utf8)
            let source = f.root.appendingPathComponent("source-captures/project/capture/source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("growing")
            try bytes.write(to: file)
            _ = try f.capture([["path": "growing", "kind": "file", "sha256": StorageObjectFiles.sha(bytes), "size": bytes.count]])
            var budget = StorageSnapshotBudget.production()
            budget.availableBytes = { _ in kind == "free_space" ? Self.gibibyte + 1_048_576 : 400 * Self.gibibyte }
            if kind == "fixed_bytes" { budget.maximumBytes = 1_048_576 }
            if kind == "object_bytes" { budget.maximumObjectBytes = 1_048_576 }
            // Grow after preflight but before the read handle opens. The copy
            // must refuse at the actual bound before writing beyond it.
            budget.observe = { if $0 == "copying_objects" { try Data(repeating: 1, count: 2 * 1_048_576).write(to: file) } }
            let operation = UUID()
            XCTAssertThrowsError(try f.build(operation, budget)) { error in
                let e = error as? CoreError
                let reason = kind == "free_space" ? "snapshot_free_space" : kind == "object_bytes" ? "snapshot_object_bytes" : "snapshot_capacity"
                XCTAssertEqual(e?.code, "BACKUP_CAPACITY_EXCEEDED")
                XCTAssertEqual(e?.details["reason"] as? String, reason)
                if kind == "free_space" {
                    XCTAssertGreaterThan(e?.details["required_free_bytes"] as? Int64 ?? 0, Self.gibibyte + 1_048_576)
                    XCTAssertEqual(e?.details["available_bytes"] as? Int64, Self.gibibyte + 1_048_576)
                } else {
                    let limit = kind == "object_bytes" ? "maximum_object_bytes" : "maximum_bytes"
                    XCTAssertEqual(e?.details[limit] as? Int64, 1_048_576)
                    XCTAssertNil(e?.details["required_free_bytes"])
                }
            }
            let names = StorageSnapshot.names(operation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(names.published).path))
            let partial = f.base.appendingPathComponent(names.staging + "/managed/source-captures/project/capture/source/growing")
            let copied = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as! NSNumber
            XCTAssertLessThanOrEqual(copied.int64Value, 1_048_576)
        }
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
