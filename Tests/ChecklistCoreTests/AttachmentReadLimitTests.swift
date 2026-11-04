import ChecklistTestSupport
import CryptoKit
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

    func testCL396AFileThatGrewPastTheLimitIsDamageAndNotTooLarge() throws {
        let (pid,id,worker) = try largeAttachment()
        let small = try call("attachment_list",["project_id":pid,"task_id":try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["task_id"]!])["attachments"] as! [JSON]
        let original = try XCTUnwrap(small.first {($0["size"] as? NSNumber)?.intValue ?? 0 < 1024})
        let file = try router.managedURL(try call("attachment_read",["project_id":pid,"attachment_id":original["id"]!,"representation":"metadata"])["path"] as! String,family:"objects")
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let handle = try FileHandle(forWritingTo:file);try handle.truncate(atOffset:9 * 1024 * 1024);try handle.close()
        XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":original["id"]!,"representation":"original"],caller:worker)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"MANAGED_ORIGINAL_UNAVAILABLE")
        }
        XCTAssertEqual(try record(pid,original["id"] as! String).0,"unavailable")
    }

    func testCL396OwnerReadOverItsLimitKeepsTheFileAvailable() throws {
        let (pid,id,_) = try largeAttachment()
        let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
        let file = try router.managedURL(stored,family:"objects")
        try router.dbQueue.write {db in
            var value = try self.router.record(db,id,type:"attachment");value["size"] = 500 * 1024 * 1024 + 1
            try self.router.save(db,value,type:"attachment")
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let handle = try FileHandle(forWritingTo:file);try handle.truncate(atOffset:500 * 1024 * 1024 + 1);try handle.close()
        XCTAssertThrowsError(try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"original"])) {
            XCTAssertEqual(($0 as? CoreError)?.code,"FILE_TOO_LARGE")
        }
        XCTAssertEqual(try record(pid,id).0,"available")
    }

    private func sparseAttachment(bytes: UInt64) throws -> (pid: String,id: String,sha: String,worker: Caller) {
        let (p,t,_) = try fixture(),pid = p["id"] as! String,sid = uuid()
        _ = try call("session_register",["project_id":pid,"session_id":sid,"provider":"codex","role":"worker","label":"Synthetic reader"])
        let worker = Caller(role:"worker",installation:"lifecycle-worker",projectIDs:[pid],sessionID:sid,workspace:p["root_path"] as? String)
        let source = URL(fileURLWithPath:p["root_path"] as! String).appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath:source.path,contents:Data("start".utf8))
        let handle = try FileHandle(forWritingTo:source);try handle.truncate(atOffset:bytes);try handle.close()
        let added = try call("attachment_add",["project_id":pid,"task_id":t["id"]!,"path":source.path,"mode":"managed_copy"])
        return (pid,try XCTUnwrap(added["id"] as? String),try XCTUnwrap(added["sha256"] as? String),worker)
    }

    func testCL397AgentReadsALargeFileInRangesAndTheBytesMatch() throws {
        let size: UInt64 = 500 * 1024 * 1024
        let (pid,id,sha,worker) = try sparseAttachment(bytes:size)
        var hasher = SHA256(),offset = 0,ranges = 0,done = false
        let baseJournal = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE instr(result,'content_base64')>0")}
        while !done {
            let params: JSON = ["project_id":pid,"attachment_id":id,"representation":"original","offset":offset,"length":CommandRouter.attachmentChunkLimit]
            XCTAssertFalse(try router.needsCommandOperation(method:"attachment_read",params:params,caller:worker))
            let reply = try router.handle(method:"attachment_read",params:params,caller:worker)["data"] as! JSON
            let bytes = try XCTUnwrap(Data(base64Encoded:reply["content_base64"] as! String))
            XCTAssertLessThanOrEqual(bytes.count,CommandRouter.attachmentChunkLimit)
            XCTAssertEqual(reply["sha256"] as? String,sha);XCTAssertEqual(reply["offset"] as? Int,offset)
            XCTAssertEqual(reply["length"] as? Int,bytes.count);XCTAssertEqual(reply["chunk_sha256"] as? String,Data(SHA256.hash(data:bytes)).map {String(format:"%02x",$0)}.joined())
            XCTAssertNil(reply["path"])
            hasher.update(data:bytes);offset += bytes.count;ranges += 1;done = reply["eof"] as! Bool
        }
        XCTAssertEqual(UInt64(offset),size);XCTAssertEqual(ranges,63)
        XCTAssertEqual(hasher.finalize().map {String(format:"%02x",$0)}.joined(),sha)
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE instr(result,'content_base64')>0")},baseJournal)
    }

    func testCL397BadRangesAreRefusedAndChangeNothing() throws {
        let (pid,id,_,worker) = try sparseAttachment(bytes:1024)
        let before = try record(pid,id)
        let bad: [JSON] = [["offset":1024,"length":10],["offset":5000,"length":10],["offset":-1,"length":10],["offset":0,"length":0],["offset":0,"length":CommandRouter.attachmentChunkLimit + 1],["offset":0],["length":10],
            ["offset":0,"length":10,"representation":"metadata"],["offset":0,"length":10,"representation":"preview"]]
        for range in bad {
            var params: JSON = ["project_id":pid,"attachment_id":id,"representation":"original"]
            params.merge(range) {$1}
            XCTAssertThrowsError(try router.handle(method:"attachment_read",params:params,caller:worker),"\(range)") {
                XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT","\(range)")
            }
        }
        let tail = try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":"original","offset":1000,"length":1000],caller:worker)["data"] as! JSON
        XCTAssertEqual(tail["length"] as? Int,24);XCTAssertEqual(tail["eof"] as? Bool,true)
        let after = try record(pid,id)
        XCTAssertEqual(after.0,before.0);XCTAssertEqual(after.1,before.1)
    }

    /// CL-404 changed the CL-397 rule: a size that differs from the record is damage, as in a whole-file read.
    func testCL404AFileWithAnotherSizeReturnsSourceChangedAndRecordsUnavailable() throws {
        let (pid,id,_,worker) = try sparseAttachment(bytes:1024)
        let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
        let file = try router.managedURL(stored,family:"objects")
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let handle = try FileHandle(forWritingTo:file);try handle.truncate(atOffset:2048);try handle.close()
        XCTAssertThrowsError(try router.handle(method:"attachment_read",params:["project_id":pid,"attachment_id":id,"representation":"original","offset":0,"length":10],caller:worker)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"SOURCE_CHANGED")
        }
        XCTAssertEqual(try record(pid,id).0,"unavailable")
    }

    private func setAvailability(_ id: String,_ value: String) throws {
        try router.dbQueue.write {db in
            var a = try self.router.record(db,id,type:"attachment");a["availability"] = value;a["cleaned_at"] = ISO8601DateFormatter().string(from:Date())
            try self.router.save(db,self.router.revised(a),type:"attachment")
        }
    }

    func testCL404ACleanedOriginalRefusesWholeAndRangeReadsWithOneErrorAndRecordsNothing() throws {
        for availability in ["original_cleaned","original_missing"] {
            let (pid,id,_,worker) = try sparseAttachment(bytes:1024)
            let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
            // Cleanup keeps the path in the record and removes the file.
            try FileManager.default.removeItem(at:try router.managedURL(stored,family:"objects"))
            try setAvailability(id,availability)
            let revision = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["revision"] as? Int
            var errors: [CoreError] = []
            let reads: [(JSON,Caller?)] = [(["representation":"original"],worker),(["representation":"original"],nil),(["representation":"preview"],worker),
                                            (["representation":"original","offset":0,"length":10],worker),(["representation":"original","offset":0,"length":10],nil)]
            for (input,caller) in reads {
                var params: JSON = ["project_id":pid,"attachment_id":id];params.merge(input) {$1}
                XCTAssertThrowsError(try router.handle(method:"attachment_read",params:params,caller:caller ?? owner),"\(availability) \(input)") {
                    if let error = $0 as? CoreError { errors.append(error) } else { XCTFail("\($0)") }
                }
            }
            XCTAssertEqual(errors.count,reads.count)
            for error in errors {
                XCTAssertEqual(error.code,"ORIGINAL_CLEANED",availability)
                XCTAssertEqual(error.message,errors[0].message)
                XCTAssertEqual(error.details["availability"] as? String,availability)
            }
            let after = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])
            XCTAssertEqual(after["availability"] as? String,availability);XCTAssertEqual(after["revision"] as? Int,revision)
        }
    }

    /// CL-404 rule: a range read that cannot open or read the managed original records the same
    /// observation as a whole-file read (availability unavailable, import job repair_required).
    /// It records no operation or read receipt, as a successful range read records none.
    func testCL404AFailedRangeReadRecordsTheSameObservationAsAWholeFileRead() throws {
        for damage in ["missing","unreadable"] {
            var outcomes: [String:(String?,[String],String?)] = [:]
            for read in ["whole","range"] {
                let (pid,id,_,worker) = try sparseAttachment(bytes:1024)
                let stored = try call("attachment_read",["project_id":pid,"attachment_id":id,"representation":"metadata"])["path"] as! String
                let file = try router.managedURL(stored,family:"objects")
                if damage == "missing" { try FileManager.default.removeItem(at:file) }
                else { try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:file.path) }
                defer { if damage == "unreadable" { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) } }
                let operations = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands")}
                var params: JSON = ["project_id":pid,"attachment_id":id,"representation":"original"]
                if read == "range" { params["offset"] = 0;params["length"] = 10 }
                var code: String?
                XCTAssertThrowsError(try router.handle(method:"attachment_read",params:params,caller:worker),"\(damage) \(read)") { code = ($0 as? CoreError)?.code }
                let state = try record(pid,id)
                outcomes[read] = (state.0,state.1,code)
                if read == "range" { XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands")},operations) }
            }
            XCTAssertEqual(outcomes["range"]?.0,"unavailable",damage);XCTAssertEqual(outcomes["range"]?.0,outcomes["whole"]?.0,damage)
            XCTAssertEqual(outcomes["range"]?.1,outcomes["whole"]?.1,damage)
            XCTAssertEqual(outcomes["range"]?.2,"MANAGED_ORIGINAL_UNAVAILABLE",damage)
        }
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
