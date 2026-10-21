import Foundation
import XCTest
@testable import ChecklistIPC

final class AsyncServiceCallTests: XCTestCase {
    private final class Service: NSObject, NSXPCListenerDelegate, ChecklistRPC {
        let listener = NSXPCListener.anonymous()
        let response: Data?
        let delay: TimeInterval
        private let lock = NSLock()
        private var connections: [NSXPCConnection] = []

        init(response: Data? = Data("{\"data\":{\"ok\":true}}".utf8), delay: TimeInterval = 0.02) {
            self.response = response; self.delay = delay
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: ChecklistRPC.self)
            connection.exportedObject = self
            lock.lock(); connections.append(connection); lock.unlock()
            connection.resume(); return true
        }
        func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
            guard let response else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { reply(response) }
        }
        func stop() {
            listener.invalidate()
            lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
            active.forEach { $0.invalidate() }
        }
    }
    private let read = Data("{\"method\":\"task_context\",\"params\":{}}".utf8)

    func testConcurrentReadsDoNotBlockXPCProgressOnTheCooperativeExecutor() async {
        let service = Service(); defer { service.stop() }
        let bytes = read
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 2)
        let succeeded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let reply = try await ChecklistClient.offloadBlockingCall {
                            let connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
                            return try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 1, connection: connection)
                        }
                        return (reply["data"] as? [String: Any])?["ok"] as? Bool == true
                    } catch { return false }
                }
            }
            var succeeded = 0
            for await success in group { if success { succeeded += 1 } }
            return succeeded
        }
        XCTAssertEqual(succeeded, count, "Blocking XPC waits must not occupy the Swift cooperative executor.")
    }

    func testSemanticServiceErrorReachesAsyncCaller() async {
        let service = Service(response: Data("{\"error\":{\"code\":\"FILE_UNAVAILABLE\",\"message\":\"The original is unavailable.\"}}".utf8))
        defer { service.stop() }
        let bytes = read
        do {
            _ = try await ChecklistClient.offloadBlockingCall {
                let connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
                return try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 1, connection: connection)
            }
            XCTFail("The service rejection must reach the async loader.")
        } catch {
            XCTAssertEqual((error as? ChecklistError)?.code, "FILE_UNAVAILABLE")
            XCTAssertEqual((error as? ChecklistError)?.details["command_outcome"] as? String, "rejected")
        }
    }

    func testMissingReplyReachesAsyncCallerAtItsDeadline() async {
        let service = Service(response: nil); defer { service.stop() }
        let bytes = read, started = Date()
        do {
            _ = try await ChecklistClient.offloadBlockingCall {
                let connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
                return try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 0.05, connection: connection)
            }
            XCTFail("A loader deadline must return a visible failure.")
        } catch {
            XCTAssertEqual((error as? ChecklistError)?.code, "OUTCOME_UNKNOWN")
            XCTAssertEqual((error as? ChecklistError)?.details["reason"] as? String, "reply_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
