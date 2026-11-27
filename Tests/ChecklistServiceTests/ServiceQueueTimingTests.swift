import XCTest
import Foundation
import os
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class ServiceQueueTimingTests: XCTestCase {
    func testTicketCaptureWaitingForObjectGateLeavesStatusAndBootstrapResponsive() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let owner = Caller(role:"owner",installation:"queue-timing-owner",projectIDs:[])
        func setup(_ method: String, _ params: JSON) throws -> JSON {
            var params = params
            params["command_id"] = uuid()
            let reply = try router.handle(method:method,params:params,caller:owner)
            return try XCTUnwrap(reply["data"] as? JSON)
        }
        let project = try XCTUnwrap(try setup("project_create",["name":"Timing fixture","root_path":root.path])["id"] as? String)
        let epic = try XCTUnwrap(try setup("epic_create",["project_id":project,"name":"Capture fixture"])["id"] as? String)
        let session = uuid(), installation = "queue-timing-worker", generation = "current"
        let credential = "queue-timing-fixture"
        let registered = try setup("session_register",["project_id":project,"project_ids":[project],"session_id":session,
            "installation":installation+"/"+generation,"provider":"codex","role":"worker","workspace":root.path])
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        coordinator.workHealthFailures = 2
        coordinator.enrollments[installation] = Enrollment(installation:installation,name:"Timing fixture",provider:"codex",role:"worker",
            projectIDs:[project],sessionID:session,workspace:root.path,profileID:nil,tokenDigest:ChecklistCore.hash(Data(credential.utf8)),generation:generation)
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let peer = Peer(coordinator:coordinator,connection:connection)
        let held = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        let holder = DispatchQueue(label:"test.archive-storage-gate")
        holder.async {
            do {
                try ArchiveStorageGate.withExclusive(root:root) { _ in
                    held.signal()
                    _ = release.wait(timeout:.now()+10)
                }
            } catch {XCTFail("Unable to hold object gate: \(error)")}
        }
        defer {
            release.signal()
            holder.sync {}
            coordinator.queue.sync {}
            coordinator.storageQueue.sync {}
            coordinator.queue.sync {coordinator.storageWake?.cancel()}
        }
        guard held.wait(timeout:.now()+5) == .success else {return XCTFail("Object gate was not acquired")}

        let command = uuid()
        let capture = try JSONSerialization.data(withJSONObject:["method":"task_create","installation":installation,
            "credential":credential,"workspace":root.path,"params":["project_id":project,"epic_id":epic,"title":"Ticket behind gate","command_id":command]])
        let status = try JSONSerialization.data(withJSONObject:["method":"service_info","params":[:]])
        let bootstrap = try JSONSerialization.data(withJSONObject:["method":"connection_bootstrap","params":[:]])
        let captureReply = expectation(description:"Committed capture"), statusReply = expectation(description:"Independent status")
        let bootstrapReply = expectation(description:"Independent bootstrap authentication")
        let captured = OSAllocatedUnfairLock(initialState:false)
        peer.execute(capture) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with:bytes)) as? JSON
            XCTAssertEqual(reply?["command_id"] as? String,command)
            XCTAssertEqual((reply?["data"] as? JSON)?["title"] as? String,"Ticket behind gate")
            captured.withLock {$0 = true}
            captureReply.fulfill()
        }
        peer.execute(status) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with:bytes)) as? JSON
            XCTAssertNotNil(reply?["data"])
            statusReply.fulfill()
        }
        peer.execute(bootstrap) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with:bytes)) as? JSON
            XCTAssertEqual((reply?["error"] as? JSON)?["code"] as? String,"NATIVE_CLIENT_REQUIRED")
            bootstrapReply.fulfill()
        }
        let responsive = XCTWaiter.wait(for:[statusReply,bootstrapReply],timeout:1)
        XCTAssertFalse(captured.withLock {$0},"Capture must wait for the object gate")
        release.signal()
        wait(for:[captureReply],timeout:5)
        if responsive != .completed {coordinator.queue.sync {}}
        XCTAssertEqual(responsive,.completed,"Status and bootstrap must reply while capture waits for the object gate")

        let workerHeld = DispatchSemaphore(value:0), releaseWorker = DispatchSemaphore(value:0)
        coordinator.ticketCaptureQueue.async {
            workerHeld.signal()
            _ = releaseWorker.wait(timeout:.now()+10)
        }
        defer {releaseWorker.signal();coordinator.ticketCaptureQueue.sync {}}
        guard workerHeld.wait(timeout:.now()+5) == .success else {return XCTFail("Capture worker was not held")}
        let stale = try JSONSerialization.data(withJSONObject:["method":"task_create","installation":installation,
            "credential":credential,"workspace":root.path,"params":["project_id":project,"epic_id":epic,"title":"Stale capture","command_id":uuid()]])
        let staleReply = expectation(description:"Stale capture refused")
        peer.execute(stale) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with:bytes)) as? JSON
            XCTAssertEqual((reply?["error"] as? JSON)?["code"] as? String,"CONNECTION_REVOKED")
            XCTAssertNotNil(reply?["write_admission"])
            staleReply.fulfill()
        }
        coordinator.queue.sync {}
        _ = try setup("session_update",["project_id":project,"session_id":session,
            "expected_revision":registered["revision"]!,"provider":"claude"])
        releaseWorker.signal()
        wait(for:[staleReply],timeout:5)
    }

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

extension ServiceQueueTimingTests {
    func testTenCleanupMetadataRepliesLeaveForegroundReadsFreeOfMutationHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        coordinator.workHealthFailures = 2
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let peer = Peer(coordinator:coordinator,connection:connection)
        var hooks = 0, replies = 0
        coordinator.queue.sync {
            coordinator.waiters[UUID()] = {hooks += 1}
            for method in Array(repeating:"cleanup_job_list",count:10) + ["cleanup_job_get","service_info","task_get"] {
                XCTAssertTrue(CommandRouter.runsOutsideSerialQueue(method),method)
                peer.finish(["data":[:]],runHooks:Peer.requiresAfterCommand(method),method:method) {_ in replies += 1}
            }
            XCTAssertEqual(replies,13)
            XCTAssertEqual(hooks,0,"Metadata reads must not queue mutation/change/native/storage scans ahead of foreground admission")
            for method in ["cleanup_job_cancel","cleanup_job_retry","task_archive","message_send","attachment_read","attachment_cleanup_preview"] {
                XCTAssertTrue(Peer.requiresAfterCommand(method),method)
            }
        }
        coordinator.storageQueue.sync {}
        coordinator.queue.sync {coordinator.storageWake?.cancel()}
    }
}
