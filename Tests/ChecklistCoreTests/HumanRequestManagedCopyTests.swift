import XCTest
import GRDB
@testable import ChecklistCore

final class HumanRequestManagedCopyTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    var project: JSON = [:]
    var ticket: JSON = [:]
    let owner = Caller(role:"owner",installation:"managed-answer-tests",projectIDs:[])

    override func setUpWithError() throws {
        // Foundation's temporaryDirectory can ignore TMPDIR. Keep these fixtures
        // in the explicit scratch directory, or within this source copy.
        let fallback = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/managed-answer-fixtures",isDirectory:true)
        let temporary = ProcessInfo.processInfo.environment["CHECKLIST_TEST_TMPDIR"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? fallback
        root = temporary.appendingPathComponent(uuid(),isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        router = try CommandRouter(root:root)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        project = try call("project_create",["name":"Managed answers","root_path":workspace.path])
        ticket = try call("task_create",["project_id":project["id"]!,"title":"Owner files","brief":"Supply exact files"])
    }
    override func tearDownWithError() throws {
        try router?.closeStore(); router = nil
        if let root { try? FileManager.default.removeItem(at:root) }
    }
    @discardableResult func call(_ method: String,_ params: JSON = [:],caller: Caller? = nil) throws -> JSON {
        var p = params
        if !CommandRouter.readMethods.contains(method),p["command_id"] == nil { p["command_id"] = uuid() }
        return try router.handle(method:method,params:p,caller:caller ?? owner)["data"] as! JSON
    }
    func file(_ name: String,_ text: String) throws -> URL {
        let file = root.appendingPathComponent(name); try Data(text.utf8).write(to:file); return file
    }
    func request(questions: [JSON] = []) throws -> JSON {
        try call("human_request_create",["project_id":project["id"]!,"task_id":ticket["id"]!,"questions":questions,
            "file_requests":[["id":"files","prompt":"Select sources","kind":"file","multiple":true]]])
    }
    func answer(_ request: JSON,_ files: [URL],mode: String = "managed") throws -> JSON {
        var hashes: [String:String] = [:]
        for file in files { hashes[file.path] = ChecklistCore.hash(try Data(contentsOf:file)) }
        return ["project_id":project["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"command_id":uuid(),
            "files":[["file_request_id":"files","paths":files.map(\.path),"mode":mode,"path_sha256":hashes]]]
    }
    func records(_ type: String) throws -> [JSON] {
        try router.dbQueue.read { try router.records($0,type:type,project:project["id"] as? String) }
    }
    func assertRefused(_ request: JSON,_ input: JSON,code: String,file: StaticString = #filePath,line: UInt = #line) throws {
        let before = try records("message").count, events = try router.dbQueue.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM events")! }
        XCTAssertThrowsError(try call("human_request_answer",input),file:file,line:line) {
            XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line)
        }
        let current = try records("request").first { $0["id"] as? String == request["id"] as? String }!
        XCTAssertEqual(current["state"] as? String,"pending",file:file,line:line)
        XCTAssertTrue((current["responses"] as! [JSON]).isEmpty,file:file,line:line)
        XCTAssertNil(current["gate_verdict_id"],file:file,line:line)
        XCTAssertTrue(try records("attachment").isEmpty,file:file,line:line)
        XCTAssertTrue(try records("review").isEmpty,file:file,line:line)
        XCTAssertTrue(try records("delivery").isEmpty,file:file,line:line)
        XCTAssertEqual(try records("message").count,before,file:file,line:line)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM events")! },events,file:file,line:line)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[input["command_id"] as! String])! },0,file:file,line:line)
    }

    func testSingleManagedAnswerCommitsExactArtifactAndHumanProvenance() throws {
        let selected = try file("single.txt","single"), request = try request()
        let result = try call("human_request_answer",answer(request,[selected]))
        XCTAssertEqual(result["state"] as? String,"answered")
        let response = (result["responses"] as! [JSON])[0]
        XCTAssertEqual(response["origin"] as? String,"human_ui")
        let refs = ((response["files"] as! [JSON])[0])["artifact_refs"] as! [JSON]
        let attachments = try records("attachment")
        XCTAssertEqual(attachments.count,1); XCTAssertEqual(refs.count,1)
        XCTAssertEqual(attachments[0]["id"] as? String,refs[0]["artifact_id"] as? String)
        XCTAssertEqual(attachments[0]["task_id"] as? String,ticket["id"] as? String)
        XCTAssertEqual(attachments[0]["sha256"] as? String,ChecklistCore.hash(Data("single".utf8)))
        XCTAssertEqual(attachments[0]["sha256"] as? String,refs[0]["sha256"] as? String)
        XCTAssertEqual(attachments[0]["mode"] as? String,"managed")
        XCTAssertEqual(try Data(contentsOf:router.managedURL(attachments[0]["path"] as! String,family:"objects")),Data("single".utf8))
        XCTAssertNotEqual(attachments[0]["path"] as? String,selected.path)
    }

    func testMultiFileAnswerCommitsOneImportAndReceiptPerSelection() throws {
        let files = try [file("first.txt","one"),file("second.txt","two"),file("third.txt","three")], request = try request()
        let result = try call("human_request_answer",answer(request,files))
        let refs = (((result["responses"] as! [JSON])[0]["files"] as! [JSON])[0])["artifact_refs"] as! [JSON]
        let attachments = try records("attachment"), jobs = try records("storage_job").filter { $0["kind"] as? String == "attachment_import" }
        XCTAssertEqual(refs.count,3); XCTAssertEqual(Set(refs.compactMap {$0["artifact_id"] as? String}).count,3)
        XCTAssertEqual(attachments.count,3); XCTAssertEqual(jobs.count,3)
        for (index,ref) in refs.enumerated() {
            XCTAssertEqual(ref["sha256"] as? String,ChecklistCore.hash(try Data(contentsOf:files[index])))
        }
        for job in jobs {
            let receipt = try router.dbQueue.read { try router.managedImportReceipt($0,principal:owner.principal,command:job["parent_command_id"] as! String,digest:job["intent_digest"] as! String) }
            XCTAssertEqual((receipt?["data"] as? JSON)?["id"] as? String,job["attachment_id"] as? String)
            XCTAssertTrue(["committed","settled"].contains(job["state"] as! String))
        }
    }

    func testChangedFileRejectsWholeAnswerWithoutDomainSideEffects() throws {
        let files = try [file("first.txt","one"),file("changed.txt","old")], request = try request(), input = try answer(request,files)
        let foreign = try unrelatedImport()
        try Data("changed".utf8).write(to:files[1])
        try assertRefused(request,input,code:"SOURCE_CHANGED")
        try assertOnlyOwnStagesRemoved(input,request:request,foreign:foreign)
    }

    func testMissingFileRejectsWholeAnswerWithoutDomainSideEffects() throws {
        let files = try [file("first.txt","one"),file("missing.txt","old")], request = try request(), input = try answer(request,files)
        let foreign = try unrelatedImport()
        try FileManager.default.removeItem(at:files[1])
        try assertRefused(request,input,code:"FILE_ACCESS_REQUIRED")
        try assertOnlyOwnStagesRemoved(input,request:request,foreign:foreign)
    }

    func unrelatedImport() throws -> ManagedAttachmentPreparation {
        let source = try file("unrelated.txt","unrelated")
        return try router.prepareManagedAttachmentImport(method:"attachment_add",params:["command_id":uuid(),"project_id":project["id"]!,"task_id":ticket["id"]!,"path":source.path],caller:owner,access:router.managedImportAccessOutsideWriter())!
    }
    func assertOnlyOwnStagesRemoved(_ input: JSON,request: JSON,foreign: ManagedAttachmentPreparation) throws {
        let files = try StorageObjectFiles(root:router.root)
        for object in try router.managedImportObjects(foreign.job) {
            XCTAssertTrue(try router.managedImportExists(files,object["stage"] as! String))
            XCTAssertTrue(try router.managedImportExists(files,object["final"] as! String))
        }
        let selection = (input["files"] as! [JSON])[0]
        let first = try router.humanAnswerImportParams(input,request:request,file:selection,path:strings(selection,"paths")[0])
        let key = try router.managedImportKey(principal:owner.principal,command:first["command_id"] as! String)
        let job = try router.dbQueue.read { try router.record($0,key,type:"storage_job") }
        XCTAssertEqual(job["state"] as? String,"finalized")
        for object in try router.managedImportObjects(job) {
            XCTAssertFalse(try router.managedImportExists(files,object["stage"] as! String))
            XCTAssertTrue(try router.managedImportExists(files,object["final"] as! String))
        }
    }

    func testUnreadableFileRefusesWholeAnswerAndKeepsOtherStaging() throws {
        let files = try [file("first.txt","one"),file("unreadable.txt","secret")], request = try request(), input = try answer(request,files)
        let foreign = try unrelatedImport()
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:files[1].path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:files[1].path) }
        try assertRefused(request,input,code:"FILE_ACCESS_REQUIRED")
        try assertOnlyOwnStagesRemoved(input,request:request,foreign:foreign)
    }

    func testPendingImportRetryUsesFinalizedBytesAndOriginalChildIDs() throws {
        let files = try [file("first.txt","one"),file("second.txt","two")], request = try request(), input = try answer(request,files)
        try FileManager.default.removeItem(at:files[1])
        try assertRefused(request,input,code:"FILE_ACCESS_REQUIRED")
        let pending = try records("storage_job").first {$0["state"] as? String == "finalized"}!
        try FileManager.default.removeItem(at:files[0])
        try Data("two".utf8).write(to:files[1])
        let result = try call("human_request_answer",input)
        XCTAssertEqual(result["state"] as? String,"answered")
        XCTAssertEqual(try records("attachment").count,2)
        XCTAssertTrue(try records("attachment").contains {$0["id"] as? String == pending["attachment_id"] as? String})
    }

    func testChangedIntentCannotReusePendingAnswerUUID() throws {
        let files = try [file("first.txt","one"),file("second.txt","two")], request = try request(), input = try answer(request,files)
        try FileManager.default.removeItem(at:files[1])
        try assertRefused(request,input,code:"FILE_ACCESS_REQUIRED")
        var changed = input; changed["explanation"] = "different intent"
        try assertRefused(request,changed,code:"IDEMPOTENCY_CONFLICT")
        var other: JSON = ["project_id":project["id"]!,"task_id":ticket["id"]!,"command_id":input["command_id"]!,"path":files[0].path]
        other["mode"] = "managed"
        XCTAssertThrowsError(try call("attachment_add",other)) { XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT") }
    }

    func commitPrepared(_ input: JSON,_ prepared: PreparedHumanRequestFiles) throws -> JSON {
        try ArchiveStorageGate.withExclusive(root:router.root) { _ in
            try router.dbQueue.writeWithoutTransaction { db in
                var preparation = CommandPreparation(); preparation.humanRequestFiles = prepared
                router.commandPreparation = preparation
                defer { router.commandPreparation = .init() }
                var result: JSON = [:]
                try router.withValidatedDomainTransaction(db) {
                    result = try router.requestWrite(db,input,owner,"human_request_answer")
                    return .commit
                }
                return result
            }
        }
    }

    func testPreparedAnswerCommitsAfterReadPermissionRemovedWithoutRehashingInWriter() throws {
        let source = try file("prepared.txt","prepared"), request = try request(), input = try answer(request,[source])
        let prepared = try router.prepareHumanRequestAnswerFiles(params:input,caller:owner)!
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:source.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.path)
        }
        XCTAssertEqual(try commitPrepared(input,prepared)["state"] as? String,"answered")
        XCTAssertEqual(try records("attachment").count,1)
    }

    func testSourceIdentityChangeAfterPreparationRefusesBeforeResponse() throws {
        let source = try file("prepared.txt","prepared"), request = try request(), input = try answer(request,[source])
        let prepared = try router.prepareHumanRequestAnswerFiles(params:input,caller:owner)!
        try Data("changed source".utf8).write(to:source)
        XCTAssertThrowsError(try commitPrepared(input,prepared)) { XCTAssertEqual(($0 as? CoreError)?.code,"SOURCE_CHANGED") }
        XCTAssertTrue(try records("attachment").isEmpty)
        XCTAssertTrue((try records("request")[0]["responses"] as! [JSON]).isEmpty)
        XCTAssertTrue(try records("message").isEmpty)
    }

    func testFinalIdentityChangeAfterPreparationRefusesBeforeResponse() throws {
        let source = try file("prepared.txt","prepared"), request = try request(), input = try answer(request,[source])
        let prepared = try router.prepareHumanRequestAnswerFiles(params:input,caller:owner)!
        let managed = try router.managedURL(prepared.imports.values.first!.prepared.attachment["path"] as! String,family:"objects")
        try Data("replaced".utf8).write(to:managed)
        XCTAssertThrowsError(try commitPrepared(input,prepared)) { XCTAssertEqual(($0 as? CoreError)?.code,"MANAGED_IMPORT_RECOVERY_REQUIRED") }
        XCTAssertTrue(try records("attachment").isEmpty)
        XCTAssertTrue((try records("request")[0]["responses"] as! [JSON]).isEmpty)
        XCTAssertTrue(try records("message").isEmpty)
    }

    func testLateAnswerReceiptFailureRollsBackAllAttachmentsResponseAndNotification() throws {
        let files = try [file("first.txt","one"),file("second.txt","two")], request = try request(), input = try answer(request,files)
        try router.dbQueue.write { db in
            try db.execute(sql:"CREATE TEMP TRIGGER refuse_answer_receipt BEFORE INSERT ON commands WHEN NEW.command_id='\(input["command_id"] as! String)' BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END")
        }
        try assertRefused(request,input,code:"OUTCOME_UNKNOWN")
        XCTAssertEqual(try records("storage_job").filter {$0["state"] as? String == "finalized"}.count,2)
    }

    func gateFixture() throws -> (JSON,JSON) {
        project = try call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"reason":"Test owner gate", "policy":["required_gates":["human_approval"],"routing_preset":"shared"]])
        ticket = try call("task_edit",["project_id":project["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!,"patch":["readiness":"ready"]])
        let attempt = try call("work_claim",["project_id":project["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!])
        let target = try call("attachment_add",["project_id":project["id"]!,"task_id":ticket["id"]!,"path":file("target.txt","target").path])
        _ = try call("work_submit",["project_id":project["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":target["id"]!,"sha256":target["sha256"]!]]]])
        let request = try call("human_request_create",["project_id":project["id"]!,"task_id":ticket["id"]!,"target_attachment_id":target["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Approve target?"]],"file_requests":[["id":"files","prompt":"Supply result","kind":"file","multiple":true]]])
        return (request,target)
    }

    func testGateDirectionFenceRunsBeforeAnyManagedAnswerImport() throws {
        let (request,target) = try gateFixture(), source = try file("answer.txt","answer")
        var input = try answer(request,[source]); input["target_sha256"] = target["sha256"]!
        input["answers"] = [["question_id":"approve","result":"approved"]]
        let jobs = try records("storage_job").count
        XCTAssertThrowsError(try call("human_request_answer",input)) { XCTAssertEqual(($0 as? CoreError)?.code,"DIRECTION_CURSOR_REQUIRED") }
        XCTAssertEqual(try records("storage_job").count,jobs)
        XCTAssertEqual(try records("attachment").count,1)
        XCTAssertTrue((try records("request")[0]["responses"] as! [JSON]).isEmpty)
        XCTAssertTrue(try records("review").isEmpty)
    }

    func testGateDirectionIsRecheckedAfterPreparationBeforeAnyImportCommit() throws {
        let (request,target) = try gateFixture(), source = try file("answer.txt","answer")
        let context = try call("task_context",["project_id":project["id"]!,"task_id":ticket["id"]!])
        var input = try answer(request,[source]); input["target_sha256"] = target["sha256"]!
        input["answers"] = [["question_id":"approve","result":"approved"]]
        input["expected_task_revision"] = (context["task"] as! JSON)["revision"]!; input["direction_cursor"] = context["direction_cursor"]!
        let prepared = try router.prepareHumanRequestAnswerFiles(params:input,caller:owner)!
        _ = try call("message_send",["project_id":project["id"]!,"task_id":ticket["id"]!,"body":"New owner direction","requires_action":true])
        XCTAssertThrowsError(try commitPrepared(input,prepared)) { XCTAssertEqual(($0 as? CoreError)?.code,"USER_DIRECTION_PENDING") }
        XCTAssertEqual(try records("attachment").count,1)
        XCTAssertTrue((try records("request")[0]["responses"] as! [JSON]).isEmpty)
        XCTAssertTrue(try records("review").isEmpty)
        XCTAssertEqual(try records("review_request")[0]["state"] as? String,"human_pending")
    }

    func testWorkerCannotPrepareOrAnswerWithOwnerProvenance() throws {
        let source = try file("owner-only.txt","owner"), request = try request(), input = try answer(request,[source]), sid = uuid()
        _ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"worker"])
        let worker = Caller(role:"worker",installation:"worker",projectIDs:[project["id"] as! String],sessionID:sid,workspace:project["root_path"] as? String)
        XCTAssertThrowsError(try call("human_request_answer",input,caller:worker)) { XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN") }
        XCTAssertThrowsError(try router.prepareHumanRequestAnswerFiles(params:input,caller:worker)) { XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED") }
        XCTAssertTrue(try records("storage_job").isEmpty); XCTAssertTrue(try records("attachment").isEmpty)
    }

    func testMultipleFileRequestsKeepDistinctDeterministicImportIdentities() throws {
        let source = try file("shared-selection.txt","same bytes")
        let request = try call("human_request_create",["project_id":project["id"]!,"task_id":ticket["id"]!,"file_requests":[["id":"a","prompt":"First","kind":"file"],["id":"b","prompt":"Second","kind":"file"]]])
        let input: JSON = ["project_id":project["id"]!,"request_id":request["id"]!,"expected_revision":1,"command_id":uuid(),"files":[["file_request_id":"a","paths":[source.path],"mode":"managed"],["file_request_id":"b","paths":[source.path],"mode":"managed"]]]
        let result = try call("human_request_answer",input)
        let files = ((result["responses"] as! [JSON])[0])["files"] as! [JSON]
        let refs = files.flatMap { $0["artifact_refs"] as! [JSON] }
        XCTAssertEqual(Set(refs.compactMap {$0["artifact_id"] as? String}).count,2)
        XCTAssertEqual(try records("attachment").count,2)
        XCTAssertEqual(try records("storage_job").filter {$0["kind"] as? String == "attachment_import"}.count,2)
        XCTAssertEqual(try router.handle(method:"human_request_answer",params:input,caller:owner)["replayed"] as? Bool,true)
    }

    func testPlatformAliasFixStillRefusesDescendantAndFinalSymlinks() throws {
        let destination = root.appendingPathComponent("actual/child",isDirectory:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:destination.deletingLastPathComponent())
        XCTAssertThrowsError(try StorageObjectFiles(root:link))
        XCTAssertThrowsError(try StorageObjectFiles(root:link.appendingPathComponent("child")))
        XCTAssertThrowsError(try CommandRouter(root:link))
        XCTAssertNoThrow(try StorageObjectFiles(root:root))
    }

    func testRetryOfSameAnswerAfterLostReplyDoesNotReadSourcesOrDuplicateImports() throws {
        let files = try [file("first.txt","one"),file("second.txt","two")], request = try request(), input = try answer(request,files)
        let original = try call("human_request_answer",input)
        for file in files { try FileManager.default.removeItem(at:file) }
        let replay = try router.handle(method:"human_request_answer",params:input,caller:owner)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try jsonString((replay["data"] as! JSON)["responses"]!),try jsonString(original["responses"]!))
        XCTAssertEqual(try records("attachment").count,2)
        XCTAssertEqual(try records("storage_job").filter {$0["kind"] as? String == "attachment_import"}.count,2)
        XCTAssertEqual(try records("message").count,1)
    }

    func testIncompleteAnswerImportsNothingAndRemainsPending() throws {
        let selected = try file("pending.txt","pending"), request = try request(questions:[["id":"check","type":"check","prompt":"Did you run it?"]])
        var input = try answer(request,[selected]); input["answers"] = [["question_id":"check","result":"not_checked"]]
        XCTAssertThrowsError(try call("human_request_answer",input)) { XCTAssertEqual(($0 as? CoreError)?.code,"ANSWER_INCOMPLETE") }
        let stored = try records("request").first!
        XCTAssertEqual(stored["state"] as? String,"pending")
        XCTAssertTrue((stored["responses"] as! [JSON]).isEmpty)
        XCTAssertTrue(try records("message").isEmpty)
        XCTAssertTrue(try records("attachment").isEmpty)
        XCTAssertTrue(try records("storage_job").isEmpty)
    }

    func testReferenceAnswerRecordsOriginalWithoutManagedImport() throws {
        let selected = try file("reference.txt","reference"), request = try request()
        let result = try call("human_request_answer",answer(request,[selected],mode:"reference"))
        let file = (((result["responses"] as! [JSON])[0])["files"] as! [JSON])[0]
        XCTAssertEqual(result["state"] as? String,"answered")
        XCTAssertEqual(file["mode"] as? String,"reference"); XCTAssertEqual(file["paths"] as? [String],[selected.path])
        XCTAssertEqual((file["path_sha256"] as? [String:String])?[selected.path],ChecklistCore.hash(Data("reference".utf8)))
        XCTAssertNil(file["artifact_refs"])
        XCTAssertTrue(try records("attachment").isEmpty); XCTAssertTrue(try records("storage_job").isEmpty)
    }

}
