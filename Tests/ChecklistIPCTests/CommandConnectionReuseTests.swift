import Darwin
import Foundation
import Security
import XCTest
@testable import ChecklistIPC

final class CommandConnectionReuseTests: XCTestCase {
    private final class Server: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        private let listener = NSXPCListener.anonymous()
        private let admission: ClientConnectionAdmission
        private let lock = NSLock()
        private var connections: [NSXPCConnection] = []
        private var requests: [(String, String?)] = []
        private var heldReply: ((Data) -> Void)?

        init(identity: ClientBuildIdentity) {
            admission = ClientConnectionAdmission(currentClients: [identity], checklistIdentifiers: [])
            super.init()
            listener.delegate = self
            listener.resume()
        }

        var admitted: Int { lock.withLock { connections.count } }
        var methods: [String] { lock.withLock { requests.map(\.0) } }
        var commandIDs: [String] { lock.withLock { requests.compactMap(\.1) } }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            admission.accept(connection, timedPeer: { timing in
                self.lock.withLock { self.connections.append(connection) }
                return Peer(server: self, admission: timing)
            })
        }

        func transport(reusingConnection: Bool) -> MacOSLocalCommandTransport {
            MacOSLocalCommandTransport(reusingConnection: reusingConnection) {
                NSXPCConnection(listenerEndpoint: self.listener.endpoint)
            }
        }

        func stop() {
            listener.invalidate()
            let inbound = lock.withLock {
                let active = connections
                connections.removeAll()
                heldReply = nil
                return active
            }
            inbound.forEach { $0.invalidate() }
        }

        private final class Peer: NSObject, ChecklistRPC {
            weak var server: Server?
            let admission: ClientAdmissionTiming

            init(server: Server, admission: ClientAdmissionTiming) {
                self.server = server
                self.admission = admission
            }

            func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
                let received = ProcessInfo.processInfo.systemUptime
                guard let server else { return }
                let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
                let method = object["method"] as? String ?? ""
                let params = object["params"] as? [String: Any] ?? [:]
                let commandID = params["command_id"] as? String
                let withhold = params["withhold_reply"] as? Bool == true
                server.lock.withLock {
                    server.requests.append((method, commandID))
                    if withhold { server.heldReply = reply }
                }
                guard !withhold else { return }
                var data: [String: Any] = ["method": method, "params": params]
                if method == "connection_bootstrap" {
                    data["connected"] = true
                    data["installation"] = "anonymous-fixture"
                    data["session_id"] = "00000000-0000-0000-0000-000000000001"
                }
                var result: [String: Any] = ["data": data]
                if let commandID { result["command_id"] = commandID }
                if let bytes = try? ServiceCallTiming(received: received, admission: admission).encode(result) { reply(bytes) }
            }
        }
    }

    private let upgradeRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

    private func localServer() throws -> Server {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        return Server(identity: try XCTUnwrap(ClientBuildIdentity.running(XCTUnwrap(code))))
    }

    private func send(_ method: String, through transport: MacOSLocalCommandTransport,
                      params: [String: Any] = [:], timeout: TimeInterval = 5) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        return try transport.request(request, replyTimeout: timeout, connection: nil, upgradeRoot: upgradeRoot)
    }

    private func timing(_ reply: [String: Any]) throws -> (received: Double, listener: Double, admitted: Double) {
        let timing = try XCTUnwrap(reply["_checklist_timing"] as? [String: Any])
        let admission = try XCTUnwrap(timing["admission"] as? [String: Any])
        return (try XCTUnwrap(timing["received_uptime_s"] as? Double),
                try XCTUnwrap(admission["listener_uptime_s"] as? Double),
                try XCTUnwrap(admission["admitted_uptime_s"] as? Double))
    }

    func testConnectionReusePreservesRepliesAndEliminatesSecondListenerAdmission() throws {
        let service = try localServer()
        defer { service.stop() }

        for index in 0..<12 {
            let scoped = service.transport(reusingConnection: true)
            let fresh = service.transport(reusingConnection: false)
            var baseline: [[String: Any]] = []
            var changed: [[String: Any]] = []
            let initialCount = service.admitted
            for method in ["connection_bootstrap", "service_info"] {
                let params: [String: Any] = ["fixture": index, "include": index.isMultiple(of: 2)]
                baseline.append(try send(method, through: fresh, params: params))
                changed.append(try send(method, through: scoped, params: params))
            }
            for (old, new) in zip(baseline, changed) {
                XCTAssertEqual(old["data"] as? NSDictionary, new["data"] as? NSDictionary)
            }
            let firstFresh = try timing(baseline[0]), secondFresh = try timing(baseline[1])
            let firstScoped = try timing(changed[0]), secondScoped = try timing(changed[1])
            XCTAssertGreaterThan(secondFresh.listener, firstFresh.received)
            XCTAssertEqual(secondScoped.listener, firstScoped.listener)
            XCTAssertEqual(secondScoped.admitted, firstScoped.admitted)
            XCTAssertGreaterThan(secondScoped.received, firstScoped.received)
            XCTAssertEqual(service.admitted - initialCount, 3)
        }
        XCTAssertEqual(service.methods.count, 48)
    }

    func testTimeoutRetiresConnectionWithoutResendingTheCommand() throws {
        let service = try localServer()
        defer { service.stop() }
        let scoped = service.transport(reusingConnection: true)
        _ = try send("connection_bootstrap", through: scoped)
        let commandID = UUID().uuidString
        XCTAssertThrowsError(try send("task_edit", through: scoped,
                                      params: ["command_id": commandID, "withhold_reply": true], timeout: 0.2)) { error in
            let reply = error as? ChecklistError
            XCTAssertEqual(reply?.code, "OUTCOME_UNKNOWN")
            XCTAssertEqual(reply?.details["command_id"] as? String, commandID)
            XCTAssertEqual(reply?.details["reason"] as? String, "reply_timeout")
        }

        _ = try send("service_info", through: scoped)
        XCTAssertEqual(service.methods, ["connection_bootstrap", "task_edit", "service_info"])
        XCTAssertEqual(service.commandIDs, [commandID])
        XCTAssertEqual(service.admitted, 2)
    }

    func testBenchmarkPairedServiceInfoConnections() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHECKLIST_XPC_REUSE_BENCHMARK"] == "1")
        let service = try localServer()
        defer { service.stop() }
        let wallTime = { ProcessInfo.processInfo.systemUptime }
        func cpuTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }

        struct Sample {
            let pairMS: Double
            let secondReadMS: Double
            let secondArrivalMS: Double
            let secondAdmissionMS: Double
            let cpuMicroseconds: Double
        }
        func pair(reused: Bool) throws -> Sample {
            let transport = service.transport(reusingConnection: reused)
            let cpuStart = cpuTime()
            let start = wallTime()
            _ = try send("connection_bootstrap", through: transport)
            let secondStart = wallTime()
            let reply = try send("service_info", through: transport)
            let end = wallTime()
            let cpu = cpuTime() - cpuStart
            let second = try timing(reply)
            let newAdmissionMS = reused ? 0 : 1000 * (second.received - max(second.admitted, secondStart))
            return Sample(pairMS: 1000 * (end - start), secondReadMS: 1000 * (end - secondStart),
                          secondArrivalMS: 1000 * (second.received - secondStart),
                          secondAdmissionMS: newAdmissionMS,
                          cpuMicroseconds: Double(cpu) / 1000)
        }
        func summarize(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            return String(format: "p50=%.3f p95=%.3f", median, p95)
        }

        _ = try pair(reused: false)
        _ = try pair(reused: true)
        func load() -> [Double] {
            var values = [Double](repeating: 0, count: 3)
            let count = values.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
            return Array(values.prefix(max(0, Int(count))))
        }
        let initialCount = service.admitted
        let utc = ISO8601DateFormatter()
        let startLoad = load()
        let startedAt = utc.string(from: Date())
        var fresh: [Sample] = [], shared: [Sample] = []
        for index in 0..<80 {
            if index.isMultiple(of: 2) {
                fresh.append(try pair(reused: false))
                shared.append(try pair(reused: true))
            } else {
                shared.append(try pair(reused: true))
                fresh.append(try pair(reused: false))
            }
        }
        let endedAt = utc.string(from: Date())
        let endLoad = load()
        XCTAssertEqual(service.admitted - initialCount, 240)
        print("CL-522 XPC paired window \(startedAt) load=\(startLoad) → \(endedAt) load=\(endLoad)")
        for (label, samples) in [("fresh connection", fresh), ("reused connection", shared)] {
            print("CL-522 XPC \(label) n=\(samples.count) pair_ms \(summarize(samples.map(\.pairMS))) second_read_ms \(summarize(samples.map(\.secondReadMS))) second_arrival_ms \(summarize(samples.map(\.secondArrivalMS))) new_second_admission_to_receive_ms \(summarize(samples.map(\.secondAdmissionMS))) cpu_us_per_pair \(summarize(samples.map(\.cpuMicroseconds)))")
        }
    }
}
