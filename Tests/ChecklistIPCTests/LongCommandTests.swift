import ChecklistTestSupport
import Foundation
import XCTest
@testable import ChecklistCore
@testable import ChecklistIPC

/// Real XPC, client decoding and Core command receipts, with an isolated service
/// peer in place of installed-service authentication/bootstrap.
final class LongCommandTests: XCTestCase {
    // The lock transfers the XPC callback once; its only input is immutable response Data.
    private final class ReplySender: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: ((Data) -> Void)?
        init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
        func send(_ response: Data) {
            lock.lock(); let callback = reply; reply = nil; lock.unlock()
            callback?(response)
        }
    }

    // receivedIDs is lock-owned; the remaining references are immutable thread-safe router/synchronization objects.
    private final class Execution: @unchecked Sendable {
        let router: CommandRouter
        let delay: TimeInterval
        let committed: XCTestExpectation
        let commandStarted = DispatchSemaphore(value: 0)
        let commandFinished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var receivedIDs: Set<String> = []
        init(router: CommandRouter, delay: TimeInterval, committed: XCTestExpectation) {
            self.router = router; self.delay = delay; self.committed = committed
        }
        func run(_ request: Data, sender: ReplySender) {
            do {
                let object = try JSONSerialization.jsonObject(with: request) as! JSON
                let params = object["params"] as! JSON
                // Delay the first invocation only; retries keep the same wire input.
                lock.lock(); let first = receivedIDs.insert(params["command_id"] as! String).inserted; lock.unlock()
                if first { commandStarted.signal(); Thread.sleep(forTimeInterval: delay) }
                let result = try router.handle(method: object["method"] as! String, params: params, caller: Caller(role: "owner", installation: "long-command-tests", projectIDs: []))
                committed.fulfill(); commandFinished.signal()
                sender.send(try JSONSerialization.data(withJSONObject: result))
            } catch {
                sender.send(try! JSONSerialization.data(withJSONObject: ["error": ["code": "FIXTURE_FAILED", "message": String(describing: error)]]))
            }
        }
    }

    // NSXPCConnection permits concurrent invalidation; this immutable handle performs that operation only.
    private final class Disconnect: @unchecked Sendable {
        let connection: NSXPCConnection
        let started: DispatchSemaphore
        init(connection: NSXPCConnection, started: DispatchSemaphore) {
            self.connection = connection; self.started = started
        }
        func run() {
            _ = started.wait(timeout: .now() + 5)
            connection.invalidate()
        }
    }

    private final class Service: NSObject, NSXPCListenerDelegate, ChecklistRPC {
        let execution: Execution
        let listener = NSXPCListener.anonymous()
        private let lock = NSLock()
        private var connections: [NSXPCConnection] = []
        init(router: CommandRouter, delay: TimeInterval, committed: XCTestExpectation) {
            execution = Execution(router: router, delay: delay, committed: committed)
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: ChecklistRPC.self)
            connection.exportedObject = self
            lock.lock(); connections.append(connection); lock.unlock(); connection.resume(); return true
        }
        func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
            let execution = execution, sender = ReplySender(reply)
            DispatchQueue.global().async { execution.run(request, sender: sender) }
        }
        func stop() {
            listener.invalidate()
            lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
            active.forEach { $0.invalidate() }
        }
    }

    private func run(delay: TimeInterval, timeout: TimeInterval?, disconnect: Bool = false) throws {
        let parent = FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try TestStore.router(root: root)
        let commandID = UUID().uuidString.lowercased()
        let committed = expectation(description: "Original and replay finish"); committed.expectedFulfillmentCount = 2
        let service = Service(router: router, delay: delay, committed: committed)
        defer { service.stop() }
        let client = ChecklistClient(usesStoredCredential: false)
        let params: JSON = ["command_id": commandID, "name": "Synthetic long command", "key_prefix": "LC", "root_path": root.path]
        func send(_ params: JSON, timeout: TimeInterval?) throws -> JSON {
            let bytes = try JSONSerialization.data(withJSONObject: ["method": "project_create", "params": params])
            let connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
            if disconnect && timeout == nil {
                let disconnect = Disconnect(connection: connection, started: service.execution.commandStarted)
                DispatchQueue.global().async { disconnect.run() }
            }
            return try client.requestOnce(bytes, replyTimeout: timeout, connection: connection)
        }
        var original: JSON?
        let start = Date()
        if timeout != nil || disconnect {
            XCTAssertThrowsError(try send(params, timeout: timeout)) { error in
                XCTAssertEqual((error as? ChecklistError)?.code, "OUTCOME_UNKNOWN")
                XCTAssertEqual((error as? ChecklistError)?.details["command_id"] as? String, commandID)
                if !disconnect { XCTAssertEqual((error as? ChecklistError)?.details["reason"] as? String, "reply_timeout") }
            }
        } else {
            original = try send(params, timeout: nil)
            XCTAssertGreaterThan(Date().timeIntervalSince(start), 15)
            XCTAssertEqual(original?["command_id"] as? String, commandID)
        }
        // Wait explicitly for the original invocation to commit before retrying;
        // no production polling or schedule is involved.
        XCTAssertEqual(service.execution.commandFinished.wait(timeout: .now() + 5), .success)
        let replay = try send(params, timeout: 5)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(replay["command_id"] as? String, commandID)
        if let original { XCTAssertEqual(try jsonString(original["data"]!), try jsonString(replay["data"]!)) }
        XCTAssertEqual(try router.dbQueue.read { try router.records($0, type: "project").count }, 1)
        wait(for: [committed], timeout: 5)
    }

    func testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient() throws {
        try QualificationSuite.requireEnabled()
        try run(delay: 16, timeout: nil)
    }
    func testBoundedClientGetsOriginalIDAndRetryReplaysAfterCommit() throws {
        try run(delay: 2, timeout: 1)
    }
    func testConnectionInvalidationEndsUnboundedWaitWithoutLosingCommandID() throws {
        try run(delay: 0.3, timeout: nil, disconnect: true)
    }
}
