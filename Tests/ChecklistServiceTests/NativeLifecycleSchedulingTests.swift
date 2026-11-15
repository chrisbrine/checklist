import XCTest
import Foundation
import ChecklistIPC
import ChecklistProviders
import ChecklistBridges
@testable import ChecklistCore
@testable import ChecklistService

final class NativeLifecycleSchedulingTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        @discardableResult func append(_ value: String) -> Int { lock.withLock { values.append(value); return values.count } }
        var snapshot: [String] { lock.withLock { values } }
    }
    private var root: URL!
    private var coordinator: Coordinator!

    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification/r12-N/test-fixtures")
            .appendingPathComponent("native-lifecycle-scheduling-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let instance = try ChecklistInstance(home: root, environment: [:])
        let credentials = InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: credentials, instance: instance)
        coordinator.nativeLifecycle.watchesEnabled = false
    }

    override func tearDownWithError() throws {
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.nativeLifecycle.observationScheduled)
            XCTAssertFalse(coordinator.nativeLifecycle.connectionRequestScheduled)
            coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel()
        }
        coordinator.queue.busyPeriods.flush()
        try coordinator.router.closeStore()
        coordinator = nil
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: trash.appendingPathComponent(root.lastPathComponent))
    }

    func testForegroundReadRunsBetweenQueuedNativeRequests() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync {
            coordinator.enqueueNativeConnectionRequest {
                trace.append("native-1")
                coordinator.queue.async { trace.append("foreground-read") }
            }
            coordinator.enqueueNativeConnectionRequest {
                trace.append("native-2"); finished.signal()
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.snapshot, ["native-1", "foreground-read", "native-2"])
    }

    func testReentrantNativeRequestKeepsFIFOAndDoesNotCreateAnotherDrain() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync {
            coordinator.enqueueNativeConnectionRequest {
                trace.append("native-1")
                coordinator.enqueueNativeConnectionRequest {
                    trace.append("native-3"); finished.signal()
                }
                coordinator.queue.async { trace.append("foreground-read") }
            }
            coordinator.enqueueNativeConnectionRequest { trace.append("native-2") }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {
            XCTAssertEqual(coordinator.nativeLifecycle.connectionRequestOffset, 0)
            XCTAssertTrue(coordinator.nativeLifecycle.connectionRequests.isEmpty)
        }
        XCTAssertEqual(trace.snapshot, ["native-1", "foreground-read", "native-2", "native-3"])
    }

    private func enrollment(_ index: Int) -> Enrollment {
        let sid = UUID().uuidString.lowercased()
        var value = Enrollment(installation: "synthetic-lifecycle-\(index)", name: "Synthetic observer fixture", provider: "claude",
            role: "worker", projectIDs: [], sessionID: sid, workspace: root.path, profileID: nil,
            tokenDigest: "synthetic-unusable-digest", generation: "synthetic-original")
        value.automatic = true; value.nativeSessionID = sid
        value.nativeExecutionDomain = "claude:\(24680 + index):5:0"
        value.identityVerification = ProviderPluginRegistry.bundled.plugin("claude", requiring: .registryClosure)?.nativeHost?.identityVerification
        return value
    }

    func testThirtyEventBurstCoalescesAndYieldsBetweenEnrollmentInspections() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        let count = 8
        let values = (0..<count).map(enrollment)
        coordinator.queue.sync {
            coordinator.enrollments = Dictionary(uniqueKeysWithValues: values.map { ($0.installation, $0) })
            coordinator.nativeLifecycle.inspect = { registration in
                let ordinal = trace.append(registration.sessionID)
                if ordinal == 1 {
                    coordinator.queue.async { trace.append("foreground-read") }
                }
                // There is one extra trace entry for the foreground read.
                if ordinal == count + 1 { finished.signal() }
                return .init(process: .running, registry: .matching, detail: "Owned observer fixture")
            }
            for _ in 0..<30 { coordinator.observeNativeConversationLifecycles() }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.nativeLifecycle.observationScheduled)
            XCTAssertFalse(coordinator.nativeLifecycle.observationDirty)
        }
        let observed = trace.snapshot
        XCTAssertEqual(observed.count, count + 1)
        XCTAssertEqual(observed.dropFirst().first, "foreground-read")
        XCTAssertEqual(Set(observed.filter { $0 != "foreground-read" }), Set(values.map(\.sessionID)))
    }

    /// Pre-change observer selection retained independently of the new helper.
    /// Generated flags cover every old eligibility guard; fake running evidence
    /// prevents any closure write and touches no provider registry.
    private func legacyEligibleSession(_ value: Enrollment) -> String? {
        guard value.automatic == true, value.role == "worker", value.assistantRelay != true,
              let plugin = ProviderPluginRegistry.bundled.plugin(value.provider, requiring: .registryClosure),
              value.identityVerification == plugin.nativeHost?.identityVerification,
              let domain = value.nativeExecutionDomain,
              let parsed = NativeLifecycleRegistration(provider: value.provider,
                sessionID: value.nativeSessionID ?? value.sessionID, executionDomain: domain, registryPath: nil),
              let path = plugin.nativeHost?.registryPath(processID: parsed.processID),
              NativeLifecycleRegistration(provider: value.provider, sessionID: value.nativeSessionID ?? value.sessionID,
                executionDomain: domain, registryPath: path) != nil else { return nil }
        return value.nativeSessionID ?? value.sessionID
    }

    func testGeneratedEnrollmentSelectionMatchesPreChangeObserver() throws {
        var values: [Enrollment] = []
        for flags in 0..<256 {
            var value = enrollment(flags)
            if flags & 1 != 0 { value.automatic = false }
            if flags & 2 != 0 { value.role = "assistant" }
            if flags & 4 != 0 { value.assistantRelay = true }
            if flags & 8 != 0 { value.identityVerification = "unverified-fixture" }
            if flags & 16 != 0 { value.nativeExecutionDomain = nil }
            if flags & 32 != 0 { value.nativeExecutionDomain = "malformed-domain" }
            if flags & 64 != 0 { value.nativeSessionID = "malformed-session" }
            if flags & 128 != 0 { value.provider = "codex"; value.nativeExecutionDomain = "codex:24680:5:0" }
            values.append(value)
        }
        let expected = values.compactMap(legacyEligibleSession).sorted()
        XCTAssertFalse(expected.isEmpty)
        let trace = Trace(), coordinator = coordinator!
        coordinator.queue.sync {
            coordinator.enrollments = Dictionary(uniqueKeysWithValues: values.map { ($0.installation, $0) })
            coordinator.nativeLifecycle.inspect = { registration in
                trace.append(registration.sessionID)
                return .init(process: .running, registry: .matching, detail: "Owned generated selection fixture")
            }
            for value in values { coordinator.observeNativeConversationLifecycle(value) }
        }
        XCTAssertEqual(trace.snapshot.sorted(), expected)
    }

    func testQueuedOldEnrollmentDoesNotInspectReplacementGeneration() throws {
        let old = enrollment(0), trace = Trace(), coordinator = coordinator!
        var replacement = old
        replacement.generation = "synthetic-replacement"
        replacement.nativeExecutionDomain = "claude:28680:6:0"
        coordinator.queue.sync {
            coordinator.enrollments[old.installation] = replacement
            coordinator.nativeLifecycle.inspect = { registration in
                trace.append(registration.sessionID)
                return .init(process: .gone, registry: .absent, detail: "Must never be used")
            }
            coordinator.observeNativeConversationLifecycle(old)
        }
        XCTAssertTrue(trace.snapshot.isEmpty)
    }
}
