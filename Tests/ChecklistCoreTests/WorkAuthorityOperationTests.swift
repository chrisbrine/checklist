import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    func testWorkAuthorityOperationsAcceptBeforeExecutionAndRetainProjectOrder() throws {
        let router = try XCTUnwrap(self.router)
        let project = try self.project(), task = try ready(project)
        let parent = try native(project,"authority-operation-parent",domain:"authority-operation-parent")
        let child = try native(project,"authority-operation-child",domain:"authority-operation-child")
        let attempt = try claim(project,task,files:[["path":"Sources","access":"write"]],caller:parent)
        let projectID = try XCTUnwrap(project["id"] as? String)
        var delegation = auth(project,attempt)
        delegation["child_session_id"] = try XCTUnwrap(child.sessionID)
        delegation["file_scopes"] = [["path":"Sources/Child.swift","access":"write"]]
        let offer = try call("work_delegate",delegation,parent)

        let operations = DispatchQueue(label:"checklist-work-authority-operation-test",attributes:.concurrent)
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), completed = DispatchSemaphore(value:0)
        let started = LockedTestState<[String]>([])
        router.configureCommandOperations(on:operations) { method, terminal in
            if ["work_checkpoint","work_child_accept"].contains(method), terminal {completed.signal()}
        }
        router.commandOperations.executionProbe = { id in
            let first = started.withLock { ids -> Bool in
                ids.append(id)
                return ids.count == 1
            }
            if first {
                entered.signal()
                XCTAssertEqual(release.wait(timeout:.now()+15),.success)
            }
        }
        defer {release.signal();router.commandOperations.executionProbe = nil}

        func submit(_ method: String, _ input: JSON, _ caller: Caller) throws -> String {
            var params = input
            let command = uuid()
            params["command_id"] = command
            let reply = try router.handle(method:method,params:params,caller:caller)
            XCTAssertEqual(reply["command_outcome"] as? String,"accepted")
            XCTAssertEqual(reply["command_id"] as? String,command)
            let data = try XCTUnwrap(reply["data"] as? JSON)
            XCTAssertNil(data["result"])
            return try XCTUnwrap(data["operation_id"] as? String)
        }
        func status(_ operation: String, _ caller: Caller) throws -> JSON {
            try call("operation_get",["project_id":projectID,"operation_id":operation],caller)
        }

        var checkpoint = auth(project,attempt)
        checkpoint["progress"] = "First progress within this project"
        let first = try submit("work_checkpoint",checkpoint,parent)
        XCTAssertEqual(entered.wait(timeout:.now()+10),.success)
        checkpoint["progress"] = "Second progress within this project"
        let second = try submit("work_checkpoint",checkpoint,parent)
        let acceptedChild = try submit("work_child_accept",["project_id":projectID,"delegation_id":offer["id"]!],child)
        XCTAssertEqual(try status(first,parent)["state"] as? String,"running")
        XCTAssertEqual(try status(second,parent)["state"] as? String,"queued")
        XCTAssertEqual(try status(acceptedChild,child)["state"] as? String,"queued")
        XCTAssertEqual(started.snapshot,[first])
        XCTAssertEqual(try call("task_get",["project_id":projectID,"task_id":task["id"]!],parent)["id"] as? String,task["id"] as? String)

        release.signal()
        for _ in 0..<3 {XCTAssertEqual(completed.wait(timeout:.now()+20),.success)}
        XCTAssertEqual(started.snapshot,[first,second,acceptedChild])
        let firstResult = try XCTUnwrap(try status(first,parent)["result"] as? JSON)
        let secondResult = try XCTUnwrap(try status(second,parent)["result"] as? JSON)
        XCTAssertNotNil((firstResult["data"] as? JSON)?["checkpoint_id"])
        XCTAssertEqual((secondResult["data"] as? JSON)?["progress"] as? String,checkpoint["progress"] as? String)
        let childReply = try status(acceptedChild,child)
        let childResult = try XCTUnwrap((childReply["result"] as? JSON)?["data"] as? JSON)
        let token = try XCTUnwrap(childResult["claim_token"] as? String)
        XCTAssertFalse(token.isEmpty)
        let gate = DispatchQueue(label:"checklist-credential-read-held-gate")
        let holding = DispatchSemaphore(value:0), releaseGate = DispatchSemaphore(value:0)
        gate.async {
            do {
                try ArchiveStorageGate.withExclusive(root:router.root) { _ in
                    holding.signal()
                    _ = releaseGate.wait(timeout:.now()+10)
                }
            } catch {XCTFail("Could not reserve the archive gate: \(error)")}
        }
        defer {releaseGate.signal();gate.sync {}}
        XCTAssertEqual(holding.wait(timeout:.now()+5),.success)
        let lookup: JSON = ["project_id":projectID,"operation_id":acceptedChild]
        XCTAssertThrowsError(try router.handleIndependentRead(method:"operation_get",params:lookup,caller:child)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"OPERATION_RESULT_BUSY")
        }
        releaseGate.signal();gate.sync {}
        let renewed = try router.handleIndependentRead(method:"operation_get",params:lookup,caller:child)
        let operation = try XCTUnwrap(renewed["data"] as? JSON)
        XCTAssertEqual(operation["state"] as? String,"succeeded")
        let result = try XCTUnwrap((operation["result"] as? JSON)?["data"] as? JSON)
        let updatedToken = try XCTUnwrap(result["claim_token"] as? String)
        XCTAssertNotEqual(updatedToken,token)
        let stored = try router.dbQueue.read { db in
            try router.record(db,try XCTUnwrap(childResult["id"] as? String),type:"attempt")
        }
        XCTAssertEqual(stored["token_hash"] as? String,ChecklistCore.hash(Data(updatedToken.utf8)))
    }
}
