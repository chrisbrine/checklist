import XCTest
import GRDB
@testable import ChecklistCore

final class PlatformStorageAdapterTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testUsesAlreadyOpenedQueueAndReturnsValues() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE fixture(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO fixture VALUES ('before adaptation')")
        }
        let storage: any TransactionStorage = GRDBTransactionAdapter(queue: queue)

        XCTAssertEqual(try storage.read { try String.fetchOne($0, sql: "SELECT value FROM fixture") }, "before adaptation")
        let changed = try storage.write { db in
            try db.execute(sql: "UPDATE fixture SET value = 'same queue'")
            return db.changesCount
        }
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT value FROM fixture") }, "same queue")
        // A nonthrowing closure retains writeWithoutTransaction's rethrows API.
        XCTAssertEqual(storage.writeWithoutTransaction { _ in 42 }, 42)
    }

    func testWriteRollsBackAllChangesOnClosureFailure() throws {
        let storage: any TransactionStorage = GRDBTransactionAdapter(queue: try DatabaseQueue())
        try storage.write { try $0.execute(sql: "CREATE TABLE fixture(value TEXT NOT NULL)") }

        XCTAssertThrowsError(try storage.write { db in
            try db.execute(sql: "INSERT INTO fixture VALUES ('first')")
            try db.execute(sql: "INSERT INTO fixture VALUES ('second')")
            throw Failure.injected
        }) { error in
            guard case Failure.injected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try storage.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") }, 0)
    }

    func testWriteWithoutTransactionDoesNotAddImplicitRollback() throws {
        let storage: any TransactionStorage = GRDBTransactionAdapter(queue: try DatabaseQueue())
        try storage.write { try $0.execute(sql: "CREATE TABLE fixture(value TEXT NOT NULL)") }

        XCTAssertThrowsError(try storage.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO fixture VALUES ('committed before failure')")
            throw Failure.injected
        }) { error in
            guard case Failure.injected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try storage.read { try String.fetchOne($0, sql: "SELECT value FROM fixture") }, "committed before failure")
    }

    func testReadCannotAcquireWriteAuthorityAndCloseClosesOwnedQueue() throws {
        let queue = try DatabaseQueue()
        let storage: any TransactionStorage = GRDBTransactionAdapter(queue: queue)
        try storage.write { try $0.execute(sql: "CREATE TABLE fixture(value TEXT NOT NULL)") }

        XCTAssertThrowsError(try storage.read { try $0.execute(sql: "INSERT INTO fixture VALUES ('forbidden')") })
        XCTAssertEqual(try storage.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") }, 0)
        try storage.close()
        XCTAssertThrowsError(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") })
        XCTAssertThrowsError(try storage.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") })
    }
}
