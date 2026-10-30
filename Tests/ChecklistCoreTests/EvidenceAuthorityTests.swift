import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class EvidenceAuthorityTests: XCTestCase {
    private static let prepared = TestStore.Template(name: "EvidenceAuthorityTests") { router, workspace in
        let owner = Caller(role:"owner",installation:"evidence-owner",projectIDs:[])
        let project = try router.handle(method:"project_create",params:["command_id":uuid(),"name":"Evidence fixture","key_prefix":"E","root_path":workspace.path],caller:owner)["data"] as! JSON
        let epicOwner = Caller(role:"owner",installation:"required-epic-fixture",projectIDs:[])
        _ = try router.handle(method:"epic_create",params:["command_id":uuid(),"project_id":project["id"]!,"name":"Fixture tickets"],caller:epicOwner)
        try router.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES ('test-evidence-project',?)",arguments:[try jsonString(project)])}
    }
    // Each source test gets private Git metadata and source bytes, while the
    // initial commit is prepared once for this linked test image.
    private static let sourcePrepared = TestStore.DirectoryTemplate(name: "EvidenceAuthorityTests-source") { workspace in
        try prepareSourceFixture(at: workspace)
    }
    private static func prepareSourceFixture(at workspace: URL) throws {
        func write(_ path: String, _ content: String) throws {
            let target = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: target)
        }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", workspace.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw CoreError("FIXTURE_GIT_FAILED", "Preparing the private source fixture failed")
            }
        }
        try write("tracked.txt", "base")
        try write(".gitignore", "private/\n.build/\n")
        try write("scripts/validate-plan.py", "from pathlib import Path\nassert Path('tracked.txt').read_text() == 'dirty'\nassert Path('untracked.txt').read_text() == 'new'\nprint('captured source passed')\n")
        try git(["init"]); try git(["add", "."])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"])
        try write("tracked.txt", "dirty"); try write("untracked.txt", "new")
        try write("private/receipt.txt", "never captured")
    }
    private var preparedProject: JSON?
    func clearPreparedProject() { preparedProject = nil }
    var directory: URL!,workspace: URL!,router: CommandRouter!
    let owner = Caller(role:"owner",installation:"evidence-owner",projectIDs:[])
    override func setUpWithError() throws {
        // Keep production's no-follow storage boundary intact: macOS /var
        // temporary paths traverse an alias, so use an owned physical cache root.
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let parent = caches.resolvingSymlinksInPath().appendingPathComponent("ChecklistQualification/CL-38", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = parent.appendingPathComponent("EvidenceAuthorityTests-" + UUID().uuidString, isDirectory: true)
        workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        router = try TestStore.router(root:directory.appendingPathComponent("store"),template:Self.prepared,workspace:workspace)
        preparedProject = try router.dbQueue.read {db in
            var project = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='test-evidence-project'")))
            project["root_path"] = workspace.resolvingSymlinksInPath().path
            return project
        }
    }
    override func tearDownWithError() throws { try router?.closeStore();router = nil;try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ input: JSON,_ caller: Caller? = nil,command: String? = nil) throws -> JSON {
        var p = input
        if method == "work_submit" { p = try fixtureAcceptanceEvidence(router,input:p) }
        if method == "batch_submit",let members = p["members"] as? [JSON] { p["members"] = try members.map {try fixtureAcceptanceEvidence(router,input:$0)} }
        if !CommandRouter.readMethods.contains(method) {p["command_id"] = command ?? UUID().uuidString}
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? owner)["data"] as! JSON
    }
    func project() throws -> JSON {
        if var preparedProject {
            let path = workspace.resolvingSymlinksInPath().path
            if preparedProject["root_path"] as? String != path {
                // Some fixtures choose a fresh workspace after setUp. Bind the
                // still-unused copied project before exposing it, preserving
                // the original project_create revision/counters and history.
                try router.dbQueue.write {db in
                    var stored = try router.record(db,preparedProject["id"] as! String,type:"project")
                    stored["root_path"] = path;try router.save(db,stored,type:"project")
                }
                preparedProject["root_path"] = path
            }
            self.preparedProject = nil;return preparedProject
        }
        return try call("project_create",["name":"Evidence fixture","key_prefix":"E","root_path":workspace.path])
    }
    func ready(_ project: JSON,kind: String = "work") throws -> JSON {
        let t = try call("task_create",["project_id":project["id"]!,"title":"Exact evidence","brief":"A bounded observable result","kind":kind])
        return try call("task_edit",["project_id":project["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["readiness":"ready"]])
    }
    func claim(_ project: JSON,_ task: JSON,files: [JSON] = [],lanes: [JSON] = [],caller: Caller? = nil) throws -> JSON { try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"file_scopes":files,"lane_scopes":lanes],caller) }
    func assertCode(_ code: String,_ action: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) { XCTAssertThrowsError(try action(),file:file,line:line) {XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line)} }
    func auth(_ p: JSON,_ a: JSON) -> JSON {["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!]}
    func native(_ p: JSON,_ label: String,domain: String,provider: String = "codex") throws -> Caller {
        let id = UUID().uuidString,installation = "fixture-"+label
        _ = try call("session_register",["project_id":p["id"]!,"session_id":id,"installation":installation,"provider":provider,"role":"worker","workspace":workspace.path,"execution_domain":domain])
        return Caller(role:"worker",installation:installation,projectIDs:[p["id"] as! String],sessionID:id,workspace:workspace.path,executionDomain:domain)
    }
    func write(_ path: String,_ content: String) throws { let target = workspace.appendingPathComponent(path);try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(content.utf8).write(to:target) }
    func git(_ args: [String]) throws { let p = Process();p.executableURL = URL(fileURLWithPath:"/usr/bin/git");p.arguments = ["-C",workspace.path]+args;p.standardOutput = FileHandle.nullDevice;p.standardError = FileHandle.nullDevice;try p.run();p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0) }
    func sourceFixture() throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty {
            try Self.sourcePrepared.copy(to: workspace)
        } else {
            // Preserve git-add/overwrite semantics for a caller that supplies
            // its own workspace content before requesting the source fixture.
            try Self.prepareSourceFixture(at: workspace)
        }
    }
    func submitSource(_ p: JSON,_ a: JSON) throws -> JSON { var input = auth(p,a);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":[:]];return try call("work_submit",input) }
    func reviewClaim(_ p: JSON,_ submitted: JSON,_ reviewer: Caller) throws -> JSON {
        let task = submitted["task"] as! JSON
        return try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":(submitted["review_request_ids"] as! [String])[0],"target_manifest_id":submitted["manifest_id"]!,"gate":"review"],reviewer)
    }
    func reviewInput(_ p: JSON,_ a: JSON,verdict: String,checks: [JSON] = []) -> JSON { var input = auth(p,a);input["review_request_id"] = a["review_request_id"];input["target_manifest_id"] = a["manifest_id"];input["gate"] = "review";input["verdict"] = verdict;input["checks"] = checks;return input }

    func ownReviewAssessment(_ p: JSON,_ review: JSON,_ reviewer: Caller) throws -> JSON {
        let task = try router.dbQueue.read {try router.record($0,review["task_id"] as! String,type:"task")},manifest = try router.dbQueue.read {try router.record($0,review["manifest_id"] as! String,type:"manifest")}
        let file = directory.appendingPathComponent("review-report-"+UUID().uuidString+".md")
        try Data("Synthetic reviewer inspected this exact source target and finding context.".utf8).write(to:file)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":file.path],reviewer)
        return try fixtureReviewAssessment(router,task:task,manifest:manifest,artifact:artifact)
    }
    func testCanonicalReservationsAndAtomicExpansionPreserveOldScope() throws {
        let p = try project(),t1 = try ready(p),t2 = try ready(p)
        try FileManager.default.createDirectory(at:workspace.appendingPathComponent("real"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:workspace.appendingPathComponent("alias").path,withDestinationPath:"real")
        let a = try claim(p,t1,files:[["path":"real","access":"write"]],lanes:[["lane_id":"build"]])
        assertCode("SCOPE_CONFLICT") { _ = try self.claim(p,t2,files:[["path":"alias/new.swift","access":"write"]]) }
        assertCode("LANE_FULL") { _ = try self.claim(p,t2,files:[["path":"other","access":"write"]],lanes:[["lane_id":"build"]]) }
        let b = try claim(p,t2,files:[["path":"other","access":"write"]])
        var input = auth(p,a);input["file_scopes"] = [["path":"real","access":"write"],["path":"other","access":"write"]]
        assertCode("SCOPE_CONFLICT") { _ = try self.call("work_scope_adjust",input) }
        let persisted = try router.dbQueue.read {try router.record($0,a["id"] as! String,type:"attempt")}
        XCTAssertEqual((persisted["file_scopes"] as! [JSON]).count,1)
        var release = auth(p,b);release["reason"] = "Fixture complete";_ = try call("work_release",release)
        let expanded = try call("work_scope_adjust",input);XCTAssertEqual((expanded["file_scopes"] as! [JSON]).count,2)
    }
    func testSymlinkRepointDoesNotMoveOriginalReservation() throws {
        let p = try project(),t1 = try ready(p),t2 = try ready(p)
        try FileManager.default.createDirectory(at:workspace.appendingPathComponent("first"),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:workspace.appendingPathComponent("second"),withIntermediateDirectories:true)
        let alias = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"first")
        let a = try claim(p,t1,files:[["path":"alias/new.swift","access":"write"]])
        XCTAssertEqual((a["file_scopes"] as! [JSON])[0]["path"] as? String,router.reservationKey(workspace.appendingPathComponent("first/new.swift").path))
        try FileManager.default.removeItem(at:alias);try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"second")
        assertCode("SCOPE_CONFLICT") {_ = try self.claim(p,t2,files:[["path":"first/new.swift","access":"write"]])}
        _ = try claim(p,t2,files:[["path":"alias/new.swift","access":"write"]])
    }
    func testConcurrentCanonicalClaimsHaveOneWinner() throws {
        let p = try project(),tasks = try (0..<8).map {_ in try ready(p)}
        let projectID = p["id"] as! String
        let inputs = try tasks.map { task in
            try JSONSerialization.data(withJSONObject:["project_id":projectID,"task_id":task["id"]!,"expected_revision":task["revision"]!,"file_scopes":[["path":"shared","access":"write"]],"lane_scopes":[]] as JSON)
        }
        let claimRouter = router!, caller = owner, winners = LockedTestState(0)
        // concurrentPerform joins every worker before XCTest teardown closes the router.
        DispatchQueue.concurrentPerform(iterations:8) { index in
            do {
                var params = try JSONSerialization.jsonObject(with:inputs[index]) as! JSON
                params["command_id"] = UUID().uuidString
                _ = try claimRouter.handle(method:"work_claim",params:try fixtureTaskInput(claimRouter,method:"work_claim",input:params),caller:caller)
                winners.withLock { $0 += 1 }
            } catch {}
        }
        XCTAssertEqual(winners.snapshot,1)
    }
    func testWritableChildrenBlockParentExitAndNarrowing() throws {
        let p = try project(),t = try ready(p),parent = try native(p,"parent",domain:"host-A"),child = try native(p,"child",domain:"host-A")
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],lanes:[["lane_id":"build"]],caller:parent)
        var delegation = auth(p,a);delegation["child_session_id"] = child.sessionID!;delegation["file_scopes"] = [["path":"Sources/Child.swift","access":"write"]];delegation["lane_scopes"] = [["lane_id":"build"]]
        let offer = try call("work_delegate",delegation,parent)
        let b = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],child)
        var release = auth(p,a);release["reason"] = "parent finished"
        assertCode("CHILD_WRITERS_ACTIVE") { _ = try self.call("work_release",release,parent) }
        var adjustment = auth(p,a);adjustment["file_scopes"] = []
        assertCode("CHILD_WRITERS_ACTIVE") { _ = try self.call("work_scope_adjust",adjustment,parent) }
        var laneReduction = auth(p,a);laneReduction["lane_scopes"] = []
        assertCode("CHILD_WRITERS_ACTIVE") { _ = try self.call("work_scope_adjust",laneReduction,parent) }
        let successor = try native(p,"child-successor",domain:"host-A")
        var handoff = auth(p,b);handoff["target_session_id"] = successor.sessionID!;handoff["summary"] = "Child checkpoint"
        let childOffer = try call("work_handoff_offer",handoff,child)
        let successorAttempt = try call("work_handoff_accept",["project_id":p["id"]!,"offer_id":childOffer["id"]!],successor)
        let unchangedRoot = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual(unchangedRoot["active_attempt_id"] as? String,a["id"] as? String)
        var childRelease = auth(p,successorAttempt);childRelease["reason"] = "child stopped";_ = try call("work_release",childRelease,successor)
        let stillParent = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]);XCTAssertEqual(stillParent["active_attempt_id"] as? String,a["id"] as? String)
        _ = try call("work_release",release,parent)
    }
    func testSurvivingReadOnlyChildCannotRegainWritesFromReleasedParent() throws {
        let p = try project(),t = try ready(p),parent = try native(p,"read-parent",domain:"host-A"),child = try native(p,"read-child",domain:"host-A")
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:parent)
        var delegation = auth(p,a);delegation["child_session_id"] = child.sessionID!;delegation["file_scopes"] = [["path":"Sources/Read.swift","access":"read"]]
        let offer = try call("work_delegate",delegation,parent),b = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],child)
        var release = auth(p,a);release["reason"] = "Parent stopped after read-only context delegation";_ = try call("work_release",release,parent)
        var expansion = auth(p,b);expansion["file_scopes"] = [["path":"Sources/Read.swift","access":"write"]]
        assertCode("STALE_CLAIM") { _ = try self.call("work_scope_adjust",expansion,child) }
        var checkpoint = auth(p,b);checkpoint["progress"] = "Read-only context retained";_ = try call("work_checkpoint",checkpoint,child)
        let releasedRoot = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        let recovered = try call("work_recover",["project_id":p["id"]!,"task_id":t["id"]!,"attempt_id":b["id"]!,"expected_revision":releasedRoot["revision"]!,"action":"confirm_stopped_revoke","reason":"Observed child stop and inspected files","observation_refs":["child-process-stop"],"file_state_refs":["inspected-read-only-scope"]])
        XCTAssertEqual(recovered["state"] as? String,"revoked")
    }
    func testHealthyHandoffFencesOriginalAuthorityAndPreservesContext() throws {
        let p = try project(),t = try ready(p),first = try native(p,"first",domain:"host-A"),second = try native(p,"second",domain:"host-B")
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:first)
        var input = auth(p,a);input["target_session_id"] = second.sessionID!;input["summary"] = "Resume at exact parser checkpoint; no child writers."
        let offer = try call("work_handoff_offer",input,first)
        var checkpoint = auth(p,a);checkpoint["progress"] = "Original authority remains until acceptance";_ = try call("work_checkpoint",checkpoint,first)
        let b = try call("work_handoff_accept",["project_id":p["id"]!,"offer_id":offer["id"]!],second)
        XCTAssertEqual(b["handoff_context"] as? String,input["summary"] as? String)
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint",checkpoint,first) }
        var current = auth(p,b);current["progress"] = "New fenced handler resumed";_ = try call("work_checkpoint",current,second)
    }
    func testCurrentPolicyBlocksIneligibleRecipientAndPendingScopeExpansion() throws {
        var p = try project()
        p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["routing_preset":"codex_led","required_gates":["review"]]])
        let t = try ready(p),parent = try native(p,"policy-parent",domain:"host-A"),target = try native(p,"policy-target",domain:"host-B",provider:"claude"),a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:parent)
        var offer = auth(p,a);offer["child_session_id"] = target.sessionID!;offer["file_scopes"] = [["path":"Sources/Child.swift","access":"write"]]
        assertCode("POLICY_DENIED") { _ = try self.call("work_delegate",offer,parent) }
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"mode":"checkpoint_active","policy":["routing_preset":"shared","required_gates":["review","human_approval"]]])
        var expansion = auth(p,a);expansion["file_scopes"] = [["path":"Sources","access":"write"],["path":"Resources","access":"write"]]
        assertCode("POLICY_ACK_REQUIRED") { _ = try self.call("work_scope_adjust",expansion,parent) }
        expansion["progress"] = "Checkpoint cannot bypass revised scope authority"
        assertCode("POLICY_ACK_REQUIRED") { _ = try self.call("work_checkpoint",expansion,parent) }
    }
    func testOfferedRecipientMustRemainEligibleAtAcceptance() throws {
        var p = try project();let t = try ready(p),parent = try native(p,"offer-parent",domain:"host-A"),target = try native(p,"offer-target",domain:"host-B",provider:"claude"),a = try claim(p,t,caller:parent)
        var input = auth(p,a);input["target_session_id"] = target.sessionID!;input["summary"] = "Explicit healthy handoff"
        let offer = try call("work_handoff_offer",input,parent)
        p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"mode":"future_attempts","policy":["routing_preset":"codex_led","required_gates":["review"]]])
        assertCode("POLICY_DENIED") { _ = try self.call("work_handoff_accept",["project_id":p["id"]!,"offer_id":offer["id"]!],target) }
        var checkpoint = auth(p,a);checkpoint["progress"] = "Original authority retained after recipient denial";_ = try call("work_checkpoint",checkpoint,parent)
    }
    func testRecoveryNeedsStopAndFileEvidenceAndDoesNotUseTimeout() throws {
        let p = try project(),t = try ready(p),a = try claim(p,t,files:[["path":"Sources","access":"write"]])
        let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        var input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":current["revision"]!,"action":"confirm_stopped_revoke","reason":"Process stop observed","observation_refs":["native-process-exit"]]
        assertCode("RECOVERY_REQUIRED") { _ = try self.call("work_recover",input) }
        input["file_state_refs"] = ["fingerprint:reviewed"]
        _ = try call("work_recover",input)
        var checkpoint = auth(p,a);checkpoint["progress"] = "Late writer"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint",checkpoint) }
    }
    func testSourceCapturesDirtyUntrackedAndStalesOnlyRelevantChanges() throws {
        try sourceFixture();let p = try project(),t = try ready(p),a = try claim(p,t),submission = try submitSource(p,a)
        let manifest = try router.dbQueue.read {try router.record($0,submission["manifest_id"] as! String,type:"manifest")},capture = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
        let paths = (capture["files"] as! [JSON]).compactMap {$0["path"] as? String}
        XCTAssertTrue(paths.contains("untracked.txt"));XCTAssertFalse(paths.contains("private/receipt.txt"))
        let snapshot = try router.managedURL(capture["snapshot_path"] as! String,family:"source-captures")
        XCTAssertEqual(try String(contentsOf:snapshot.appendingPathComponent("tracked.txt"),encoding:.utf8),"dirty")
        let current = submission["task"] as! JSON
        let edited = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":current["revision"]!,"patch":["title":"Cosmetic title","order":2]])
        _ = try router.dbQueue.read {try router.validateManifestTarget($0,task:edited,manifestID:submission["manifest_id"] as! String)}
        try write("tracked.txt","changed after capture")
        assertCode("EVIDENCE_STALE") { _ = try self.router.dbQueue.read {try self.router.validateManifestTarget($0,task:edited,manifestID:submission["manifest_id"] as! String)} }
    }
    func testSourceReviewUsesOwnAssessmentWithoutMandatoryExecution() throws {
        try sourceFixture();let p = try project(),a = try claim(p,ready(p)),submission = try submitSource(p,a),reviewer = Caller(role:"owner",installation:"source-reviewer",projectIDs:[]),review = try reviewClaim(p,submission,reviewer)
        assertCode("REVIEW_ASSESSMENT_REQUIRED") { _ = try self.call("review_record",self.reviewInput(p,review,verdict:"pass"),reviewer) }
        var input = reviewInput(p,review,verdict:"pass");input["review_assessment"] = try ownReviewAssessment(p,review,reviewer)
        _ = try call("review_record",input,reviewer)
        let jobs = try router.dbQueue.read {try router.records($0,type:"source_execution",project:p["id"] as? String)};XCTAssertTrue(jobs.isEmpty)
        let t = try call("task_get",["project_id":p["id"]!,"task_id":(submission["task"] as! JSON)["id"]!])
        let done = try call("task_complete",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]);XCTAssertEqual(done["status_category"] as? String,"done")
    }
    func testStableSourceFindingRequiresCurrentTargetResolutionEvidence() throws {
        try sourceFixture();let p = try project(),author = try claim(p,ready(p)),submitted = try submitSource(p,author),reviewer = Caller(role:"owner",installation:"finding-reviewer",projectIDs:[]),review = try reviewClaim(p,submitted,reviewer)
        let firstManifest = try router.dbQueue.read {try router.record($0,submitted["manifest_id"] as! String,type:"manifest")},firstSource = (firstManifest["evidence"] as! JSON)["source_capture"] as! JSON
        let oldRef: JSON = ["source_capture_id":firstSource["id"]!,"sha256":firstSource["sha256"]!]
        var reject = reviewInput(p,review,verdict:"reject");reject["findings"] = [["client_ref":"missing-marker","description":"Expected marker absent","severity":"normal","evidence_refs":[oldRef]]]
        let rejected = try call("review_record",reject,reviewer),finding = (rejected["findings"] as! [JSON])[0]
        try write("marker.txt","verified fix")
        try write("scripts/validate-plan.py","from pathlib import Path\nassert Path('tracked.txt').read_text() == 'dirty'\nassert Path('untracked.txt').read_text() == 'new'\nassert Path('marker.txt').read_text() == 'verified fix'\nprint('fixed captured source')\n")
        let task = try call("task_get",["project_id":p["id"]!,"task_id":review["task_id"]!]),fixAttempt = try claim(p,task),fixed = try submitSource(p,fixAttempt),newReview = try reviewClaim(p,fixed,reviewer),assessment = try ownReviewAssessment(p,newReview,reviewer)
        let newManifest = try router.dbQueue.read {try router.record($0,fixed["manifest_id"] as! String,type:"manifest")},newSource = (newManifest["evidence"] as! JSON)["source_capture"] as! JSON
        var pass = reviewInput(p,newReview,verdict:"pass");pass["review_assessment"] = assessment
        pass["finding_resolutions"] = [["finding_id":finding["id"]!,"disposition":"resolved","reason":"Captured check observed marker","evidence_refs":[oldRef]]]
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.call("review_record",pass,reviewer) }
        pass["finding_resolutions"] = [["finding_id":finding["id"]!,"disposition":"resolved","reason":"Captured check observed marker","evidence_refs":[["source_capture_id":newSource["id"]!,"sha256":newSource["sha256"]!]]]]
        _ = try call("review_record",pass,reviewer)
        let resolved = try router.dbQueue.read {try router.record($0,finding["id"] as! String,type:"finding")}
        XCTAssertEqual(resolved["state"] as? String,"resolved");XCTAssertEqual(resolved["resolved_on_manifest_id"] as? String,fixed["manifest_id"] as? String)
    }
    func testInterruptedSourceProcessRetainsReservationsUntilExplicitRecovery() throws {
        try sourceFixture();let p = try project(),a = try claim(p,ready(p)),submission = try submitSource(p,a),reviewer = Caller(role:"owner",installation:"interrupted-reviewer",projectIDs:[]),review = try reviewClaim(p,submission,reviewer),job = UUID().uuidString
        try router.dbQueue.write { db in try router.save(db,["id":job,"project_id":p["id"]!,"task_id":review["task_id"]!,"attempt_id":review["id"]!,"state":"interrupted","revision":1],type:"source_execution") }
        var release = auth(p,review);release["reason"] = "Cannot silently release an unknown process"
        assertCode("SOURCE_EXECUTION_ACTIVE") { _ = try self.call("work_release",release,reviewer) }
        assertCode("SOURCE_EXECUTION_ACTIVE") { _ = try self.call("review_record",self.reviewInput(p,review,verdict:"reject"),reviewer) }
        var adjust = auth(p,review);adjust["file_scopes"] = []
        assertCode("SOURCE_EXECUTION_ACTIVE") { _ = try self.call("work_scope_adjust",adjust,reviewer) }
        var run = auth(p,review);run["tool"] = "project_script";run["args"] = ["scripts/validate-plan.py"]
        assertCode("UNSUPPORTED_CAPABILITY") { _ = try self.call("source_review_execute",run,reviewer) }
        let task = try call("task_get",["project_id":p["id"]!,"task_id":review["task_id"]!])
        var recover: JSON = ["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"confirm_stopped_revoke","reason":"Native process group stop and files inspected","observation_refs":["observed-native-process-group-stop"],"file_state_refs":["source-and-output-fingerprints"]]
        assertCode("RECOVERY_REQUIRED") { _ = try self.call("work_recover",recover,reviewer) }
        recover["source_execution_ids"] = [job];recover["expected_source_execution_revisions"] = [job:1];_ = try call("work_recover",recover,reviewer)
        let stopped = try call("source_execution_get",["project_id":p["id"]!,"execution_id":job],reviewer);XCTAssertEqual(stopped["state"] as? String,"stopped")
        var checkpoint = auth(p,review);checkpoint["progress"] = "old authority"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint",checkpoint,reviewer) }
    }
    func testUnverifiedStopFlagRetainsAuthorityAcrossDescriptiveFailureStates() throws {
        try sourceFixture();let p = try project(),a = try claim(p,ready(p)),submission = try submitSource(p,a),reviewer = Caller(role:"owner",installation:"unverified-stop-reviewer",projectIDs:[]),review = try reviewClaim(p,submission,reviewer)
        let ids = [UUID().uuidString,UUID().uuidString]
        try router.dbQueue.write { db in
            for (index,state) in ["stale","failed"].enumerated() { try router.save(db,["id":ids[index],"project_id":p["id"]!,"task_id":review["task_id"]!,"attempt_id":review["id"]!,"state":state,"process_stop_unverified":true,"revision":1],type:"source_execution") }
        }
        var release = auth(p,review);release["reason"] = "Descriptive failure does not prove child process stop"
        assertCode("SOURCE_EXECUTION_ACTIVE") { _ = try self.call("work_release",release,reviewer) }
        var run = auth(p,review);run["tool"] = "project_script";run["args"] = ["scripts/validate-plan.py"]
        assertCode("UNSUPPORTED_CAPABILITY") { _ = try self.call("source_review_execute",run,reviewer) }
        let task = try call("task_get",["project_id":p["id"]!,"task_id":review["task_id"]!])
        _ = try call("work_recover",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"action":"confirm_stopped_revoke","reason":"Actual process group stops inspected","observation_refs":["verified-groups-stopped"],"file_state_refs":["reviewed-source-output-state"],"source_execution_ids":ids,"expected_source_execution_revisions":Dictionary(uniqueKeysWithValues:ids.map {($0,1)})],reviewer)
        for id in ids { let stopped = try call("source_execution_get",["project_id":p["id"]!,"execution_id":id],reviewer);XCTAssertEqual(stopped["state"] as? String,"stopped");XCTAssertFalse(bool(stopped,"process_stop_unverified")) }
    }
    func testDisabledRunnerDoesNotCreateAQueuedOrRunningProcess() throws {
        try sourceFixture();let p = try project(),a = try claim(p,ready(p)),submission = try submitSource(p,a),reviewer = Caller(role:"owner",installation:"disabled-runner-reviewer",projectIDs:[]),review = try reviewClaim(p,submission,reviewer)
        var run = auth(p,review);run["tool"] = "swift_test";run["args"] = []
        assertCode("UNSUPPORTED_CAPABILITY") { _ = try self.call("source_review_execute",run,reviewer) }
        let jobs = try router.dbQueue.read {try router.records($0,type:"source_execution",project:p["id"] as? String)};XCTAssertTrue(jobs.isEmpty)
        var release = auth(p,review);release["reason"] = "No service execution was started";_ = try call("work_release",release,reviewer)
    }
    func testDecisionTargetsNeedNoDummyArtifactAndMintProvenance() throws {
        let p = try project(),t = try ready(p,kind:"question"),a = try claim(p,t)
        var input = auth(p,a);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"decision","decision":["text":"Use the blue asset","origin":"forged","actor":"someone else"]]
        let submission = try call("work_submit",input),manifest = try router.dbQueue.read {try router.record($0,submission["manifest_id"] as! String,type:"manifest")},decision = (manifest["evidence"] as! JSON)["decision"] as! JSON
        XCTAssertEqual(decision["origin"] as? String,"human_ui");XCTAssertEqual(decision["actor"] as? String,owner.principal)
        let work = try ready(p),claim = try self.claim(p,work);var bad = auth(p,claim);bad["acceptance_revision"] = 1;bad["evidence_manifest"] = input["evidence_manifest"]
        assertCode("INVALID_INPUT") { _ = try self.call("work_submit",bad) }
    }
}
