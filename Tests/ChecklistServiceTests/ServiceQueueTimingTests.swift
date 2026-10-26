import XCTest
import Foundation
import os
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class ServiceQueueTimingTests: XCTestCase {
    func testTimingKeepsReplyBeforeOrderedPostCommandWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        coordinator.workHealthFailures = 2
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let peer = Peer(coordinator:coordinator,connection:connection)
        var observed: [String] = []
        coordinator.waiters[UUID()] = {observed.append("waiter")}
        peer.finish(["data":["value":42]],timing:ServiceCallTiming(),method:"message_send") { bytes in
            let result = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any]
            XCTAssertEqual((result?["data"] as? [String:Any])?["value"] as? Int,42)
            XCTAssertNotNil(result?["_checklist_timing"])
            observed.append("reply")
        }
        XCTAssertEqual(observed,["reply","waiter"])
        coordinator.storageQueue.sync {}
        coordinator.queue.sync {coordinator.storageWake?.cancel()}
    }

    func testUntimedPureReadReplyDoesNotRunMutationHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let peer = Peer(coordinator:coordinator,connection:connection)
        coordinator.waiters[UUID()] = {XCTFail("A pure read must not wake mutation observers")}
        var replies = 0
        peer.finish(["data":["value":42]],runHooks:Peer.requiresAfterCommand("task_get"),method:"task_get") { bytes in
            let result = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any]
            XCTAssertNil(result?["_checklist_timing"])
            replies += 1
        }
        XCTAssertEqual(replies,1)
    }
}

extension ServiceQueueTimingTests {
    func testHeldDeadlineReadLeavesAdmissionFreeAndCoalescesFreshEarlierPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        defer {coordinator.storageWake?.cancel();try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let firstStarted = DispatchSemaphore(value:0), secondStarted = DispatchSemaphore(value:0)
        let resumeFirst = DispatchSemaphore(value:0), resumeSecond = DispatchSemaphore(value:0)
        defer {resumeFirst.signal();resumeSecond.signal()}
        let reads = OSAllocatedUnfairLock(initialState:0)
        let first = Date().addingTimeInterval(3600), earlier = first.addingTimeInterval(-600)
        let load: @Sendable () throws -> Date? = {
            let index = reads.withLock { $0 += 1; return $0 }
            if index == 1 {
                firstStarted.signal()
                guard resumeFirst.wait(timeout:.now()+10) == .success else {throw NSError(domain:"DeadlineTest",code:1)}
                return first
            }
            secondStarted.signal()
            guard resumeSecond.wait(timeout:.now()+10) == .success else {throw NSError(domain:"DeadlineTest",code:2)}
            return earlier
        }
        coordinator.queue.sync {coordinator.armStorageWake(loadDeadline:load)}
        XCTAssertEqual(firstStarted.wait(timeout:.now()+10),.success)
        // This sync completes while discovery is deliberately held: request
        // admission and repeated change notifications cannot join that read.
        coordinator.queue.sync {
            for _ in 0..<20 {coordinator.armStorageWake(loadDeadline:load)}
            XCTAssertTrue(coordinator.storageWakePlanning)
        }
        XCTAssertEqual(reads.withLock { $0 },1)
        resumeFirst.signal()
        XCTAssertEqual(secondStarted.wait(timeout:.now()+10),.success)
        coordinator.queue.sync {XCTAssertEqual(coordinator.storageWakePlan.deadline,first)}
        resumeSecond.signal()
        coordinator.storageQueue.sync {}
        coordinator.queue.sync {
            XCTAssertEqual(coordinator.storageWakePlan.deadline,earlier)
            XCTAssertFalse(coordinator.storageWakePlanning)
            XCTAssertFalse(coordinator.storageWakeReplan)
        }
        XCTAssertEqual(reads.withLock { $0 },2)
    }

    func testPureWorkspaceReadsKeepRepairHooksReservedForManagedReadsAndWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let peer = Peer(coordinator:coordinator,connection:connection)
        coordinator.waiters[UUID()] = {XCTFail("Pure workspace reads cannot announce a mutation")}
        for method in ["workspace_page","task_list","triage_list","epic_list"] {
            var replies = 0
            peer.finish(["data":[:]],runHooks:Peer.requiresAfterCommand(method),method:method) {_ in replies += 1}
            XCTAssertEqual(replies,1)
        }
        for method in ["task_context","attachment_read","attachment_cleanup_preview","review_record","batch_claim","batch_release","message_send"] {
            XCTAssertTrue(Peer.requiresAfterCommand(method),method)
        }
    }
}


extension ServiceQueueTimingTests {
    func testMaintenanceTurnFencesPlanThatWasAlreadyInFlight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        defer {coordinator.storageWake?.cancel();try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let started = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        defer {resume.signal()}
        let old = Date().addingTimeInterval(3600), fresh = old.addingTimeInterval(-300)
        coordinator.queue.sync {
            coordinator.armStorageWake(loadDeadline:{
                started.signal()
                guard resume.wait(timeout:.now()+10) == .success else {throw NSError(domain:"DeadlineTest",code:3)}
                return old
            })
        }
        XCTAssertEqual(started.wait(timeout:.now()+10),.success)
        coordinator.queue.sync {coordinator.armStorageWake();coordinator.storageRunning = true}
        resume.signal()
        coordinator.storageQueue.sync {}
        coordinator.queue.sync {
            XCTAssertNil(coordinator.storageWakePlan.deadline,"The running maintenance turn owns the next fresh plan")
            XCTAssertFalse(coordinator.storageWakePlanning)
            XCTAssertFalse(coordinator.storageWakeReplan)
            coordinator.storageRunning = false
            coordinator.armStorageWake(loadDeadline:{fresh})
        }
        coordinator.storageQueue.sync {}
        coordinator.queue.sync {XCTAssertEqual(coordinator.storageWakePlan.deadline,fresh)}
    }
}
