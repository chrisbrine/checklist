import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-423: real router replies over private synthetic stores; no native host or Keychain.
final class ClaimTriageMembershipTests: XCTestCase {
    private var root: URL!, workspace: URL!, router: CommandRouter!, project: JSON!
    private let owner = Caller(role: "owner", installation: "claim-membership-owner", projectIDs: [])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("claim-membership-" + uuid())
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        router = try CommandRouter(root: root.appendingPathComponent("store"))
        project = try call("project_create", ["name": "Membership fixture", "key_prefix": "CM", "root_path": workspace.path])
    }
    override func tearDownWithError() throws {
        try router?.closeStore(); router = nil
        // Bounded qualification can retain its owned evidence for the orchestrator.
        if ProcessInfo.processInfo.environment["CHECKLIST_RETAIN_TEST_FIXTURES"] != "1", let root {
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        }
    }
    @discardableResult private func call(_ method: String, _ input: JSON = [:], _ caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var params = input
        if method == "work_submit" { params = try fixtureAcceptanceEvidence(router, input: params) }
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = command ?? uuid() }
        return try router.handle(method: method, params: fixtureTaskInput(router, method: method, input: params), caller: caller ?? owner)["data"] as! JSON
    }
    private func worker(_ label: String, project p: JSON? = nil, workspace path: URL? = nil, sessionID: String? = nil) throws -> Caller {
        let p = p ?? project!, path = path ?? workspace!, sid = sessionID ?? uuid()
        var registration: JSON = ["project_id": p["id"]!, "session_id": sid, "provider": "codex", "role": "worker", "installation": label, "workspace": path.path, "execution_domain": label]
        if sessionID != nil { registration["project_ids"] = [project["id"]!, p["id"]!] }
        _ = try call("session_register", registration)
        return Caller(role: "worker", installation: label, projectIDs: [p["id"] as! String], sessionID: sid, workspace: path.path, executionDomain: label)
    }
    private func start(_ caller: Caller, name: String = "This pass", project p: JSON? = nil) throws -> JSON {
        try call("triage_orchestrate", ["project_id": (p ?? project!)["id"]!, "action": "start", "name": name], caller)
    }
    private func ready() throws -> JSON {
        let task = try call("task_create", ["project_id": project["id"]!, "title": "Grouped work", "brief": "An observable result"])
        return try call("task_edit", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
    }
    private func current(_ value: JSON, type: String = "task") throws -> JSON {
        try router.dbQueue.read { try router.record($0, value["id"] as! String, type: type) }
    }
    private func members(_ group: JSON) throws -> [String] { router.triageMemberIDs(try current(group, type: "group")) }
    private func add(_ task: JSON, to group: JSON, caller: Caller) throws {
        _ = try call("group_membership", ["project_id": project["id"]!, "group_id": group["id"]!, "task_id": task["id"]!, "expected_revision": try current(group, type: "group")["revision"]!, "action": "add"], caller)
    }
    private func claim(_ task: JSON, _ caller: Caller, command: String? = nil) throws -> JSON {
        try call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": try current(task)["revision"]!], caller, command: command)
    }
    private func membership(_ reply: JSON) throws -> JSON { try XCTUnwrap(reply["triage_membership"] as? JSON) }
    private func notices(_ reply: JSON) -> [String] { (reply["_checklist"] as? JSON)?["notices"] as? [String] ?? [] }

    func testClaimByOrchestratorReportsMembershipAfterMove() throws {
        let caller = try worker("orchestrator"), triage = try start(caller), task = try ready()
        let reply = try claim(task, caller), statement = try membership(reply)
        XCTAssertEqual(statement["state"] as? String, "member")
        XCTAssertEqual(statement["triage_id"] as? String, triage["id"] as? String)
        XCTAssertEqual(statement["text"] as? String, "\(task["key"]!) is in your Triage \(triage["key"]!) \"This pass\".")
        XCTAssertEqual(try members(triage), [task["id"] as! String])
        XCTAssertTrue(notices(reply).isEmpty)
    }

    func testHelperClaimKeepsOtherConversationsTriageAndExplainsNoteRouting() throws {
        let orchestrator = try worker("orchestrator"), helper = try worker("helper"), triage = try start(orchestrator), task = try ready()
        try add(task, to: triage, caller: orchestrator)
        let reply = try claim(task, helper), statement = try membership(reply)
        XCTAssertEqual(statement["state"] as? String, "member")
        XCTAssertEqual(statement["triage_id"] as? String, triage["id"] as? String)
        XCTAssertEqual(statement["text"] as? String, "\(task["key"]!) stays in \(triage["key"]!) \"This pass\", which another conversation orchestrates. You are the ticket holder; its notes reach you and that orchestrator.")
        XCTAssertEqual(try members(triage), [task["id"] as! String]); XCTAssertTrue(notices(reply).isEmpty)
    }

    func testUngroupedClaimHasNoticeAndExecutableStartWithAddTemplate() throws {
        let helper = try worker("helper"), task = try ready(), reply = try claim(task, helper), statement = try membership(reply)
        let text = "\(task["key"]!) is in no Triage, so only you get its notes. If a conversation sent you this work, ask it to add \(task["key"]!) to its Triage (group_membership add). If you orchestrate this work, call triage_orchestrate action=start without triage_id, then use add_command."
        XCTAssertEqual(statement["state"] as? String, "none"); XCTAssertEqual(statement["text"] as? String, text)
        XCTAssertEqual(notices(reply), [text])
        let startCommand = try XCTUnwrap(statement["start_command"] as? JSON), startArguments = try XCTUnwrap(startCommand["arguments"] as? JSON)
        XCTAssertEqual(startCommand["method"] as? String, "triage_orchestrate"); XCTAssertNil(startArguments["triage_id"])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(startArguments["command_id"] as? String)))
        XCTAssertEqual(startArguments["project_id"] as? String, project["id"] as? String)
        let triage = try call("triage_orchestrate", startArguments, helper, command: startArguments["command_id"] as? String)
        XCTAssertTrue(try members(triage).isEmpty, "The claim and start never automatically group this ticket.")
        let addCommand = try XCTUnwrap(statement["add_command"] as? JSON)
        XCTAssertEqual(addCommand["method"] as? String, "group_membership")
        var arguments = try XCTUnwrap(addCommand["arguments"] as? JSON)
        XCTAssertEqual(arguments["task_id"] as? String, task["id"] as? String)
        XCTAssertTrue(arguments["group_id"] is String); XCTAssertTrue(arguments["expected_revision"] is String)
        arguments["group_id"] = triage["id"]; arguments["expected_revision"] = triage["revision"]
        _ = try call("group_membership", arguments, helper)
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testMissingMembershipFallbackReusesTaskCreateAddCommandForOrchestrator() throws {
        let caller = try worker("orchestrator"), triage = try start(caller), task = try ready()
        // C2 is defensive: a successful claim normally joins the caller's Triage.
        // Exercise the shared reply builder against the missing post-move state.
        let statement = try router.dbQueue.read { try router.claimTriageMembership($0, task: task, caller: caller) }
        let expected = try router.dbQueue.read { try router.taskCreateTriageMembership($0, task: task, joined: nil, caller: caller) }
        XCTAssertEqual(try jsonString(statement), try jsonString(expected))
        XCTAssertEqual(statement["state"] as? String, "none"); XCTAssertNil(statement["start_command"])
        let command = try XCTUnwrap(statement["add_command"] as? JSON)
        _ = try call("group_membership", try XCTUnwrap(command["arguments"] as? JSON), caller)
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testClaimOnPlanReportsNoneAfterLeavingPlan() throws {
        let helper = try worker("helper"), task = try ready()
        let plan = try call("triage_create", ["project_id": project["id"]!, "name": "Next pass"])
        try add(task, to: plan, caller: owner)
        let reply = try claim(task, helper)
        XCTAssertEqual(try membership(reply)["state"] as? String, "none"); XCTAssertEqual(notices(reply).count, 1)
        XCTAssertTrue(try members(plan).isEmpty)
    }

    func testTakeoverReportsUnchangedTriageForHelper() throws {
        let orchestrator = try worker("orchestrator"), earlier = try worker("earlier"), helper = try worker("helper")
        let triage = try start(orchestrator), task = try ready(); try add(task, to: triage, caller: orchestrator)
        _ = try claim(task, earlier)
        let reply = try call("work_takeover", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": try current(task)["revision"]!, "reason": "Continue this work"], helper)
        XCTAssertEqual(try membership(reply)["triage_id"] as? String, triage["id"] as? String)
        XCTAssertTrue((try membership(reply)["text"] as! String).contains("another conversation orchestrates"))
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testAcceptedHandoffReportsMembershipAfterOrchestratorMove() throws {
        let earlier = try worker("earlier"), receiver = try worker("receiver"), triage = try start(receiver), task = try ready(), attempt = try claim(task, earlier)
        let offer = try call("work_handoff_offer", ["project_id": project["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "target_session_id": receiver.sessionID!, "summary": "Continue this work"], earlier)
        let reply = try call("work_handoff_accept", ["project_id": project["id"]!, "offer_id": offer["id"]!], receiver)
        XCTAssertEqual(try membership(reply)["state"] as? String, "member")
        XCTAssertEqual(try membership(reply)["triage_id"] as? String, triage["id"] as? String)
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testBatchClaimItemsAndParentCarryUngroupedNotices() throws {
        let helper = try worker("helper"), tasks = try [ready(), ready()]
        let plan = try call("triage_create", ["project_id": project["id"]!, "name": "Batch plan"])
        for task in tasks { try add(task, to: plan, caller: owner) }
        let entries: [JSON] = try tasks.map { ["task_id": $0["id"]!, "expected_revision": try current($0)["revision"]!] }
        let batch = try call("batch_prepare", ["project_id": project["id"]!, "triage_id": plan["id"]!, "expected_revision": try current(plan, type: "group")["revision"]!, "phase": "implementation", "tasks": entries], helper)
        let reply = try call("batch_claim", ["project_id": project["id"]!, "batch_id": batch["id"]!, "expected_revision": batch["revision"]!, "policy_revision": batch["policy_revision"]!], helper)
        let claims = try XCTUnwrap(reply["claims"] as? [JSON]); XCTAssertEqual(claims.count, 2)
        for (claim, task) in zip(claims, tasks) {
            let statement = try membership(claim)
            XCTAssertEqual(statement["state"] as? String, "none")
            XCTAssertTrue((statement["text"] as! String).hasPrefix(task["key"] as! String))
            XCTAssertEqual(notices(claim), [statement["text"] as! String])
        }
        XCTAssertEqual(notices(reply), claims.flatMap { notices($0) }); XCTAssertTrue(try members(plan).isEmpty)
    }

    func testReviewClaimCarriesStatementAfterOrchestratorMove() throws {
        let author = try worker("author"), reviewer = try worker("reviewer"), triage = try start(reviewer), task = try ready(), attempt = try claim(task, author)
        let file = workspace.appendingPathComponent("result.txt"); try Data("Synthetic result".utf8).write(to: file)
        let artifact = try call("attachment_add", ["project_id": project["id"]!, "task_id": task["id"]!, "path": file.path], author)
        let submitted = try call("work_submit", ["project_id": project["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "acceptance_revision": 1, "evidence_manifest": ["artifact_refs": [["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]]]], author)
        let reply = try call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": (submitted["task"] as! JSON)["revision"]!, "phase": "review", "review_request_id": (submitted["review_request_ids"] as! [String])[0], "target_manifest_id": submitted["manifest_id"]!, "gate": "review"], reviewer)
        XCTAssertEqual(try membership(reply)["triage_id"] as? String, triage["id"] as? String)
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testReturnedClaimPickupTruthfullyReportsFinishedTriageAsPlan() throws {
        let author = try worker("author"), reviewer = try worker("reviewer"), triage = try start(author), task = try ready(), attempt = try claim(task, author)
        let file = workspace.appendingPathComponent("returned-result.txt"); try Data("Synthetic result".utf8).write(to: file)
        let artifact = try call("attachment_add", ["project_id": project["id"]!, "task_id": task["id"]!, "path": file.path], author)
        let submitted = try call("work_submit", ["project_id": project["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "acceptance_revision": 1, "evidence_manifest": ["artifact_refs": [["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]]]], author)
        let review = try call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": (submitted["task"] as! JSON)["revision"]!, "phase": "review", "review_request_id": (submitted["review_request_ids"] as! [String])[0], "target_manifest_id": submitted["manifest_id"]!, "gate": "review"], reviewer)
        let returned = try call("review_record", ["project_id": project["id"]!, "attempt_id": review["id"]!, "claim_token": review["claim_token"]!, "review_request_id": review["review_request_id"]!, "target_manifest_id": review["manifest_id"]!, "gate": "review", "verdict": "evidence_missing", "reason": "Supply the missing observation"], reviewer)
        XCTAssertEqual((returned["implementation_return"] as? JSON)?["state"] as? String, "active")
        _ = try call("triage_orchestrate", ["project_id": project["id"]!, "triage_id": triage["id"]!, "expected_revision": try current(triage, type: "group")["revision"]!, "action": "finish", "reason": "End this pass"], author)
        let reply = try claim(task, author), statement = try membership(reply)
        XCTAssertEqual(statement["state"] as? String, "member"); XCTAssertEqual(statement["plan"] as? Bool, true)
        XCTAssertEqual(statement["triage_id"] as? String, triage["id"] as? String)
        XCTAssertFalse((statement["text"] as! String).contains("another conversation orchestrates"))
        XCTAssertEqual(try members(triage), [task["id"] as! String]); XCTAssertTrue(notices(reply).isEmpty)
    }

    func testReturnedClaimPickupUsesAddGuidanceForNewlyStartedTriage() throws {
        let author = try worker("author"), reviewer = try worker("reviewer"), task = try ready(), attempt = try claim(task, author)
        let file = workspace.appendingPathComponent("returned-result.txt"); try Data("Synthetic result".utf8).write(to: file)
        let artifact = try call("attachment_add", ["project_id": project["id"]!, "task_id": task["id"]!, "path": file.path], author)
        let submitted = try call("work_submit", ["project_id": project["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "acceptance_revision": 1, "evidence_manifest": ["artifact_refs": [["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]]]], author)
        let review = try call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": (submitted["task"] as! JSON)["revision"]!, "phase": "review", "review_request_id": (submitted["review_request_ids"] as! [String])[0], "target_manifest_id": submitted["manifest_id"]!, "gate": "review"], reviewer)
        let returned = try call("review_record", ["project_id": project["id"]!, "attempt_id": review["id"]!, "claim_token": review["claim_token"]!, "review_request_id": review["review_request_id"]!, "target_manifest_id": review["manifest_id"]!, "gate": "review", "verdict": "evidence_missing", "reason": "Supply the missing observation"], reviewer)
        XCTAssertEqual((returned["implementation_return"] as? JSON)?["state"] as? String, "active")
        let triage = try start(author), reply = try claim(task, author), statement = try membership(reply)
        let freshTask = try current(task)
        let expected = try router.dbQueue.read { try router.taskCreateTriageMembership($0, task: freshTask, joined: nil, caller: author) }
        XCTAssertEqual(try jsonString(statement), try jsonString(expected))
        XCTAssertEqual(statement["state"] as? String, "none"); XCTAssertNil(statement["start_command"])
        XCTAssertEqual((statement["caller_triage"] as? JSON)?["triage_id"] as? String, triage["id"] as? String)
        XCTAssertTrue(notices(reply).isEmpty)
        let command = try XCTUnwrap(statement["add_command"] as? JSON)
        _ = try call("group_membership", try XCTUnwrap(command["arguments"] as? JSON), author)
        XCTAssertEqual(try members(triage), [task["id"] as! String])
    }

    func testServiceInfoReportsNullThenCurrentProjectTriageAndCatalogScope() throws {
        let caller = try worker("orchestrator")
        XCTAssertTrue((try call("service_info", [:], caller)["caller"] as! JSON)["orchestrated_triage"] is NSNull)
        let triage = try start(caller)
        let info = try call("service_info", [:], caller), mine = try XCTUnwrap((info["caller"] as? JSON)?["orchestrated_triage"] as? JSON)
        XCTAssertEqual(mine["triage_id"] as? String, triage["id"] as? String)
        XCTAssertEqual(mine["key"] as? String, triage["key"] as? String); XCTAssertEqual(mine["name"] as? String, "This pass")
        let tool = try XCTUnwrap(router.toolCatalog(caller).first { $0["name"] as? String == "service_info" })
        XCTAssertNotNil(((tool["inputSchema"] as? JSON)?["properties"] as? JSON)?["project_id"])
        XCTAssertFalse(strings(tool["inputSchema"] as? JSON ?? [:], "required").contains("project_id"))
    }

    func testServiceInfoDoesNotLeakOtherProjectsOrInventWorkspaceBinding() throws {
        let caller = try worker("orchestrator"); _ = try start(caller)
        let foreignWorkspace = root.appendingPathComponent("foreign"); try FileManager.default.createDirectory(at: foreignWorkspace, withIntermediateDirectories: true)
        let foreign = try call("project_create", ["name": "Other project", "key_prefix": "OTHER", "root_path": foreignWorkspace.path])
        let foreignCaller = try worker("orchestrator", project: foreign, workspace: foreignWorkspace, sessionID: caller.sessionID)
        let foreignTriage = try start(foreignCaller, name: "Other pass", project: foreign)
        let multiple = Caller(role: "worker", installation: caller.installation, projectIDs: [project["id"] as! String, foreign["id"] as! String], sessionID: caller.sessionID, workspace: workspace.path, executionDomain: caller.executionDomain)
        let info = try call("service_info", [:], multiple)
        XCTAssertFalse(try jsonString((info["caller"] as! JSON)["orchestrated_triage"] as! JSON).contains(foreignTriage["id"] as! String))
        XCTAssertThrowsError(try call("service_info", ["project_id": foreign["id"]!], caller)) { XCTAssertEqual(($0 as? CoreError)?.code, "FORBIDDEN") }
        XCTAssertThrowsError(try call("service_info", ["project_id": foreign["id"]!], multiple)) { XCTAssertEqual(($0 as? CoreError)?.code, "ROOT_MISMATCH") }
        let unbound = Caller(role: "worker", installation: caller.installation, projectIDs: multiple.projectIDs, sessionID: caller.sessionID, executionDomain: caller.executionDomain)
        XCTAssertTrue((try call("service_info", [:], unbound)["caller"] as! JSON)["orchestrated_triage"] is NSNull)
    }

    func testClaimNoticeCoexistsWithPendingNoteAndReplaysOriginalStatement() throws {
        let helper = try worker("helper"), task = try ready()
        _ = try call("message_send", ["project_id": project["id"]!, "task_id": task["id"]!, "body": "Read this note", "recipient": ["kind": "session", "session_id": helper.sessionID!]])
        let command = uuid(), input: JSON = ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": task["revision"]!]
        let reply = try call("work_claim", input, helper, command: command)
        XCTAssertNotNil((reply["_checklist"] as? JSON)?["pending_notes"]); XCTAssertEqual(notices(reply).count, 1)
        let replay = try call("work_claim", input, helper, command: command)
        XCTAssertEqual(try jsonString(membership(reply)), try jsonString(membership(replay)))
        XCTAssertEqual(notices(reply), notices(replay))
    }
}
