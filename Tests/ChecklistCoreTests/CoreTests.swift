import ChecklistTestSupport
import XCTest
import GRDB
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ChecklistCore

final class CoreTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"test-owner",projectIDs:[])
    /// CL-125: batch fixtures that keep tickets through claims prepare from an orchestrated Triage (rule 6).
    var orchestrateBatchTriages = false
    override func setUpWithError() throws {
        // macOS /var temporary paths traverse a symlink rejected by storage admission.
        let qualificationRoot = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ChecklistQualification/CL-20", isDirectory: true)
        try FileManager.default.createDirectory(at: qualificationRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = qualificationRoot.appendingPathComponent("CoreTests-" + UUID().uuidString, isDirectory: true)
        router = try TestStore.router(root: directory)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ p: JSON = [:],_ caller: Caller? = nil,_ command: String? = nil) throws -> JSON {
        var p = p
        if method == "work_submit" { p = try fixtureAcceptanceEvidence(router,input:p) }
        if method == "batch_submit",let members = p["members"] as? [JSON] { p["members"] = try members.map {try fixtureAcceptanceEvidence(router,input:$0)} }
        // Supply explicit synthetic review evidence for legacy fixtures exercising other guards.
        // Assessment-negative tests use their own raw router calls instead of this convenience.
        if method == "review_record" {p = try addingSyntheticReviewEvidence(p,actor:caller ?? owner)}
        if method == "batch_review_record",let members = p["members"] as? [JSON] {p["members"] = try members.map {try addingSyntheticReviewEvidence($0,actor:caller ?? owner)}}
        if !CommandRouter.readMethods.contains(method) { p["command_id"] = command ?? UUID().uuidString }
        return try router.handle(method:method,params:(caller?.role == "assistant" ? p : try fixtureTaskInput(router,method:method,input:p)),caller:caller ?? owner)["data"] as! JSON
    }
    func addingSyntheticReviewEvidence(_ input: JSON,actor: Caller) throws -> JSON {
        var p = input
        guard p["verdict"] as? String == "pass",p["review_assessment"] == nil,let aid = p["attempt_id"] as? String,let attempt = try? router.dbQueue.read({try router.record($0,aid,type:"attempt")}),let tid = attempt["task_id"] as? String,let mid = attempt["manifest_id"] as? String else {return p}
        let task = try router.dbQueue.read {try router.record($0,tid,type:"task")},manifest = try router.dbQueue.read {try router.record($0,mid,type:"manifest")}
        let file = URL(fileURLWithPath:actor.workspace ?? directory.path).appendingPathComponent("review-fixture-"+UUID().uuidString+".md")
        try Data("Synthetic reviewer report for the guard exercised by this test.".utf8).write(to:file)
        let artifact = try call("attachment_add",["project_id":attempt["project_id"]!,"task_id":tid,"path":file.path],actor)
        p["review_assessment"] = try fixtureReviewAssessment(router,task:task,manifest:manifest,artifact:artifact)
        return p
    }
    var fullAssistantPermissions: [String:Bool] { ["read":true,"create_drafts_on_request":true,"post_notes_on_request":true,"receive_messages":true,"receive_notifications":true] }
    func qualifySyntheticAssistant(projectID: String,sessionID: String,profileID: String) throws {
        // Synthetic adapter attestation fixture. Public owner payloads cannot set these verified fields.
        try router.dbQueue.write { db in
            let hostRef = "synthetic-host:"+profileID
            var profile = try router.record(db,profileID,type:"profile");profile["identity_source"] = "host";profile["host_identity_verified"] = true;profile["host_identity_ref"] = hostRef;profile["kind"] = "personal_assistant";try router.save(db,profile,type:"profile")
            var session = try router.scoped(db,sessionID,projectID,type:"session");session["host_identity_verified"] = true;session["host_identity_ref"] = hostRef;session["adapter_registry_id"] = "codex.dot";try router.save(db,session,type:"session")
        }
    }
    func project(_ name: String = "Test",_ prefix: String = "T") throws -> JSON { try call("project_create",["name":name,"key_prefix":prefix]) }
    func task(_ project: JSON,_ title: String = "Fix input") throws -> JSON { try call("task_create",["project_id":project["id"]!,"title":title,"brief":"Input responds correctly"]) }
    func ready(_ p: JSON,_ t: JSON) throws -> JSON { try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["readiness":"ready"]]) }
    func observedGateAnswer(_ input: JSON, task: JSON) throws -> JSON {
        let context = try call("task_context",["project_id":input["project_id"]!,"task_id":task["id"]!])
        var input = input
        input["direction_cursor"] = context["direction_cursor"]!
        input["expected_task_revision"] = (context["task"] as! JSON)["revision"]!
        return input
    }
    func assertCode(_ code: String,_ block: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) { XCTAssertThrowsError(try block(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line) } }
    func testProjectIsolationRevisionAndReadiness() throws {
        let a = try project("A"),b = try project("B"); let ta = try task(a),tb = try task(b)
        XCTAssertEqual(ta["key"] as? String,tb["key"] as? String)
        assertCode("NOT_FOUND") { _ = try self.call("task_get",["project_id":a["id"]!,"task_id":tb["id"]!]) }
        assertCode("NOT_READY") { _ = try self.call("work_claim",["project_id":a["id"]!,"task_id":ta["id"]!,"expected_revision":ta["revision"]!]) }
        _ = try ready(a,ta)
        assertCode("REVISION_CONFLICT") { _ = try self.call("task_edit",["project_id":a["id"]!,"task_id":ta["id"]!,"expected_revision":1,"patch":["title":"stale"]]) }
    }
    func testIdempotencyAndLostClaimResponseRecovery() throws {
        let p = try project(); let t = try ready(p,task(p)); let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"implementation"]; let command = UUID().uuidString
        let first = try call("work_claim",input,nil,command); let replay = try call("work_claim",input,nil,command)
        XCTAssertEqual(first["id"] as? String,replay["id"] as? String); XCTAssertNotNil(replay["claim_token"])
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint",["project_id":p["id"]!,"attempt_id":first["id"]!,"claim_token":first["claim_token"]!,"progress":"old token"]) }
        _ = try call("work_checkpoint",["project_id":p["id"]!,"attempt_id":replay["id"]!,"claim_token":replay["claim_token"]!,"progress":"Recovered after lost response"])
        assertCode("CLAIM_CONFLICT") { _ = try self.call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":3]) }
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":99],nil,command) }
    }
    func testAssistantCannotWorkOrImpersonateHuman() throws {
        let p = try project();let t = try task(p)
        // A named session needs its registered record (CL-81); the grants under test stay on the caller.
        _ = try call("session_register",["project_id":p["id"]!,"session_id":"assistant-session","role":"assistant","provider":"codex","assistant_grants":[p["id"] as! String:fullAssistantPermissions]])
        let c = Caller(role:"assistant",installation:"dot",projectIDs:[p["id"] as! String],sessionID:"assistant-session",assistantGrants:[p["id"] as! String:fullAssistantPermissions])
        assertCode("FORBIDDEN") { _ = try self.call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":1],c) }
        assertCode("INVALID_INPUT") { _ = try self.call("service_info",["owner":true],c) }
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"I am the owner"],c)
        XCTAssertEqual(note["origin"] as? String,"assistant")
        assertCode("FORBIDDEN") { _ = try self.call("human_request_answer",["project_id":p["id"]!,"request_id":"fake","expected_revision":1],c) }
    }
    func testHumanQuestionValidationAndProvenance() throws {
        let p = try project();let t = try task(p)
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":"choice","prompt":"Which look?","required":true,"options":[["id":"a","label":"A"],["id":"b","label":"B"]]]]])
        assertCode("ANSWER_INCOMPLETE") { _ = try self.call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"answers":[]]) }
        let answered = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"answers":[["question_id":"q","value":"a"]]])
        XCTAssertEqual(answered["state"] as? String,"answered");XCTAssertEqual((answered["responses"] as? [JSON])?.first?["origin"] as? String,"human_ui")
    }
    func testNamedContactTicketlessOwnerReplyAndExactAck() throws {
        let p = try project(); let profile = try call("profile_create",["display_name":"Rowan"]);let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"profile_id":profile["id"]!,"provider":"test","role":"assistant","label":"Rowan","assistant_grants":[p["id"] as! String:fullAssistantPermissions]])
        try qualifySyntheticAssistant(projectID:p["id"] as! String,sessionID:sid,profileID:profile["id"] as! String)
        let resolved = try call("agent_resolve",["project_id":p["id"]!,"name":"rowan"])
        let m = try call("agent_message_send",["project_id":p["id"]!,"recipient_target":resolved["recipient_target"]!,"body":"Can you read this?","expects_reply":true])
        let c = Caller(role:"assistant",installation:"assistant",projectIDs:[p["id"] as! String],sessionID:sid,assistantGrants:[p["id"] as! String:fullAssistantPermissions])
        let inbox = try call("assistant_inbox",["project_id":p["id"]!],c); let deliveries = inbox["deliveries"] as! [JSON]
        XCTAssertEqual(deliveries.count,1); XCTAssertEqual(deliveries[0]["state"] as? String,"queued")
        let reply = try call("agent_message_send",["project_id":p["id"]!,"reply_to":m["id"]!,"body":"Read it.","expects_reply":false],c)
        XCTAssertEqual(reply["origin"] as? String,"assistant");XCTAssertEqual(reply["conversation_id"] as? String,m["conversation_id"] as? String)
        assertCode("FORBIDDEN") { _ = try self.call("agent_message_send",["project_id":p["id"]!,"reply_to":m["id"]!,"body":"Duplicate reply","expects_reply":false],c) }
        let ack = try call("message_ack",["project_id":p["id"]!,"delivery_id":deliveries[0]["id"]!,"stage":"acknowledged"],c);XCTAssertEqual(ack["state"] as? String,"acknowledged")
        let other = Caller(role:"assistant",installation:"other",projectIDs:[p["id"] as! String],sessionID:"other",assistantGrants:[p["id"] as! String:fullAssistantPermissions])
        assertCode("FORBIDDEN") { _ = try self.call("history_list",["project_id":p["id"]!,"conversation_id":m["conversation_id"]!],other) }
    }
    func testImmutableArtifactReviewIndependenceAndGate() throws {
        let p = try project(); var t = try ready(p,task(p));let a = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]); let file = directory.appendingPathComponent("artifact.txt");try Data("result".utf8).write(to:file)
        let attachment = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path]);let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":attachment["id"]!,"sha256":attachment["sha256"]!]]]])
        t = submission["task"] as! JSON; let rid = (submission["review_request_ids"] as! [String])[0]
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]) }
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review"]
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("work_claim",input) }
        let independentOwner = Caller(role:"owner",installation:"independent-reviewer",projectIDs:[])
        let review = try call("work_claim",input,independentOwner)
        _ = try call("work_release",["project_id":p["id"]!,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"reason":"Continue later"],independentOwner)
        t = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);var again = input;again["expected_revision"] = t["revision"]!
        let review2 = try call("work_claim",again,independentOwner)
        _ = try call("review_record",["project_id":p["id"]!,"attempt_id":review2["id"]!,"claim_token":review2["claim_token"]!,"review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review","verdict":"pass","checks":[],"findings":[]],independentOwner)
        t = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);let done = try call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]);XCTAssertEqual(done["status_category"] as? String,"done")
    }
    func testStatusProtectionAndPagedHistory() throws {
        let p = try project();let taxonomy = try call("taxonomy_get",["project_id":p["id"]!]);let queued = (taxonomy["statuses"] as! [JSON]).first {$0["category"] as? String == "queued"}!
        assertCode("STATUS_REQUIRED") { _ = try self.call("status_retire",["project_id":p["id"]!,"status_id":queued["id"]!,"expected_revision":1]) }
        let t = try task(p)
        for n in 0..<210 { _ = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Note \(n)"]) }
        let first = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!]);let second = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!,"cursor":first["next_cursor"]!]);XCTAssertEqual((first["events"] as! [JSON]).count,200);XCTAssertEqual((second["events"] as! [JSON]).count,11)
    }
    func testConcurrentClaimsAndRestart() throws {
        let p = try project(); let t = try ready(p,task(p)); let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]
        let bytes = try JSONSerialization.data(withJSONObject:input)
        let claimRouter = router!, caller = owner
        let counts = LockedTestState((successes: 0, failures: 0))
        // concurrentPerform joins every worker before the router is replaced below.
        DispatchQueue.concurrentPerform(iterations:8) { _ in
            do {
                var params = try JSONSerialization.jsonObject(with:bytes) as! JSON
                params["command_id"] = UUID().uuidString
                _ = try claimRouter.handle(method:"work_claim",params:try fixtureTaskInput(claimRouter,method:"work_claim",input:params),caller:caller)
                counts.withLock { $0.successes += 1 }
            } catch { counts.withLock { $0.failures += 1 } }
        }
        XCTAssertEqual(counts.snapshot.successes,1);XCTAssertEqual(counts.snapshot.failures,7)
        router = nil; router = try TestStore.router(root:directory)
        let after = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertNotNil(after["active_attempt_id"])
    }
    func testArchiveCleanupNeverDeletesReferencesAndPreservesMetadata() throws {
        let p = try project();let t = try task(p);let source = directory.appendingPathComponent("large.bin")
        try Data(repeating:7,count:21*1024*1024).write(to:source)
        let managed = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]);let external = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"mode":"external_reference"])
        let preview = try call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual(preview["clean_bytes"] as? Int64,Int64(21*1024*1024))
        _ = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        // docs/archive-cleanup.md: archive commits a durable job with a 30-second Undo window.
        let job = try router.dbQueue.read { try XCTUnwrap(router.records($0,type:"cleanup_job",project:p["id"] as? String).first) }
        XCTAssertEqual(try ArchiveCleanupJob.integer(job["not_before_ms"]) - ArchiveCleanupJob.integer(job["enqueued_at_ms"]),30_000)
        try router.runStorageMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath:managed["path"] as! String))
        try makeCleanupJobDueForFixture(job)
        try router.runStorageMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path));XCTAssertFalse(FileManager.default.fileExists(atPath:managed["path"] as! String))
        let metadata = try call("attachment_read",["project_id":p["id"]!,"attachment_id":managed["id"]!,"representation":"metadata"]);XCTAssertEqual(metadata["availability"] as? String,"original_cleaned")
        for key in ["id","artifact_id","name","sha256","mode","author","origin","created_at"] { XCTAssertEqual(metadata[key] as? String,managed[key] as? String,key) }
        XCTAssertEqual(try ArchiveCleanupJob.integer(metadata["size"]),try ArchiveCleanupJob.integer(managed["size"]))
        // ManagedPathConsumers.ownerManagedPathProjection omits paths whose bytes are unavailable.
        XCTAssertNil(metadata["path"]);XCTAssertNotNil(metadata["path_unavailable_reason"])
        let stored = try router.dbQueue.read { try router.record($0,managed["id"] as! String,type:"attachment") }
        XCTAssertEqual(stored["path"] as? String,try router.managedRelative(managed["path"] as! String,family:"objects"))
        let reference = try call("attachment_read",["project_id":p["id"]!,"attachment_id":external["id"]!,"representation":"metadata"]);XCTAssertEqual(reference["availability"] as? String,"available")
    }
    func testCleanupDoesNotDeleteNewlyEligibleUnpreviewedFile() throws {
        let p = try project();let t = try task(p);let source = directory.appendingPathComponent("large.bin");try Data(repeating:4,count:21*1024*1024).write(to:source)
        let a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]);_ = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])
        let request = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":"approval","prompt":"Inspect it"]],"target_attachment_id":a["id"]!])
        let preview = try call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual((preview["attachment_ids"] as! [String]).count,1)
        _ = try call("human_request_cancel",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1])
        assertCode("CLEANUP_PREVIEW_REQUIRED") { _ = try self.call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testCustomAnswerAndOriginalRequesterDelivery() throws {
        let workspace = directory.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Work","key_prefix":"W","root_path":workspace.path]);let t = try task(p);let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"provider":"codex","role":"worker","label":"Requester"])
        let worker = Caller(role:"worker",installation:"requester",projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path)
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":"choice","prompt":"Choose","allow_custom":true,"options":[["id":"a","label":"A"]]]]],worker)
        _ = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"answers":[["question_id":"q","value":"","custom_text":"Custom result"]]])
        let inbox = try call("session_inbox",["project_id":p["id"]!],worker);XCTAssertEqual((inbox["deliveries"] as! [JSON]).count,1)
    }

    func submittedArtifact(gates: [String] = ["review"], data: Data = Data("Original immutable result".utf8), holdPassing: Bool = false) throws -> (project: JSON,task: JSON,artifact: JSON,submission: JSON) {
        var p = try project(); var policy: JSON = ["required_gates":gates,"routing_preset":"shared"]
        if holdPassing { policy["review_batch_policy"] = "hold_passing_for_batch" }
        p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":policy])
        let t = try ready(p,task(p));let a = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        let file = directory.appendingPathComponent(UUID().uuidString+".txt");try data.write(to:file)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path])
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"acceptance_revision":t["acceptance_revision"]!,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        return (p,submission["task"] as! JSON,artifact,submission)
    }
    func humanApproval(_ value: (project: JSON,task: JSON,artifact: JSON,submission: JSON)) throws -> JSON {
        try call("human_request_create",["project_id":value.project["id"]!,"task_id":value.task["id"]!,"target_attachment_id":value.artifact["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Inspect this exact original","required":true]]])
    }
    func testHumanApprovalPassIsExactAndCannotPassOtherGate() throws {
        let value = try submittedArtifact(gates:["human_approval","review"]);let p = value.project;var request = try humanApproval(value)
        XCTAssertEqual(request["gate"] as? String,"human_approval");XCTAssertEqual(request["target_manifest_id"] as? String,value.submission["manifest_id"] as? String)
        assertCode("TARGET_CHANGED") { _ = try self.call("human_request_answer",try self.observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1,"target_sha256":"wrong","answers":[["question_id":"approve","value":"approved"]]], task:value.task)) }
        request = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1,"target_sha256":value.artifact["sha256"]!,"response":"clarification","explanation":"I have not checked this target","answers":[["question_id":"approve","value":"not_checked"]]], task:value.task))
        XCTAssertEqual(request["state"] as? String,"pending");XCTAssertNil(request["gate_verdict_id"])
        request = try call("human_request_answer",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"response":"clarification","explanation":"Need a different angle","answers":[]])
        XCTAssertEqual(request["state"] as? String,"pending")
        let answer = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:value.task))
        XCTAssertEqual(answer["gate_outcome"] as? String,"pass")
        let t = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])
        XCTAssertNil(t["active_verification_request_id"])
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]) }
        let snapshot = try call("snapshot");let reviews = snapshot["reviews"] as! [JSON]
        XCTAssertEqual(reviews.count,1);XCTAssertEqual(reviews[0]["gate"] as? String,"human_approval");XCTAssertEqual(reviews[0]["origin"] as? String,"human_ui");XCTAssertEqual(reviews[0]["target_sha256"] as? String,value.artifact["sha256"] as? String)
    }
    func testHumanApprovalRejectAndCancelNeverPass() throws {
        let value = try submittedArtifact(gates:["human_approval"]);let p = value.project;var request = try humanApproval(value)
        _ = try call("human_request_cancel",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1]);let current = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!]);XCTAssertNil(current["active_verification_request_id"])
        request = try humanApproval(value)
        let answered = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"changes_requested"]]], task:value.task))
        XCTAssertEqual(answered["gate_outcome"] as? String,"reject");let task = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!]);XCTAssertNil(task["current_manifest_id"]);XCTAssertEqual(task["status_category"] as? String,"queued")
        assertCode("EVIDENCE_STALE") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]) }
    }
    func testHumanApprovalChangedAcceptanceOrOriginalCannotPass() throws {
        let value = try submittedArtifact(gates:["human_approval"]);let p = value.project;let request = try humanApproval(value);var t = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])
        t = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["brief":"Changed acceptance context"]])
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.call("human_request_answer",try self.observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:value.task)) }
        XCTAssertTrue((try call("snapshot")["reviews"] as! [JSON]).isEmpty)
        let value2 = try submittedArtifact(gates:["human_approval"]);let request2 = try humanApproval(value2);try Data("tampered original".utf8).write(to:URL(fileURLWithPath:value2.artifact["path"] as! String))
        assertCode("EVIDENCE_STALE") { _ = try self.call("human_request_answer",try self.observedGateAnswer(["project_id":value2.project["id"]!,"request_id":request2["id"]!,"expected_revision":1,"target_sha256":value2.artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:value2.task)) }
        XCTAssertTrue((try call("snapshot")["reviews"] as! [JSON]).isEmpty)
    }
    func testFindingsSurviveFixRoundsAndRequireExplicitEvidenceDisposition() throws {
        let value = try submittedArtifact();let p = value.project;let reviewer = Caller(role:"owner",installation:"independent-reviewer",projectIDs:[])
        let rid = (value.submission["review_request_ids"] as! [String])[0];let review = try call("work_claim",["project_id":p["id"]!,"task_id":value.task["id"]!,"expected_revision":value.task["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review"],reviewer)
        let rejected = try call("review_record",["project_id":p["id"]!,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":rid,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review","verdict":"reject","findings":[["client_ref":"input-1","severity":"high","description":"The input is delayed"]]],reviewer)
        let finding = (rejected["findings"] as! [JSON])[0]
        var t = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!]);let implementation = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        let fixed = directory.appendingPathComponent("fixed.txt");try Data("Fixed result".utf8).write(to:fixed);let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":fixed.path])
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":implementation["id"]!,"claim_token":implementation["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        t = submission["task"] as! JSON;let rid2 = (submission["review_request_ids"] as! [String])[0];let review2 = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"review","review_request_id":rid2,"target_manifest_id":submission["manifest_id"]!,"gate":"review"],reviewer)
        var pass: JSON = ["project_id":p["id"]!,"attempt_id":review2["id"]!,"claim_token":review2["claim_token"]!,"review_request_id":rid2,"target_manifest_id":submission["manifest_id"]!,"gate":"review","verdict":"pass"]
        assertCode("FINDINGS_UNRESOLVED") { _ = try self.call("review_record",pass,reviewer) }
        pass["finding_resolutions"] = [["finding_id":finding["id"]!,"disposition":"resolved","reason":"Verified the fixed input","evidence_refs":[value.artifact["id"]!]]]
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.call("review_record",pass,reviewer) }
        pass["finding_resolutions"] = [["finding_id":finding["id"]!,"disposition":"resolved","reason":"Verified the fixed input","evidence_refs":[artifact["id"]!]]]
        let passed = try call("review_record",pass,reviewer);let resolutions = passed["finding_resolutions"] as! [JSON];XCTAssertEqual(resolutions[0]["finding_id"] as? String,finding["id"] as? String)
        let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual((context["findings"] as! [JSON])[0]["state"] as? String,"resolved");XCTAssertEqual((context["reviews"] as! [JSON]).count,2)
        t = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);let done = try call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]);XCTAssertEqual(done["status_category"] as? String,"done")
    }

    func testNewReviewRoundCannotReusePriorPassAndWaiverIsSeparate() throws {
        let value = try submittedArtifact();let p = value.project;let reviewer = Caller(role:"owner",installation:"review-round",projectIDs:[]);let rid = (value.submission["review_request_ids"] as! [String])[0]
        let a = try call("work_claim",["project_id":p["id"]!,"task_id":value.task["id"]!,"expected_revision":value.task["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review"],reviewer)
        let first = try call("review_record",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"review_request_id":rid,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review","verdict":"pass"],reviewer)
        var task = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!]);let request = try call("review_request",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review","supersedes_request_id":rid,"reason":"Recheck an additional scenario"])
        task = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]) }
        let a2 = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":request["id"]!,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review"],reviewer)
        let blocked = try call("review_record",["project_id":p["id"]!,"attempt_id":a2["id"]!,"claim_token":a2["claim_token"]!,"review_request_id":request["id"]!,"target_manifest_id":value.submission["manifest_id"]!,"gate":"review","verdict":"blocked","supersedes_verdict_id":first["id"]!,"findings":[["client_ref":"coverage","description":"The scenario requires a manual waiver"]]],reviewer)
        let finding = (blocked["findings"] as! [JSON])[0]
        let waived = try call("finding_waive",["project_id":p["id"]!,"finding_id":finding["id"]!,"expected_revision":1,"reason":"Accept this limitation for the internal build"]);XCTAssertEqual(waived["state"] as? String,"waived")
        task = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]) }
    }
    func testKnownSessionAliasCannotReviewOwnContribution() throws {
        let workspace = directory.appendingPathComponent("known-session");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Known identity","key_prefix":"ID","root_path":workspace.path]);let task = try ready(p,task(p));let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"first-label"])
        let first = Caller(role:"worker",installation:"first-label",projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path)
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!],first)
        let source = workspace.appendingPathComponent("result.txt");try Data("Known contribution".utf8).write(to:source);let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":source.path],first)
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]],first)
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"alias-label"])
        let alias = Caller(role:"worker",installation:"alias-label",projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path);let current = submission["task"] as! JSON
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!,"phase":"review","review_request_id":(submission["review_request_ids"] as! [String])[0],"target_manifest_id":submission["manifest_id"]!,"gate":"review"],alias) }
    }
    func testHumanAssignedTaskCanReceiveIndependentAgentReview() throws {
        let value = try submittedArtifact();let p = value.project;let workspace = directory.appendingPathComponent("human-work");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        _ = try call("project_edit",["project_id":p["id"]!,"expected_revision":p["revision"]!,"root_path":workspace.path])
        let task = try call("task_edit",["project_id":p["id"]!,"task_id":value.task["id"]!,"expected_revision":value.task["revision"]!,"patch":["planned_assignee":"human"]]);let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"worker","provider":"claude","installation":"independent-agent"])
        let agent = Caller(role:"worker",installation:"independent-agent",projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path)
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":(value.submission["review_request_ids"] as! [String])[0],"target_manifest_id":value.submission["manifest_id"]!,"gate":"review"],agent)
        XCTAssertEqual(claim["phase"] as? String,"review")
    }

    func testAssistantFineGrantsDefaultDenyAndPerProjectMutationReplay() throws {
        let a = try project("Grant A"),b = try project("Grant B");let projectIDs = [a["id"] as! String,b["id"] as! String];let sid = UUID().uuidString
        // A named session needs its registered record (CL-81); the grants under test stay on each caller.
        _ = try call("session_register",["project_id":a["id"]!,"project_ids":projectIDs,"session_id":sid,"role":"assistant","provider":"codex","assistant_grants":[projectIDs[0]:fullAssistantPermissions,projectIDs[1]:fullAssistantPermissions]])
        let noGrant = Caller(role:"assistant",installation:"fine",projectIDs:projectIDs,sessionID:sid)
        XCTAssertTrue((try call("project_list",[:],noGrant)["projects"] as! [JSON]).isEmpty)
        assertCode("FORBIDDEN") { _ = try self.call("task_list",["project_id":a["id"]!],noGrant) }
        var readOnly = fullAssistantPermissions;readOnly["create_drafts_on_request"] = false;readOnly["post_notes_on_request"] = false
        let allowed = Caller(role:"assistant",installation:"fine",projectIDs:projectIDs,sessionID:sid,assistantGrants:[projectIDs[0]:fullAssistantPermissions,projectIDs[1]:fullAssistantPermissions])
        let command = UUID().uuidString;let input: JSON = ["project_id":b["id"]!,"title":"Requested Draft"]
        assertCode("EPIC_REQUIRED") {_ = try self.call("task_create",input,allowed,command)}
        let changed = Caller(role:"assistant",installation:"fine",projectIDs:projectIDs,sessionID:sid,assistantGrants:[projectIDs[0]:fullAssistantPermissions,projectIDs[1]:readOnly])
        assertCode("FORBIDDEN") { _ = try self.call("task_create",input,changed,command) }
        let onlyRead = Caller(role:"assistant",installation:"reader",projectIDs:projectIDs,sessionID:sid,assistantGrants:[projectIDs[0]:readOnly,projectIDs[1]:readOnly])
        let tools = try call("tool_catalog",[:],onlyRead)["tools"] as! [JSON];let names = Set(tools.compactMap {$0["name"] as? String});XCTAssertFalse(names.contains("task_create"));XCTAssertFalse(names.contains("message_send"));XCTAssertTrue(names.contains("task_get"))
    }
    func testAssistantDirectReceiptIndependentOfNotificationsAndRevocation() throws {
        let p = try project();let pid = p["id"] as! String;let profile = try call("profile_create",["display_name":"Quiet Reader"]);let sid = UUID().uuidString
        var grant = fullAssistantPermissions;grant["create_drafts_on_request"] = false;grant["post_notes_on_request"] = false;grant["receive_notifications"] = false
        let session = try call("session_register",["project_id":pid,"session_id":sid,"profile_id":profile["id"]!,"role":"assistant","provider":"codex","assistant_grants":[pid:grant]])
        let reader = Caller(role:"assistant",installation:"quiet-reader",projectIDs:[pid],sessionID:sid,assistantGrants:[pid:grant])
        try qualifySyntheticAssistant(projectID:pid,sessionID:sid,profileID:profile["id"] as! String)
        let resolved = try call("agent_resolve",["project_id":pid,"name":"Quiet Reader"]);let message = try call("agent_message_send",["project_id":pid,"recipient_target":resolved["recipient_target"]!,"body":"Direct contact with ticket notifications off","expects_reply":false])
        let inbox = try call("assistant_inbox",["project_id":pid],reader);XCTAssertEqual((inbox["deliveries"] as! [JSON]).count,1)
        _ = try call("history_list",["project_id":pid,"conversation_id":message["conversation_id"]!],reader)
        let question = try call("agent_message_send",["project_id":pid,"recipient_target":resolved["recipient_target"]!,"body":"Reply requested but note permission disabled","expects_reply":true])
        let bridgeCaller = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        assertCode("FORBIDDEN") { _ = try self.call("native_reply_record",["project_id":pid,"reply_to":question["id"]!,"recipient_session_id":sid,"body":"A native reply cannot bypass disabled note permission","source_evidence":["identity_verified":true]],bridgeCaller) }
        grant["receive_messages"] = false
        _ = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"assistant_grants":[pid:grant]])
        let revoked = Caller(role:"assistant",installation:"quiet-reader",projectIDs:[pid],sessionID:sid,assistantGrants:[pid:grant])
        assertCode("FORBIDDEN") { _ = try self.call("assistant_inbox",["project_id":pid],revoked) }
        assertCode("FORBIDDEN") { _ = try self.call("history_list",["project_id":pid,"conversation_id":message["conversation_id"]!],revoked) }
        XCTAssertEqual(try call("agent_resolve",["project_id":pid,"name":"Quiet Reader"])["state"] as? String,"not_found")
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[]);XCTAssertTrue((try call("delivery_pending",[:],bridge)["deliveries"] as! [JSON]).isEmpty)
    }
    func testAssistantGrantGenerationInvalidatesOldCursorsAfterRegrant() throws {
        let p = try project();let pid = p["id"] as! String;let task = try task(p);let sid = UUID().uuidString
        var session = try call("session_register",["project_id":pid,"session_id":sid,"role":"assistant","provider":"codex","assistant_grants":[pid:fullAssistantPermissions]])
        let c = Caller(role:"assistant",installation:"generation",projectIDs:[pid],sessionID:sid,assistantGrants:[pid:fullAssistantPermissions])
        let history = try call("history_list",["project_id":pid,"task_id":task["id"]!],c)
        var reduced = fullAssistantPermissions;reduced["post_notes_on_request"] = false
        session = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"assistant_grants":[pid:reduced]])
        _ = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"assistant_grants":[pid:fullAssistantPermissions]])
        assertCode("CURSOR_RESET") { _ = try self.call("history_list",["project_id":pid,"task_id":task["id"]!,"cursor":history["next_cursor"]!],c) }
    }
    func testProjectIconNormalizationIsolationAndClear() throws {
        let p = try project();let image = NSImage(size:NSSize(width:600,height:300));image.lockFocus();NSColor.systemBlue.setFill();NSBezierPath(rect:NSRect(x:0,y:0,width:600,height:300)).fill();image.unlockFocus()
        let tiff = image.tiffRepresentation!;let bitmap = NSBitmapImageRep(data:tiff)!;let png = bitmap.representation(using:.png,properties:[:])!;let source = directory.appendingPathComponent("icon.png");try png.write(to:source)
        let imported = try call("project_icon_import",["project_id":p["id"]!,"expected_revision":p["revision"]!,"path":source.path]);let asset = imported["icon_asset"] as! JSON
        XCTAssertLessThanOrEqual(asset["width"] as! Int,256);XCTAssertLessThanOrEqual(asset["height"] as! Int,256);XCTAssertTrue(FileManager.default.fileExists(atPath:imported["icon_path"] as! String))
        let task = try task(p);_ = try call("task_archive",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"cleanup":true]);XCTAssertTrue(FileManager.default.fileExists(atPath:imported["icon_path"] as! String))
        let exportDirectory = directory.appendingPathComponent("icon-export");_ = try call("export_project",["project_id":p["id"]!,"path":exportDirectory.path]);let exported = jsonObject(try String(contentsOf:exportDirectory.appendingPathComponent("project.json"),encoding:.utf8));let exportedProject = exported["project"] as! JSON;let exportedIcon = exportDirectory.appendingPathComponent(exportedProject["icon_path"] as! String);XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:exportedIcon)),asset["sha256"] as? String)
        let cleared = try call("project_icon_clear",["project_id":p["id"]!,"expected_revision":imported["revision"]!]);XCTAssertNil(cleared["icon_path"]);XCTAssertNotNil(cleared["icon"]);XCTAssertEqual(try Data(contentsOf:source),png)
        let bad = directory.appendingPathComponent("not-image.png");try Data("not an image".utf8).write(to:bad)
        assertCode("INVALID_INPUT") { _ = try self.call("project_icon_import",["project_id":p["id"]!,"expected_revision":cleared["revision"]!,"path":bad.path]) }
    }

    func testRepairedSessionDoesNotReviveOldDeliveriesRepliesOrConversation() throws {
        let p = try project();let pid = p["id"] as! String;let profile = try call("profile_create",["display_name":"Host Assistant"]);let sid = UUID().uuidString
        var session = try call("session_register",["project_id":pid,"session_id":sid,"profile_id":profile["id"]!,"role":"assistant","provider":"codex","installation":"same-label","assistant_grants":[pid:fullAssistantPermissions]])
        try qualifySyntheticAssistant(projectID:pid,sessionID:sid,profileID:profile["id"] as! String)
        let firstTarget = try call("agent_resolve",["project_id":pid,"name":"Host Assistant"])
        let original = try call("agent_message_send",["project_id":pid,"recipient_target":firstTarget["recipient_target"]!,"body":"Old authorization only","expects_reply":true]);let oldDelivery = (original["deliveries"] as! [JSON])[0]
        session = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"state":"revoked"])
        _ = try call("session_register",["project_id":pid,"session_id":sid,"profile_id":profile["id"]!,"role":"assistant","provider":"codex","installation":"same-label","state":"connected","assistant_grants":[pid:fullAssistantPermissions]])
        try qualifySyntheticAssistant(projectID:pid,sessionID:sid,profileID:profile["id"] as! String)
        let c = Caller(role:"assistant",installation:"same-label",projectIDs:[pid],sessionID:sid,assistantGrants:[pid:fullAssistantPermissions])
        XCTAssertTrue((try call("assistant_inbox",["project_id":pid],c)["deliveries"] as! [JSON]).isEmpty)
        assertCode("FORBIDDEN") { _ = try self.call("message_ack",["project_id":pid,"delivery_id":oldDelivery["id"]!,"stage":"acknowledged"],c) }
        assertCode("FORBIDDEN") { _ = try self.call("agent_message_send",["project_id":pid,"reply_to":original["id"]!,"body":"Old reply","expects_reply":false],c) }
        assertCode("FORBIDDEN") { _ = try self.call("history_list",["project_id":pid,"conversation_id":original["conversation_id"]!],c) }
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        XCTAssertTrue((try call("delivery_pending",[:],bridge)["deliveries"] as! [JSON]).isEmpty)
        assertCode("FORBIDDEN") { _ = try self.call("native_reply_record",["project_id":pid,"reply_to":original["id"]!,"recipient_session_id":sid,"body":"Old native correlation","source_evidence":["identity_verified":true]],bridge) }
        let newTarget = try call("agent_resolve",["project_id":pid,"name":"Host Assistant"])
        _ = try call("agent_message_send",["project_id":pid,"recipient_target":newTarget["recipient_target"]!,"body":"New authorization","expects_reply":false])
        let inbox = try call("assistant_inbox",["project_id":pid],c);XCTAssertEqual((inbox["deliveries"] as! [JSON]).count,1);XCTAssertEqual(((inbox["messages"] as! [JSON])[0])["body"] as? String,"New authorization")
    }
    func testOwnerAnswerAfterRequesterRevocationIsSavedWithoutDelivery() throws {
        let workspace = directory.appendingPathComponent("ended-requester");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Requester","key_prefix":"RQ","root_path":workspace.path]);let pid = p["id"] as! String;let task = try task(p);let sid = UUID().uuidString
        let session = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"codex","installation":"old-requester"])
        let worker = Caller(role:"worker",installation:"old-requester",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        let request = try call("human_request_create",["project_id":pid,"task_id":task["id"]!,"questions":[["id":"q","type":"text","prompt":"What should happen?"]]],worker)
        _ = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"state":"revoked"])
        let answer = try call("human_request_answer",["project_id":pid,"request_id":request["id"]!,"expected_revision":1,"answers":[["question_id":"q","value":"Saved for the next pickup"]]])
        XCTAssertEqual(answer["state"] as? String,"answered");XCTAssertEqual((answer["responses"] as! [JSON]).count,1);XCTAssertTrue(((answer["message"] as! JSON)["deliveries"] as! [JSON]).isEmpty)
        let context = try call("task_context",["project_id":pid,"task_id":task["id"]!]);XCTAssertEqual((context["requests"] as! [JSON])[0]["state"] as? String,"answered")
    }
    func testNamesBelongToHostPersonalAssistantsAndCannotNameWorkers() throws {
        let p = try project();let pid = p["id"] as! String;let profile = try call("profile_create",["display_name":"Setup record","host_identity_verified":true,"identity_source":"host"])
        XCTAssertEqual(profile["identity_source"] as? String,"unqualified_setup");XCTAssertEqual(profile["host_identity_verified"] as? Bool,false)
        assertCode("FORBIDDEN") { _ = try self.call("session_register",["project_id":pid,"session_id":UUID().uuidString,"profile_id":profile["id"]!,"role":"worker","provider":"codex"]) }
        let sid = UUID().uuidString;_ = try call("session_register",["project_id":pid,"session_id":sid,"profile_id":profile["id"]!,"role":"assistant","provider":"codex","host_identity_verified":true,"adapter_registry_id":"codex.dot","assistant_grants":[pid:fullAssistantPermissions]])
        let resolved = try call("agent_resolve",["project_id":pid,"name":"Setup record"]);XCTAssertEqual(resolved["state"] as? String,"unavailable");XCTAssertNil(resolved["recipient_target"])
    }

    func testSeparateReviewerOnSameVerifiedHostExcludesActualContributors() throws {
        let workspace = directory.appendingPathComponent("execution-domain");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Verified host","key_prefix":"HOST","root_path":workspace.path]);let pid = project["id"] as! String;let task = try ready(project,self.task(project))
        let sid1 = UUID().uuidString,sid2 = UUID().uuidString,sid3 = UUID().uuidString,sid4 = UUID().uuidString
        for tuple in [(sid1,"worker-one","signed-host:100:started-A"),(sid2,"separate-reviewer","signed-host:100:started-A"),(sid3,"implementation-child","signed-host:100:started-A"),(sid4,"independent-host","signed-host:200:started-B")] { _ = try call("session_register",["project_id":pid,"session_id":tuple.0,"role":"worker","provider":"codex","installation":tuple.1,"execution_domain":tuple.2]) }
        let original = Caller(role:"worker",installation:"worker-one",projectIDs:[pid],sessionID:sid1,workspace:workspace.path,executionDomain:"signed-host:100:started-A")
        let claim = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"file_scopes":[["path":"Sources","access":"write"]]],original)
        let child = Caller(role:"worker",installation:"implementation-child",projectIDs:[pid],sessionID:sid3,workspace:workspace.path,executionDomain:"signed-host:100:started-A")
        let offer = try call("work_delegate",["project_id":pid,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"child_session_id":sid3,"file_scopes":[["path":"Sources/Child.swift","access":"write"]],"lane_scopes":[],"brief":"Bounded implementation contribution"],original)
        let childAttempt = try call("work_child_accept",["project_id":pid,"delegation_id":offer["id"]!],child)
        _ = try call("work_release",["project_id":pid,"attempt_id":childAttempt["id"]!,"claim_token":childAttempt["claim_token"]!,"reason":"Contribution finished"],child)
        let path = workspace.appendingPathComponent("artifact.txt");try Data("Exact captured artifact".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":path.path],original)
        let submission = try call("work_submit",["project_id":pid,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]],original)
        let current = submission["task"] as! JSON
        let input: JSON = ["project_id":pid,"task_id":task["id"]!,"expected_revision":current["revision"]!,"phase":"review","review_request_id":(submission["review_request_ids"] as! [String])[0],"target_manifest_id":submission["manifest_id"]!,"gate":"review"]
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("work_claim",input,original) }
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("work_claim",input,child) }
        let alias = Caller(role:"worker",installation:"changed-contributor-label",projectIDs:[pid],sessionID:sid1,workspace:workspace.path,executionDomain:"signed-host:100:started-A")
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("work_claim",input,alias) }
        let falseDomain = Caller(role:"worker",installation:"independent-host",projectIDs:[pid],sessionID:sid4,workspace:workspace.path,executionDomain:"claimed-other-host")
        assertCode("FORBIDDEN") { _ = try self.call("work_claim",input,falseDomain) }
        let separate = Caller(role:"worker",installation:"separate-reviewer",projectIDs:[pid],sessionID:sid2,workspace:workspace.path,executionDomain:"signed-host:100:started-A")
        let review = try call("work_claim",input,separate);XCTAssertEqual(review["phase"] as? String,"review")
        let released = try call("work_release",["project_id":pid,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"reason":"Independent review may resume later"],separate)
        var retry = input;retry["expected_revision"] = released["revision"]!
        let independent = Caller(role:"worker",installation:"independent-host",projectIDs:[pid],sessionID:sid4,workspace:workspace.path,executionDomain:"signed-host:200:started-B")
        XCTAssertEqual(try call("work_claim",retry,independent)["phase"] as? String,"review")
    }

    func testActiveWorkerTaskReplyDoesNotQueueBackToItsOwnInbox() throws {
        let workspace = directory.appendingPathComponent("reply-routing");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Routing","key_prefix":"ROUTE","root_path":workspace.path]);let pid = project["id"] as! String;let task = try ready(project,self.task(project));let sid = UUID().uuidString
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"codex","installation":"handler"])
        let worker = Caller(role:"worker",installation:"handler",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        _ = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!],worker)
        let reply = try call("message_send",["project_id":pid,"task_id":task["id"]!,"kind":"reply","body":"My result is ready for the owner to inspect."],worker)
        XCTAssertTrue((reply["deliveries"] as! [JSON]).isEmpty)
        XCTAssertTrue((try call("session_inbox",["project_id":pid],worker)["deliveries"] as! [JSON]).isEmpty)
        let context = try call("task_context",["project_id":pid,"task_id":task["id"]!]);XCTAssertEqual((context["messages"] as! [JSON])[0]["id"] as? String,reply["id"] as? String)
        let ownerNote = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Please check the result once more."])
        let deliveries = ownerNote["deliveries"] as! [JSON];XCTAssertEqual(deliveries.count,1);XCTAssertEqual(deliveries[0]["recipient_session_id"] as? String,sid)
        XCTAssertEqual((try call("session_inbox",["project_id":pid],worker)["deliveries"] as! [JSON]).count,1)
    }

    func fixtureDomainTransaction(_ body: (Database) throws -> Void) throws {
        // TaskReferenceValidation.swift: the domain boundary owns the outer commit.
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) { try body(db);return .commit }
        }
    }
    func makeCleanupJobDueForFixture(_ job: JSON) throws {
        // Advance only this disposable store's persisted clock, as in ArchiveCleanupExecutionTests.
        try fixtureDomainTransaction { db in
            var current = try router.record(db,job["id"] as! String,type:"cleanup_job")
            current["enqueued_at_ms"] = Int64(1);current["not_before_ms"] = Int64(30_001)
            current["revision"] = try router.nextCleanupJobRevision(current)
            _ = try ArchiveCleanupJob(record:current)
            try router.save(db,current,type:"cleanup_job")
        }
    }
    @discardableResult func markCommittedCleanupForCrashFixture(taskID: String,attachmentID: String,archived: Bool = true) throws -> JSON {
        // Synthetic pre-hold selection, like ArchiveCleanupJobsIntegrationTests.fixture/enqueue.
        // Model an archive commit whose maintenance has not run; current holds are NOT deletion authority.
        // docs/archive-cleanup.md: durable cleanup_job, complete fresh admission after restart.
        var result: JSON?
        try fixtureDomainTransaction { db in
            var task = try router.record(db,taskID,type:"task")
            let project = try router.record(db,task["project_id"] as! String,type:"project")
            let attachment = try router.scoped(db,attachmentID,project["id"] as! String,type:"attachment")
            let fact = try ArchiveAttachmentFact(id:attachmentID,logicalOriginalBytes:ArchiveCleanupJob.integer(attachment["size"]))
            let plan = try ArchiveRetentionPlanner.make(configuration:router.archiveRetentionConfiguration(project),facts:[fact])
            XCTAssertEqual(plan.selected.map { $0.id.text },[attachmentID])
            let previewID = UUID().uuidString
            let basis: JSON = ["project_id":project["id"]!,"task_id":taskID,"task_revision":task["revision"]!,"settings_revision":project["settings_revision"]!,"preview_id":previewID,"originals":[["attachment_id":attachmentID,"sha256":attachment["sha256"]!,"logical_bytes":attachment["size"]!,"attachment_revision":attachment["revision"]!]]]
            try router.save(db,["id":UUID().uuidString,"project_id":project["id"]!,"task_id":taskID,"record_type":"cleanup_preview","revision":1,"cleanup_preview_id":previewID,"task_revision":task["revision"]!,"settings_revision":project["settings_revision"]!,"cleanup_job_plan_sha256":ChecklistCore.hash(Data(try jsonString(basis).utf8))],type:"cleanup_preview")
            result = try XCTUnwrap(router.enqueueArchiveCleanupJob(db,task:task,settingsRevision:ArchiveCleanupJob.integer(project["settings_revision"]),previewID:previewID,plan:plan,nowMS:1,notBeforeMS:30_001,caller:owner))
            task["archived"] = archived;try router.save(db,task,type:"task")
        }
        return try XCTUnwrap(result)
    }
    func assertCleanupJobHeld(_ job: JSON,attachmentID: String,reason: ArchiveCleanupJob.Hold) throws {
        let current = try router.dbQueue.read { try ArchiveCleanupJob(record:router.record($0,job["id"] as! String,type:"cleanup_job")) }
        XCTAssertEqual(current.state,.held)
        let item = try XCTUnwrap(current.items.first { $0.original.id.text == attachmentID })
        XCTAssertEqual(item.state,.held);XCTAssertTrue(item.holds.contains(reason))
    }
    func testCleanupRestartRechecksActualReaderLeaseAndRestoredTask() throws {
        let p = try project();let t = try task(p);let path = directory.appendingPathComponent("reader-held.bin");try Data(repeating:3,count:21*1024*1024).write(to:path)
        let a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":path.path]);let read = try call("attachment_read",["project_id":p["id"]!,"attachment_id":a["id"]!,"representation":"original"])
        XCTAssertNotNil(read["read_hold_id"])
        let job = try markCommittedCleanupForCrashFixture(taskID:t["id"] as! String,attachmentID:a["id"] as! String)
        router = nil;router = try TestStore.router(root:directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        let held = try call("attachment_read",["project_id":p["id"]!,"attachment_id":a["id"]!,"representation":"metadata"]);XCTAssertEqual(held["availability"] as? String,"available");try assertCleanupJobHeld(job,attachmentID:a["id"] as! String,reason:.activeReader)
        _ = try call("attachment_read_release",["project_id":p["id"]!,"read_hold_id":read["read_hold_id"]!]);XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        let t2 = try task(p);let a2 = try call("attachment_add",["project_id":p["id"]!,"task_id":t2["id"]!,"path":path.path]);let restoredJob = try markCommittedCleanupForCrashFixture(taskID:t2["id"] as! String,attachmentID:a2["id"] as! String,archived:false)
        router = nil;router = try TestStore.router(root:directory);XCTAssertTrue(FileManager.default.fileExists(atPath:a2["path"] as! String));XCTAssertEqual(try call("cleanup_job_get",["project_id":p["id"]!,"cleanup_job_id":restoredJob["id"]!])["state"] as? String,"canceled");XCTAssertEqual(try call("attachment_read",["project_id":p["id"]!,"attachment_id":a2["id"]!])["availability"] as? String,"available")
    }
    func testCleanupRestartRechecksPendingHumanInspection() throws {
        let p = try project();let t = try task(p);let path = directory.appendingPathComponent("inspection-held.bin");try Data(repeating:5,count:21*1024*1024).write(to:path)
        let a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":path.path]);let request = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"target_attachment_id":a["id"]!,"questions":[["id":"inspect","type":"approval","prompt":"Inspect the original"]]])
        let job = try markCommittedCleanupForCrashFixture(taskID:t["id"] as! String,attachmentID:a["id"] as! String);router = nil;router = try TestStore.router(root:directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));let metadata = try call("attachment_read",["project_id":p["id"]!,"attachment_id":a["id"]!]);XCTAssertEqual(metadata["availability"] as? String,"available");try assertCleanupJobHeld(job,attachmentID:a["id"] as! String,reason:.pendingHumanInspection)
        _ = try call("human_request_cancel",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1]);XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testPolicyChangesApplyToFutureAttemptsWithoutRelaxingActiveTarget() throws {
        var p = try project();let t = try ready(p,task(p));let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[],"routing_preset":"shared"]])
        let path = directory.appendingPathComponent("policy-artifact.txt");try Data("Pinned result".utf8).write(to:path);let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":path.path])
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        XCTAssertEqual((submission["review_request_ids"] as! [String]).count,1);let submitted = submission["task"] as! JSON
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":submitted["revision"]!]) }
        let future = try ready(p,task(p));let futureClaim = try call("work_claim",["project_id":p["id"]!,"task_id":future["id"]!,"expected_revision":future["revision"]!]);let futureArtifact = try call("attachment_add",["project_id":p["id"]!,"task_id":future["id"]!,"path":path.path])
        let futureSubmission = try call("work_submit",["project_id":p["id"]!,"attempt_id":futureClaim["id"]!,"claim_token":futureClaim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":futureArtifact["id"]!,"sha256":futureArtifact["sha256"]!]]]])
        XCTAssertTrue((futureSubmission["review_request_ids"] as! [String]).isEmpty)
        assertCode("INVALID_INPUT") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"mode":"silently_replace_active","policy":["required_gates":[]]]) }
    }
    func testLegacyAttemptRecoversOriginalPolicyFromDurableReceipt() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":["review","human_approval"]]])
        let t = try ready(p,task(p));let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]);p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        try router.dbQueue.write { db in var a = try router.record(db,claim["id"] as! String,type:"attempt");a.removeValue(forKey:"policy_snapshot");try router.save(db,a,type:"attempt");try db.execute(sql:"DELETE FROM records WHERE type='policy_revision'") }
        let path = directory.appendingPathComponent("legacy-target.txt");try Data("Legacy pinned result".utf8).write(to:path);let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":path.path])
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        XCTAssertEqual((submission["review_request_ids"] as! [String]).count,2)
        let oldPolicy = try call("policy_get",["project_id":p["id"]!,"revision":2]);XCTAssertEqual((oldPolicy["policy"] as! JSON)["required_gates"] as? [String],["review","human_approval"])
    }
    func testAgentMessageContextUsesStableChronologicalOrder() throws {
        let p = try project();let t = try task(p);var notes: [JSON] = []
        for body in ["Inserted first but later time","Earlier second","Earlier third"] { notes.append(try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":body])) }
        try router.dbQueue.write { db in for index in notes.indices { var note = notes[index];note.removeValue(forKey:"deliveries");note.removeValue(forKey:"delivery_status");note["created_at"] = index == 0 ? "2026-10-16T12:01:00Z" : "2026-10-16T12:00:00Z";try router.save(db,note,type:"message") } }
        let expected = [notes[1]["id"] as! String,notes[2]["id"] as! String,notes[0]["id"] as! String]
        let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual((context["messages"] as! [JSON]).compactMap {$0["id"] as? String},expected)
        let history = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual((history["messages"] as! [JSON]).compactMap {$0["id"] as? String},expected)
    }
    func testEpicsArePersistentSubprojectsAndTriagesHandleAcrossThem() throws {
        let p = try project();let pid = p["id"] as! String;var first = try call("epic_create",["project_id":pid,"name":"Input subsystem","brief":"Persistent input production work"]);var second = try call("epic_create",["project_id":pid,"name":"Interface subsystem","brief":"Persistent interface production work"])
        let t1 = try call("task_create",["project_id":pid,"title":"Input task","brief":"Input responds correctly","epic_id":first["id"]!]),t2 = try call("task_create",["project_id":pid,"title":"Interface task","brief":"Input responds correctly","epic_id":second["id"]!])
        first = (try call("epic_list",["project_id":pid,"key":first["key"]!])["groups"] as! [JSON])[0]
        second = (try call("epic_list",["project_id":pid,"key":second["key"]!])["groups"] as! [JSON])[0]
        first = try call("group_membership",["project_id":pid,"group_id":first["id"]!,"expected_revision":first["revision"]!,"task_id":t1["id"]!,"action":"add"])
        second = try call("group_membership",["project_id":pid,"group_id":second["id"]!,"expected_revision":second["revision"]!,"task_id":t2["id"]!,"action":"add"])
        var triage = try call("triage_create",["project_id":pid,"name":"Handle interaction regressions","purpose":"Temporary work spanning both subprojects"])
        triage = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":t1["id"]!,"action":"add"])
        let joined = (triage["members"] as! [JSON])[0]["joined_at"] as! String
        triage = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":t2["id"]!,"action":"add","exit_milestone":"review_accepted"])
        let task1 = try call("task_get",["project_id":pid,"task_id":t1["id"]!]);XCTAssertEqual(task1["epic_id"] as? String,first["id"] as? String)
        assertCode("EPIC_MOVE_REQUIRED") { _ = try self.call("group_membership",["project_id":pid,"group_id":second["id"]!,"expected_revision":second["revision"]!,"task_id":t1["id"]!,"action":"add"]) }
        second = try call("group_membership",["project_id":pid,"group_id":second["id"]!,"expected_revision":second["revision"]!,"task_id":t1["id"]!,"action":"move","expected_task_revision":task1["revision"]!,"from_epic_id":first["id"]!,"from_epic_revision":first["revision"]!])
        XCTAssertEqual((second["task_ids"] as! [String]).count,2)
        let epics = try call("epic_list",["project_id":pid])["groups"] as! [JSON];XCTAssertTrue((epics.first {$0["id"] as? String == first["id"] as? String}!["task_ids"] as! [String]).isEmpty)
        triage = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":t1["id"]!,"action":"update","exit_milestone":"review_accepted"])
        XCTAssertEqual((triage["members"] as! [JSON]).first {$0["task_id"] as? String == t1["id"] as? String}!["joined_at"] as? String,joined)
        triage = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":t1["id"]!,"action":"update","exit_milestone":"implementation_submitted"])
        let moved = try call("task_get",["project_id":pid,"task_id":t1["id"]!]);let readyTask = try ready(p,moved);let claim = try call("work_claim",["project_id":pid,"task_id":t1["id"]!,"expected_revision":readyTask["revision"]!])
        let path = directory.appendingPathComponent("triage-target.txt");try Data("Handled input work".utf8).write(to:path);let artifact = try call("attachment_add",["project_id":pid,"task_id":t1["id"]!,"path":path.path])
        let submission = try call("work_submit",["project_id":pid,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        let currentTriage = (try call("triage_list",["project_id":pid])["groups"] as! [JSON])[0];XCTAssertEqual(currentTriage["task_ids"] as? [String],[t2["id"] as! String]);XCTAssertEqual(try call("task_get",["project_id":pid,"task_id":t1["id"]!])["epic_id"] as? String,second["id"] as? String)
        let submitted = submission["task"] as! JSON;let rid = (submission["review_request_ids"] as! [String])[0];let reviewer = Caller(role:"owner",installation:"triage-reviewer",projectIDs:[])
        let review = try call("work_claim",["project_id":pid,"task_id":t1["id"]!,"expected_revision":submitted["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review"],reviewer)
        var reviewTriage = try call("triage_create",["project_id":pid,"name":"Review follow-through","phase":"review","purpose":"Handle only the current submitted review target"])
        reviewTriage = try call("group_membership",["project_id":pid,"group_id":reviewTriage["id"]!,"expected_revision":reviewTriage["revision"]!,"task_id":t1["id"]!,"action":"add","handling_phase":"review"])
        _ = try call("review_record",["project_id":pid,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review","verdict":"pass"],reviewer)
        let reviewed = try call("task_get",["project_id":pid,"task_id":t1["id"]!]);_ = try call("task_complete",["project_id":pid,"task_id":t1["id"]!,"expected_revision":reviewed["revision"]!])
        let finalTriages = try call("triage_list",["project_id":pid])["groups"] as! [JSON];XCTAssertTrue((finalTriages.first {$0["id"] as? String == reviewTriage["id"] as? String}!["task_ids"] as! [String]).isEmpty)
        let context = try call("task_context",["project_id":pid,"task_id":t1["id"]!]);XCTAssertEqual((context["epic"] as! JSON)["brief"] as? String,"Persistent interface production work")

    }
    func testSessionContextAttachDoesNotClaimOrAssignAndFencesStaleBindings() throws {
        let workspace = directory.appendingPathComponent("task-session");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Native task context","key_prefix":"CTX","root_path":workspace.path]);let pid = project["id"] as! String;let task = try self.task(project);let sid = UUID().uuidString
        let session = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"codex","installation":"native","execution_domain":"signed-host:context"])
        let worker = Caller(role:"worker",installation:"native",projectIDs:[pid],sessionID:sid,workspace:workspace.path,executionDomain:"signed-host:context")
        let input: JSON = ["project_id":pid,"task_id":task["id"]!];let command = UUID().uuidString
        let linked = try call("session_attach_task",input,worker,command);let replay = try call("session_attach_task",input,worker,command);let again = try call("session_attach_task",input,worker)
        XCTAssertEqual(linked["id"] as? String,replay["id"] as? String);XCTAssertEqual(linked["id"] as? String,again["id"] as? String);XCTAssertEqual(linked["purpose"] as? String,"context");XCTAssertEqual(linked["binding_current"] as? Bool,true)
        let after = try call("task_get",input);XCTAssertEqual(after["revision"] as? Int,task["revision"] as? Int);XCTAssertEqual(after["readiness"] as? String,"draft");XCTAssertNil(after["active_attempt_id"]);XCTAssertNil(after["planned_assignee"])
        XCTAssertEqual((try call("session_list",["project_id":pid,"task_id":task["id"]!],worker)["sessions"] as! [JSON]).count,1)
        var spoof = input;spoof["session_id"] = "another-thread";assertCode("INVALID_INPUT") { _ = try self.call("session_attach_task",spoof,worker) }
        let foreignProject = try self.project("Unrelated context");assertCode("FORBIDDEN") { _ = try self.call("session_attach_task",["project_id":foreignProject["id"]!,"task_id":task["id"]!],worker) }
        let wrong = Caller(role:"worker",installation:"native",projectIDs:[pid],sessionID:sid,workspace:directory.path,executionDomain:"signed-host:context");assertCode("ROOT_MISMATCH") { _ = try self.call("session_attach_task",input,wrong) }
        _ = try call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"state":"revoked"])
        assertCode("RECIPIENT_CHANGED") { _ = try self.call("session_attach_task",input,worker) }
        let context = try call("task_context",input);XCTAssertEqual((context["task_sessions"] as! [JSON])[0]["binding_current"] as? Bool,false)
    }

    func testCleanupRestartProtectsCurrentQueuedReviewOriginal() throws {
        let value = try submittedArtifact(data:Data(repeating:8,count:21*1024*1024))
        let job = try markCommittedCleanupForCrashFixture(taskID:value.task["id"] as! String,attachmentID:value.artifact["id"] as! String)
        router = nil;router = try TestStore.router(root:directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath:value.artifact["path"] as! String))
        let metadata = try call("attachment_read",["project_id":value.project["id"]!,"attachment_id":value.artifact["id"]!]);XCTAssertEqual(metadata["availability"] as? String,"available");try assertCleanupJobHeld(job,attachmentID:value.artifact["id"] as! String,reason:.currentReview)
    }

    func testIdenticalMessageTimestampsPreserveCreationOrderInsteadOfUUIDOrder() {
        let createdFirst: JSON = ["id":"ffffffff-ffff-ffff-ffff-ffffffffffff","created_at":"2026-10-16T12:00:00Z","body":"Created first"]
        let createdSecond: JSON = ["id":"00000000-0000-0000-0000-000000000000","created_at":"2026-10-16T12:00:00Z","body":"Created second"]
        let sorted = chronologicalMessages([createdFirst,createdSecond])
        XCTAssertEqual(sorted.compactMap {$0["body"] as? String},["Created first","Created second"])
    }

}
