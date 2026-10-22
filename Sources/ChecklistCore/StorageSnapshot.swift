import Foundation
import GRDB

struct StorageSnapshotSource {
    let parent: URL
    let source: URL
    let storeID: String
    let publicationName: String?
    let permit: ArchiveStoragePermit
    init(source: URL, parent: URL, storeID: String, publicationName: String? = nil, permit: ArchiveStoragePermit) throws {
        try permit.requireRoot(source)
        guard UUID(uuidString: storeID) != nil else { throw StorageSnapshotFailure.unsupportedAuthority }
        if let publicationName { guard !publicationName.isEmpty, !publicationName.contains("/"), !publicationName.contains("\0"), publicationName != ".", publicationName != ".." else { throw StorageSnapshotFailure.unsupportedAuthority } }
        self.parent = parent; self.source = source; self.storeID = storeID; self.publicationName = publicationName; self.permit = permit
    }
}

struct StorageSnapshotMaterializedObject: Codable {
    let descriptor: StorageSnapshotObject
    let sha256: String
    let size: Int64
}
struct StorageSnapshotManifest: Codable {
    let format: Int
    let kind: String
    let operationID: String
    let storeID: String
    let sourceRoot: String
    let schema: Int
    let databaseSHA256: String
    let databaseSize: Int64
    let objects: [StorageSnapshotMaterializedObject]
    let unavailable: [StorageSnapshotAbsence]
    let externalReferences: [String]
}
struct StorageSnapshotReceipt {
    let kind = "checklist-store-snapshot"
    let operationID: UUID
    let manifestSHA256: String
    // No live protected-generation status, SQL completion row or drain attestation.
}

/// Capture runs under the current root's object permit. Native bootstrap must own
/// the supported service singleton before applying a schema change; the SQLite
/// lease alone cannot drain a previous process's filesystem continuation.
enum StorageSnapshot {
    static let kind = "checklist-store-snapshot"
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func names(_ operation: UUID, publicationName: String? = nil) -> (staging: String, published: String) {
        let suffix = operation.uuidString.lowercased()
        return (".snapshot-staging-" + suffix, publicationName ?? ("snapshot-" + suffix))
    }

    static func build(_ fixture: StorageSnapshotSource, operation: UUID,
                      budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
        do { return try prepareGeneration(fixture, operation: operation, budget: budget)() }
        catch { throw budget.reporting(error) }
    }

    /// Owner backup holds the crash-released retention barrier across capture,
    /// copying and publication. Only capture occupies the ordinary object gate.
    static func buildOnline(source: URL, parent: URL, storeID: String, publicationName: String,
                            operation: UUID, budget: StorageSnapshotBudget, retention: StorageSnapshotRetention) throws -> StorageSnapshotReceipt {
        try retention.requireRoot(source)
        do {
            let finish = try ArchiveStorageGate.withExclusive(root: source) { permit in
                try prepareGeneration(StorageSnapshotSource(source: source, parent: parent, storeID: storeID,
                    publicationName: publicationName, permit: permit), operation: operation, budget: budget)
            }
            try budget.observe("capture_released")
            return try finish()
        } catch { throw budget.reporting(error) }
    }

