import XCTest
import Foundation
import GRDB
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class NativeLifecycleWriteGateTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var snapshot: [String] { lock.withLock { values } }
    }
    private var root: URL!
    private var coordinator: Coordinator!

    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification/r12-N/test-fixtures")
            .appendingPathComponent("native-writer-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let instance = try ChecklistInstance(home: root, environment: [:])
        let credentials = InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: credentials, instance: instance)
        coordinator.nativeLifecycle.watchesEnabled = false
    }

    override func tearDownWithError() throws {
        // The last deferred write can schedule a final empty observation turn.
        coordinator.queue.sync {}; coordinator.queue.sync {}
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.nativeLifecycle.resumptionInFlight)
            XCTAssertFalse(coordinator.nativeLifecycle.deferredWriteScheduled)
            XCTAssertFalse(coordinator.nativeLifecycle.connectionRequestScheduled)
            XCTAssertTrue(coordinator.nativeLifecycle.deferredWrites.isEmpty)
            coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel()
        }
        coordinator.queue.busyPeriods.flush()
        try coordinator.router.closeStore(); coordinator = nil
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: trash.appendingPathComponent(root.lastPathComponent))
    }

    func testReadRunsWhileRealWriterIsHeldAndQueuedWriteWaitsForCommit() throws {
        let coordinator = coordinator!, trace = Trace()
        let writerEntered = DispatchSemaphore(value: 0), releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup(), readFinished = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        coordinator.queue.sync { coordinator.nativeLifecycle.resumptionInFlight = true }
        writerFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writerFinished.leave() }
            do {
                try coordinator.router.dbQueue.write { db in
                    try coordinator.router.save(db, ["id": "held-gate-fixture", "project_id": "gate-project", "revision": 1], type: "session")
                    writerEntered.signal()
                    guard releaseWriter.wait(timeout: .now() + 10) == .success else {
                        throw NSError(domain: "WriterGateTestTimedOut", code: 1)
                    }
                }
                trace.append("committed")
            } catch { trace.append("writer-error: \(error)") }
        }
        defer { releaseWriter.signal(); _ = writerFinished.wait(timeout: .now() + 10) }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 10), .success)
        coordinator.queue.async {
            coordinator.performNativeLifecycleWrite {
                do {
                    let count = try coordinator.router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM records WHERE id='held-gate-fixture'") }
                    trace.append("write-sees-\(count ?? -1)")
                } catch { trace.append("write-error: \(error)") }
                writeFinished.signal()
            }
            do {
                let count = try coordinator.router.readForPreparation { try Int.fetchOne($0, sql: "SELECT count(*) FROM records WHERE id='held-gate-fixture'") }
                trace.append("read-sees-\(count ?? -1)")
            } catch { trace.append("read-error: \(error)") }
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(trace.snapshot, ["read-sees-0"])
        coordinator.queue.sync { XCTAssertEqual(coordinator.nativeLifecycle.deferredWrites.count, 1) }
        releaseWriter.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 10), .success)
        coordinator.queue.async { coordinator.finishNativeBootstrapWork { trace.append("completion") } }
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.snapshot, ["read-sees-0", "committed", "completion", "write-sees-1"])
    }

    func testDeferredWritesKeepFIFOAndYieldBeforeNextBootstrap() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.performNativeLifecycleWrite {
                trace.append("write-1")
                coordinator.performNativeLifecycleWrite { trace.append("nested-write-1") }
                coordinator.queue.async { trace.append("foreground-read") }
            }
            coordinator.performNativeLifecycleWrite { trace.append("write-2") }
            coordinator.enqueueNativeConnectionRequest { trace.append("bootstrap"); finished.signal() }
            coordinator.finishNativeBootstrapWork {
                trace.append("completion")
                coordinator.performNativeLifecycleWrite { trace.append("completion-write") }
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.snapshot, ["completion", "write-1", "nested-write-1", "foreground-read", "write-2", "completion-write", "bootstrap"])
    }

    func testSynchronousRelayWriterReturnsItsCommittedValueOffQueue() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync { coordinator.nativeLifecycle.resumptionInFlight = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Int, NSError> = coordinator.syncNativeLifecycleWrite {
                coordinator.requireCommandQueue()
                trace.append("relay-write")
                return .success(73)
            }
            switch result {
            case .success(let value): trace.append("returned-\(value)")
            case .failure(let error): trace.append("unexpected-error-\(error)")
            }
            finished.signal()
        }
        coordinator.queue.async {
            trace.append("foreground-read")
            coordinator.finishNativeBootstrapWork {}
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.snapshot, ["foreground-read", "relay-write", "returned-73"])
    }

    func testFailedBootstrapCompletionStillDrainsWritersAndLaterRequests() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.performNativeLifecycleWrite { trace.append("queued-write") }
            coordinator.enqueueNativeConnectionRequest { trace.append("later-bootstrap"); finished.signal() }
            let failure: Result<Coordinator.BootstrapResult, Error> = .failure(CoreError("SYNTHETIC_FAILURE", "Owned gate fixture"))
            coordinator.finishNativeBootstrapWork {
                if case .failure(let error) = failure { trace.append((error as? CoreError)?.code ?? "wrong-error") }
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.snapshot, ["SYNTHETIC_FAILURE", "queued-write", "later-bootstrap"])
    }

    func testCompletionDoesNotDuplicateAnAlreadyScheduledNativeTurn() throws {
        let coordinator = coordinator!, trace = Trace(), finished = DispatchSemaphore(value: 0)
        coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.enqueueNativeConnectionRequest {
                trace.append("bootstrap-1")
                coordinator.queue.async { trace.append("foreground-read") }
            }
            coordinator.enqueueNativeConnectionRequest { trace.append("bootstrap-2"); finished.signal() }
            // The first admission already scheduled a turn. Finishing before it
            // runs must reuse that turn and retain foreground-read fairness.
            coordinator.finishNativeBootstrapWork { trace.append("completion") }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.nativeLifecycle.connectionTurnPending)
            XCTAssertFalse(coordinator.nativeLifecycle.connectionRequestScheduled)
            XCTAssertTrue(coordinator.nativeLifecycle.connectionRequests.isEmpty)
        }
        XCTAssertEqual(trace.snapshot, ["completion", "bootstrap-1", "foreground-read", "bootstrap-2"])
    }
}
