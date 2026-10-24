import ChecklistTestSupport
import XCTest
import GRDB
import ImageIO
import CoreGraphics
@testable import ChecklistCore

/// New disposable-router integration cases only. Not native host/UI qualification.
final class ReviewRequirementIntegrationTests: XCTestCase {
    var directory: URL!,workspace: URL!,router: CommandRouter!
    let author = Caller(role:"owner",installation:"rubric-fixture-author",projectIDs:[])
    let critic = Caller(role:"owner",installation:"rubric-fixture-critic",projectIDs:[])
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        router = try TestStore.router(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:directory)}
    @discardableResult func call(_ method: String,_ raw: JSON,_ actor: Caller? = nil) throws -> JSON {
        var p = raw;if !CommandRouter.readMethods.contains(method) {p["command_id"] = uuid()}
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:actor ?? author)["data"] as! JSON
    }
    func assertCode(_ code: String,_ body: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) {XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line)}
    }
    func rubric(_ types: [String],check: String = "Inspect the fixture result.") -> JSON {
        ["default":["checks":[["id":"fixture-check","text":check]],"reject_bar":"Reject an unmet fixture requirement.","required_evidence_types":types]]
    }
    func project() throws -> JSON {try call("project_create",["name":"Rubric fixture","key_prefix":"RUB","root_path":workspace.path])}
    func currentProject(_ p: JSON) throws -> JSON {try call("project_settings_get",["project_id":p["id"]!])}
    func setRubric(_ p: JSON,_ types: [String],check: String = "Inspect the fixture result.",mode: String = "future_attempts") throws -> JSON {
        let current = try currentProject(p);var policy = current["policy"] as! JSON;policy["review_requirements"] = rubric(types,check:check)
        return try call("policy_apply",["project_id":p["id"]!,"expected_revision":current["revision"]!,"policy":policy,"mode":mode])
    }
    func submitted(_ p: JSON,source: Bool = false) throws -> JSON {
        var task = try call("task_create",["project_id":p["id"]!,"title":"Observable fixture","brief":"Produce the inspectable fixture result.","kind":"bug","acceptance":["A fixture result is inspectable."]])
        task = try call("task_edit",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        let path = workspace.appendingPathComponent("result-"+(task["id"] as! String)+".txt");try Data("Exact fixture result".utf8).write(to:path)
        let file = try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":path.path])
        var evidence: JSON = ["artifact_refs":[ref(file)]]
        if source {evidence["kind"] = "source";evidence["source_capture"] = [:]}
        return try call("work_submit",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":evidence])
    }
    func selectors(_ p: JSON,_ submission: JSON) -> JSON {
        let task = submission["task"] as! JSON
        return ["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":(submission["review_request_ids"] as! [String])[0],"target_manifest_id":submission["manifest_id"]!,"gate":"review"]
    }
    func ref(_ file: JSON) -> JSON {["artifact_id":file["id"]!,"sha256":file["sha256"]!]}
    func report(_ p: JSON,_ attempt: JSON) throws -> JSON {
        try call("review_evidence_add",["project_id":p["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"title":"Actual fixture review evidence","body":"Selected fixture observations; not native or execution qualification."],critic)
    }
    func context(_ selectors: JSON,selected: [JSON]? = nil) throws -> JSON {
        var p = selectors.filter {["project_id","task_id","review_request_id","target_manifest_id","gate"].contains($0.key)};if let selected {p["evidence_refs"] = selected};return try call("review_context",p,critic)
    }
    func verdict(_ p: JSON,_ a: JSON,_ selected: [JSON],value: String = "pass") throws -> JSON {
        let selection: JSON = ["project_id":p["id"]!,"task_id":a["task_id"]!,"review_request_id":a["review_request_id"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review"]
        let ctx = try context(selection),contract = ctx["review_contract"] as! JSON
        func rows(_ key: String) -> [JSON] {(contract[key] as! [JSON]).map {["requirement_id":$0["id"]!,"result":"pass","rationale":"Synthetic API fixture assessment.","evidence_refs":selected]}}
        let assessment: JSON = ["contract_sha256":contract["sha256"]!,"target_manifest_id":a["manifest_id"]!,"acceptance":rows("acceptance"),"project_requirements":rows("project_requirements"),"evidence_refs":selected,"instruction_coverage":contract["project_instruction_refs"]!,"all_applicable_project_requirements_assessed":true,"additional_requirements":[]]
        return try call("review_record",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"review_request_id":a["review_request_id"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review","verdict":value,"checks":[],"review_assessment":assessment,"direction_cursor":ctx["direction_cursor"]!],critic)
    }
    func attach(_ p: JSON,_ taskID: Any,_ name: String,_ bytes: Data) throws -> JSON {
        let path = directory.appendingPathComponent(UUID().uuidString+"-"+name);try bytes.write(to:path)
        return try call("attachment_add",["project_id":p["id"]!,"task_id":taskID,"path":path.path,"name":name],critic)
    }
    func png() throws -> Data {
        let provider = CGDataProvider(data:Data([255,0,0,255]) as CFData)!
        let image = CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data = NSMutableData(),destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
    }

    func testCanonicalConfigurationUsesRealOwnerPolicyRevision() throws {
        let p = try project(),updated = try setRubric(p,["text_record","image"]),policy = updated["policy"] as! JSON
        let base = (policy["review_requirements"] as! JSON)["default"] as! JSON
        XCTAssertEqual(strings(base,"required_evidence_types"),["image","text_record"])
        XCTAssertGreaterThan(int(updated,"policy_revision"),int(p,"policy_revision"))
        let context = try call("task_context",["project_id":p["id"]!,"task_id":(try submitted(p)["task"] as! JSON)["id"]!])
        XCTAssertEqual(((context["review_requirements"] as! JSON)["snapshot"] as! JSON)["policy_revision"] as? Int,int(updated,"policy_revision"))
    }

    func testNewIndividualReviewPinsLatestRubricAndOldVerdictStaysImmutable() throws {
        let p = try project(),s = try submitted(p),updated = try setRubric(p,["reviewer_report"])
        let a = try call("work_claim",selectors(p,s),critic),before = try context(selectors(p,s))
        XCTAssertEqual(int(a,"policy_revision"),int(p,"policy_revision")) // Manifest gates stay on the old round.
        XCTAssertEqual(int(a["review_requirement_snapshot"] as! JSON,"policy_revision"),int(updated,"policy_revision"))
        let own = try report(p,a);_ = try setRubric(p,["image"],check:"A newer check.")
        let after = try context(selectors(p,s))
        XCTAssertEqual((before["review_contract"] as! JSON)["sha256"] as? String,(after["review_contract"] as! JSON)["sha256"] as? String)
        let recorded = try verdict(p,a,[ref(own)])
        let saved = try router.dbQueue.read { db in
            try jsonString(router.record(db,recorded["id"] as! String,type:"review"))
        }
        let beforePostVerdictEdit = try currentProject(p)
        let postVerdictPolicy = try setRubric(p,["text_record"],check:"A post-verdict check.")
        XCTAssertGreaterThan(int(postVerdictPolicy,"policy_revision"),int(beforePostVerdictEdit,"policy_revision"))
        XCTAssertNotEqual(try jsonString((beforePostVerdictEdit["policy"] as! JSON)["review_requirements"] as! JSON),
                          try jsonString((postVerdictPolicy["policy"] as! JSON)["review_requirements"] as! JSON))
        let afterPolicyEdit = try router.dbQueue.read {try router.record($0,recorded["id"] as! String,type:"review")}
        XCTAssertEqual(try jsonString(afterPolicyEdit),saved)
        var task = try call("task_get",["project_id":p["id"]!,"task_id":a["task_id"]!])
        let request = try call("review_request",["project_id":p["id"]!,"task_id":a["task_id"]!,"expected_revision":task["revision"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review","supersedes_request_id":a["review_request_id"]!,"reason":"New independent review uses the new rubric."])
        task = try call("task_get",["project_id":p["id"]!,"task_id":a["task_id"]!])
        let fresh = try call("work_claim",["project_id":p["id"]!,"task_id":a["task_id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":request["id"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review"],critic)
        XCTAssertGreaterThan(int(fresh["review_requirement_snapshot"] as! JSON,"policy_revision"),int(recorded["review_requirement_snapshot"] as! JSON,"policy_revision"))
        XCTAssertEqual(int(fresh["review_requirement_snapshot"] as! JSON,"policy_revision"),int(postVerdictPolicy,"policy_revision"))
        XCTAssertEqual(strings((fresh["review_requirement_snapshot"] as! JSON)["requirement"] as! JSON,"required_evidence_types"),["text_record"])
        let unchanged = try router.dbQueue.read {try router.record($0,recorded["id"] as! String,type:"review")}
        XCTAssertEqual(try jsonString(unchanged),saved)
    }

    func testAtomicBatchUsesTheSamePinAndRejectsPolicyChangedAfterPreparation() throws {
        let p = try project(),submissions = try [submitted(p),submitted(p)],updated = try setRubric(p,["text_record"])
        var group = try call("triage_create",["project_id":p["id"]!,"name":"Review fixture","phase":"review","purpose":"Only this disposable API fixture."])
        for submission in submissions {
            _ = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":(submission["task"] as! JSON)["id"]!,"action":"add"])
            group = (try call("triage_list",["project_id":p["id"]!])["groups"] as! [JSON]).first {$0["id"] as? String == group["id"] as? String}!
        }
        func prepare() throws -> JSON {
            let members = try submissions.map { submission -> JSON in
                var member = selectors(p,submission).filter {["task_id","expected_revision","review_request_id","target_manifest_id","gate"].contains($0.key)};member["expected_revision"] = try call("task_get",["project_id":p["id"]!,"task_id":member["task_id"]!])["revision"]!;return member
            }
            return try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":group["revision"]!,"phase":"review","tasks":members],critic)
        }
        let stale = try prepare();_ = try setRubric(p,["image"])
        assertCode("POLICY_CHANGED") {_ = try self.call("batch_claim",["project_id":p["id"]!,"batch_id":stale["id"]!,"expected_revision":1,"policy_revision":updated["policy_revision"]!],self.critic)}
        let batch = try prepare(),claimed = try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"policy_revision":batch["policy_revision"]!],critic)
        XCTAssertEqual((claimed["claims"] as! [JSON]).count,2)
        for a in claimed["claims"] as! [JSON] {XCTAssertEqual(int(a["review_requirement_snapshot"] as! JSON,"policy_revision"),int(batch,"policy_revision"))}
    }

    func testActualSelectedImageBytesNotFilenameOrUnselectedAttachmentFillGap() throws {
        let p = try project();_ = try setRubric(p,["reviewer_report","image"])
        let s = try submitted(p),a = try call("work_claim",selectors(p,s),critic),own = try report(p,a)
        let fake = try attach(p,a["task_id"]!,"screenshot.png",Data("Not image bytes".utf8))
        let image = try attach(p,a["task_id"]!,"no-extension",png())
        let missing = try context(selectors(p,s),selected:[ref(own),ref(fake)])["review_evidence_requirements"] as! JSON
        XCTAssertEqual(strings(missing,"missing_evidence_types"),["image"])
        assertCode("REVIEW_EVIDENCE_MISSING") {_ = try self.verdict(p,a,[self.ref(own),self.ref(fake)])}
        XCTAssertNotNil(try call("task_get",["project_id":p["id"]!,"task_id":a["task_id"]!])["active_attempt_id"])
        let available = try context(selectors(p,s),selected:[ref(own),ref(image)])["review_evidence_requirements"] as! JSON
        XCTAssertTrue(strings(available,"missing_evidence_types").isEmpty)
        XCTAssertEqual(try verdict(p,a,[ref(own),ref(image)])["verdict"] as? String,"pass")
    }

    func testCurrentReportProvenanceAndChangedOrWrongTaskBytesCannotBeInvented() throws {
        let p = try project();_ = try setRubric(p,["reviewer_report"])
        let s = try submitted(p),a = try call("work_claim",selectors(p,s),critic)
        let named = try attach(p,a["task_id"]!,"reviewer_report.md",Data("Only an imported file".utf8))
        XCTAssertEqual(strings(try context(selectors(p,s),selected:[ref(named)])["review_evidence_requirements"] as! JSON,"missing_evidence_types"),["reviewer_report"])
        let other = try submitted(p),foreign = try attach(p,(other["task"] as! JSON)["id"]!,"report.md",Data("Wrong ticket".utf8))
        assertCode("EVIDENCE_STALE") {_ = try self.context(self.selectors(p,s),selected:[self.ref(foreign)])}
        let own = try report(p,a);try Data("Changed managed bytes".utf8).write(to:URL(fileURLWithPath:own["path"] as! String))
        assertCode("EVIDENCE_STALE") {_ = try self.context(self.selectors(p,s),selected:[self.ref(own)])}
    }

    func testSourceCaptureClassBindsActualValidatedTarget() throws {
        let p = try project();_ = try setRubric(p,["reviewer_report","source_capture"])
        let s = try submitted(p,source:true),a = try call("work_claim",selectors(p,s),critic),own = try report(p,a)
        let ctx = try context(selectors(p,s)),source = ((ctx["target_manifest"] as! JSON)["evidence"] as! JSON)["source_capture"] as! JSON
        let captureRef: JSON = ["source_capture_id":source["id"]!,"sha256":source["sha256"]!]
        XCTAssertTrue(strings(try context(selectors(p,s),selected:[ref(own),captureRef])["review_evidence_requirements"] as! JSON,"missing_evidence_types").isEmpty)
        var wrong = captureRef;wrong["source_capture_id"] = uuid()
        assertCode("REVIEW_TARGET_MISMATCH") {_ = try self.context(self.selectors(p,s),selected:[self.ref(own),wrong])}
    }

    func testMissingClassAllowsHonestBlockedVerdictAndRecordsAppliedRevision() throws {
        let p = try project();_ = try setRubric(p,["image"])
        let s = try submitted(p),a = try call("work_claim",selectors(p,s),critic),own = try report(p,a)
        let blocked = try verdict(p,a,[ref(own)],value:"blocked")
        XCTAssertEqual(blocked["verdict"] as? String,"blocked")
        XCTAssertNotNil(blocked["review_requirement_snapshot"])
        XCTAssertEqual(strings((blocked["review_assessment"] as! JSON)["review_evidence_requirements"] as! JSON,"missing_evidence_types"),["image"])
    }

    func testPreclaimPreviewAndLegacyUnpinnedClaimNeverInventAppliedRequirements() throws {
        let p = try project(),s = try submitted(p),selector = selectors(p,s)
        let preview = try context(selector)["review_evidence_requirements"] as! JSON
        XCTAssertEqual(preview["state"] as? String,"claim_required")
        XCTAssertEqual(preview["availability_evaluated"] as? Bool,false)
        assertCode("REVIEW_CLAIM_REQUIRED") {_ = try self.context(selector,selected:[])}
        let a = try call("work_claim",selector,critic)
        XCTAssertEqual((try context(selector)["review_evidence_requirements"] as! JSON)["state"] as? String,"selection_required")
        try router.dbQueue.write { db in
            var legacy = try self.router.record(db,a["id"] as! String,type:"attempt")
            legacy.removeValue(forKey:"review_requirement_snapshot")
            try self.router.save(db,legacy,type:"attempt")
        }
        assertCode("REVIEW_REQUIREMENT_RECLAIM_REQUIRED") {_ = try self.context(selector)}
    }

    func testUnsupportedActiveRubricReconciliationHasNoPolicySideEffect() throws {
        let p = try project(),s = try submitted(p);_ = try call("work_claim",selectors(p,s),critic)
        let before = try currentProject(p)
        assertCode("REVIEW_REQUIREMENT_RECONCILIATION_UNSUPPORTED") {_ = try self.setRubric(p,["image"],mode:"checkpoint_active")}
        XCTAssertEqual(try jsonString(currentProject(p)),try jsonString(before))
        var unchangedRubric = before["policy"] as! JSON;unchangedRubric["review_batch_policy"] = "hold_passing_for_batch"
        let allowed = try call("policy_apply",["project_id":p["id"]!,"expected_revision":before["revision"]!,"policy":unchangedRubric,"mode":"checkpoint_active"])
        XCTAssertGreaterThan(int(allowed,"policy_revision"),int(before,"policy_revision"))
    }
}
