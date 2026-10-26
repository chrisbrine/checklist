import XCTest
import GRDB
@testable import ChecklistCore

final class StorageDeadlineReadTests: XCTestCase {
    func testForegroundCleanupAdmissionReadsOnlyIndexedJobFamily() throws {
        let f = try ReadPerformanceFixture("CL-283-cleanup-admission"), router = f.router
        var statements: [String] = []
        try router.dbQueue.writeWithoutTransaction { db in
            db.trace { if case .statement(let statement) = $0 { statements.append(statement.expandedSQL) } }
        }
        _ = try f.call("project_create",["name":"Indexed admissions","key_prefix":"IA"])
        try router.dbQueue.writeWithoutTransaction { $0.trace(options:[]) }
        let admission = try XCTUnwrap(statements.first { $0.contains("SELECT j.id FROM records j LEFT JOIN records c") })
        try router.dbQueue.read { db in
            let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + admission).map { $0["detail"] as String }
            XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX records_scope") },plan.joined(separator:"\n"))
            XCTAssertTrue(plan.contains { $0.contains("SEARCH j USING INTEGER PRIMARY KEY") },plan.joined(separator:"\n"))
        }
    }

    func testDeadlineDiscoveryReadsOnlyIndexedRecordFamilies() throws {
        let f = try ReadPerformanceFixture("CL-281-deadline-families"), router = f.router
        _ = try f.call("project_create",["name":"Indexed deadlines","key_prefix":"ID"])
        let readers = try XCTUnwrap(router.readers)
        var statements: [String] = []
        try readers.read { db in
            db.trace { if case .statement(let statement) = $0 { statements.append(statement.sql) } }
        }
        _ = try router.nextArchiveCleanupDeadline()
        try readers.read { $0.trace(options:[]) }
        let metadata = statements.filter { $0.contains("json_valid") }
        XCTAssertEqual(metadata.count,4)
        try readers.read { db in
            for sql in metadata {
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql,arguments:sql.contains("expires_at") ? [Date().timeIntervalSince1970] : [])
                XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("COVERING INDEX records_scope") })
                XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("INTEGER PRIMARY KEY") })
            }
        }
    }

    func testDeadlineMetadataReadDoesNotJoinHeldWriterAndKeepsRetryFloor() throws {
        let f = try ReadPerformanceFixture("CL-283-deadline"), router = f.router
        _ = try f.call("project_create",["name":"Deadline fixture","key_prefix":"DL"])
        let floor = Date(timeIntervalSince1970:(Date().timeIntervalSince1970 + 120).rounded(.up))
        router.ticketCleanupRetryAt = floor
        let held = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"writer released")
        let lock = NSLock()
        var holding = false
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            do {
                try router.dbQueue.writeWithoutTransaction { _ in
                    lock.lock();holding = true;lock.unlock();held.signal()
                    _ = resume.wait(timeout:.now()+10)
                    lock.lock();holding = false;lock.unlock()
                }
            } catch {XCTFail("\(error)")}
        }
        defer {resume.signal()}
        XCTAssertEqual(held.wait(timeout:.now()+10),.success)
        let deadline = try XCTUnwrap(router.nextArchiveCleanupDeadline())
        lock.lock();XCTAssertTrue(holding,"Deadline discovery must use the read pool rather than wait for the writer");lock.unlock()
        XCTAssertGreaterThanOrEqual(deadline,floor)
        resume.signal();wait(for:[finished],timeout:10)
    }
}


extension StorageDeadlineReadTests {
    func testDeadlineReadParticipatesInDrainAndNewReadsStayFenced() throws {
        let f = try ReadPerformanceFixture("CL-283-deadline-drain"), router = f.router
        let readers = try XCTUnwrap(router.readers)
        let started = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"deadline read released")
        let lock = NSLock()
        var failure: Error?
        var gated = false
        try readers.read { db in
            db.trace(options:.profile) { event in
                if case .profile(let statement, _) = event, statement.sql.contains("SELECT MIN"), !gated {
                    gated = true;started.signal()
                    _ = resume.wait(timeout:.now()+10)
                }
            }
        }
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            do {_ = try router.nextArchiveCleanupDeadline()}
            catch {lock.lock();failure = error;lock.unlock();started.signal()}
        }
        defer {resume.signal()}
        XCTAssertEqual(started.wait(timeout:.now()+10),.success)
        let drain = try router.beginStorageDrain(caller:f.owner)
        defer {try? router.cancelStorageDrain(drain,caller:f.owner)}
        XCTAssertFalse(try router.waitForStorageDrain(drain,timeout:0,caller:f.owner))
        XCTAssertThrowsError(try router.nextArchiveCleanupDeadline()) { error in
            XCTAssertEqual((error as? CoreError)?.code,"STORAGE_DRAINING")
        }
        resume.signal();wait(for:[finished],timeout:10)
        lock.lock();XCTAssertNil(failure);lock.unlock()
        XCTAssertTrue(try router.waitForStorageDrain(drain,timeout:0,caller:f.owner))
        try readers.read {$0.trace(options:[])}
    }
}
