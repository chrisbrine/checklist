import ChecklistTestSupport
import ChecklistProviders
import XCTest
@testable import ChecklistCore
@testable import ChecklistIPC

/// CL-241 synthetic tests. MockCodexHost stands in for the caller's own Codex host tool
/// (codex_app.create_thread). No Codex app, app-server, CLI runtime or model runs.
final class CodexThreadStartTests: XCTestCase {
    enum HostResult { case created(String), unavailable(String), refused(String), failed(String) }
    struct MockCodexHost {
        let result: HostResult
        var requests: [[String: Any]] = []
        mutating func createThread(_ request: [String: Any]) -> HostResult { requests.append(request); return result }
    }
    var root: URL!
    var router: CommandRouter!
    let requester = "01a00000-0000-7000-8000-000000000001"
    lazy var owner = Caller(role: "owner", installation: "disposable-codex-thread-test", projectIDs: [], sessionID: requester)
    /// Reads use the plain owner channel; the synthetic requester session has no stored generation.
    let reader = Caller(role: "owner", installation: "disposable-codex-thread-reader", projectIDs: [])
    override func setUpWithError() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        root = parent.appendingPathComponent("codex-thread-" + UUID().uuidString); router = try TestStore.router(root: root)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: root) }
    @discardableResult func call(_ method: String, _ p: [String: Any] = [:], as caller: Caller? = nil) throws -> [String: Any] {
        var p = p
        if !CommandRouter.readMethods.contains(method), p["command_id"] == nil { p["command_id"] = UUID().uuidString }
        let reply = try router.handle(method: method, params: p, caller: caller ?? (["history_list", "task_get", "tool_catalog"].contains(method) ? reader : owner))
        return reply["data"] as? [String: Any] ?? reply
    }
    func assertCode(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual(($0 as? CoreError)?.code, code, file: file, line: line) }
    }
    func fixture() throws -> (String, [String: Any]) {
        let project = try call("project_create", ["name": "Disposable", "root_path": root.path, "key_prefix": "CT"])
        let epic = try call("epic_create", ["project_id": project["id"]!, "name": "Fixture tickets"])
        let task = try call("task_create", ["project_id": project["id"]!, "title": "Synthetic thread start", "epic_id": epic["id"]!])
        return (project["id"] as! String, task)
    }
    func threadEvents(_ project: String, _ task: String) throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["kind"] as? String == "codex_thread_requested" { found.append(object) }
                object.values.forEach(walk)
            } else if let list = value as? [Any] { list.forEach(walk) }
        }
        walk(try call("history_list", ["project_id": project, "task_id": task]))
        return found
    }
    func eventData(_ event: [String: Any]) -> [String: Any] {
        if let data = event["data"] as? [String: Any] { return data }
        if let text = event["data"] as? String, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return object }
        return event
    }
    /// Prepare, hand the request to the mock host, then record exactly what the host returned.
    func run(_ host: inout MockCodexHost, _ project: String, _ task: String) throws -> ([String: Any], [String: Any]) {
        let prepared = try call("codex_thread_start", ["project_id": project, "task_id": task])
        var p: [String: Any] = ["project_id": project, "task_id": task]
        switch host.createThread(prepared["host_request"] as! [String: Any]) {
        case .created(let id): p["host_outcome"] = "created"; p["thread_id"] = id
        case .unavailable(let detail): p["host_outcome"] = "unavailable"; p["host_detail"] = detail
        case .refused(let detail): p["host_outcome"] = "refused"; p["host_detail"] = detail
        case .failed(let detail): p["host_outcome"] = "failed"; p["host_detail"] = detail
        }
        return (prepared, try call("codex_thread_start", p))
    }

    func testPreparedRequestCarriesTheScopedPromptAndStartsNothing() throws {
        let (pid, task) = try fixture(), tid = task["id"] as! String
        let prepared = try call("codex_thread_start", ["project_id": pid, "task_id": tid])
        XCTAssertEqual(prepared["state"] as? String, "prepared"); XCTAssertEqual(prepared["started"] as? Bool, false)
        XCTAssertEqual(prepared["claim_acquired"] as? Bool, false); XCTAssertNil(prepared["thread_id"])
        let request = prepared["host_request"] as! [String: Any]
        XCTAssertEqual(request["tool"] as? String, "codex_app.create_thread"); XCTAssertEqual(request["workspace"] as? String, root.path)
        let expected = try ChecklistHandoff.instruction(key: task["key"] as! String, title: "Synthetic thread start", root: root.path, projectID: pid, taskID: tid, cliCommand: router.cliCommand)
        XCTAssertEqual(request["prompt"] as? String, expected)
        let fallback = prepared["fallback"] as! [String: Any]
        XCTAssertEqual(fallback["kind"] as? String, "composer_owner_send"); XCTAssertEqual(fallback["owner_send_required"] as? Bool, true)
        XCTAssertNotNil(ProviderPluginRegistry.bundled.plugin("codex", requiring: .composer)?.validateComposeURL(fallback["compose_url"] as! String))
        XCTAssertTrue(try threadEvents(pid, tid).isEmpty)
        XCTAssertNil(try call("task_get", ["project_id": pid, "task_id": tid])["active_attempt_id"])
    }
    func testCreatedRecordsTheHostReturnedIdentityWithoutClaimAssignmentOrAttachment() throws {
        let (pid, task) = try fixture(), tid = task["id"] as! String, thread = "01A147CA-1ECB-7AA3-B20D-47A356BD5DA0"
        var host = MockCodexHost(result: .created(thread))
        let (prepared, result) = try run(&host, pid, tid)
        XCTAssertEqual(host.requests.count, 1); XCTAssertEqual(host.requests[0]["prompt"] as? String, (prepared["host_request"] as! [String: Any])["prompt"] as? String)
        XCTAssertEqual(result["state"] as? String, "host_created"); XCTAssertEqual(result["started"] as? Bool, true)
        XCTAssertEqual(result["thread_id"] as? String, thread.lowercased()); XCTAssertEqual(result["attachment_state"] as? String, "pending_self_attach")
        XCTAssertEqual(result["claim_acquired"] as? Bool, false); XCTAssertEqual(result["assignment_changed"] as? Bool, false); XCTAssertNil(result["fallback"])
        let events = try threadEvents(pid, tid)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(eventData(events[0])["thread_id"] as? String, thread.lowercased())
        XCTAssertEqual(eventData(events[0])["requested_by_session"] as? String, requester)
        let current = try call("task_get", ["project_id": pid, "task_id": tid])
        XCTAssertNil(current["active_attempt_id"]); XCTAssertEqual(current["status_id"] as? String, task["status_id"] as? String)
        XCTAssertEqual(current["planned_assignee"] as? NSObject, task["planned_assignee"] as? NSObject)
        // A retry with the same command_id returns the original receipt and records nothing new.
        let command = UUID().uuidString, input: [String: Any] = ["project_id": pid, "task_id": tid, "host_outcome": "created", "thread_id": "0190f000-0000-7000-8000-000000000241", "command_id": command]
        let first = try call("codex_thread_start", input), replay = try call("codex_thread_start", input)
        XCTAssertEqual(first["thread_id"] as? String, replay["thread_id"] as? String); XCTAssertEqual(try threadEvents(pid, tid).count, 2)
    }
    func testUnavailableRefusedAndFailedReportTheExactOutcomeAndKeepTheComposerFallback() throws {
        let (pid, task) = try fixture(), tid = task["id"] as! String
        let cases: [(HostResult, String, String)] = [(.unavailable("codex_app tools absent in this host"), "unavailable", "codex_app tools absent in this host"),
            (.refused("owner declined the host approval prompt"), "refused", "owner declined the host approval prompt"), (.failed("host error 500"), "failed", "host error 500")]
        for (index, (hostResult, outcome, detail)) in cases.enumerated() {
            var host = MockCodexHost(result: hostResult)
            let (_, result) = try run(&host, pid, tid)
            XCTAssertEqual(result["state"] as? String, outcome); XCTAssertEqual(result["started"] as? Bool, false); XCTAssertNil(result["thread_id"])
            XCTAssertEqual(result["host_detail"] as? String, detail); XCTAssertTrue((result["limitation"] as! String).contains(outcome))
            let fallback = result["fallback"] as! [String: Any]
            XCTAssertEqual(fallback["kind"] as? String, "composer_owner_send"); XCTAssertTrue((fallback["compose_url"] as! String).hasPrefix("codex://threads/new?"))
            let events = try threadEvents(pid, tid)
            XCTAssertEqual(events.count, index + 1); XCTAssertEqual(eventData(events[index])["outcome"] as? String, outcome); XCTAssertNil(eventData(events[index])["thread_id"])
        }
        XCTAssertNil(try call("task_get", ["project_id": pid, "task_id": tid])["active_attempt_id"])
    }
    func testNoStartIsRecordedWithoutAHostReturnedIdentity() throws {
        let (pid, task) = try fixture(), tid = task["id"] as! String, base: [String: Any] = ["project_id": pid, "task_id": tid]
        assertCode("HOST_THREAD_IDENTITY_REQUIRED") { try self.call("codex_thread_start", base.merging(["host_outcome": "created"]) { $1 }) }
        assertCode("INVALID_INPUT") { try self.call("codex_thread_start", base.merging(["host_outcome": "created", "thread_id": "draft-composer"]) { $1 }) }
        assertCode("INVALID_INPUT") { try self.call("codex_thread_start", base.merging(["host_outcome": "created", "thread_id": self.requester]) { $1 }) }
        assertCode("INVALID_INPUT") { try self.call("codex_thread_start", base.merging(["host_outcome": "refused", "thread_id": "0190f000-0000-7000-8000-000000000240"]) { $1 }) }
        XCTAssertThrowsError(try call("codex_thread_start", base.merging(["host_outcome": "started"]) { $1 }))
        XCTAssertTrue(try threadEvents(pid, tid).isEmpty)
    }
    func testWorkersDiscoverTheCommandAndAssistantsCannotUseIt() throws {
        let (pid, task) = try fixture()
        let tools = try call("tool_catalog")["tools"] as? [[String: Any]] ?? []
        let entry = try XCTUnwrap(tools.first { $0["name"] as? String == "codex_thread_start" })
        XCTAssertTrue(String(describing: entry).contains("created"))
        let assistant = Caller(role: "assistant", installation: "disposable-assistant", projectIDs: [pid], assistantGrants: [pid: ["read": true]])
        XCTAssertFalse(router.toolCatalog(assistant).contains { $0["name"] as? String == "codex_thread_start" })
        XCTAssertThrowsError(try call("codex_thread_start", ["project_id": pid, "task_id": task["id"]!], as: assistant))
    }
}
