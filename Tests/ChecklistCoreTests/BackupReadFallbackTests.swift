import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

private final class BackupReadOperation: @unchecked Sendable {
    let run: () throws -> Void
    init(_ run: @escaping () throws -> Void) {self.run = run}
}

final class BackupReadFallbackTests: XCTestCase {
    private func attachment() throws -> (StorageFixture,JSON,JSON,JSON) {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p)
        let source = f.workspace.appendingPathComponent("source.bin")
        try Data("immutable original".utf8).write(to:source)
        let a = try XCTUnwrap(f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as? JSON)
        return (f,p,t,a)
    }
    private func locked(_ reply: JSON,file: StaticString = #filePath,line: UInt = #line) {
        let data = reply["data"] as? JSON,admission = reply["write_admission"] as? JSON
        XCTAssertEqual(data?["state"] as? String,"locked",file:file,line:line)
        XCTAssertEqual(data?["queued"] as? Bool,false,file:file,line:line)
        XCTAssertEqual(data?["retry_required"] as? Bool,true,file:file,line:line)
        XCTAssertNil(data?["read_hold_id"],file:file,line:line)
        XCTAssertNil(data?["lease_id"],file:file,line:line)
        XCTAssertEqual(admission?["locked"] as? Bool,true,file:file,line:line)
        XCTAssertEqual(admission?["reason"] as? String,"backup_in_progress",file:file,line:line)
        XCTAssertNil(reply["command_outcome"],file:file,line:line)
        XCTAssertNil(reply["command_id"],file:file,line:line)
    }
    /// Hold the actual writer queue while reads execute on another thread. A
    /// fallback that accidentally enters it fails the bounded expectation, then
    /// releases cleanly rather than stranding the test process.
    private func withBlockedWriter(_ router: CommandRouter,_ body: @escaping () throws -> Void) {
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        let writer = expectation(description:"writer released"),reads = DispatchSemaphore(value:0)
        let operation = BackupReadOperation(body)
        DispatchQueue.global().async {
            router.dbQueue.writeWithoutTransaction {_ in entered.signal();_ = release.wait(timeout:.now()+10)}
            writer.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        DispatchQueue.global().async {
            do {try operation.run()} catch {XCTFail("Read failed: \(error)")}
            reads.signal()
        }
        let answer = reads.wait(timeout:.now()+1)
        release.signal()
        wait(for:[writer],timeout:5)
        if answer == .timedOut {_ = reads.wait(timeout:.now()+5)}
        XCTAssertEqual(answer,.success)
    }
    private func end(_ router: CommandRouter) {
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
    }
    func testOwnerOriginalReturnsLockedWithoutCreatingHoldAndRetryCreatesRealHold() throws {
        let (f,p,_,a) = try attachment(),router = f.router!
        let params: JSON = ["project_id":p["id"]!,"attachment_id":a["id"]!,"representation":"original"]
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {
            self.locked(try f.call("attachment_read",params))
            let metadata = try f.call("attachment_read",["project_id":p["id"]!,"attachment_id":a["id"]!])
            XCTAssertEqual((metadata["data"] as? JSON)?["id"] as? String,a["id"] as? String)
        }
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"storage_hold").filter {$0["kind"] as? String == "reader"}.count},0)
        end(router)
        let read = try XCTUnwrap(f.call("attachment_read",params)["data"] as? JSON)
        XCTAssertNotNil(read["read_hold_id"])
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:read["url"] as! String)),Data("immutable original".utf8))
    }
    func testMissingOriginalObservationIsRetriedWithoutFabricatingAvailability() throws {
        let (f,p,_,a) = try attachment(),router = f.router!,id = a["id"] as! String
        try FileManager.default.removeItem(at:router.managedURL(a["path"] as! String,family:"objects"))
        let params: JSON = ["project_id":p["id"]!,"attachment_id":id,"representation":"original"]
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {self.locked(try f.call("attachment_read",params))}
        XCTAssertEqual(try router.dbQueue.read {try router.record($0,id,type:"attachment")["availability"] as? String},"available")
        end(router)
        XCTAssertThrowsError(try f.call("attachment_read",params))
        XCTAssertEqual(try router.dbQueue.read {try router.record($0,id,type:"attachment")["availability"] as? String},"unavailable")
    }
    func testAvailabilityRepairWaitsForRetryAndDoesNotLoseOriginal() throws {
        let (f,p,_,a) = try attachment(),router = f.router!,id = a["id"] as! String
        try router.dbQueue.write {db in
            var value = try router.record(db,id,type:"attachment");value["availability"] = "unavailable"
            try router.save(db,value,type:"attachment")
        }
        let params: JSON = ["project_id":p["id"]!,"attachment_id":id,"representation":"original"]
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {self.locked(try f.call("attachment_read",params))}
        XCTAssertEqual(try router.dbQueue.read {try router.record($0,id,type:"attachment")["availability"] as? String},"unavailable")
        end(router)
        let read = try XCTUnwrap(f.call("attachment_read",params)["data"] as? JSON)
        XCTAssertEqual(read["availability"] as? String,"available");XCTAssertNotNil(read["read_hold_id"])
    }
    func testFirstCleanupPreviewIsLockedAndRetryPersistsExactlyOnePreview() throws {
        let (f,p,t,_) = try attachment(),router = f.router!
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!]
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {self.locked(try f.call("attachment_cleanup_preview",params))}
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"cleanup_preview").count},0)
        end(router)
        let first = try XCTUnwrap(f.call("attachment_cleanup_preview",params)["data"] as? JSON)
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {
            let repeated = try f.call("attachment_cleanup_preview",params)["data"] as? JSON
            XCTAssertEqual(repeated?["id"] as? String,first["id"] as? String)
        }
        end(router)
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"cleanup_preview").count},1)
    }
    func testNativeMediaReadAndLeaseRoutesReturnLockedWithoutWriterOrFakeLease() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),router = f.router!
        let routes: [(String,JSON)] = [
            ("media_original_read",["round_id":UUID().uuidString,"item_id":UUID().uuidString,"reference_id":UUID().uuidString]),
            ("media_original_read",["round_id":UUID().uuidString,"item_id":UUID().uuidString,"reference_id":UUID().uuidString,"representation":"lease"]),
            ("media_example_read_lease",["round_id":UUID().uuidString,"target_id":UUID().uuidString,"decision_id":UUID().uuidString,"reference_id":UUID().uuidString]),
            ("media_example_read_release",["lease_id":UUID().uuidString]),
            ("media_navigation",[:])]
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {
            for (method,input) in routes {
                var params = input;params["project_id"] = p["id"]!
                self.locked(try f.call(method,params))
            }
        }
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"storage_hold").count},0)
        end(router)
        XCTAssertNotNil((try f.call("media_navigation",["project_id":p["id"]!])["data"] as? JSON)?["types"])
    }
    func testWorkerOriginalBytesStillReadWithoutWriterAndNoQueuedIntentIsCreated() throws {
        let (f,p,_,a) = try attachment(),router = f.router!,installation = "backup-read-worker"
        let session = try XCTUnwrap(f.call("session_register",["project_id":p["id"]!,"label":"Read worker","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path])["data"] as? JSON)
        let worker = Caller(role:"worker",installation:installation,projectIDs:[p["id"] as! String],sessionID:session["id"] as? String,workspace:f.workspace.path)
        try router.backupWrites.beginCapture()
        withBlockedWriter(router) {
            let read = try f.call("attachment_read",["project_id":p["id"]!,"attachment_id":a["id"]!,"representation":"original"],caller:worker)
            XCTAssertEqual((read["data"] as? JSON)?["content_base64"] as? String,Data("immutable original".utf8).base64EncodedString())
            XCTAssertEqual((read["write_admission"] as? JSON)?["locked"] as? Bool,true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:router.root.appendingPathComponent("backup-write-queue").path))
        end(router)
    }
    func testLockedReplyPreservesObservedAdmissionAfterCaptureEnds() throws {
        let f = try StorageFixture(fast:true),router = f.router!
        try router.backupWrites.beginCapture()
        guard case .reply(let reply) = router.backupWrites.admitWriterDependentRead() else {return XCTFail("Read was not locked")}
        end(router)
        XCTAssertEqual(router.writeAdmissionStatus["locked"] as? Bool,false)
        locked(router.addingWriteAdmission(reply))
        XCTAssertFalse(FileManager.default.fileExists(atPath:router.root.appendingPathComponent("backup-write-queue").path))
    }
    func testAdmittedReadFallbackFencesCaptureUntilItFinishes() throws {
        let f = try StorageFixture(fast:true),router = f.router!
        guard case .run = router.backupWrites.admitWriterDependentRead() else {return XCTFail("Admission unexpectedly locked")}
        let locked = expectation(description:"capture closes admission")
        let captured = DispatchSemaphore(value:0)
        router.observeWriteAdmission {if router.writeAdmissionStatus["locked"] as? Bool == true {locked.fulfill()}}
        DispatchQueue.global().async {do {try router.backupWrites.beginCapture()} catch {XCTFail("\(error)")};captured.signal()}
        wait(for:[locked],timeout:5)
        XCTAssertEqual(captured.wait(timeout:.now()+0.05),.timedOut)
        router.backupWrites.finishWrite()
        XCTAssertEqual(captured.wait(timeout:.now()+5),.success)
        router.observeWriteAdmission {}
        end(router)
    }
}
