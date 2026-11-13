import XCTest
import GRDB
import ChecklistTestSupport
@testable import ChecklistCore

/// CL-363: a disposable unit fixture states that its store is a fresh clone of a template
/// (`CommandRouter.FixtureFreshStore`). The startup then leaves out the read-only preflight
/// and, for a clone with no row and no managed file, the sweeps and pruning statements that
/// can find nothing. These cases prove that the store has the rows, the files and the
/// write-ahead log state of the complete startup, and that every other open keeps that startup.
final class FixtureFreshStoreTests: XCTestCase {
    private static let populated = TestStore.Template(name: "FixtureFreshStoreTests.populated") { router, workspace in
        let owner = Caller(role: "owner", installation: "fresh-store-template", projectIDs: [])
        let project = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "Prepared", "key_prefix": "FF", "root_path": workspace.path], caller: owner)["data"] as! JSON
        let input: JSON = ["command_id": UUID().uuidString, "project_id": project["id"]!, "title": "Prepared ticket"]
        let task = try router.handle(method: "task_create", params: fixtureTaskInput(router, method: "task_create", input: input), caller: owner)["data"] as! JSON
        let file = workspace.appendingPathComponent("evidence.txt"); try Data("prepared bytes".utf8).write(to: file)
        _ = try router.handle(method: "attachment_add", params: ["command_id": UUID().uuidString, "project_id": project["id"]!, "task_id": task["id"]!, "path": file.path], caller: owner)
    }
    private let owner = Caller(role: "owner", installation: "fresh-store-fixture", projectIDs: [])
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CL363-fresh-" + UUID().uuidString)
    }

    /// The phases of `StorageBootstrap.open` that ran during `body`.
    private func bootstrapPhases(_ body: () throws -> Void) rethrows -> [String] {
        let prior = StorageBootstrap.qualificationObserve
        var phases: [String] = []
        StorageBootstrap.qualificationObserve = { phase, _ in phases.append(phase) }
        defer { StorageBootstrap.qualificationObserve = prior }
        try body()
        return phases
    }
    /// Every stored row that does not name this clone's own identity, key or the time of its retention mark.
    private func rows(_ router: CommandRouter) throws -> [String: [String]] {
        try router.dbQueue.read { db in
            var result: [String: [String]] = [:]
            result["metadata"] = try Row.fetchAll(db, sql: "SELECT key,value FROM metadata WHERE key NOT IN ('incarnation','store_identity','cursor_seal_key','command_retention_marks') ORDER BY key").map { ($0["key"] as String) + "=" + ($0["value"] as String) }
            result["records"] = try Row.fetchAll(db, sql: "SELECT id,type,revision,data FROM records ORDER BY rowid").map { ($0["id"] as String) + "|" + ($0["type"] as String) + "|" + String($0["revision"] as Int) + "|" + ($0["data"] as String) }
            result["events"] = try String.fetchAll(db, sql: "SELECT kind FROM events ORDER BY seq")
            result["commands"] = try String.fetchAll(db, sql: "SELECT digest FROM commands ORDER BY rowid")
            result["cursors"] = try String.fetchAll(db, sql: "SELECT token FROM cursors ORDER BY rowid")
            result["schema"] = try String.fetchAll(db, sql: "SELECT type || ' ' || name FROM sqlite_master ORDER BY type,name")
            return result
        }
    }
    /// Counts for each record type and event kind: equal for two stores that ran the same commands.
    private func shape(_ router: CommandRouter) throws -> [String] {
        try router.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT 'record ' || type || ' ' || COUNT(*) FROM records GROUP BY type ORDER BY type")
                + String.fetchAll(db, sql: "SELECT 'event ' || kind || ' ' || COUNT(*) FROM events GROUP BY kind ORDER BY kind")
                + String.fetchAll(db, sql: "SELECT 'commands ' || COUNT(*) FROM commands")
                + String.fetchAll(db, sql: "SELECT 'metadata ' || key FROM metadata ORDER BY key")
        }
    }
    private func files(_ root: URL) throws -> [String] {
        let base = root.resolvingSymlinksInPath().path
        let all = try XCTUnwrap(FileManager.default.enumerator(atPath: base)).compactMap { $0 as? String }
        // Object names follow each clone's own bytes and identifiers; compare the fixed layout.
        // The name of an import stage follows the clone's own command ID.
        return all.filter { !$0.hasPrefix("objects/") }
            .map { $0.replacingOccurrences(of: "managed-import-[0-9a-f]{64}", with: "managed-import-*", options: .regularExpression) }.sorted()
    }
    private func hasImportRecoveryIndex(_ router: CommandRouter) throws -> Bool {
        try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_temp_master WHERE name='checklist_import_recovery'") == 1 }
    }

    func testOnlyAFreshUnitCloneLeavesOutThePreflight() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var unit: CommandRouter!, durable: CommandRouter!
        let unitPhases = try bootstrapPhases { unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false) }
        let durablePhases = try bootstrapPhases { durable = try TestStore.router(root: root.appendingPathComponent("durable"), durable: true) }
        defer { try? unit.closeStore(); try? durable.closeStore() }
        XCTAssertFalse(unitPhases.contains("schema.preflight"))
        XCTAssertTrue(durablePhases.contains("schema.preflight"), "A durable fixture keeps the complete startup")
        XCTAssertTrue(unitPhases.contains("sqlite.writer-open")); XCTAssertTrue(unitPhases.contains("schema.backfill"))
        // The routine pruning interval is running in both, and both wrote the retention mark of the pass.
        XCTAssertNotNil(unit.lastRoutinePrune); XCTAssertNotNil(durable.lastRoutinePrune)
        for router in [unit!, durable!] {
            XCTAssertNotNil(try router.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'") })
        }
        // A pruning pass always writes its mark. An emptied mark shows whether a later pass ran.
        for router in [unit!, durable!] {
            try router.dbQueue.write { try $0.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks','[]')") }
        }
        _ = try unit.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "After open", "key_prefix": "FF"], caller: owner)
        XCTAssertEqual(try unit.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'") }, "[]", "No pass is due in the first ten minutes")
        // A reopened fixture store is not a fresh clone: the preflight and a pruning pass run.
        try unit.closeStore()
        let reopenPhases = try bootstrapPhases { unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false) }
        XCTAssertTrue(reopenPhases.contains("schema.preflight"))
        XCTAssertNotEqual(try unit.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'") }, "[]")
        let projects = try unit.handle(method: "project_list", params: [:], caller: owner)["data"] as! JSON
        XCTAssertEqual((projects["projects"] as! [JSON]).count, 1)
        // A direct router on an existing store keeps the complete startup as well.
        try durable.closeStore()
        let directPhases = try bootstrapPhases { durable = try CommandRouter(root: root.appendingPathComponent("durable")) }
        XCTAssertTrue(directPhases.contains("schema.preflight"))
    }

    func testAFreshEmptyCloneHasTheRowsAndFilesOfTheCompleteStartup() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false)
        let complete = try TestStore.router(root: root.appendingPathComponent("complete"), durable: true)
        defer { try? unit.closeStore(); try? complete.closeStore() }
        // The same rows in every table and the same files, directly after the open; the clone's
        // own identity, key and the time of its retention mark aside.
        XCTAssertEqual(try rows(unit), try rows(complete))
        XCTAssertEqual(try rows(unit)["records"], []); XCTAssertEqual(try rows(unit)["events"], []); XCTAssertEqual(try rows(unit)["commands"], [])
        XCTAssertEqual(try rows(unit)["cursors"], [])
        XCTAssertEqual(try files(unit.root), try files(complete.root))
        XCTAssertTrue(try files(unit.root).contains(".snapshot-retention.lock"), "The first maintenance pass ran")
        // The retention mark of the pruning pass is the first frame of the write-ahead log: a
        // pool reader has a comparable snapshot, as after the complete startup.
        for router in [unit, complete] {
            let reader = try XCTUnwrap(router.readers)
            XCTAssertNotNil(try reader.read { db in try router.readSnapshotCache.withSnapshot(db, caller: owner) { router.readSnapshotCache.readVersion(db) } })
        }
        XCTAssertNotEqual(unit.incarnation, complete.incarnation)
        // The seed wrote the identity rows through its own connection. The product connection
        // finds the table and its key index complete and in the order of the storage collation.
        XCTAssertEqual(try unit.dbQueue.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }, ["ok"])
        XCTAssertEqual(try unit.dbQueue.read { try String.fetchAll($0, sql: "SELECT key FROM metadata ORDER BY key") },
                       try complete.dbQueue.read { try String.fetchAll($0, sql: "SELECT key FROM metadata ORDER BY key") })
        XCTAssertEqual(try unit.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='incarnation'") }, unit.incarnation)
        // An empty store has no import job, so neither startup made the recovery index of the maintenance pass.
        XCTAssertFalse(try hasImportRecoveryIndex(complete)); XCTAssertFalse(try hasImportRecoveryIndex(unit))
        // The same commands on both. Each command ends with a storage maintenance pass: the one after
        // the import makes the recovery index in the fresh clone as in the complete startup.
        for (router, name) in [(unit, "unit"), (complete, "complete")] {
            let project = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "Same command", "key_prefix": "FF"], caller: owner)["data"] as! JSON
            let input: JSON = ["command_id": UUID().uuidString, "project_id": project["id"]!, "title": "Same ticket"]
            let task = try router.handle(method: "task_create", params: fixtureTaskInput(router, method: "task_create", input: input), caller: owner)["data"] as! JSON
            let file = root.appendingPathComponent("evidence-" + name + ".txt"); try Data("same bytes".utf8).write(to: file)
            _ = try router.handle(method: "attachment_add", params: ["command_id": UUID().uuidString, "project_id": project["id"]!, "task_id": task["id"]!, "path": file.path], caller: owner)
            _ = try router.handle(method: "message_send", params: ["command_id": UUID().uuidString, "project_id": project["id"]!, "task_id": task["id"]!, "body": "After the import"], caller: owner)
        }
        XCTAssertTrue(try hasImportRecoveryIndex(unit)); XCTAssertTrue(try hasImportRecoveryIndex(complete))
        XCTAssertEqual(try shape(unit), try shape(complete))
        XCTAssertEqual(try files(unit.root), try files(complete.root))
    }

    func testAFreshPreparedCloneKeepsTheCompleteStartupAfterThePreflight() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var unit: CommandRouter!
        let phases = try bootstrapPhases {
            unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false, template: Self.populated, workspace: root.appendingPathComponent("unit-workspace"))
        }
        let complete = try TestStore.router(root: root.appendingPathComponent("complete"), durable: true, template: Self.populated, workspace: root.appendingPathComponent("complete-workspace"))
        defer { try? unit.closeStore(); try? complete.closeStore() }
        XCTAssertFalse(phases.contains("schema.preflight"))
        XCTAssertNotNil(unit.lastRoutinePrune)
        // A prepared store has records and managed files: the sweeps, the first maintenance pass
        // and the complete pruning pass run.
        XCTAssertEqual(try rows(unit)["metadata"]?.count, try rows(complete)["metadata"]?.count)
        XCTAssertTrue(try hasImportRecoveryIndex(unit)); XCTAssertTrue(try hasImportRecoveryIndex(complete))
        XCTAssertEqual(try shape(unit), try shape(complete))
        XCTAssertEqual(try files(unit.root), try files(complete.root))
        for router in [unit!, complete] {
            let projects = try router.handle(method: "project_list", params: [:], caller: owner)["data"] as! JSON
            let project = try XCTUnwrap((projects["projects"] as? [JSON])?.first)
            let tasks = try router.handle(method: "task_list", params: ["project_id": project["id"]!], caller: owner)["data"] as! JSON
            XCTAssertEqual((tasks["tasks"] as? [JSON])?.count, 1)
            let input: JSON = ["command_id": UUID().uuidString, "project_id": project["id"]!, "title": "After the clone"]
            _ = try router.handle(method: "task_create", params: fixtureTaskInput(router, method: "task_create", input: input), caller: owner)
        }
        XCTAssertEqual(try shape(unit), try shape(complete))
    }
}
