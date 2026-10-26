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

    func testJSONOffloadPreservesValuesAndReturnsIndependentReply() async throws {
        let originalValues = NSMutableArray(array: [NSNull(), true, 42, 0.125, "text"])
        let params: [String: Any] = ["nested": ["values": originalValues]]
        let reply = try await ChecklistClient.offloadBlockingJSONCall(params) { parameters in
            let nested = try XCTUnwrap(parameters["nested"] as? [String: Any])
            let values = try XCTUnwrap(nested["values"] as? [Any])
            XCTAssertEqual(values.count, 5)
            XCTAssertTrue(values[0] is NSNull)
            XCTAssertEqual(values[1] as? Bool, true)
            XCTAssertEqual(values[2] as? Int, 42)
            XCTAssertEqual(values[3] as? Double, 0.125)
            XCTAssertEqual(values[4] as? String, "text")
            // Exercise a mutable worker-local Foundation reply as well.
            return ["result": NSMutableDictionary(dictionary: ["accepted": true, "values": values])]
        }
        originalValues.removeAllObjects()
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["accepted"] as? Bool, true)
        XCTAssertEqual((result["values"] as? [Any])?.count, 5)
    }

    func testJSONOffloadPreservesOperationError() async {
        enum Failure: Error { case original }
        do {
            _ = try await ChecklistClient.offloadBlockingJSONCall([:]) { _ in throw Failure.original }
            XCTFail("The worker's error must reach its caller.")
        } catch Failure.original {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testJSONOffloadRejectsUnsupportedRequestBeforeOperation() async {
        do {
            _ = try await ChecklistClient.offloadBlockingJSONCall(["unsupported": Date()]) { _ in
                XCTFail("Invalid JSON must fail before invoking the operation.")
                return [:]
            }
            XCTFail("Unsupported request values must be rejected.")
        } catch {}
    }

    func testJSONOffloadRejectsUnsupportedReply() async {
        do {
            _ = try await ChecklistClient.offloadBlockingJSONCall([:]) { _ in ["unsupported": Date()] }
            XCTFail("Unsupported reply values must be rejected.")
        } catch {}
    }

    func testOffloadReturnsIndependentSendableValues() async throws {
        let values = try await withThrowingTaskGroup(of: Int.self, returning: Set<Int>.self) { group in
            for value in 0..<32 {
                group.addTask { try await ChecklistClient.offloadBlockingCall { value } }
            }
            var values = Set<Int>()
            for try await value in group { values.insert(value) }
            return values
        }
        XCTAssertEqual(values, Set(0..<32))
    }

    func testConcurrentReadsDoNotBlockXPCProgressOnTheCooperativeExecutor() async {
        let service = Service(); defer { service.stop() }
        let bytes = read
        let endpoint = service.listener.endpoint
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 2)
        let succeeded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let reply = try await ChecklistClient.offloadBlockingCall {
                            let connection = NSXPCConnection(listenerEndpoint: endpoint)
                            let response = try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 1, connection: connection)
                            return (response["data"] as? [String: Any])?["ok"] as? Bool == true
                        }
                        return reply
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
        let endpoint = service.listener.endpoint
        do {
            _ = try await ChecklistClient.offloadBlockingCall {
                let connection = NSXPCConnection(listenerEndpoint: endpoint)
                _ = try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 1, connection: connection)
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
        let endpoint = service.listener.endpoint
        do {
            _ = try await ChecklistClient.offloadBlockingCall {
                let connection = NSXPCConnection(listenerEndpoint: endpoint)
                _ = try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 0.05, connection: connection)
            }
            XCTFail("A loader deadline must return a visible failure.")
        } catch {
            XCTAssertEqual((error as? ChecklistError)?.code, "OUTCOME_UNKNOWN")
            XCTAssertEqual((error as? ChecklistError)?.details["reason"] as? String, "reply_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
