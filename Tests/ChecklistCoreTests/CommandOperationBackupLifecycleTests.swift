import ChecklistTestSupport
import XCTest
import Foundation
import Dispatch
import GRDB
@testable import ChecklistCore

final class CommandOperationBackupLifecycleTests: XCTestCase {
    private final class Lane {
        let queue = DispatchQueue(label:"backup-lifecycle-" + UUID().uuidString)
        private var held = true
        init(_ router: CommandRouter) {queue.suspend();router.configureCommandOperations(on:queue)}
        func finish(file: StaticString = #filePath,line: UInt = #line) {
            if held {held = false;queue.resume()}
            let done = DispatchSemaphore(value:0)
            queue.async {done.signal()}
            XCTAssertEqual(done.wait(timeout:.now()+30),.success,file:file,line:line)
        }
        deinit {if held {queue.resume()}}
    }
    private func data(_ reply: JSON) throws -> JSON {try XCTUnwrap(reply["data"] as? JSON)}
    private func worker(_ f: StorageFixture,_ project: JSON) throws -> Caller {
        let installation = "backup-lifecycle-worker",session = uuid(),domain = "claude:377:1:0"
        _ = try f.call("session_register",["project_id":project["id"]!,"session_id":session,
            "installation":installation,"provider":"claude","role":"worker","workspace":f.workspace.path,"execution_domain":domain])
        return Caller(role:"worker",installation:installation,projectIDs:[project["id"] as! String],
            sessionID:session,workspace:f.workspace.path,executionDomain:domain)
    }
    private func status(_ f: StorageFixture,_ command: String,project: String? = nil,caller: Caller? = nil) throws -> JSON {
        var input: JSON = ["command_id":command];input["project_id"] = project
        return try data(f.call("command_status",input,caller:caller))
    }

    func testAcceptedOwnerAndAgentBackupsOutliveTheReturningCaller() throws {
        for agent in [false,true] {
            let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
            let caller: Caller
            if agent {caller = try worker(f,project)} else {caller = f.owner}
            let lane = Lane(f.router!);defer {lane.finish()}
            let command = uuid(),input: JSON = agent ? ["project_id":pid] : ["path":f.base.appendingPathComponent("owner-backup").path]
            // The originating call has returned before service-owned work starts.
            let accepted = try data(f.call("backup_create",input,command:command,caller:caller))
            XCTAssertEqual(accepted["state"] as? String,"queued")
            lane.finish()
            let finished = try status(f,command,project:agent ? pid : nil,caller:caller)
            XCTAssertEqual(finished["operation_id"] as? String,accepted["operation_id"] as? String)
            XCTAssertEqual(finished["state"] as? String,"succeeded")
            XCTAssertEqual(((finished["result"] as? JSON)?["data"] as? JSON)?["status"] as? String,"complete")
            let replay = try data(f.call("backup_create",input,command:command,caller:caller))
            XCTAssertEqual(try jsonString(replay),try jsonString(finished))
        }
    }

