import Darwin
import Foundation
import XCTest
@testable import ChecklistMCPServer

final class MCPServiceInfoBenchmarkTests: XCTestCase {
    private final class MockService: BridgeClient, @unchecked Sendable {
        let toolCount = 150
        private lazy var catalog: [String: Any] = ["data": ["tools": (0..<toolCount).map { index in
            ["name": index == 0 ? "service_info" : "synthetic_\(index)",
             "description": "Read a scoped Checklist record and its current revision.",
             "inputSchema": ["type": "object", "additionalProperties": false,
                             "properties": ["project_id": ["type": "string", "format": "uuid"],
                                            "record_id": ["type": "string", "format": "uuid"],
                                            "expected_revision": ["type": "integer"]]],
             "annotations": ["readOnlyHint": true, "openWorldHint": false]] as [String: Any]
        }]]
        private let lock = NSLock()
        private var catalogReads = 0
        private var statusReads = 0

        var counts: (catalog: Int, status: Int) { lock.withLock { (catalogReads, statusReads) } }

        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            XCTFail("The mock is already paired.")
            return [:]
        }

        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            lock.withLock {
                switch method {
                case "tool_catalog":
                    catalogReads += 1
                    return catalog
                case "service_info":
                    statusReads += 1
                    return ["data": ["build_id": "synthetic", "role": "worker"]]
                default:
                    XCTFail("Unexpected service request \(method)")
                    return [:]
                }
            }
        }
    }

    func testMeasurePersistentMCPServiceInfo() async throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_MCP_SERVICE_INFO_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CHECKLIST_MCP_SERVICE_INFO_BENCHMARK=1 to measure the bridge.")
        }
        let service = MockService()
        let bridge = Bridge(configuration: .init(workspace: FileManager.default.currentDirectoryPath, automatic: false),
                            environment: .init(makeClient: { _ in service }))
        let catalog = try await bridge.tools()
        XCTAssertEqual(catalog.count, service.toolCount)
        let expected = try await bridge.concurrentCall("service_info", .object([:]))
        let before = service.counts
        let count = 1_200
        let start = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for _ in 0..<count {
            let reply = try await bridge.concurrentCall("service_info", .object([:]))
            XCTAssertEqual(reply, expected)
        }
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
        let wall = DispatchTime.now().uptimeNanoseconds - start
        let after = service.counts
        XCTAssertEqual(after.status - before.status, count)
        print("CL-522 MCP component \(count) calls, \(after.catalog - before.catalog) catalog reads, " +
              "\(Double(count) * 1e9 / Double(wall)) calls/s, \(Double(cpu) / Double(count) / 1e3) CPU us/call, " +
              "\(Double(wall) / 1e9) wall s")
    }
}
