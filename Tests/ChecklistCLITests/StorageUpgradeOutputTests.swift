import XCTest
import Darwin
import MCP
import ChecklistIPC
@testable import ChecklistCLI

final class StorageUpgradeOutputTests: XCTestCase {
    private final class StatusPlatform: LocalCommandTransport, LocalServiceLifecycle, LocalCredentialReader, @unchecked Sendable {
        var requests: [[String: Any]] = []
        var credentialReads = 0
        var reply: [String: Any] = ["data": ["service": "checklist", "state": "ready"]]
        var services: LocalPlatformServices { .init(transport: self, lifecycle: self, credentials: self, supportedCapabilities: Set(LocalPlatformCapability.allCases)) }
        func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any] {
            requests.append(try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
            XCTAssertEqual(replyTimeout, 10)
            return reply
        }
        func prepare() throws {}
        func registerInstalledBuild() throws { XCTFail("A status probe never registers an owner app") }
        func startService(timeLimit: TimeInterval) throws {}
        func readInstallationCredential(_ installation: String) throws -> String? { credentialReads += 1; XCTFail("A status probe never reads Keychain"); return nil }
    }
    func testReadinessProbeUsesUnenrolledStatusWithoutCredentialReadOrBootstrap() throws {
        let platform = StatusPlatform()
        _ = try ChecklistCommand.serviceStatus(installation: "synthetic-status", workspace: "/synthetic", platformServices: platform.services)
        XCTAssertEqual(platform.credentialReads, 0)
        XCTAssertEqual(platform.requests.count, 1)
        XCTAssertEqual(platform.requests.first?["method"] as? String, "service_info")
        XCTAssertNil(platform.requests.first?["credential"])
    }
    private func legacyStatus(_ platform: StatusPlatform) async throws -> Value {
        let client = ChecklistClient(installation: "synthetic-status", workspace: "/synthetic",
                                     usesStoredCredential: false, platformServices: platform.services)
        let bytes = try await client.callAsyncData("service_info", Data("{}".utf8), replyTimeout: 10)
        return try JSONDecoder().decode(Value.self, from: bytes)
    }

    func testReadinessProjectionMatchesLegacyDecodeAcrossGeneratedReplies() async throws {
        let platform = StatusPlatform()
        for index in 0..<36 {
            platform.reply = ["data": ["build": "fixture-\(index)", "healthy": index.isMultiple(of: 2),
                "details": ["text": "line\n§\(index)\t\"/", "null": NSNull(), "avatar": "data:text/plain;base64,YQ==",
                            "values": [index, 3.125, NSNumber(value: UInt64.max), NSNull()] as [Any]]],
                "_checklist_timing": ["preparation_ms": Double(index) / 7]]
            let previous = try await legacyStatus(platform)
            let current = try ChecklistCommand.serviceStatus(installation: "synthetic-status", workspace: "/synthetic",
                                                              platformServices: platform.services)
            XCTAssertEqual(current, previous)
        }
        XCTAssertEqual(platform.requests.count, 72)
        XCTAssertEqual(platform.credentialReads, 0)
    }

    func testBenchmarkReadinessClientOverhead() async throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_P522D_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CHECKLIST_P522D_BENCHMARK=1 for the paired component measurement.")
        }
        let platform = StatusPlatform()
        platform.reply = ["data": ["service": "checklist", "state": "ready", "diagnostics": (0..<160).map { index in
            ["name": "synthetic diagnostic \(index)", "active": index.isMultiple(of: 2),
             "count": index, "recent_ms": [12.5, 46.75, 132.875]] as [String: Any]
        }]]
        let expected = try await legacyStatus(platform)
        let callsPerPath = 100
        var elapsed: [UInt64] = [0, 0]
        var cpu: [UInt64] = [0, 0]
        for index in 0..<callsPerPath {
            for variant in index.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                let start = DispatchTime.now().uptimeNanoseconds
                let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
                let reply = variant == 0 ? try await legacyStatus(platform)
                    : try ChecklistCommand.serviceStatus(installation: "synthetic-status", workspace: "/synthetic",
                                                         platformServices: platform.services)
                cpu[variant] += clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
                elapsed[variant] += DispatchTime.now().uptimeNanoseconds - start
                XCTAssertEqual(reply, expected)
            }
        }
        XCTAssertEqual(platform.requests.count, 2 * callsPerPath + 1)
        XCTAssertEqual(platform.credentialReads, 0)
        for (variant, label) in ["before", "after"].enumerated() {
            let divisor = Double(callsPerPath) * 1e6
            print("CL-522 diagnostic client \(label): \(callsPerPath) calls, wall \(Double(elapsed[variant]) / divisor) ms/call, CPU \(Double(cpu[variant]) / divisor) ms/call")
        }
    }

    func testUpgradeDiagnosticIsStructuredAndKeepsStageEstimateAndOutcome() throws {
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "migration_rehearsal", estimatedRemainingSeconds: 360))
        let bytes = try XCTUnwrap(ChecklistCommand.upgradeErrorOutput(status.error(), command: "service"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any]), details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "STORAGE_UPGRADING")
        XCTAssertTrue((error["message"] as? String)?.contains("about 6 minutes") == true)
        XCTAssertEqual(details["state"] as? String, "upgrading")
        XCTAssertEqual(details["stage"] as? String, "migration_rehearsal")
        XCTAssertEqual(details["estimated_remaining_seconds"] as? Int, 360)
        XCTAssertEqual(details["command_outcome"] as? String, "not_sent")
    }
    func testMCPStartupAndOrdinaryErrorsNeverWriteDiagnosticJSONToStdout() throws {
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "final_migration", estimatedRemainingSeconds: 90))
        XCTAssertNil(ChecklistCommand.upgradeErrorOutput(status.error(), command: "mcp"))
        XCTAssertNil(ChecklistCommand.upgradeErrorOutput(ChecklistError("SERVICE_UNAVAILABLE", "Synthetic offline"), command: "service"))
    }
}
