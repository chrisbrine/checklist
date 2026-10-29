import XCTest
import Foundation
import ChecklistCore
@testable import ChecklistService

final class CommandOperationServiceTests: XCTestCase {
    func testCoordinatorUsesExistingUtilityLaneForDurableBackupReply() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("operation-service-" + UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let router = try CommandRouter(root:directory.appendingPathComponent("store"))
        let coordinator = Coordinator(router:router,enrollmentFile:directory.appendingPathComponent("unused-enrollments.json"),startBackgroundWork:false)
        defer {coordinator.storageQueue.sync {};coordinator.queue.sync {};try? router.closeStore()}
        let caller = Caller(role:"owner",installation:"operation-service-fixture",projectIDs:[]),command = UUID().uuidString
        let reply = try router.handle(method:"backup_create",params:["command_id":command,"path":directory.appendingPathComponent("backup").path],caller:caller)
        XCTAssertEqual(reply["command_outcome"] as? String,"accepted")
        let receipt = try XCTUnwrap(reply["data"] as? [String:Any]),id = try XCTUnwrap(receipt["operation_id"] as? String)
        XCTAssertEqual(receipt["status_method"] as? String,"operation_get")
        coordinator.storageQueue.sync {};coordinator.queue.sync {}
        let status = try router.handle(method:"operation_get",params:["operation_id":id],caller:caller)["data"] as! [String:Any]
        XCTAssertEqual(status["state"] as? String,"succeeded")
        let result = try XCTUnwrap(status["result"] as? [String:Any])
        XCTAssertEqual(result["command_id"] as? String,command)
        XCTAssertEqual((result["data"] as? [String:Any])?["status"] as? String,"complete")
    }
}
