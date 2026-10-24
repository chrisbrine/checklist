import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class MessageRecipientTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "recipient-test-owner", projectIDs: [])

    override func setUpWithError() throws {
        let parent = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ChecklistQualification/CL-24/MessageRecipientTests",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        directory = parent.appendingPathComponent(UUID().uuidString)
        router = try TestStore.router(root: directory)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func call(_ method: String, _ input: JSON = [:], _ caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var params = input
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = command ?? uuid() }
        return try router.handle(method: method, params: fixtureTaskInput(router,method:method,input:params), caller: caller ?? owner)["data"] as! JSON
    }
    struct Fixture {
        let project: JSON
        let task: JSON
        let handler: Caller
        let target: Caller
        let attempt: JSON
        var pid: String { project["id"] as! String }
        var tid: String { task["id"] as! String }
    }
    func fixture() throws -> Fixture {
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Recipient fixtures", "key_prefix": "ROUTE", "root_path": workspace.path])
        let pid = project["id"] as! String
        var task = try call("task_create", ["project_id": pid, "title": "Scoped note", "brief": "Synthetic routing fixture"])
        task = try call("task_edit", ["project_id": pid, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
        var workers: [Caller] = []
        for name in ["handler", "target"] {
            let sid = uuid()
            _ = try call("session_register", ["project_id": pid, "session_id": sid, "role": "worker", "provider": "codex", "installation": name])
            workers.append(Caller(role: "worker", installation: name, projectIDs: [pid], sessionID: sid, workspace: workspace.path))
        }
        let attempt = try call("work_claim", ["project_id": pid, "task_id": task["id"]!, "expected_revision": task["revision"]!], workers[0])
        return Fixture(project: project, task: task, handler: workers[0], target: workers[1], attempt: attempt)
    }
    func input(_ f: Fixture, recipient: Any? = nil) -> JSON {
        var params: JSON = ["project_id": f.pid, "task_id": f.tid, "body": "Synthetic coordination note"]
        if let recipient { params["recipient"] = recipient }
        return params
    }
    func counts() throws -> [Int] {
        try router.dbQueue.read { db in
            try ["SELECT COUNT(*) FROM records", "SELECT COUNT(*) FROM events", "SELECT COUNT(*) FROM commands", "SELECT COUNT(*) FROM cursors"].map { try Int.fetchOne(db, sql: $0)! }
        }
    }
    func assertAtomicFailure(_ params: JSON, _ caller: Caller? = nil, code: String = "INVALID_INPUT", file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try counts()
        XCTAssertThrowsError(try call("message_send", params, caller), file: file, line: line) { XCTAssertEqual(($0 as? CoreError)?.code, code, file: file, line: line) }
        XCTAssertEqual(try counts(), before, "Rejected route changed stored records, events, command receipts or cursors", file: file, line: line)
    }
    func recipients(_ message: JSON) -> [String] { (message["deliveries"] as? [JSON] ?? []).compactMap { $0["recipient_session_id"] as? String } }

    func testMissingKindDoesNotFallBackToHandler() throws {
        let f = try fixture()
        for actor in [owner, f.target] {
            try assertAtomicFailure(input(f, recipient: ["session_id": f.target.sessionID!]), actor)
        }
    }
    func testOtherMalformedRecipientShapesAreAtomicForOwnerAndWorker() throws {
        let f = try fixture()
        let invalid: [Any] = [NSNull(), "session", [], true, [:], ["kind": "session"], ["kind": "current_handlers"], ["kind": "attempt", "attempt_id": f.attempt["id"]!], ["kind": 1, "session_id": f.target.sessionID!], ["kind": "session", "session_id": 42], ["kind": "session", "session_id": ""], ["kind": "session", "session_id": " \n\t"], ["kind": "session", "session_id": String(repeating: "x", count: 4001)], ["kind": "session", "session_id": f.target.sessionID!, "unexpected": true]]
        for actor in [owner, f.target] {
            for recipient in invalid { try assertAtomicFailure(input(f, recipient: recipient), actor) }
        }
    }
    func testExplicitOwnerDirectionRejectsAtomicallyAndOmittedFanoutRemains() throws {
        let f = try fixture()
        var conflicting = input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!])
        conflicting["requires_action"] = true; conflicting["expects_reply"] = true
        try assertAtomicFailure(conflicting)
        var required = input(f)
        required["requires_action"] = true; required["expects_reply"] = true
        let direction = try call("message_send", required)
        XCTAssertEqual(direction["requires_action"] as? Bool, true)
        XCTAssertEqual(recipients(direction), [f.handler.sessionID!])
        XCTAssertEqual(direction["reply_recipient_session_id"] as? String, f.handler.sessionID)
        XCTAssertEqual(direction["reply_used"] as? Bool, false)
        let deliveries = direction["deliveries"] as! [JSON]
        XCTAssertTrue(deliveries.allSatisfy { $0["state"] as? String == "queued" && $0["acknowledged_at"] == nil })
    }
    func testValidExplicitSessionOverridesHandlerAndRetainsExactReplyAllowance() throws {
        let f = try fixture()
        var params = input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!])
        params["expects_reply"] = true
        let message = try call("message_send", params)
        XCTAssertEqual(recipients(message), [f.target.sessionID!])
        XCTAssertEqual(message["reply_recipient_session_id"] as? String, f.target.sessionID)
        XCTAssertEqual(message["delivery_status"] as? String, "queued")
        XCTAssertEqual(message["native_push"] as? Bool, false)
        let delivery = (message["deliveries"] as! [JSON])[0]
        XCTAssertEqual(delivery["state"] as? String, "queued")
        XCTAssertNil(delivery["acknowledged_at"])
        let workerNote = try call("message_send", input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!]), f.handler)
        XCTAssertEqual(recipients(workerNote), [f.target.sessionID!])
    }
    func testDoneTicketStillAcceptsExactDirectNoticeAndOmittedRouteStaysHistoryOnly() throws {
        let f = try fixture()
        // Preexisting closed-ticket fixture: routing, not completion gates, is under test.
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var task = try router.scoped(db, f.tid, f.pid, type: "task")
            task["status_id"] = try router.status(db, f.pid, "done")["id"]!
            task.removeValue(forKey: "active_attempt_id")
            try router.save(db, router.revised(task), type: "task")
            var attempt = try router.scoped(db, f.attempt["id"] as! String, f.pid, type: "attempt")
            attempt["state"] = "submitted"
            try router.save(db, router.revised(attempt), type: "attempt")
            return .commit
        } }
        XCTAssertEqual(try call("task_get", ["project_id": f.pid, "task_id": f.tid])["status_category"] as? String, "done")
        let direct = try call("message_send", input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!]), f.handler)
        XCTAssertEqual(recipients(direct), [f.target.sessionID!])
        let omitted = try call("message_send", input(f), f.handler)
        XCTAssertTrue(recipients(omitted).isEmpty)
        XCTAssertEqual(omitted["delivery_status"] as? String, "saved_for_pickup")
    }
    func testOmittedRecipientKeepsNativeComposerHandlerAndAttemptFence() throws {
        let f = try fixture()
        var params = input(f)
        params["expects_reply"] = true; params["expected_attempt_id"] = f.attempt["id"]!
        let note = try call("message_send", params)
        XCTAssertEqual(recipients(note), [f.handler.sessionID!])
        XCTAssertEqual(note["reply_recipient_session_id"] as? String, f.handler.sessionID)
        params["expected_attempt_id"] = uuid()
        try assertAtomicFailure(params, code: "RECIPIENT_CHANGED")
    }
    func testExplicitUnknownForeignOrEndedSessionNeverFallsBack() throws {
        let f = try fixture()
        try assertAtomicFailure(input(f, recipient: ["kind": "session", "session_id": uuid()]), f.handler, code: "NOT_FOUND")
        let foreign = try call("project_create", ["name": "Other scope", "key_prefix": "OTHER"])
        let foreignID = uuid()
        _ = try call("session_register", ["project_id": foreign["id"]!, "session_id": foreignID, "role": "worker", "provider": "codex", "installation": "foreign"])
        try assertAtomicFailure(input(f, recipient: ["kind": "session", "session_id": foreignID]), f.handler, code: "NOT_FOUND")
        let target = try router.dbQueue.read { try router.record($0, f.target.sessionID!, type: "session") }
        _ = try call("session_update", ["project_id": f.pid, "session_id": f.target.sessionID!, "expected_revision": target["revision"]!, "state": "ended", "observation": "Synthetic fixture ended"])
        try assertAtomicFailure(input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!]), f.handler, code: "FORBIDDEN")
    }
    func testOwnerReplyRejectsExplicitRouteWithoutConsumingAllowance() throws {
        let f = try fixture()
        var original = input(f); original["expects_reply"] = true
        let note = try call("message_send", original)
        for recipient: Any in [["session_id": f.target.sessionID!], ["kind": "session", "session_id": f.target.sessionID!]] {
            var reply = input(f, recipient: recipient); reply["reply_to"] = note["id"]!
            try assertAtomicFailure(reply, f.handler)
            let stored = try router.dbQueue.read { try router.record($0, note["id"] as! String, type: "message") }
            XCTAssertEqual(stored["reply_used"] as? Bool, false)
        }
        var permitted = input(f); permitted["reply_to"] = note["id"]!
        let reply = try call("message_send", permitted, f.handler)
        XCTAssertTrue(recipients(reply).isEmpty)
        let stored = try router.dbQueue.read { try router.record($0, note["id"] as! String, type: "message") }
        XCTAssertEqual(stored["reply_used"] as? Bool, true)
    }
    func testNonOwnerReplyKeepsItsValidExplicitSessionRoute() throws {
        let f = try fixture()
        let original = try call("message_send", input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!]), f.handler)
        var params = input(f, recipient: ["kind": "session", "session_id": f.handler.sessionID!]); params["reply_to"] = original["id"]!
        let reply = try call("message_send", params, f.target)
        XCTAssertEqual(recipients(reply), [f.handler.sessionID!])
        XCTAssertEqual(reply["reply_to"] as? String, original["id"] as? String)
    }
    func testDiscoveredRecipientSchemaIsClosedAndMatchesSupportedRoute() throws {
        let f = try fixture()
        let tools = try call("tool_catalog", [:], f.handler)["tools"] as! [JSON]
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "message_send" })
        let schema = tool["inputSchema"] as! JSON, properties = schema["properties"] as! JSON
        let recipient = properties["recipient"] as! JSON, fields = recipient["properties"] as! JSON
        XCTAssertFalse((schema["required"] as! [String]).contains("recipient"))
        XCTAssertEqual(recipient["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(recipient["required"] as! [String]), ["kind", "session_id"])
        XCTAssertEqual(Set(fields.keys), ["kind", "session_id"])
        XCTAssertEqual((fields["kind"] as! JSON)["enum"] as? [String], ["session"])
        XCTAssertEqual((fields["session_id"] as! JSON)["minLength"] as? Int, 1)
        XCTAssertEqual((fields["session_id"] as! JSON)["maxLength"] as? Int, 4000)
        XCTAssertEqual((fields["session_id"] as! JSON)["pattern"] as? String, "\\S")
    }
    func testValidRetryKeepsCommittedTargetAfterHandlerChangesWithoutNewWrites() throws {
        let f = try fixture()
        let params = input(f, recipient: ["kind": "session", "session_id": f.target.sessionID!]), command = uuid()
        let original = try call("message_send", params, f.handler, command: command)
        _ = try call("work_release", ["project_id": f.pid, "attempt_id": f.attempt["id"]!, "claim_token": f.attempt["claim_token"]!, "expected_revision": f.attempt["revision"]!, "reason": "Synthetic handler handoff"], f.handler)
        let nextID = uuid()
        _ = try call("session_register", ["project_id": f.pid, "session_id": nextID, "role": "worker", "provider": "codex", "installation": "next-handler"])
        let next = Caller(role: "worker", installation: "next-handler", projectIDs: [f.pid], sessionID: nextID, workspace: f.handler.workspace)
        let ready = try call("task_get", ["project_id": f.pid, "task_id": f.tid])
        let attempt = try call("work_claim", ["project_id": f.pid, "task_id": f.tid, "expected_revision": ready["revision"]!], next)
        let current = try call("task_get", ["project_id": f.pid, "task_id": f.tid])
        XCTAssertEqual(current["active_attempt_id"] as? String, attempt["id"] as? String)
        let before = try counts()
        let replay = try call("message_send", params, f.handler, command: command)
        XCTAssertEqual(replay["id"] as? String, original["id"] as? String)
        XCTAssertEqual(recipients(replay), [f.target.sessionID!])
        XCTAssertEqual((replay["deliveries"] as! [JSON]).compactMap { $0["id"] as? String }, (original["deliveries"] as! [JSON]).compactMap { $0["id"] as? String })
        XCTAssertEqual(try counts(), before)
    }
    func testMalformedLegacyReceiptCannotReplayIgnoredRoute() throws {
        let f = try fixture()
        // Pre-upgrade fixture: an already committed note followed the old fallback route.
        let original = try call("message_send", input(f), f.target)
        XCTAssertEqual(recipients(original), [f.handler.sessionID!])
        var params = input(f, recipient: ["session_id": f.target.sessionID!]); let command = uuid(); params["command_id"] = command
        let durable = try jsonString(["data": original])
        try router.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)", arguments: [f.target.principal, command, ChecklistCore.hash(Data(("message_send" + (try jsonString(params))).utf8)), durable])
        }
        let before = try counts()
        XCTAssertThrowsError(try router.handle(method: "message_send", params: params, caller: f.target)) { XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT") }
        XCTAssertEqual(try counts(), before)
        let preserved = try router.dbQueue.read { db -> JSON in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT result FROM commands WHERE principal=? AND command_id=?", arguments: [f.target.principal, command]), durable)
            for delivery in original["deliveries"] as! [JSON] { XCTAssertNoThrow(try router.record(db, delivery["id"] as! String, type: "delivery")) }
            return try router.record(db, original["id"] as! String, type: "message")
        }
        XCTAssertEqual(preserved["id"] as? String, original["id"] as? String)
        XCTAssertEqual(preserved["body"] as? String, original["body"] as? String)
    }
}
