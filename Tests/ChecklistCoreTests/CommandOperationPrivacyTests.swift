import XCTest
import Foundation
import Dispatch
import GRDB
@testable import ChecklistCore

final class CommandOperationPrivacyTests: XCTestCase {
    private func otherProject(_ f: StorageFixture) throws -> JSON {
        let workspace = f.base.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try XCTUnwrap(f.call("project_create",["name":"Second project","key_prefix":"SP","root_path":workspace.path])["data"] as? JSON)
        _ = try f.call("epic_create",["project_id":project["id"]!,"name":"Second project tickets"])
        return project
    }

    private func preparePurge(_ f: StorageFixture,task: JSON) throws -> JSON {
        let project = try XCTUnwrap(task["project_id"] as? String)
        let current = try XCTUnwrap(f.call("task_get",["project_id":project,"task_id":task["id"]!])["data"] as? JSON)
        let trashed = try XCTUnwrap(f.call("task_archive",["project_id":project,"task_id":task["id"]!,
            "expected_revision":current["revision"]!,"action":"trash"])["data"] as? JSON)
        var input: JSON = ["project_id":project,"task_id":task["id"]!,"expected_revision":trashed["revision"]!,"command_id":uuid()]
        let preview = try XCTUnwrap(f.router!.executeBackupQueuedWrite(method:"task_purge_preview",params:input,caller:f.owner)["data"] as? JSON)
        input["preview_digest"] = preview["digest"]
        input["command_id"] = uuid()
        return input
    }

