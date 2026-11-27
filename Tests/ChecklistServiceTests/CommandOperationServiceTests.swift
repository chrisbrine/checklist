import XCTest
import Foundation
import os
@testable import ChecklistCore
@testable import ChecklistService

final class CommandOperationServiceTests: XCTestCase {
    func testCoordinatorRunsDurableBackupReplyOnItsOperationQueue() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("operation-service-" + UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let router = try CommandRouter(root:directory.appendingPathComponent("store"))
        let coordinator = Coordinator(router:router,enrollmentFile:directory.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        defer {coordinator.commandOperationQueue.sync(flags:.barrier) {};coordinator.queue.sync {};try? router.closeStore()}
        let caller = Caller(role:"owner",installation:"operation-service-fixture",projectIDs:[]),command = UUID().uuidString
        let reply = try router.handle(method:"backup_create",params:["command_id":command,"path":directory.appendingPathComponent("backup").path],caller:caller)
        XCTAssertEqual(reply["command_outcome"] as? String,"accepted")
        let receipt = try XCTUnwrap(reply["data"] as? [String:Any]),id = try XCTUnwrap(receipt["operation_id"] as? String)
        XCTAssertEqual(receipt["status_method"] as? String,"operation_get")
        coordinator.commandOperationQueue.sync(flags:.barrier) {};coordinator.queue.sync {}
        let status = try router.handle(method:"operation_get",params:["operation_id":id],caller:caller)["data"] as! [String:Any]
        XCTAssertEqual(status["state"] as? String,"succeeded")
        let result = try XCTUnwrap(status["result"] as? [String:Any])
        XCTAssertEqual(result["command_id"] as? String,command)
        XCTAssertEqual((result["data"] as? [String:Any])?["status"] as? String,"complete")
    }

    func testMediaRoundDeletionInAnotherProjectFinishesWhileFirstProjectIsPreparing() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("media-deletion-service-" + UUID().uuidString)
        let router = try CommandRouter(root:directory.appendingPathComponent("store"))
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:directory)}
        let owner = Caller(role:"owner",installation:"operation-service-fixture",projectIDs:[])
        let first = try closedRound(router,owner,name:"Project A")
        let second = try closedRound(router,owner,name:"Project B")
        let coordinator = Coordinator(router:router,enrollmentFile:directory.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}

        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),secondFinished = DispatchSemaphore(value:0)
        let firstPreparation = OSAllocatedUnfairLock(initialState:true)
        let executions = OSAllocatedUnfairLock(initialState:[String]())
        router.commandOperations.executionProbe = {id in executions.withLock {$0.append(id)}}
        router.mediaRoundDeletionPreparationProbe = {
            let hold = firstPreparation.withLock {value in
                defer {value = false}
                return value
            }
            guard hold else {return}
            entered.signal()
            guard release.wait(timeout:.now()+25) == .success else {throw CoreError("TEST_TIMEOUT","Held reader was not released.")}
        }
        let waiter = UUID()
        defer {
            release.signal()
            let drained = DispatchSemaphore(value:0)
            coordinator.mediaRoundDeletionQueue.async(flags:.barrier) {drained.signal()}
            XCTAssertEqual(drained.wait(timeout:.now()+10),.success)
            coordinator.queue.sync {_ = coordinator.waiters.removeValue(forKey:waiter)}
            router.mediaRoundDeletionPreparationProbe = nil
            router.commandOperations.executionProbe = nil
        }
        func accept(_ round: (project: String,id: String,revision: Int)) throws -> JSON {
            let reply = try router.handle(method:"media_round_delete",params:["project_id":round.project,"round_id":round.id,
                "expected_revision":round.revision,"reason":"Retire this synthetic media pass","command_id":uuid()],caller:owner)
            let id = try XCTUnwrap((reply["data"] as? JSON)?["operation_id"] as? String)
            XCTAssertEqual(reply["command_outcome"] as? String,"accepted")
            return ["project_id":round.project,"operation_id":id]
        }
        func status(_ query: JSON) throws -> JSON {
            try XCTUnwrap(router.handle(method:"operation_get",params:query,caller:owner)["data"] as? JSON)
        }
        let queryA = try coordinator.queue.sync {try accept(first)}
        guard entered.wait(timeout:.now()+10) == .success else {return XCTFail("Project A did not reach reader preparation")}
        let queryB = try coordinator.queue.sync {
            let query = try accept(second)
            coordinator.waiters[waiter] = {
                if let result = try? status(query),["succeeded","failed"].contains(result["state"] as? String ?? "") {secondFinished.signal()}
            }
            return query
        }
        var statusSeconds: [TimeInterval] = []
        for sample in 0..<4 {
            if sample > 0 {Thread.sleep(forTimeInterval:0.25)}
            let before = ProcessInfo.processInfo.systemUptime
            let reply = try coordinator.queue.sync {try coordinator.execute(["method":"service_info"],connection:connection)}
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            XCTAssertNotNil(reply["data"])
            XCTAssertLessThan(elapsed,1,"Service status while Project A's reader is held")
            statusSeconds.append(elapsed)
        }
        print("CL-518 coordinator service_info wall seconds with held reader: \(statusSeconds)")
        guard secondFinished.wait(timeout:.now()+5) == .success else {return XCTFail("Project B waited for Project A's held reader")}
        XCTAssertEqual(try status(queryB)["state"] as? String,"succeeded")
        XCTAssertEqual(try status(queryA)["state"] as? String,"running")
        release.signal()
        coordinator.mediaRoundDeletionQueue.sync(flags:.barrier) {}
        XCTAssertEqual(try status(queryA)["state"] as? String,"succeeded")
        XCTAssertEqual(executions.withLock {$0},try [queryA,queryB].map {try XCTUnwrap($0["operation_id"] as? String)})
    }

    private func closedRound(_ router: CommandRouter,_ owner: Caller,name: String) throws -> (project: String,id: String,revision: Int) {
        let created = try router.handle(method:"project_create",params:["command_id":uuid(),"name":name,"key_prefix":"DEL"],caller:owner)
        let project = try XCTUnwrap((created["data"] as? JSON)?["id"] as? String)
        func media(_ method: String,_ input: JSON) throws -> JSON {
            var params = input
            params["project_id"] = project
            if method != "media_type_get" {params["command_id"] = uuid()}
            return try router.executeMediaCommand(method:method,params:params,caller:owner)
        }
        let schema: JSON = ["schema_version":1,"id":"server-replaced","name":"Story","fields":[],
            "slots":[["id":"text","kind":"text","required":true]],"layout":["kind":"text_compare","primary_slot_id":"text"]]
        let type = try media("media_type_create",["title":"Story","schema":schema])
        let typeID = try XCTUnwrap(type["id"] as? String),draft = try media("media_type_get",["type_id":typeID])
        _ = try media("media_type_adopt",["type_id":typeID,"type_revision_id":draft["draft_revision_id"]!,
            "expected_revision":draft["revision"]!,"observed_type_token":draft["observed_type_token"]!])
        let round = try media("media_round_create",["type_id":typeID,"title":"Synthetic round"])
        let id = try XCTUnwrap(round["id"] as? String)
        let canceled = try media("media_round_cancel",["round_id":id,"expected_revision":round["revision"]!,"reason":"Synthetic cancellation"])
        return (project,id,try XCTUnwrap(canceled["revision"] as? Int))
    }
}
