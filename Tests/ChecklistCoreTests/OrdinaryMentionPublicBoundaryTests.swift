// NEW public-boundary source cases only. Not compiled or executed.
import XCTest
import GRDB
@testable import ChecklistCore

final class OrdinaryMentionPublicBoundaryTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "public-mention-test", projectIDs: [])
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(uuid())
        router = try CommandRouter(root: directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: directory) }
    @discardableResult
    func call(_ method: String, _ params: JSON, _ caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var input = params
        if !CommandRouter.readMethods.contains(method) { input["command_id"] = command ?? uuid() }
        return try router.handle(method: method, params: input, caller: caller ?? owner)["data"] as! JSON
    }
    struct Fixture {
        let project: JSON, source: JSON, target: JSON, targetAttempt: JSON
        let writer: Caller, handler: Caller, tagged: Caller
        var pid: String { project["id"] as! String }
        var tid: String { source["id"] as! String }
    }
    func task(_ pid: String, _ title: String) throws -> JSON {
        let value = try call("task_create", ["project_id": pid, "title": title, "brief": "Synthetic public mention unit"])
        return try call("task_edit", ["project_id": pid, "task_id": value["id"]!, "expected_revision": value["revision"]!, "patch": ["readiness": "ready"]])
    }
    func worker(_ project: JSON, _ label: String) throws -> Caller {
        let pid = project["id"] as! String, sid = uuid(), workspace = project["root_path"] as! String
        _ = try call("session_register", ["project_id": pid, "session_id": sid, "provider": "codex", "role": "worker", "label": label, "installation": label, "workspace": workspace])
        return Caller(role: "worker", installation: label, projectIDs: [pid], sessionID: sid, workspace: workspace)
    }
    func fixture() throws -> Fixture {
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Public mentions", "key_prefix": "TAG", "root_path": workspace.path])
        let pid = project["id"] as! String, source = try task(pid, "Source"), target = try task(pid, "Target")
        let writer = try worker(project, "Writer"), handler = try worker(project, "Handler"), tagged = try worker(project, "Target worker")
        _ = try call("work_claim", ["project_id": pid, "task_id": source["id"]!, "expected_revision": source["revision"]!], handler)
        let attempt = try call("work_claim", ["project_id": pid, "task_id": target["id"]!, "expected_revision": target["revision"]!], tagged)
        return .init(project: project, source: source, target: target, targetAttempt: attempt, writer: writer, handler: handler, tagged: tagged)
    }
    func prepare(_ f: Fixture, _ body: String, selections: [JSON] = [], reply: String? = nil, caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var input: JSON = ["project_id": f.pid, "task_id": f.tid, "body": body, "selections": selections]
        if let reply { input["reply_to"] = reply }
        return try call("message_mentions_prepare", input, caller ?? f.writer, command: command)
    }
    func note(_ f: Fixture, _ body: String, plan: JSON? = nil, reply: String? = nil) -> JSON {
        var input: JSON = ["project_id": f.pid, "task_id": f.tid, "body": body]
        if let plan { input["mention_target"] = plan["mention_target"]! }
        if let reply { input["reply_to"] = reply }
        return input
    }
    func recipients(_ value: JSON) -> Set<String> { Set((value["deliveries"] as? [JSON] ?? []).compactMap { $0["recipient_session_id"] as? String }) }
    func planCount() throws -> Int { try router.dbQueue.read { try router.records($0, type: "ordinary_mention_plan").count } }
    func selection(_ token: JSON, _ candidate: JSON) -> JSON { ["start": token["start"]!, "end": token["end"]!, "target": candidate["target"]!] }
    func tokens(_ value: JSON) -> [JSON] { value["tokens"] as? [JSON] ?? [] }
    func candidates(_ token: JSON) -> [JSON] { token["candidates"] as? [JSON] ?? [] }
    func assertFailure(_ code: String, _ operation: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { XCTAssertEqual(($0 as? CoreError)?.code, code, file: file, line: line) }
    }

    func testParserPreservesEmailsCodeAndEscapesAndReportsUTF8Spans() throws {
        let body = "email a@example.com `@Published @MainActor`\n```swift\n@Unknown\n```\n~~~\n@Unknown\n~~~\n\\@literal 🙂 (@CL-12), @{Target worker}"
        let parsed = try OrdinaryMentionTokens.parse(body)
        XCTAssertEqual(parsed.map(\.query), ["CL-12", "Target worker"])
        let bytes = Array(body.utf8)
        XCTAssertEqual(parsed.map { String(decoding: bytes[$0.start..<$0.end], as: UTF8.self) }, ["@CL-12", "@{Target worker}"])
        XCTAssertEqual(try OrdinaryMentionTokens.parse("``literal ` @Published``").count, 0)
        XCTAssertEqual(try OrdinaryMentionTokens.parse("`unfinished @MainActor").count, 0)
        XCTAssertEqual(try OrdinaryMentionTokens.parse("```swift\n@MainActor").count, 0)
        XCTAssertEqual(try OrdinaryMentionTokens.parse("\\\\@CL-12").map(\.query), ["CL-12"])
    }

    func testParserRejectsMalformedAndBoundedOversizeMentions() throws {
        for body in ["@", "@{}", "@{ leading}", "@{trailing }", "@{nested{x}", "@{line\nbreak}", "@{unterminated"] {
            XCTAssertThrowsError(try OrdinaryMentionTokens.parse(body))
        }
        XCTAssertThrowsError(try OrdinaryMentionTokens.parse(String(repeating: "x", count: 65537)))
        XCTAssertThrowsError(try OrdinaryMentionTokens.parse(Array(repeating: "@Worker", count: 51).joined(separator: " ")))
    }

    func testPublicPreparationResolvesTicketAndExactSessionToOneContextualRoute() throws {
        let f = try fixture(), body = "Ask @\(f.target["key"]!) and @\(f.tagged.sessionID!)."
        let plan = try prepare(f, body)
        XCTAssertEqual(plan["state"] as? String, "prepared")
        XCTAssertEqual(tokens(plan).count, 2)
        XCTAssertEqual(plan["body_sha256"] as? String, ChecklistCore.hash(Data(body.utf8)))
        let message = try call("message_send", note(f, body, plan: plan), f.writer)
        XCTAssertEqual(recipients(message), [f.handler.sessionID!, f.tagged.sessionID!])
        XCTAssertEqual((message["mentions"] as? [JSON])?.count, 2)
        XCTAssertTrue((message["deliveries"] as! [JSON]).allSatisfy { $0["state"] as? String == "queued" && $0["acknowledged_at"] == nil })
    }

    func testCrossNamespaceAndDuplicateLabelAmbiguityRequireExplicitFreshSelection() throws {
        let f = try fixture(), key = f.target["key"] as! String
        let sameLabel = try worker(f.project, key), other = try worker(f.project, key)
        let body = "@" + key, before = try planCount(), unresolved = try prepare(f, body)
        XCTAssertEqual(unresolved["state"] as? String, "needs_selection")
        XCTAssertNil(unresolved["mention_target"])
        XCTAssertEqual(try planCount(), before)
        let token = try XCTUnwrap(tokens(unresolved).first), matches = candidates(token)
        XCTAssertEqual(matches.count, 3)
        let chosen = try XCTUnwrap(matches.first { ($0["target"] as? JSON)?["session_id"] as? String == other.sessionID })
        let plan = try prepare(f, body, selections: [selection(token, chosen)])
        XCTAssertEqual(recipients(try call("message_send", note(f, body, plan: plan), f.writer)), [f.handler.sessionID!, other.sessionID!])
        XCTAssertFalse(recipients(try call("message_send", note(f, "later"), f.writer)).contains(sameLabel.sessionID!))
    }

    func testUnknownTokenPreventsPartialPlanAndExplicitForeignReferenceIsRefused() throws {
        let f = try fixture(), body = "@\(f.target["key"]!) @Missing"
        let foreignRoot = directory.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let foreign = try call("project_create", ["name": "Foreign", "key_prefix": "TAG", "root_path": foreignRoot.path])
        let foreignWorker = try worker(foreign, "Missing")
        let foreignGeneration = try router.dbQueue.read { try router.record($0, foreignWorker.sessionID!, type: "session")["authorization_generation"] as! String }
        let before = try planCount()
        let unresolved = try prepare(f, body)
        XCTAssertEqual(tokens(unresolved).map { $0["state"] as! String }, ["resolved", "not_found"])
        XCTAssertNil(unresolved["mention_target"])
        XCTAssertEqual(try planCount(), before)
        let last = try XCTUnwrap(tokens(unresolved).last)
        let forged: JSON = ["start": last["start"]!, "end": last["end"]!, "target": ["kind": "session", "session_id": foreignWorker.sessionID!, "authorization_generation": foreignGeneration]]
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [forged]) }
        assertFailure("MENTION_PREPARATION_REQUIRED") { try self.call("message_send", self.note(f, body), f.writer) }
    }

    func testSelectionShapeSpanAndGenerationCannotForgeOrShiftATarget() throws {
        let f = try fixture(), body = "@{Target worker}", plan = try prepare(f, body)
        let token = try XCTUnwrap(tokens(plan).first), choice = try XCTUnwrap(candidates(token).first)
        let good = selection(token, choice)
        var boolean = good; boolean["start"] = true
        assertFailure("INVALID_INPUT") { try self.prepare(f, body, selections: [boolean]) }
        var fraction = good; fraction["end"] = 1.5
        assertFailure("INVALID_INPUT") { try self.prepare(f, body, selections: [fraction]) }
        var shifted = good; shifted["start"] = 1
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [shifted]) }
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [good, good]) }
        var target = good["target"] as! JSON; target["authorization_generation"] = "old"
        var stale = good; stale["target"] = target
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [stale]) }
        target = good["target"] as! JSON; target["protected"] = true; stale["target"] = target
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [stale]) }
    }

    func testBodyBoundPublicTokenRefusesChangedTextWithoutConsumingPlan() throws {
        let f = try fixture(), body = "@{Target worker}", plan = try prepare(f, body)
        assertFailure("RECIPIENT_CHANGED") { try self.call("message_send", self.note(f, body + " edited", plan: plan), f.writer) }
        let stored = try router.dbQueue.read { try router.record($0, plan["mention_target"] as! String, type: "ordinary_mention_plan") }
        XCTAssertFalse(bool(stored, "used"))
        XCTAssertEqual(recipients(try call("message_send", note(f, body, plan: plan), f.writer)), [f.handler.sessionID!, f.tagged.sessionID!])
    }

    func testCachedPublicChoiceCannotAdoptReconnectedWorkerGeneration() throws {
        let f = try fixture(), body = "@{Target worker}", first = try prepare(f, body)
        let token = try XCTUnwrap(tokens(first).first), choice = try XCTUnwrap(candidates(token).first)
        let oldSelection = selection(token, choice)
        let current = try router.dbQueue.read { try router.record($0, f.tagged.sessionID!, type: "session") }
        _ = try call("session_update", ["project_id": f.pid, "session_id": f.tagged.sessionID!, "expected_revision": current["revision"]!, "state": "ended"])
        _ = try call("session_register", ["project_id": f.pid, "session_id": f.tagged.sessionID!, "role": "worker", "provider": "codex", "label": "Target worker", "state": "connected", "installation": f.tagged.installation, "workspace": f.tagged.workspace!])
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, body, selections: [oldSelection]) }
        XCTAssertEqual(try prepare(f, body)["state"] as? String, "prepared")
    }

    func testPublicScopeReplyAndRoleAreGuardedBeforePreparation() throws {
        let f = try fixture(), body = "@{Target worker}"
        let original = try call("message_send", note(f, "original"), f.writer)
        let plan = try prepare(f, body, reply: original["id"] as? String)
        assertFailure("RECIPIENT_CHANGED") { try self.call("message_send", self.note(f, body, plan: plan), f.writer) }
        let assistant = Caller(role: "assistant", installation: "observer", projectIDs: [f.pid], sessionID: uuid())
        XCTAssertFalse(router.toolCatalog(assistant).contains { $0["name"] as? String == "message_mentions_prepare" })
        assertFailure("FORBIDDEN") { try self.prepare(f, body, caller: assistant) }
        let outsider = Caller(role: "worker", installation: "outside", projectIDs: [], sessionID: uuid(), workspace: f.writer.workspace)
        assertFailure("FORBIDDEN") { try self.prepare(f, body, caller: outsider) }
        assertFailure("INVALID_INPUT") { try self.call("message_mentions_prepare", ["project_id": f.pid, "task_id": f.tid, "body": body, "protected": true]) }
    }

    func testPreparationReplayIsSameBodyAndTokenWithoutAnotherPlan() throws {
        let f = try fixture(), body = "@{Target worker}", command = uuid()
        let first = try prepare(f, body, command: command), count = try planCount()
        let replay = try prepare(f, body, command: command)
        XCTAssertEqual(replay["mention_target"] as? String, first["mention_target"] as? String)
        XCTAssertEqual(try planCount(), count)
        assertFailure("IDEMPOTENCY_CONFLICT") { try self.prepare(f, body + " changed", command: command) }
    }

    func testTechnicalOrdinaryCommentSendsWithoutMentionPreparation() throws {
        let f = try fixture(), body = "Use a@example.com. `@Published` and `@MainActor` are attributes.\n```swift\n@Unknown var value\n```"
        let prepared = try prepare(f, body)
        XCTAssertEqual(prepared["state"] as? String, "untagged")
        XCTAssertNil(prepared["mention_target"])
        let note = try call("message_send", self.note(f, body), f.writer)
        XCTAssertEqual(recipients(note), [f.handler.sessionID!])
        XCTAssertEqual(note["body"] as? String, body)
        assertFailure("MENTION_PREPARATION_REQUIRED") { try self.call("message_send", self.note(f, body + "\n@Unknown"), f.writer) }
    }

    func testMultipleBindingsAreCurrentTokenSpecificAndUnicodeExact() throws {
        let f = try fixture(), a = "\u{00e9}", b = "e\u{0301}"
        let first = try worker(f.project, a), second = try worker(f.project, b)
        let body = "🙂 @\(a) @\(b)", plan = try prepare(f, body), parsed = tokens(plan)
        XCTAssertEqual(parsed.count, 2)
        let selections = parsed.map { selection($0, candidates($0)[0]) }
        let selected = try prepare(f, body, selections: selections)
        XCTAssertEqual(recipients(try call("message_send", note(f, body, plan: selected), f.writer)), [f.handler.sessionID!, first.sessionID!, second.sessionID!])
        // Same byte span alone cannot rebind a choice to a newly typed token.
        let changed = "🙂 @x @\(b)"
        assertFailure("RECIPIENT_CHANGED") { try self.prepare(f, changed, selections: selections) }
    }

    // C38-PUB-001: legal maximum-size inputs, not a duration assertion. Marker
    // lookback happens only at the final marker, never at every backslash.
    func testLegalMaximumBackslashBodyAndMarkerParity() throws {
        XCTAssertEqual(try OrdinaryMentionTokens.parse(String(repeating: "\\", count: 65536)), [])
        XCTAssertEqual(try OrdinaryMentionTokens.parse(String(repeating: "\\", count: 65535) + "@"), [])
        let marked = try OrdinaryMentionTokens.parse(String(repeating: "\\", count: 65530) + "@CL-12")
        XCTAssertEqual(marked, [.init(start: 65530, end: 65536, query: "CL-12")])
        XCTAssertEqual(try OrdinaryMentionTokens.parse(String(repeating: "\\", count: 65532) + "`@x`"), [])
    }

}