    /// The returned continuation touches only immutable source objects and its
    /// owned stage. Callers retain either the exclusive gate or a retention lease.
    private static func prepareGeneration(_ fixture: StorageSnapshotSource, operation: UUID,
                                          budget: StorageSnapshotBudget) throws -> () throws -> StorageSnapshotReceipt {
        try fixture.permit.requireRoot(fixture.source)
        try budget.check()
        guard budget.pagesPerStep > 0, budget.maximumBytes > 0, budget.maximumObjectBytes > 0,
              budget.maximumObjects > 0, budget.maximumRecords > 0, budget.maximumManifestBytes > 0 else { throw StorageSnapshotFailure.limit }
        let parent = try StorageObjectFiles(root: fixture.parent), sourceFiles = try StorageObjectFiles(root: fixture.source)
        let names = names(operation, publicationName: fixture.publicationName), stage = try parent.makeDirectory(names.staging)
        let intent = ["format": "1", "kind": kind, "operation_id": operation.uuidString.lowercased(), "store_id": fixture.storeID, "source_root": fixture.source.path]
        let intentData = try encoded(intent)
        let intentSize = try budget.adding(Int64(intentData.count), to: 0)
        try stage.writeNew("intent.json", bytes: intentData)
        // Do not clean staging in a defer. Restart must retain uncertain state.
        var writerConfiguration = Configuration()
        writerConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=50") }
        let writer = try DatabaseQueue(path: StorageBootstrap.writableURI(fixture.source.appendingPathComponent("checklist.sqlite")), configuration: writerConfiguration)
        defer { try? writer.close() }
        let (inventory, schema) = try writer.writeWithoutTransaction { lease -> (StorageSnapshotInventory, Int) in
            try lease.beginTransaction(.immediate)
            defer { try? lease.rollback() }
            try budget.observe("writer_lease_acquired")
            // The source is a distinct read-only connection; the lease connection
            // never calls backup while it owns a source write transaction.
            var readConfiguration = Configuration(); readConfiguration.readonly = true
            readConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA busy_timeout=50") }
            let source = try DatabaseQueue(path: fixture.source.appendingPathComponent("checklist.sqlite").path, configuration: readConfiguration)
            defer { try? source.close() }
            let pageSize = try source.read { db -> Int64 in
                _ = try SchemaMigrations.inspect(db)
                return try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            }
            guard pageSize > 0 else { throw StorageSnapshotFailure.incomplete }
            let destination = try DatabaseQueue(path: stage.root.appendingPathComponent("database.sqlite").path, configuration: writerConfiguration)
            var sawDone = false
            var callbackFailure: Error?
            do {
                try source.backup(to: destination, pagesPerStep: budget.pagesPerStep) { progress in
                    if progress.isCompleted { sawDone = true }
                    do {
                        try budget.observe(progress.isCompleted ? "backup_done" : "backup_step")
                        try budget.check()
                        let bound = Int64(progress.totalPageCount).multipliedReportingOverflow(by: pageSize)
                        guard !bound.overflow else { throw StorageSnapshotFailure.limit }
                        _ = try budget.adding(bound.partialValue, to: intentSize)
                    } catch { callbackFailure = error; throw error }
                }
                // GRDB ignores a throw from a completed callback. This separate
                // final check is required even when sawDone is true.
                try budget.check()
                if let callbackFailure { throw callbackFailure }
                guard sawDone else { throw StorageSnapshotFailure.incomplete }
                // Backup carries the WAL-format header. Normalize only this
                // owned copy to a self-contained rollback-journal database
                // before read-only reopening; no source PRAGMA is changed.
                try destination.writeWithoutTransaction { db in
                    guard try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")?.lowercased() == "delete" else { throw StorageSnapshotFailure.incomplete }
                }
                try destination.close()
                try stage.removeClosedCopySharedMemory()
            } catch { try? destination.close(); throw error }
            budget.measurement.metadataBytes = try stage.size("database.sqlite") + intentSize
            budget.measurement.bytes = budget.measurement.metadataBytes
            let copy = try DatabaseQueue(path: stage.root.appendingPathComponent("database.sqlite").path, configuration: readConfiguration)
            let inventory: StorageSnapshotInventory, schema: Int
            do {
                (inventory, schema) = try copy.read { db in
                    _ = try SchemaMigrations.inspect(db)
                    return (try StorageSnapshotAuthority.inventory(db, root: fixture.source, budget: budget, retainedExists: { try sourceFiles.regularOrLinkExists($0) }), try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1)
                }
                try copy.close()
            } catch { try? copy.close(); throw error }
            return (inventory, schema)
        }
        // Close the SQLite lease and all live/copy read connections before the
        // continuation, so ordinary writes and WAL checkpointing can proceed.
        return {
            // Measure the complete closed inventory before expensive durable copies.
            // Lengths are descriptor-relative/no-follow; copy still rehashes and
            // checks identity, expected size and digest independently afterwards.
            var measured = try stage.size("database.sqlite") + intentSize
            var oversized = false
            for object in inventory.objects {
                try budget.check()
                let size: Int64
                if object.kind == "file" {
                    size = try sourceFiles.size(object.relativePath)
                    guard object.expectedSize == nil || object.expectedSize == size else { throw StorageSnapshotFailure.sourceChanged }
                    oversized = oversized || size > budget.maximumObjectBytes
                } else { size = Int64(object.linkTarget?.utf8.count ?? 0) }
                let sum = measured.addingReportingOverflow(size)
                guard !sum.overflow else { throw StorageSnapshotFailure.limit }
                measured = sum.partialValue
            }
            budget.measurement.bytes = measured
            budget.measurement.objects = inventory.objects.count
            // Manifest bytes are added below, so this remains a lower bound.
            guard !oversized, measured <= budget.maximumBytes else { throw budget.capacityFailure("snapshot_capacity") }
            // Explicitly flush/close the copied DB before hashing it.
            try stage.synchronizeOwnedFile("database.sqlite")
            let database = try stage.digest("database.sqlite", budget: budget)
            var total = try budget.adding(database.1, to: intentSize)
            var materialized: [StorageSnapshotMaterializedObject] = []
            try budget.observe("copying_objects")
            for descriptor in inventory.objects where descriptor.kind == "file" {
                try budget.check()
                var remainingBudget = budget
                remainingBudget.maximumObjectBytes = min(budget.maximumObjectBytes, budget.maximumBytes - total)
                let value = try sourceFiles.copy(descriptor.relativePath, to: stage, expected: descriptor.expectedSHA256, budget: remainingBudget)
                guard descriptor.expectedSize == nil || descriptor.expectedSize == value.1 else { throw StorageSnapshotFailure.sourceChanged }
                total = try budget.adding(value.1, to: total)
                materialized.append(.init(descriptor: descriptor, sha256: value.0, size: value.1))
                try budget.observe("object_copied")
            }
            for descriptor in inventory.objects where descriptor.kind == "symlink" {
                try budget.check()
                guard let target = descriptor.linkTarget, try sourceFiles.linkTarget(descriptor.relativePath) == target,
                      let expected = descriptor.expectedSHA256 else { throw StorageSnapshotFailure.sourceChanged }
                total = try budget.adding(Int64(target.utf8.count), to: total)
                try stage.writeLink("managed/" + descriptor.relativePath, target: target)
                materialized.append(.init(descriptor: descriptor, sha256: expected, size: Int64(target.utf8.count)))
            }
            let manifest = StorageSnapshotManifest(format: 1, kind: kind, operationID: operation.uuidString.lowercased(),
                storeID: fixture.storeID, sourceRoot: fixture.source.path, schema: schema, databaseSHA256: database.0,
                databaseSize: database.1, objects: materialized.sorted { $0.descriptor.relativePath < $1.descriptor.relativePath },
                unavailable: inventory.unavailable, externalReferences: inventory.externalReferences)
            let manifestData = try encoded(manifest)
            budget.measurement.bytes = total + Int64(manifestData.count)
            budget.measurement.lowerBound = false
            guard manifestData.count <= budget.maximumManifestBytes else { throw budget.capacityFailure("snapshot_manifest_capacity") }
            total = try budget.adding(Int64(manifestData.count), to: total)
            try stage.writeNew("manifest.json", bytes: manifestData)
            try budget.observe("manifest_written")
            _ = try verify(stage, operation: operation, budget: budget)
            try budget.check()
            // After rename, a flush failure is publication-uncertain; it must
            // never trigger deletion of the published directory or source.
            try budget.observe("before_publish")
            try budget.check()
            try parent.publish(names.staging, as: names.published) { try budget.observe("published_before_parent_flush") }
            return try reconcile(parent: fixture.parent, operation: operation, publicationName: fixture.publicationName, budget: budget)
        }
    }

