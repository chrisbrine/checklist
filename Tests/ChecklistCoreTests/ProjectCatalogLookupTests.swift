import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class ProjectCatalogLookupTests: XCTestCase {
    func testCatalogSeekMatchesEarlierIndexScanAcrossProjectScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root: root)
        defer {
            try? router.closeStore()
            try? FileManager.default.removeItem(at: root)
        }
        let owner = Caller(role: "owner", installation: "catalog-lookup-fixture", projectIDs: [])
        func write(_ method: String, _ params: JSON) throws -> JSON {
            var params = params
            params["command_id"] = uuid()
            return try XCTUnwrap(router.handle(method: method, params: params, caller: owner)["data"] as? JSON)
        }
        func compareCatalog(count: Int) throws {
            try router.dbQueue.read { db in
                // The prior product query scanned every entry in the scope index.
                let sql = """
                    SELECT \(CommandRouter.canonicalRecordColumns) FROM records
                    WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type=CAST(? AS TEXT))
                    ORDER BY rowid
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [Data("project".utf8)])
                let old = try rows.map { try GRDBRecordEnvelopeAdapter.decode($0).object }
                let current = try router.records(db, type: "project")
                XCTAssertEqual(current.count, count)
                XCTAssertEqual(try old.map(jsonString), try current.map(jsonString))
            }
        }

        try compareCatalog(count: 0)
        for index in 0..<8 {
            let workspace = root.deletingLastPathComponent().appendingPathComponent("catalog-\(uuid())")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let project = try write("project_create", ["name": "Project \(index)", "root_path": workspace.path])
            let id = try XCTUnwrap(project["id"] as? String)
            let epic = try write("epic_create", ["project_id": id, "name": "Project work"])
            if index.isMultiple(of: 2) {
                _ = try write("task_create", ["project_id": id, "epic_id": try XCTUnwrap(epic["id"]), "title": "Fixture \(index)"])
            }
            if index.isMultiple(of: 3) {
                _ = try write("project_archive", ["project_id": id, "expected_revision": try XCTUnwrap(project["revision"])])
            }
            try compareCatalog(count: index + 1)
        }
    }
}
