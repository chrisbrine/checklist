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
    var recordFamilies: [String:Int]? = nil
    var tableRows: [String:Int]? = nil
    // Added without changing format 1; older verified generations have no time.
    var capturedAt: String? = nil
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
    /// copying and publication. Only the database copy occupies the ordinary object gate.
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
        let parent = try StorageObjectFiles(root: fixture.parent,folderAccess:budget.folderAccess), sourceFiles = try StorageObjectFiles(root: fixture.source,folderAccess:budget.folderAccess)
        let names = names(operation, publicationName: fixture.publicationName), stage = try parent.makeDirectory(names.staging, batchSynchronization: true)
        let intent = ["format": "2", "kind": kind, "operation_id": operation.uuidString.lowercased(), "store_id": fixture.storeID, "source_root": fixture.source.path]
        let intentData = try encoded(intent)
        let intentSize = try budget.adding(Int64(intentData.count), to: 0)
        try stage.writeNew("intent.json", bytes: intentData)
        // Do not clean staging in a defer. Restart must retain uncertain state.
        var writerConfiguration = Configuration()
        writerConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=50") }
        let writer = try DatabaseQueue(path: StorageBootstrap.writableURI(fixture.source.appendingPathComponent("checklist.sqlite")), configuration: writerConfiguration)
        defer { try? writer.close() }
        let capturedAt = try writer.writeWithoutTransaction { lease -> String in
            try lease.beginTransaction(.immediate)
            let leaseStarted = budget.uptime()
            defer {
                try? lease.rollback()
                budget.measurement.writerLeaseSeconds = budget.uptime() - leaseStarted
            }
            try budget.observe("writer_lease_acquired")
            let capturedAt = now() // Source writes are fenced by this lease.
            // The source is a distinct read-only connection; the lease connection
            // never calls backup while it owns a source write transaction.
            var readConfiguration = Configuration(); readConfiguration.readonly = true
            readConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA busy_timeout=50") }
            let source = try DatabaseQueue(path: fixture.source.appendingPathComponent("checklist.sqlite").path, configuration: readConfiguration)
            defer { try? source.close() }
            // Validate the completed copy below. A live quick_check scans the
            // entire store and must not extend this consistent-copy lease.
            let pageSize = try source.read { db -> Int64 in
                try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
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
            } catch { try? destination.close(); throw error }
            try destination.close()
            return capturedAt
        }
        try writer.close()
        try budget.observe("writer_lease_released")
        // The continuation runs after the ordinary gate is released for online
        // capture. Retention protects the whole immutable namespace before its
        // inventory is known, including pending imports and recovery objects.
        return {
            // Normalize only the owned copy after releasing the source writer.
            // Backup carries the WAL-format header; read-only reopening requires
            // a self-contained rollback-journal copy. No source PRAGMA changes.
            let destination = try DatabaseQueue(path: stage.root.appendingPathComponent("database.sqlite").path, configuration: writerConfiguration)
            do {
                try destination.writeWithoutTransaction { db in
                    guard try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")?.lowercased() == "delete" else { throw StorageSnapshotFailure.incomplete }
                }
                try destination.close()
                try stage.removeClosedCopySharedMemory()
            } catch { try? destination.close(); throw error }
            budget.measurement.metadataBytes = try stage.size("database.sqlite") + intentSize
            budget.measurement.bytes = budget.measurement.metadataBytes
            var readConfiguration = Configuration(); readConfiguration.readonly = true
            readConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA busy_timeout=50") }
            let copy = try DatabaseQueue(path: stage.root.appendingPathComponent("database.sqlite").path, configuration: readConfiguration)
            let inventory: StorageSnapshotInventory, schema: Int, families: [String:Int], tables: [String:Int]
            do {
                try budget.observe("inventory_started")
                (inventory, schema, families, tables) = try copy.read { db in
                    _ = try SchemaMigrations.inspect(db)
                    return (try StorageSnapshotAuthority.inventory(db, root: fixture.source, budget: budget, retainedExists: { try sourceFiles.regularOrLinkExists($0) }), try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1, try recordFamilyCounts(db), try tableCounts(db))
                }
                try copy.close()
                try budget.observe("inventory_finished")
            } catch { try? copy.close(); throw error }
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
            var copiedContent: [String:(path: String, size: Int64)] = [:]
            try budget.observe("copying_objects")
            for descriptor in inventory.objects where descriptor.kind == "file" {
                try budget.check()
                var remainingBudget = budget
                remainingBudget.maximumObjectBytes = min(budget.maximumObjectBytes, budget.maximumBytes - total)
                let value: (String, Int64)
                if let expected = descriptor.expectedSHA256, let prior = copiedContent[expected] {
                    // Hash every source path: an expected hash alone never proves
                    // its bytes. Only the owned backup shares inodes, never the store.
                    value = try sourceFiles.digest(descriptor.relativePath, budget: remainingBudget)
                    guard value == (expected, prior.size), value.1 <= remainingBudget.maximumObjectBytes else { throw StorageSnapshotFailure.sourceChanged }
                    if try !stage.writeHardLink("managed/" + descriptor.relativePath, to: prior.path, link: budget.linkFile) {
                        let copied = try sourceFiles.copy(descriptor.relativePath, to: stage, expected: expected, budget: remainingBudget)
                        guard copied == value else { throw StorageSnapshotFailure.sourceChanged }
                        copiedContent[expected] = ("managed/" + descriptor.relativePath, value.1)
                    }
                } else {
                    value = try sourceFiles.copy(descriptor.relativePath, to: stage, expected: descriptor.expectedSHA256, budget: remainingBudget)
                    copiedContent[value.0] = ("managed/" + descriptor.relativePath, value.1)
                }
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
            let manifest = StorageSnapshotManifest(format: 2, kind: kind, operationID: operation.uuidString.lowercased(),
                storeID: fixture.storeID, sourceRoot: fixture.source.path, schema: schema, databaseSHA256: database.0,
                databaseSize: database.1, objects: materialized.sorted { $0.descriptor.relativePath < $1.descriptor.relativePath },
                unavailable: inventory.unavailable, externalReferences: inventory.externalReferences, recordFamilies: families, tableRows: tables, capturedAt: capturedAt)
            let manifestData = try encoded(manifest)
            budget.measurement.bytes = total + Int64(manifestData.count)
            budget.measurement.lowerBound = false
            guard manifestData.count <= budget.maximumManifestBytes else { throw budget.capacityFailure("snapshot_manifest_capacity") }
            total = try budget.adding(Int64(manifestData.count), to: total)
            try stage.synchronizeCopiedDirectories(budget: budget)
            try budget.observe("directories_synchronized")
            try budget.check()
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

    static func recordFamilyCounts(_ db: Database) throws -> [String:Int] {
        var counts = Dictionary(uniqueKeysWithValues: EnvelopeFamily.catalog.keys.map {($0,0)})
        for row in try Row.fetchAll(db,sql:"SELECT type,COUNT(*) AS n FROM records GROUP BY type") {
            let type: String = row["type"]
            guard counts[type] != nil else {throw StorageSnapshotFailure.unsupportedAuthority}
            counts[type] = row["n"] as Int
        }
        return counts
    }
    static func tableCounts(_ db: Database) throws -> [String:Int] {
        var counts: [String:Int] = [:]
        for table in ["metadata","records","commands","events","cursors"] {
            counts[table] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM " + table) ?? 0
        }
        return counts
    }

    static func reconcile(parent: URL, operation: UUID, publicationName: String? = nil, budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
        do { return try reconcileGeneration(parent: parent, operation: operation, publicationName: publicationName, budget: budget) }
        catch { throw budget.reporting(error) }
    }

    private static func reconcileGeneration(parent: URL, operation: UUID, publicationName: String?, budget: StorageSnapshotBudget) throws -> StorageSnapshotReceipt {
        let published = try StorageObjectFiles(root: parent.appendingPathComponent(names(operation, publicationName: publicationName).published, isDirectory: true),folderAccess:budget.folderAccess)
        let digest = try verify(published, operation: operation, budget: budget)
        let containingDirectory = try StorageObjectFiles(root: parent,folderAccess:budget.folderAccess)
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
        let containing = try StorageObjectFiles(root:parent,folderAccess:budget.folderAccess)
        let stageName = names(operation).staging
        let stage = try StorageObjectFiles(root:parent.appendingPathComponent(stageName,isDirectory:true),folderAccess:budget.folderAccess)
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
        // A previous attempt may have ended during the commit barrier. Redo
        // the root-entry fsync and full-device barrier before publication.
        try stage.synchronizePublicationDirectory()
        try stage.synchronizeOwnedFile("manifest.json")
        try budget.check()
        try containing.publish(stageName,as:publicationName)
        return try reconcile(parent:parent,operation:operation,publicationName:publicationName,budget:budget)
    }

    static func verify(_ files: StorageObjectFiles, operation: UUID, budget: StorageSnapshotBudget) throws -> String {
        try budget.check()
        let manifestSize = try files.size("manifest.json")
        guard manifestSize <= budget.maximumManifestBytes else { throw budget.capacityFailure("snapshot_manifest_capacity") }
        let manifestData = try files.read("manifest.json", maximum: budget.maximumManifestBytes)
        guard let shape = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any], Set(shape.keys).subtracting(["recordFamilies","tableRows","capturedAt"]) == [
            "format", "kind", "operationID", "storeID", "sourceRoot", "schema", "databaseSHA256", "databaseSize", "objects", "unavailable", "externalReferences"
        ] else { throw StorageSnapshotFailure.incomplete }
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: manifestData)
        guard [1, 2].contains(manifest.format), manifest.kind == kind, manifest.operationID == operation.uuidString.lowercased(),
              UUID(uuidString: manifest.storeID) != nil, (0...SchemaMigrations.currentSchema).contains(manifest.schema), manifest.objects.count <= budget.maximumObjects else { throw StorageSnapshotFailure.incomplete }
        if let capturedAt = manifest.capturedAt {
            guard capturedAt.utf8.count <= 40,ISO8601DateFormatter().date(from:capturedAt) != nil else {throw StorageSnapshotFailure.incomplete}
        }
        let intentData = try files.read("intent.json", maximum: 1024)
        let intent = try JSONDecoder().decode([String: String].self, from: intentData)
        guard intent == ["format": String(manifest.format), "kind": kind, "operation_id": manifest.operationID, "store_id": manifest.storeID, "source_root": manifest.sourceRoot] else { throw StorageSnapshotFailure.incomplete }
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
                // Additive registered families can be absent from older manifests
                // only when they contain zero rows. Nonzero counts remain exact.
                if let counts = manifest.recordFamilies { guard counts.filter({$0.value != 0}) == (try recordFamilyCounts(db)).filter({$0.value != 0}) else {throw StorageSnapshotFailure.incomplete} }
                if let counts = manifest.tableRows { guard counts == (try tableCounts(db)) else {throw StorageSnapshotFailure.incomplete} }
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
