import ChecklistTestSupport
import Foundation
import XCTest
@testable import ChecklistCore

final class AuthorityStoredRecordTests: XCTestCase {
    private var directory: URL!
    private var router: CommandRouter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        router = try TestStore.router(root: directory)
    }

    override func tearDownWithError() throws {
        router = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func assertMalformed(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? CoreError)?.code, "CANONICAL_RECORD_INVALID", file: file, line: line)
        }
    }

    func testMalformedReferenceProjectIdentityThrows() throws {
        try router.dbQueue.read { db in
            let malformedRecords: [JSON] = [[:], ["project_id": NSNull()], ["project_id": true], ["project_id": 1]]
            for malformed in malformedRecords {
                assertMalformed { _ = try self.router.agentReference(db, malformed) }
                assertMalformed { _ = try self.router.subject(db, message: malformed) }
            }
        }
    }

    func testMalformedScopeIdentityThrowsInsteadOfTrapping() {
        let parent: JSON = ["file_scopes": [["access": "write", "canonical_key": "/synthetic"]]]
        let malformedKeys: [Any] = [NSNull(), true, 1]
        for malformed in malformedKeys {
            let file: JSON = ["access": "write", "canonical_key": malformed]
            assertMalformed { try self.router.requireBoundedScopes([file], lanes: [], parent: parent) }
        }
        assertMalformed {
            try self.router.requireBoundedScopes(
                [["access": "write", "canonical_key": "/synthetic/child"]], lanes: [],
                parent: ["file_scopes": [["access": "write"]]]
            )
        }
    }

    func testUnknownScopeFieldsRetainLegacyEligibility() throws {
        let parent: JSON = ["file_scopes": [["access": "write", "canonical_key": "/synthetic", "future": true]]]
        try router.requireBoundedScopes(
            [["access": "read", "canonical_key": "/synthetic/child", "future": NSNull()]],
            lanes: [], parent: parent
        )
    }
    func testNativeAttemptOrderingRejectsMalformedIdentity() {
        let malformedRecords: [JSON] = [[:], ["id": NSNull()], ["id": true], ["id": 1]]
        for malformed in malformedRecords {
            assertMalformed { _ = try self.router.nativeAttemptsDeepestFirst([malformed]) }
        }
    }

    func testNativeAttemptOrderingRejectsDuplicateParentIdentities() {
        let child: JSON = ["id": "child", "parent_attempt_id": "parent"]
        assertMalformed { _ = try self.router.nativeAttemptsDeepestFirst([child, child]) }
    }

    func testNativeAttemptOrderingRetainsDescendantFirstAndUnknownFields() throws {
        let parent: JSON = ["id": "parent", "future": NSNull()]
        let child: JSON = ["id": "child", "parent_attempt_id": "parent", "future": true]
        let ordered = try router.nativeAttemptsDeepestFirst([parent, child])
        XCTAssertEqual(ordered.compactMap { $0["id"] as? String }, ["child", "parent"])
        XCTAssertEqual(ordered[0]["future"] as? Bool, true)
        XCTAssertTrue(ordered[1]["future"] is NSNull)
    }

}
