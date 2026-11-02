import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

/// CL-396: a read over the size limit says so and leaves a healthy file available.
extension TicketLifecycleCleanupTests {
    private func largeAttachment() throws -> (pid: String,id: String,worker: Caller) {
        let (p,t,_) = try fixture(),pid = p["id"] as! String,sid = uuid()
        _ = try call("session_register",["project_id":pid,"session_id":sid,"provider":"codex","role":"worker","label":"Synthetic reader"])
        let worker = Caller(role:"worker",installation:"lifecycle-worker",projectIDs:[pid],sessionID:sid,workspace:p["root_path"] as? String)
        let source = URL(fileURLWithPath:p["root_path"] as! String).appendingPathComponent("large.bin")
        try Data(count:8 * 1024 * 1024 + 1).write(to:source)
        let added = try call("attachment_add",["project_id":pid,"task_id":t["id"]!,"path":source.path,"mode":"managed_copy"])
        return (pid,try XCTUnwrap(added["id"] as? String),worker)
    }
    private func record(_ pid: String,_ id: String) throws -> (String?,[String]) {
        let state = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])
        let jobs = try router.dbQueue.read {try self.router.records($0,type:"storage_job")}.filter {$0["attachment_id"] as? String == id}.map {$0["state"] as? String ?? ""}
        return (state["availability"] as? String,jobs)
    }

    func testCL396AgentReadOverTheLimitKeepsTheFileAvailable() throws {
        let (pid,id,worker) = try largeAttachment(),before = try record(pid,id)
        for value in ["original","preview"] {
            XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":value],caller:worker)) {
                let error = $0 as? CoreError
                XCTAssertEqual(error?.code,"FILE_TOO_LARGE")
                XCTAssertEqual(error?.details["limit_bytes"] as? Int,8 * 1024 * 1024)
                XCTAssertEqual((error?.details["size_bytes"] as? NSNumber)?.intValue,8 * 1024 * 1024 + 1)
            }
            let after = try record(pid,id)
            XCTAssertEqual(after.0,"available");XCTAssertEqual(after.1,before.1)
        }
        // The owner's larger limit still reads the same file.
        XCTAssertNoThrow(try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"original"]))
    }

    func testCL396AnOriginalThatCannotBeOpenedStillRecordsUnavailable() throws {
        let (pid,id,worker) = try largeAttachment()
        let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
        let file = try router.managedURL(stored,family:"objects").path
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:file)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file)}
        XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":"original"],caller:worker)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"MANAGED_ORIGINAL_UNAVAILABLE")
        }
        XCTAssertEqual(try record(pid,id).0,"unavailable")
    }
    func testCL396AMissingFileStillRecordsUnavailable() throws {
        let (pid,id,worker) = try largeAttachment()
        let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
        try FileManager.default.removeItem(at:try router.managedURL(stored,family:"objects"))
        XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":"original"],caller:worker)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"MANAGED_FILE_UNAVAILABLE")
        }
        XCTAssertEqual(try record(pid,id).0,"unavailable")
    }

    func testCL396UnknownRepresentationIsRefusedAndTheCatalogNamesTheValues() throws {
        let (pid,id,worker) = try largeAttachment(),before = try record(pid,id)
        XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":"content"],caller:worker)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")
        }
        let after = try record(pid,id)
        XCTAssertEqual(after.0,before.0);XCTAssertEqual(after.1,before.1)
        XCTAssertTrue(router.description("attachment_read").contains("8 MiB"))
    }
}
