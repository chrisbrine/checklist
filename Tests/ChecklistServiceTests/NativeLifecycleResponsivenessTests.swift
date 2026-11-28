import XCTest
import Foundation
import CryptoKit
import Darwin
import GRDB
import ChecklistIPC
import ChecklistProviders
import ChecklistBridges
@testable import ChecklistCore
@testable import ChecklistService

/// Real coordinator admission, closure, bootstrap and receipt creation on owned
/// stores. Only native OS evidence is fake; no host app or native registry runs.
final class NativeLifecycleResponsivenessTests: XCTestCase {
    private typealias JSON = [String: Any]
    private let owner = Caller(role: "owner", installation: "lifecycle-responsiveness-owner", projectIDs: [])

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let coordinator: Coordinator
        let project: String
        let readTask: String
        let enrollments: [Enrollment]
        let attempts: [String]
        let notesPerSession: Int
        let reader: Enrollment
        init(root: URL, coordinator: Coordinator, project: String, readTask: String,
             enrollments: [Enrollment], attempts: [String], notesPerSession: Int, reader: Enrollment) {
            self.root = root; self.coordinator = coordinator; self.project = project; self.readTask = readTask
            self.enrollments = enrollments; self.attempts = attempts; self.notesPerSession = notesPerSession; self.reader = reader
        }
    }

    private struct ReadSample: Sendable {
        let queueMS: Double
        let lifecycleMS: Double
        let totalMS: Double
        let error: String?
    }

    private final class WorkloadResults: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [(String, Double)] = []
        private var errors: [String] = []
        private var turns: [(Double, [String: Double])] = []
        func phase(_ name: String, _ milliseconds: Double) { lock.withLock { phases.append((name, milliseconds)) } }
        func failed(_ error: Error) { lock.withLock { errors.append(String(describing: error)) } }
        func turn(_ milliseconds: Double, _ activities: [String: Double]) { lock.withLock { turns.append((milliseconds, activities)) } }
        func snapshot() -> (phases: [(String, Double)], errors: [String]) { lock.withLock { (phases, errors) } }
        func turnSnapshot() -> [(Double, [String: Double])] { lock.withLock { turns } }
    }

    /// Timer submission is independent of the command queue. Each submission
    /// reaches that same queue before doing the production pooled task_get read.
    private final class ReadProbe: @unchecked Sendable {
        private let fixture: Fixture
        private let timerQueue = DispatchQueue(label: "org.checklist.lifecycle-test-reader")
        private let pending = DispatchGroup()
        private let first = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var samples: [ReadSample] = []
        private var timer: DispatchSourceTimer?
        init(_ fixture: Fixture) { self.fixture = fixture }
        func start() throws {
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(1))
            timer.setEventHandler { [self] in submit() }
            self.timer = timer; timer.resume()
            guard first.wait(timeout: .now() + 10) == .success else {
                throw NSError(domain: "NativeLifecycleReadProbe", code: 1)
            }
        }
        // Guarantee the small case includes a request behind lifecycle work,
        // even when that work finishes before the next 250 ms timer firing.
        func boundaryRead() { timerQueue.async { [self] in submit() } }
        private func submit() {
            let submitted = ProcessInfo.processInfo.systemUptime
            pending.enter()
            let bootstrap: @Sendable (Bool) throws -> Coordinator.BootstrapResult = { [self] currentConnectionOnly in
                let e = fixture.reader
                return try fixture.coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: e.provider,
                    session: e.sessionID, process: 29680, executionDomain: e.nativeExecutionDomain!, workspace: fixture.root.path),
                    readCredential: fixture.coordinator.credentials.read, currentConnectionOnly: currentConnectionOnly)
            }
            let read: @Sendable (Result<Coordinator.BootstrapResult, Error>, TimeInterval) -> Void = { [self] result, dequeued in
                var bootstrapFailure: String?
                do {
                    if try result.get().changed { bootstrapFailure = "Current reader bootstrap changed authority" }
                } catch { bootstrapFailure = String(describing: error) }
                fixture.coordinator.observeNativeConversationLifecycles()
                let observed = ProcessInfo.processInfo.systemUptime
                let checkedFailure = bootstrapFailure
                DispatchQueue.global(qos: .userInitiated).async { [self] in autoreleasepool {
                    var failure = checkedFailure
                    do {
                        let reply = try fixture.coordinator.router.handle(method: "task_get",
                            params: ["project_id": fixture.project, "task_id": fixture.readTask],
                            caller: Caller(role: "worker", installation: fixture.reader.installation + "/" + fixture.reader.generation,
                                projectIDs: [fixture.project], sessionID: fixture.reader.sessionID, workspace: fixture.root.path,
                                executionDomain: fixture.reader.nativeExecutionDomain))
                        if (reply["data"] as? [String: Any])?["id"] as? String != fixture.readTask {
                            failure = "task_get did not return the selected task"
                        }
                    } catch { failure = String(describing: error) }
                    let sample = ReadSample(queueMS: (dequeued - submitted) * 1000,
                        lifecycleMS: (observed - dequeued) * 1000,
                        totalMS: (ProcessInfo.processInfo.systemUptime - submitted) * 1000, error: failure)
                    lock.withLock { samples.append(sample) }
                    first.signal(); pending.leave()
                }}
            }
            fixture.coordinator.queue.async { [self] in
                let dequeued = ProcessInfo.processInfo.systemUptime
                do {
                    guard let current = try fixture.coordinator.attemptCurrentNativeBootstrap({ try bootstrap(true) }, retry: {
                        let began = ProcessInfo.processInfo.systemUptime
                        read(Result { try bootstrap(false) }, began)
                    }) else { return }
                    read(.success(current), dequeued)
                } catch { read(.failure(error), dequeued) }
            }
        }

        func stop() throws -> [ReadSample] {
            timer?.cancel(); timerQueue.sync {}; timer = nil
            guard pending.wait(timeout: .now() + 1800) == .success else {
                throw NSError(domain: "NativeLifecycleReadProbe", code: 2)
            }
            return lock.withLock { samples }
        }
    }

    private func call(_ router: CommandRouter, _ method: String, _ params: JSON, caller: Caller? = nil) throws -> JSON {
        var params = params
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = UUID().uuidString.lowercased() }
        return try XCTUnwrap(router.handle(method: method, params: params, caller: caller ?? owner)["data"] as? JSON)
    }

    private func fixture(claudeCount: Int, notes: Int, deliveries: Int, fillerBytes: Int) throws -> Fixture {
        let qualification = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification").resolvingSymlinksInPath()
        let parent: URL
        if let path = ProcessInfo.processInfo.environment["CHECKLIST_LIFECYCLE_FIXTURE_ROOT"] {
            let selected = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard path.hasPrefix("/"), selected.path.hasPrefix(qualification.path + "/") else {
                throw XCTSkip("Use an isolated lifecycle fixture directory under Library/Caches/ChecklistQualification.")
            }
            parent = selected
        } else {
            parent = qualification.appendingPathComponent("r12-N2/test-fixtures")
        }
        let root = parent.appendingPathComponent("native-lifecycle-response-" + UUID().uuidString).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instance = try ChecklistInstance(home: root, environment: [:])
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let credentials = InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        let coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: credentials, instance: instance)
        coordinator.nativeLifecycle.watchesEnabled = false
        coordinator.nativeLifecycle.inspect = { _ in .init(process: .running, registry: .matching, detail: "Owned synthetic evidence") }
        let project = try call(router, "project_create", ["name": "Lifecycle responsiveness fixture", "key_prefix": "LR", "root_path": root.path])["id"] as! String
        let epic = try call(router, "epic_create", ["project_id": project, "name": "Synthetic restart"])["id"] as! String
        var enrollments: [Enrollment] = [], attempts: [String] = [], prototypes: [(JSON, Enrollment)] = []
        var readTask = ""
        for index in 0...claudeCount {
            let provider = index == claudeCount ? "codex" : "claude"
            let sid = UUID().uuidString.lowercased()
            let identity = SHA256.hash(data: Data("\(provider)|\(sid)|\(project)".utf8)).map { String(format: "%02x", $0) }.joined()
            let token = "synthetic-lifecycle-token-\(index)"
            var enrollment = Enrollment(installation: "auto-\(provider)-" + identity.prefix(40), name: "Synthetic restart \(index)",
                provider: provider, role: "worker", projectIDs: [project], sessionID: sid, workspace: root.path,
                profileID: nil, tokenDigest: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "before-restart")
            enrollment.automatic = true; enrollment.nativeSessionID = sid
            enrollment.nativeExecutionDomain = "\(provider):\(24680 + index):5:0"
            enrollment.identityVerification = ProviderPluginRegistry.bundled.plugin(provider, requiring: .workSession)?.nativeHost?.identityVerification
            enrollment.codexAppHostProven = provider == "codex" ? true : nil
            _ = try call(router, "session_register", ["project_id": project, "project_ids": [project], "session_id": sid,
                "installation": enrollment.installation + "/" + enrollment.generation, "provider": provider, "role": "worker",
                "workspace": root.path, "execution_domain": enrollment.nativeExecutionDomain!])
            coordinator.enrollments[enrollment.installation] = enrollment
            try credentials.write(enrollment.installation, token)
            var task = try call(router, "task_create", ["project_id": project, "epic_id": epic,
                "title": "Synthetic closure \(index)", "brief": "Owned fixture"])
            task = try call(router, "task_edit", ["project_id": project, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
            let worker = Caller(role: "worker", installation: enrollment.installation + "/" + enrollment.generation,
                projectIDs: [project], sessionID: sid, workspace: root.path, executionDomain: enrollment.nativeExecutionDomain)
            let attempt = try call(router, "work_claim", ["project_id": project, "task_id": task["id"]!,
                "expected_revision": task["revision"]!, "file_scopes": [["path": "Sources/fixture-\(index)", "access": "write"]]], caller: worker)
            attempts.append(attempt["id"] as! String)
            if readTask.isEmpty { readTask = task["id"] as! String }
            let note = try call(router, "message_send", ["project_id": project, "task_id": task["id"]!, "body": "Unacknowledged synthetic restart note 0"])
            let message = try router.dbQueue.read { try router.record($0, note["id"] as! String, type: "message") }
            prototypes.append((message, enrollment)); enrollments.append(enrollment)
        }
        // An unrelated enrolled conversation stays current throughout the burst.
        let sid = UUID().uuidString.lowercased(), token = "synthetic-current-reader"
        let identity = SHA256.hash(data: Data("claude|\(sid)|\(project)".utf8)).map { String(format: "%02x", $0) }.joined()
        var reader = Enrollment(installation: "auto-claude-" + identity.prefix(40), name: "Current read connection", provider: "claude",
            role: "worker", projectIDs: [project], sessionID: sid, workspace: root.path, profileID: nil,
            tokenDigest: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "reader-generation")
        reader.automatic = true; reader.nativeSessionID = sid; reader.nativeExecutionDomain = "claude:29680:6:0"
        reader.identityVerification = ProviderPluginRegistry.bundled.plugin("claude", requiring: .workSession)?.nativeHost?.identityVerification
        _ = try call(router, "session_register", ["project_id": project, "project_ids": [project], "session_id": sid,
            "installation": reader.installation + "/" + reader.generation, "provider": "claude", "role": "worker",
            "workspace": root.path, "execution_domain": reader.nativeExecutionDomain!])
        coordinator.enrollments[reader.installation] = reader
        try credentials.write(reader.installation, token)
        try coordinator.saveEnrollments()
        // Setup uses the real receipt function; this is outside the measured interval.
        try router.dbQueue.write { db in
            for (prototype, enrollment) in prototypes {
                for ordinal in 1..<notes {
                    var message = prototype
                    message["id"] = UUID().uuidString.lowercased()
                    message["body"] = "Unacknowledged synthetic restart note \(ordinal)"
                    try router.save(db, message, type: "message")
                    _ = try router.queueDirectionDeliveries(db, message: message, recipients: [["session_id": enrollment.sessionID, "recipient_role": "handler"]])
                }
            }
            let have = try Int.fetchOne(db, sql: "SELECT count(*) FROM records WHERE type='delivery'") ?? 0
            var prototype = prototypes[0].0
            prototype["id"] = UUID().uuidString.lowercased()
            prototype["body"] = "Unrelated synthetic delivery history"
            try router.save(db, prototype, type: "message")
            // Same-project unrelated history makes the original delivery lookups
            // scan the same record family as the incident's large project.
            for ordinal in have..<max(have, deliveries) {
                let filler: JSON = ["id": UUID().uuidString.lowercased(), "project_id": project,
                    "message_id": prototype["id"]!, "recipient_session_id": "unrelated-synthetic-history",
                    "recipient_authorization_generation": "historical-\(ordinal)", "recipient_role": "handler",
                    "state": "acknowledged", "push_state": "unavailable", "revision": 1,
                    "created_at": prototype["created_at"]!, "push_reason": String(repeating: "f", count: fillerBytes)]
                try router.save(db, filler, type: "delivery")
            }
        }
        let host = CodexProcess(pid: 28680, executable: "/Applications/Synthetic.app/Contents/MacOS/codex", role: .appHost)
        coordinator.codexAppHostRestartEffects = .init(available: true, process: { registration in
            registration.startSeconds == 5 ? .gone : .running
        }, source: { _ in .init(host: .nativeApp, reason: .sourceVscode, source: "vscode") }, scan: { _ in
            .init(hosts: [host], holders: [host], unreadable: false, execClaim: false, incompleteNonCodex: 0, blockers: [])
        }, signed: { _ in true }, holds: { _ in true }, pauseBeforeRetry: {})
        return Fixture(root: root, coordinator: coordinator, project: project, readTask: readTask,
            enrollments: enrollments, attempts: attempts, notesPerSession: notes, reader: reader)
    }

    private func retire(_ fixture: Fixture) throws {
        let coordinator = fixture.coordinator
        for _ in 0..<2 {
            coordinator.storageQueue.sync {}; coordinator.workHealthQueue.sync {}
            coordinator.nativeLifecycle.closureQueue.sync {}; coordinator.queue.sync {}
        }
        coordinator.queue.sync {
            coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel()
            coordinator.queue.didCompletePeriod = nil
        }
        coordinator.queue.busyPeriods.flush()
        try coordinator.router.closeStore()
        if ProcessInfo.processInfo.environment["CHECKLIST_LIFECYCLE_KEEP_FIXTURE"] == "1" {
            print("CL-462 retained_fixture=\(fixture.root.path)")
        } else {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fixture.root, to: trash.appendingPathComponent(fixture.root.lastPathComponent))
        }
    }

    private func run(claudeCount: Int, notes: Int, deliveryCount: Int) throws {
        let environment = ProcessInfo.processInfo.environment
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let fixture = try fixture(claudeCount: claudeCount, notes: notes, deliveries: deliveryCount,
            fillerBytes: Int(environment["CHECKLIST_LIFECYCLE_FILLER_BYTES"] ?? "800") ?? 800)
        defer {
            do { try retire(fixture) }
            catch { XCTFail("Owned lifecycle fixture cleanup failed: \(error)") }
        }
        let coordinator = fixture.coordinator, router = coordinator.router
        let hooks = environment["CHECKLIST_LIFECYCLE_HOOKS"] == "1"
        let connection = NSXPCConnection(machServiceName: "org.checklist.synthetic.lifecycle-probe")
        defer { connection.invalidate() }
        let peer = Peer(coordinator: coordinator, connection: connection)
        let counts = try router.dbQueue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM records WHERE type='delivery'") ?? 0,
             try Int.fetchOne(db, sql: "SELECT sum(length(CAST(data AS BLOB))) FROM records WHERE type='delivery'") ?? 0)
        }
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        print("CL-462 start=\(ISO8601DateFormatter().string(from: Date())) claude=\(claudeCount) codex=1 notes_per_session=\(notes) deliveries=\(counts.0) delivery_json_bytes=\(counts.1) setup_seconds=\(ProcessInfo.processInfo.systemUptime - setupStarted) after_command_hooks=\(hooks) load=\(load)")
        let probe = ReadProbe(fixture)
        let results = WorkloadResults()
        coordinator.queue.sync {
            coordinator.queue.didCompletePeriod = { _, milliseconds, activities in results.turn(milliseconds, activities) }
        }
        defer { _ = try? probe.stop() }
        try probe.start()
        coordinator.queue.sync {
            coordinator.nativeLifecycle.inspect = { registration in
                .init(process: registration.startSeconds == 5 ? .gone : .running,
                    registry: registration.startSeconds == 5 ? .absent : .matching, detail: "Owned synthetic closure evidence")
            }
            let began = ProcessInfo.processInfo.systemUptime
            probe.boundaryRead()
            coordinator.observeNativeConversationLifecycles()
            results.phase("claude_event_observer_schedule_1", (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
        // Fifteen process exits and fifteen registry notifications each called
        // the original observer. Keep the same event burst before and after a fix.
        let events = DispatchGroup()
        for event in 2...30 {
            events.enter()
            coordinator.queue.async {
                let began = ProcessInfo.processInfo.systemUptime
                coordinator.observeNativeConversationLifecycles()
                results.phase("claude_event_observer_schedule_\(event)", (ProcessInfo.processInfo.systemUptime - began) * 1000)
                events.leave()
            }
        }
        let bootstraps = DispatchGroup()
        for enrollment in fixture.enrollments {
            bootstraps.enter()
            coordinator.queue.async {
                coordinator.enqueueNativeConnectionRequest {
                let began = ProcessInfo.processInfo.systemUptime
                probe.boundaryRead()
                let complete: @Sendable (Result<Coordinator.BootstrapResult, Error>) -> Void = { outcome in
                    defer {
                        results.phase(enrollment.provider == "codex" ? "codex_restart_closure_and_resume" : "claude_resume", (ProcessInfo.processInfo.systemUptime - began) * 1000)
                        bootstraps.leave()
                    }
                    do {
                        let result = try outcome.get()
                        if !result.changed { throw NSError(domain: "NativeLifecycleBootstrapUnchanged", code: 1) }
                        if hooks { peer.finish(result.reply, runHooks: true, method: "connection_bootstrap") { _ in } }
                    } catch { results.failed(error) }
                }
                do {
                    let process: Int32 = enrollment.provider == "codex" ? 28680 : 28681
                    let result = try coordinator.withDeferredNativeResumption {
                        try coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: enrollment.provider,
                            session: enrollment.sessionID, process: process, executionDomain: "\(enrollment.provider):\(process):6:0",
                            workspace: fixture.root.path), readCredential: coordinator.credentials.read)
                    }
                    complete(.success(result))
                } catch let continuation as NativeBootstrapContinuation {
                    coordinator.startNativeBootstrapContinuation(continuation, completion: complete)
                } catch { complete(.failure(error)) }
                }
            }
        }
        XCTAssertEqual(events.wait(timeout: .now() + 1800), .success)
        XCTAssertEqual(bootstraps.wait(timeout: .now() + 1800), .success)
        // The final continuation can enqueue after-command writes before its
        // reply completes. Keep the independent reader active through those
        // same production writer gates, including the optional hook workload.
        let writesFinished = DispatchSemaphore(value: 0)
        coordinator.queue.async {
            coordinator.performNativeLifecycleWrite { writesFinished.signal() }
        }
        XCTAssertEqual(writesFinished.wait(timeout: .now() + 1800), .success)
        let samples = try probe.stop()
        let (phases, errors) = results.snapshot()
        let turns = results.turnSnapshot()
        let longest = samples.map(\.totalMS).max() ?? .infinity
        let queueWait = samples.map(\.queueMS).max() ?? .infinity
        for (phase, milliseconds) in phases { print("CL-462 phase=\(phase) phase_elapsed_ms=\(milliseconds)") }
        print("CL-462 queue_turns=\(turns.count) longest_actual_queue_busy_ms=\(turns.map(\.0).max() ?? 0)")
        for activity in ["native_lifecycle_observation", "native_closure_reconciliation", "native_connection_request", "native_resumption_transaction", "native_deferred_write"] {
            let periods = turns.compactMap { $0.1[activity] }
            print("CL-462 queue_activity=\(activity) count=\(periods.count) longest_ms=\(periods.max() ?? 0) sum_ms=\(periods.reduce(0, +))")
        }
        print("CL-462 reads=\(samples.count) fresh_bootstrap=true cadence_ms=250 lifecycle_events=30 boundary_reads=\(fixture.enrollments.count + 1) longest_read_ms=\(longest) longest_queue_wait_ms=\(queueWait) longest_read_lifecycle_ms=\(samples.map(\.lifecycleMS).max() ?? 0) read_errors=\(samples.compactMap(\.error))")
        XCTAssertTrue(errors.isEmpty, "Bootstrap failures: \(errors)")
        try router.dbQueue.read { db in
            for (index, old) in fixture.enrollments.enumerated() {
                let session = try router.record(db, old.sessionID, type: "session")
                XCTAssertEqual(session["state"] as? String, "connected")
                XCTAssertNotEqual(session["installation"] as? String, old.installation + "/" + old.generation)
                let attempt = try router.record(db, fixture.attempts[index], type: "attempt")
                XCTAssertEqual(attempt["state"] as? String, "released"); XCTAssertNil(attempt["token_hash"])
                let newCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.recipient_session_id')=? AND json_extract(data,'$.recipient_authorization_generation')=?",
                    arguments: [fixture.project, old.sessionID, router.sessionGeneration(session)])
                XCTAssertEqual(newCount, fixture.notesPerSession)
                let receipts = try Row.fetchAll(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.recipient_session_id')=? ORDER BY rowid", arguments: [fixture.project, old.sessionID])
                    .map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "delivery").object }
                let ended = receipts.filter { $0["recipient_authorization_generation"] as? String != router.sessionGeneration(session) }
                let fresh = receipts.filter { $0["recipient_authorization_generation"] as? String == router.sessionGeneration(session) }
                XCTAssertEqual(ended.count, fixture.notesPerSession)
                for receipt in ended {
                    XCTAssertFalse(try router.deliveryCurrent(db, receipt)); XCTAssertNil(receipt["acknowledged_at"])
                    let projection = try router.deliveryReceiptProjection(db, receipt)
                    XCTAssertEqual(projection["state"] as? String, "fenced")
                    XCTAssertNotNil(projection["native_closure_ref"])
                }
                for receipt in fresh {
                    XCTAssertTrue(try router.deliveryCurrent(db, receipt)); XCTAssertNil(receipt["acknowledged_at"])
                    XCTAssertNotNil(receipt["resumed_from_delivery_id"])
                    XCTAssertNotNil(receipt["resumed_native_closure_ref"])
                }
            }
        }
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.compactMap(\.error).isEmpty)
        XCTAssertLessThan(longest, 1000, "A native restart must leave read admission responsive")
    }

    func testSmallRestartKeepsReadsResponsiveAndPreservesReceipts() throws {
        try run(claudeCount: 2, notes: 3, deliveryCount: 100)
    }

    func testFencedPendingClosureReconcilesAgainBeforeResumingAfterWriterStops() throws {
        let fixture = try fixture(claudeCount: 1, notes: 1, deliveries: 3, fillerBytes: 10)
        defer {
            do { try retire(fixture) }
            catch { XCTFail("Owned pending-closure fixture cleanup failed: \(error)") }
        }
        let coordinator = fixture.coordinator, router = coordinator.router
        let enrollment = fixture.enrollments[0], execution = UUID().uuidString.lowercased()
        try router.dbQueue.write { db in
            try router.save(db, ["id": execution, "project_id": fixture.project, "task_id": fixture.readTask,
                "attempt_id": fixture.attempts[0], "state": "interrupted", "revision": 1], type: "source_execution")
        }
        coordinator.queue.sync {
            coordinator.nativeLifecycle.inspect = { _ in
                .init(process: .gone, registry: .absent, detail: "Owned stopped host fixture")
            }
            coordinator.observeNativeConversationLifecycle(enrollment)
            XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        }
        func bootstrap() throws -> Coordinator.BootstrapResult {
            try coordinator.queue.sync {
                try coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: "claude", session: enrollment.sessionID,
                    process: 28681, executionDomain: "claude:28681:6:0", workspace: fixture.root.path),
                    readCredential: coordinator.credentials.read)
            }
        }
        XCTAssertThrowsError(try bootstrap()) { error in
            XCTAssertEqual((error as? CoreError)?.code, "NATIVE_CLOSURE_PENDING")
        }
        try router.dbQueue.write { db in
            var record = try router.record(db, execution, type: "source_execution")
            record["state"] = "stopped"
            try router.save(db, router.revised(record), type: "source_execution")
        }
        XCTAssertTrue(try bootstrap().changed)
        try router.dbQueue.read { db in
            let attempt = try router.record(db, fixture.attempts[0], type: "attempt")
            XCTAssertEqual(attempt["state"] as? String, "released"); XCTAssertNil(attempt["token_hash"])
            let session = try router.record(db, enrollment.sessionID, type: "session")
            XCTAssertEqual(session["state"] as? String, "connected")
            XCTAssertNotEqual(session["installation"] as? String, enrollment.installation + "/" + enrollment.generation)
            let closure = try router.record(db, try XCTUnwrap((session["prior_native_closure_refs"] as? [String])?.last), type: "native_closure")
            XCTAssertEqual(closure["state"] as? String, "released")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.recipient_session_id')=? AND json_extract(data,'$.recipient_authorization_generation')=?",
                arguments: [fixture.project, enrollment.sessionID, router.sessionGeneration(session)]), 1)
        }
    }

    func testAsynchronousClosureWakesWaiterAfterReleasedWorkIsReadable() throws {
        let fixture = try fixture(claudeCount: 1, notes: 1, deliveries: 3, fillerBytes: 10)
        defer {
            do { try retire(fixture) }
            catch { XCTFail("Owned closure-waiter fixture cleanup failed: \(error)") }
        }
        let coordinator = fixture.coordinator, router = coordinator.router
        let finished = DispatchSemaphore(value: 0), results = WorkloadResults()
        let gateEntered = DispatchSemaphore(value:0), gateRelease = DispatchSemaphore(value:0)
        let gateFinished = DispatchSemaphore(value:0), readFinished = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            defer {gateFinished.signal()}
            do {
                try ArchiveStorageGate.withExclusive(root:router.root) { _ in
                    gateEntered.signal()
                    guard gateRelease.wait(timeout:.now()+15) == .success else {
                        throw NSError(domain:"NativeClosureFixtureGateNotReleased",code:1)
                    }
                }
            } catch {results.failed(error)}
        }
        defer {gateRelease.signal();_ = gateFinished.wait(timeout:.now()+15)}
        XCTAssertEqual(gateEntered.wait(timeout:.now()+5),.success)
        coordinator.queue.sync {
            coordinator.waiters[UUID()] = {
                do {
                    let response = try router.handle(method: "task_get", params: ["project_id": fixture.project,
                        "task_id": fixture.readTask], caller: Caller(role: "owner", installation: "closure-waiter-reader", projectIDs: []))
                    let task = response["data"] as? [String: Any]
                    if task == nil || task?["active_attempt_id"] != nil {
                        throw NSError(domain: "NativeClosureWaiterWokeBeforeCommit", code: 1)
                    }
                } catch { results.failed(error) }
                finished.signal()
            }
            // Only this task's conversation closes. An unrelated closure can
            // legitimately wake a general waiter before this task is released.
            let enrollment = fixture.enrollments[0], target = enrollment.sessionID
            coordinator.nativeLifecycle.inspect = { registration in
                if registration.sessionID == target {
                    coordinator.queue.async {
                        defer {readFinished.signal()}
                        do {
                            let response = try router.handle(method:"task_get",params:["project_id":fixture.project,"task_id":fixture.readTask],
                                caller:Caller(role:"owner",installation:"before-closure-reader",projectIDs:[]))
                            if coordinator.enrollmentSnapshot().committed[enrollment.installation]?.revoked != true ||
                                (response["data"] as? JSON)?["active_attempt_id"] == nil {
                                throw NSError(domain:"NativeClosureEarlyRelease",code:1)
                            }
                        } catch {results.failed(error)}
                    }
                }
                return .init(process: registration.sessionID == target ? .gone : .running,
                    registry: registration.sessionID == target ? .absent : .matching,
                    detail: "Owned asynchronous closure fixture")
            }
            coordinator.observeNativeConversationLifecycles()
        }
        XCTAssertEqual(readFinished.wait(timeout:.now()+5),.success,"The held archive gate must leave the command queue available")
        gateRelease.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync { coordinator.waiters.removeAll() }
        XCTAssertTrue(results.snapshot().errors.isEmpty, "The closure waiter must observe the committed release")
    }

    /// Set DELIVERY_COUNT to at least the assigned slot's measured live-copy
    /// count. The fixture never opens the selected slot or the live database.
    func testLiveSizeRestartQualification() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHECKLIST_LIFECYCLE_QUALIFICATION"] == "1",
              let count = Int(environment["CHECKLIST_LIFECYCLE_DELIVERY_COUNT"] ?? ""), count >= 2400 else {
            throw XCTSkip("Opt in with CHECKLIST_LIFECYCLE_QUALIFICATION=1 and a measured CHECKLIST_LIFECYCLE_DELIVERY_COUNT >=2400")
        }
        try run(claudeCount: 15, notes: 150, deliveryCount: count)
    }
}
