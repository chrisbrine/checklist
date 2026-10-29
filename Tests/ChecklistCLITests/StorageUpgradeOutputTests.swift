import XCTest
import ChecklistIPC
@testable import ChecklistCLI

final class StorageUpgradeOutputTests: XCTestCase {
    private final class StatusPlatform: LocalCommandTransport, LocalServiceLifecycle, LocalCredentialReader, @unchecked Sendable {
        var requests: [[String: Any]] = []
        var credentialReads = 0
        var services: LocalPlatformServices { .init(transport: self, lifecycle: self, credentials: self, supportedCapabilities: Set(LocalPlatformCapability.allCases)) }
        func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any] {
            requests.append(try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
            return ["data": ["service": "checklist", "state": "ready"]]
        }
        func prepare() throws {}
        func registerInstalledBuild() throws { XCTFail("A status probe never registers an owner app") }
        func startService(timeLimit: TimeInterval) throws {}
        func readInstallationCredential(_ installation: String) throws -> String? { credentialReads += 1; XCTFail("A status probe never reads Keychain"); return nil }
    }
    func testReadinessProbeUsesUnenrolledStatusWithoutCredentialReadOrBootstrap() async throws {
        let platform = StatusPlatform()
        _ = try await ChecklistCommand.serviceStatus(installation: "synthetic-status", workspace: "/synthetic", platformServices: platform.services)
        XCTAssertEqual(platform.credentialReads, 0)
        XCTAssertEqual(platform.requests.count, 1)
        XCTAssertEqual(platform.requests.first?["method"] as? String, "service_info")
        XCTAssertNil(platform.requests.first?["credential"])
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
