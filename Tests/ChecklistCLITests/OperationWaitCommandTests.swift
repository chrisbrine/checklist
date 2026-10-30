import XCTest
import MCP
@testable import ChecklistBridges
import ChecklistCore
import ChecklistIPC
import ChecklistMCPServer
@testable import ChecklistCLI

/// CL-364: `checklist call --wait`, through the same call function as the installed CLI.
/// The router tests run real operations on an owned store and a real operation queue.
final class OperationWaitCommandTests: XCTestCase {
    private final class Client: BridgeClient, @unchecked Sendable {
        private let lock = NSLock()
        let session: String
        let handler: @Sendable (String, [String: Any], Int) throws -> [String: Any]
        private var reads: [(method: String, params: [String: Any], timeout: TimeInterval?)] = []
        init(session: String, handler: @escaping @Sendable (String, [String: Any], Int) throws -> [String: Any]) { self.session = session; self.handler = handler }
        var statusReads: [(method: String, params: [String: Any], timeout: TimeInterval?)] { lock.lock(); defer { lock.unlock() }; return reads.filter { ["operation_get", "command_status"].contains($0.method) } }
        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            ["data": ["installation": "wait-fixture", "project_id": "wait-project", "session_id": session, "connected": true]]
        }
        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            lock.lock(); reads.append((method, params, replyTimeout)); let count = reads.filter { $0.method == method }.count; lock.unlock()
            return try handler(method, params, count)
        }
    }

    private let commandID = UUID().uuidString, operationID = UUID().uuidString
    private var workspace = ""
    private var context: NativeSessionContext!

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("operation-wait-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        workspace = folder.path
        context = try XCTUnwrap(NativeSessionContext.observed(provider: "codex", environment: ["CODEX_THREAD_ID": UUID().uuidString], currentDirectory: workspace))
    }

    private func bridge(_ client: any BridgeClient) -> Bridge {
        let context = context!
        return Bridge(configuration: .init(workspace: workspace, command: "call"),
                      environment: .init(makeClient: { _ in client }, discover: { _ in .available(context) }, stderr: { _ in }))
    }

    private func run(_ client: any BridgeClient, wait: String? = "--wait=5", method: String = "backup_create", input: String? = nil) async throws -> Value {
        var words = ["call", method, input ?? #"{"project_id":"wait-project","command_id":"\#(commandID)"}"#, "--workspace", workspace]
        if let wait { words.insert(wait, at: 1) }
        return try await ChecklistCommand.call(arguments: Arguments(words), bridge: bridge(client))
    }

    private func envelope(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func accepted(_ state: String = "queued") -> [String: Any] {
        ["command_id": commandID, "command_outcome": "accepted", "data": ["operation_id": operationID, "command_id": commandID, "method": "backup_create", "state": state, "status_method": "operation_get"]]
    }

    private func operation(_ state: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["data": ["operation_id": operationID, "command_id": commandID, "method": "backup_create", "state": state, "status_method": "operation_get"].merging(extra) { _, new in new }]
    }

    private func script(_ steps: [[String: Any]]) -> Client {
        let accepted = accepted()
        return Client(session: context.nativeSessionID) { method, _, count in
            if method == "operation_get" { return steps[min(count - 1, steps.count - 1)] }
            if method == "service_info" { return ["data": ["service": "fixture"]] }
            return accepted
        }
    }

    func testArgumentsAcceptTheWaitFormsAndRefuseTheRestBeforeAnyCommand() throws {
        XCTAssertNil(try Arguments(["call", "m"]).wait)
        XCTAssertEqual(try Arguments(["call", "--wait", "m", "{}"]).wait, 120)
        XCTAssertEqual(try Arguments(["call", "m", "{}", "--wait=30"]).wait, 30)
        XCTAssertEqual(try Arguments(["--wait=0.5", "call", "m"]).wait, 0.5)
        XCTAssertEqual(try Arguments(["call", "--wait", "m", "{}"]).command, ["call", "m", "{}"])
        for bad in ["--wait=", "--wait=0", "--wait=-1", "--wait=abc", "--wait=nan", "--wait=inf", "--wait=3601"] {
            XCTAssertThrowsError(try Arguments(["call", bad, "m"]), bad)
        }
        XCTAssertThrowsError(try Arguments(["call", "--wait", "--wait=3", "m"]))
        XCTAssertThrowsError(try Arguments(["tools", "--wait"]))
        XCTAssertThrowsError(try Arguments(["connect", "--wait=3"]))
    }

    func testSlowOperationPrintsTheFinalReplyInTheSynchronousShape() async throws {
        let final: [String: Any] = ["command_id": commandID, "data": ["status": "complete", "path": "/x"], "write_admission": ["locked": false]]
        let client = script([operation("queued"), operation("running"), operation("running"), operation("succeeded", ["result": final])])
        let started = ProcessInfo.processInfo.systemUptime
        let reply = try await run(client)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: envelope(reply), options: .sortedKeys), try JSONSerialization.data(withJSONObject: final, options: .sortedKeys))
        XCTAssertFalse(OperationWait.isUnfinished(reply))
        let reads = client.statusReads
        XCTAssertEqual(reads.count, 4)
        XCTAssertTrue(reads.allSatisfy { $0.params["operation_id"] as? String == operationID && $0.params["project_id"] as? String == "wait-project" })
        XCTAssertTrue(reads.allSatisfy { ($0.timeout ?? 0) > 0 && ($0.timeout ?? 99) <= 5 }, "Each read has a reply budget within the wait")
        XCTAssertLessThan(elapsed, 3)
        print("CL-364 slow operation: \(reads.count) reads, \(Int(elapsed * 1000)) ms")
    }

    func testFailedOperationThrowsTheOriginalErrorLikeASynchronousFailure() async throws {
        let client = script([operation("running"), operation("failed", ["error": ["code": "BACKUP_CAPACITY_EXCEEDED", "message": "Store preserved.", "details": ["reason": "snapshot_manifest_capacity"]]])])
        do {
            _ = try await run(client)
            XCTFail("A failed operation is not a reply")
        } catch let error as ChecklistError {
            XCTAssertEqual(error.code, "BACKUP_CAPACITY_EXCEEDED")
            XCTAssertEqual(error.details["command_outcome"] as? String, "rejected")
            XCTAssertEqual(error.details["command_id"] as? String, commandID)
            XCTAssertTrue(error.localizedDescription.contains("Reason: snapshot_manifest_capacity."), error.localizedDescription)
        }
    }

    func testTimeoutPrintsTheOperationWithItsStateAndADistinctExit() async throws {
        let client = script([operation("running")])
        let started = ProcessInfo.processInfo.systemUptime
        let reply = try await run(client, wait: "--wait=0.4")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let object = try envelope(reply), data = try XCTUnwrap(object["data"] as? [String: Any]), wait = try XCTUnwrap(object["wait"] as? [String: Any])
        XCTAssertEqual(data["operation_id"] as? String, operationID)
        XCTAssertEqual(data["state"] as? String, "running")
        XCTAssertEqual(wait["finished"] as? Bool, false)
        XCTAssertEqual(wait["reason"] as? String, "timed_out")
        XCTAssertEqual(wait["state"] as? String, "running")
        XCTAssertTrue(OperationWait.isUnfinished(reply))
        XCTAssertEqual(OperationWait.unfinishedExitCode, 124)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testPlainCallAndSynchronousRepliesStayUnchangedAndUnread() async throws {
        let plain = script([operation("succeeded", ["result": ["data": ["x": 1]]])])
        let unread = try envelope(try await run(plain, wait: nil))
        XCTAssertEqual(unread["command_outcome"] as? String, "accepted")
        XCTAssertNil(unread["wait"])
        XCTAssertEqual(plain.statusReads.count, 0)
        let session = context.nativeSessionID
        let synchronous = Client(session: session) { _, _, _ in ["data": ["id": "t1"]] }
        let reply = try envelope(try await run(synchronous, method: "task_get", input: #"{"project_id":"wait-project"}"#))
        XCTAssertEqual((reply["data"] as? [String: Any])?["id"] as? String, "t1")
        XCTAssertEqual(synchronous.statusReads.count, 0)
    }

    func testQueuedWriteWaitsOnCommandStatus() async throws {
        let id = commandID
        let client = Client(session: context.nativeSessionID) { method, params, count in
            if method == "command_status" {
                XCTAssertEqual(params["command_id"] as? String, id)
                return count == 1 ? ["data": ["state": "queued", "command_id": id]] : ["data": ["state": "applied", "command_id": id, "result": ["command_id": id, "data": ["id": "note"]]]]
            }
            return ["command_id": id, "command_outcome": "queued", "data": ["state": "queued", "queued": true, "status_method": "command_status", "command_id": id]]
        }
        let reply = try envelope(try await run(client, method: "message_send"))
        XCTAssertEqual((reply["data"] as? [String: Any])?["id"] as? String, "note")
        XCTAssertEqual(client.statusReads.count, 2)
    }

    func testRestartDuringTheWaitKeepsWaitingAndALastingReadErrorIsNotARejection() async throws {
        let final: [String: Any] = ["data": ["done": true]]
        let succeeded = operation("succeeded", ["result": final])
        let restart = Client(session: context.nativeSessionID) { [accepted = accepted()] method, _, count in
            guard method == "operation_get" else { return accepted }
            if count < 3 { throw CommandReply.unknown(commandID: nil, reason: "connection_ended") }
            return succeeded
        }
        let restarted = try envelope(try await run(restart))
        XCTAssertEqual((restarted["data"] as? [String: Any])?["done"] as? Bool, true)
        let lost = Client(session: context.nativeSessionID) { [accepted = accepted()] method, _, _ in
            guard method == "operation_get" else { return accepted }
            throw ChecklistError("COMMAND_RESULT_EXPIRED", "The result expired.", details: ["command_outcome": "rejected"])
        }
        let reply = try await run(lost)
        XCTAssertTrue(OperationWait.isUnfinished(reply))
        let object = try envelope(reply), wait = try XCTUnwrap(object["wait"] as? [String: Any])
        XCTAssertEqual(wait["reason"] as? String, "read_failed")
        XCTAssertEqual((wait["read_error"] as? [String: Any])?["code"] as? String, "COMMAND_RESULT_EXPIRED")
        XCTAssertEqual(object["command_outcome"] as? String, "accepted", "The accepted receipt stays the last known fact")
    }

    func testAReadThatDoesNotAnswerCannotHoldTheWaitPastItsLimit() async throws {
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { release.signal() }
        let client = Client(session: context.nativeSessionID) { [accepted = accepted()] method, _, _ in
            if method == "operation_get" { release.wait() ; throw CommandReply.unknown(commandID: nil, reason: "late") }
            return accepted
        }
        let started = ProcessInfo.processInfo.systemUptime
        let reply = try await run(client, wait: "--wait=0.3")
        XCTAssertTrue(OperationWait.isUnfinished(reply))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    // Real operations: accepted on a held queue, read through the real router.
    private final class RouterClient: BridgeClient, @unchecked Sendable {
        let router: CommandRouter, caller: Caller, session: String
        private let lock = NSLock()
        private var reads = 0
        var statusReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
        init(router: CommandRouter, caller: Caller, session: String) { self.router = router; self.caller = caller; self.session = session }
        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            ["data": ["installation": "wait-fixture", "project_id": "none", "session_id": session, "connected": true]]
        }
        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            if method == "operation_get" { lock.lock(); reads += 1; lock.unlock() }
            do { return try router.handle(method: method, params: params, caller: caller) }
            catch let error as CoreError { throw ChecklistError(error.code, error.message, details: error.details) }
        }
    }

    private func routerFixture() throws -> (RouterClient, DispatchQueue, URL) {
        let root = URL(fileURLWithPath: workspace)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let lane = DispatchQueue(label: "cl-364-operation-lane")
        router.configureCommandOperations(on: lane)
        addTeardownBlock { lane.sync {}; try? router.closeStore() }
        return (RouterClient(router: router, caller: Caller(role: "owner", installation: "cl-364-owner", projectIDs: []), session: context.nativeSessionID), lane, root)
    }

    func testRealSlowBackupOperationReturnsItsCompleteReply() async throws {
        let (client, lane, root) = try routerFixture()
        lane.suspend()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { lane.resume() }
        let input = #"{"command_id":"\#(commandID)","path":"\#(root.appendingPathComponent("backup").path)"}"#
        let started = ProcessInfo.processInfo.systemUptime
        let reply = try envelope(try await run(client, wait: "--wait=60", input: input))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertNil(reply["command_outcome"], "The final reply replaces the receipt")
        XCTAssertEqual(reply["command_id"] as? String, commandID)
        XCTAssertEqual((reply["data"] as? [String: Any])?["status"] as? String, "complete")
        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "The operation was held until 0.5 s")
        print("CL-364 real slow backup: \(Int(elapsed * 1000)) ms")
    }

    func testRealFailedOperationThrowsItsError() async throws {
        let (client, _, root) = try routerFixture()
        let project = try client.call("project_create", ["command_id": UUID().uuidString, "name": "CL-364 fixture", "key_prefix": "WAIT", "root_path": root.path], replyTimeout: nil)
        let projectID = try XCTUnwrap((project["data"] as? [String: Any])?["id"] as? String)
        // Acceptance runs no domain check, so the missing ticket fails on the operation queue.
        let input = #"{"command_id":"\#(commandID)","project_id":"\#(projectID)","task_id":"\#(UUID().uuidString)"}"#
        do {
            _ = try await run(client, wait: "--wait=60", method: "task_purge_preview", input: input)
            XCTFail("A purge preview of a missing ticket fails")
        } catch let error as ChecklistError {
            print("CL-364 real failed operation: \(error.localizedDescription) after \(client.statusReads) reads")
            XCTAssertGreaterThan(client.statusReads, 0, "The failure came from the operation, not from the send")
            XCTAssertEqual(error.code, "NOT_FOUND")
            XCTAssertEqual(error.details["command_outcome"] as? String, "rejected")
            XCTAssertEqual(error.details["command_id"] as? String, commandID)
        }
    }

    func testRealOperationStillQueuedEndsTheWaitWithItsState() async throws {
        let (client, lane, root) = try routerFixture()
        lane.suspend()
        defer { lane.resume() }
        let input = #"{"command_id":"\#(commandID)","path":"\#(root.appendingPathComponent("backup").path)"}"#
        let reply = try await run(client, wait: "--wait=0.4", input: input)
        XCTAssertTrue(OperationWait.isUnfinished(reply))
        XCTAssertEqual((try envelope(reply)["data"] as? [String: Any])?["state"] as? String, "queued")
    }
}