    func testConfirmedNativeClosureDuringBackupRetainsItsFailedOutcomeAndRevokesReads() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let router = f.router!,caller = try worker(f,project),command = uuid()
        let generation = try router.dbQueue.read {try router.sessionGeneration(router.record($0,caller.sessionID!,type:"session"))}
        let proof = VerifiedNativeClosure(projectID:pid,sessionID:caller.sessionID!,installation:caller.installation,
            executionDomain:caller.executionDomain!,provider:"claude",authorizationGeneration:generation,
            processState:"gone",registryState:"absent",registryDigest:nil)
        let lane = Lane(router);defer {lane.finish()}
        let accepted = try data(f.call("backup_create",["project_id":pid],command:command,caller:caller))
        let id = try XCTUnwrap(accepted["operation_id"] as? String)
        var observed = false
        router.commandOperations.backupExecutionProbe = {phase in
            guard phase == "copying_objects" else {return}
            observed = true
            XCTAssertTrue(try StorageSnapshotRetention.isActive(root:f.root))
            XCTAssertEqual(try router.dbQueue.read {try router.operationRecord($0,id:id)?["state"] as? String},"running")
            _ = try router.reconcileVerifiedNativeClosure(proof,caller:Caller(role:"owner",installation:"native-lifecycle",projectIDs:[]))
        }
        lane.finish();router.commandOperations.backupExecutionProbe = nil
        XCTAssertTrue(observed,"The closure must happen after capture and during real backup work")
        let failed = try router.dbQueue.read {db in try router.operationPayload(db,XCTUnwrap(router.operationRecord(db,id:id)),caller:caller)}
        XCTAssertEqual(failed["state"] as? String,"failed")
        XCTAssertEqual((failed["error"] as? JSON)?["code"] as? String,"FORBIDDEN")
        XCTAssertEqual(failed["operation_id"] as? String,id)
        XCTAssertNotNil(failed["finished_at"])
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'")},0)
        XCTAssertThrowsError(try status(f,command,project:pid,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"RECIPIENT_CHANGED")}
        XCTAssertThrowsError(try f.call("backup_create",["project_id":pid],command:command,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"RECIPIENT_CHANGED")}
        let retained = try router.dbQueue.read {db in try router.operationPayload(db,XCTUnwrap(router.operationRecord(db,id:id)),caller:caller)}
        XCTAssertEqual(try jsonString(retained),try jsonString(failed),"A revoked caller cannot replace its first outcome")
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
    }

    func testCanceledAndUnknownBackupReplayKeepTheFirstErrorAndFolder() throws {
        for uncertain in [false,true] {
            let f = try StorageFixture(fast:true);_ = try f.project()
            var router: CommandRouter! = f.router
            let lane = Lane(router);defer {lane.finish()}
            let command = uuid(),input: JSON = ["path":f.base.appendingPathComponent("failed-backup").path]
            let accepted = try data(f.call("backup_create",input,command:command))
            router.commandOperations.backupExecutionProbe = {phase in
                if phase == "copying_objects" {throw uncertain ? StorageSnapshotFailure.publicationUncertain : StorageSnapshotFailure.canceled}
            }
            lane.finish();router.commandOperations.backupExecutionProbe = nil
            let failed = try status(f,command)
            XCTAssertEqual(failed["state"] as? String,"failed")
            XCTAssertEqual((failed["error"] as? JSON)?["code"] as? String,uncertain ? "OUTCOME_UNKNOWN" : "BACKUP_CANCELED")
            if uncertain {
                // Earlier builds marked this terminal backup recoverable. The
                // new replay rule must also preserve that existing receipt.
                try router.dbQueue.write {db in
                    var record = try XCTUnwrap(router.operationRecord(db,id:accepted["operation_id"] as! String))
                    record["recoverable"] = true;try router.saveOperation(db,record)
                }
            }
            let folders = try FileManager.default.contentsOfDirectory(atPath:f.base.path).sorted()
            let replay = try data(f.call("backup_create",input,command:command))
            lane.finish()
            XCTAssertEqual(replay["operation_id"] as? String,accepted["operation_id"] as? String)
            XCTAssertEqual(try jsonString(replay),try jsonString(failed))
            XCTAssertEqual(try jsonString(status(f,command)),try jsonString(failed))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.base.path).sorted(),folders)
            router = nil
            try f.reopen()
            let afterRestart = Lane(f.router!);defer {afterRestart.finish()}
            XCTAssertEqual(try jsonString(data(f.call("backup_create",input,command:command))),try jsonString(failed))
            afterRestart.finish()
            XCTAssertEqual(try jsonString(status(f,command)),try jsonString(failed))
        }
    }

    func testTerminalBackupReplayHonorsCanonicalResultAndErrorExpiry() throws {
        for succeeds in [false,true] {
            let f = try StorageFixture(fast:true);_ = try f.project()
            let router = f.router!,lane = Lane(router);defer {lane.finish()}
            let command = uuid(),input: JSON = ["path":f.base.appendingPathComponent("expiring-backup").path]
            let accepted = try data(f.call("backup_create",input,command:command))
            if !succeeds {router.commandOperations.backupExecutionProbe = {if $0 == "copying_objects" {throw StorageSnapshotFailure.canceled}}}
            lane.finish();router.commandOperations.backupExecutionProbe = nil
            let original = try status(f,command),id = accepted["operation_id"] as! String
            let resultCommand = succeeds ? command : CommandRouter.commandOperationID(principal:f.owner.principal,command:"error:" + id)
            try router.dbQueue.write {db in
                try db.execute(sql:"UPDATE commands SET result=? WHERE principal=? AND command_id=?",arguments:[CommandRouter.prunedResult,f.owner.principal,resultCommand])
            }
            XCTAssertThrowsError(try f.call("backup_create",input,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
            lane.finish()
            XCTAssertEqual(try router.dbQueue.read {try router.operationRecord($0,id:id)?["state"] as? String},original["state"] as? String)
        }
    }

    func testCommittedBackupReceiptWinsOverLaterFailureAndLegacyFailedMetadata() throws {
        let f = try StorageFixture(fast:true);_ = try f.project()
        var router: CommandRouter! = f.router
        let lane = Lane(router);defer {lane.finish()}
        let command = uuid(),input: JSON = ["path":f.base.appendingPathComponent("committed-backup").path]
        let accepted = try data(f.call("backup_create",input,command:command)),id = accepted["operation_id"] as! String
        var failedAfterReceipt = false
        router.commandOperations.backupExecutionProbe = {phase in
            if phase == "retention_end" {failedAfterReceipt = true;throw StorageSnapshotFailure.canceled}
        }
        lane.finish();router.commandOperations.backupExecutionProbe = nil
        XCTAssertTrue(failedAfterReceipt)
        let succeeded = try status(f,command)
        XCTAssertEqual(succeeded["state"] as? String,"succeeded")
        XCTAssertEqual(((succeeded["result"] as? JSON)?["data"] as? JSON)?["status"] as? String,"complete")
        XCTAssertNil(succeeded["error"])
        XCTAssertEqual(try jsonString(data(f.call("backup_create",input,command:command))),try jsonString(succeeded))
        // Older builds could leave a failed operation despite this committed
        // semantic receipt. Startup must recognize the real success too.
        try router.dbQueue.write {db in
            var record = try XCTUnwrap(router.operationRecord(db,id:id))
            record["state"] = "failed";record["error"] = CoreError("BACKUP_CANCELED","Late advisory failure").dictionary
            try router.saveOperation(db,record)
        }
        router = nil
        try f.reopen()
        let recovered = try status(f,command)
        XCTAssertEqual(recovered["state"] as? String,"succeeded")
        XCTAssertEqual(try jsonString(XCTUnwrap(recovered["result"])),try jsonString(XCTUnwrap(succeeded["result"])))
        XCTAssertNil(recovered["error"])
    }

    func testInterruptedBackupReplayKeepsOriginalOperationAndPartialFolder() throws {
        for originalState in ["queued","running"] {
            let f = try StorageFixture(fast:true);_ = try f.project()
            var router: CommandRouter! = f.router
            let command = uuid(),id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
            let destination = f.base.appendingPathComponent("interrupted-backup"),input: JSON = ["command_id":command,"path":destination.path]
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            let partial = destination.appendingPathComponent("database.sqlite"),partialBytes = Data("retained partial generation".utf8)
            try partialBytes.write(to:partial)
            let operation: JSON = ["operation_id":id,"command_id":command,"method":"backup_create","principal":f.owner.principal,
                "caller":["role":f.owner.role,"installation":f.owner.installation],"digest":ChecklistCore.hash(Data(("backup_create" + (try jsonString(input))).utf8)),
                "state":originalState,"incarnation":router.incarnation,"created_at":"2026-10-30T19:39:25Z","updated_at":"2026-10-30T19:39:25Z"]
            try router.dbQueue.write {try router.saveOperation($0,operation)}
            router = nil
            try f.reopen()
            let interrupted = try status(f,command)
            XCTAssertEqual((interrupted["error"] as? JSON)?["code"] as? String,"OPERATION_INTERRUPTED")
            XCTAssertEqual(((interrupted["error"] as? JSON)?["details"] as? JSON)?["command_outcome"] as? String,originalState == "running" ? "unknown" : "rejected")
            let lane = Lane(f.router!);defer {lane.finish()}
            let replay = try data(f.call("backup_create",input,command:command))
            lane.finish()
            XCTAssertEqual(try jsonString(replay),try jsonString(interrupted))
            XCTAssertEqual(try jsonString(status(f,command)),try jsonString(interrupted))
            XCTAssertEqual(try Data(contentsOf:partial),partialBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("manifest.json").path))
        }
    }
}
