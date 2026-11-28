import Foundation
import Darwin
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
        guard ProcessInfo.processInfo.environment["CHECKLIST_CL514_SLOT_TWO"] == "1" else {
            throw XCTSkip("Run only on the stopped CL-514 slot 2 owned by this thread.")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let slot = support.appendingPathComponent("Checklist Test Instances/slot-2")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: slot.appendingPathComponent("slot.json"))) as? JSON)
        XCTAssertTrue((metadata["tickets"] as? [String])?.contains("CL-514") == true)
        XCTAssertEqual(metadata["mode"] as? String, "stopped")
        XCTAssertEqual((metadata["seed"] as? JSON)?["kind"] as? String, "backup")
        guard (metadata["tickets"] as? [String])?.contains("CL-514") == true, metadata["mode"] as? String == "stopped",
              (metadata["seed"] as? JSON)?["kind"] as? String == "backup" else {throw XCTSkip("Slot 2 is not the stopped CL-514 backup seed.")}
        let root = slot.appendingPathComponent("data")
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
            .appendingPathComponent("ChecklistQualification/r13-P514")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try qualify(router, caller: Caller(role: "owner", installation: "cl514-slot-qualification", projectIDs: []),
                    backup: cache.appendingPathComponent("slot2-backup-" + UUID().uuidString.lowercased()), label: "slot2")
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
        print("CL514_FIXTURE records_before=\(current) added=\(added) total=\(current + added) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
    }

    private func qualify(_ router: CommandRouter, caller: Caller, backup: URL, label: String) throws {
        let sourceFamilies = try router.dbQueue.read {try StorageSnapshot.recordFamilyCounts($0)}
        let count = sourceFamilies.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(count, 150_000)
        func phase(_ label: String, _ work: () throws -> JSON) rethrows -> JSON {
            let start = ProcessInfo.processInfo.systemUptime
            defer {
                var load = [Double](repeating: 0, count: 3)
                _ = getloadavg(&load, 3)
                var resources = rusage()
                let measured = getrusage(RUSAGE_SELF, &resources) == 0
                let peak = measured ? String(resources.ru_maxrss) : "unavailable"
                print("CL514_PHASE scope=\(label) seconds=\(ProcessInfo.processInfo.systemUptime - start) peak_rss_bytes=\(peak) utc=\(now()) load=\(load)")
            }
            return try work()
        }
        let backupReply = try phase("\(label)_backup") {
            try router.executeStorageBackup(params: ["path": backup.path, "command_id": uuid()], caller: caller)
        }
        let captured = try XCTUnwrap(backupReply["data"] as? JSON)
        XCTAssertEqual(captured["status"] as? String, "complete")
        let sha = try XCTUnwrap(captured["manifest_sha256"] as? String)
        let previewReply = try phase("\(label)_verify") {
            try router.executeStorageRestore(method: "restore_preview", params: ["path": backup.path], caller: caller)
        }
        let preview = try XCTUnwrap(previewReply["data"] as? JSON)
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
        let restored = URL(fileURLWithPath: try XCTUnwrap(restore["path"] as? String)).appendingPathComponent("checklist.sqlite")
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let database = try DatabaseQueue(path: restored.path, configuration: config)
        defer {try? database.close()}
        try database.read { db in
            XCTAssertEqual(try StorageSnapshot.recordFamilyCounts(db), sourceFamilies)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertNotEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'"), router.incarnation)
        }
        print("CL514_RESULT scope=\(label) records=\(count) managed_files=\(preview["managed_files"] ?? "?") managed_bytes=\(preview["managed_bytes"] ?? "?") manifest=\(sha)")
    }
}