    private func assertExpired(_ f: StorageFixture,_ selector: JSON,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try f.call("operation_get",selector),file:file,line:line) {
            XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED",file:file,line:line)
        }
    }

    func testCL520OwnerPreviewDoesNotSaveForeignManagedTextAcrossPurge() throws {
        let media = try MediaRoundTests.Fixture(),f = media.storage,router = media.router
        let sourceProject = try otherProject(f),task = try f.task(sourceProject)
        let text = "Private contents of the purged attachment."
        let source = f.base.appendingPathComponent("purge-source.txt")
        try Data(text.utf8).write(to:source)
        let attachment = try XCTUnwrap(f.call("attachment_add",["project_id":sourceProject["id"]!,"task_id":task["id"]!,"path":source.path])["data"] as? JSON)
        let path = try XCTUnwrap(attachment["path"] as? String)
        XCTAssertTrue(path.hasPrefix(f.root.path + "/objects/"))
        let purge = try preparePurge(f,task:task)
        let round = try media.round(media.type(MediaRoundTests().schema()))
        let lane = DispatchQueue(label:"owner-selected-file-purge")
        router.configureCommandOperations(on:lane)
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        router.mediaIntakePreviewPreparationProbe = {prepared in
            XCTAssertTrue(prepared.encodedResult.contains(text),"Pause after reading and projecting the managed text")
            entered.signal()
            guard release.wait(timeout:.now() + 20) == .success else {throw CoreError("TEST_TIMEOUT","Preview did not resume.")}
        }
        defer {
            release.signal();lane.sync {}
            router.mediaIntakePreviewPreparationProbe = nil
        }
        let command = uuid()
        let input: JSON = ["project_id":media.project,"round_id":round["id"]!,"sources":[["path":path]]]
        let accepted = try XCTUnwrap(f.call("media_intake_preview",input,command:command)["data"] as? JSON)
        let selector: JSON = ["project_id":media.project,"operation_id":try XCTUnwrap(accepted["operation_id"])]
        XCTAssertEqual(entered.wait(timeout:.now() + 10),.success)
        XCTAssertEqual((try f.call("operation_get",selector)["data"] as? JSON)?["state"] as? String,"running")
        let removed = try router.executeBackupQueuedWrite(method:"task_purge",params:purge,caller:f.owner)
        XCTAssertEqual(((removed["data"] as? JSON)?["task"] as? JSON)?["purged"] as? Bool,true)
        release.signal();lane.sync {}
        assertExpired(f,selector)
        let statusInput: JSON = ["project_id":media.project,"command_id":command]
        XCTAssertThrowsError(try f.call("command_status",statusInput)) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
        for family in ["media_intake","media_intake_row","media_intake_plan"] {XCTAssertTrue(try media.rows(family).isEmpty,family)}
        try router.dbQueue.read {db in
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))
            let id = try XCTUnwrap(selector["operation_id"] as? String)
            let operation = try XCTUnwrap(router.operationRecord(db,id:id))
            XCTAssertEqual(operation["state"] as? String,"failed")
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",
                arguments:[f.owner.principal,try XCTUnwrap(operation["error_result_command_id"] as? String)]),CommandRouter.prunedResult)
        }
        XCTAssertEqual((try f.call("media_intake_preview",input,command:command)["data"] as? JSON)?["operation_id"] as? String,accepted["operation_id"] as? String)
    }

    func testCL520ManualPurgeKeepsUnrelatedErrorsAndOversizedReplyAtPublication() throws {
        let media = try MediaRoundTests.Fixture(),f = media.storage,router = media.router
        let first = try router.dbQueue.read {try router.record($0,media.project,type:"project")}
        let second = try otherProject(f),other = try XCTUnwrap(second["id"] as? String)
        let task = try f.task(first),purge = try preparePurge(f,task:task)
        let sources: [JSON] = try (0..<10).map {index in
            let source = f.base.appendingPathComponent("large-media-\(index).txt")
            try Data(("Take \(index): " + String(repeating:"x",count:230_000)).utf8).write(to:source)
            return ["path":source.path]
        }
        func confirmation(project: String) throws -> JSON {
            let schema = MediaRoundTests().schema()
            let type = try media.call("media_type_create",["project_id":project,"title":"Large intake","schema":schema])
            let draft = try media.call("media_type_get",["project_id":project,"type_id":type["id"]!])
            let adopted = try media.call("media_type_adopt",["project_id":project,"type_id":draft["id"]!,"type_revision_id":draft["draft_revision_id"]!,
                "expected_revision":draft["revision"]!,"observed_type_token":draft["observed_type_token"]!])
            let round = try media.call("media_round_create",["project_id":project,"type_id":adopted["id"]!,"title":"Large intake round"])
            let intake = try media.call("media_intake_preview",["project_id":project,"round_id":round["id"]!,"sources":sources])
            let plan = try XCTUnwrap(intake["plan"] as? JSON)
            return ["project_id":project,"intake_id":intake["id"]!,"expected_revision":intake["revision"]!,
                "plan_id":plan["id"]!,"plan_digest":plan["digest"]!]
        }
        let aConfirm = try confirmation(project:media.project),bConfirm = try confirmation(project:other)
        let lane = DispatchQueue(label:"operation-receipt-projects")
        router.configureCommandOperations(on:lane)
        func start(_ method: String,_ params: JSON,command: String = uuid()) throws -> JSON {
            let accepted = try XCTUnwrap(f.call(method,params,command:command)["data"] as? JSON)
            return ["project_id":try XCTUnwrap(params["project_id"]),"operation_id":try XCTUnwrap(accepted["operation_id"])]
        }
        func status(_ selector: JSON) throws -> JSON {try XCTUnwrap(f.call("operation_get",selector)["data"] as? JSON)}
        let errorA = try start("attachment_cleanup_preview",["project_id":media.project,"task_id":uuid()])
        let errorB = try start("attachment_cleanup_preview",["project_id":other,"task_id":uuid()])
        let successA = try start("media_intake_confirm",aConfirm)
        lane.sync {}
        XCTAssertEqual(try status(errorA)["state"] as? String,"failed")
        let bError = try XCTUnwrap(status(errorB)["error"] as? JSON)
        XCTAssertEqual(try status(errorB)["state"] as? String,"failed")
        XCTAssertEqual(try status(successA)["state"] as? String,"succeeded")
        XCTAssertGreaterThan(try jsonString(status(successA)["result"]!).utf8.count,TicketCleanupInventory.rowByteLimit)

        let command = uuid(),id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        router.commandOperations.publicationProbe = {operation in
            guard operation == id else {return}
            entered.signal();XCTAssertEqual(release.wait(timeout:.now() + 20),.success)
        }
        defer {release.signal();lane.sync {};router.commandOperations.publicationProbe = nil}
        let successB = try start("media_intake_confirm",bConfirm,command:command)
        XCTAssertEqual(entered.wait(timeout:.now() + 10),.success)
        XCTAssertEqual(try status(successB)["state"] as? String,"running")
        let storedB = try router.dbQueue.read {db in
            try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))
        }
        XCTAssertGreaterThan(storedB.utf8.count,TicketCleanupInventory.rowByteLimit)
        let removed = try router.executeBackupQueuedWrite(method:"task_purge",params:purge,caller:f.owner)
        XCTAssertEqual(((removed["data"] as? JSON)?["task"] as? JSON)?["purged"] as? Bool,true)
        release.signal();lane.sync {}
        assertExpired(f,errorA);assertExpired(f,successA)
        XCTAssertEqual(try jsonString(status(errorB)["error"]!),try jsonString(bError))
        let result = try status(successB)
        XCTAssertEqual(result["state"] as? String,"succeeded")
        let reply = try XCTUnwrap(result["result"] as? JSON)
        XCTAssertEqual(try jsonString(reply["data"]!),storedB)
        XCTAssertEqual(reply["command_id"] as? String,command)
    }

    func testLargePreviewReceiptExpiresOnPurgeWithoutBlockingOrReplaying() throws {try previewReceiptExpires(bytes:TicketCleanupInventory.rowByteLimit + 1)}
    func testSmallPreviewWithSourceIDsExpiresWhenImportedTicketIsPurged() throws {try previewReceiptExpires(bytes:100)}
    private func previewReceiptExpires(bytes: Int) throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project)
        let pid = project["id"] as! String,command = uuid(),id = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
        let input: JSON = ["command_id":command,"project_id":pid,"path":f.base.appendingPathComponent("import.json").path,"source_format":"checklist-intermediate","source_namespace":"owned-preview"]
        let digest = ChecklistCore.hash(Data(("import_preview" + (try jsonString(input))).utf8))
        let result: JSON = ["data":["canonical_bundle":["private_body":String(repeating:"x",count:bytes)]]]
        try f.router!.dbQueue.write {db in
            try f.router!.saveOperation(db,["operation_id":id,"command_id":command,"method":"import_preview","principal":f.owner.principal,"project_id":pid,"incarnation":f.router!.incarnation,"digest":digest,"state":"succeeded","created_at":now(),"finished_at":now()])
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[f.owner.principal,command,digest,try jsonString(result)])
        }
        XCTAssertNoThrow(try f.call("operation_get",["project_id":pid,"operation_id":id]))
        let trashed = try f.call("task_archive",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"trash"])["data"] as! JSON
        let preview = try f.call("task_purge_preview",["project_id":pid,"task_id":task["id"]!,"expected_revision":trashed["revision"]!])["data"] as! JSON
        _ = try f.call("task_purge",["project_id":pid,"task_id":task["id"]!,"expected_revision":trashed["revision"]!,"preview_digest":preview["digest"]!])
        XCTAssertThrowsError(try f.call("operation_get",["project_id":pid,"operation_id":id])) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
        try f.router!.dbQueue.read {db in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))
            XCTAssertEqual(row["digest"] as String,digest)
            XCTAssertTrue(CommandRouter.isPrunedResult(jsonObject(row["result"])))
        }
        // A large preview's expiry never frees its original UUID for another command.
        f.router!.configureCommandOperations(on:DispatchQueue(label:"expired-operation-replay"))
        let replay = try f.router!.handle(method:"import_preview",params:input,caller:f.owner)
        XCTAssertEqual((replay["data"] as? JSON)?["operation_id"] as? String,id)
        XCTAssertEqual((replay["data"] as? JSON)?["state"] as? String,"succeeded")
    }

    func testAcceptanceDoesNotWaitForUnrelatedManagedObjectGate() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let held = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),done = DispatchSemaphore(value:0)
        let ownedRoot = f.root
        DispatchQueue.global(qos:.utility).async {
            defer {done.signal()}
            try? ArchiveStorageGate.withExclusive(root:ownedRoot) { _ in
                held.signal();_ = release.wait(timeout:.now() + 10)
            }
        }
        XCTAssertEqual(held.wait(timeout:.now() + 5),.success)
        let lane = DispatchQueue(label:"held-operation-privacy");lane.suspend()
        f.router!.configureCommandOperations(on:lane)
        defer {release.signal();_ = done.wait(timeout:.now()+10);lane.resume();lane.sync {}}
        let reply = try f.call("attachment_cleanup_preview",["project_id":pid,"task_id":uuid()])
        XCTAssertEqual(reply["command_outcome"] as? String,"accepted")
        XCTAssertEqual((reply["data"] as? JSON)?["state"] as? String,"queued")
        // If the journal acquired the managed-object gate, this call could only
        // return after the guard's timeout; the gate must still be held here.
        XCTAssertEqual(done.wait(timeout:.now()),.timedOut)
    }
    func testManagedOperationResultProjectsURLsWithoutPersistingThem() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String
        let file = f.workspace.appendingPathComponent("attachment.txt");try Data("owned managed bytes".utf8).write(to:file)
        let lane = DispatchQueue(label:"managed-operation-projection");lane.suspend()
        f.router!.configureCommandOperations(on:lane)
        let command = uuid(),reply = try f.call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":file.path],command:command)
        lane.resume();lane.sync {}
        let id = (reply["data"] as! JSON)["operation_id"] as! String
        let status = try f.call("operation_get",["project_id":pid,"operation_id":id])["data"] as! JSON
        XCTAssertEqual(status["state"] as? String,"succeeded")
        let output = (status["result"] as? JSON)?["data"] as? JSON
        XCTAssertTrue((output?["path"] as? String)?.hasPrefix(f.root.path + "/objects/") == true)
        try f.router!.dbQueue.read {db in
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command]))
            let stored = jsonObject(raw)["data"] as? JSON
            XCTAssertTrue((stored?["path"] as? String)?.hasPrefix("objects/") == true)
            XCTAssertFalse(raw.contains(f.root.path))
        }
        let original = try f.call("attachment_read",["project_id":pid,"attachment_id":output!["id"]!,"representation":"original"])
        XCTAssertEqual(original["command_outcome"] as? String,"accepted")
        lane.sync {}
        let originalID = (original["data"] as! JSON)["operation_id"] as! String
        let originalStatus = try f.call("operation_get",["project_id":pid,"operation_id":originalID])["data"] as! JSON
        let originalData = (originalStatus["result"] as? JSON)?["data"] as? JSON
        XCTAssertNotNil(originalData?["read_hold_id"])
        XCTAssertNotNil(originalData?["read_hold_expires_at"])
        XCTAssertTrue((originalData?["url"] as? String)?.hasPrefix(f.root.path + "/objects/") == true)
        let originalCommand = original["command_id"] as! String
        try f.router!.dbQueue.read {db in
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,originalCommand]))
            XCTAssertFalse(raw.contains(f.root.path))
        }
    }

    func testCompletedSourceReviewClaimReadRefreshesCredentialsOnlyInReply() throws {
        let fixture = AgentReviewAssessmentTests();try fixture.setUpWithError();defer {try? fixture.tearDownWithError()}
        let (project,_,_,selectors) = try fixture.fixture(source:true),pid = project["id"] as! String
        let lane = DispatchQueue(label:"source-review-claim-operation");lane.suspend()
        fixture.router.configureCommandOperations(on:lane)
        var contextInput = selectors;contextInput["command_id"] = uuid()
        let context = try fixture.router.handle(method:"review_context",params:contextInput,caller:fixture.critic)
        var prepareInput = selectors;prepareInput["command_id"] = uuid()
        let prepared = try fixture.router.handle(method:"review_prepare",params:prepareInput,caller:fixture.critic)
        XCTAssertEqual(context["command_outcome"] as? String,"accepted")
        XCTAssertEqual(prepared["command_outcome"] as? String,"accepted")
        var input = selectors;let command = uuid();input["command_id"] = command
        let accepted = try fixture.router.handle(method:"work_claim",params:input,caller:fixture.critic)
        lane.resume();lane.sync {}
        for read in [context,prepared] {
            let readID = (read["data"] as! JSON)["operation_id"] as! String
            let readStatus = try fixture.router.handle(method:"operation_get",params:["project_id":pid,"operation_id":readID],caller:fixture.critic)["data"] as! JSON
            XCTAssertEqual(readStatus["state"] as? String,"succeeded",String(describing:readStatus["error"]))
            XCTAssertNotNil(((readStatus["result"] as? JSON)?["data"] as? JSON)?["review_contract"])
        }
        let id = (accepted["data"] as! JSON)["operation_id"] as! String
        let status = try fixture.router.handle(method:"operation_get",params:["project_id":pid,"operation_id":id],caller:fixture.critic)["data"] as! JSON
        XCTAssertEqual(status["state"] as? String,"succeeded",String(describing:status["error"]))
        let result = (status["result"] as? JSON)?["data"] as? JSON
        XCTAssertNotNil(result?["claim_token"] as? String)
        try fixture.router.dbQueue.read {db in
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[fixture.critic.principal,command]))
            XCTAssertNil((jsonObject(raw)["data"] as? JSON)?["claim_token"])
            var claim: JSON = ["attempt_id":result?["id"] as Any,"claim_token":result?["claim_token"] as Any,"project_id":pid]
            claim["attempt_id"] = result?["id"];claim["claim_token"] = result?["claim_token"]
            XCTAssertNoThrow(try fixture.router.claimAttempt(db,claim,fixture.critic,pid))
        }
    }

    func testPrivateFailureUsesPurgeGovernedReceiptAndCannotSurviveTicketRemoval() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),pid = project["id"] as! String
        let task = try f.call("task_create",["project_id":pid,"title":"Private failure snapshot"])["data"] as! JSON
        let tid = task["id"] as! String
        var group = try f.call("triage_create",["project_id":pid,"name":"Owned plan"])["data"] as! JSON
        group = try f.call("group_membership",["project_id":pid,"group_id":group["id"]!,"task_id":tid,"expected_revision":group["revision"]!,"action":"add"])["data"] as! JSON
        let lane = DispatchQueue(label:"private-error-operation");lane.suspend()
        f.router!.configureCommandOperations(on:lane)
        let command = uuid()
        let input: JSON = ["command_id":command,"project_id":pid,"triage_id":group["id"]!,"expected_revision":group["revision"]!,"action":"queue","expected_member_revisions":[tid:999999]]
        // Exercise the real domain rejection in the operation boundary; no
        // synthetic private error is inserted by the fixture.
        let reply = try f.router!.acceptCommandOperation(method:"triage_transition",params:input,caller:f.owner)
        lane.resume();lane.sync {}
        let id = (reply["data"] as! JSON)["operation_id"] as! String
        let failure = try f.call("operation_get",["project_id":pid,"operation_id":id])["data"] as! JSON
        XCTAssertEqual(failure["state"] as? String,"failed")
        XCTAssertTrue(try jsonString(failure).contains("Private failure snapshot"))
        try f.router!.dbQueue.read {db in
            let metadata = try XCTUnwrap(f.router!.operationRecord(db,id:id))
            XCTAssertFalse(try jsonString(metadata).contains("Private failure snapshot"))
            XCTAssertNotNil(metadata["error_result_command_id"])
        }
        // Older uncertain failures can still be marked recoverable when a later
        // maintenance pass expires their receipt.
        try f.router!.dbQueue.write {db in
            var value = try XCTUnwrap(f.router!.operationRecord(db,id:id))
            value["recoverable"] = true
            value["outcome_unknown"] = true
            try f.router!.saveOperation(db,value)
        }
        let current = try f.call("task_get",["project_id":pid,"task_id":tid])["data"] as! JSON
        let trashed = try f.call("task_archive",["project_id":pid,"task_id":tid,"expected_revision":current["revision"]!,"action":"trash"])["data"] as! JSON
        let purgeInput: JSON = ["project_id":pid,"task_id":tid,"expected_revision":trashed["revision"]!]
        // Purge is itself operation-capable in the service; execute the owned
        // domain boundary here so this privacy test needs no polling loop.
        var previewInput = purgeInput;previewInput["command_id"] = uuid()
        let preview = try f.router!.executeBackupQueuedWrite(method:"task_purge_preview",params:previewInput,caller:f.owner)["data"] as! JSON
        var commit = purgeInput;commit["command_id"] = uuid();commit["preview_digest"] = preview["digest"]!
        _ = try f.router!.executeBackupQueuedWrite(method:"task_purge",params:commit,caller:f.owner)
        XCTAssertThrowsError(try f.call("operation_get",["project_id":pid,"operation_id":id])) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
        XCTAssertThrowsError(try f.call("triage_transition",input,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"COMMAND_RESULT_EXPIRED")}
        lane.sync {}
        XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.operationRecord($0,id:id)?["state"] as? String},"failed")
    }

    func testInterruptedRetryRetainsHistoricalErrorReferenceThroughSuccess() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String
        let command = uuid(),input: JSON = ["command_id":command,"project_id":pid,"task_id":task["id"]!]
        let lane = DispatchQueue(label:"historical-operation-error")
        f.router!.configureCommandOperations(on:lane)
        let accepted = try f.call("attachment_cleanup_preview",input,command:command)
        lane.sync {}
        let id = (accepted["data"] as! JSON)["operation_id"] as! String
        let errorCommand = CommandRouter.commandOperationID(principal:f.owner.principal,command:"error:" + id)
        try f.router!.dbQueue.write {db in
            var record = try XCTUnwrap(f.router!.operationRecord(db,id:id))
            record["state"] = "running";record["error_result_command_id"] = errorCommand
            try f.router!.saveOperation(db,record)
            try db.execute(sql:"DELETE FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,command])
            let digest = ChecklistCore.hash(Data(("operation-error:" + (record["digest"] as! String)).utf8))
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[f.owner.principal,errorCommand,digest,try jsonString(["error":["code":"OLD_PRIVATE_FAILURE","message":"Historical error"]])])
        }
        try f.reopen()
        let recovered = try f.call("operation_get",["project_id":pid,"operation_id":id])["data"] as! JSON
        XCTAssertEqual((recovered["error"] as? JSON)?["code"] as? String,"OPERATION_INTERRUPTED")
        let retryLane = DispatchQueue(label:"historical-operation-retry");retryLane.suspend()
        f.router!.configureCommandOperations(on:retryLane)
        defer {retryLane.resume();retryLane.sync {}}
        _ = try f.call("attachment_cleanup_preview",input,command:command)
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try f.router!.operationRecord(db,id:id)?["error_result_command_id"] as? String,errorCommand)
        }
        retryLane.resume();retryLane.sync {};retryLane.suspend()
        let result = try f.call("operation_get",["project_id":pid,"operation_id":id])["data"] as! JSON
        XCTAssertEqual(result["state"] as? String,"succeeded")
        XCTAssertNil(result["error"])
        XCTAssertNil(result["error_result_command_id"])
        try f.router!.dbQueue.read {db in
            XCTAssertEqual(try f.router!.operationRecord(db,id:id)?["error_result_command_id"] as? String,errorCommand)
        }
        let trashed = try f.call("task_archive",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"trash"])["data"] as! JSON
        var purge: JSON = ["command_id":uuid(),"project_id":pid,"task_id":task["id"]!,"expected_revision":trashed["revision"]!]
        let preview = try f.router!.executeBackupQueuedWrite(method:"task_purge_preview",params:purge,caller:f.owner)["data"] as! JSON
        purge["command_id"] = uuid();purge["preview_digest"] = preview["digest"]!
        _ = try f.router!.executeBackupQueuedWrite(method:"task_purge",params:purge,caller:f.owner)
        try f.router!.dbQueue.read {db in
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,errorCommand]))
            XCTAssertTrue(CommandRouter.isPrunedResult(jsonObject(raw)),"Error snapshots without ticket IDs still expire after retry success")
        }
    }

}
