import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private func workspaceCreator(_ provider: String = "codex") throws -> Caller {
        let workspace = directory.appendingPathComponent("new-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return Caller(role: "worker", installation: "native-create/" + UUID().uuidString,
                      projectIDs: [], sessionID: UUID().uuidString, workspace: workspace.path,
                      executionDomain: provider + ":synthetic-native-process")
    }
    private func creationRegistration(_ caller: Caller, _ project: String, _ provider: String) -> JSON {
        ["project_id": project, "project_ids": [project], "session_id": caller.sessionID!,
         "installation": caller.installation, "role": "worker", "provider": provider,
         "workspace": canonical(caller.workspace!), "execution_domain": caller.executionDomain!, "name": "Native creator"]
    }
    private func createWorkspace(_ caller: Caller, provider: String = "codex", input: JSON? = nil) throws -> JSON {
        try router.commitWorkspaceProjectCreation(intent: input ?? ["command_id": UUID().uuidString, "name": "Native project", "key_prefix": "NP"],
            caller: caller, provider: provider, preparePersistence: { self.creationRegistration(caller, $0, provider) }, rollback: {})
    }

    func testWorkspaceCreationAtomicallyGrantsBothNativeProvidersWithAgentProvenance() throws {
        for provider in ["codex", "claude"] {
            let caller = try workspaceCreator(provider)
            let project = try createWorkspace(caller, provider: provider)["data"] as! JSON
            let id = project["id"] as! String
            XCTAssertEqual(project["root_path"] as? String, canonical(caller.workspace!))
            XCTAssertEqual((project["policy"] as? JSON)?["agent_rule_changes"] as? String, "allowed")
            XCTAssertEqual((project["policy"] as? JSON)?["required_gates"] as? [String], try currentPolicy(try self.project())["required_gates"] as? [String])
            let session = try router.dbQueue.read { try router.record($0, caller.sessionID!, type: "session") }
            XCTAssertEqual(strings(session, "project_ids"), [id]); XCTAssertEqual(session["role"] as? String, "worker")
            XCTAssertEqual(session["installation"] as? String, caller.installation)
            XCTAssertEqual(session["provider"] as? String, provider)
            XCTAssertEqual(session["workspace"] as? String, canonical(caller.workspace!))
            XCTAssertEqual(session["execution_domain"] as? String, caller.executionDomain)
            XCTAssertNotNil(session["authorization_generation"])
            var bound = caller; bound.projectIDs = [id]
            XCTAssertEqual(try call("taxonomy_get", ["project_id": id], bound)["statuses"].map { ($0 as! [JSON]).count }, 7)
            let created = try router.dbQueue.read { try Row.fetchOne($0, sql: "SELECT actor,data FROM events WHERE project_id=? AND kind='project_created'", arguments: [id])! }
            XCTAssertEqual(created["actor"] as String, caller.principal)
            XCTAssertEqual(jsonObject(created["data"])["origin"] as? String, "agent")
        }
    }

    func testWorkspaceCreationRootMustEqualActualWorkspaceAndAcceptsCanonicalAlias() throws {
        let caller = try workspaceCreator(), other = try workspaceCreator()
        for root in [other.workspace!, "relative", "", directory.path] {
            assertCode("ROOT_MISMATCH") { _ = try self.createWorkspace(caller, input: ["command_id": UUID().uuidString, "name": "No", "root_path": root]) }
        }
        let link = directory.appendingPathComponent("workspace-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: caller.workspace!)
        let created = try createWorkspace(caller, input: ["command_id": UUID().uuidString, "name": "Canonical", "root_path": link.path])["data"] as! JSON
        XCTAssertEqual(created["root_path"] as? String, canonical(caller.workspace!))
    }

    func testWorkspaceCreationRefusesMissingOrNonDirectoryWorkspace() throws {
        var caller = try workspaceCreator()
        try FileManager.default.removeItem(atPath: caller.workspace!)
        assertCode("FILE_ACCESS_REQUIRED") { _ = try self.createWorkspace(caller) }
        let file = directory.appendingPathComponent("file-workspace"); try Data("file".utf8).write(to: file)
        caller.workspace = file.path
        assertCode("FILE_ACCESS_REQUIRED") { _ = try self.createWorkspace(caller) }
    }

    func testWorkspaceCreationRefusesAlreadyRegisteredAndBothOverlapDirections() throws {
        let caller = try workspaceCreator()
        let child = URL(fileURLWithPath: caller.workspace!).appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let existing = try call("project_create", ["name": "Existing", "root_path": child.path])
        assertCode("ROOT_OVERLAP") { _ = try self.createWorkspace(caller) }
        var nested = try workspaceCreator(); nested.workspace = child.appendingPathComponent("nested").path
        try FileManager.default.createDirectory(atPath: nested.workspace!, withIntermediateDirectories: true)
        assertCode("ROOT_OVERLAP") { _ = try self.createWorkspace(nested) }
        var exact = try workspaceCreator(); exact.workspace = child.path
        assertCode("PROJECT_ALREADY_REGISTERED") { _ = try self.createWorkspace(exact) }
        _ = try call("project_archive", ["project_id": existing["id"]!, "expected_revision": existing["revision"]!, "archived": true])
        assertCode("PROJECT_ALREADY_REGISTERED") { _ = try self.createWorkspace(exact) }
    }

    func testWorkspaceCreationReplaysOriginalReceiptAfterBindingWithoutPreparation() throws {
        let caller = try workspaceCreator(), input: JSON = ["command_id": UUID().uuidString, "name": "Original"]
        let first = try createWorkspace(caller, input: input)
        let id = (first["data"] as! JSON)["id"] as! String
        var bound = caller; bound.projectIDs = [id]
        let replay = try router.commitWorkspaceProjectCreation(intent: input, caller: bound, provider: "codex",
            preparePersistence: { _ in XCTFail("Replay must not prepare credentials or register again"); return [:] }, rollback: { XCTFail("Replay must not roll back") })
        XCTAssertEqual(try jsonString(first["data"]!), try jsonString(replay["data"]!))
        XCTAssertEqual(first["event_cursor"] as? String, replay["event_cursor"] as? String)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.createWorkspace(bound, input: ["command_id": input["command_id"]!, "name": "Changed"]) }
        assertCode("PROJECT_ALREADY_REGISTERED") { _ = try self.createWorkspace(bound) }
        XCTAssertEqual(try call("project_list")["projects"].map { ($0 as! [JSON]).count }, 1)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events WHERE kind='session_registered'") }, 1)
    }

    func testWorkspaceCreationRollsBackProjectGrantAndExternalPreparationWhenReceiptFails() throws {
        let caller = try workspaceCreator()
        try router.dbQueue.write { db in try db.execute(sql: "CREATE TRIGGER refuse_creation_receipt BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END") }
        var prepared = 0, rolledBack = 0
        XCTAssertThrowsError(try router.commitWorkspaceProjectCreation(intent: ["command_id": UUID().uuidString, "name": "Atomic"], caller: caller, provider: "codex", preparePersistence: {
            prepared += 1; return self.creationRegistration(caller, $0, "codex")
        }, rollback: { rolledBack += 1 }))
        XCTAssertEqual(prepared, 1); XCTAssertEqual(rolledBack, 1)
        for type in ["project", "status", "session"] { XCTAssertEqual(try router.dbQueue.read { try self.router.records($0, type: type).count }, 0) }
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events") }, 0)
    }

    func testWorkspaceCreationRejectsExpandedRegistrationAndConflictingSession() throws {
        let caller = try workspaceCreator()
        var rolledBack = false
        assertCode("INVALID_INPUT") { _ = try self.router.commitWorkspaceProjectCreation(intent: ["command_id": UUID().uuidString, "name": "No expanded grant"], caller: caller, provider: "codex", preparePersistence: { id in
            var registration = self.creationRegistration(caller, id, "codex"); registration["project_ids"] = [id, "foreign"]; return registration
        }, rollback: { rolledBack = true }) }
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(try call("project_list")["projects"].map { ($0 as! [JSON]).count }, 0)
        let existing = try project()
        _ = try call("session_register", ["project_id": existing["id"]!, "session_id": caller.sessionID!, "role": "worker", "provider": "codex"])
        assertCode("SESSION_ID_CONFLICT") { _ = try self.createWorkspace(caller) }
    }

    func testWorkspaceCreationRefusesAssistantsUnverifiedWorkersAndAuthorityFields() throws {
        let caller = try workspaceCreator()
        var assistant = caller; assistant.role = "assistant"; assistant.workspace = nil
        var noDomain = caller; noDomain.executionDomain = nil
        var noSession = caller; noSession.sessionID = nil
        var noWorkspace = caller; noWorkspace.workspace = nil
        for rejected in [assistant, noDomain, noSession, noWorkspace, owner] {
            assertCode("FORBIDDEN") { _ = try self.createWorkspace(rejected) }
        }
        assertCode("FORBIDDEN") { _ = try self.call("project_create", ["name": "Payload cannot authenticate a native host"], caller) }
        for field in ["policy", "role", "project_ids", "workspace", "agent_rule_changes"] {
            assertCode("INVALID_INPUT") { _ = try self.createWorkspace(caller, input: ["command_id": UUID().uuidString, "name": "No bypass", field: "supplied"]) }
        }
    }

    func testWorkspaceCreatorCompletesSetupAndKeepsOwnerOnlyBoundaries() throws {
        let caller = try workspaceCreator()
        var project = try createWorkspace(caller)["data"] as! JSON
        let id = project["id"] as! String
        var bound = caller; bound.projectIDs = [id]
        project = try call("project_settings_save", ["project_id": id, "expected_revision": project["revision"]!, "name": "Ready project", "key_prefix": "RP", "icon": "gamecontroller", "accent": "purple", "default_view": ["group_by": "none", "order_by": "updated_desc"]], bound)
        project = try call("project_edit", ["project_id": id, "expected_revision": project["revision"]!, "brief": "Build the prototype", "pinned_decisions": ["Use the existing engine"]], bound)
        let policy = project["policy"] as! JSON
        _ = try call("policy_apply", ["project_id": id, "expected_revision": project["revision"]!, "policy": policy, "reason": "Confirm project workflow"], bound)
        let status = try call("status_create", ["project_id": id, "name": "Polish", "category": "parked"], bound)
        XCTAssertEqual(status["name"] as? String, "Polish")
        let tag = try call("tag_create", ["project_id": id, "name": "prototype", "color": "blue"], bound)
        let epic = try call("epic_create", ["project_id": id, "name": "Prototype"], bound)
        let ticket = try call("task_create", ["project_id": id, "title": "First feature", "brief": "Implement feature", "epic_id": epic["id"]!, "tag_ids": [tag["id"]!]], bound)
        XCTAssertEqual(ticket["key"] as? String, "RP-1")
        XCTAssertEqual((project["pinned_decisions"] as! [JSON])[0]["origin"] as? String, "agent")
        assertCode("INVALID_INPUT") { _ = try self.call("project_edit", ["project_id": id, "expected_revision": try self.currentProjectRevision(project), "root_path": caller.workspace!], bound) }
        var locked = policy; locked["agent_rule_changes"] = "owner_only"
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("policy_apply", ["project_id": id, "expected_revision": try self.currentProjectRevision(project), "policy": locked, "reason": "Cannot flip switch"], bound) }
        assertCode("FORBIDDEN") { _ = try self.call("human_request_answer", ["project_id": id, "request_id": "owner-only", "expected_revision": 1], bound) }
    }
}
