import XCTest
import GRDB
@testable import ChecklistCore

/// Owner decision 2026-10-18: Checklist is AI-first. Enrolled agents change rules and settings with agent provenance;
/// the owner can limit a project to app-only changes, and only the owner can move that switch.
extension CoreTests {
    func agentChangeFixture(provider: String = "claude") throws -> (project: JSON, agent: Caller) {
        let workspace = directory.appendingPathComponent("agent-change-"+UUID().uuidString);try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Agent rules","key_prefix":"AR","root_path":workspace.path]),sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"provider":provider,"role":"worker","label":"Agent"])
        return (p,Caller(role:"worker",installation:"agent-"+provider,projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path))
    }
    func currentPolicy(_ p: JSON) throws -> JSON { try call("policy_get",["project_id":p["id"]!])["policy"] as! JSON }
    func currentProjectRevision(_ p: JSON) throws -> Any { try call("project_settings_get",["project_id":p["id"]!])["revision"]! }

    func testAgentAppliesRuleChangeThatAllowsItsOwnProvider() throws {
        let (p,agent) = try agentChangeFixture()
        var codexOnly = try currentPolicy(p);codexOnly["allowed_providers"] = ["codex"]
        codexOnly["roles"] = ["coordinator":["providers":["codex"]],"implementer":["providers":["codex"]],"reviewer":["providers":["codex"]]]
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":codexOnly])
        let t = try ready(p,task(p))
        assertCode("POLICY_DENIED") { _ = try self.call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!],agent) }
        var shared = try currentPolicy(p);shared["allowed_providers"] = ["codex","claude"]
        shared["roles"] = ["coordinator":["providers":["codex","claude"]],"implementer":["providers":["codex","claude"]],"reviewer":["providers":["codex","claude"]]]
        assertCode("INVALID_INPUT") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"policy":shared],agent) }
        let updated = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":shared,"reason":"Owner asked to remove the Codex-only rule."],agent)
        XCTAssertEqual(strings(updated["policy"] as! JSON,"allowed_providers"),["codex","claude"])
        let event = try router.dbQueue.read { db in try Row.fetchOne(db,sql:"SELECT data FROM events WHERE kind='policy_updated' ORDER BY seq DESC LIMIT 1") }
        let data = try JSONSerialization.jsonObject(with:Data((event?["data"] as String? ?? "{}").utf8)) as! JSON
        XCTAssertEqual(data["origin"] as? String,"agent");XCTAssertEqual(data["reason"] as? String,"Owner asked to remove the Codex-only rule.")
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!],agent)
        XCTAssertEqual(claim["state"] as? String,"active")
    }

    func testOwnerOnlySwitchStaysWithTheOwner() throws {
        let (p,agent) = try agentChangeFixture()
        var locked = try currentPolicy(p);locked["agent_rule_changes"] = "owner_only"
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"policy":locked,"reason":"Lock"],agent) }
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":locked])
        var unlocked = try currentPolicy(p);unlocked["agent_rule_changes"] = "allowed"
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"policy":unlocked,"reason":"Unlock"],agent) }
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("status_create",["project_id":p["id"]!,"name":"Polish","category":"parked"],agent) }
        let t = try task(p)
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive"],agent) }
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":unlocked])
        XCTAssertEqual(try call("status_create",["project_id":p["id"]!,"name":"Polish","category":"parked"],agent)["name"] as? String,"Polish")
    }

    func testAgentManagesTaxonomyArchiveAndProjectSettings() throws {
        let (p,agent) = try agentChangeFixture()
        let status = try call("status_create",["project_id":p["id"]!,"name":"Needs art","category":"blocked","sort_order":7],agent)
        XCTAssertEqual(status["category"] as? String,"blocked")
        let renamed = try call("status_edit",["project_id":p["id"]!,"status_id":status["id"]!,"expected_revision":status["revision"]!,"name":"Waiting on art"],agent)
        XCTAssertEqual(renamed["name"] as? String,"Waiting on art")
        let tag = try call("tag_create",["project_id":p["id"]!,"name":"audio","color":"blue"],agent)
        _ = try call("tag_retire",["project_id":p["id"]!,"tag_id":tag["id"]!,"expected_revision":tag["revision"]!],agent)
        let t = try task(p)
        let archived = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive"],agent)
        XCTAssertTrue(bool(archived,"archived"))
        let restored = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":archived["revision"]!,"action":"unarchive"],agent)
        XCTAssertFalse(bool(restored,"archived"))
        let saved = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"name":"Agent-run game"],agent)
        XCTAssertEqual(saved["name"] as? String,"Agent-run game")
        let briefed = try call("project_edit",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"brief":"Ship the vertical slice.","pinned_decisions":["Use the existing art style."]],agent)
        let pin = (briefed["pinned_decisions"] as! [JSON])[0]
        XCTAssertEqual(pin["origin"] as? String,"agent")
        let notes = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!])["messages"] as! [JSON]
        XCTAssertTrue(notes.contains { $0["origin"] as? String == "agent" && ($0["body"] as? String ?? "").contains("project brief") })
        XCTAssertFalse(notes.contains { $0["origin"] as? String == "human_ui" && bool($0,"requires_action") })
    }

    func testAgentCatalogDescribesChangesAndCommandIDs() throws {
        let (_,agent) = try agentChangeFixture()
        let tools = router.toolCatalog(agent)
        let names = Set(tools.compactMap { $0["name"] as? String })
        for name in ["policy_apply","project_settings_save","project_edit","project_archive","status_create","status_edit","status_retire","tag_create","tag_edit","tag_retire","task_archive"] { XCTAssertTrue(names.contains(name),name) }
        let policyApply = tools.first { $0["name"] as? String == "policy_apply" }!, schema = policyApply["inputSchema"] as! JSON
        XCTAssertTrue(strings(schema,"required").contains("reason"))
        let commandID = (schema["properties"] as! JSON)["command_id"] as! JSON
        XCTAssertEqual(commandID["format"] as? String,"uuid")
        let edit = tools.first { $0["name"] as? String == "task_edit" }!
        let patch = ((edit["inputSchema"] as! JSON)["properties"] as! JSON)["patch"] as! JSON
        XCTAssertTrue((patch["description"] as? String ?? "").contains("readiness"))
        XCTAssertTrue((tools.first { $0["name"] as? String == "triage_create" }!["description"] as? String ?? "").contains("A Triage has no phase"))
        // CL-125 rules 8-10: no tool description keeps the retired departure or phase rules.
        for tool in tools {
            let text = tool["description"] as? String ?? ""
            for retired in ["removes the ticket from all current Triages","depart","detaches every membership","removes all current Triage memberships","phase orchestrator"] {
                XCTAssertFalse(text.contains(retired),"\(tool["name"] ?? "") still says \(retired)")
            }
        }
        for name in ["work_claim","review_record","work_release","work_submit","batch_review_record"] {
            XCTAssertTrue((tools.first { $0["name"] as? String == name }!["description"] as? String ?? "").contains("Triage"),name)
        }
    }

    func testTaskContextNamesRefinementAndPrerequisiteWaits() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let prerequisite = try task(p),draft = try task(p,"Draft dependent")
        XCTAssertEqual(try call("task_context",["project_id":p["id"]!,"task_id":draft["id"]!])["next_action"] as? String,"refine_draft")
        try link(p,draft,prerequisite)
        let readied = try ready(p,currentRelationTask(p,draft))
        XCTAssertEqual(readied["effective_readiness"] as? String,"blocked")
        XCTAssertEqual(try call("task_context",["project_id":p["id"]!,"task_id":draft["id"]!])["next_action"] as? String,"wait_for_prerequisites")
        _ = try completeRelationFixture(p,prerequisite)
        XCTAssertEqual(try call("task_context",["project_id":p["id"]!,"task_id":draft["id"]!])["next_action"] as? String,"claim_work")
    }

    func testAgentCannotFlipTheSwitchThroughProposalsOrSettings() throws {
        let (p,agent) = try agentChangeFixture()
        var locked = try currentPolicy(p);locked["agent_rule_changes"] = "owner_only"
        let proposal = try call("policy_propose",["project_id":p["id"]!,"policy":locked,"mode":"future_attempts"],agent)
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"proposal_id":proposal["id"]!,"digest":proposal["digest"]!,"reason":"Flip via proposal"],agent) }
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("project_settings_save",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"policy":locked,"reason":"Flip via settings"],agent) }
        XCTAssertEqual(try currentPolicy(p)["agent_rule_changes"] as? String,"allowed")
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":locked])
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("project_edit",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"name":"Renamed"],agent) }
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("project_archive",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"archived":true],agent) }
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("project_settings_save",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"name":"Renamed"],agent) }
    }

    func testOnlyEnrolledWorkersMayChangeTheProject() throws {
        let (p,agent) = try agentChangeFixture()
        let assistant = Caller(role:"assistant",installation:"assistant-fixture",projectIDs:[p["id"] as! String])
        assertCode("FORBIDDEN") { _ = try self.call("status_create",["project_id":p["id"]!,"name":"Nope","category":"parked"],assistant) }
        let ghost = Caller(role:"worker",installation:"unregistered",projectIDs:[p["id"] as! String],sessionID:UUID().uuidString,workspace:agent.workspace)
        assertCode("FORBIDDEN") { _ = try self.call("status_create",["project_id":p["id"]!,"name":"Nope","category":"parked"],ghost) }
    }

    func testAgentArchivesAndRestoresTheProjectButCannotMoveItsRoot() throws {
        let (p,agent) = try agentChangeFixture()
        let archived = try call("project_archive",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"archived":true],agent)
        XCTAssertTrue(bool(archived,"archived"))
        assertCode("PROJECT_ARCHIVED") { _ = try self.call("project_edit",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"name":"Edited while archived"],agent) }
        let restored = try call("project_archive",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"archived":false],agent)
        XCTAssertFalse(bool(restored,"archived"))
        let elsewhere = directory.appendingPathComponent("elsewhere-"+UUID().uuidString);try FileManager.default.createDirectory(at:elsewhere,withIntermediateDirectories:true)
        assertCode("INVALID_INPUT") { _ = try self.call("project_edit",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"root_path":elsewhere.path],agent) }
        let editSchema = (router.toolCatalog(agent).first { $0["name"] as? String == "project_edit" }!["inputSchema"] as! JSON)["properties"] as! JSON
        XCTAssertNil(editSchema["root_path"])
    }

    func testAgentWithActiveWorkChangesRulesOnlyForFutureAttempts() throws {
        let (p,agent) = try agentChangeFixture()
        let t = try ready(p,task(p))
        _ = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!],agent)
        var noGates = try currentPolicy(p);noGates["required_gates"] = []
        assertCode("POLICY_DENIED") { _ = try self.call("policy_apply",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"policy":noGates,"mode":"checkpoint_active","reason":"Drop gates on my own work"],agent) }
        let future = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":noGates,"mode":"future_attempts","reason":"Gates for later work"],agent)
        XCTAssertEqual(strings(future["policy"] as! JSON,"required_gates"),[])
    }
}
