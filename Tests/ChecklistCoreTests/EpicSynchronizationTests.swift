import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class EpicSynchronizationTests: XCTestCase {
    func testSynchronizationPreservesFirstJoinDateAndOverrideOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-epic-sync-" + uuid())
        let router = try TestStore.router(root:directory.appendingPathComponent("store"))
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:directory)}
        let owner = Caller(role:"owner",installation:"epic-sync-fixture",projectIDs:[])
        func call(_ method: String,_ input: JSON) throws -> JSON {
            var input = input;input["command_id"] = uuid()
            return try router.handle(method:method,params:input,caller:owner)["data"] as! JSON
        }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Synthetic synchronization","key_prefix":"SYNC","root_path":workspace.path])
        let pid = project["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Ticket history"]),gid = epic["id"] as! String
        var tasks: [JSON] = []
        for title in ["First","Second","Third"] {
            tasks.append(try call("task_create",["project_id":pid,"epic_id":gid,"title":title]))
        }
        let first = tasks[0]["id"] as! String,second = tasks[1]["id"] as! String,third = tasks[2]["id"] as! String
        try ArchiveStorageGate.withExclusive(root:router.root) {_ in
        try router.dbQueue.writeWithoutTransaction {db in
        try router.withValidatedDomainTransaction(db) {
            var source = try router.record(db,gid,type:"group")
            source["members"] = [
                ["task_id":second,"joined_at":NSNull()],
                ["task_id":first,"joined_at":"2026-01-01T00:00:00Z"],
                ["task_id":first,"joined_at":"2026-02-01T00:00:00Z"],
                ["task_id":second,"joined_at":"2026-03-01T00:00:00Z"],
                ["task_id":third],
                ["task_id":third,"joined_at":"2026-04-01T00:00:00Z"],
                ["task_id":"removed","joined_at":"2025-01-01T00:00:00Z"],
            ] as [JSON]
            // An override keeps the existing remove-then-append ordering.
            let before = now(),result = try router.syncEpic(db,source,taskOverride:tasks[0]),after = now()
            XCTAssertEqual(result["task_ids"] as? [String],[second,third,first])
            let members = try XCTUnwrap(result["members"] as? [JSON])
            XCTAssertTrue(members[0]["joined_at"] is NSNull)
            let newJoin = try XCTUnwrap(members[1]["joined_at"] as? String)
            XCTAssertGreaterThanOrEqual(newJoin,before);XCTAssertLessThanOrEqual(newJoin,after)
            XCTAssertEqual(members[2]["joined_at"] as? String,"2026-01-01T00:00:00Z")
            XCTAssertTrue(bool(result,"has_held_ticket"))
            return .commit
        }}}
        let created = try call("task_create",["project_id":pid,"epic_id":gid,"title":"Fourth"])
        XCTAssertEqual(created["key"] as? String,"SYNC-4")
        let stored = try router.dbQueue.read {try router.record($0,gid,type:"group")}
        XCTAssertEqual(stored["task_ids"] as? [String],[first,second,third,created["id"] as! String])
        let members = try XCTUnwrap(stored["members"] as? [JSON])
        XCTAssertEqual(members[0]["joined_at"] as? String,"2026-01-01T00:00:00Z")
        XCTAssertTrue(members[1]["joined_at"] is NSNull)
        XCTAssertThrowsError(try call("task_create",["project_id":pid,"epic_id":gid,"title":"Conflicting key","key":"SYNC-1"])) {
            XCTAssertEqual(($0 as? CoreError)?.code,"KEY_CONFLICT")
        }
        try router.dbQueue.read {db in
            XCTAssertEqual(int(try router.record(db,pid,type:"project"),"next_number"),5)
            XCTAssertEqual(int(try router.record(db,gid,type:"group"),"revision"),int(stored,"revision"))
        }
    }
}
