import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

private final class BackupQueueSignal: @unchecked Sendable {
    let lock = NSLock()
    var sent = false
    func once(_ body: () -> Void) {lock.lock();defer {lock.unlock()};if !sent {sent = true;body()}}
}

final class BackupWriteQueueTests: XCTestCase {
    private func drain(_ router: CommandRouter) {
        let finished = expectation(description:"durable write queue drains"),signal = BackupQueueSignal()
        router.observeWriteAdmission { [weak router] in
            guard let router else {return}
            if router.writeAdmissionStatus["locked"] as? Bool == false {signal.once {finished.fulfill()}}
        }
        router.backupWrites.endCapture(router:router)
        wait(for:[finished],timeout:15)
        router.backupWrites.endBackup(router:router)
        router.observeWriteAdmission {}
    }
    private func status(_ f: StorageFixture,_ command: String,_ project: JSON) throws -> JSON {
        let reply = try f.call("command_status",["project_id":project["id"]!,"command_id":command])
        return try XCTUnwrap(reply["data"] as? JSON)
    }

    private func worker(_ f: StorageFixture,_ project: JSON) throws -> Caller {
        let installation = "backup-queue-worker"
        let session = try XCTUnwrap(f.call("session_register",["project_id":project["id"]!,"label":"Backup queue worker","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path])["data"] as? JSON)
        return Caller(role:"worker",installation:installation,projectIDs:[project["id"] as! String],sessionID:session["id"] as? String,workspace:f.workspace.path)
    }

    func testReadsStayCurrentAndTwoWritesReturnQueuedThenApplyInArrivalOrder() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!
        try router.backupWrites.beginCapture()
        let note = UUID().uuidString,edit = UUID().uuidString
        let first = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Queued during consistent copy"],command:note)
        let second = try f.call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["title":"Applied after queued note"]],command:edit)
        for reply in [first,second] {
            XCTAssertEqual(reply["command_outcome"] as? String,"queued")
            let admission = reply["write_admission"] as? JSON
            XCTAssertEqual(admission?["locked"] as? Bool,true);XCTAssertEqual(admission?["queued"] as? Bool,true)
            XCTAssertEqual(admission?["reason"] as? String,"backup_in_progress")
            XCTAssertTrue(admission?["estimated_remaining_seconds"] is NSNull)
        }
        let read = try f.call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual((read["data"] as? JSON)?["title"] as? String,t["title"] as? String)
        XCTAssertEqual((read["write_admission"] as? JSON)?["locked"] as? Bool,true)
        XCTAssertEqual(try status(f,note,p)["state"] as? String,"queued")
        drain(router)
        XCTAssertEqual(try status(f,note,p)["state"] as? String,"applied")
        XCTAssertEqual(try status(f,edit,p)["state"] as? String,"applied")
        try router.dbQueue.read {db in
            let commands = try String.fetchAll(db,sql:"SELECT command_id FROM commands WHERE command_id IN (?,?) ORDER BY rowid",arguments:[note,edit])
            XCTAssertEqual(commands,[note,edit])
        }
        XCTAssertEqual((try f.call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])["data"] as? JSON)?["title"] as? String,"Applied after queued note")
    }

    func testSameIDKeepsOneIntentAndConflictDoesNotChangeOrder() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!,command = UUID().uuidString
        try router.backupWrites.beginCapture()
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"body":"Original queued intent"]
        _ = try f.call("message_send",params,command:command)
        _ = try f.call("message_send",params,command:command)
        var conflicting = params;conflicting["body"] = "Changed input"
        XCTAssertThrowsError(try f.call("message_send",conflicting,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:router.root.appendingPathComponent("backup-write-queue").path).filter {$0.hasSuffix(".intent")}.count,1)
        drain(router)
        let replay = try f.call("message_send",params,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).count},1)
    }

    func testAcceptedWritesRemainInStorageDrainAndFinishThroughTheirAdmission() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!
        try router.backupWrites.beginCapture()
        _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Accepted before drain"])
        let ticket = try router.beginStorageDrain(caller:f.owner)
        XCTAssertFalse(try router.waitForStorageDrain(ticket,timeout:0,caller:f.owner))
        drain(router)
        XCTAssertTrue(try router.waitForStorageDrain(ticket,timeout:1,caller:f.owner))
        try router.cancelStorageDrain(ticket,caller:f.owner)
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).count},1)
    }

    func testPendingIntentSurvivesRouterRestartAndUnpublishedTemporaryIsIgnored() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),command = UUID().uuidString
        try f.router!.backupWrites.beginCapture()
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"body":"Durable accepted note"]
        _ = try f.call("message_send",params,command:command)
        let temp = f.root.appendingPathComponent("backup-write-queue/.pending-" + UUID().uuidString.lowercased())
        try Data("incomplete unacknowledged bytes".utf8).write(to:temp)
        // This fixture deliberately models process loss, where the in-memory
        // capture flag disappears while fsynced accepted intents remain.
        try f.close();try f.reopen()
        let router = f.router!,finished = expectation(description:"restored intent applies"),signal = BackupQueueSignal()
        router.observeWriteAdmission { [weak router] in
            guard let router else {return}
            if router.writeAdmissionStatus["locked"] as? Bool == false {signal.once {finished.fulfill()}}
        }
        if router.writeAdmissionStatus["locked"] as? Bool == false {signal.once {finished.fulfill()}}
        wait(for:[finished],timeout:15)
        XCTAssertEqual(try status(f,command,p)["state"] as? String,"applied")
        XCTAssertEqual((try f.call("message_send",params,command:command))["replayed"] as? Bool,true)
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).count},1)
    }

    func testQueueStatusNeverExposesAnotherPrincipalAndRejectedWriteKeepsActualError() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!,command = UUID().uuidString
        try router.backupWrites.beginCapture()
        _ = try f.call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":9999,"patch":["title":"Must not apply"]],command:command)
        let other = Caller(role:"owner",installation:"different-authenticated-owner",projectIDs:[])
        let privateStatus = try f.call("command_status",["project_id":p["id"]!,"command_id":command],caller:other)["data"] as? JSON
        XCTAssertEqual(privateStatus?["state"] as? String,"unknown")
        drain(router)
        let result = try status(f,command,p)
        XCTAssertEqual(result["state"] as? String,"failed")
        XCTAssertEqual((result["error"] as? JSON)?["code"] as? String,"REVISION_CONFLICT")
        XCTAssertEqual((try f.call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])["data"] as? JSON)?["title"] as? String,t["title"] as? String)
    }
    func testQueuedWorkerRetainsItsStorageDrainAdmission() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!,worker = try worker(f,p),command = UUID().uuidString
        try router.backupWrites.beginCapture()
        _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Worker accepted before drain"],command:command,caller:worker)
        let ticket = try router.beginStorageDrain(caller:f.owner)
        XCTAssertFalse(try router.waitForStorageDrain(ticket,timeout:0,caller:f.owner))
        drain(router)
        XCTAssertTrue(try router.waitForStorageDrain(ticket,timeout:1,caller:f.owner))
        try router.cancelStorageDrain(ticket,caller:f.owner)
        let status = try f.call("command_status",["project_id":p["id"]!,"command_id":command],caller:worker)["data"] as? JSON
        XCTAssertEqual(status?["state"] as? String,"applied")
    }

    func testQueuedWorkerGenerationRotationFailsWithItsOriginalRejection() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!,worker = try worker(f,p),command = UUID().uuidString
        try router.backupWrites.beginCapture()
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"body":"Must not inherit rotated authorization"]
        _ = try f.call("message_send",params,command:command,caller:worker)
        try router.dbQueue.write {db in
            var session = try router.record(db,worker.sessionID!,type:"session")
            session["authorization_generation"] = UUID().uuidString
            try router.save(db,router.revised(session),type:"session")
        }
        drain(router)
        let result = try f.call("command_status",["project_id":p["id"]!,"command_id":command],caller:worker)["data"] as? JSON
        XCTAssertEqual(result?["state"] as? String,"failed")
        XCTAssertEqual((result?["error"] as? JSON)?["code"] as? String,"CONNECTION_REVOKED")
        XCTAssertThrowsError(try f.call("message_send",params,command:command,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"CONNECTION_REVOKED")}
        var changed = params;changed["body"] = "Do not reuse accepted UUID"
        XCTAssertThrowsError(try f.call("message_send",changed,command:command,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).count},0)
    }

    func testStatusUsesCanonicalReceiptAndCannotResurrectExpiredContent() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),command = UUID().uuidString
        do {
            let router = f.router!
            try router.backupWrites.beginCapture()
            _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Private journal content"],command:command)
            drain(router)
            let receiptDirectory = router.root.appendingPathComponent("backup-write-queue")
            let resultFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:receiptDirectory,includingPropertiesForKeys:nil).first {$0.pathExtension == "result"})
            let sidecar = try Data(contentsOf:resultFile)
            XCTAssertNil((try JSONSerialization.jsonObject(with:sidecar) as? JSON)?["result"])
            let result = try status(f,command,p)
            XCTAssertEqual((((result["result"] as? JSON)?["data"] as? JSON)?["body"]) as? String,"Private journal content")
            try router.dbQueue.write {db in try db.execute(sql:"UPDATE commands SET result=? WHERE principal=? AND command_id=?",arguments:[CommandRouter.prunedResult,f.owner.principal,command])}
            XCTAssertThrowsError(try status(f,command,p)) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
        }
        try f.close();try f.reopen()
        XCTAssertThrowsError(try status(f,command,p)) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
    }

    func testNativeSendFenceDefersWithoutQueueingOrClaimingACommit() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!
        let params: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["title":"Fence committed before external send"],"command_id":UUID().uuidString]
        try router.backupWrites.beginCapture()
        XCTAssertNil(try router.handleIfWriteAvailable(method:"task_edit",params:params,caller:f.owner))
        XCTAssertNil(router.withImmediateWriteAccess {true})
        XCTAssertFalse(FileManager.default.fileExists(atPath:router.root.appendingPathComponent("backup-write-queue").path))
        drain(router)
        let applied = try XCTUnwrap(router.handleIfWriteAvailable(method:"task_edit",params:params,caller:f.owner))
        XCTAssertEqual((applied["data"] as? JSON)?["title"] as? String,"Fence committed before external send")
        XCTAssertEqual(router.withImmediateWriteAccess {true},true)
    }

    func testRestoreAndFollowingWriteWaitForBackupRetentionWithoutFailingFIFO() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!
        let source = f.base.appendingPathComponent("restore-source")
        _ = try f.call("backup_create",["path":source.path])
        let preview = try XCTUnwrap(f.call("restore_preview",["path":source.path])["data"] as? JSON)
        let restore = UUID().uuidString,note = UUID().uuidString
        try router.backupWrites.beginCapture()
        let waiting = expectation(description:"restore pauses for retained backup objects"),finished = expectation(description:"retention release drains FIFO")
        let waitSignal = BackupQueueSignal(),finishSignal = BackupQueueSignal()
        router.observeWriteAdmission { [weak router] in
            guard let router else {return}
            let status = router.writeAdmissionStatus
            if status["reason"] as? String == "backup_in_progress",status["queued"] as? Bool == true {waitSignal.once {waiting.fulfill()}}
            if status["locked"] as? Bool == false {finishSignal.once {finished.fulfill()}}
        }
        try StorageSnapshotRetention.withCapture(root:router.root) { _ in
            _ = try f.call("restore_create",["path":source.path,"manifest_sha256":preview["manifest_sha256"]!],command:restore)
            _ = try f.call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"After retained restore"],command:note)
            router.backupWrites.endCapture(router:router)
            wait(for:[waiting],timeout:15)
            XCTAssertEqual(try status(f,restore,p)["state"] as? String,"queued")
            XCTAssertEqual(try status(f,note,p)["state"] as? String,"queued")
            XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).count},0)
        }
        router.backupWrites.endBackup(router:router)
        wait(for:[finished],timeout:15)
        XCTAssertEqual(try status(f,restore,p)["state"] as? String,"applied")
        XCTAssertEqual(try status(f,note,p)["state"] as? String,"applied")
        XCTAssertEqual(try router.dbQueue.read {try String.fetchAll($0,sql:"SELECT command_id FROM commands WHERE command_id IN (?,?) ORDER BY rowid",arguments:[restore,note])},[restore,note])
    }

    func testQueuedWorkerMediaSuggestionStatusRestoresItsNormalWireEnvelope() throws {
        let f = try MediaFrozenIntakeTests.Fixture(),helper = MediaWorkerChannelTests()
        let round = try f.round(f.type(MediaRoundTests().schema()))
        _ = try f.item(round);_ = try f.publish(round)
        let session = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:session["installation"] as! String,projectIDs:[f.project],
            sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let view = try helper.worker(f,"media_round_get",["round_id":round["id"]!],as:caller)
        var input = helper.suggestion(view,(view["items"] as! [JSON])[0]);input["note"] = "Queued worker advice"
        let command = uuid(),router = f.router!
        try router.backupWrites.beginCapture()
        var params = input;params["project_id"] = f.project;params["command_id"] = command
        let queued = try router.handle(method:"media_suggest",params:params,caller:caller)
        XCTAssertEqual(queued["command_outcome"] as? String,"queued")
        drain(router)
        let applied = try router.handle(method:"command_status",params:["project_id":f.project,"command_id":command],caller:caller)["data"] as! JSON
        XCTAssertEqual(applied["state"] as? String,"applied")
        let wire = try XCTUnwrap(applied["result"] as? JSON)
        XCTAssertEqual(wire["command_id"] as? String,command)
        let suggestion = try XCTUnwrap(((wire["data"] as? JSON)?["decisions"] as? [JSON])?.first)
        XCTAssertEqual(suggestion["note"] as? String,"Queued worker advice")
        let replay = try helper.worker(f,"media_suggest",input,as:caller,command:command)
        XCTAssertEqual((replay["decisions"] as! [JSON])[0]["id"] as? String,suggestion["id"] as? String)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
    }

    func testQueuedNativeMediaStatusRestoresItsNormalWireEnvelope() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),router = f.router!,command = UUID().uuidString
        try router.backupWrites.beginCapture()
        let input: JSON = ["project_id":p["id"]!,"title":"Queued native media type"]
        let queued = try f.call("media_type_create",input,command:command)
        XCTAssertEqual(queued["command_outcome"] as? String,"queued")
        drain(router)
        let applied = try status(f,command,p),wire = try XCTUnwrap(applied["result"] as? JSON)
        XCTAssertEqual(applied["state"] as? String,"applied")
        XCTAssertEqual(wire["command_id"] as? String,command)
        let data = try XCTUnwrap(wire["data"] as? JSON)
        XCTAssertEqual(data["title"] as? String,"Queued native media type")
        let replay = try f.call("media_type_create",input,command:command)
        XCTAssertEqual((replay["data"] as? JSON)?["id"] as? String,data["id"] as? String)
    }

    func testAlreadyAdmittedServiceWriteFinishesBeforeCopyDespiteNestedRouterCall() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),t = try f.task(p),router = f.router!
        let locked = expectation(description:"copy closes admission"),captured = expectation(description:"earlier service write finishes before copy")
        let signal = BackupQueueSignal()
        router.observeWriteAdmission { [weak router] in
            if router?.writeAdmissionStatus["locked"] as? Bool == true {signal.once {locked.fulfill()}}
        }
        let result = try router.withImmediateWriteAccess {
            DispatchQueue.global().async {
                do {try router.backupWrites.beginCapture()}
                catch {XCTFail("Capture failed: \(error)")}
                captured.fulfill()
            }
            wait(for:[locked],timeout:15)
            return try f.call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["title":"Earlier admitted service write"]])
        }
        XCTAssertNotEqual(result?["command_outcome"] as? String,"queued")
        XCTAssertEqual((result?["data"] as? JSON)?["title"] as? String,"Earlier admitted service write")
        wait(for:[captured],timeout:15)
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        router.observeWriteAdmission {}
    }

}
