import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Prepared SQL changes compilation cost, not the canonical write or its guards.
final class StoreStatementFixtureTests: XCTestCase {
    func testProductionAndDurableFixturesKeepDefaultExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statement-default-" + uuid())
        defer { _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let production = try CommandRouter(root: root.appendingPathComponent("production"))
        let durable = try TestStore.router(root: root.appendingPathComponent("durable"), durable: true)
        let unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false)
        defer { try? production.closeStore(); try? durable.closeStore(); try? unit.closeStore() }
        XCTAssertNil(production.fixtureStoreStatement)
        XCTAssertNil(durable.fixtureStoreStatement)
        XCTAssertNil(production.fixtureStoreRows)
        XCTAssertNil(durable.fixtureStoreRows)
        XCTAssertNotNil(unit.fixtureStoreStatement)
        XCTAssertEqual(try production.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA synchronous") }, 2)
        XCTAssertEqual(try durable.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA synchronous") }, 2)
    }

    func testPreparedReadsKeepBindingsAndCurrentRowsReal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statement-reads-" + uuid())
        defer { _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let router = try TestStore.router(root: root, durable: false)
        defer { try? router.closeStore() }
        let owner = Caller(role: "owner", installation: "statement-reads", projectIDs: [])
        func create(_ name: String) throws -> JSON {
            try router.handle(method: "project_create", params: ["name": name, "key_prefix": "SR", "command_id": uuid()], caller: owner)["data"] as! JSON
        }
        let first = try create("First"), second = try create("Second")
        let firstID = first["id"] as! String, secondID = second["id"] as! String
        for id in [firstID, secondID, firstID] {
            XCTAssertEqual(try router.dbQueue.read { try router.record($0, id, type: "project")["id"] as? String }, id)
        }
        _ = try router.handle(method: "project_edit", params: ["project_id": firstID, "expected_revision": first["revision"]!, "name": "Fresh", "command_id": uuid()], caller: owner)
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, firstID, type: "project")["name"] as? String }, "Fresh")
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, secondID, type: "project")["name"] as? String }, "Second")
        XCTAssertThrowsError(try router.dbQueue.read { try router.record($0, firstID, type: "task") })
        XCTAssertThrowsError(try router.dbQueue.read { try router.record($0, uuid(), type: "project") })
    }

    func testPreparedWritesKeepTriggersRollbackAndSchemaChangesReal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statement-effects-" + uuid())
        defer { _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let owner = Caller(role: "owner", installation: "statement-fixture", projectIDs: [])
        let router = try TestStore.router(root: root, durable: false)
        defer { try? router.closeStore() }
        func call(_ title: String, command: String = uuid()) throws -> JSON {
            try router.handle(method: "project_create", params: ["name": title, "key_prefix": "SC", "command_id": command], caller: owner)["data"] as! JSON
        }
        let first = try call("First")
        let second = try call("Second")
        XCTAssertNotEqual(first["id"] as? String, second["id"] as? String)
        try router.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMP TRIGGER statement_fixture_fail BEFORE INSERT ON records WHEN NEW.type='project' BEGIN SELECT RAISE(ABORT,'fixture refusal'); END")
        }
        let failedCommand = uuid()
        XCTAssertThrowsError(try call("Refused", command: failedCommand))
        try router.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE type='project'"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commands WHERE command_id=?", arguments: [failedCommand]), 0)
        }
        try router.dbQueue.writeWithoutTransaction { try $0.execute(sql: "DROP TRIGGER statement_fixture_fail") }
        let final = try call("After trigger change")
        let updated = try router.handle(method: "project_edit", params: ["project_id": final["id"]!, "expected_revision": final["revision"]!, "name": "Updated", "command_id": uuid()], caller: owner)["data"] as! JSON
        XCTAssertEqual(updated["name"] as? String, "Updated")
        let identity = router.incarnation
        try router.closeStore()
        let reopened = try CommandRouter(root: root)
        defer { try? reopened.closeStore() }
        XCTAssertEqual(reopened.incarnation, identity)
        let projects = try reopened.handle(method: "project_list", params: [:], caller: owner)["data"] as! JSON
        XCTAssertEqual((projects["projects"] as? [JSON])?.count, 3)
        let saved = try reopened.dbQueue.read { try reopened.record($0, updated["id"] as! String, type: "project") }
        XCTAssertEqual(saved["name"] as? String, "Updated")
        XCTAssertEqual(saved["revision"] as? Int, 2)
    }
}
