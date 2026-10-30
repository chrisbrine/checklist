import Foundation
import os
import XCTest
@testable import ChecklistCore
@testable import ChecklistService

final class WorkHealthSchedulingTests: XCTestCase {
    func testHeldAdvisoryCheckLeavesCommandAdmissionFree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-health-scheduling-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        defer {
            coordinator.queue.sync {coordinator.workHealthWake?.cancel()}
            try? router.closeStore()
            try? FileManager.default.removeItem(at:root)
        }
        let entered = DispatchSemaphore(value:0),resume = DispatchSemaphore(value:0)
        let admitted = DispatchSemaphore(value:0),completed = DispatchSemaphore(value:0)
        defer {resume.signal()}
        coordinator.queue.async {
            coordinator.waiters[UUID()] = {completed.signal()}
            coordinator.runWorkHealth(check:{
                entered.signal()
                guard resume.wait(timeout:.now()+10) == .success else {throw NSError(domain:"HeldWorkHealth",code:1)}
                return ["enabled":false,"changed":1]
            })
        }
        XCTAssertEqual(entered.wait(timeout:.now()+10),.success)
        // This is an ordering check while the health page is deliberately held,
        // not a wall-time acceptance budget. Ordinary admission must stay free.
        coordinator.queue.async {admitted.signal()}
        let admission = admitted.wait(timeout:.now()+2)
        resume.signal()
        XCTAssertEqual(admission,.success,"Advisory work-health storage must not occupy the request command queue")
        XCTAssertEqual(completed.wait(timeout:.now()+10),.success,"Apply changed results back on the command queue")
    }

    func testNotificationsDuringOnePageCoalesceWithoutOverlappingChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-health-coalescing-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        let entered = DispatchSemaphore(value:0),resume = DispatchSemaphore(value:0),completed = DispatchSemaphore(value:0)
        let calls = OSAllocatedUnfairLock(initialState:0)
        defer {
            resume.signal()
            coordinator.workHealthQueue.sync {}
            coordinator.queue.sync {coordinator.workHealthWake?.cancel()}
            try? router.closeStore();try? FileManager.default.removeItem(at:root)
        }
        let check: @Sendable () throws -> [String:Any] = {
            let index = calls.withLock {$0 += 1;return $0}
            if index == 1 {
                entered.signal()
                guard resume.wait(timeout:.now()+10) == .success else {throw NSError(domain:"HeldWorkHealth",code:2)}
            }
            return ["enabled":false,"changed":1]
        }
        coordinator.queue.async {
            coordinator.waiters[UUID()] = {if calls.withLock({$0}) == 2 {completed.signal()}}
            coordinator.runWorkHealth(check:check)
        }
        XCTAssertEqual(entered.wait(timeout:.now()+10),.success)
        coordinator.queue.sync {
            for _ in 0..<20 {coordinator.runWorkHealth(check:check)}
            XCTAssertTrue(coordinator.workHealthRunning)
            XCTAssertEqual(calls.withLock {$0},1)
        }
        resume.signal()
        XCTAssertEqual(completed.wait(timeout:.now()+10),.success,"One fresh page preserves notifications received during an old disabled observation")
        coordinator.workHealthQueue.sync {}
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.workHealthRunning)
            XCTAssertFalse(coordinator.workHealthRecheck)
            XCTAssertNil(coordinator.workHealthWake)
        }
        XCTAssertEqual(calls.withLock {$0},2)
    }

    func testFailuresKeepTwoAttemptHoldAndSuccessfulPageResetsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-health-failures-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        defer {
            coordinator.workHealthQueue.sync {}
            coordinator.queue.sync {coordinator.workHealthWake?.cancel()}
            try? router.closeStore();try? FileManager.default.removeItem(at:root)
        }
        for attempt in 1...2 {
            coordinator.queue.sync {coordinator.runWorkHealth(check:{throw NSError(domain:"WorkHealthFailure",code:1)})}
            coordinator.workHealthQueue.sync {}
            coordinator.queue.sync {
                XCTAssertFalse(coordinator.workHealthRunning)
                XCTAssertEqual(coordinator.workHealthFailures,attempt)
                XCTAssertEqual(coordinator.workHealthWake != nil,attempt < 2)
                coordinator.workHealthWake?.cancel();coordinator.workHealthWake = nil
            }
        }
        coordinator.queue.sync {coordinator.runWorkHealth(check:{["enabled":true,"changed":0,"has_more":false]})}
        coordinator.workHealthQueue.sync {}
        coordinator.queue.sync {
            XCTAssertEqual(coordinator.workHealthFailures,0)
            XCTAssertFalse(coordinator.workHealthRunning)
            XCTAssertNotNil(coordinator.workHealthWake)
        }
    }

    func testCaptureDefersHealthAndUnlockedNotificationCanResumeIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-health-capture-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        let calls = OSAllocatedUnfairLock(initialState:0)
        defer {
            router.backupWrites.endBackup(router:router)
            coordinator.workHealthQueue.sync {}
            coordinator.queue.sync {coordinator.workHealthWake?.cancel()}
            try? router.closeStore();try? FileManager.default.removeItem(at:root)
        }
        let check: @Sendable () throws -> [String:Any] = {calls.withLock {$0 += 1};return ["enabled":false,"changed":0]}
        try router.backupWrites.beginCapture()
        coordinator.queue.sync {coordinator.runWorkHealth(check:check)}
        coordinator.workHealthQueue.sync {}
        coordinator.queue.sync {
            XCTAssertEqual(calls.withLock {$0},0)
            XCTAssertFalse(coordinator.workHealthRunning)
            XCTAssertEqual(coordinator.workHealthFailures,0)
            XCTAssertNil(coordinator.workHealthWake)
        }
        router.backupWrites.endBackup(router:router)
        // Synchronous fixtures disable background hooks. Invoke the same resume
        // entry point used by the production admission-unlock observer.
        coordinator.queue.sync {coordinator.runWorkHealth(check:check)}
        coordinator.workHealthQueue.sync {}
        coordinator.queue.sync {XCTAssertEqual(calls.withLock {$0},1);XCTAssertFalse(coordinator.workHealthRunning)}
    }

    func testUnlockDuringDeferredWorkerCompletionRearmsOneCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-health-deferred-unlock-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        let workerHeld = DispatchSemaphore(value:0),releaseWorker = DispatchSemaphore(value:0)
        let commandHeld = DispatchSemaphore(value:0),releaseCommand = DispatchSemaphore(value:0)
        let completed = DispatchSemaphore(value:0),calls = OSAllocatedUnfairLock(initialState:0)
        defer {
            releaseWorker.signal();releaseCommand.signal()
            coordinator.workHealthQueue.sync {}
            coordinator.queue.sync {coordinator.workHealthWake?.cancel()}
            router.backupWrites.endBackup(router:router)
            coordinator.queue.sync {}
            try? router.closeStore();try? FileManager.default.removeItem(at:root)
        }
        let check: @Sendable () throws -> [String:Any] = {
            calls.withLock {$0 += 1}
            return ["enabled":false,"changed":1]
        }
        // Hold the worker before its immediate-write admission, while allowing
        // the command queue to record the single in-flight page.
        coordinator.workHealthQueue.async {
            workerHeld.signal()
            _ = releaseWorker.wait(timeout:.now()+10)
        }
        XCTAssertEqual(workerHeld.wait(timeout:.now()+10),.success)
        coordinator.queue.sync {
            coordinator.waiters[UUID()] = {if calls.withLock({$0}) == 1 {completed.signal()}}
            coordinator.runWorkHealth(check:check)
            XCTAssertTrue(coordinator.workHealthRunning)
        }
        try router.backupWrites.beginCapture()
        // Keep the deferred worker's result queued until the unlock notification
        // has reached runWorkHealth with the old in-flight flag still set.
        coordinator.queue.async {
            commandHeld.signal()
            _ = releaseCommand.wait(timeout:.now()+10)
            router.backupWrites.endBackup(router:router)
            coordinator.runWorkHealth(check:check)
            XCTAssertTrue(coordinator.workHealthRunning)
            XCTAssertTrue(coordinator.workHealthRecheck)
        }
        XCTAssertEqual(commandHeld.wait(timeout:.now()+10),.success)
        releaseWorker.signal()
        coordinator.workHealthQueue.sync {}
        XCTAssertEqual(calls.withLock {$0},0,"Capture must defer the worker before the injected health check")
        releaseCommand.signal()
        XCTAssertEqual(completed.wait(timeout:.now()+10),.success,"The unlock must survive the pending deferred completion")
        coordinator.workHealthQueue.sync {}
        coordinator.queue.sync {
            XCTAssertEqual(calls.withLock {$0},1)
            XCTAssertFalse(coordinator.workHealthRunning)
            XCTAssertFalse(coordinator.workHealthRecheck)
            XCTAssertEqual(coordinator.workHealthFailures,0)
            XCTAssertNil(coordinator.workHealthWake)
        }
    }

}