    static func reconcile(parent: URL, operation: UUID, publicationName: String? = nil, budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
        do { return try reconcileGeneration(parent: parent, operation: operation, publicationName: publicationName, budget: budget) }
        catch { throw budget.reporting(error) }
    }

    private static func reconcileGeneration(parent: URL, operation: UUID, publicationName: String?, budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
        let published = try StorageObjectFiles(root: parent.appendingPathComponent(names(operation, publicationName: publicationName).published, isDirectory: true))
        let digest = try verify(published, operation: operation, budget: budget)
        let containingDirectory = try StorageObjectFiles(root: parent)
        // Readability cannot establish the rename's required durability barrier.
        // Retry that barrier even when recovering a previously uncertain result.
        try containingDirectory.synchronizePublicationDirectory {
            try budget.observe("reconcile_before_parent_flush")
            try budget.check()
        }
        try budget.check()
        return .init(operationID: operation, manifestSHA256: digest)
    }

    /// An explicit same-command retry may finish a fully verified stage. A
    /// partial owned stage is retained under a unique incomplete name before
    /// rebuilding; neither original data nor a completed generation is deleted.
    static func resumeStaging(parent: URL, operation: UUID, publicationName: String, budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt? {
        let containing = try StorageObjectFiles(root:parent)
        let stageName = names(operation).staging
        let stage = try StorageObjectFiles(root:parent.appendingPathComponent(stageName,isDirectory:true))
        do {
            _ = try verify(stage,operation:operation,budget:budget)
        } catch {
            // IO/permission/full-volume failures may be transient; retaining the
            // stage is safe and the explicit retry can create a fresh attempt.
            try budget.check()
            let quarantine = ".snapshot-incomplete-" + operation.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
            try containing.publish(stageName,as:quarantine)
            return nil
        }
        try budget.check()
        try containing.publish(stageName,as:publicationName)
        return try reconcile(parent:parent,operation:operation,publicationName:publicationName,budget:budget)
    }

    private static func verify(_ files: StorageObjectFiles, operation: UUID, budget: StorageSnapshotBudget) throws -> String {
        try budget.check()
        let manifestSize = try files.size("manifest.json")
        guard manifestSize <= budget.maximumManifestBytes else { throw budget.capacityFailure("snapshot_manifest_capacity") }
        let manifestData = try files.read("manifest.json", maximum: budget.maximumManifestBytes)
        guard let shape = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any], Set(shape.keys) == [
            "format", "kind", "operationID", "storeID", "sourceRoot", "schema", "databaseSHA256", "databaseSize", "objects", "unavailable", "externalReferences"
        ] else { throw StorageSnapshotFailure.incomplete }
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: manifestData)
        guard manifest.format == 1, manifest.kind == kind, manifest.operationID == operation.uuidString.lowercased(),
              UUID(uuidString: manifest.storeID) != nil, [0, 1, 2, 3].contains(manifest.schema), manifest.objects.count <= budget.maximumObjects else { throw StorageSnapshotFailure.incomplete }
        let intentData = try files.read("intent.json", maximum: 1024)
        let intent = try JSONDecoder().decode([String: String].self, from: intentData)
        guard intent == ["format": "1", "kind": kind, "operation_id": manifest.operationID, "store_id": manifest.storeID, "source_root": manifest.sourceRoot] else { throw StorageSnapshotFailure.incomplete }
        let database = try files.digest("database.sqlite", budget: budget)
        guard database == (manifest.databaseSHA256, manifest.databaseSize) else { throw StorageSnapshotFailure.sourceChanged }
        var readConfiguration = Configuration(); readConfiguration.readonly = true
        readConfiguration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let copy = try DatabaseQueue(path: files.root.appendingPathComponent("database.sqlite").path, configuration: readConfiguration)
        let required: StorageSnapshotInventory
        budget.measurement.metadataBytes = database.1 + Int64(intentData.count) + Int64(manifestData.count)
        budget.measurement.bytes = budget.measurement.metadataBytes
        do {
            required = try copy.read { db in
                _ = try SchemaMigrations.inspect(db)
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == manifest.schema else { throw StorageSnapshotFailure.incomplete }
                let sourceRoot = URL(fileURLWithPath: manifest.sourceRoot, isDirectory: true)
                return try StorageSnapshotAuthority.inventory(db, root: sourceRoot, budget: budget, objectRoot: files.root.appendingPathComponent("managed"), retainedExists: { try files.regularOrLinkExists("managed/" + $0) })
            }
            try copy.close()
        } catch { try? copy.close(); throw error }
        guard manifest.objects.map(\.descriptor).sorted(by: { $0.relativePath < $1.relativePath }) == required.objects,
              manifest.unavailable == required.unavailable, manifest.externalReferences == required.externalReferences else { throw StorageSnapshotFailure.incomplete }
        var paths: Set<String> = ["intent.json", "manifest.json", "database.sqlite"]
        var total = try budget.adding(database.1, to: 0)
        total = try budget.adding(Int64(intentData.count), to: total)
        total = try budget.adding(Int64(manifestData.count), to: total)
        try StorageSnapshotAuthority.validateCapturedLinks(manifest.objects.map(\.descriptor))
        for object in manifest.objects {
            try budget.check()
            let path = "managed/" + object.descriptor.relativePath
            _ = try StorageObjectFiles.parts(path)
            guard paths.insert(path).inserted else { throw StorageSnapshotFailure.incomplete }
            if object.descriptor.kind == "file" {
                let value = try files.digest(path, budget: budget)
                guard value == (object.sha256, object.size), value.1 <= budget.maximumObjectBytes,
                      object.descriptor.expectedSHA256 == nil || object.descriptor.expectedSHA256 == value.0,
                      object.descriptor.expectedSize == nil || object.descriptor.expectedSize == value.1 else { throw StorageSnapshotFailure.sourceChanged }
                total = try budget.adding(value.1, to: total)
            } else if object.descriptor.kind == "symlink" {
                guard let target = object.descriptor.linkTarget, !target.hasPrefix("/"), !target.contains("\0"),
                      try files.linkTarget(path) == target, StorageObjectFiles.sha(Data(target.utf8)) == object.sha256,
                      object.sha256 == object.descriptor.expectedSHA256, object.size == Int64(target.utf8.count) else { throw StorageSnapshotFailure.sourceChanged }
                total = try budget.adding(Int64(target.utf8.count), to: total)
            } else { throw StorageSnapshotFailure.unsupportedAuthority }
        }
        guard try files.listedFiles(budget: budget) == paths else { throw StorageSnapshotFailure.incomplete }
        budget.measurement.bytes = total
        budget.measurement.objects = manifest.objects.count
        budget.measurement.lowerBound = false
        try budget.check()
        return StorageObjectFiles.sha(manifestData)
    }
}
