import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// Closed, disposable stores exercise startup rather than rewriting a running
/// database. The source and copy have separate ordinary files and no hardlinks.
final class ManagedPathRelocationTests: XCTestCase {
    private final class Fixture {
        let source: StorageFixture
        let root: URL
        let projectID: String
        let taskID: String
        let attachmentID: String
        let captureID = UUID().uuidString.lowercased()
        let manifestID = UUID().uuidString.lowercased()
        let executionID = UUID().uuidString.lowercased()
        let originalBytes = Data("copy-owned immutable original".utf8)
        let previewBytes = Data("copy-owned preview".utf8)
        let iconBytes = Data("copy-owned icon".utf8)
        let sourceBytes = Data("copy-owned captured source".utf8)
        let outputBytes = Data("copy-owned execution output".utf8)
        var original: String { "objects/relocation/original.bin" }
        var preview: String { "objects/relocation/preview.png" }
        var icon: String { "icons/relocation/icon.png" }
        var capture: String { "source-captures/" + projectID + "/" + captureID + "/source" }
        var output: String { "source-executions/" + executionID + "/output.log" }
        var expectedObjects: Set<String> { [original, preview, icon, capture + "/result.txt", capture + "/result-link", output] }
        var lease: StorageServiceLease?
        var router: CommandRouter?
        let owner = Caller(role: "owner", installation: "managed-relocation-fixture", projectIDs: [])

        init(schema: Int, inPlace: Bool = false, relative: Bool = false, outside: URL? = nil, mismatch: Bool = false, storePath: String = "relocated-store") throws {
            source = try StorageFixture()
            root = source.base.appendingPathComponent(storePath, isDirectory: true)
            let p = try source.project(), t = try source.task(p)
            projectID = p["id"] as! String; taskID = t["id"] as! String
            attachmentID = UUID().uuidString.lowercased()
            func write(_ value: Data, _ path: String) throws {
                let destination = source.root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try value.write(to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            try write(originalBytes, original); try write(previewBytes, preview)
            try write(iconBytes, icon); try write(sourceBytes, capture + "/result.txt")
            try write(outputBytes, output)
            try FileManager.default.createSymbolicLink(atPath: source.root.appendingPathComponent(capture + "/result-link").path, withDestinationPath: "result.txt")
            let origin = inPlace ? root : source.root
            func stored(_ path: String) -> String { relative ? path : origin.appendingPathComponent(path).path }
            var project = p
            project["icon_path"] = stored(icon)
            project["icon_asset"] = ["id": "relocation-icon", "sha256": ChecklistCore.hash(iconBytes)]
            let attachment: JSON = ["id": attachmentID, "project_id": projectID, "task_id": taskID, "artifact_id": attachmentID,
                "name": "original.bin", "mode": "managed", "path": outside?.path ?? stored(original), "preview_path": stored(preview),
                "sha256": ChecklistCore.hash(originalBytes), "size": originalBytes.count, "availability": "available",
                "keep_original": false, "unlinked": false, "revision": 1, "created_at": now()]
            let captured: JSON = ["id": captureID, "project_id": projectID, "task_id": taskID, "revision": 1,
                "snapshot_path": stored(capture), "source_root": source.workspace.path,
                "files": [["path": "result.txt", "kind": "file", "sha256": ChecklistCore.hash(sourceBytes), "size": sourceBytes.count, "executable": false],
                    ["path": "result-link", "kind": "symlink", "target": "result.txt", "sha256": ChecklistCore.hash(Data("result.txt".utf8))]],
                "sha256": ChecklistCore.hash(sourceBytes), "size": sourceBytes.count]
            let evidence: JSON = ["kind": "source", "source_capture": captured]
            let manifest: JSON = ["id": manifestID, "project_id": projectID, "task_id": taskID, "revision": 1,
                "evidence": evidence, "digest": ChecklistCore.hash(Data((try jsonString(evidence)).utf8))]
            let execution: JSON = ["id": executionID, "project_id": projectID, "task_id": taskID, "revision": 1,
                "state": "completed", "source_capture_id": captureID, "working_directory": stored(capture),
                "output_path": stored(output), "output_sha256": ChecklistCore.hash(outputBytes)]
            let records = try source.router!.dbQueue.read { db -> [(String, String?, String, Int, String)] in
                try Row.fetchAll(db, sql: "SELECT id,project_id,type,revision,data FROM records").map {
                    ($0["id"], $0["project_id"], $0["type"], $0["revision"], $0["data"])
                }
            }
            let identity = try source.router!.dbQueue.read { db in
                try StoreIdentityReceipt.decode(Data(try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='store_identity'")).utf8))
            }
            try source.close()
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.root, to: root)
            for name in ["checklist.sqlite", "checklist.sqlite-wal", "checklist.sqlite-shm", StoreIdentityReceipt.fileName] {
                let path = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            var configuration = Configuration()
            configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
            let queue = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: configuration)
            try queue.write { db in
                try db.execute(sql: schema < 2 ? SchemaMigrations.baselineSQL : SchemaMigrations.currentSQL)
                try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('incarnation',?)", arguments: [identity.incarnation])
                if schema != 0 {
                    try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('store_identity',?),('schema_migrations',?)", arguments: [
                        String(decoding: try identity.withSchema(schema).encoded(), as: UTF8.self), try jsonString(SchemaMigrations.ledgers(schema))])
                }
                for (id, scope, type, revision, raw) in records {
                    let value = id == projectID ? try jsonString(project) : raw
                    try db.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)", arguments: [id, scope, type, revision, value])
                }
                for (value, type) in [(attachment, "attachment"), (captured, "source_capture"), (manifest, "manifest"), (execution, "source_execution")] {
                    try db.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)", arguments: [value["id"] as! String, projectID, type, 1, try jsonString(value)])
                }
                try db.execute(sql: "PRAGMA user_version=\(schema)")
            }
            try queue.close()
            if schema != 0 { try identity.withSchema(schema).encoded().write(to: root.appendingPathComponent(StoreIdentityReceipt.fileName)) }
            if mismatch { try Data("wrong local immutable bytes".utf8).write(to: root.appendingPathComponent(original)) }
        }

