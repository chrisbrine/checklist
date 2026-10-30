import ChecklistTestSupport
import XCTest
import Foundation
import Dispatch
import GRDB
@testable import ChecklistCore

/// Owned template stores only. Holding the utility lane proves acceptance does
/// not execute the command, without a timing-sensitive slow-file fixture.
final class CommandOperationTests: XCTestCase {
    private final class HeldLane {
        let queue = DispatchQueue(label:"checklist-command-operation-test-" + UUID().uuidString)
        private var held = true
        init(_ router: CommandRouter) {queue.suspend();router.configureCommandOperations(on:queue)}
        func release() {if held {held = false;queue.resume()}}
        func finish(file: StaticString = #filePath,line: UInt = #line) {
            release()
            let done = DispatchSemaphore(value:0)
            queue.async {done.signal()}
            XCTAssertEqual(done.wait(timeout:.now() + 30),.success,"Owned operation did not finish",file:file,line:line)
        }
        deinit {release()}
    }
    private func data(_ reply: JSON) throws -> JSON {try XCTUnwrap(reply["data"] as? JSON)}
    private func assertPublicMetadata(_ value: JSON,file: StaticString = #filePath,line: UInt = #line) {
        for key in ["digest","principal","caller","authorization_generation","incarnation","recoverable","reply_write_admission"] {
            XCTAssertNil(value[key],"Operation metadata exposed internal \(key)",file:file,line:line)
        }
    }
    private func read(_ f: StorageFixture,_ accepted: JSON,project: String? = nil,caller: Caller? = nil) throws -> JSON {
        var params: JSON = ["operation_id":try XCTUnwrap(data(accepted)["operation_id"] as? String)]
        params["project_id"] = project
        return try data(f.call("operation_get",params,caller:caller))
    }
    private func assertAccepted(_ f: StorageFixture,_ reply: JSON,method: String,command: String,file: StaticString = #filePath,line: UInt = #line) throws {
        let value = try data(reply),id = try XCTUnwrap(value["operation_id"] as? String,file:file,line:line)
        XCTAssertEqual(reply["command_outcome"] as? String,"accepted",file:file,line:line)
        XCTAssertEqual(reply["command_id"] as? String,command,file:file,line:line)
        XCTAssertEqual(value["state"] as? String,"queued",file:file,line:line)
        XCTAssertEqual(value["method"] as? String,method,file:file,line:line)
        XCTAssertEqual(value["status_method"] as? String,"operation_get",file:file,line:line)
        XCTAssertNotNil(value["created_at"],file:file,line:line)
        XCTAssertNotNil(value["updated_at"],file:file,line:line)
        assertPublicMetadata(value,file:file,line:line)
        try f.router!.dbQueue.read {db in
            let durable = try XCTUnwrap(f.router!.operationRecord(db,id:id),file:file,line:line)
            XCTAssertEqual(durable["command_id"] as? String,command,file:file,line:line)
            XCTAssertEqual(durable["principal"] as? String,f.owner.principal,file:file,line:line)
            XCTAssertNotNil(durable["caller"],file:file,line:line)
            XCTAssertEqual(durable["state"] as? String,"queued",file:file,line:line)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]),0,file:file,line:line)
        }
    }
    @discardableResult private func assertSucceeded(_ f: StorageFixture,_ accepted: JSON,project: String? = nil,file: StaticString = #filePath,line: UInt = #line) throws -> JSON {
        let value = try read(f,accepted,project:project)
        XCTAssertEqual(value["state"] as? String,"succeeded",file:file,line:line)
        XCTAssertNotNil(value["started_at"],file:file,line:line)
        XCTAssertNotNil(value["finished_at"],file:file,line:line)
        let result = try XCTUnwrap(value["result"] as? JSON,file:file,line:line)
        let command = try XCTUnwrap(data(accepted)["command_id"] as? String,file:file,line:line)
        let raw = try f.router!.dbQueue.read {db in try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]),file:file,line:line)}
        XCTAssertEqual(try jsonString(result),try jsonString(jsonObject(raw)),"Status must preserve the original complete command envelope",file:file,line:line)
        XCTAssertNil(value["principal"],file:file,line:line)
        XCTAssertNil(value["authorization_generation"],file:file,line:line)
        XCTAssertNil(value["caller"],file:file,line:line)
        assertPublicMetadata(value,file:file,line:line)
        return result
    }

    func testBackupAndRestoreReturnBeforeLaneRunsThenExposeOriginalReplies() throws {
        let f = try StorageFixture(fast:true);_ = try f.project()
        let destination = f.base.appendingPathComponent("operation-backup"),command = uuid(),input: JSON = ["path":destination.path]
        let lane = HeldLane(f.router!);defer {lane.finish()}
        let accepted = try f.call("backup_create",input,command:command)
        try assertAccepted(f,accepted,method:"backup_create",command:command)
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try data(f.call("backup_create",input,command:command))["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        XCTAssertEqual(try read(f,accepted)["state"] as? String,"queued")
        lane.finish()
        let backup = try data(assertSucceeded(f,accepted))
        XCTAssertEqual(backup["status"] as? String,"complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try data(f.call("backup_create",input,command:command))["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        let status = try data(f.call("command_status",["command_id":command]))
        XCTAssertEqual(status["operation_id"] as? String,try data(accepted)["operation_id"] as? String)

        let previewLane = HeldLane(f.router!);defer {previewLane.finish()}
        let pc = uuid(),previewInput: JSON = ["path":destination.path,"command_id":pc]
        let previewAccepted = try f.call("restore_preview",previewInput,command:pc)
        try assertAccepted(f,previewAccepted,method:"restore_preview",command:pc)
        previewLane.finish()
        let preview = try data(assertSucceeded(f,previewAccepted))
        let restoreLane = HeldLane(f.router!);defer {restoreLane.finish()}
        let rc = uuid(),restoreInput: JSON = ["path":destination.path,"manifest_sha256":preview["manifest_sha256"]!]
        let restoreAccepted = try f.call("restore_create",restoreInput,command:rc)
        try assertAccepted(f,restoreAccepted,method:"restore_create",command:rc)
        restoreLane.finish()
        let restored = try data(assertSucceeded(f,restoreAccepted))
        XCTAssertNotEqual(restored["store_incarnation"] as? String,f.router!.incarnation)
        XCTAssertEqual(try data(f.call("restore_create",restoreInput,command:rc))["operation_id"] as? String,try data(restoreAccepted)["operation_id"] as? String)
    }

    func testCleanupPreviewAndArchiveCleanupKeepTheirFinalDomainReplies() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String
        let previewLane = HeldLane(f.router!);defer {previewLane.finish()}
        let pc = uuid(),previewInput: JSON = ["project_id":pid,"task_id":task["id"]!,"command_id":pc]
        let accepted = try f.call("attachment_cleanup_preview",previewInput,command:pc)
        try assertAccepted(f,accepted,method:"attachment_cleanup_preview",command:pc)
        previewLane.finish()
        let preview = try data(assertSucceeded(f,accepted,project:pid))
        XCTAssertNotNil(preview["cleanup_preview_id"])
        XCTAssertEqual(try data(f.call("attachment_cleanup_preview",previewInput,command:pc))["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        let lane = HeldLane(f.router!);defer {lane.finish()}
        let command = uuid(),input: JSON = ["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!]
        let archived = try f.call("task_archive",input,command:command)
        try assertAccepted(f,archived,method:"task_archive",command:command)
        XCTAssertFalse(bool(try data(f.call("task_get",["project_id":pid,"task_id":task["id"]!])),"archived"))
        lane.finish()
        _ = try assertSucceeded(f,archived,project:pid)
        XCTAssertTrue(bool(try data(f.call("task_get",["project_id":pid,"task_id":task["id"]!])),"archived"))
        XCTAssertEqual(try data(f.call("task_archive",input,command:command))["operation_id"] as? String,try data(archived)["operation_id"] as? String)
    }

    func testImportPreviewAndCommitKeepTheirFinalDomainReplies() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let directory = f.workspace.appendingPathComponent("import")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let document: JSON = ["format":"synthetic-board/1","items":[["id":"OP-1","title":"Operation import","state":"queued"]],"events":[]]
        try JSONSerialization.data(withJSONObject:document,options:.sortedKeys).write(to:directory.appendingPathComponent("bundle.json"))
        let epic = try f.router!.dbQueue.read {try f.router!.records($0,type:"group",project:pid).first {$0["kind"] as? String == "epic"}!}
        let current = try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")}
        var input: JSON = ["project_id":pid,"path":directory.path,"source_format":"synthetic-board/1","source_namespace":"operation-fixture","expected_revision":current["revision"]!,"epic_id":epic["id"]!]
        let previewLane = HeldLane(f.router!);defer {previewLane.finish()}
        let pc = uuid();input["command_id"] = pc
        let accepted = try f.call("import_preview",input,command:pc)
        try assertAccepted(f,accepted,method:"import_preview",command:pc)
        previewLane.finish()
        let preview = try data(assertSucceeded(f,accepted,project:pid))
        XCTAssertEqual(try data(f.call("import_preview",input,command:pc))["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        input["preview_digest"] = preview["preview_digest"];input.removeValue(forKey:"command_id")
        let lane = HeldLane(f.router!);defer {lane.finish()}
        let command = uuid(),commit = try f.call("import_commit",input,command:command)
        try assertAccepted(f,commit,method:"import_commit",command:command)
        XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.records($0,type:"task",project:pid).count},0)
        lane.finish()
        XCTAssertEqual(try data(assertSucceeded(f,commit,project:pid))["task_count"] as? Int,1)
        XCTAssertEqual(try data(f.call("import_commit",input,command:command))["operation_id"] as? String,try data(commit)["operation_id"] as? String)
    }

    func testEveryAlwaysOperationMethodAndArchiveCleanupPersistFailureReplayAndRestartRecovery() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let invalidSource = f.base.appendingPathComponent("invalid-source")
        try Data([0]).write(to:invalidSource)
        let methods = CommandRouter.alwaysOperationMethods.union(CommandRouter.operationEvidenceMethods).union(["task_archive","attachment_add","attachment_read","work_submit","batch_submit","project_edit","project_settings_save"])
        for method in methods.sorted() {
            let lane = HeldLane(f.router!);defer {lane.finish()}
            let command = uuid()
            let input: JSON = ["project_id":pid,"command_id":command,"path":invalidSource.path,"task_id":uuid(),"cleanup":true]
            let accepted = try f.router!.acceptCommandOperation(method:method,params:input,caller:f.owner)
            try assertAccepted(f,accepted,method:method,command:command)
            let id = try XCTUnwrap(data(accepted)["operation_id"] as? String)
            XCTAssertEqual(try data(f.call(method,input,command:command))["operation_id"] as? String,id,method)
            lane.finish()
            let failed = try read(f,accepted,project:pid)
            assertPublicMetadata(failed)
            XCTAssertEqual(failed["state"] as? String,"failed",method)
            XCTAssertNotNil((failed["error"] as? JSON)?["code"],method)
            XCTAssertNil(failed["result"],method)
            XCTAssertNotNil(failed["finished_at"],method)
            XCTAssertEqual(try data(f.call(method,input,command:command))["operation_id"] as? String,id,method)
            XCTAssertEqual(try read(f,accepted,project:pid)["state"] as? String,"failed",method)
            // Simulate process death after durable admission, with no live job
            // or lease left behind. The next startup must retain a truthful error.
            try f.router!.dbQueue.write {db in
                var record = try XCTUnwrap(f.router!.operationRecord(db,id:id))
                record["state"] = "running";record.removeValue(forKey:"error");record.removeValue(forKey:"finished_at")
                try f.router!.saveOperation(db,record)
            }
            try f.reopen()
            let recovered = try read(f,accepted,project:pid)
            XCTAssertEqual(recovered["state"] as? String,"failed",method)
            XCTAssertEqual((recovered["error"] as? JSON)?["code"] as? String,"OPERATION_INTERRUPTED",method)
            let retryLane = HeldLane(f.router!);defer {retryLane.finish()}
            let retry = try f.call(method,input,command:command)
            XCTAssertEqual(try data(retry)["operation_id"] as? String,id,method)
            XCTAssertEqual(try data(retry)["state"] as? String,"queued",method)
            retryLane.finish()
            XCTAssertEqual(try read(f,accepted,project:pid)["state"] as? String,"failed",method)
        }
    }

    func testOperationScopeIntentReservationAndShortCommandsStaySynchronous() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let lane = HeldLane(f.router!);defer {lane.finish()}
        let command = uuid(),input: JSON = ["project_id":pid,"task_id":uuid(),"command_id":command]
        let accepted = try f.call("attachment_cleanup_preview",input,command:command)
        let foreign = Caller(role:"owner",installation:"different-owner",projectIDs:[])
        XCTAssertThrowsError(try read(f,accepted,project:pid,caller:foreign)) {XCTAssertEqual(($0 as? CoreError)?.code,"NOT_FOUND")}
        XCTAssertThrowsError(try read(f,accepted,project:uuid())) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        var changed = input;changed["task_id"] = uuid()
        XCTAssertThrowsError(try f.call("attachment_cleanup_preview",changed,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        XCTAssertThrowsError(try f.call("task_create",["project_id":pid,"title":"Reused operation UUID"],command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
        let short = try f.call("task_create",["project_id":pid,"title":"Synchronous edit"])
        XCTAssertNotNil(try data(short)["id"])
        XCTAssertNotEqual(short["command_outcome"] as? String,"accepted")
        lane.finish()
    }

    func testAdmittedQueuedOperationKeepsDrainOpenUntilItsContinuationFinishes() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let lane = HeldLane(f.router!);defer {lane.finish()}
        let command = uuid(),accepted = try f.call("attachment_cleanup_preview",["project_id":pid,"task_id":uuid(),"command_id":command],command:command)
        let drain = try f.router!.beginStorageDrain(caller:f.owner)
        defer {try? f.router!.cancelStorageDrain(drain,caller:f.owner)}
        XCTAssertFalse(try f.router!.waitForStorageDrain(drain,timeout:0,caller:f.owner))
        XCTAssertThrowsError(try f.call("task_create",["project_id":pid,"title":"Rejected during drain"])) {XCTAssertEqual(($0 as? CoreError)?.code,"STORAGE_DRAINING")}
        lane.finish()
        XCTAssertTrue(try f.router!.waitForStorageDrain(drain,timeout:1,caller:f.owner))
        // Reading is performed after returning admission, like the lifecycle owner.
        try f.router!.cancelStorageDrain(drain,caller:f.owner)
        XCTAssertEqual(try read(f,accepted,project:pid)["state"] as? String,"failed")
    }

    func testStartupRecoversQueuedAndRunningCanonicalReceiptsWithoutLosingFinalEnvelope() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        var replies: [(JSON,JSON)] = []
        for state in ["queued","running"] {
            let command = uuid(),id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
            let result: JSON = ["command_id":command,"data":["fixture":"canonical-" + state],"event_cursor":"retained-envelope"]
            let record: JSON = ["operation_id":id,"command_id":command,"method":"import_commit","principal":f.owner.principal,"caller":["role":"owner","installation":f.owner.installation],"project_id":pid,"incarnation":f.router!.incarnation,"digest":"fixture-digest-" + state,"state":state,"created_at":now(),"updated_at":now()]
            try f.router!.dbQueue.write {db in
                try f.router!.saveOperation(db,record)
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[f.owner.principal,command,record["digest"] as! String,try jsonString(result)])
            }
            replies.append((["data":["operation_id":id]],result))
        }
        try f.reopen()
        for (accepted,expected) in replies {
            let value = try read(f,accepted,project:pid)
            XCTAssertEqual(value["state"] as? String,"succeeded")
            XCTAssertEqual(try jsonString(XCTUnwrap(value["result"] as? JSON)),try jsonString(expected))
        }
    }

    func testSourceTargetClassificationFindsNestedManifestEvidenceAndExplicitReferencedIDs() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),router = f.router!,pid = project["id"] as! String,tid = task["id"] as! String
        let params: JSON = ["project_id":pid,"task_id":tid]
        XCTAssertFalse(try router.needsCommandOperation(method:"task_complete",params:params,caller:f.owner))
        let manifestID = uuid()
        let evidenceCases: [JSON] = [
            ["source_capture":["id":uuid()]],
            ["artifact_refs":[["artifact_id":uuid()]]],
            ["playtest_bundle":["id":uuid()]],
            ["acceptance_evidence":[["evidence_refs":[["kind":"attachment","attachment_id":uuid(),"sha256":String(repeating:"a",count:64)]]]]]
        ]
        // Classifier planning reads metadata only. Insert owned pseudo-manifests
        // directly as matching SQL/JSON envelopes: these are deliberately not a
        // complete runnable domain graph and are never reopened or executed.
        for evidence in evidenceCases {
            try router.dbQueue.write {db in
                var current = try router.record(db,tid,type:"task")
                current["current_manifest_id"] = manifestID
                try db.execute(sql:"UPDATE records SET data=? WHERE id=?",arguments:[try jsonString(current),tid])
                let manifest: JSON = ["id":manifestID,"project_id":pid,"task_id":tid,"revision":1,"evidence":evidence]
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?, 'manifest',1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",arguments:[manifestID,pid,try jsonString(manifest)])
            }
            for method in ["task_complete","review_context","review_prepare","review_batch_inputs","work_takeover"] {
                XCTAssertTrue(try router.needsCommandOperation(method:method,params:params,caller:f.owner),method)
            }
            var completion = params;completion["include_completion_eligibility"] = true
            XCTAssertTrue(try router.needsCommandOperation(method:"task_get",params:completion,caller:f.owner))
            XCTAssertFalse(try router.needsCommandOperation(method:"task_get",params:params,caller:f.owner))
            XCTAssertTrue(try router.needsCommandOperation(method:"work_claim",params:["project_id":pid,"task_id":tid,"phase":"review"],caller:f.owner))
            XCTAssertFalse(try router.needsCommandOperation(method:"work_claim",params:["project_id":pid,"task_id":tid,"phase":"implementation"],caller:f.owner))
        }
        try router.dbQueue.write {db in
            var current = try router.record(db,tid,type:"task")
            current.removeValue(forKey:"current_manifest_id")
            try db.execute(sql:"UPDATE records SET data=? WHERE id=?",arguments:[try jsonString(current),tid])
        }
        for key in ["artifact_id","attachment_id","source_capture_id"] {
            var input = params
            input["evidence_refs"] = [["nested":[key:uuid()]]]
            XCTAssertTrue(try router.needsCommandOperation(method:"review_evidence_add",params:input,caller:f.owner),key)
        }
        XCTAssertFalse(try router.needsCommandOperation(method:"review_evidence_add",params:params,caller:f.owner))
    }

    func testPolicyAndProjectContextCascadesReturnOriginalRepliesWhileCosmeticEditsStaySynchronous() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        _ = try f.task(project)
        let policy = project["policy"] as? JSON ?? [:]
        let calls: [(String,JSON)] = [("policy_preview",["policy":policy]),("policy_propose",["policy":policy]),
            ("policy_apply",["policy":policy]),("project_edit",["brief":"Owned context change"]),
            ("project_settings_save",["pinned_decisions":["Owned decision"]]),("project_settings_save",["policy":policy])]
        for (method,patch) in calls {
            let current = try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")}
            var input = patch;input["project_id"] = pid;input["expected_revision"] = current["revision"]!
            let lane = HeldLane(f.router!);defer {lane.finish()}
            let command = uuid();input["command_id"] = command
            let accepted = try f.call(method,input,command:command)
            try assertAccepted(f,accepted,method:method,command:command)
            lane.finish();_ = try assertSucceeded(f,accepted,project:pid)
            XCTAssertEqual(try data(f.call(method,input,command:command))["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        }
        let current = try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")}
        let cosmetic = try f.call("project_edit",["project_id":pid,"expected_revision":current["revision"]!,"name":"Cosmetic update"])
        XCTAssertNil(cosmetic["command_outcome"])
        XCTAssertEqual((cosmetic["data"] as? JSON)?["name"] as? String,"Cosmetic update")
        XCTAssertFalse(try f.router!.needsCommandOperation(method:"project_settings_save",params:["project_id":pid,"accent":"teal"],caller:f.owner))
    }

    func testMediaPublicationPreviewOperationKeepsReadEnvelopeAndCanonicalSemanticPayload() throws {
        let media = try MediaRoundTests.Fixture(),f = media.storage
        let schema: JSON = ["schema_version":1,"id":"server","name":"Operation preview","slots":[["id":"text","kind":"text","required":true]],"layout":["kind":"text_compare","primary_slot_id":"text"]]
        let round = try media.round(media.type(schema)),input: JSON = ["project_id":media.project,"round_id":round["id"]!]
        let lane = HeldLane(media.router);defer {lane.finish()}
        let command = uuid();var selected = input;selected["command_id"] = command
        let accepted = try f.call("media_publication_preview",selected,command:command)
        try assertAccepted(f,accepted,method:"media_publication_preview",command:command)
        lane.finish()
        let status = try read(f,accepted,project:media.project)
        XCTAssertEqual(status["state"] as? String,"succeeded",String(describing:status["error"]))
        let reply = try XCTUnwrap(status["result"] as? JSON),semantic = try data(reply)
        XCTAssertNil(reply["command_id"],"The former synchronous owner read has no command ID")
        XCTAssertNotNil(semantic["items"])
        let raw = try media.router.dbQueue.read {db in try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))}
        XCTAssertEqual(try jsonString(semantic),try jsonString(jsonObject(raw)))
        XCTAssertNil(jsonObject(raw)["data"])
    }

    func testMediaOperationPreservesSemanticJournalAndProjectsExactlyOneEnvelope() throws {
        let media = try MediaRoundTests.Fixture(),f = media.storage
        let schema: JSON = ["schema_version":1,"id":"server","name":"Operation text","slots":[["id":"text","kind":"text","required":true]],"layout":["kind":"text_compare","primary_slot_id":"text"]]
        let round = try media.round(media.type(schema)),command = uuid()
        let input: JSON = ["project_id":media.project,"round_id":round["id"]!,"text":"one\ntwo\n"]
        let lane = HeldLane(media.router);defer {lane.finish()}
        let accepted = try f.call("media_intake_preview",input,command:command)
        try assertAccepted(f,accepted,method:"media_intake_preview",command:command)
        lane.finish()
        let operation = try read(f,accepted,project:media.project)
        XCTAssertEqual(operation["state"] as? String,"succeeded")
        assertPublicMetadata(operation)
        let reply = try XCTUnwrap(operation["result"] as? JSON),semantic = try data(reply)
        let journal = try media.router.dbQueue.read {db in
            try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))
        }
        let raw = jsonObject(journal)
        XCTAssertNotNil(raw["id"])
        XCTAssertNil(raw["data"],"The media journal remains its original semantic payload")
        XCTAssertNil(raw["command_id"])
        XCTAssertEqual(try jsonString(semantic),try jsonString(raw))
        XCTAssertEqual(reply["command_id"] as? String,command)
        XCTAssertEqual(strings(semantic,"remaining_row_ids").count,2)
        let replay = try f.call("media_intake_preview",input,command:command)
        XCTAssertEqual(try data(replay)["operation_id"] as? String,try data(accepted)["operation_id"] as? String)
        XCTAssertEqual(try media.router.dbQueue.read {try media.router.records($0,type:"media_intake",project:media.project).count},1)
    }

    func testWorkerGenerationChangeBeforeExecutionRejectsWithoutCreatingPreviewOrReply() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),router = f.router!,pid = project["id"] as! String
        let installation = "operation-generation-worker"
        let session = try data(f.call("session_register",["project_id":pid,"label":"Operation worker","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path]))
        let worker = Caller(role:"worker",installation:installation,projectIDs:[pid],sessionID:session["id"] as? String,workspace:f.workspace.path)
        let lane = HeldLane(router);defer {lane.finish()}
        let command = uuid(),input: JSON = ["project_id":pid,"task_id":task["id"]!,"command_id":command]
        let accepted = try f.call("attachment_cleanup_preview",input,command:command,caller:worker)
        let id = try XCTUnwrap(data(accepted)["operation_id"] as? String)
        XCTAssertEqual(try data(accepted)["state"] as? String,"queued")
        try router.dbQueue.write {db in
            var current = try router.record(db,worker.sessionID!,type:"session")
            current["authorization_generation"] = uuid();try router.save(db,router.revised(current),type:"session")
        }
        lane.finish()
        try router.dbQueue.read {db in
            let failed = try XCTUnwrap(router.operationRecord(db,id:id))
            XCTAssertEqual(failed["state"] as? String,"failed")
            let errorCommand = try XCTUnwrap(failed["error_result_command_id"] as? String)
            let errorReceipt = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[worker.principal,errorCommand]))
            XCTAssertEqual((jsonObject(errorReceipt)["error"] as? JSON)?["code"] as? String,"CONNECTION_REVOKED")
            XCTAssertNil(failed["error"],"Private error details have one purge-governed journal owner")
            XCTAssertEqual(try router.records(db,type:"cleanup_preview",project:pid).count,0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal=? AND command_id=?",arguments:[worker.principal,command]),0)
        }
        XCTAssertThrowsError(try read(f,accepted,project:pid,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"CONNECTION_REVOKED")}
        XCTAssertThrowsError(try f.call("attachment_cleanup_preview",input,command:command,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"CONNECTION_REVOKED")}
    }
    func testConcurrentDifferentIntentsCannotOwnBothAdmissionJournals() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String,router = f.router!
        try router.backupWrites.beginCapture()
        defer {router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)}
        let lane = HeldLane(router);defer {lane.finish()}
        for _ in 0..<3 {
            let command = uuid(),results = OperationAdmissionResults(),done = DispatchGroup(),caller = f.owner
            let calls: [(String,JSON)] = [
                ("attachment_cleanup_preview",["command_id":command,"project_id":pid,"task_id":task["id"]!]),
                ("task_create",["command_id":command,"project_id":pid,"title":"Competing original intent"])]
            // Freeze JSON before transfer to independent request lanes.
            for (method,input) in calls {
                let bytes = try JSONSerialization.data(withJSONObject:input)
                done.enter()
                DispatchQueue.global().async {
                    defer {done.leave()}
                    results.append(Result {try router.handle(method:method,params:JSONSerialization.jsonObject(with:bytes) as! JSON,caller:caller)})
                }
            }
            XCTAssertEqual(done.wait(timeout:.now()+10),.success)
            let outputs = results.values
            XCTAssertEqual(outputs.count,2)
            XCTAssertEqual(outputs.filter {if case .success = $0 {return true};return false}.count,1)
            for output in outputs {if case .failure(let error) = output {XCTAssertEqual((error as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}}
            let input: JSON = ["command_id":command]
            let generic = try router.hasCommandOperation(params:input,caller:f.owner)
            let fifo = router.backupWrites.hasReservedCommand(params:input,caller:f.owner)
            XCTAssertNotEqual(generic,fifo,"Exactly one durable journal owns a caller/UUID")
        }
        let drained = expectation(description:"competing admissions finish their original FIFO")
        let signal = OperationAdmissionSignal()
        router.observeWriteAdmission { [weak router] in
            guard let router,router.writeAdmissionStatus["locked"] as? Bool == false else {return}
            router.resumeCommandOperations();signal.once {drained.fulfill()}
        }
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        wait(for:[drained],timeout:15)
        lane.finish();router.observeWriteAdmission {}
    }

    /// CL-353 F1: read operations take no backup write admission. A capture
    /// begins while a read operation executes, a read operation starts and runs
    /// during the capture, and a write operation still waits for the capture.
    func testReadOperationsRunDuringCaptureWhileWriteOperationsWait() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String,router = f.router!
        _ = try f.task(project)
        let policy = project["policy"] as? JSON ?? [:]
        func accept(_ method: String) throws -> JSON {
            let current = try router.dbQueue.read {try router.record($0,pid,type:"project")}
            let command = uuid()
            let accepted = try f.call(method,["project_id":pid,"policy":policy,"expected_revision":current["revision"]!,"command_id":command],command:command)
            try assertAccepted(f,accepted,method:method,command:command)
            return accepted
        }
        func durableState(_ accepted: JSON) throws -> String? {
            let id = try XCTUnwrap(data(accepted)["operation_id"] as? String)
            return try router.dbQueue.read {try router.operationRecord($0,id:id)?["state"] as? String}
        }
        let lane = HeldLane(router);defer {lane.finish()}
        let first = try accept("policy_preview")
        let firstID = try XCTUnwrap(data(first)["operation_id"] as? String)
        let probe = OperationCaptureProbe()
        router.commandOperations.executionProbe = { id in
            if id == firstID {
                // Begin a capture on another thread while this read executes.
                let began = DispatchSemaphore(value:0)
                DispatchQueue.global().async {
                    do {try router.backupWrites.beginCapture()} catch {probe.fail(error)}
                    began.signal()
                }
                probe.setCaptureBegan(began.wait(timeout:.now() + 5) == .success)
            }
            probe.record(id,locked:router.writeAdmissionStatus["locked"] as? Bool == true)
        }
        defer {router.commandOperations.executionProbe = nil}
        lane.finish()
        XCTAssertTrue(probe.captureBegan,"A capture must not wait for a running read operation")
        XCTAssertNil(probe.error)
        XCTAssertEqual(router.writeAdmissionStatus["locked"] as? Bool,true)
        // The finished read waits for admission only for its terminal-state write.
        XCTAssertEqual(try durableState(first),"running")
        XCTAssertEqual(try read(f,first,project:pid)["state"] as? String,"running")
        XCTAssertNil(try read(f,first,project:pid)["result"])

        let second = try accept("policy_preview"),write = try accept("policy_propose")
        let secondID = try XCTUnwrap(data(second)["operation_id"] as? String),writeID = try XCTUnwrap(data(write)["operation_id"] as? String)
        lane.finish()
        XCTAssertTrue(probe.executions.contains {$0.id == secondID && $0.locked},"A read operation must start and run during a capture")
        XCTAssertFalse(probe.executions.contains {$0.id == writeID},"A write operation must wait for the capture")
        XCTAssertEqual(try durableState(second),"queued","No operation write happens during a capture")
        XCTAssertEqual(try read(f,second,project:pid)["state"] as? String,"running")
        XCTAssertEqual(try durableState(write),"queued")
        XCTAssertEqual(try read(f,write,project:pid)["state"] as? String,"queued")

        router.observeWriteAdmission { [weak router] in router?.resumeCommandOperations() }
        defer {router.observeWriteAdmission {}}
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        lane.finish()
        XCTAssertTrue(probe.executions.contains {$0.id == writeID && !$0.locked},"The write operation runs after the capture")
        XCTAssertEqual(probe.executions.filter {$0.id == firstID || $0.id == secondID}.count,2,"A held read reply is not executed again")
        for accepted in [first,second,write] {_ = try assertSucceeded(f,accepted,project:pid)}
    }

    /// Unlike the earlier logical-capture test, this holds SQLite's real writer
    /// lease. Accepting a new operation must not enter BEGIN IMMEDIATE here.
    func testReadOperationAcceptedAndExecutedWhileCaptureOwnsSQLiteWriter() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),router = f.router!,pid = project["id"] as! String
        let source = f.workspace.appendingPathComponent("capture-original.txt"),bytes = Data("Original bytes during capture".utf8)
        try bytes.write(to:source)
        let attachment = try data(f.call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":source.path]))
        let installation = "operation-capture-reader"
        let session = try data(f.call("session_register",["project_id":pid,"label":"Capture reader","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path]))
        let worker = Caller(role:"worker",installation:installation,projectIDs:[pid],sessionID:session["id"] as? String,workspace:f.workspace.path)
        let lane = HeldLane(router);defer {lane.finish()}
        try router.backupWrites.beginCapture()
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),finished = DispatchSemaphore(value:0)
        let blocker = try DatabaseQueue(path:router.root.appendingPathComponent("checklist.sqlite").path)
        DispatchQueue.global().async {
            do {
                try blocker.writeWithoutTransaction {db in
                    try db.beginTransaction(.immediate)
                    entered.signal()
                    _ = release.wait(timeout:.now()+20)
                    try db.rollback()
                }
            } catch {XCTFail("Capture writer: \(error)")}
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        defer {
            release.signal();XCTAssertEqual(finished.wait(timeout:.now()+5),.success)
            router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        }
        let command = uuid(),params: JSON = ["project_id":pid,"attachment_id":attachment["id"]!,"representation":"original","command_id":command]
        let accepted = try f.call("attachment_read",params,command:command,caller:worker)
        let id = try XCTUnwrap(data(accepted)["operation_id"] as? String)
        XCTAssertEqual(accepted["command_outcome"] as? String,"accepted")
        let stagedPath = router.root.appendingPathComponent("backup-write-queue/operation-" + id + ".intent")
        XCTAssertTrue(FileManager.default.fileExists(atPath:stagedPath.path),"Acceptance must be durable without SQLite's writer")
        XCTAssertEqual(try data(f.call("attachment_read",params,command:command,caller:worker))["operation_id"] as? String,id)
        XCTAssertEqual(try read(f,accepted,project:pid,caller:worker)["state"] as? String,"queued")
        lane.finish()
        XCTAssertEqual(try read(f,accepted,project:pid,caller:worker)["state"] as? String,"running")
        XCTAssertNil(try read(f,accepted,project:pid,caller:worker)["result"],"The terminal write waits for capture release")
        release.signal();XCTAssertEqual(finished.wait(timeout:.now()+5),.success)
        // Balance the deferred wait without keeping a second writer alive.
        finished.signal()
        router.observeWriteAdmission { [weak router] in router?.resumeCommandOperations() }
        defer {router.observeWriteAdmission {}}
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        lane.finish()
        let complete = try read(f,accepted,project:pid,caller:worker)
        XCTAssertEqual(complete["state"] as? String,"succeeded")
        let result = try XCTUnwrap((complete["result"] as? JSON)?["data"] as? JSON)
        XCTAssertEqual(result["content_base64"] as? String,bytes.base64EncodedString())
        XCTAssertFalse(FileManager.default.fileExists(atPath:stagedPath.path),"The canonical terminal commit retires the sidecar")
    }

    func testCaptureAdmissionRestartRecoversQueuedIntentAndPreservesCanonicalTerminal() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        func stage(_ router: CommandRouter) throws -> JSON {
            let command = uuid(),id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
            let value: JSON = ["operation_id":id,"command_id":command,"method":"policy_preview","principal":f.owner.principal,
                "digest":ChecklistCore.hash(Data(command.utf8)),"incarnation":router.incarnation,"state":"queued","project_id":pid,"created_at":now(),"updated_at":now()]
            try router.commandOperations.stageAdmission(value,baseHash:nil,root:router.root)
            return value
        }
        let queued = try stage(f.router!),committed = try stage(f.router!)
        let original: JSON = ["data":["canonical":"terminal reply survives a stale sidecar"]]
        try f.router!.dbQueue.write {db in
            var value = committed;value["state"] = "succeeded";value["finished_at"] = now()
            try f.router!.saveOperation(db,value)
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",
                arguments:[f.owner.principal,committed["command_id"] as! String,committed["digest"] as! String,try jsonString(original)])
        }
        try f.reopen()
        let interrupted = try read(f,["data":queued],project:pid)
        XCTAssertEqual(interrupted["state"] as? String,"failed")
        let failure = try XCTUnwrap(interrupted["error"] as? JSON)
        XCTAssertEqual(failure["code"] as? String,"OPERATION_INTERRUPTED")
        XCTAssertEqual((failure["details"] as? JSON)?["command_outcome"] as? String,"rejected")
        let terminal = try read(f,["data":committed],project:pid)
        XCTAssertEqual(terminal["state"] as? String,"succeeded")
        XCTAssertEqual(try jsonString(terminal["result"]!),try jsonString(original))
        for value in [queued,committed] {
            let id = value["operation_id"] as! String
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backup-write-queue/operation-" + id + ".intent").path))
        }
    }

    func testMalformedStagedIdentityIsRefusedEvenWhenCanonicalTerminalExists() throws {
        let f = try StorageFixture(fast:true),command = uuid()
        let id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
        let valid: JSON = ["operation_id":id,"command_id":command,"method":"policy_preview","principal":f.owner.principal,
            "digest":ChecklistCore.hash(Data(command.utf8)),"incarnation":f.router!.incarnation,"state":"succeeded","created_at":now(),"updated_at":now(),"finished_at":now()]
        try f.router!.dbQueue.write {try f.router!.saveOperation($0,valid)}
        var malformed = valid;malformed["state"] = "queued";malformed["principal"] = "foreign-principal"
        try f.router!.commandOperations.stageAdmission(malformed,baseHash:nil,root:f.root)
        XCTAssertThrowsError(try f.reopen()) {XCTAssertEqual(($0 as? CoreError)?.code,"RECOVERY_REQUIRED")}
    }

    /// CL-353 F3: the contract lists every operation route the code uses.
    func testContractListsEveryOperationRouteAndReadOperation() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(contentsOf:root.appendingPathComponent("docs/mcp-contract.md"),encoding:.utf8)
        let start = try XCTUnwrap(contract.range(of:"### Long command operations (CL-353)"))
        let rest = contract[start.upperBound...]
        let section = String(rest[..<(rest.range(of:"\n#{2,3} ",options:.regularExpression)?.lowerBound ?? rest.endIndex)])
        func names(after prefix: String,until end: String) throws -> Set<String> {
            let from = try XCTUnwrap(section.range(of:prefix),prefix)
            let tail = section[from.upperBound...]
            let sentence = tail[..<(try XCTUnwrap(tail.range(of:end),end).lowerBound)]
            let regex = try NSRegularExpression(pattern:"`([a-z_]+)`")
            let text = String(sentence)
            return Set(regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).map {String(text[Range($0.range(at:1),in:text)!])})
        }
        XCTAssertEqual(try names(after:"The service always uses this route for ",until:". `project_edit`"),CommandRouter.alwaysOperationMethods)
        XCTAssertEqual(try names(after:"Read operations run exactly as their synchronous reads",until:". A backup capture"),CommandRouter.readOperationMethods)
        let sourceTargets = try names(after:"Evidence preparation uses operation admission for the source-target methods (",until:")")
        XCTAssertEqual(sourceTargets,CommandRouter.sourceTargetMethods)
        for method in CommandRouter.conditionalOperationMethods.sorted() {
            XCTAssertTrue(section.contains("`\(method)`"),"docs/mcp-contract.md must name the conditional operation route \(method)")
        }
    }

    func testLegacyBackupFIFOReservationKeepsItsIntentAndOriginalExecution() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String
        let router = f.router!,command = uuid(),source = f.workspace.appendingPathComponent("legacy-attachment.txt")
        try Data("Original queued bytes".utf8).write(to:source)
        try router.backupWrites.beginCapture()
        defer {router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)}
        let input: JSON = ["command_id":command,"project_id":pid,"task_id":task["id"]!,"path":source.path]
        XCTAssertEqual(try f.call("attachment_add",input,command:command)["command_outcome"] as? String,"queued")
        let lane = HeldLane(router);defer {lane.finish()}
        XCTAssertEqual(try f.call("attachment_add",input,command:command)["command_outcome"] as? String,"queued")
        for method in ["attachment_cleanup_preview","backup_create","task_create"] {
            var other: JSON = ["project_id":pid,"task_id":task["id"]!,"path":source.path,"title":"Conflicting queued UUID"]
            other["command_id"] = command
            XCTAssertThrowsError(try f.call(method,other,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT",method)}
        }
        let drained = expectation(description:"legacy FIFO retains direct execution")
        let signaled = OperationAdmissionSignal()
        router.observeWriteAdmission { [weak router] in
            guard let router,router.writeAdmissionStatus["locked"] as? Bool == false else {return}
            signaled.once {drained.fulfill()}
        }
        router.backupWrites.endCapture(router:router)
        wait(for:[drained],timeout:15)
        router.observeWriteAdmission {}
        let status = try f.call("command_status",["project_id":pid,"command_id":command])["data"] as! JSON
        XCTAssertEqual(status["state"] as? String,"applied")
        XCTAssertNil(status["operation_id"])
        XCTAssertNotNil(((status["result"] as? JSON)?["data"] as? JSON)?["id"])
        XCTAssertEqual(try f.call("attachment_add",input,command:command)["command_id"] as? String,command)
        XCTAssertFalse(try router.hasCommandOperation(params:input,caller:f.owner))
    }

}

private final class OperationAdmissionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fulfilled = false
    func once(_ body: () -> Void) {lock.withLock {if !fulfilled {fulfilled = true;body()}}}
}

private final class OperationAdmissionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Result<JSON,Error>] = []
    func append(_ output: Result<JSON,Error>) {lock.withLock {outputs.append(output)}}
    var values: [Result<JSON,Error>] {lock.withLock {outputs}}
}

private final class OperationCaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var failure: Error?
    private var seen: [(id: String,locked: Bool)] = []
    func setCaptureBegan(_ value: Bool) {lock.withLock {began = value}}
    func fail(_ error: Error) {lock.withLock {failure = error}}
    func record(_ id: String,locked: Bool) {lock.withLock {seen.append((id,locked))}}
    var captureBegan: Bool {lock.withLock {began}}
    var error: Error? {lock.withLock {failure}}
    var executions: [(id: String,locked: Bool)] {lock.withLock {seen}}
}
