import XCTest
import ChecklistIPC
import ChecklistProviders
@testable import ChecklistCore
@testable import ChecklistBridges
@testable import ChecklistService

/// CL-429: real temporary stores, fake endpoints and native effects only. No
/// listener, process/registry observation, Codex store read, queue command or
/// thread open runs. Fixtures live under the test storage root and tearDown removes them.
final class SlotNativeRelayTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let instance: ChecklistInstance
        let environment: [String: String]
        var coordinator: Coordinator
        let project: String

        init(root: URL, instance: ChecklistInstance, environment: [String: String], coordinator: Coordinator, project: String) {
            self.root = root; self.instance = instance; self.environment = environment
            self.coordinator = coordinator; self.project = project
        }
    }
    private final class QueueEffects: @unchecked Sendable {
        let clock = Date()
        var threads = Set<String>()
        var reads = 0
        var preflights = 0
        var proofs = 0
        var sends: [String] = []
        var opens: [String] = []
        var occupied = false
    }
    private final class PeerEffects: NativePeerTransportEffects {
        var sessions: [String] = []
        func send(content: String, messageID: String, sender: ClaudePeerSender, endpoint: String,
                  expectedPeerPID: Int32?, expectedRegistration: NativeLifecycleRegistration?,
                  timeout: TimeInterval, providerRegistry: ProviderPluginRegistry) throws -> NativeWriteReceipt {
            sessions.append(try XCTUnwrap(expectedRegistration?.sessionID))
            return NativeWriteReceipt(status: "transport_written", byteCount: content.utf8.count,
                socketDevice: 1, socketInode: 2, peerPID: expectedPeerPID ?? 24680, recordedAt: Date())
        }
    }
    private var fixtures: [Fixture] = []
    private let owner = Caller(role: "owner", installation: "slot-relay-test-owner", projectIDs: [])

    /// The test storage root, as the other service tests use it; never a folder beside the
    /// source tree (CL-431: from the checkout that was ~/Documents/Work).
    static func storageRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["CHECKLIST_TEST_STORAGE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        }
        return FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    }
    private func fixture(slot: Int? = 1, environment: [String: String] = [:]) throws -> Fixture {
        let root = Self.storageRoot().appendingPathComponent("slot-relay-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instance = try ChecklistInstance(slotValue: slot.map { NSNumber(value: $0) }, home: root, environment: [:])
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let credentials = InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        let coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: credentials, instance: instance, environment: environment)
        let result = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
            "name": "Slot relay fixture", "key_prefix": "SR", "root_path": root.path], caller: owner)
        let project = try XCTUnwrap((result["data"] as? [String: Any])?["id"] as? String)
        let fixture = Fixture(root: root, instance: instance, environment: environment, coordinator: coordinator, project: project)
        fixtures.append(fixture)
        return fixture
    }
    override func tearDownWithError() throws {
        for fixture in fixtures {
            drain(fixture.coordinator)
            for _ in 0..<2 {
                fixture.coordinator.storageQueue.sync {}; fixture.coordinator.workHealthQueue.sync {}; fixture.coordinator.queue.sync {}
            }
            fixture.coordinator.queue.sync { fixture.coordinator.storageWake?.cancel(); fixture.coordinator.workHealthWake?.cancel() }
            try fixture.coordinator.router.closeStore()
            // Only the folder that fixture(slot:environment:) created for this test.
            try FileManager.default.removeItem(at: fixture.root)
        }
        fixtures = []
    }
    func testFixturesUseTheTestStorageRootAndNeverTheSourceTree() throws {
        // CL-433: the source root is the folder that holds Package.swift (#filePath up 3 levels).
        // The folder above it may hold the test storage root, so the test compares only with the
        // source root and with the old CL-429 folder swift-slot-relay-fixtures beside it.
        let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oldFixtures = source.deletingLastPathComponent().appendingPathComponent("swift-slot-relay-fixtures")
        let made = try fixture()
        XCTAssertTrue(made.root.path.hasPrefix(Self.storageRoot().path + "/"), made.root.path)
        XCTAssertFalse(made.root.path.hasPrefix(source.path + "/"), "No fixture in the source tree: \(made.root.path)")
        XCTAssertFalse(made.root.path.hasPrefix(oldFixtures.path + "/"), "No fixture in the old CL-429 folder: \(made.root.path)")
        let custom = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("custom-root")
        XCTAssertEqual(Self.storageRoot(environment: ["CHECKLIST_TEST_STORAGE_ROOT": custom.path]).path, custom.path)
        try tearDownWithError()
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.root.path), "tearDown leaves no fixture folder")
    }
    private func call(_ fixture: Fixture, _ method: String, _ params: [String: Any], caller: Caller? = nil) throws -> [String: Any] {
        var params = params
        if params["command_id"] == nil { params["command_id"] = UUID().uuidString }
        let result = try fixture.coordinator.router.handle(method: method, params: params, caller: caller ?? owner)
        return result["data"] as? [String: Any] ?? result
    }
    private func enrollment(_ fixture: Fixture, provider: String, marker: String? = nil) -> Enrollment {
        let session = UUID().uuidString.lowercased()
        var enrollment = Enrollment(installation: "fixture-\(session)", name: "Synthetic \(provider)", provider: provider,
            role: "worker", projectIDs: [fixture.project], sessionID: session, workspace: fixture.root.path,
            profileID: nil, tokenDigest: "synthetic", generation: UUID().uuidString)
        enrollment.automatic = true
        enrollment.identityVerification = ProviderPluginRegistry.bundled.plugin(provider, requiring: .workSession)?.nativeHost?.identityVerification
        enrollment.nativeExecutionDomain = "\(provider):24680:5:0"
        enrollment.nativeSessionID = session
        enrollment.nativeRelayRegistrationStore = marker
        if provider == "claude" {
            enrollment.nativeEndpoint = fixture.root.appendingPathComponent("fake-peer.sock").path
            enrollment.nativeDevice = 1; enrollment.nativeInode = 2
        } else { enrollment.codexAppHostProven = true }
        return enrollment
    }
    private func register(_ fixture: Fixture, _ enrollment: Enrollment) throws {
        _ = try call(fixture, "session_register", ["project_id": fixture.project, "project_ids": [fixture.project],
            "session_id": enrollment.sessionID, "installation": enrollment.installation + "/" + enrollment.generation,
            "provider": enrollment.provider, "role": enrollment.role, "workspace": fixture.root.path,
            "execution_domain": enrollment.nativeExecutionDomain!])
        fixture.coordinator.enrollments[enrollment.installation] = enrollment
        // The fake registration is never offered to a real lifecycle inspector,
        // including a dispatch invoked after the fake queue result is recorded.
        fixture.coordinator.nativeLifecycle.reconciled.insert(enrollment.installation + "/" + enrollment.generation)
    }
    private func note(_ fixture: Fixture, to enrollment: Enrollment) throws -> (id: String, message: [String: Any], before: String) {
        let message = try call(fixture, "message_send", ["project_id": fixture.project, "body": "Synthetic slot relay note",
            "recipient": ["kind": "session", "session_id": enrollment.sessionID]])
        let id = try XCTUnwrap((message["deliveries"] as? [[String: Any]])?.first?["id"] as? String)
        return (id, message, try row(fixture, id))
    }
    private func row(_ fixture: Fixture, _ id: String) throws -> String {
        try fixture.coordinator.router.dbQueue.read { db in
            let record = try fixture.coordinator.router.record(db, id, type: "delivery")
            return String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
        }
    }
    private func assertPickup(_ fixture: Fixture, _ enrollment: Enrollment, _ id: String, before: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try row(fixture, id), before, file: file, line: line)
        let caller = Caller(role: "worker", installation: enrollment.installation + "/" + enrollment.generation,
            projectIDs: [fixture.project], sessionID: enrollment.sessionID, workspace: fixture.root.path,
            executionDomain: enrollment.nativeExecutionDomain)
        let inbox = try call(fixture, "session_inbox", ["project_id": fixture.project], caller: caller)
        XCTAssertTrue((inbox["deliveries"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id }, file: file, line: line)
    }
    @discardableResult
    private func installQueue(_ fixture: Fixture, threads: Set<String>) throws -> QueueEffects {
        let fake = QueueEffects(); fake.threads = threads
        let effects = CodexQueueRouteEffects(enabled: true, readAppThreads: { _ in fake.reads += 1; return fake.threads },
            preflight: { _, _ in
                fake.preflights += 1
                let observation = CodexQueueObservation(host: .nativeApp, reason: .sourceVscode, source: "vscode")
                return fake.occupied ? .occupied(observation, count: 1) : .allowed(observation, executable: "/synthetic/codex")
            }, provesRegistration: { _ in fake.proofs += 1; return true },
            send: { content, registration, _, _ in
                fake.sends.append(registration.sessionID)
                return .init(exitStatus: 0, byteCount: content.utf8.count, itemID: "synthetic-item")
            }, followup: { _, lane, status in
                .init(openEnabled: true, item: { _ in .removed }, observe: { .init(host: .nativeApp, reason: .sourceVscode) },
                    load: { .unloaded }, status: status, now: { fake.clock.timeIntervalSince1970 },
                    schedule: { _, body in lane.async(execute: body) }, open: { thread, _ in fake.opens.append(thread); return 0 },
                    execHolder: { false })
            }, now: { fake.clock })
        let marker = fixture.root.appendingPathComponent("codex-queue-route.json")
        try JSONSerialization.data(withJSONObject: ["activated_at": ISO8601DateFormatter().string(from: fake.clock.addingTimeInterval(-60))]).write(to: marker)
        fixture.coordinator.codexRoute = CodexQueueRouteState(markerFile: marker, effects: effects, log: { _ in })
        return fake
    }
    private func warmThreads(_ fixture: Fixture) {
        let ready = expectation(description: "Fake Codex candidates cached")
        _ = fixture.coordinator.codexRoute.appThreads { ready.fulfill() }
        wait(for: [ready], timeout: 5)
    }
    private func drain(_ coordinator: Coordinator) {
        for _ in 0..<12 { coordinator.codexRoute.lane.sync {}; coordinator.queue.sync {} }
    }
    private func start(_ fixture: Fixture, _ enrollment: Enrollment, _ note: (id: String, message: [String: Any], before: String)) throws {
        let registration = try XCTUnwrap(Coordinator.codexQueueRegistration(enrollment))
        fixture.coordinator.startCodexQueueDelivery(.init(deliveryID: note.id, messageID: note.message["id"] as! String,
            enrollment: enrollment, registration: registration, origin: .agent, author: "Synthetic author", body: "Synthetic note",
            subject: nil, ticket: nil, createdAt: note.message["created_at"] as? String ?? ""))
        drain(fixture.coordinator)
    }

    func testSlotDefaultsOffBeforeEndpointProjectionQueueEffectsOrListenerFilesystemAccess() throws {
        let fixture = try fixture(), coordinator = fixture.coordinator
        // Even an enrollment with the exact local marker cannot bypass the
        // default-off switch. Legacy copied records have no marker at all.
        let claude = enrollment(fixture, provider: "claude", marker: coordinator.nativeRelayPolicy.registrationStore)
        let codex = enrollment(fixture, provider: "codex", marker: coordinator.nativeRelayPolicy.registrationStore)
        try register(fixture, claude); try register(fixture, codex)
        let claudeNote = try note(fixture, to: claude), codexNote = try note(fixture, to: codex)
        let fake = try installQueue(fixture, threads: [codex.sessionID]); fake.occupied = true
        var endpoints = 0, projections = 0
        let selected = coordinator.nativeDispatchDeliveries(endpointAvailable: { _ in endpoints += 1; return true }) { _ in
            projections += 1; return ["deliveries": [["id": "must-not-project"]]]
        }
        XCTAssertTrue(selected.isEmpty); XCTAssertEqual(endpoints, 0); XCTAssertEqual(projections, 0)
        XCTAssertNil(coordinator.codexQueueSelection())
        try start(fixture, codex, codexNote)
        XCTAssertEqual(coordinator.codexQueueFence(deliveryID: codexNote.id, enrollment: codex), .authorizationChanged)
        if case .changed = coordinator.codexQueueDeliveryStatus(id: codexNote.id, enrollment: codex) {} else { XCTFail("Disabled route must fence its followup") }
        XCTAssertEqual(fake.reads, 0); XCTAssertEqual(fake.proofs, 0); XCTAssertEqual(fake.preflights, 0)
        XCTAssertTrue(fake.sends.isEmpty); XCTAssertTrue(fake.opens.isEmpty); XCTAssertTrue(coordinator.attemptedDeliveries.isEmpty)
        let listenerDirectory = fixture.root.appendingPathComponent("listener-must-not-be-created")
        coordinator.startNativeReplies(directory: listenerDirectory.path)
        XCTAssertNil(coordinator.nativeListener); XCTAssertFalse(FileManager.default.fileExists(atPath: listenerDirectory.path))
        let info = try call(fixture, "service_info", [:])
        let listener = try XCTUnwrap(info["native_reply_listener"] as? [String: Any])
        XCTAssertEqual(listener["state"] as? String, "disabled"); XCTAssertEqual(listener["slot_relays"] as? String, "off")
        XCTAssertEqual(listener["codex_queue_relay"] as? String, "off")
        XCTAssertTrue((listener["message"] as? String ?? "").contains("off in test slot 1"))
        try assertPickup(fixture, claude, claudeNote.id, before: claudeNote.before)
        try assertPickup(fixture, codex, codexNote.id, before: codexNote.before)
    }

    func testOnlyExactSyntheticSettingEnablesASlot() throws {
        for value in ["", "1", "true", "SYNTHETIC", "all"] {
            let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": value])
            XCTAssertFalse(fixture.coordinator.nativeRelayPolicy.enabled, value)
        }
        XCTAssertTrue(try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"]).coordinator.nativeRelayPolicy.enabled)
    }

    func testSyntheticModeProjectsOnlyLocalRegistrationsOnBothRoutes() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"]), coordinator = fixture.coordinator
        let marker = try XCTUnwrap(coordinator.nativeRelayPolicy.registrationStore)
        var locals: [Enrollment] = [], copied: [Enrollment] = []
        for provider in ["claude", "codex"] {
            let local = enrollment(fixture, provider: provider, marker: marker)
            let legacy = enrollment(fixture, provider: provider)
            let foreign = enrollment(fixture, provider: provider, marker: "another-slot-store")
            locals.append(local); copied += [legacy, foreign]
            for enrollment in [local, legacy, foreign] { try register(fixture, enrollment) }
        }
        let fake = try installQueue(fixture, threads: Set((locals + copied).filter { $0.provider == "codex" }.map(\.sessionID)))
        warmThreads(fixture)
        var endpointSessions = Set<String>(), selectedSessions = Set<String>()
        let rows = coordinator.nativeDispatchDeliveries(endpointAvailable: { enrollment in
            endpointSessions.insert(enrollment.sessionID); return true
        }) { params in
            let ids = params["native_session_ids"] as? [String] ?? []
            selectedSessions.formUnion(ids)
            return ["deliveries": ids.map { ["id": $0] }]
        }
        XCTAssertEqual(endpointSessions, Set(locals.filter { $0.provider == "claude" }.map(\.sessionID)))
        XCTAssertEqual(selectedSessions, Set(locals.map(\.sessionID))); XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(fake.preflights, 0); XCTAssertTrue(fake.sends.isEmpty); XCTAssertTrue(fake.opens.isEmpty)
        let peer = PeerEffects()
        for enrollment in (locals + copied).filter({ $0.provider == "claude" }) {
            guard selectedSessions.contains(enrollment.sessionID), coordinator.nativeRelayPolicy.allows(enrollment) else { continue }
            let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "claude", sessionID: enrollment.sessionID,
                executionDomain: enrollment.nativeExecutionDomain!, registryPath: fixture.root.appendingPathComponent("fake-registry.json").path))
            _ = try NativeProviderTransport.send(provider: "claude", content: "Synthetic local-slot note", messageID: UUID().uuidString,
                replyAddress: "uds:" + fixture.root.appendingPathComponent("fake-reply.sock").path, displayName: "Checklist",
                endpoint: enrollment.nativeEndpoint!, expectedPeerPID: 24680, expectedRegistration: registration, effects: peer)
        }
        XCTAssertEqual(peer.sessions, locals.filter { $0.provider == "claude" }.map(\.sessionID))
        // This exercises policy-gated candidate selection and an explicitly
        // injected peer transport; it is not the whole service's socket send.
        for enrollment in copied {
            XCTAssertFalse(coordinator.nativeRelayPolicy.allows(enrollment))
            let note = try note(fixture, to: enrollment)
            if enrollment.provider == "codex" { try start(fixture, enrollment, note) }
            try assertPickup(fixture, enrollment, note.id, before: note.before)
        }
        XCTAssertEqual(fake.preflights, 0); XCTAssertTrue(fake.sends.isEmpty); XCTAssertTrue(fake.opens.isEmpty)
    }

    func testSyntheticLocalCodexCanUseFakeQueueAndFakeThreadOpen() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"])
        let codex = enrollment(fixture, provider: "codex", marker: fixture.coordinator.nativeRelayPolicy.registrationStore)
        try register(fixture, codex)
        let fake = try installQueue(fixture, threads: [codex.sessionID])
        let first = try note(fixture, to: codex)
        try start(fixture, codex, first)
        XCTAssertEqual(fake.sends, [codex.sessionID])
        // The occupied route opens through the same injected effect, without a
        // second queue call. No native command or URL is ever executed.
        fake.occupied = true
        let waiting = try note(fixture, to: codex)
        try start(fixture, codex, waiting)
        XCTAssertEqual(fake.sends, [codex.sessionID]); XCTAssertEqual(fake.opens, [codex.sessionID])
    }

    func testLivePolicyDemonstratesCopiedClaudeAndCodexRoutesRemainSelectable() throws {
        let fixture = try fixture(slot: nil), coordinator = fixture.coordinator
        let claude = enrollment(fixture, provider: "claude"), codex = enrollment(fixture, provider: "codex")
        try register(fixture, claude); try register(fixture, codex)
        let codexNote = try note(fixture, to: codex)
        let fake = try installQueue(fixture, threads: [codex.sessionID]); warmThreads(fixture)
        var selected = Set<String>()
        _ = coordinator.nativeDispatchDeliveries(endpointAvailable: { _ in true }) { params in
            selected.formUnion(params["native_session_ids"] as? [String] ?? []); return ["deliveries": []]
        }
        XCTAssertEqual(selected, [claude.sessionID, codex.sessionID])
        try start(fixture, codex, codexNote)
        XCTAssertEqual(fake.sends, [codex.sessionID])
        let peer = PeerEffects()
        let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "claude", sessionID: claude.sessionID,
            executionDomain: claude.nativeExecutionDomain!, registryPath: fixture.root.appendingPathComponent("fake-registry.json").path))
        let receipt = try NativeProviderTransport.send(provider: "claude", content: "Synthetic copied-store note", messageID: UUID().uuidString,
            replyAddress: "uds:" + fixture.root.appendingPathComponent("fake-reply.sock").path, displayName: "Checklist",
            endpoint: claude.nativeEndpoint!, expectedPeerPID: 24680, expectedRegistration: registration, effects: peer)
        XCTAssertEqual(peer.sessions, [claude.sessionID]); XCTAssertEqual(receipt.status, "transport_written")
        // Candidate selection plus the explicit fake transport proves that
        // bridge dispatch has no hidden instance/store check. It does not
        // qualify real socket ownership, process, registry or signing checks.
    }

    func testMarkerBindsSlotCanonicalEnrollmentFolderAndStoreIncarnation() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"])
        let marker = try XCTUnwrap(fixture.coordinator.nativeRelayPolicy.registrationStore)
        let local = enrollment(fixture, provider: "claude", marker: marker)
        let environment = ["CHECKLIST_SLOT_RELAYS": "synthetic"]
        let incarnation = fixture.coordinator.router.storeIncarnation
        let same = SlotNativeRelayPolicy(instance: fixture.instance, storeRoot: fixture.root.appendingPathComponent("."), incarnation: incarnation, environment: environment)
        XCTAssertTrue(same.allows(local))
        let otherRoot = SlotNativeRelayPolicy(instance: fixture.instance, storeRoot: fixture.root.appendingPathComponent("copied"), incarnation: incarnation, environment: environment)
        let otherStore = SlotNativeRelayPolicy(instance: fixture.instance, storeRoot: fixture.root, incarnation: "new-store-incarnation", environment: environment)
        let secondSlot = try ChecklistInstance(slotValue: NSNumber(value: 2), home: fixture.root, environment: [:])
        let otherSlot = SlotNativeRelayPolicy(instance: secondSlot, storeRoot: fixture.root, incarnation: incarnation, environment: environment)
        XCTAssertFalse(otherRoot.allows(local)); XCTAssertFalse(otherStore.allows(local)); XCTAssertFalse(otherSlot.allows(local))
    }

    func testFreshBootstrapStampsProvenanceAndExistingBootstrapNeverUpgradesCopiedRecords() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"]), coordinator = fixture.coordinator
        try installQueue(fixture, threads: [])
        let native = Coordinator.VerifiedNativeWorkspace(provider: "codex", session: UUID().uuidString.lowercased(), process: getpid(),
            executionDomain: "codex:24680:5:0", workspace: fixture.root.path)
        let fresh = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read)
        XCTAssertTrue(fresh.changed)
        let installation = try XCTUnwrap((fresh.reply["data"] as? [String: Any])?["installation"] as? String)
        let registered = try XCTUnwrap(coordinator.enrollments[installation])
        XCTAssertEqual(registered.nativeRelayRegistrationStore, coordinator.nativeRelayPolicy.registrationStore)
        XCTAssertTrue(coordinator.nativeRelayPolicy.allows(registered))
        for marker: String? in [nil, "copied-live-or-other-slot-marker"] {
            coordinator.enrollments[installation]?.nativeRelayRegistrationStore = marker
            try coordinator.saveEnrollments()
            let reconnect = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read)
            XCTAssertFalse(reconnect.changed)
            let existing = try XCTUnwrap(coordinator.enrollments[installation])
            XCTAssertEqual(existing.nativeRelayRegistrationStore, marker)
            XCTAssertFalse(coordinator.nativeRelayPolicy.allows(existing))
        }
    }

    func testOwnerAllowedReconnectRotatesGenerationWithoutChangingRegistrationOrigin() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"]), coordinator = fixture.coordinator
        try installQueue(fixture, threads: [])
        let native = Coordinator.VerifiedNativeWorkspace(provider: "codex", session: UUID().uuidString.lowercased(), process: getpid(),
            executionDomain: "codex:24680:5:0", workspace: fixture.root.path)
        let fresh = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read)
        let installation = try XCTUnwrap((fresh.reply["data"] as? [String: Any])?["installation"] as? String)
        let localMarker = try XCTUnwrap(coordinator.nativeRelayPolicy.registrationStore)
        for marker: String? in [nil, "copied-live-or-other-slot-marker", localMarker] {
            let earlier = try XCTUnwrap(coordinator.enrollments[installation])
            coordinator.enrollments[installation]?.nativeRelayRegistrationStore = marker
            try coordinator.saveEnrollments()
            let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: native.session, project: fixture.project, caller: owner))
            let boundInstallation = try XCTUnwrap(session["installation"])
            for method in ["connection_revoke", "connection_allow"] {
                let current = try XCTUnwrap(coordinator.router.connectionSession(sessionID: native.session, project: fixture.project, caller: owner))
                _ = try call(fixture, method, ["project_id": fixture.project, "session_id": native.session,
                    "installation": boundInstallation, "expected_revision": current["revision"]!])
            }
            let reconnect = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read)
            XCTAssertTrue(reconnect.changed)
            let resumed = try XCTUnwrap(coordinator.enrollments[installation])
            XCTAssertNotEqual(resumed.generation, earlier.generation)
            XCTAssertEqual(resumed.nativeRelayRegistrationStore, marker)
            XCTAssertEqual(coordinator.nativeRelayPolicy.allows(resumed), marker == localMarker)
        }
    }

    func testEnrollmentProvenanceSurvivesCodableAndCoordinatorRestart() throws {
        let fixture = try fixture(environment: ["CHECKLIST_SLOT_RELAYS": "synthetic"])
        let local = enrollment(fixture, provider: "codex", marker: fixture.coordinator.nativeRelayPolicy.registrationStore)
        let copied = enrollment(fixture, provider: "claude")
        try register(fixture, local); try register(fixture, copied)
        let encoded = try JSONEncoder().encode(local)
        XCTAssertEqual(try JSONDecoder().decode(Enrollment.self, from: encoded).nativeRelayRegistrationStore, local.nativeRelayRegistrationStore)
        try fixture.coordinator.saveEnrollments()
        let previousMarker = fixture.coordinator.nativeRelayPolicy.registrationStore
        drain(fixture.coordinator)
        try fixture.coordinator.router.closeStore()
        let router = try CommandRouter(root: fixture.root.appendingPathComponent("store"))
        fixture.coordinator = Coordinator(router: router, enrollmentFile: fixture.root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: InstallationCredentialStore(root: fixture.root, instance: fixture.instance, legacyRead: nil),
            instance: fixture.instance, environment: fixture.environment)
        XCTAssertEqual(fixture.coordinator.nativeRelayPolicy.registrationStore, previousMarker)
        let restored = try XCTUnwrap(fixture.coordinator.enrollments[local.installation])
        XCTAssertEqual(restored.nativeRelayRegistrationStore, local.nativeRelayRegistrationStore)
        XCTAssertTrue(fixture.coordinator.nativeRelayPolicy.allows(restored))
        XCTAssertNil(fixture.coordinator.enrollments[copied.installation]?.nativeRelayRegistrationStore)
        XCTAssertFalse(fixture.coordinator.nativeRelayPolicy.allows(try XCTUnwrap(fixture.coordinator.enrollments[copied.installation])))
    }
}
