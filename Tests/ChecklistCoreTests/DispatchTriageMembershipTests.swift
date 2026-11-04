import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-423 rework: real dispatch routes over private synthetic stores, without a native host.
final class DispatchTriageMembershipTests: XCTestCase {
    private var root: URL!, workspace: URL!, router: CommandRouter!, project: JSON!
    private let owner = Caller(role: "owner", installation: "dispatch-membership-owner", projectIDs: [])

    private enum Route: String, CaseIterable {
        case codex = "codex_thread_start", handoff = "work_handoff_offer", delegate = "work_delegate"
    }
    private enum Scenario { case own, other, none, missingFromOwn, differentFromOwn, plan }
    private struct Fixture {
        let caller: Caller, recipient: Caller, task: JSON, attempt: JSON?
        let joined: JSON?, mine: JSON?
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("dispatch-membership-" + uuid())
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        router = try CommandRouter(root: root.appendingPathComponent("store"))
        project = try call("project_create", ["name": "Dispatch fixture", "key_prefix": "DM", "root_path": workspace.path])
    }

    override func tearDownWithError() throws {
        try router?.closeStore(); router = nil
        // The bounded runner retains this owned fixture below its assigned TMPDIR.
    }

    @discardableResult private func call(_ method: String, _ input: JSON = [:], _ caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var params = input
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = command ?? uuid() }
        return try router.handle(method: method, params: fixtureTaskInput(router, method: method, input: params), caller: caller ?? owner)["data"] as! JSON
    }
    private func worker(_ label: String) throws -> Caller {
        let sid = uuid()
        _ = try call("session_register", ["project_id": project["id"]!, "session_id": sid, "provider": "codex", "role": "worker", "installation": label, "workspace": workspace.path, "execution_domain": label])
        return Caller(role: "worker", installation: label, projectIDs: [project["id"] as! String], sessionID: sid, workspace: workspace.path, executionDomain: label)
    }
    private func start(_ caller: Caller, name: String = "This pass") throws -> JSON {
        try call("triage_orchestrate", ["project_id": project["id"]!, "action": "start", "name": name], caller)
    }
    private func ready() throws -> JSON {
        let task = try call("task_create", ["project_id": project["id"]!, "title": "Dispatched work", "brief": "An observable result"])
        return try call("task_edit", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
    }
    private func current(_ value: JSON, type: String = "task") throws -> JSON {
        try router.dbQueue.read { try router.record($0, value["id"] as! String, type: type) }
    }
    private func members(_ group: JSON) throws -> [String] { router.triageMemberIDs(try current(group, type: "group")) }
    private func add(_ task: JSON, to group: JSON, caller: Caller) throws {
        _ = try call("group_membership", ["project_id": project["id"]!, "group_id": group["id"]!, "task_id": task["id"]!, "expected_revision": try current(group, type: "group")["revision"]!, "action": "add"], caller)
    }
    private func claim(_ task: JSON, _ caller: Caller) throws -> JSON {
        try call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": try current(task)["revision"]!], caller)
    }
    private func membership(_ reply: JSON) throws -> JSON { try XCTUnwrap(reply["triage_membership"] as? JSON) }
    private func notices(_ reply: JSON) -> [String] { (reply["_checklist"] as? JSON)?["notices"] as? [String] ?? [] }

    private func fixture(_ scenario: Scenario, route: Route) throws -> Fixture {
        let caller = try worker("dispatcher"), recipient = try worker("recipient"), task = try ready()
        // Offers require an existing claim. Establish it before any membership setup so
        // its ordinary claim move cannot hide an unintended move by the dispatch route.
        let attempt = route == .codex ? nil : try claim(task, caller)
        var joined: JSON?, mine: JSON?
        switch scenario {
        case .own:
            mine = try start(caller); joined = mine
            try add(task, to: joined!, caller: caller)
        case .other:
            let orchestrator = try worker("other-orchestrator")
            joined = try start(orchestrator, name: "Other pass")
            try add(task, to: joined!, caller: orchestrator)
        case .none:
            break
        case .missingFromOwn:
            mine = try start(caller)
        case .differentFromOwn:
            mine = try start(caller)
            let orchestrator = try worker("other-orchestrator")
            joined = try start(orchestrator, name: "Other pass")
            try add(task, to: joined!, caller: orchestrator)
        case .plan:
            joined = try call("triage_create", ["project_id": project["id"]!, "name": "Next pass"])
            try add(task, to: joined!, caller: owner)
        }
        return Fixture(caller: caller, recipient: recipient, task: task, attempt: attempt, joined: joined, mine: mine)
    }

    private func dispatch(_ route: Route, _ fixture: Fixture, command: String? = nil, extra: JSON = [:]) throws -> JSON {
        var input: JSON = ["project_id": project["id"]!]
        switch route {
        case .codex:
            input["task_id"] = fixture.task["id"]!
        case .handoff, .delegate:
            input["attempt_id"] = fixture.attempt!["id"]!; input["claim_token"] = fixture.attempt!["claim_token"]!
            if route == .handoff {
                input["target_session_id"] = fixture.recipient.sessionID!; input["summary"] = "Continue this bounded work"
            } else {
                input["child_session_id"] = fixture.recipient.sessionID!; input["file_scopes"] = [JSON](); input["lane_scopes"] = [JSON](); input["brief"] = "Inspect this bounded work"
            }
        }
        input.merge(extra) { _, new in new }
        return try call(route.rawValue, input, fixture.caller, command: command)
    }

    private func promptLine(_ fixture: Fixture) -> String {
        let key = fixture.task["key"] as! String
        guard let joined = fixture.joined else { return "\(key) is in no Triage; ask the conversation that sent you this work to add it." }
        guard let orchestrator = router.triageOrchestratorSession(joined) else {
            return "\(key) is in Triage \(AgentReference.text(joined)), a plan with no orchestrator; your claim removes it from that plan. Ask the conversation that sent you this work to add it to its Triage. Do not call triage_orchestrate."
        }
        return "Your claim keeps \(key) in Triage \(AgentReference.text(joined)), which conversation \(AgentReference.quoted(orchestrator)) holds. Do not call triage_orchestrate."
    }

    private func assertPrompt(_ reply: JSON, _ fixture: Fixture, prepared: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let task = fixture.task
        let base = try router.ticketThreadInstruction(key: task["key"] as! String, title: task["title"] as! String, root: workspace.path, projectID: project["id"] as! String, taskID: task["id"] as! String)
        let expected = base + "\n" + promptLine(fixture)
        if prepared {
            XCTAssertEqual((reply["host_request"] as? JSON)?["prompt"] as? String, expected, file: file, line: line)
        }
        let fallback = try XCTUnwrap(reply["fallback"] as? JSON, file: file, line: line)
        XCTAssertEqual(fallback["instruction"] as? String, expected, file: file, line: line)
        XCTAssertEqual(fallback["owner_send_required"] as? Bool, true, file: file, line: line)
        if let url = fallback["compose_url"] as? String, let components = URLComponents(string: url) {
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "prompt" })?.value, expected, file: file, line: line)
        }
    }

    private func assertCase(_ scenario: Scenario, route: Route, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try fixture(scenario, route: route), before = try current(f.task)
        let groups = try [f.joined, f.mine].compactMap { $0 }.map { try current($0, type: "group") }
        let reply = try dispatch(route, f), statement = try membership(reply), key = f.task["key"] as! String
        XCTAssertEqual(try jsonString(current(f.task)), try jsonString(before), "Dispatch must not claim, reassign or change the ticket.", file: file, line: line)
        for group in groups {
            XCTAssertEqual(try jsonString(current(group, type: "group")), try jsonString(group), "Dispatch must only observe membership.", file: file, line: line)
        }
        if route == .codex { try assertPrompt(reply, f, file: file, line: line) }
        else {
            XCTAssertEqual(reply["state"] as? String, "offered", file: file, line: line)
            XCTAssertEqual(reply["task_id"] as? String, f.task["id"] as? String, file: file, line: line)
            XCTAssertEqual(reply["target_session_id"] as? String, f.recipient.sessionID, file: file, line: line)
        }
        switch scenario {
        case .own, .other:
            let joined = try XCTUnwrap(f.joined), reference = AgentReference.text(joined)
            let expected = scenario == .own ? "\(key) is in your Triage \(reference)." : "\(key) stays in \(reference), which another conversation orchestrates. You are the ticket holder; its notes reach you and that orchestrator."
            XCTAssertEqual(statement["state"] as? String, "member", file: file, line: line)
            XCTAssertEqual(statement["triage_id"] as? String, joined["id"] as? String, file: file, line: line)
            XCTAssertEqual(statement["plan"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(statement["text"] as? String, expected, file: file, line: line)
            XCTAssertNil(statement["start_command"], file: file, line: line); XCTAssertNil(statement["add_command"], file: file, line: line)
            XCTAssertTrue(notices(reply).isEmpty, file: file, line: line)
        case .none:
            let expected = "\(key) is in no Triage, so only you get its notes. If a conversation sent you this work, ask it to add \(key) to its Triage (group_membership add). If you orchestrate this work, call triage_orchestrate action=start without triage_id, then use add_command."
            XCTAssertEqual(statement["state"] as? String, "none", file: file, line: line)
            XCTAssertEqual(statement["text"] as? String, expected, file: file, line: line)
            XCTAssertEqual(notices(reply), [expected], file: file, line: line)
            let startCommand = try XCTUnwrap(statement["start_command"] as? JSON), startArgs = try XCTUnwrap(startCommand["arguments"] as? JSON)
            XCTAssertEqual(startCommand["method"] as? String, "triage_orchestrate", file: file, line: line)
            XCTAssertEqual(startArgs["action"] as? String, "start", file: file, line: line); XCTAssertNil(startArgs["triage_id"], file: file, line: line)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(startArgs["command_id"] as? String)), file: file, line: line)
            let triage = try call("triage_orchestrate", startArgs, f.caller, command: startArgs["command_id"] as? String)
            XCTAssertTrue(try members(triage).isEmpty, file: file, line: line)
            let addCommand = try XCTUnwrap(statement["add_command"] as? JSON)
            var args = try XCTUnwrap(addCommand["arguments"] as? JSON)
            XCTAssertEqual(addCommand["method"] as? String, "group_membership", file: file, line: line)
            XCTAssertEqual(args["group_id"] as? String, "<triage_id from start_command>", file: file, line: line)
            XCTAssertEqual(args["expected_revision"] as? String, "<revision from start_command>", file: file, line: line)
            XCTAssertEqual(args["command_id"] as? String, "<new UUID>", file: file, line: line)
            XCTAssertEqual(args["task_id"] as? String, f.task["id"] as? String, file: file, line: line)
            args["group_id"] = triage["id"]; args["expected_revision"] = triage["revision"]
            _ = try call("group_membership", args, f.caller)
            XCTAssertEqual(try members(triage), [f.task["id"] as! String], file: file, line: line)
        case .missingFromOwn, .differentFromOwn:
            let mine = try XCTUnwrap(f.mine)
            let prefix = f.joined.map { "\(key) is in \(AgentReference.text($0, projectName: project["name"] as? String))." } ?? "\(key) is in no Triage."
            let expected = "\(prefix) You orchestrate \(AgentReference.text(mine, projectName: project["name"] as? String)). Use add_command to add this ticket, and supply a new UUID as its command_id. Do not add a split or follow-up ticket that goes to the next unstarted plan."
            XCTAssertEqual(statement["state"] as? String, f.joined == nil ? "none" : "member", file: file, line: line)
            XCTAssertEqual(statement["triage_id"] as? String, f.joined?["id"] as? String, file: file, line: line)
            XCTAssertEqual(statement["text"] as? String, expected, file: file, line: line)
            XCTAssertEqual((statement["caller_triage"] as? JSON)?["triage_id"] as? String, mine["id"] as? String, file: file, line: line)
            XCTAssertNil(statement["start_command"], file: file, line: line); XCTAssertTrue(notices(reply).isEmpty, file: file, line: line)
            XCTAssertTrue(try members(mine).isEmpty, file: file, line: line)
            if let joined = f.joined { XCTAssertEqual(try members(joined), [f.task["id"] as! String], file: file, line: line) }
            let addCommand = try XCTUnwrap(statement["add_command"] as? JSON), args = try XCTUnwrap(addCommand["arguments"] as? JSON)
            XCTAssertEqual(addCommand["method"] as? String, "group_membership", file: file, line: line)
            XCTAssertEqual(args["group_id"] as? String, mine["id"] as? String, file: file, line: line)
            XCTAssertEqual((args["expected_revision"] as? NSNumber)?.intValue, (try current(mine, type: "group")["revision"] as? NSNumber)?.intValue, file: file, line: line)
            XCTAssertEqual(args["task_id"] as? String, f.task["id"] as? String, file: file, line: line)
            XCTAssertNil(args["command_id"], file: file, line: line)
            _ = try call("group_membership", args, f.caller)
            XCTAssertEqual(try members(mine), [f.task["id"] as! String], file: file, line: line)
            if let joined = f.joined { XCTAssertTrue(try members(joined).isEmpty, file: file, line: line) }
        case .plan:
            let plan = try XCTUnwrap(f.joined)
            XCTAssertEqual(statement["state"] as? String, "member", file: file, line: line)
            XCTAssertEqual(statement["triage_id"] as? String, plan["id"] as? String, file: file, line: line)
            XCTAssertEqual(statement["plan"] as? Bool, true, file: file, line: line)
            XCTAssertEqual(statement["text"] as? String, "\(key) is in \(AgentReference.text(plan, projectName: project["name"] as? String)).", file: file, line: line)
            XCTAssertNil(statement["start_command"], file: file, line: line); XCTAssertNil(statement["add_command"], file: file, line: line)
            XCTAssertTrue(notices(reply).isEmpty, file: file, line: line)
            XCTAssertEqual(try members(plan), [f.task["id"] as! String], file: file, line: line)
        }
    }

    func testCodexStartReportsOwnTriageWithoutMovingTicket() throws { try assertCase(.own, route: .codex) }
    func testCodexStartReportsOtherOrchestratorsTriage() throws { try assertCase(.other, route: .codex) }
    func testCodexStartUngroupedHasExecutableStartAndAddTemplate() throws { try assertCase(.none, route: .codex) }
    func testCodexStartMissingFromOwnTriageHasExecutableAdd() throws { try assertCase(.missingFromOwn, route: .codex) }
    func testCodexStartDifferentTriageHasAddWithoutMovingCurrentMember() throws { try assertCase(.differentFromOwn, route: .codex) }
    func testCodexStartKeepsPlanAndExplainsClaimRemovesMembership() throws { try assertCase(.plan, route: .codex) }
    func testHandoffOfferReportsOwnTriageWithoutMovingTicket() throws { try assertCase(.own, route: .handoff) }
    func testHandoffOfferReportsOtherOrchestratorsTriage() throws { try assertCase(.other, route: .handoff) }
    func testHandoffOfferUngroupedHasExecutableStartAndAddTemplate() throws { try assertCase(.none, route: .handoff) }
    func testHandoffOfferMissingFromOwnTriageHasExecutableAdd() throws { try assertCase(.missingFromOwn, route: .handoff) }
    func testHandoffOfferDifferentTriageHasAddWithoutMovingCurrentMember() throws { try assertCase(.differentFromOwn, route: .handoff) }
    func testHandoffOfferKeepsPlanMembership() throws { try assertCase(.plan, route: .handoff) }
    func testDelegateOfferReportsOwnTriageWithoutMovingTicket() throws { try assertCase(.own, route: .delegate) }
    func testDelegateOfferReportsOtherOrchestratorsTriage() throws { try assertCase(.other, route: .delegate) }
    func testDelegateOfferUngroupedHasExecutableStartAndAddTemplate() throws { try assertCase(.none, route: .delegate) }
    func testDelegateOfferMissingFromOwnTriageHasExecutableAdd() throws { try assertCase(.missingFromOwn, route: .delegate) }
    func testDelegateOfferDifferentTriageHasAddWithoutMovingCurrentMember() throws { try assertCase(.differentFromOwn, route: .delegate) }
    func testDelegateOfferKeepsPlanMembership() throws { try assertCase(.plan, route: .delegate) }

    func testCodexAllHostOutcomesCarryMembershipAndFallbackPrompt() throws {
        let f = try fixture(.other, route: .codex), prepared = try dispatch(.codex, f)
        let expected = try jsonString(membership(prepared)), taskBefore = try current(f.task)
        for outcome in ["created", "unavailable", "refused", "failed"] {
            var extra: JSON = ["host_outcome": outcome, "host_detail": "Synthetic host outcome"]
            if outcome == "created" { extra["thread_id"] = uuid() }
            let reply = try dispatch(.codex, f, extra: extra)
            XCTAssertEqual(try jsonString(membership(reply)), expected)
            XCTAssertEqual(reply["state"] as? String, outcome == "created" ? "host_created" : outcome)
            XCTAssertEqual(reply["claim_acquired"] as? Bool, false); XCTAssertEqual(reply["assignment_changed"] as? Bool, false)
            if outcome == "created" { XCTAssertNil(reply["fallback"]) }
            else { try assertPrompt(reply, f, prepared: false) }
        }
        XCTAssertEqual(try jsonString(current(f.task)), try jsonString(taskBefore))
        XCTAssertEqual(try members(f.joined!), [f.task["id"] as! String])
    }

    func testDispatchReplayRetainsOriginalMembershipNoticeAndStartCommand() throws {
        for route in Route.allCases {
            let f = try fixture(.none, route: route), command = uuid()
            let first = try dispatch(route, f, command: command), replay = try dispatch(route, f, command: command)
            XCTAssertEqual(try jsonString(membership(first)), try jsonString(membership(replay)), route.rawValue)
            XCTAssertEqual(notices(first), notices(replay), route.rawValue)
            XCTAssertEqual(first["id"] as? String, replay["id"] as? String, route.rawValue)
            XCTAssertNil(try router.dbQueue.read { try router.callerOrchestratedTriage($0, project: project["id"] as! String, caller: f.caller) })
        }
    }
}
