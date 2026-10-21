import XCTest
@testable import ChecklistCore

final class AcceptanceEvidenceTests: XCTestCase {
    func fixture(_ acceptance: [String] = ["First observable result","Second observable result"]) throws -> (SubmissionEvidenceFixture,JSON,Caller,JSON) {
        let f = try SubmissionEvidenceFixture("CL-183");try f.write("source.txt")
        let task = try f.ready(acceptance),author = try f.worker("author"),attempt = try f.claim(task,author)
        return (f,task,author,attempt)
    }
    func limitations(_ items: [String]) -> [JSON] { items.indices.map {["item":$0,"limitation":"Synthetic component evidence only; installed observation remains separate."]} }
    func missing(_ body: () throws -> Void,items: [Int],reason: String? = nil,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) {
            let error = $0 as? CoreError
            XCTAssertEqual(error?.code,"ACCEPTANCE_EVIDENCE_MISSING",file:file,line:line)
            XCTAssertEqual((error?.details["uncovered_items"] as? [JSON])?.map {int($0,"item")},items,file:file,line:line)
            if let reason { XCTAssertTrue(error?.message.contains(reason) == true,error?.message ?? "",file:file,line:line) }
        }
    }
    func assertUnsubmitted(_ f: SubmissionEvidenceFixture,_ task: JSON,_ attempt: JSON,file: StaticString = #filePath,line: UInt = #line) throws {
        let current = try f.record(task["id"]!,"task")
        XCTAssertNil(current["current_manifest_id"],file:file,line:line);XCTAssertEqual(current["active_attempt_id"] as? String,attempt["id"] as? String,file:file,line:line)
        XCTAssertEqual(try f.record(attempt["id"]!,"attempt")["state"] as? String,"active",file:file,line:line)
        try f.router.dbQueue.read { db in
            for type in ["review_request","manifest","source_capture"] { XCTAssertTrue(try f.router.records(db,type:type,project:f.project["id"] as? String).isEmpty,file:file,line:line) }
        }
    }
    func attach(_ f: SubmissionEvidenceFixture,_ task: JSON,_ author: Caller,description: String = "Synthetic report build-1") throws -> JSON {
        let path = "reports/"+UUID().uuidString+".txt";try f.write(path,"Synthetic report; no installed application was run.")
        return try f.call("attachment_add",["task_id":task["id"]!,"path":f.workspace.appendingPathComponent(path).path,"description":description],author)
    }
    func reportRef(_ attachment: JSON,build: String = "build-1") -> JSON { ["kind":"check_runner_report","attachment_id":attachment["id"]!,"sha256":attachment["sha256"]!,"build_id":build] }
    func testCompleteSubmissionStoresImmutableMapAndReviewContextShowsIt() throws {
        let (f,task,author,a) = try fixture(["Attachment result","Recorded check","Carried observation"]),file = try attach(f,task,author)
        var input = try f.submissionInput(a,author),evidence = input["evidence_manifest"] as! JSON
        evidence["checks"] = [["label":"bounded unit check","result":"passed"]];input["evidence_manifest"] = evidence
        input["acceptance_evidence"] = [["item":0,"evidence_refs":[["kind":"attachment","attachment_id":file["id"]!,"sha256":file["sha256"]!]]],["item":1,"evidence_refs":[["kind":"check","name":"bounded unit check"]]],["item":2,"evidence_refs":[["kind":"carried","producer":"original-check-runner","target":"original-build","sha256":String(repeating:"a",count:64)]]]]
        let s = try f.call("work_submit",input,author),reviewer = try f.worker("reviewer"),context = try f.call("review_context",f.selectors(s),reviewer)
        let map = try XCTUnwrap(context["acceptance_evidence"] as? [JSON]),manifest = try f.record(s["manifest_id"]!,"manifest"),stored = manifest["evidence"] as! JSON
        XCTAssertEqual(map.count,3);XCTAssertEqual(map.map {$0["item_text"] as! String},strings(task,"acceptance"))
        XCTAssertTrue(map.allSatisfy {bool($0["coverage"] as! JSON,"covered")})
        XCTAssertEqual(try jsonString(map),try jsonString(stored["acceptance_evidence"]!))
        XCTAssertEqual(manifest["digest"] as? String,ChecklistCore.hash(Data(try jsonString(stored).utf8)))
        let referencedArtifacts = f.router.acceptanceArtifactRefs(stored)
        XCTAssertEqual(referencedArtifacts.first?["artifact_id"] as? String,file["id"] as? String)
        _ = try f.call("work_claim",f.selectors(s),reviewer)
    }
    func testMissingFieldAndUncoveredItemsRefuseBeforeCaptureOrReviewRequest() throws {
        let (f,task,author,a) = try fixture(),input = try f.submissionInput(a,author)
        missing({_ = try f.call("work_submit",input,author)},items:[1,2],reason:"First observable result")
        try assertUnsubmitted(f,task,a)
        var partial = input;partial["acceptance_evidence"] = [["item":0,"limitation":"Only a component check"],["item":1]]
        missing({_ = try f.call("work_submit",partial,author)},items:[2],reason:"no evidence or limitation")
        try assertUnsubmitted(f,task,a)
        // No prepared capture directory should survive either refusal.
        let objects = f.router.root.appendingPathComponent("source-captures")
        XCTAssertFalse(FileManager.default.fileExists(atPath:objects.path))
    }
    func testStatedLimitationCoversPlainItem() throws {
        let (f,task,author,a) = try fixture(["Observable result"]);var input = try f.submissionInput(a,author)
        input["acceptance_evidence"] = limitations(strings(task,"acceptance"))
        let s = try f.call("work_submit",input,author),m = try f.record(s["manifest_id"]!,"manifest"),map = (m["evidence"] as! JSON)["acceptance_evidence"] as! [JSON]
        XCTAssertNotNil(map[0]["limitation"]);XCTAssertTrue(bool(map[0]["coverage"] as! JSON,"covered"))
    }
    func testInstalledContributorReportIsRefused() throws {
        let (f,task,author,a) = try fixture(["Installed result"]),report = try attach(f,task,author)
        var input = try f.submissionInput(a,author);input["evidence_manifest"] = ["source_capture":[:],"installed_build_id":"build-1"]
        input["acceptance_evidence"] = [["item":0,"observation":"installed","evidence_refs":[reportRef(report)]]]
        missing({_ = try f.call("work_submit",input,author)},items:[1],reason:"report was added by a contributor")
        try assertUnsubmitted(f,task,a)
    }
    func testInstalledAndNativeNonContributorReportsForSameBuildPass() throws {
        for observation in ["installed","native"] {
            let (f,task,author,a) = try fixture(["Observed result"]),runner = try f.worker("check-runner"),report = try attach(f,task,runner)
            var input = try f.submissionInput(a,author);input["evidence_manifest"] = ["source_capture":[:],"installed_build_id":"build-1"]
            input["acceptance_evidence"] = [["item":0,"observation":observation,"evidence_refs":[reportRef(report)]]]
            _ = try f.call("work_submit",input,author)
        }
    }
    func testAnotherBuildReportAndMissingBuildIDAreRefused() throws {
        let (f,task,author,a) = try fixture(["Installed result"]),runner = try f.worker("runner"),report = try attach(f,task,runner)
        var input = try f.submissionInput(a,author);input["evidence_manifest"] = ["source_capture":[:],"installed_build_id":"build-2"]
        input["acceptance_evidence"] = [["item":0,"observation":"installed","evidence_refs":[reportRef(report)]]]
        missing({_ = try f.call("work_submit",input,author)},items:[1],reason:"does not match submitted build build-2")
        input["evidence_manifest"] = ["source_capture":[:]]
        missing({_ = try f.call("work_submit",input,author)},items:[1],reason:"installed_build_id is required")
        try assertUnsubmitted(f,task,a)
    }
    func testInstalledLimitationAndDescriptionWithoutBuildAreRefused() throws {
        let (f,task,author,a) = try fixture(["Installed result"]),runner = try f.worker("runner"),report = try attach(f,task,runner,description:"Synthetic report without build identity")
        var input = try f.submissionInput(a,author);input["evidence_manifest"] = ["source_capture":[:],"installed_build_id":"build-1"]
        input["acceptance_evidence"] = [["item":0,"observation":"installed","limitation":"Could not run installed app"]]
        missing({_ = try f.call("work_submit",input,author)},items:[1],reason:"needs a non-contributor check-runner report")
        input["acceptance_evidence"] = [["item":0,"observation":"installed","evidence_refs":[reportRef(report)]]]
        missing({_ = try f.call("work_submit",input,author)},items:[1],reason:"description does not name build")
    }
    func testPriorAndDelegatedContributorsCannotSupplyRunnerReport() throws {
        for delegated in [false,true] {
            let (f,task,author,a) = try fixture(["Installed result"]),other = try f.worker("other"),report: JSON,submitter: Caller,attempt: JSON
            if delegated {
                let offer = try f.call("work_delegate",["attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"child_session_id":other.sessionID!,"file_scopes":[]],author)
                let child = try f.call("work_child_accept",["delegation_id":offer["id"]!],other)
                report = try attach(f,task,other)
                _ = try f.call("work_release",["attempt_id":child["id"]!,"claim_token":child["claim_token"]!,"reason":"Synthetic child finished"],other)
                submitter = author;attempt = a
            } else {
                report = try attach(f,task,author)
                _ = try f.call("work_release",["attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"reason":"Synthetic handoff"],author)
                let current = try f.record(task["id"]!,"task");attempt = try f.claim(current,other);submitter = other
            }
            var input = try f.submissionInput(attempt,submitter);input["evidence_manifest"] = ["source_capture":[:],"installed_build_id":"build-1"]
            input["acceptance_evidence"] = [["item":0,"observation":"installed","evidence_refs":[reportRef(report)]]]
            missing({_ = try f.call("work_submit",input,submitter)},items:[1],reason:"report was added by a contributor")
        }
    }
    func testOwnerObservationAndTrustedOwnerSubmissionKeepAppPath() throws {
        let (f,_,author,a) = try fixture(["Owner decides"]);var input = try f.submissionInput(a,author)
        input["acceptance_evidence"] = [["item":0,"observation":"owner"]];_ = try f.call("work_submit",input,author)
        let task = try f.ready(["Trusted owner result"]),attempt = try f.call("work_claim",["task_id":task["id"]!,"expected_revision":task["revision"]!])
        _ = try f.call("work_submit",f.submissionInput(attempt,f.storage.owner))
    }
    func testDuplicateOutOfRangeAndBooleanIndexesAreInvalid() throws {
        let (f,_,author,a) = try fixture(["Observable result"]),base = try f.submissionInput(a,author)
        let cases: [[JSON]] = [[["item":0,"limitation":"fixture"],["item":0,"limitation":"duplicate"]],[["item":1,"limitation":"range"]],[["item":true,"limitation":"boolean"]]]
        for entries in cases {
            var input = base;input["acceptance_evidence"] = entries
            XCTAssertThrowsError(try f.call("work_submit",input,author)) { XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT") }
        }
    }
    func testBatchUncoveredMemberRefusesAllMembersBeforeCapture() throws {
        let f = try SubmissionEvidenceFixture("CL-183");try f.write("source.txt")
        let tasks = try [f.ready(["First result"]),f.ready(["Second result"])],author = try f.worker("batch-author")
        var group = try f.call("triage_create",["name":"Synthetic implementation","phase":"implementation"])
        for task in tasks {
            _ = try f.call("group_membership",["group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"])
            group = try f.record(group["id"]!,"group")
        }
        let members: [JSON] = tasks.map {["task_id":$0["id"]!,"expected_revision":$0["revision"]!,"file_scopes":[],"lane_scopes":[]]}
        let batch = try f.call("batch_prepare",["triage_id":group["id"]!,"expected_revision":group["revision"]!,"phase":"implementation","tasks":members],author)
        let claims = try f.call("batch_claim",["batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],author)["claims"] as! [JSON]
        var inputs = try claims.map {try f.submissionInput($0,author)};inputs[0]["acceptance_evidence"] = [["item":0,"limitation":"Synthetic component check"]];inputs[1]["acceptance_evidence"] = [["item":0]]
        missing({_ = try f.call("batch_submit",["batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"members":inputs],author)},items:[1],reason:"Second result")
        for (task,claim) in zip(tasks,claims) { try assertUnsubmitted(f,task,claim) }
    }
    func testDecisionTargetCanCarryAcceptanceAttachmentWithoutBecomingArtifactTarget() throws {
        let f = try SubmissionEvidenceFixture("CL-183")
        var task = try f.call("task_create",["title":"Synthetic question","brief":"Record an answer","kind":"question","acceptance":["Decision has supporting evidence"]])
        task = try f.call("task_edit",["task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        let author = try f.worker("decision-author"),attempt = try f.claim(task,author),attachment = try attach(f,task,author)
        var input = try f.submissionInput(attempt,author)
        input["evidence_manifest"] = ["kind":"decision","decision":["text":"Synthetic recorded answer"]]
        input["acceptance_evidence"] = [["item":0,"evidence_refs":[["kind":"attachment","attachment_id":attachment["id"]!,"sha256":attachment["sha256"]!]]]]
        let s = try f.call("work_submit",input,author),reviewer = try f.worker("decision-reviewer")
        _ = try f.call("review_context",f.selectors(s),reviewer)
        let m = try f.record(s["manifest_id"]!,"manifest"),e = m["evidence"] as! JSON
        XCTAssertEqual(e["kind"] as? String,"decision");XCTAssertTrue((e["artifact_refs"] as? [JSON] ?? []).isEmpty)
    }
    func testCatalogExposesEvidenceMapAndBuildIdentity() throws {
        let f = try SubmissionEvidenceFixture("CL-183"),worker = try f.worker("catalog"),tools = f.router.toolCatalog(worker)
        let submit = tools.first {$0["name"] as? String == "work_submit"}!,properties = (submit["inputSchema"] as! JSON)["properties"] as! JSON
        XCTAssertEqual((properties["acceptance_evidence"] as? JSON)?["type"] as? String,"array")
        XCTAssertNotNil(((properties["evidence_manifest"] as? JSON)?["properties"] as? JSON)?["installed_build_id"])
        let batch = tools.first {$0["name"] as? String == "batch_submit"}!,batchFields = (batch["inputSchema"] as! JSON)["properties"] as! JSON
        XCTAssertNotNil((((batchFields["members"] as? JSON)?["items"] as? JSON)?["properties"] as? JSON)?["acceptance_evidence"])
    }
}
