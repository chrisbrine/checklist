import ChecklistTestSupport
import Foundation
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testBatchContextRejectsMalformedStoredMemberIdentifiers() throws {
        for member: JSON in [[:], ["task_id":NSNull()], ["task_id":42], ["task_id":true]] {
            assertCode("CANONICAL_RECORD_INVALID") {
                _ = try BatchClaimContext(batch:["members":[member]])
            }
        }
    }

    func testBatchContextRejectsDuplicateStoredMemberIdentifiers() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try BatchClaimContext(batch:["members":[["task_id":"same"],["task_id":"same"]]])
        }
    }

    func testBatchContextRetainsUnknownFieldsAndLegacyAbsentMembers() throws {
        let value: JSON = ["members":[["task_id":"one","future":NSNull()],["task_id":"two"]],"future_flag":true]
        let context = try BatchClaimContext(batch:value)
        XCTAssertEqual(Set(context.attemptIDs.keys),Set(["one","two"]))
        XCTAssertEqual(Set(context.attemptIDs.values).count,2)
        XCTAssertEqual(try jsonString(context.batch),try jsonString(value))
        for value: JSON in [[:],["members":NSNull()],["members":"legacy"]] {
            XCTAssertTrue(try BatchClaimContext(batch:value).attemptIDs.isEmpty)
        }
    }

    func testBatchRelatedLookupRejectsMalformedStoredIdentity() throws {
        for value: JSON in [[:],["project_id":true,"id":"batch"],["project_id":"project","id":NSNull()]] {
            assertCode("CANONICAL_RECORD_INVALID") {
                _ = try self.router.dbQueue.read { try self.router.batchRelatedRecord($0,value,type:"attempt") }
            }
        }
    }

    func testGroupTaskProjectionRejectsMalformedStoredIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try self.router.dbQueue.read { try self.router.taskTriages($0,["project_id":"project","id":false]) }
        }
    }

    func testReservationLabelRejectsMalformedStoredAttemptIdentity() throws {
        assertCode("CANONICAL_RECORD_INVALID") {
            _ = try self.router.dbQueue.read {
                try self.router.reservationTicketLabel($0,["id":"attempt","project_id":"project","task_id":NSNull()])
            }
        }
    }
}
