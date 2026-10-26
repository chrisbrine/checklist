import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

final class RequestStoredRecordTests: XCTestCase {
    func testMalformedTaskHandlerScopeReturnsCanonicalError() throws {
        try withRouter { router in
            let malformed: [JSON] = [["id": "ticket"], ["project_id": "project"], ["id": true, "project_id": "project"]]
            for task in malformed {
                XCTAssertThrowsError(try router.dbQueue.read { try router.ordinaryHandlerRecipients($0, task: task) }) {
                    self.assertMalformed($0)
                }
            }
        }
    }

    func testMalformedHumanResponseScopeReturnsCanonicalError() throws {
        try withRouter { router in
            let caller = Caller(role: "owner", installation: "stored-request-tests", projectIDs: [])
            XCTAssertThrowsError(try router.dbQueue.read {
                try router.notifyHumanResponse($0, request: ["project_id": NSNull()], response: [:], caller: caller)
            }) { self.assertMalformed($0) }
        }
    }

    func testMalformedOrdinaryMessageScopeReturnsCanonicalErrorWithinTransaction() throws {
        try withRouter { router in
            XCTAssertThrowsError(try router.dbQueue.write {
                try router.queueOrdinaryDeliveries($0, message: ["project_id": "project", "id": 7], recipients: [])
            }) { self.assertMalformed($0) }
        }
    }

    private func assertMalformed(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? CoreError)?.code, "CANONICAL_RECORD_INVALID", file: file, line: line)
        XCTAssertFalse(error.localizedDescription.contains("project"), file: file, line: line)
    }

    private func withRouter(_ body: (CommandRouter) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try TestStore.router(root: root)
        defer { try? router.closeStore() }
        try body(router)
    }
}
