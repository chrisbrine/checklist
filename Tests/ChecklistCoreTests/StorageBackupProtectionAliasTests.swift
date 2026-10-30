import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class StorageBackupProtectionAliasTests: XCTestCase {
    private func invoke(_ f: StorageFixture, _ method: String, _ params: JSON) throws -> JSON {
        var input = params; input["command_id"] = uuid()
        return try f.router!.executeStorageBackupPruning(method: method, params: input, caller: f.owner, trashRoot: f.workspace)
    }
    private func snapshot(_ f: StorageFixture, day: Int) throws -> JSON {
        let path = f.root.appendingPathComponent("backups/snapshot-" + uuid(), isDirectory: true)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try f.call("backup_create", ["path": path.path])["data"] as! JSON
        try f.router!.dbQueue.write { db in
            try db.execute(sql: "UPDATE metadata SET value=json_set(value,'$.summary.captured_at',?) WHERE key=?", arguments: ["2020-01-0\(day)T00:00:00Z", "backup-generation:" + (result["operation_id"] as! String)])
        }
        return result
    }
    private func entry(_ f: StorageFixture, path: String) throws -> JSON {
        let preview = try f.router!.backupPrunePreview()
        return try XCTUnwrap((preview["snapshots"] as? [JSON])?.first { $0["path"] as? String == path })
    }
    private func foreign(_ f: StorageFixture, local: String) -> String {
        f.base.appendingPathComponent("previous-installation/backups/" + URL(fileURLWithPath: local).lastPathComponent).path
    }

    func testCopiedUpgradeHistoryStaysProtectedUntilExplicitLocalRetirementAndCurrentProtectionRemains() throws {
        let f = try StorageFixture(), current = try snapshot(f, day: 1), history = try snapshot(f, day: 2)
        _ = try snapshot(f, day: 3)
        _ = try invoke(f, "backup_retention_set", ["newest_count": 1, "daily_days": 0])
        let currentPath = current["path"] as! String, historyPath = history["path"] as! String
        let currentRaw = try jsonString(["path": foreign(f, local: currentPath), "manifest_sha256": current["manifest_sha256"]!, "protected": true])
        let historyRaw = try jsonString([["path": foreign(f, local: historyPath), "manifest_sha256": history["manifest_sha256"]!, "protected": true]])
        try f.router!.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [currentRaw])
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('backup-protected-history',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [historyRaw])
        }
        for path in [currentPath, historyPath] {
            let value = try entry(f, path: path)
            XCTAssertTrue((value["keep_reasons"] as? [String] ?? []).contains("protected_upgrade"))
            XCTAssertEqual(value["prune"] as? Bool, false)
            XCTAssertEqual(value["path"] as? String, path)
        }
        XCTAssertEqual(try entry(f, path: historyPath)["historical_upgrade_protection"] as? Bool, true)
        try f.router!.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='preupgrade_snapshot'"), currentRaw)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='backup-protected-history'"), historyRaw)
        }
        _ = try invoke(f, "backup_pin", ["path": historyPath, "pinned": false, "retire_upgrade_protection": true])
        XCTAssertEqual(try entry(f, path: historyPath)["prune"] as? Bool, true)
        XCTAssertEqual(try entry(f, path: historyPath)["historical_upgrade_protection"] as? Bool, false)
        _ = try invoke(f, "backup_pin", ["path": currentPath, "pinned": false, "retire_upgrade_protection": true])
        XCTAssertEqual(try entry(f, path: currentPath)["prune"] as? Bool, false)
        try f.router!.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='preupgrade_snapshot'"), currentRaw)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='backup-protected-history'"), "[]")
        }
    }

    func testCopiedOwnerPinStaysKeptUntilExplicitManagedLocalUnpin() throws {
        let f = try StorageFixture(), old = try snapshot(f, day: 1)
        _ = try snapshot(f, day: 2)
        _ = try invoke(f, "backup_retention_set", ["newest_count": 1, "daily_days": 0])
        let path = old["path"] as! String, original = foreign(f, local: old["path"] as! String)
        let settingsRaw = try f.router!.dbQueue.write { db -> String in
            var settings = jsonObject(try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='backup-retention-settings'")))
            settings["pins"] = [["path": original, "manifest_sha256": old["manifest_sha256"]!]]
            let raw = try jsonString(settings)
            try db.execute(sql: "UPDATE metadata SET value=? WHERE key='backup-retention-settings'", arguments: [raw])
            return raw
        }
        let value = try entry(f, path: path)
        XCTAssertTrue((value["keep_reasons"] as? [String] ?? []).contains("owner_pinned"))
        XCTAssertEqual(value["prune"] as? Bool, false)
        XCTAssertEqual(try f.router!.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='backup-retention-settings'") }, settingsRaw)
        XCTAssertThrowsError(try invoke(f, "backup_pin", ["path": original, "pinned": false])) {
            XCTAssertEqual(($0 as? CoreError)?.code, "BACKUP_PRUNE_PATH_REFUSED")
        }
        _ = try invoke(f, "backup_pin", ["path": path, "pinned": false])
        XCTAssertEqual(try entry(f, path: path)["prune"] as? Bool, true)
        let settings = try f.router!.dbQueue.read { try f.router!.backupRetentionSettings($0) }
        XCTAssertEqual((settings["pins"] as? [JSON])?.count, 0)
    }

    func testOnlyStrictSnapshotUUIDAddsLocalProtectionAndLocalOriginIsUnchanged() throws {
        let root = URL(fileURLWithPath: "/private/tmp/protection-alias-owner", isDirectory: true), folder = "snapshot-" + uuid()
        let local = root.appendingPathComponent("backups/" + folder, isDirectory: true).path, original = "/previous/backups/" + folder
        XCTAssertEqual(StorageBackupProtectionAliases.paths(original, root: root), Set([original, local]))
        XCTAssertEqual(StorageBackupProtectionAliases.paths(local, root: root), Set([local]))
        for invalid in ["/previous/backups/snapshot-old", "/previous/backups/" + folder + ".json", "/previous/backups/" + folder + "/..", "relative/" + folder] {
            XCTAssertEqual(StorageBackupProtectionAliases.paths(invalid, root: root), Set([invalid]))
        }
    }
}
