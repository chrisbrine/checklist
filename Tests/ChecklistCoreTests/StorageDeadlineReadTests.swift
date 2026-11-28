import XCTest
import GRDB
@testable import ChecklistCore

final class StorageDeadlineReadTests: XCTestCase {
    func testBackgroundCleanupAdmissionReadsOnlyIndexedJobFamily() throws {
        let f = try ReadPerformanceFixture("CL-283-cleanup-admission"), router = f.router
        let statements = LockedTestState<[String]>([])
        router.dbQueue.writeWithoutTransaction { db in
            db.trace { if case .statement(let statement) = $0 { statements.withLock { $0.append(statement.expandedSQL) } } }
        }
        _ = try f.call("project_create",["name":"Indexed admissions","key_prefix":"IA"])
        router.dbQueue.writeWithoutTransaction { $0.trace(options:[]) }
        XCTAssertFalse(statements.snapshot.contains { $0.contains("SELECT j.id FROM records j LEFT JOIN records c") })

        let readers = try XCTUnwrap(router.readers)
        try readers.read { db in
            db.trace { if case .statement(let statement) = $0 { statements.withLock { $0.append(statement.expandedSQL) } } }
        }
        defer {try? readers.read { $0.trace(options:[]) }}
        try router.runArchiveStorageMaintenance()
        let admission = try XCTUnwrap(statements.snapshot.first { $0.contains("SELECT j.id FROM records j LEFT JOIN records c") })
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
        let statements = LockedTestState<[String]>([])
        _ = try router.nextArchiveCleanupDeadline(observeRead:{ db in
            db.trace { if case .statement(let statement) = $0 { statements.withLock { $0.append(statement.expandedSQL) } } }
        })
        let metadata = statements.snapshot.filter { $0.contains("json_valid") && $0.contains("rowid IN") }
        XCTAssertEqual(metadata.count,4)
        let imports = try XCTUnwrap(statements.snapshot.first { $0.contains("'attachment_import'") && $0.contains("json_valid") })
        try readers.read { db in
            for sql in metadata {
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql)
                XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("COVERING INDEX records_scope") })
                XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("INTEGER PRIMARY KEY") })
            }
            let importPlan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + imports).map { $0["detail"] as String }
            XCTAssertTrue(importPlan.contains { $0.contains("USING INDEX records_scope") },importPlan.joined(separator:"\n"))
        }
    }

    func testDeadlineMetadataReadDoesNotJoinHeldWriterAndKeepsRetryFloor() throws {
        let f = try ReadPerformanceFixture("CL-283-deadline"), router = f.router
        _ = try f.call("project_create",["name":"Deadline fixture","key_prefix":"DL"])
        let floor = Date(timeIntervalSince1970:(Date().timeIntervalSince1970 + 120).rounded(.up))
        router.ticketCleanupRetryAt = floor
        let held = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"writer released")
        let holding = LockedTestState(false)
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            router.dbQueue.writeWithoutTransaction { _ in
                holding.withLock { $0 = true };held.signal()
                _ = resume.wait(timeout:.now()+10)
                holding.withLock { $0 = false }
            }
        }
        defer {resume.signal()}
        XCTAssertEqual(held.wait(timeout:.now()+10),.success)
        let deadline = try XCTUnwrap(router.nextArchiveCleanupDeadline())
        XCTAssertTrue(holding.snapshot,"Deadline discovery must use the read pool rather than wait for the writer")
        XCTAssertGreaterThanOrEqual(deadline,floor)
        resume.signal();wait(for:[finished],timeout:10)
    }
}


extension StorageDeadlineReadTests {
    func testDeadlineReadParticipatesInDrainAndNewReadsStayFenced() throws {
        let f = try ReadPerformanceFixture("CL-283-deadline-drain"), router = f.router
        let started = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"deadline read released")
        let failure = LockedTestState<Error?>(nil)
        let gated = LockedTestState(false)
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            do {
                _ = try router.nextArchiveCleanupDeadline(observeRead:{ db in
                    db.trace(options:.profile) { event in
                        if case .profile(let statement, _) = event, statement.sql.contains("SELECT MIN"), gated.withLock({ value in
                            if value { return false }; value = true; return true
                        }) {
                            started.signal()
                            _ = resume.wait(timeout:.now()+10)
                        }
                    }
                })
            }
            catch {failure.withLock { $0 = error };started.signal()}
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
        XCTAssertNil(failure.snapshot)
        XCTAssertTrue(try router.waitForStorageDrain(drain,timeout:0,caller:f.owner))
    }
}
