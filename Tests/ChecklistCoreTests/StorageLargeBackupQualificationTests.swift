import Foundation
import Darwin
import CryptoKit
import GRDB
import XCTest
@testable import ChecklistCore

final class StorageLargeBackupQualificationTests: XCTestCase {
    func testCL514ComponentLiveFamilyMixBacksUpVerifiesAndRestores() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1" else {
            throw XCTSkip("Run the focused large-store qualification explicitly.")
        }
        let fixture = try StorageFixture()
        let project = try fixture.project()
        let task = try fixture.task(project)
        let router = try XCTUnwrap(fixture.router)
        let namespace = String(UUID().uuidString.lowercased().dropLast(12))
        let samples = try (0..<128).map { index -> JSON in
            let relative = "objects/qualification/file-\(index)"
            let url = fixture.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = Data("CL-514 retained object \(index)".utf8)
            try payload.write(to: url)
            return ["mode": "managed", "availability": "available", "path": relative,
                    "sha256": ChecklistCore.hash(payload), "size": payload.count]
        }
        try addMix(router, project: try XCTUnwrap(project["id"] as? String), task: try XCTUnwrap(task["id"] as? String),
                   namespace: namespace, samples: samples, upTo: 151_000)
        try qualify(router, caller: fixture.owner, backup: fixture.base.appendingPathComponent("large-backup"),
                    label: "component")
    }

    func testCL514OwnedSlotTwoLiveFamilyMixBacksUpVerifiesAndRestores() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHECKLIST_CL514_SLOT_TWO"] == "1" else {
            throw XCTSkip("Run only on the stopped CL-514 slot 2 owned by this thread.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let slot = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-2", isDirectory: true)
        let root = slot.appendingPathComponent("data", isDirectory: true)
        func readMarker(_ name: String) throws -> JSON {
            let url = slot.appendingPathComponent(name)
            guard url.path == url.resolvingSymlinksInPath().path else { throw StorageSnapshotFailure.invalidFixture }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON)
        }
        let metadata = try readMarker("slot.json")
        let marker = try readMarker(".checklist-workspace.json")
        guard let session = environment["CODEX_THREAD_ID"], !session.isEmpty,
              marker["session_id"] as? String == session, marker["released"] as? Bool == false,
              marker["purpose"] as? String == "disposable test slot 2",
              root.path == root.resolvingSymlinksInPath().path,
              metadata["slot"] as? Int == 2, metadata["mode"] as? String == "stopped",
              (metadata["tickets"] as? [String])?.contains("CL-514") == true,
              (metadata["seed"] as? JSON)?["kind"] as? String == "backup" else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED", "Use the owned stopped CL-514 slot 2 seeded from a backup.")
        }
        let router = try CommandRouter(root: root, serviceLease: StorageServiceLease(root: root))
        defer {try? router.closeStore()}
        let (project, task, samples) = try router.dbQueue.read { db -> (String, String, [JSON]) in
            let attachment = try Row.fetchOne(db, sql: """
                SELECT project_id,json_extract(data,'$.task_id') AS task_id
                FROM records WHERE type='attachment' AND json_extract(data,'$.mode')='managed'
                AND json_extract(data,'$.availability')='available' AND json_type(data,'$.task_id')='text'
                AND json_type(data,'$.media_capture_history') IS NULL ORDER BY rowid LIMIT 1
                """)
            let row = try XCTUnwrap(attachment)
            let project: String = row["project_id"], task: String = row["task_id"]
            let rows = try Row.fetchAll(db, sql: """
                SELECT json_extract(data,'$.path') AS path,json_extract(data,'$.sha256') AS digest,
                       json_extract(data,'$.size') AS size
                FROM records WHERE project_id=? AND type='attachment'
                AND json_extract(data,'$.mode')='managed' AND json_extract(data,'$.availability')='available'
                AND json_type(data,'$.path')='text' AND json_type(data,'$.size')='integer'
                AND json_type(data,'$.sha256')='text' AND json_type(data,'$.media_capture_history') IS NULL
                ORDER BY rowid LIMIT 256
                """, arguments: [project])
            let files = try StorageObjectFiles(root: root)
            let samples: [JSON] = try rows.compactMap { row in
                let path: String = row["path"]
                guard let relative = try ManagedPaths.relative(path, family: "objects", root: root),
                      try files.regularOrLinkExists(relative) else {return nil}
                return ["path": relative, "sha256": row["digest"] as String, "size": row["size"] as Int,
                        "mode": "managed", "availability": "available"]
            }
            return (project, task, samples)
        }
        XCTAssertFalse(samples.isEmpty)
        let namespace = String(UUID().uuidString.lowercased().dropLast(12))
        try addMix(router, project: project, task: task, namespace: namespace, samples: samples, upTo: 155_000)
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ChecklistQualification/r13-P514b")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try qualify(router, caller: Caller(role: "owner", installation: "cl514-slot-qualification", projectIDs: []),
                    backup: cache.appendingPathComponent("slot2-backup-" + UUID().uuidString.lowercased()), label: "slot2",
                    backupOnly: environment["CHECKLIST_CL514_BACKUP_ONLY"] == "1")
    }

    private func addMix(_ router: CommandRouter, project: String, task: String, namespace: String, samples: [JSON], upTo target: Int) throws {
        guard !samples.isEmpty else {throw CoreError("QUALIFICATION_REFUSED","The fixture needs managed file descriptors.")}
        let current = try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records") ?? 0 }
        let added = max(0, target - current)
        let start = ProcessInfo.processInfo.systemUptime
        func id(_ index: Int) -> String {namespace + String(format: "%012d", index)}
        for first in stride(from: 0, to: added, by: 1024) {
            try router.dbQueue.writeWithoutTransaction { db in
                try router.withValidatedDomainTransaction(db) {
                    for index in first..<min(first + 1024, added) {
                        try autoreleasepool {
                            var value: JSON = ["id": id(index), "project_id": project, "task_id": task,
                                               "created_at": "2026-01-01T00:00:00Z", "revision": 1]
                            let type: String
                            switch index % 100 {
                            case 0..<34:
                                type = "delivery"
                                value["message_id"] = id(index - index % 100 + 99)
                                value["recipient_session_id"] = id(999_999_999)
                                value["state"] = "queued"
                                value["push_state"] = "held"
                            case 34..<64:
                                type = "storage_job"
                                value["kind"] = "attachment_import"
                                value["state"] = "settled"
                                value["attachment_id"] = id(index - index % 100 + 64 + index % 25)
                                var object = samples[index % samples.count]
                                object["representation"] = "original"
                                object["final"] = object.removeValue(forKey: "path")
                                value["objects"] = [object]
                            case 64..<89:
                                type = "attachment"
                                value.merge(samples[index % samples.count]) { _, new in new }
                            default:
                                type = "message"
                                value["kind"] = "note"
                                value["body"] = "Synthetic storage qualification note."
                            }
                            try router.save(db, value, type: type)
                        }
                    }
                    return .commit
                }
            }
        }
        measurement("fixture", started: start)
        print("CL514_FIXTURE records_before=\(current) added=\(added) total=\(current + added)")
    }

    private func measurement(_ phase: String, started: TimeInterval) {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        var resources = rusage()
        let measured = getrusage(RUSAGE_SELF, &resources) == 0
        let peak = measured ? String(resources.ru_maxrss) : "unavailable"
        print("CL514_PHASE scope=\(phase) seconds=\(ProcessInfo.processInfo.systemUptime - started) peak_rss_bytes=\(peak) utc=\(now()) load=\(load)")
    }

    private func qualify(_ router: CommandRouter, caller: Caller, backup: URL, label: String, backupOnly: Bool = false) throws {
        let sourceFamilies = try router.dbQueue.read {try StorageSnapshot.recordFamilyCounts($0)}
        let count = sourceFamilies.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(count, 150_000)
        print("CL514_SOURCE_FAMILIES " + (try jsonString(sourceFamilies)))
        func phase(_ label: String, _ work: () throws -> JSON) rethrows -> JSON {
            let start = ProcessInfo.processInfo.systemUptime
            defer { measurement(label, started: start) }
            do { return try work() }
            catch {
                let detail = (error as? CoreError).flatMap {try? jsonString($0.dictionary)} ?? String(reflecting: error)
                fputs("CL514_TERMINAL scope=\(label) error=\(detail)\n", stderr)
                throw error
            }
        }
        let params: JSON = ["path": backup.path, "command_id": uuid()]
        print("CL514_BACKUP_REQUEST " + (try jsonString(params)))
        let backupReply = try phase("\(label)_backup") {
            try router.executeStorageBackup(params: params, caller: caller)
        }
        let captured = try XCTUnwrap(backupReply["data"] as? JSON)
        XCTAssertEqual(captured["status"] as? String, "complete")
        let sha = try XCTUnwrap(captured["manifest_sha256"] as? String)
        let manifest = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ChecklistCore.hash(manifest), sha)
        let replay = try router.executeStorageBackup(params: params, caller: caller)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(try jsonString(try XCTUnwrap(replay["data"] as? JSON)), try jsonString(captured))
        print("CL514_COMMITTED_RECEIPT " + (try jsonString(captured)))
        guard !backupOnly else { return }
        let previewReply = try phase("\(label)_verify") {
            try router.executeStorageRestore(method: "restore_preview", params: ["path": backup.path], caller: caller)
        }
        let preview = try XCTUnwrap(previewReply["data"] as? JSON)
        XCTAssertEqual(preview["state"] as? String, "complete")
        XCTAssertEqual(preview["manifest_sha256"] as? String, sha)
        XCTAssertEqual(preview["record_families"] as? [String: Int], sourceFamilies)
        let restoreReply = try phase("\(label)_restore") {
            try router.executeStorageRestore(method: "restore_create", params: ["path": backup.path, "manifest_sha256": sha,
                "command_id": uuid()], caller: caller)
        }
        let restore = try XCTUnwrap(restoreReply["data"] as? JSON)
        XCTAssertEqual(restore["status"] as? String, "complete")
        XCTAssertEqual(restore["manifest_sha256"] as? String, sha)
        XCTAssertEqual(restore["dispatch"] as? String, "quarantined")
        let restoredRoot = URL(fileURLWithPath: try XCTUnwrap(restore["path"] as? String))
        let restored = restoredRoot.appendingPathComponent("checklist.sqlite")
        let fenced = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: restoredRoot.appendingPathComponent("restore-receipt.json"))) as? JSON)
        let incarnation = try XCTUnwrap(restore["store_incarnation"] as? String)
        XCTAssertEqual(fenced["state"] as? String, "complete")
        XCTAssertEqual(fenced["dispatch"] as? String, "quarantined")
        XCTAssertEqual(fenced["incarnation"] as? String, incarnation)
        XCTAssertEqual(fenced["manifest_sha256"] as? String, sha)
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let database = try DatabaseQueue(path: restored.path, configuration: config)
        defer {try? database.close()}
        let capturedDatabase = try DatabaseQueue(path: backup.appendingPathComponent("database.sqlite").path, configuration: config)
        defer {try? capturedDatabase.close()}
        try database.read { db in
            XCTAssertEqual(try StorageSnapshot.recordFamilyCounts(db), sourceFamilies)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'"), incarnation)
            XCTAssertNotEqual(incarnation, router.incarnation)
        }
        _ = try phase("\(label)_payloads") {
            let capturedDigest = try router.dbQueue.read { source in
                try capturedDatabase.read { copy in try comparePayloads(source, copy) }
            }
            let restoredDigest = try capturedDatabase.read { copy in
                try database.read { candidate in try comparePayloads(copy, candidate, fencedAt: incarnation) }
            }
            let hashes: JSON = ["source_and_capture": capturedDigest, "restore": restoredDigest]
            print("CL514_PAYLOAD_SHA256 " + (try jsonString(hashes)))
            return hashes
        }
        print("CL514_RESULT scope=\(label) records=\(count) managed_files=\(preview["managed_files"] ?? "?") managed_bytes=\(preview["managed_bytes"] ?? "?") manifest=\(sha)")
    }

    private func comparePayloads(_ before: Database, _ after: Database, fencedAt: String? = nil) throws -> String {
        let sql = "SELECT id,project_id,type,revision,data FROM records ORDER BY id COLLATE BINARY"
        let originals = try Row.fetchCursor(before, sql: sql)
        let copies = try Row.fetchCursor(after, sql: sql)
        var digest = SHA256()
        while let previous = try originals.next() {
            try autoreleasepool {
                let copy = try XCTUnwrap(try copies.next(), "The copy is missing a canonical row")
                let id: String = previous["id"], family: String = previous["type"]
                guard id.utf8.elementsEqual((copy["id"] as String).utf8), family == copy["type"] as String,
                      previous["project_id"] as String? == copy["project_id"] as String?,
                      previous["revision"] as Int == copy["revision"] as Int else {
                    throw CoreError("QUALIFICATION_PAYLOAD_MISMATCH", "Canonical identity or revision changed in \(family).")
                }
                let original: String = previous["data"], actual: String = copy["data"]
                if let fencedAt, ["session","attempt","task","delivery","group","handoff","delegation","task_session","recipient_target","ordinary_mention_plan"].contains(family) {
                    let expected = try fencedPayload(original, actual: actual, family: family, incarnation: fencedAt)
                    guard expected.utf8.elementsEqual(actual.utf8) else {
                        throw CoreError("QUALIFICATION_PAYLOAD_MISMATCH", "Restore changed an unexpected field in \(family).")
                    }
                } else if !original.utf8.elementsEqual(actual.utf8) {
                    throw CoreError("QUALIFICATION_PAYLOAD_MISMATCH", "The exact payload changed in \(family).")
                }
                digest.update(data: Data(id.utf8))
                digest.update(data: Data([0]))
                digest.update(data: Data(actual.utf8))
                digest.update(data: Data([0]))
            }
        }
        XCTAssertNil(try copies.next(), "The copy contains an extra canonical row")
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fencedPayload(_ original: String, actual: String, family: String, incarnation: String) throws -> String {
        var expected = jsonObject(original)
        let restored = jsonObject(actual)
        switch family {
        case "session":
            for key in ["authorization_generation", "grant_generation"] {
                let newGeneration = try XCTUnwrap(restored[key] as? String)
                XCTAssertNotNil(UUID(uuidString: newGeneration))
                XCTAssertNotEqual(newGeneration, expected[key] as? String)
                expected[key] = newGeneration
            }
            expected["state"] = "revoked"
            expected["restore_quarantined"] = true
            expected["assistant_grants"] = [:] as JSON
            for key in ["native_endpoint", "native_binding", "execution_domain", "token_hash"] { expected.removeValue(forKey: key) }
        case "attempt" where expected["state"] as? String == "active":
            expected["recovery_required"] = true
            expected["recovery_reason"] = "restored_store"
            expected.removeValue(forKey: "token_hash")
        case "task" where expected["active_attempt_id"] != nil || expected["active_verification_request_id"] != nil:
            expected["recovery_required"] = true
        case "delivery" where !["acknowledged","addressed"].contains(expected["state"] as? String ?? ""):
            expected["restore_prior_state"] = expected["state"]
            expected["state"] = "quarantined"
            expected["push_state"] = "quarantined"
            expected["restore_incarnation"] = incarnation
        case "group" where expected["orchestration"] != nil:
            expected["restore_prior_orchestration"] = expected.removeValue(forKey: "orchestration")
        case "handoff", "delegation", "task_session", "recipient_target", "ordinary_mention_plan":
            expected["restore_quarantined"] = true
        default: return original
        }
        return try jsonString(expected)
    }
}