        func open() throws {
            let held = try StorageServiceLease(root: root)
            let opened = try CommandRouter(root: root, serviceLease: held)
            lease = held; router = opened
        }
        func close() throws { try router?.closeStore(); router = nil; lease = nil }
        deinit { try? close(); try? FileManager.default.removeItem(at: root) }
        func call(_ method: String, _ input: JSON) throws -> JSON {
            var input = input
            if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString.lowercased() }
            let reply = try router!.handle(method: method, params: input, caller: owner)
            guard let data = reply["data"] as? JSON else { throw CoreError("FIXTURE_RESPONSE", "The owned fixture command returned no object data.") }
            return data
        }
        func record(_ id: String, _ type: String) throws -> JSON { try router!.dbQueue.read { try router!.record($0, id, type: type) } }
        func readClosed<T>(_ body: (Database) throws -> T) throws -> T {
            var configuration = Configuration(); configuration.readonly = true
            configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
            let queue = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read(body)
        }
        func protected() throws -> JSON { try router!.dbQueue.read { jsonObject(try XCTUnwrap(String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='preupgrade_snapshot'"))) } }
        func poisonOrigin() throws {
            for path in [original, preview, icon, capture + "/result.txt", output] {
                try Data(("origin must never be read: " + path).utf8).write(to: source.root.appendingPathComponent(path))
            }
        }
        func archiveAndRunCleanup() throws {
            var project = try record(projectID, "project")
            project = try call("archive_storage_settings", ["project_id": projectID, "expected_revision": project["revision"]!, "settings_revision": project["settings_revision"]!,
                "archive_storage": ["preset": "clean_large_managed_on_archive", "large_original_bytes": 1, "retained_budget_bytes": 0]])
            _ = project
            let task = try record(taskID, "task")
            let preview = try call("attachment_cleanup_preview", ["project_id": projectID, "task_id": taskID])
            _ = try call("task_archive", ["project_id": projectID, "task_id": taskID, "expected_revision": task["revision"]!, "action": "archive", "cleanup": true, "cleanup_preview_id": preview["cleanup_preview_id"]!])
            try router!.dbQueue.writeWithoutTransaction { db in
                try router!.withValidatedDomainTransaction(db) {
                    for var job in try router!.records(db, type: "cleanup_job", project: projectID) {
                        job["enqueued_at_ms"] = Int64(1); job["not_before_ms"] = Int64(2)
                        job["revision"] = try router!.nextCleanupJobRevision(job)
                        try router!.save(db, job, type: "cleanup_job")
                    }
                    return .commit
                }
            }
            try router!.runStorageMaintenance()
        }
    }

    private func assertMoved(_ f: Fixture, schema: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try StorageObjectFiles(root: f.root)
        let before = try f.readClosed { try StorageSnapshotAuthority.inventory($0, root: f.root, budget: .production(), retainedExists: files.regularOrLinkExists) }
        let manifestBefore = try f.readClosed { try XCTUnwrap(String.fetchOne($0, sql: "SELECT data FROM records WHERE id=?", arguments: [f.manifestID])) }
        let evidenceBefore = try XCTUnwrap(jsonObject(manifestBefore)["evidence"] as? JSON)
        let evidenceHashBefore = ChecklistCore.hash(Data((try jsonString(evidenceBefore)).utf8))
        XCTAssertEqual(Set(before.objects.map(\.relativePath)), f.expectedObjects, file: file, line: line)
        XCTAssertNil(try ManagedPaths.resolve(f.source.root.appendingPathComponent(f.original).path, family: "objects", root: f.root), file: file, line: line)
        try f.poisonOrigin()
        try f.open()
        XCTAssertEqual(try f.router!.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, SchemaMigrations.currentSchema, file: file, line: line)
        let protection = try f.protected(), protectedRoot = URL(fileURLWithPath: try XCTUnwrap(protection["path"] as? String))
        XCTAssertEqual(protection["protected"] as? Bool, true, file: file, line: line)
        let bytes = try Data(contentsOf: protectedRoot.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ChecklistCore.hash(bytes), protection["manifest_sha256"] as? String, file: file, line: line)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: bytes)
        XCTAssertEqual(manifest.schema, schema, file: file, line: line)
        XCTAssertEqual(manifest.sourceRoot, f.root.path, file: file, line: line)
        XCTAssertEqual(Set(manifest.objects.map { $0.descriptor.relativePath }), f.expectedObjects, file: file, line: line)
        var readOnly = Configuration(); readOnly.readonly = true
        readOnly.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let protectedDatabase = try DatabaseQueue(path: protectedRoot.appendingPathComponent("database.sqlite").path, configuration: readOnly)
        try protectedDatabase.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), schema, file: file, line: line)
            let stored = jsonObject(try XCTUnwrap(String.fetchOne(db, sql: "SELECT data FROM records WHERE id=?", arguments: [f.attachmentID])))
            XCTAssertEqual(stored["path"] as? String, f.source.root.appendingPathComponent(f.original).path, file: file, line: line)
        }
        try protectedDatabase.close()
        for object in manifest.objects {
            XCTAssertFalse(object.descriptor.relativePath.hasPrefix("/"), file: file, line: line)
            XCTAssertTrue(FileManager.default.fileExists(atPath: protectedRoot.appendingPathComponent("managed/" + object.descriptor.relativePath).path), file: file, line: line)
        }
        let attachment = try f.record(f.attachmentID, "attachment"), project = try f.record(f.projectID, "project")
        let capture = try f.record(f.captureID, "source_capture"), execution = try f.record(f.executionID, "source_execution")
        let retainedManifest = try f.record(f.manifestID, "manifest")
        let evidenceAfter = try XCTUnwrap(retainedManifest["evidence"] as? JSON)
        let nested = try XCTUnwrap(evidenceAfter["source_capture"] as? JSON)
        let manifestAfter = try f.router!.dbQueue.read { try XCTUnwrap(String.fetchOne($0, sql: "SELECT data FROM records WHERE id=?", arguments: [f.manifestID])) }
        XCTAssertEqual(manifestAfter, manifestBefore, "Review manifests retain their exact immutable bytes.", file: file, line: line)
        XCTAssertEqual(ChecklistCore.hash(Data(manifestAfter.utf8)), ChecklistCore.hash(Data(manifestBefore.utf8)), file: file, line: line)
        XCTAssertEqual(ChecklistCore.hash(Data((try jsonString(evidenceAfter)).utf8)), evidenceHashBefore, file: file, line: line)
        XCTAssertEqual(retainedManifest["digest"] as? String, evidenceHashBefore, file: file, line: line)
        let retainedPath = try XCTUnwrap(nested["snapshot_path"] as? String)
        XCTAssertEqual(retainedPath, f.source.root.appendingPathComponent(f.capture).path, file: file, line: line)
        XCTAssertEqual(f.router!.managedCapturePaths[Data(retainedPath.utf8)], f.capture, file: file, line: line)
        XCTAssertEqual(try f.router!.managedURL(retainedPath, family: "source-captures").path, f.root.appendingPathComponent(f.capture).path, file: file, line: line)
        for (stored, relative, family) in [(attachment["path"], f.original, "objects"), (attachment["preview_path"], f.preview, "objects"),
            (project["icon_path"], f.icon, "icons"), (capture["snapshot_path"], f.capture, "source-captures"),
            (execution["output_path"], f.output, "source-executions"),
            (execution["working_directory"], f.capture, "source-captures")] {
            XCTAssertEqual(stored as? String, relative, file: file, line: line)
            let resolved = try XCTUnwrap(ManagedPaths.resolve(try XCTUnwrap(stored as? String), family: family, root: f.root))
            XCTAssertTrue(resolved.path.hasPrefix(f.root.path + "/"), file: file, line: line)
        }
        for representation in ["original", "preview"] {
            let response = try f.call("attachment_read", ["project_id": f.projectID, "attachment_id": f.attachmentID, "representation": representation])
            let url = URL(fileURLWithPath: try XCTUnwrap(response["url"] as? String))
            XCTAssertTrue(url.path.hasPrefix(f.root.path + "/"), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: url), representation == "original" ? f.originalBytes : f.previewBytes, file: file, line: line)
            if let hold = response["read_hold_id"] { _ = try f.call("attachment_read_release", ["project_id": f.projectID, "read_hold_id": hold]) }
        }
        let destination = f.source.base.appendingPathComponent("export-\(schema)")
        _ = try f.call("export_project", ["project_id": f.projectID, "path": destination.path])
        let portable = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("project.json"))) as? JSON)
        let exportedAttachment = try XCTUnwrap((portable["attachment"] as? [JSON])?.first)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(try XCTUnwrap(exportedAttachment["path"] as? String))), f.originalBytes, file: file, line: line)
        let exportedProject = try XCTUnwrap(portable["project"] as? JSON)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(try XCTUnwrap(exportedProject["icon_path"] as? String))), f.iconBytes, file: file, line: line)
        let exportedCapture = try XCTUnwrap((portable["source_capture"] as? [JSON])?.first)
        let exportedSource = destination.appendingPathComponent(try XCTUnwrap(exportedCapture["snapshot_path"] as? String))
        XCTAssertEqual(try Data(contentsOf: exportedSource.appendingPathComponent("result.txt")), f.sourceBytes, file: file, line: line)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: exportedSource.appendingPathComponent("result-link").path), "result.txt", file: file, line: line)
        let exportedExecution = try XCTUnwrap((portable["source_execution"] as? [JSON])?.first)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(try XCTUnwrap(exportedExecution["output_path"] as? String))), f.outputBytes, file: file, line: line)
        let backup = f.source.base.appendingPathComponent("post-migration-backup-\(schema)")
        _ = try f.call("backup_create", ["path": backup.path])
        let backupManifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
        XCTAssertEqual(Set(backupManifest.objects.map { $0.descriptor.relativePath }), f.expectedObjects, file: file, line: line)
        let fingerprint = try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }
        try f.close(); try f.open()
        XCTAssertEqual(try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }, fingerprint, file: file, line: line)
        XCTAssertEqual(try jsonString(f.protected()), try jsonString(protection), file: file, line: line)
    }

    func testSchemaZeroCopyProtectsAndRelocatesEveryManagedFamilyBeforeNormalStartup() throws {
        try assertMoved(Fixture(schema: 0), schema: 0)
    }

    func testSchemaTwoCopyProtectsAndRelocatesEveryManagedFamilyBeforeNormalStartup() throws {
        try assertMoved(Fixture(schema: 2), schema: 2)
    }

    func testInPlaceLegacyPathsMigrateOnlyAfterProtectionAndRestartDoesNothing() throws {
        let f = try Fixture(schema: 2, inPlace: true)
        try f.open()
        let protection = try f.protected()
        XCTAssertEqual(protection["protected"] as? Bool, true)
        XCTAssertEqual(try f.record(f.attachmentID, "attachment")["path"] as? String, f.original)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(ManagedPaths.resolve(f.original, family: "objects", root: f.root))), f.originalBytes)
        let manifestRoot = URL(fileURLWithPath: try XCTUnwrap(protection["path"] as? String))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: Data(contentsOf: manifestRoot.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schema, 2)
        XCTAssertEqual(Set(manifest.objects.map { $0.descriptor.relativePath }), f.expectedObjects)
        let fingerprint = try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }
        try f.close(); try f.open()
        XCTAssertEqual(try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }, fingerprint)
        XCTAssertEqual(try jsonString(f.protected()), try jsonString(protection))
    }

    func testInterruptedSchemaOneToTwoReceiptStillProtectsBeforeUpgradingToThree() throws {
        let f = try Fixture(schema: 1, inPlace: true)
        let receipt = f.root.appendingPathComponent(StoreIdentityReceipt.fileName)
        let original = try StoreIdentityReceipt.decode(Data(contentsOf: receipt))
        try original.withSchema(2).withState("preparing").encoded().write(to: receipt)
        try f.open()
        XCTAssertEqual(try f.router!.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, SchemaMigrations.currentSchema)
        let ready = try StoreIdentityReceipt.decode(Data(contentsOf: receipt))
        XCTAssertEqual(ready, original.withSchema(SchemaMigrations.currentSchema).withState("ready"))
        let protection = try f.protected()
        XCTAssertEqual(protection["protected"] as? Bool, true)
        let generation = URL(fileURLWithPath: try XCTUnwrap(protection["path"] as? String))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: Data(contentsOf: generation.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schema, 1)
        XCTAssertEqual(Set(manifest.objects.map { $0.descriptor.relativePath }), f.expectedObjects)
        for (value, relative, family) in [
            (try f.record(f.attachmentID, "attachment")["path"], f.original, "objects"),
            (try f.record(f.attachmentID, "attachment")["preview_path"], f.preview, "objects"),
            (try f.record(f.projectID, "project")["icon_path"], f.icon, "icons"),
            (try f.record(f.captureID, "source_capture")["snapshot_path"], f.capture, "source-captures"),
            (try f.record(f.executionID, "source_execution")["output_path"], f.output, "source-executions"),
            (try f.record(f.executionID, "source_execution")["working_directory"], f.capture, "source-captures")] {
            XCTAssertEqual(value as? String, relative)
            XCTAssertEqual(try f.router!.managedURL(try XCTUnwrap(value as? String), family: family).path, f.root.appendingPathComponent(relative).path)
        }
    }

    func testCurrentRelativeCopyNeedsNoRelocationOrProtectedUpgrade() throws {
        let f = try Fixture(schema: SchemaMigrations.currentSchema, relative: true)
        try f.poisonOrigin(); try f.open()
        XCTAssertNil(try f.router!.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='preupgrade_snapshot'") })
        XCTAssertEqual(try f.record(f.attachmentID, "attachment")["path"] as? String, f.original)
        let read = try f.call("attachment_read", ["project_id": f.projectID, "attachment_id": f.attachmentID, "representation": "original"])
        let url = URL(fileURLWithPath: try XCTUnwrap(read["url"] as? String))
        XCTAssertEqual(url.path, f.root.appendingPathComponent(f.original).path)
        XCTAssertEqual(try Data(contentsOf: url), f.originalBytes)
        _ = try f.call("attachment_read_release", ["project_id": f.projectID, "read_hold_id": read["read_hold_id"]!])
        let fingerprint = try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }
        try f.close(); try f.open()
        XCTAssertEqual(try f.router!.dbQueue.read { try restartFingerprint($0, root: f.root) }, fingerprint)
    }

    func testResolverRefusesOutsideTraversalWrongFamilyAndSymlinkWithoutFollowingThem() throws {
        let f = try Fixture(schema: 2)
        XCTAssertEqual(try ManagedPaths.relative(f.original, family: "objects", root: f.root), f.original)
        XCTAssertEqual(try ManagedPaths.relative(f.root.appendingPathComponent(f.original).path, family: "objects", root: f.root), f.original)
        XCTAssertNil(try ManagedPaths.relative(f.source.root.appendingPathComponent(f.original).path, family: "objects", root: f.root))
        for value in ["objects/../outside", "objects/./original", "icons/wrong-family.png", "objects/NUL\0suffix", "file:///tmp/outside"] {
            XCTAssertThrowsError(try ManagedPaths.resolve(value, family: "objects", root: f.root), value)
        }
        let link = f.root.appendingPathComponent("objects/escaped")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source.root.appendingPathComponent("objects/relocation"))
        XCTAssertThrowsError(try ManagedPaths.resolve("objects/escaped/original.bin", family: "objects", root: f.root))
    }

    func testInPlaceRootMayContainManagedFamilyNamesWithoutAmbiguousOriginGuessing() throws {
        let f = try Fixture(schema: 2, inPlace: true, storePath: "objects/icons/source-captures/source-executions/instance")
        let path = f.root.appendingPathComponent(f.original).path
        XCTAssertEqual(try ManagedPaths.relative(path, family: "objects", root: f.root), f.original)
        try f.open()
        XCTAssertEqual(try f.record(f.attachmentID, "attachment")["path"] as? String, f.original)
        XCTAssertEqual(try f.router!.managedURL(f.original, family: "objects").path, path)
        let sourceSentinel = f.source.root.appendingPathComponent(f.original), before = try observation(sourceSentinel)
        let directory = f.root.appendingPathComponent("objects/relocation")
        try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("objects/retained"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: sourceSentinel.deletingLastPathComponent())
        XCTAssertThrowsError(try f.router!.managedURL(f.original, family: "objects"))
        XCTAssertThrowsError(try f.call("attachment_read", ["project_id": f.projectID, "attachment_id": f.attachmentID, "representation": "original"]))
        XCTAssertEqual(try observation(sourceSentinel), before)
    }

    func testRelocatedOriginContainingFamilyNamesUsesOneCommonProvenPrefix() throws {
        let f = try Fixture(schema: 2)
        // This origin is never created or opened. Its family-named ancestors
        // leave exactly one common prefix across the complete descriptor set.
        let origin = f.source.base.appendingPathComponent("uncreated/objects/icons/source-captures/source-executions/origin", isDirectory: true)
        let oldPrefix = f.source.root.path + "/", newPrefix = origin.path + "/"
        func rewrite(_ value: inout JSON, type: String) throws {
            let keys: [String]
            switch type {
            case "attachment": keys = ["path", "preview_path"]
            case "project": keys = ["icon_path"]
            case "source_capture": keys = ["snapshot_path"]
            case "source_execution": keys = ["output_path", "working_directory"]
            case "manifest":
                if var evidence = value["evidence"] as? JSON, var capture = evidence["source_capture"] as? JSON {
                    try rewrite(&capture, type: "source_capture")
                    evidence["source_capture"] = capture; value["evidence"] = evidence
                    value["digest"] = ChecklistCore.hash(Data((try jsonString(evidence)).utf8))
                }
                keys = []
            default: keys = []
            }
            for key in keys {
                if let path = value[key] as? String, path.hasPrefix(oldPrefix) { value[key] = newPrefix + String(path.dropFirst(oldPrefix.count)) }
            }
        }
        var configuration = Configuration(); configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("checklist.sqlite").path, configuration: configuration)
        try queue.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT rowid,type,data FROM records") {
                let rowID: Int64 = row["rowid"], type: String = row["type"], raw: String = row["data"]
                var value = jsonObject(raw); try rewrite(&value, type: type)
                try db.execute(sql: "UPDATE records SET data=? WHERE rowid=?", arguments: [try jsonString(value), rowID])
            }
        }
        let before = try queue.read { try XCTUnwrap(String.fetchOne($0, sql: "SELECT data FROM records WHERE id=?", arguments: [f.manifestID])) }
        try queue.close(); try f.open()
        let protection = try f.protected(), generation = URL(fileURLWithPath: try XCTUnwrap(protection["path"] as? String))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: Data(contentsOf: generation.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.schema, 2)
        XCTAssertEqual(Set(manifest.objects.map { $0.descriptor.relativePath }), f.expectedObjects)
        for (value, relative, family) in [
            (try f.record(f.attachmentID, "attachment")["path"], f.original, "objects"),
            (try f.record(f.attachmentID, "attachment")["preview_path"], f.preview, "objects"),
            (try f.record(f.projectID, "project")["icon_path"], f.icon, "icons"),
            (try f.record(f.captureID, "source_capture")["snapshot_path"], f.capture, "source-captures"),
            (try f.record(f.executionID, "source_execution")["output_path"], f.output, "source-executions"),
            (try f.record(f.executionID, "source_execution")["working_directory"], f.capture, "source-captures")] {
            XCTAssertEqual(value as? String, relative)
            XCTAssertEqual(try f.router!.managedURL(try XCTUnwrap(value as? String), family: family).path, f.root.appendingPathComponent(relative).path)
        }
        let after = try f.router!.dbQueue.read { try XCTUnwrap(String.fetchOne($0, sql: "SELECT data FROM records WHERE id=?", arguments: [f.manifestID])) }
        XCTAssertEqual(after, before)
        XCTAssertEqual(ChecklistCore.hash(Data(after.utf8)), ChecklistCore.hash(Data(before.utf8)))
        let retained = (try f.record(f.manifestID, "manifest")["evidence"] as! JSON)["source_capture"] as! JSON
        let retainedPath = try XCTUnwrap(retained["snapshot_path"] as? String)
        XCTAssertEqual(retainedPath, origin.appendingPathComponent(f.capture).path)
        XCTAssertEqual(try f.router!.managedURL(retainedPath, family: "source-captures").path, f.root.appendingPathComponent(f.capture).path)
    }

    func testCompletedSnapshotReconcilesWhenBothOriginAndCopyRootsAreGone() throws {
        let f = try Fixture(schema: 2)
        try f.open()
        let backup = f.source.base.appendingPathComponent("independent-backup")
        let receipt = try f.call("backup_create", ["path": backup.path])
        let operation = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(receipt["operation_id"] as? String)))
        let digest = try XCTUnwrap(receipt["manifest_sha256"] as? String)
        try f.close()
        try FileManager.default.moveItem(at: f.source.root, to: f.source.base.appendingPathComponent("origin-preserved"))
        try FileManager.default.moveItem(at: f.root, to: f.source.base.appendingPathComponent("copy-preserved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        let verified = try StorageSnapshot.reconcile(parent: f.source.base, operation: operation, publicationName: backup.lastPathComponent, budget: .production())
        XCTAssertEqual(verified.manifestSHA256, digest)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("managed/" + f.original)), f.originalBytes)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("managed/" + f.capture + "/result.txt")), f.sourceBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: backup.appendingPathComponent("managed/" + f.capture + "/result-link").path), "result.txt")
    }

    func testCopyArchiveAndPendingOrphanCleanupOnlyRemoveCopyOwnedObjects() throws {
        let f = try Fixture(schema: 2)
        let originOriginal = f.source.root.appendingPathComponent(f.original), before = try observation(originOriginal)
        try f.open()
        let pending = PendingSourceCapture(id: UUID().uuidString.lowercased(), namespace: "project-" + ChecklistCore.hash(Data(f.projectID.utf8)))
        for root in [f.root, f.source.root] {
            let file = root.appendingPathComponent(pending.directory + "/source/orphan.txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("owned orphan".utf8).write(to: file)
        }
        let originOrphan = f.source.root.appendingPathComponent(pending.directory + "/source/orphan.txt"), orphanBefore = try observation(originOrphan)
        try f.router!.recordPendingSourceCapture(pending)
        try f.router!.dbQueue.writeWithoutTransaction { try f.router!.sweepPendingSourceCaptures($0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(pending.directory).path))
        XCTAssertEqual(try observation(originOrphan), orphanBefore)
        try f.archiveAndRunCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.original).path))
        XCTAssertEqual(try f.record(f.attachmentID, "attachment")["availability"] as? String, "original_cleaned")
        XCTAssertEqual(try observation(originOriginal), before)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(f.preview)), f.previewBytes)
    }

    func testUnprovedOutsideAbsoluteIsUnavailableAndSourceSentinelSurvivesExportInventoryAndCleanup() throws {
        let outer = try StorageFixture(open: false)
        let sentinel = outer.base.appendingPathComponent("outside/objects/sentinel.bin")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outside sentinel must survive".utf8).write(to: sentinel)
        let before = try observation(sentinel)
        let f = try Fixture(schema: 2, outside: sentinel)
        XCTAssertNil(try ManagedPaths.resolve(sentinel.path, family: "objects", root: f.root))
        let files = try StorageObjectFiles(root: f.root)
        let inventory = try f.readClosed { try StorageSnapshotAuthority.inventory($0, root: f.root, budget: .production(), retainedExists: files.regularOrLinkExists) }
        XCTAssertFalse(inventory.objects.contains { $0.authorities.contains("attachment:" + f.attachmentID + ":original") })
        XCTAssertTrue(inventory.unavailable.contains { $0.authority.hasPrefix("attachment:" + f.attachmentID) })
        try f.open()
        XCTAssertThrowsError(try f.call("attachment_read", ["project_id": f.projectID, "attachment_id": f.attachmentID, "representation": "original"]))
        let export = f.source.base.appendingPathComponent("unavailable-export")
        // An export may preserve explicit absence or refuse the incomplete source
        // set. Neither outcome grants access to the outside path.
        _ = try? f.call("export_project", ["project_id": f.projectID, "path": export.path])
        let backup = f.source.base.appendingPathComponent("unavailable-backup")
        _ = try f.call("backup_create", ["path": backup.path])
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.unavailable.contains { $0.authority.hasPrefix("attachment:" + f.attachmentID) })
        try f.archiveAndRunCleanup()
        try f.router!.runStorageMaintenance()
        XCTAssertEqual(try observation(sentinel), before)
    }

    func testRelocationRejectsMismatchedLocalDigestWithoutReadingTheOrigin() throws {
        let f = try Fixture(schema: 2, mismatch: true)
        let sentinel = f.source.root.appendingPathComponent(f.original), before = try observation(sentinel)
        let files = try StorageObjectFiles(root: f.root)
        let inventory = try f.readClosed { try StorageSnapshotAuthority.inventory($0, root: f.root, budget: .production(), retainedExists: files.regularOrLinkExists) }
        XCTAssertFalse(inventory.objects.contains { $0.authorities.contains("attachment:" + f.attachmentID + ":original") })
        XCTAssertTrue(inventory.unavailable.contains { $0.authority.hasPrefix("attachment:" + f.attachmentID) })
        try f.open()
        XCTAssertThrowsError(try f.call("attachment_read", ["project_id": f.projectID, "attachment_id": f.attachmentID, "representation": "original"]))
        // Correcting local bytes cannot silently authorize an unproved absolute
        // descriptor after the protected schema upgrade has already finished.
        try f.originalBytes.write(to: f.root.appendingPathComponent(f.original))
        let filesAfter = try StorageObjectFiles(root: f.root)
        let after = try f.router!.dbQueue.read { try StorageSnapshotAuthority.inventory($0, root: f.root, budget: .production(), retainedExists: filesAfter.regularOrLinkExists) }
        XCTAssertFalse(after.objects.contains { $0.authorities.contains("attachment:" + f.attachmentID + ":original") })
        XCTAssertTrue(after.unavailable.contains { $0.authority.hasPrefix("attachment:" + f.attachmentID) })
        XCTAssertEqual(try observation(sentinel), before)
    }

    func testExplicitBackupRelocationDecisionIsReadOnly() throws {
        guard let selected = ProcessInfo.processInfo.environment["CHECKLIST_RELOCATION_BACKUP"] else {
            throw XCTSkip("Requires the explicitly selected backup database. No service or writable store is opened.")
        }
        let input = URL(fileURLWithPath: selected).standardizedFileURL
        let objectRoot = input.deletingLastPathComponent().appendingPathComponent("managed", isDirectory: true)
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-1/data", isDirectory: true)
        let inputBefore = ChecklistCore.hash(try Data(contentsOf: input))
        var uri = try XCTUnwrap(URLComponents(url: input, resolvingAgainstBaseURL: false))
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let queue = try DatabaseQueue(path: try XCTUnwrap(uri.string), configuration: configuration)
        defer { try? queue.close() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try queue.read { db -> JSON in
            let plan = try ManagedPathRelocation.plan(db, root: destination, budget: .production(), objectRoot: objectRoot)
            var total = 0, relocated = 0, alreadyLocal = 0, unavailable: [String: Int] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid")
            while let row = try rows.next() {
                let envelope = try GRDBRecordEnvelopeAdapter.decode(row)
                for field in try ManagedPathRelocation.fields(envelope.object, type: envelope.type) {
                    total += 1
                    let decision = try plan.decision(field.stored, family: field.family, root: destination)
                    if decision.relative == nil { unavailable[decision.reason ?? "outside_store_root", default: 0] += 1 }
                    else if field.stored.hasPrefix("/") { relocated += 1 }
                    else { alreadyLocal += 1 }
                }
            }
            return ["input_database_sha256": inputBefore, "managed_value_occurrences": total, "relocated_value_occurrences": relocated,
                "already_relative_value_occurrences": alreadyLocal, "unavailable_value_occurrences_by_reason": unavailable,
                "unique_outside_descriptors": plan.decisions.count, "destination_root": destination.path,
                "source_access": "mode=ro&immutable=1; local backup managed files only; no service, store copy or writes",
                "seconds": ProcessInfo.processInfo.systemUptime - started]
        }
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf: input)), inputBefore)
        print("CL170 read-only backup relocation: " + (try jsonString(result)))
    }

    private struct Observation: Equatable {
        let bytes: Data
        let inode: UInt64
        let device: Int32
        let modificationSeconds: Int
        let modificationNanoseconds: Int
    }
    /// Routine cursor and retention bookkeeping can run at every startup.
    /// Compare domain bytes, migration authority and the snapshot generations.
    private func restartFingerprint(_ db: Database, root: URL) throws -> String {
        var state: [String: [[String]]] = [:]
        for table in ["metadata", "records"] {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(" + table + ")").map { $0["name"] as String }
            let selections = (table == "metadata" ? [] : ["rowid"]) + columns
            let sql = "SELECT " + selections.flatMap { ["typeof(" + $0 + ")", "hex(CAST(" + $0 + " AS BLOB))"] }.joined(separator: ",")
                + " FROM " + table
                + (table == "metadata" ? " WHERE key IN ('incarnation','store_identity','schema_migrations','preupgrade_snapshot','managed-capture-paths-v3')" : "")
                + " ORDER BY " + (table == "metadata" ? "key" : "rowid")
            state[table] = try Row.fetchAll(db, sql: sql).map { row in (0..<row.count).map { row[$0] as String } }
        }
        state["schema"] = [[String(try XCTUnwrap(Int.fetchOne(db, sql: "PRAGMA user_version")))]]
        let backups = root.appendingPathComponent("backups")
        state["snapshot_generations"] = [(try? FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()) ?? []]
        return ChecklistCore.hash(Data((try jsonString(state)).utf8))
    }
    private func observation(_ url: URL) throws -> Observation {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CoreError("FIXTURE_STAT_FAILED", "The owned sentinel is missing.") }
        return Observation(bytes: try Data(contentsOf: url), inode: UInt64(info.st_ino), device: info.st_dev,
            modificationSeconds: info.st_mtimespec.tv_sec, modificationNanoseconds: info.st_mtimespec.tv_nsec)
    }
}
