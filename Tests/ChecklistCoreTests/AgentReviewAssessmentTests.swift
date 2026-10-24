import XCTest
@testable import ChecklistCore

/// Synthetic test evidence only. This helper does not record a live product review.
func fixtureReviewAssessment(_ router: CommandRouter, task: JSON, manifest: JSON, artifact: JSON) throws -> JSON {
    // Review claims pin an applied rubric; a submission/pre-claim task still
    // describes the preview contract (docs/policies.md, Revisioned review requirements).
    let contract = try router.dbQueue.read { db in
        let current = try router.record(db,task["id"] as! String,type:"task")
        return try router.reviewContract(db,task:current,manifest:manifest)
    }
    let ref: JSON = ["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]
    func rows(_ section: String) -> [JSON] {(contract[section] as? [JSON] ?? []).map {["requirement_id":$0["id"]!,"result":"pass","rationale":"Synthetic fixture observed the requirement for this test scenario.","evidence_refs":[ref]]}}
    let instructions = contract["project_instruction_refs"] as? [JSON] ?? []
    return ["contract_sha256":contract["sha256"]!,"target_manifest_id":manifest["id"]!,"acceptance":rows("acceptance"),"project_requirements":rows("project_requirements"),"evidence_refs":[ref],"instruction_coverage":instructions,"all_applicable_project_requirements_assessed":true,"additional_requirements":instructions.map {["requirement":"Synthetic captured instruction coverage","source":$0["path"]!,"result":"pass","rationale":"Synthetic fixture exercised exact instruction references.","evidence_refs":[ref]]}]
}

/// Existing fixtures exercise review rules; their submission limitations claim no observation.
func fixtureAcceptanceEvidence(_ router: CommandRouter,input: JSON) throws -> JSON {
    var p = input
    guard p["acceptance_evidence"] == nil,let aid = p["attempt_id"] as? String,let attempt = try? router.dbQueue.read({try router.record($0,aid,type:"attempt")}),let tid = attempt["task_id"] as? String,let task = try? router.dbQueue.read({try router.record($0,tid,type:"task")}) else { return p }
    p["acceptance_evidence"] = strings(task,"acceptance").indices.map {["item":$0,"limitation":"Synthetic fixture for another command guard; no installed or native observation is claimed."] as JSON}
    return p
}

final class AgentReviewAssessmentTests: XCTestCase {
    var directory: URL!,workspace: URL!,router: CommandRouter!
    let owner = Caller(role:"owner",installation:"review-fixture-owner",projectIDs:[])
    let critic = Caller(role:"owner",installation:"review-fixture-critic",projectIDs:[])
    override func setUpWithError() throws {directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);workspace = directory.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true);router = try CommandRouter(root:directory.appendingPathComponent("store"))}
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:directory)}
    @discardableResult func call(_ method: String,_ input: JSON,_ actor: Caller? = nil) throws -> JSON {var p = method == "work_submit" ? try fixtureAcceptanceEvidence(router,input:input) : input;if !CommandRouter.readMethods.contains(method) {p["command_id"] = UUID().uuidString};return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:actor ?? owner)["data"] as! JSON}
    func assertCode(_ code: String,_ body: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {XCTAssertThrowsError(try body(),file:file,line:line) {XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line)}}
    func fixture(source: Bool = false,instructionSymlink: Bool = false) throws -> (JSON,JSON,JSON,JSON) {
        let p = try call("project_create",["name":"Agent review fixture","key_prefix":"AR","root_path":workspace.path])
        var task = try call("task_create",["project_id":p["id"]!,"title":"Observed outcome","brief":"A complete reviewer assessment","acceptance":["First observable result","Second observable result"]])
        task = try call("task_edit",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        let author = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        let path = workspace.appendingPathComponent("result.txt");try Data("observed output".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":path.path])
        var evidence: JSON = ["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]
        if source {
            if instructionSymlink {
                try Data("Review the changed controls for keyboard access and record the observed result.".utf8).write(to:workspace.appendingPathComponent("rules.md"))
                try FileManager.default.createSymbolicLink(atPath:workspace.appendingPathComponent("AGENTS.md").path,withDestinationPath:"rules.md")
            } else {try Data("Review safety and exact input requirements.".utf8).write(to:workspace.appendingPathComponent("AGENTS.md"))}
            evidence["kind"] = "source";evidence["source_capture"] = [:]
        }
        let submission = try call("work_submit",["project_id":p["id"]!,"attempt_id":author["id"]!,"claim_token":author["claim_token"]!,"acceptance_revision":1,"evidence_manifest":evidence])
        task = submission["task"] as! JSON
        let selectors: JSON = ["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":(submission["review_request_ids"] as! [String])[0],"target_manifest_id":submission["manifest_id"]!,"gate":"review"]
        return (p,task,submission,selectors)
    }
    func ownReport(_ p: JSON,_ task: JSON,_ actor: Caller) throws -> JSON {let file = directory.appendingPathComponent(UUID().uuidString+".md");try Data("Synthetic independent assessment report; no service program was run.".utf8).write(to:file);return try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":file.path],actor)}
    func verdict(_ p: JSON,_ a: JSON) -> JSON {["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"review_request_id":a["review_request_id"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review","verdict":"pass","checks":[]]}
    func testFreshPreparationDoesNotClaimOrLaunchAndKeepsExactContext() throws {
        let (p,t,_,selectors) = try fixture(source:true)
        var prepare = selectors;prepare["provider"] = "codex"
        let result = try call("review_prepare",prepare)
        XCTAssertEqual(result["state"] as? String,"prepared_composer");XCTAssertEqual(result["claim_acquired"] as? Bool,false);XCTAssertEqual(result["launch_available"] as? Bool,false)
        XCTAssertTrue((result["instruction"] as! String).contains("fresh independent"));XCTAssertTrue((result["instruction"] as! String).contains(selectors["review_request_id"] as! String))
        let context = try call("review_context",selectors,critic),contract = context["review_contract"] as! JSON
        XCTAssertEqual((contract["acceptance"] as! [JSON]).count,2);XCTAssertEqual((contract["project_instruction_refs"] as! [JSON]).first?["path"] as? String,"AGENTS.md")
        XCTAssertEqual((context["task"] as! JSON)["brief"] as? String,t["brief"] as? String)
        let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertNil(current["active_attempt_id"])
        assertCode("REVIEW_INDEPENDENCE") {_ = try self.call("work_claim",selectors)}
    }
    func testEachAcceptanceMustBeAssessedAndOwnEvidenceIsRequiredWithoutForcedTests() throws {
        let (p,t,s,selectors) = try fixture(),a = try call("work_claim",selectors,critic),report = try ownReport(p,t,critic)
        let manifest = try router.dbQueue.read {try router.record($0,s["manifest_id"] as! String,type:"manifest")}
        var input = verdict(p,a)
        assertCode("REVIEW_ASSESSMENT_REQUIRED") {_ = try self.call("review_record",input,self.critic)}
        var assessment = try fixtureReviewAssessment(router,task:t,manifest:manifest,artifact:report)
        let complete = assessment["acceptance"] as! [JSON];assessment["acceptance"] = Array(complete.prefix(1));input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        assessment["acceptance"] = complete;input["review_assessment"] = assessment
        let recorded = try call("review_record",input,critic)
        XCTAssertEqual(recorded["verdict"] as? String,"pass");XCTAssertEqual((recorded["review_assessment"] as! JSON)["actor"] as? String,critic.principal);XCTAssertEqual((recorded["checks"] as! [JSON]).count,0)
    }
    func testSubmittedAuthorFileCannotImpersonateOwnReviewReport() throws {
        let (p,t,s,selectors) = try fixture(),a = try call("work_claim",selectors,critic)
        let manifest = try router.dbQueue.read {try router.record($0,s["manifest_id"] as! String,type:"manifest")},ref = ((manifest["evidence"] as! JSON)["artifact_refs"] as! [JSON])[0]
        let authorFile = try router.dbQueue.read {try router.record($0,ref["artifact_id"] as! String,type:"attachment")}
        var input = verdict(p,a);input["review_assessment"] = try fixtureReviewAssessment(router,task:t,manifest:manifest,artifact:authorFile)
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
    }
    func testCurrentProjectRequirementsChangeAssessmentContractAndNeedFullCoverage() throws {
        let (p,t,s,selectors) = try fixture(),oldContext = try call("review_context",selectors,critic),oldHash = (oldContext["review_contract"] as! JSON)["sha256"] as! String
        let settings = try call("project_settings_get",["project_id":p["id"]!])
        _ = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":settings["revision"]!,"brief":"Preserve the project’s stated review outcome.","pinned_decisions":[["body":"Inspect keyboard access on changed controls."]]])
        let context = try call("review_context",selectors,critic),contract = context["review_contract"] as! JSON
        XCTAssertNotEqual(contract["sha256"] as? String,oldHash)
        let requirements = contract["project_requirements"] as! [JSON]
        // Generic review check/reject guidance now accompanies brief and pinned decisions.
        XCTAssertEqual(requirements.compactMap {$0["kind"] as? String},["project_brief","approved_project_decision","review_check","review_reject_bar"])
        let a = try call("work_claim",selectors,critic),report = try ownReport(p,t,critic),manifest = try router.dbQueue.read {try router.record($0,s["manifest_id"] as! String,type:"manifest")}
        var assessment = try fixtureReviewAssessment(router,task:t,manifest:manifest,artifact:report),input = verdict(p,a)
        assessment["contract_sha256"] = oldHash;input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_REQUIRED") {_ = try self.router.dbQueue.read {try self.router.validateReviewAssessment($0,params:input,task:t,attempt:a,verdict:"pass",caller:self.critic)}}
        let applied = try call("review_context",selectors,critic),currentTask = applied["task"] as! JSON
        assessment["contract_sha256"] = (applied["review_contract"] as! JSON)["sha256"]!
        assessment["project_requirements"] = (assessment["project_requirements"] as! [JSON]).filter {$0["requirement_id"] as? String != "project:brief"}
        input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.router.dbQueue.read {try self.router.validateReviewAssessment($0,params:input,task:currentTask,attempt:a,verdict:"pass",caller:self.critic)}}
    }
    func testNewReviewerReportRollbackDuringBackupCleansOnlyItsOwnFile() throws {
        let (p,_,_,selectors) = try fixture(source:true),a = try call("work_claim",selectors,critic)
        let input: JSON = ["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"title":"Synthetic report during backup","body":"Synthetic rollback evidence"]
        let destination = directory.appendingPathComponent("report-backup")
        var budget = StorageSnapshotBudget.production(),observed = false,committed: JSON = [:]
        budget.observe = {event in
            guard event == "copying_objects" else {return};observed = true
            var rolledBackPath = ""
            try ArchiveStorageGate.withExclusive(root:self.router.root) { _ in
                try self.router.dbQueue.writeWithoutTransaction {db in
                    try db.inTransaction {
                        let artifact = try self.router.addAgentReviewEvidence(db,input,self.critic)
                        rolledBackPath = try self.router.managedURL(artifact["path"] as! String,family:"objects").path
                        XCTAssertTrue(FileManager.default.fileExists(atPath:rolledBackPath))
                        return .rollback
                    }
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:rolledBackPath))
            committed = try self.call("review_evidence_add",input,self.critic)
            XCTAssertTrue(FileManager.default.fileExists(atPath:try self.router.managedURL(committed["path"] as! String,family:"objects").path))
        }
        _ = try router.executeStorageBackup(params:["command_id":UUID().uuidString,"path":destination.path],caller:owner,budget:budget)
        XCTAssertTrue(observed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try router.managedURL(committed["path"] as! String,family:"objects").path))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (committed["id"] as! String) + ":original")})
        _ = try StorageSnapshot.reconcile(parent:directory,operation:UUID(uuidString:manifest.operationID)!,publicationName:destination.lastPathComponent,budget:.production())
    }

    func testManagedReviewerReportBindsExactAttemptAndCleansBytesOnRollback() throws {
        let (p,t,_,selectors) = try fixture(source:true),a = try call("work_claim",selectors,critic)
        let input: JSON = ["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"title":"Independent review report","body":"Actual synthetic fixture report body; source files stay unchanged."]
        var rolledBackPath = "",rolledBackID = ""
        try router.dbQueue.writeWithoutTransaction { db in
            try db.inTransaction {
                let artifact = try router.addAgentReviewEvidence(db,input,critic);rolledBackPath = try XCTUnwrap(ManagedPaths.resolve(artifact["path"] as! String,family:"objects",root:router.root)).path
                XCTAssertTrue(FileManager.default.fileExists(atPath:rolledBackPath))
                rolledBackID = artifact["id"] as! String;return .rollback
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:rolledBackPath))
        assertCode("NOT_FOUND") {_ = try self.router.dbQueue.read {try self.router.record($0,rolledBackID,type:"attachment")}}
        let report = try call("review_evidence_add",input,critic)
        XCTAssertEqual(report["review_attempt_id"] as? String,a["id"] as? String);XCTAssertEqual(report["target_manifest_id"] as? String,a["manifest_id"] as? String)
        XCTAssertEqual(report["author"] as? String,critic.principal);XCTAssertEqual(report["sha256"] as? String,ChecklistCore.hash(Data((input["body"] as! String).utf8)))
        let context = try call("review_context",selectors,critic),manifest = context["target_manifest"] as! JSON
        var pass = verdict(p,a);pass["review_assessment"] = try fixtureReviewAssessment(router,task:t,manifest:manifest,artifact:report)
        _ = try call("review_record",pass,critic)
    }
    func testDisabledRunnerNeverExecutesSubmittedCodeOrQueuesAJob() throws {
        let (p,_,_,selectors) = try fixture(source:true),a = try call("work_claim",selectors,critic)
        assertCode("UNSUPPORTED_CAPABILITY") {_ = try self.call("source_review_execute",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"tool":"project_script","args":["scripts/validate-plan.py"]],self.critic)}
        let jobs = try router.dbQueue.read {try router.records($0,type:"source_execution",project:p["id"] as? String)};XCTAssertTrue(jobs.isEmpty)
    }
    func testCapturedInstructionSymlinkRequiresExactLinkAndResolvedContentCoverage() throws {
        let (p,t,_,selectors) = try fixture(source:true,instructionSymlink:true)
        let attempt = try call("work_claim",selectors,critic)
        // A pre-claim context is a preview; use the applied contract for every guard below.
        let context = try call("review_context",selectors,critic),contract = context["review_contract"] as! JSON,refs = contract["project_instruction_refs"] as! [JSON]
        XCTAssertEqual(refs.count,1)
        let instruction = try XCTUnwrap(refs.first),capture = ((context["target_manifest"] as! JSON)["evidence"] as! JSON)["source_capture"] as! JSON
        let contentHash = ChecklistCore.hash(Data("Review the changed controls for keyboard access and record the observed result.".utf8)),linkHash = ChecklistCore.hash(Data("rules.md".utf8))
        XCTAssertEqual(instruction["source_capture_id"] as? String,capture["id"] as? String);XCTAssertEqual(instruction["source_sha256"] as? String,capture["sha256"] as? String)
        XCTAssertEqual(instruction["path"] as? String,"AGENTS.md");XCTAssertEqual(instruction["resolved_path"] as? String,"rules.md");XCTAssertEqual(instruction["sha256"] as? String,contentHash)
        XCTAssertEqual(try jsonString(instruction["link_chain"]!),try jsonString([["path":"AGENTS.md","target":"rules.md","sha256":linkHash]]))
        let report = try ownReport(p,t,critic),reportRef: JSON = ["artifact_id":report["id"]!,"sha256":report["sha256"]!]
        var assessment: JSON = ["contract_sha256":contract["sha256"]!,"target_manifest_id":selectors["target_manifest_id"]!,"acceptance":(contract["acceptance"] as! [JSON]).map {["requirement_id":$0["id"]!,"result":"pass","rationale":"Inspected the exact synthetic acceptance outcome.","evidence_refs":[reportRef]]},"project_requirements":(contract["project_requirements"] as! [JSON]).map {["requirement_id":$0["id"]!,"result":"pass","rationale":"Inspected the synthetic generic review requirement.","evidence_refs":[reportRef]]},"evidence_refs":[reportRef],"instruction_coverage":[],"all_applicable_project_requirements_assessed":true,"additional_requirements":[]]
        var input = verdict(p,attempt);input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        assessment["instruction_coverage"] = refs;input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        assessment["additional_requirements"] = [["requirement":"Changed controls remain keyboard accessible.","source":"Captured AGENTS.md -> rules.md","result":"pass","rationale":"The independent synthetic report records the inspected keyboard path.","evidence_refs":[reportRef]]]
        var stripped = instruction;stripped.removeValue(forKey:"link_chain");stripped.removeValue(forKey:"resolved_path");assessment["instruction_coverage"] = [stripped];input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        var altered = instruction;altered["source_capture_id"] = UUID().uuidString;assessment["instruction_coverage"] = [altered];input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        altered = instruction;altered["link_chain"] = [["path":"AGENTS.md","target":"other-rules.md","sha256":linkHash]];assessment["instruction_coverage"] = [altered];input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") {_ = try self.call("review_record",input,self.critic)}
        assessment["instruction_coverage"] = refs;input["review_assessment"] = assessment
        let recorded = try call("review_record",input,critic)
        XCTAssertEqual(recorded["verdict"] as? String,"pass");XCTAssertEqual(try jsonString((recorded["review_assessment"] as! JSON)["instruction_coverage"]!),try jsonString(refs))
        let jobs = try router.dbQueue.read {try router.records($0,type:"source_execution",project:p["id"] as? String)};XCTAssertTrue(jobs.isEmpty)
    }
    func testNestedCapturedInstructionSymlinkChainUsesOnlyIncludedTargets() throws {
        let nested = workspace.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:workspace.appendingPathComponent("linked-rules.md").path,withDestinationPath:"rules.md")
        try FileManager.default.createSymbolicLink(atPath:nested.appendingPathComponent("AGENTS.md").path,withDestinationPath:"../linked-rules.md")
        let (_,_,_,selectors) = try fixture(source:true,instructionSymlink:true),context = try call("review_context",selectors,critic),refs = (context["review_contract"] as! JSON)["project_instruction_refs"] as! [JSON]
        let instruction = try XCTUnwrap(refs.first {$0["path"] as? String == "nested/AGENTS.md"}),links = instruction["link_chain"] as! [JSON]
        XCTAssertEqual(instruction["resolved_path"] as? String,"rules.md");XCTAssertEqual(links.compactMap {$0["path"] as? String},["nested/AGENTS.md","linked-rules.md"])
        XCTAssertEqual(instruction["sha256"] as? String,refs.first {$0["path"] as? String == "AGENTS.md"}?["sha256"] as? String)
    }
    func testCapturedInstructionResolverRejectsEscapeCycleMissingAndOverlongChains() throws {
        func symlink(_ path: String,_ target: String) -> JSON {["path":path,"kind":"symlink","target":target,"sha256":ChecklistCore.hash(Data(target.utf8))]}
        func capture(_ files: [JSON]) -> JSON {["id":UUID().uuidString,"sha256":String(repeating:"1",count:64),"files":files]}
        for files in [[symlink("AGENTS.md","../outside.md")],[symlink("AGENTS.md","rules.md"),symlink("rules.md","AGENTS.md")],[symlink("AGENTS.md","absent.md")]] {
            assertCode("EVIDENCE_STALE") {_ = try self.router.capturedReviewInstructions(capture(files))}
        }
        var files = [symlink("AGENTS.md","link-0.md")]
        for index in 0..<32 {files.append(symlink("link-\(index).md",index == 31 ? "rules.md" : "link-\(index+1).md"))}
        files.append(["path":"rules.md","kind":"file","sha256":String(repeating:"2",count:64)])
        assertCode("EVIDENCE_STALE") {_ = try self.router.capturedReviewInstructions(capture(files))}
    }
}
