import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageWriterLeaseTests: XCTestCase {
    private struct CaptureFinished: Error {}
    private func load() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        _ = getloadavg(&values, 3)
        return values
    }

    private func withFixture(_ body: (URL, DatabaseQueue, Configuration) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".local/writer-lease-tests/" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let writer = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: configuration)
        defer { try? writer.close() }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "CREATE TABLE captured(value INTEGER, payload BLOB)")
            try db.execute(sql: "INSERT INTO captured VALUES (1, zeroblob(1048576))")
        }
        try body(root, writer, configuration)
    }

    func testWriterReleasedBeforeCopyAndLaterWritesAreExcludedFromPinnedSnapshot() throws {
        try withFixture { root, writer, configuration in
            let destination = root.appendingPathComponent("copy.sqlite")
            var released = false, changed = false, budget = StorageSnapshotBudget.production()
            budget.pagesPerStep = 1
            budget.observe = { phase in
                if phase == "writer_lease_released" { released = true }
                guard phase == "backup_step", !changed else { return }
                XCTAssertTrue(released)
                try writer.write { try $0.execute(sql: "UPDATE captured SET value=2, payload=zeroblob(2097152)") }
                changed = true
            }
            _ = try StorageDatabaseCapture.copy(source: root, destination: destination, configuration: configuration, intentSize: 0, budget: budget)
            XCTAssertTrue(changed)
            XCTAssertGreaterThan(budget.measurement.writerLeaseSeconds, 0)
            let copy = try DatabaseQueue(path: destination.path, configuration: configuration)
            defer { try? copy.close() }
            try copy.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT value FROM captured"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT length(payload) FROM captured"), 1048576)
                XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            }
            XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT value FROM captured") }, 2)
        }
    }

    func testCancellationReleasesReadSnapshotAndWriterFence() throws {
        try withFixture { root, writer, configuration in
            var budget = StorageSnapshotBudget.production()
            budget.pagesPerStep = 1
            budget.observe = { phase in if phase == "backup_step" { throw StorageSnapshotFailure.canceled } }
            XCTAssertThrowsError(try StorageDatabaseCapture.copy(source: root, destination: root.appendingPathComponent("copy.sqlite"), configuration: configuration, intentSize: 0, budget: budget)) {
                guard case StorageSnapshotFailure.canceled = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            try writer.write { try $0.execute(sql: "UPDATE captured SET value=3") }
            let checkpoint = try writer.writeWithoutTransaction { try XCTUnwrap(Row.fetchOne($0, sql: "PRAGMA wal_checkpoint(TRUNCATE)")) }
            XCTAssertEqual(checkpoint[0] as Int, 0)
            XCTAssertGreaterThan(budget.measurement.writerLeaseSeconds, 0)
        }
    }

    func testCompletedCallbackFailureStillRefusesCopyAndReleasesReadSnapshot() throws {
        try withFixture { root, writer, configuration in
            var budget = StorageSnapshotBudget.production()
            budget.observe = { phase in if phase == "backup_done" { throw StorageSnapshotFailure.canceled } }
            XCTAssertThrowsError(try StorageDatabaseCapture.copy(source: root, destination: root.appendingPathComponent("copy.sqlite"), configuration: configuration, intentSize: 0, budget: budget)) {
                guard case StorageSnapshotFailure.canceled = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            try writer.write { try $0.execute(sql: "UPDATE captured SET value=4") }
            let checkpoint = try writer.writeWithoutTransaction { try XCTUnwrap(Row.fetchOne($0, sql: "PRAGMA wal_checkpoint(TRUNCATE)")) }
            XCTAssertEqual(checkpoint[0] as Int, 0)
        }
    }

    /// Executes the production capture and normalization only. The selected
    /// source is an owned clone of a real completed snapshot's database; absent
    /// managed objects cannot turn this into whole-backup qualification.
    func testCaptureOnOwnedLiveSizeDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_P356B_CAPTURE_ROOT"], let output = env["CHECKLIST_P356B_CAPTURE_OUTPUT"] else {
            throw XCTSkip("Requires an explicitly owned live-size database clone and output.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard root.pathComponents.starts(with: temporary.pathComponents),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("owner.json").path) else {
            throw StorageSnapshotFailure.invalidFixture
        }
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        XCTAssertEqual(limit.rlim_cur, 256)
        var padding: [Int32] = []
        func descriptors() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
        while descriptors() < 98 {
            let fd = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw StorageSnapshotFailure.io }
            padding.append(fd)
        }
        defer { for fd in padding { Darwin.close(fd) } }
        let parent = root.appendingPathComponent("captures", isDirectory: true), operation = UUID()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let identity = try StoreIdentityReceipt.decode(Data(contentsOf: root.appendingPathComponent(StoreIdentityReceipt.fileName)))
        let started = ProcessInfo.processInfo.systemUptime, startLoad = load()
        var events: [[String: Any]] = [], steps = 0, reached = false
        var budget = StorageSnapshotBudget.production()
        budget.observe = { phase in
            if phase == "backup_step" { steps += 1; return }
            events.append(["phase": phase, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started, "load": self.load()])
            if phase == "inventory_started" { reached = true; throw CaptureFinished() }
        }
        do {
            _ = try ArchiveStorageGate.withExclusive(root: root) { permit in
                try StorageSnapshot.build(StorageSnapshotSource(source: root, parent: parent, storeID: identity.logical_store_id, permit: permit), operation: operation, budget: budget)
            }
            XCTFail("Capture-only observation did not stop before inventory")
        } catch is CaptureFinished {} catch {
            XCTFail("Capture failed: \(error)")
        }
        let captureSeconds = ProcessInfo.processInfo.systemUptime - started, captureLoad = load()
        let captured = parent.appendingPathComponent(StorageSnapshot.names(operation).staging).appendingPathComponent("database.sqlite")
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let database = try DatabaseQueue(path: captured.path, configuration: configuration)
        defer { try? database.close() }
        let integrityStarted = ProcessInfo.processInfo.systemUptime, integrityLoad = load()
        let integrity = try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        let integritySeconds = ProcessInfo.processInfo.systemUptime - integrityStarted, integrityEndLoad = load()
        let families = try database.read { try StorageSnapshot.recordFamilyCounts($0) }
        let result: [String: Any] = ["scope": "Production prepareGeneration through capture and normalization, stopping before inventory; not whole backup/startup qualification", "runtime": root.path, "captured_database": captured.path, "operation_id": operation.uuidString.lowercased(), "nofile_soft": limit.rlim_cur, "nofile_hard": limit.rlim_max, "descriptor_baseline": descriptors(), "load_start": startLoad, "load_capture_end": captureLoad, "capture_seconds": captureSeconds, "writer_lease_seconds": budget.measurement.writerLeaseSeconds, "backup_steps": steps, "events": events, "integrity_check": integrity ?? "missing", "integrity_seconds": integritySeconds, "integrity_load_start": integrityLoad, "integrity_load_end": integrityEndLoad, "record_families": families]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        XCTAssertTrue(reached)
        XCTAssertEqual(integrity, "ok")
        if env["CHECKLIST_P356B_EXPECT_SHORT_LEASE"] == "1" { XCTAssertLessThan(budget.measurement.writerLeaseSeconds, 8) }
    }

    /// Real legacy-representation lookup only, using the current unchanged
    /// legacy helper. This is not an old executable or whole-preparation timing.
    func testLegacyReceiptLookupOnOwnedDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_P356B_LEGACY_LOOKUP_ROOT"], let output = env["CHECKLIST_P356B_LEGACY_LOOKUP_OUTPUT"] else {
            throw XCTSkip("Requires the explicitly owned unchanged legacy database and output.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".local/p356b-writer-lease-copy", isDirectory: true).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        var report: JSON = ["runtime": root.path, "scope": "Actual current unchanged legacy helper on the real 25-receipt legacy representation. Cold means this process's receipt cache; source hashing and SQL headers run first, and no OS-cold-cache claim is made. This is not a prechange executable or whole cleanup preparation. No CommandRouter/bootstrap, candidate-path open, manifest or payload verification."]
        var events: [JSON] = [], observations: [JSON] = [], lookupCalls = 0
        let totalStarted = ProcessInfo.processInfo.systemUptime
        func save() throws {
            report["events"] = events; report["lookup_observations"] = observations; report["lookup_calls"] = lookupCalls
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        func systemLoad() throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); process.arguments = ["-n", "vm.loadavg"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, let value = String(data: data, encoding: .utf8) else { throw StorageSnapshotFailure.io }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func descriptors() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
        func measured(_ phase: String, _ body: () throws -> JSON) throws -> JSON {
            let startLoad = try systemLoad(), began = ProcessInfo.processInfo.systemUptime
            do {
                let value = try body(), seconds = ProcessInfo.processInfo.systemUptime - began
                events.append(["phase": phase, "seconds": seconds, "sysctl_load_start": startLoad, "sysctl_load_end": try systemLoad(), "success": true, "result": value])
                try save(); return value
            } catch {
                let seconds = ProcessInfo.processInfo.systemUptime - began
                events.append(["phase": phase, "seconds": seconds, "sysctl_load_start": startLoad, "sysctl_load_end": (try? systemLoad()) ?? "unavailable", "success": false, "failure": TicketCleanupFailureDiagnostics.details(error), "error": String(describing: error)])
                try save(); throw error
            }
        }
        do {
            report["sysctl_load_start"] = try systemLoad()
            guard root.pathComponents.starts(with: temporary.pathComponents), root.path.utf8.elementsEqual(expected.path.utf8) else { throw StorageSnapshotFailure.invalidFixture }
            let files = try StorageObjectFiles(root: root, pinRootForGates: true)
            let owner = try JSONSerialization.jsonObject(with: files.read("owner.json", maximum: 16_384)) as? JSON
            guard owner?["owner"] as? String == "/root/writer_lease", owner?["thread"] as? String == ProcessInfo.processInfo.environment["CHECKLIST_WRITER_LEASE_OWNER_THREAD"],
                  (owner?["purpose"] as? String)?.hasPrefix("P356b owned live-size database-only writer lease comparison") == true else { throw StorageSnapshotFailure.invalidFixture }
            report["owner_sha256"] = ChecklistCore.hash(try files.read("owner.json", maximum: 16_384))
            var limit = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur == 256 else { throw StorageSnapshotFailure.invalidFixture }
            report["nofile_soft"] = limit.rlim_cur; report["nofile_hard"] = limit.rlim_max
            report["descriptors_before_padding"] = descriptors()
            var padding: [Int32] = []
            defer { for fd in padding { Darwin.close(fd) } }
            while descriptors() < 98 {
                let fd = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { throw StorageSnapshotFailure.io }; padding.append(fd)
            }
            report["descriptor_baseline_padded"] = descriptors()
            let before = try measured("database_digest_before") {
                let digest = try files.digest("checklist.sqlite", budget: .production())
                return ["sha256": digest.0, "bytes": digest.1]
            }
            var configuration = Configuration(); configuration.readonly = true
            configuration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA busy_timeout=50") }
            let database = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: configuration)
            defer { try? database.close() }
            try files.requireNamedRoot(root)
            let headers = try measured("legacy_receipt_sql_headers") {
                try database.read { db in
                    let identity = try StoreIdentityReceipt.decode(Data(try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='store_identity'")).utf8))
                    let rows = try Row.fetchAll(db, sql: "SELECT key,octet_length(value) AS bytes,COALESCE(json_extract(value,'$.format'),1) AS format,json_array_length(value,'$.objects') AS objects,json_extract(value,'$.manifest_sha256') AS manifest FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY key")
                    var bindings: [JSON] = [], bytes: Int64 = 0, objects: Int64 = 0, legacy = 0
                    for row in rows {
                        let size: Int64 = row["bytes"], count: Int64 = row["objects"] ?? 0, format: Int = row["format"]
                        bytes += size; objects += count; if format != 2 { legacy += 1 }
                        bindings.append(["key": row["key"] as String, "bytes": size, "objects": count, "format": format, "manifest_sha256": row["manifest"] as String? ?? ""])
                    }
                    return ["receipt_count": rows.count, "legacy_receipts": legacy, "receipt_bytes": bytes, "object_entries": objects, "headers": bindings, "headers_sha256": ChecklistCore.hash(try JSONSerialization.data(withJSONObject:bindings,options:[.sortedKeys])), "incarnation": identity.incarnation, "schema": try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1]
                }
            }
            report["legacy_headers"] = headers
            guard headers["receipt_count"] as? Int == 25, headers["legacy_receipts"] as? Int == 25, headers["schema"] as? Int == 4 else { throw StorageSnapshotFailure.invalidFixture }
            let incarnation = try XCTUnwrap(headers["incarnation"] as? String), cache = StorageBackupAccountingCache.shared(root: root)
            report["initial_parsed_receipts"] = cache.parsedReceiptCount
            guard cache.parsedReceiptCount == 0 else { throw StorageSnapshotFailure.invalidFixture }
            var current = "cold"
            cache.cleanupLookupObserver = { seconds, parsed in observations.append(["phase": current, "seconds": seconds, "legacy_receipts_parsed": parsed]) }
            defer { cache.cleanupLookupObserver = nil }
            for phase in ["cold", "warm"] {
                current = phase
                _ = try measured("legacy_lookup_" + phase) {
                    let parsedBefore = cache.parsedReceiptCount
                    lookupCalls += 1
                    let index = try database.read { try cache.cleanupIndex($0, root: root, incarnation: incarnation, limit: TicketCleanupBatchInventory.byteLimit) }
                    return ["legacy_receipts_parsed": cache.parsedReceiptCount - parsedBefore, "retained_observation_bytes": index.cleanupRetainedBytes, "inventory_limit_bytes": TicketCleanupBatchInventory.byteLimit, "candidate_manifest_count": index.copyManifests.count, "candidate_bindings_sha256": ChecklistCore.hash(try StorageSnapshot.encoded(index.copyManifests)), "descriptor_count": descriptors()]
                }
            }
            let after = try measured("database_digest_after") {
                let digest = try files.digest("checklist.sqlite", budget: .production())
                return ["sha256": digest.0, "bytes": digest.1]
            }
            report["database_unchanged"] = before["sha256"] as? String == after["sha256"] as? String
            guard observations.count == 2, observations.first?["legacy_receipts_parsed"] as? Int == 25,
                  observations.last?["legacy_receipts_parsed"] as? Int == 0, report["database_unchanged"] as? Bool == true else {
                throw CoreError("LEGACY_LOOKUP_QUALIFICATION_FAILED", "The actual lookup observations or database digest did not match the qualification inputs.", details: ["observations": observations, "database_unchanged": report["database_unchanged"] ?? false])
            }
            report["seconds"] = ProcessInfo.processInfo.systemUptime - totalStarted; report["sysctl_load_end"] = try systemLoad(); report["success"] = true
            try save()
        } catch {
            report["success"] = false; report["failure"] = TicketCleanupFailureDiagnostics.details(error); report["error"] = String(describing: error)
            if let failure = error as? CoreError { report["core_error"] = failure.dictionary }
            report["seconds"] = ProcessInfo.processInfo.systemUptime - totalStarted; report["sysctl_load_end"] = (try? systemLoad()) ?? "unavailable"
            try save(); throw error
        }
    }
}
