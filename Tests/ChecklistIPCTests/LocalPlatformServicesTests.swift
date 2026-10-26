import Foundation
import XCTest
@testable import ChecklistIPC

final class LocalPlatformServicesTests: XCTestCase {
    private final class FakePlatform: LocalCommandTransport, LocalServiceLifecycle, LocalCredentialReader, @unchecked Sendable {
        var preparations = 0
        var registrations = 0
        var startupLimits: [TimeInterval] = []
        var credentialAccounts: [String] = []
        var requests: [Data] = []
        var timeouts: [TimeInterval?] = []
        var credential: String? = "fixture-credential"
        var registrationError: Error?
        var failures: [Error] = []

        var services: LocalPlatformServices {
            LocalPlatformServices(transport: self, lifecycle: self, credentials: self,
                                  supportedCapabilities: Set(LocalPlatformCapability.allCases))
        }
        func prepare() throws { preparations += 1 }
        func registerInstalledBuild() throws {
            registrations += 1
            if let registrationError { throw registrationError }
        }
        func startService(timeLimit: TimeInterval) throws { startupLimits.append(timeLimit) }
        func readInstallationCredential(_ installation: String) throws -> String? {
            credentialAccounts.append(installation)
            return credential
        }
        func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any] {
            requests.append(bytes)
            timeouts.append(replyTimeout)
            if !failures.isEmpty { throw failures.removeFirst() }
            return ["data": ["fixture": true]]
        }
        func envelope(_ index: Int = 0) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: requests[index]) as? [String: Any])
        }
    }

    func testUnavailableCapabilitiesArePreciseAndAdvertiseNoSupport() throws {
        let services = LocalPlatformServices.unavailable(platform: "fixture-platform")
        XCTAssertTrue(services.supportedCapabilities.isEmpty)
        let operations: [(LocalPlatformCapability, () throws -> Void)] = [
            (.localCommandTransport, { _ = try services.transport.request(Data(), replyTimeout: nil) }),
            (.servicePreparation, { try services.lifecycle.prepare() }),
            (.serviceRegistration, { try services.lifecycle.registerInstalledBuild() }),
            (.serviceStartup, { try services.lifecycle.startService(timeLimit: 1) }),
            (.installationCredentialRead, { _ = try services.credentials.readInstallationCredential("fixture") })
        ]
        for (capability, operation) in operations {
            XCTAssertThrowsError(try operation()) { failure in
                let error = failure as? ChecklistError
                XCTAssertEqual(error?.code, "PLATFORM_CAPABILITY_UNAVAILABLE")
                XCTAssertEqual(error?.details["capability"] as? String, capability.rawValue)
                XCTAssertEqual(error?.details["platform"] as? String, "fixture-platform")
            }
        }
    }

    func testUnavailableClientDoesNotFallBackToNativeRuntime() {
        let client = ChecklistClient(platformServices: .unavailable(platform: "fixture-platform"))
        for operation in [{ try client.call("service_info") }, { try client.bootstrap(["session_id": "fixture"]) }] {
            XCTAssertThrowsError(try operation()) { failure in
                let error = failure as? ChecklistError
                XCTAssertEqual(error?.code, "PLATFORM_CAPABILITY_UNAVAILABLE")
                XCTAssertEqual(error?.details["capability"] as? String, "service_preparation")
            }
        }
    }

    func testWorkerRequestUsesOnlyItsSelectedCredentialAndNativeContext() throws {
        let fake = FakePlatform()
        let client = ChecklistClient(installation: "fixture-installation", workspace: "/fixture-workspace",
                                     nativeContext: ["session_id": "fixture-session"], platformServices: fake.services)
        _ = try client.call("service_info", replyTimeout: 3)
        let request = try fake.envelope()
        XCTAssertEqual(fake.preparations, 1)
        XCTAssertEqual(fake.registrations, 0)
        XCTAssertEqual(fake.credentialAccounts, ["fixture-installation"])
        XCTAssertEqual(request["credential"] as? String, "fixture-credential")
        XCTAssertEqual(request["owner_channel"] as? Bool, false)
        XCTAssertEqual(request["installation"] as? String, "fixture-installation")
        XCTAssertEqual(request["workspace"] as? String, "/fixture-workspace")
        XCTAssertEqual((request["native_context"] as? [String: Any])?["session_id"] as? String, "fixture-session")
        XCTAssertEqual(fake.timeouts.first!, 3)
    }

    func testOwnerRequestRegistersButDoesNotReadCredentialOrSupplyNativeContext() throws {
        let fake = FakePlatform()
        let client = ChecklistClient(owner: true, nativeContext: ["session_id": "fixture-session"], platformServices: fake.services)
        _ = try client.call("service_info")
        let request = try fake.envelope()
        XCTAssertEqual(fake.preparations, 1)
        XCTAssertEqual(fake.registrations, 1)
        XCTAssertTrue(fake.credentialAccounts.isEmpty)
        XCTAssertEqual(request["owner_channel"] as? Bool, true)
        XCTAssertNil(request["credential"])
        XCTAssertNil(request["native_context"])
    }

    func testUnenrolledRequestDoesNotReadCredential() throws {
        let fake = FakePlatform()
        _ = try ChecklistClient(usesStoredCredential: false, platformServices: fake.services).call("service_info")
        XCTAssertTrue(fake.credentialAccounts.isEmpty)
        XCTAssertNil(try fake.envelope()["credential"])
    }

    func testOwnerRegistrationFailureStopsBeforeTransport() {
        let fake = FakePlatform()
        fake.registrationError = ChecklistError("OWNER_CHANNEL_REQUIRED", "fixture")
        XCTAssertThrowsError(try ChecklistClient(owner: true, platformServices: fake.services).call("task_edit")) { failure in
            XCTAssertEqual((failure as? ChecklistError)?.code, "OWNER_CHANNEL_REQUIRED")
        }
        XCTAssertTrue(fake.requests.isEmpty)
        XCTAssertTrue(fake.credentialAccounts.isEmpty)
        XCTAssertTrue(fake.startupLimits.isEmpty)
    }

    func testDefiniteTransportUnavailabilityRetriesIdenticalMutationOnce() throws {
        let fake = FakePlatform()
        fake.failures = [ChecklistError("SERVICE_UNAVAILABLE", "fixture")]
        _ = try ChecklistClient(platformServices: fake.services).call("task_edit", ["title": "fixture"], replyTimeout: 2)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(fake.requests[0], fake.requests[1])
        XCTAssertEqual(fake.startupLimits, [8])
        XCTAssertEqual(fake.credentialAccounts.count, 1)
        let params = try XCTUnwrap(try fake.envelope()["params"] as? [String: Any])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(params["command_id"] as? String)))
        XCTAssertEqual(fake.timeouts.compactMap { $0 }, [2, 2])
    }

    func testSecondUnavailableReplyStopsWithoutAnotherStartup() {
        let fake = FakePlatform()
        fake.failures = [ChecklistError("SERVICE_UNAVAILABLE", "first"), ChecklistError("SERVICE_UNAVAILABLE", "second")]
        XCTAssertThrowsError(try ChecklistClient(platformServices: fake.services).call("service_info")) { failure in
            XCTAssertEqual((failure as? ChecklistError)?.message, "second")
        }
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(fake.startupLimits, [8])
    }

    func testOutcomeUnknownNeverStartsOrRetriesAndRetainsOriginalCommandID() {
        let fake = FakePlatform()
        fake.failures = [CommandReply.unknown(commandID: "original-id", reason: "transport_error_after_send")]
        XCTAssertThrowsError(try ChecklistClient(platformServices: fake.services).call("task_edit", ["command_id": "original-id"])) { failure in
            let error = failure as? ChecklistError
            XCTAssertEqual(error?.code, "OUTCOME_UNKNOWN")
            XCTAssertEqual(error?.details["command_id"] as? String, "original-id")
        }
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertTrue(fake.startupLimits.isEmpty)
    }

    func testBootstrapKeepsUnenrolledEnvelopeAndBoundedRetry() throws {
        let fake = FakePlatform()
        fake.failures = [ChecklistError("SERVICE_UNAVAILABLE", "fixture")]
        let client = ChecklistClient(owner: true, installation: "ignored-installation", platformServices: fake.services)
        _ = try client.bootstrap(["session_id": "fixture-session"], timeBudget: 3)
        let request = try fake.envelope()
        XCTAssertEqual(request["method"] as? String, "connection_bootstrap")
        XCTAssertEqual(request["installation"] as? String, "automatic")
        XCTAssertEqual(request["owner_channel"] as? Bool, false)
        XCTAssertEqual((request["params"] as? [String: Any])?["session_id"] as? String, "fixture-session")
        XCTAssertNil(request["credential"])
        XCTAssertNil(request["workspace"])
        XCTAssertEqual(fake.registrations, 0)
        XCTAssertTrue(fake.credentialAccounts.isEmpty)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(fake.requests[0], fake.requests[1])
        XCTAssertEqual(fake.startupLimits.count, 1)
        XCTAssertTrue(fake.startupLimits.allSatisfy { $0 > 0 && $0 <= 3 })
        XCTAssertEqual(fake.timeouts.compactMap { $0 }.count, 2)
        XCTAssertTrue(fake.timeouts.compactMap { $0 }.allSatisfy { $0 > 0 && $0 <= 3 })
    }

    func testInvalidBootstrapBudgetFailsBeforePlatformEffects() {
        let fake = FakePlatform()
        let client = ChecklistClient(platformServices: fake.services)
        for budget in [-1, TimeInterval.infinity, TimeInterval.nan] {
            XCTAssertThrowsError(try client.bootstrap([:], timeBudget: budget)) { failure in
                XCTAssertEqual((failure as? ChecklistError)?.code, "INVALID_INPUT")
            }
        }
        XCTAssertEqual(fake.preparations, 0)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testNativeTransportRejectsInvalidTimeoutBeforeOpeningConnection() {
        let transport = MacOSLocalCommandTransport()
        for timeout in [-1, TimeInterval.infinity, TimeInterval.nan] {
            XCTAssertThrowsError(try transport.request(Data(), replyTimeout: timeout)) { failure in
                XCTAssertEqual((failure as? ChecklistError)?.code, "INVALID_INPUT")
            }
        }
    }
}
