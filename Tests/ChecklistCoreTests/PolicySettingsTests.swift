import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

final class PolicySettingsTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"policy-settings-owner",projectIDs:[])
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); router = try TestStore.router(root:directory) }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ p: JSON = [:],_ caller: Caller? = nil) throws -> JSON {
        var params = p; if !CommandRouter.readMethods.contains(method) { params["command_id"] = uuid() }
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:params),caller:caller ?? owner)["data"] as! JSON
    }
    func project() throws -> JSON { try call("project_create",["name":"Policy fixture","key_prefix":"POL","root_path":directory.path]) }
    func ready(_ project: JSON,kind: String = "work") throws -> JSON {
        let task = try call("task_create",["project_id":project["id"]!,"title":"A bounded result","brief":"A useful verified result","kind":kind])
        return try call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
    }
    func assertCode(_ expected: String,_ block: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) { XCTAssertThrowsError(try block(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,expected,file:file,line:line) } }

    func testSharedPassingReviewDefaultAndBoundedProjectOverride() throws {
        let base = try router.normalizedPolicy([:])
        XCTAssertEqual(router.effectiveReviewBatchPolicy(base),"complete_passing_independently")
        let changed = try router.normalizedPolicy(["review_batch_policy":"hold_passing_for_batch"])
        XCTAssertEqual(router.effectiveReviewBatchPolicy(changed),"hold_passing_for_batch")
        XCTAssertEqual(strings(changed,"required_gates"),["review"])
        assertCode("INVALID_INPUT") { _ = try self.router.normalizedPolicy(["review_batch_policy":"skip_failed_gates"]) }
    }

    func testKindOverrideIsEffectiveAndCannotExpandProvidersOrEnableAnAssistant() throws {
        let rule: JSON = ["providers":["claude"],"preferred_provider":"claude","preferred_models":[]]
        let policy = try router.normalizedPolicy(["routing_preset":"codex_led","task_kind_overrides":[["kind":"asset","roles":["implementer":rule],"required_gates":["human_approval"]]]])
        let work = router.effectivePolicy(policy,kind:"work"), asset = router.effectivePolicy(policy,kind:"asset")
        XCTAssertEqual(strings((work["roles"] as! JSON)["implementer"] as! JSON,"providers"),["codex"])
        XCTAssertEqual(strings((asset["roles"] as! JSON)["implementer"] as! JSON,"providers"),["claude"])
        XCTAssertEqual(strings(asset,"required_gates"),["human_approval"])
        assertCode("POLICY_DENIED") { _ = try self.router.normalizedPolicy(["allowed_providers":["codex"],"task_kind_overrides":[["kind":"asset","roles":["implementer":rule]]]]) }
        assertCode("FORBIDDEN") { _ = try self.router.normalizedPolicy(["assistant_relay_grants":["read":true]]) }
        assertCode("INVALID_INPUT") { _ = try self.router.normalizedPolicy(["task_kind_overrides":[["kind":"asset","required_gates":[]],["kind":"asset","required_gates":[]]]]) }
        assertCode("INVALID_INPUT") { _ = try self.router.normalizedPolicy(["required_gates":["pretend_native_qualification"]]) }
    }

    func testPolicyPreviewReportsExactGatesAndRejectsStaleProposal() throws {
        let project = try project(), task = try ready(project)
        let claim = try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        let proposal = try call("policy_propose",["project_id":project["id"]!,"policy":["required_gates":["review","human_approval"]],"mode":"checkpoint_active"])
        XCTAssertEqual((proposal["active_rounds"] as? [JSON])?.count,1)
        XCTAssertEqual(strings((proposal["affected_tasks"] as! [JSON])[0],"after_gates"),["review","human_approval"])
        _ = try call("work_checkpoint",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"A newer checkpoint changes preview inputs"])
        assertCode("REVISION_CONFLICT") { _ = try self.call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"proposal_id":proposal["id"]!,"digest":proposal["digest"]!]) }
    }

    func testAtomicSettingsRejectsInvalidDefaultsWithoutPartialIdentityOrPolicyChange() throws {
        let project = try project()
        assertCode("INVALID_INPUT") { _ = try self.call("project_settings_save",["project_id":project["id"]!,"expected_revision":project["revision"]!,"name":"Must not partly save","policy":["required_gates":[]],"capture_defaults":["enabled_kinds":["asset"],"default_kind":"asset","starter_overrides":[]]]) }
        let saved = try call("project_settings_get",["project_id":project["id"]!])
        XCTAssertEqual(saved["name"] as? String,project["name"] as? String)
        XCTAssertEqual(int(saved,"policy_revision"),int(project,"policy_revision"))
        XCTAssertEqual(int(saved,"revision"),int(project,"revision"))
    }

    func testAtomicSettingsRetainsOldKeysAndStoresCanonicalDefaults() throws {
        let project = try project(), first = try ready(project)
        let saved = try call("project_settings_save",["project_id":project["id"]!,"expected_revision":project["revision"]!,"key_prefix":"NEW","brief":"Updated context","capture_defaults":["enabled_kinds":["work","question"],"default_kind":"question","starter_overrides":[["kind":"question","outcome_hint":"Record the answer"]]],"default_view":["group_by":"epic","order_by":"priority"],"alert_override":"quiet","policy":["review_batch_policy":"complete_passing_independently"]])
        let next = try call("task_create",["project_id":project["id"]!,"title":"Next ticket"])
        XCTAssertEqual(first["key"] as? String,"POL-1"); XCTAssertEqual(next["key"] as? String,"NEW-2")
        XCTAssertEqual(saved["alert_override"] as? String,"quiet")
        XCTAssertEqual((saved["capture_defaults"] as? JSON)?["default_kind"] as? String,"question")
        XCTAssertEqual(int(saved,"context_revision"),2)
        XCTAssertEqual(int(saved,"policy_revision"),2)
    }

    func testFuturePolicyPreservesActiveSnapshotAndCheckpointModeRequiresExplicitAcknowledgment() throws {
        var project = try project(); let task = try ready(project)
        let claim = try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        project = try call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"policy":["required_gates":[]],"mode":"future_attempts"])
        try router.dbQueue.read { db in let active = try router.record(db,claim["id"] as! String,type:"attempt"); XCTAssertEqual(strings(try router.attemptPolicy(db,active),"required_gates"),["review"]); XCTAssertNil(active["pending_policy_revision"]) }
        project = try call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"policy":["required_gates":["human_approval"]],"mode":"checkpoint_active"])
        try router.dbQueue.read { db in let active = try router.record(db,claim["id"] as! String,type:"attempt"); assertCode("POLICY_ACK_REQUIRED") { try self.router.verifyPolicyAuthority(db,attempt:active,caller:self.owner) } }
        assertCode("CHECKPOINT_REQUIRED") { _ = try self.call("policy_acknowledge",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Reconcile current work"] ) }
        _ = try call("work_checkpoint",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"Preserved work; revise approval plan"])
        let acknowledged = try call("policy_acknowledge",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Use owner approval for this current round"])
        let active = acknowledged["attempt"] as! JSON
        XCTAssertNil(active["pending_policy_revision"])
        XCTAssertEqual(strings(active["policy_snapshot"] as! JSON,"required_gates"),["human_approval"])
        XCTAssertEqual(int(active,"policy_revision"),int(project,"policy_revision"))
    }

    func testTaskExceptionRequiresEligibleProviderAndTrustedProvenance() throws {
        let project = try project(); var task = try ready(project)
        assertCode("INVALID_INPUT") { _ = try self.call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["planned_assignee":["kind":"agent","provider":"claude"]]]) }
        task = try call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["planned_assignee":["kind":"agent","provider":"claude"],"assignment_reason":"This asset needs the eligible second provider"]])
        XCTAssertEqual((task["assignment_provenance"] as? JSON)?["origin"] as? String,"human_ui")
        XCTAssertEqual((task["assignment_provenance"] as? JSON)?["actor"] as? String,owner.principal)
    }

    func testImmediateRevocationPreservesClaimAndAllowsCheckpointRecoveryOnly() throws {
        let project = try project(), task = try ready(project), sid = uuid()
        _ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"provider":"claude","role":"worker","workspace":directory.path,"installation":"policy-worker"])
        let worker = Caller(role:"worker",installation:"policy-worker",projectIDs:[project["id"] as! String],sessionID:sid,workspace:directory.path)
        let claim = try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!],worker)
        _ = try call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"policy":["allowed_providers":["codex"]],"mode":"future_attempts"])
        try router.dbQueue.read { db in
            let active = try router.record(db,claim["id"] as! String,type:"attempt")
            XCTAssertEqual(active["state"] as? String,"active"); XCTAssertTrue(bool(active,"policy_authority_revoked")); XCTAssertNotNil(active["token_hash"])
            XCTAssertEqual((try router.record(db,task["id"] as! String,type:"task"))["active_attempt_id"] as? String,claim["id"] as? String)
            assertCode("POLICY_DENIED") { try self.router.verifyPolicyAuthority(db,attempt:active,caller:worker) }
        }
        _ = try call("work_checkpoint",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"Saved revoked work pending explicit recovery"],worker)
        assertCode("POLICY_DENIED") { _ = try self.call("work_submit",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":task["acceptance_revision"]!,"evidence_manifest":[:]],worker) }
    }

    func testHumanDecisionEvidenceIsExplicitBooleanAndKindBounded() throws {
        let base = try router.normalizedPolicy([:])
        XCTAssertFalse(bool(base,"allow_human_decision_evidence"))
        let policy = try router.normalizedPolicy(["task_kind_overrides":[["kind":"asset","allow_human_decision_evidence":true]]])
        XCTAssertTrue(bool(router.effectivePolicy(policy,kind:"asset"),"allow_human_decision_evidence"))
        XCTAssertFalse(bool(router.effectivePolicy(policy,kind:"work"),"allow_human_decision_evidence"))
        assertCode("INVALID_INPUT") { _ = try self.router.normalizedPolicy(["allow_human_decision_evidence":1]) }
    }

    func testStatusRetirementRemapsOnlyExactProjectRevisionsAndKeepsParkedTypesDistinct() throws {
        let project = try project(), task = try ready(project)
        let a = try call("status_create",["project_id":project["id"]!,"name":"Waiting for audio","category":"parked","sort_order":10])
        let b = try call("status_create",["project_id":project["id"]!,"name":"Waiting for build","category":"parked","sort_order":11])
        let parked = try call("task_transition",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"target_status_id":a["id"]!])
        assertCode("INVALID_TRANSITION") { _ = try self.call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":parked["revision"]!]) }
        assertCode("REVISION_CONFLICT") { _ = try self.call("status_retire",["project_id":project["id"]!,"status_id":a["id"]!,"expected_revision":a["revision"]!,"remap_target_status_id":b["id"]!,"expected_task_revisions":[task["id"] as! String:1]]) }
        let unchanged = try call("task_get",["project_id":project["id"]!,"task_id":task["id"]!]); XCTAssertEqual(unchanged["status_id"] as? String,a["id"] as? String)
        _ = try call("status_retire",["project_id":project["id"]!,"status_id":a["id"]!,"expected_revision":a["revision"]!,"remap_target_status_id":b["id"]!,"expected_task_revisions":[task["id"] as! String:parked["revision"]!]])
        let remapped = try call("task_get",["project_id":project["id"]!,"task_id":task["id"]!]); XCTAssertEqual(remapped["status_id"] as? String,b["id"] as? String)
        let taxonomy = try call("taxonomy_get",["project_id":project["id"]!]); XCTAssertTrue((taxonomy["statuses"] as! [JSON]).contains { $0["id"] as? String == b["id"] as? String && !bool($0,"retired") })
    }
}
