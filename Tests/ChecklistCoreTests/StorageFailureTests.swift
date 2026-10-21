import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageFailureTests: XCTestCase {
    private func killedImport(_ mode: String) throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let source = f.workspace.appendingPathComponent("source.bin"),bytes = Data(repeating:0x39,count:65536)
        try bytes.write(to:source)
        let command = UUID().uuidString.lowercased(),params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]
        try f.writeCommand(params);try f.close()
        let child = try f.spawn(mode,command:command);try f.finish(child)
        XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        try f.reopen()
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'"),0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
        }
        // Finalized exact bytes remain retryable after original source loss.
        try FileManager.default.removeItem(at:source)
        let result = try f.call("attachment_add",params,command:command),a = result["data"] as! JSON
        XCTAssertEqual(a["availability"] as? String,"available")
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:a["path"] as! String)),bytes)
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),1)
        }
    }
    func testSIGKILLAfterOriginalFinalizationRetainsExactRetry() throws {try killedImport("import-finalized")}
    func testSIGKILLDuringSemanticReceiptRollsBackAvailableAndRetries() throws {try killedImport("import-commit")}
    func testSIGKILLAfterNoteCommitBeforeReplyReplaysWithoutDuplicateHistory() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),command = UUID().uuidString.lowercased()
        let sid = UUID().uuidString.lowercased()
        _ = try f.call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"storage-outbox-fixture"])
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"body":"Committed before external reply","kind":"note","recipient":["kind":"session","session_id":sid]]
        try f.writeCommand(params);try f.close()
        let child = try f.spawn("note-committed",command:command);try f.finish(child)
        XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("ready").path))
        try f.reopen()
        // Actual durable outbox rows, before replay. Queued is not native send,
        // acknowledgment or a model turn; the original recipient generation is
        // retained and retry must not mint another message/delivery.
        let committed = try f.router!.dbQueue.read {db -> (String,String,String) in
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE command_id=?",arguments:[command]))
            let message = try XCTUnwrap(jsonObject(raw)["data"] as? JSON),mid = try XCTUnwrap(message["id"] as? String)
            let deliveries = try f.router!.records(db,type:"delivery",project:p["id"] as? String).filter {$0["message_id"] as? String == mid}
            let delivery = try XCTUnwrap(deliveries.first);XCTAssertEqual(deliveries.count,1)
            XCTAssertEqual(delivery["recipient_session_id"] as? String,sid);XCTAssertEqual(delivery["state"] as? String,"queued")
            XCTAssertTrue(try f.router!.deliveryCurrent(db,delivery))
            return (mid,try XCTUnwrap(delivery["id"] as? String),try jsonString(delivery))
        }
        let replay = try f.call("message_send",params,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual((replay["data"] as? JSON)?["id"] as? String,committed.0)
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND json_extract(data,'$.body')='Committed before external reply'"),1)
            let deliveries = try f.router!.records(db,type:"delivery",project:p["id"] as? String).filter {$0["message_id"] as? String == committed.0}
            XCTAssertEqual(deliveries.count,1);XCTAssertEqual(deliveries.first?["id"] as? String,committed.1)
            XCTAssertEqual(try jsonString(try XCTUnwrap(deliveries.first)),committed.2)
        }
    }
    func testActualSQLiteFullRejectsWithoutLosingCommittedNoteOrReceiptTruth() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Preserved committed note","kind":"note"])
        let command = UUID().uuidString.lowercased()
        try f.router!.dbQueue.writeWithoutTransaction {db in
            let pages = try Int.fetchOne(db,sql:"PRAGMA page_count")!
            try db.execute(sql:"PRAGMA max_page_count=" + String(pages))
        }
        XCTAssertThrowsError(try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":String(repeating:"x",count:60_000),"kind":"note"],command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"OUTCOME_UNKNOWN");XCTAssertEqual(($0 as? CoreError)?.details["sqlite_result_code"] as? Int32,13)}
        try f.router!.dbQueue.writeWithoutTransaction {try $0.execute(sql:"PRAGMA max_page_count=1073741823")}
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND json_extract(data,'$.body')='Preserved committed note'"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND length(json_extract(data,'$.body'))=60000"),0)
        }
        try f.close();try f.reopen()
        XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND json_extract(data,'$.body')='Preserved committed note'")},1)
    }
    func testRepairedDestinationPermissionRetriesOriginalBackupWithoutEmptySuccess() throws {
        let f = try StorageFixture();_ = try f.project()
        let parent = f.base.appendingPathComponent("deny",isDirectory:true),destination = parent.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        XCTAssertEqual(chmod(parent.path,0o500),0);defer {_ = chmod(parent.path,0o700)}
        let command = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try f.call("backup_create",["path":destination.path],command:command))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command])},0)
        XCTAssertEqual(chmod(parent.path,0o700),0)
        XCTAssertEqual((try f.call("backup_create",["path":destination.path],command:command)["data"] as! JSON)["status"] as? String,"complete")
    }
    func testActualParentFlushFailureIsUncertainUntilFreshFlushAndTamperRefuses() throws {
        let f = try StorageFixture();_ = try f.project()
        let operation = UUID(),parent = f.base.appendingPathComponent("snapshots",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let identity = try f.router!.dbQueue.read {db in try StoreIdentityReceipt.decode(Data((try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'"))!.utf8))}
        var faultObserved = false
        try ArchiveStorageGate.withExclusive(root:f.root) {permit in
            let source = try StorageSnapshotSource(source:f.root,parent:parent,storeID:identity.logical_store_id,permit:permit)
            var budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime + 15,canceled:{false})
            budget.observe = {event in
                if event == "published_before_parent_flush" {
                    // Close only this child test's exact UUID-owned parent FD.
                    // The ensuing fsync is a real EBADF, not a modeled throw.
                    for fd in 3..<1024 {
                        var buffer = [CChar](repeating:0,count:Int(MAXPATHLEN))
                        let rc = buffer.withUnsafeMutableBufferPointer {fcntl(Int32(fd),F_GETPATH,$0.baseAddress!)}
                        if rc == 0,String(cString:buffer) == parent.path {faultObserved = true;_ = Darwin.close(Int32(fd))}
                    }
                }
            }
            XCTAssertThrowsError(try StorageSnapshot.build(source,operation:operation,budget:budget)) {if let failure = $0 as? StorageSnapshotFailure,case .publicationUncertain = failure {} else {XCTFail("Expected real parent publication uncertainty") }}
        }
        XCTAssertTrue(faultObserved)
        let receipt = try StorageSnapshot.reconcile(parent:parent,operation:operation,budget:.init(deadlineUptime:ProcessInfo.processInfo.systemUptime + 15,canceled:{false}))
        XCTAssertEqual(receipt.manifestSHA256.count,64)
        let directory = parent.appendingPathComponent(StorageSnapshot.names(operation).published)
        try Data("tampered".utf8).write(to:directory.appendingPathComponent("database.sqlite"))
        XCTAssertThrowsError(try StorageSnapshot.reconcile(parent:parent,operation:operation,budget:.init(deadlineUptime:ProcessInfo.processInfo.systemUptime + 5,canceled:{false})))
    }
    func testCorruptOriginalRefusesWithoutReplacement() throws {
        let f = try StorageFixture();_ = try f.project();try f.close()
        let database = f.root.appendingPathComponent("checklist.sqlite")
        var original = try Data(contentsOf:database);original.replaceSubrange(0..<16,with:Data(repeating:0x5a,count:16));try original.write(to:database)
        XCTAssertThrowsError(try f.reopen())
        XCTAssertEqual(try Data(contentsOf:database),original)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(StoreIdentityReceipt.fileName).path))
        let child = try f.spawn("recovery-refusal");try f.finish(child);XCTAssertEqual(child.terminationStatus,0)
        let info = try JSONSerialization.jsonObject(with:Data(contentsOf:f.base.appendingPathComponent("recovery-info.json"))) as! JSON
        XCTAssertEqual((info["data"] as! JSON)["state"] as? String,"recovery_required")
        XCTAssertEqual((info["data"] as! JSON)["persistent_store_open"] as? Bool,false)
        let denied = try JSONSerialization.jsonObject(with:Data(contentsOf:f.base.appendingPathComponent("recovery-refusal.json"))) as! JSON
        XCTAssertEqual((denied["error"] as! JSON)["code"] as? String,"RECOVERY_REQUIRED")
        XCTAssertEqual(try Data(contentsOf:database),original)
    }
}
