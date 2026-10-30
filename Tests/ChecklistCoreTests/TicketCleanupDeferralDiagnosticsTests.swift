import ChecklistTestSupport
import Darwin
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class TicketCleanupDeferralDiagnosticsTests: XCTestCase {
    func testRetentionObservationAtRealDescriptorLimitPreservesErrnoAndReleasesRoot() throws {
        let fixture = try StorageFixture(fast:true)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:fixture.root))
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&original),0)
        guard original.rlim_max >= 256 else {throw XCTSkip("A hard descriptor limit of at least 256 is required.")}
        var limited = original;limited.rlim_cur = 256
        var padding: [Int32] = []
        defer {
            _ = setrlimit(RLIMIT_NOFILE,&original)
            for descriptor in padding {Darwin.close(descriptor)}
        }
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE,&limited),0)
        func openCount() -> Int {(0..<256).filter {fcntl(Int32($0),F_GETFD) >= 0}.count}
        while openCount() < 255 {
            let descriptor = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {throw CoreError("TEST_PADDING_FAILED","Could not establish descriptor pressure.",details:["posix_errno":errno])}
            padding.append(descriptor)
        }
        let baseline = openCount()
        for _ in 0..<2 {
            XCTAssertThrowsError(try StorageSnapshotRetention.isActive(root:fixture.root)) {error in
                let failure = error as? CoreError
                XCTAssertEqual(failure?.code,"BACKUP_HOLD_UNAVAILABLE")
                XCTAssertEqual(failure?.details["operation"] as? String,"open_snapshot_retention")
                XCTAssertEqual((failure?.details["posix_errno"] as? NSNumber)?.int32Value,EMFILE)
            }
            XCTAssertEqual(openCount(),baseline,"A failed barrier open must release its duplicated store root.")
        }
        for descriptor in padding {Darwin.close(descriptor)}
        padding.removeAll()
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:fixture.root),"The next observation succeeds after descriptor headroom returns.")
        print("CL369_RETENTION_FD soft=256 pressure_baseline=\(baseline) repeated_failures=2 errno=\(EMFILE) retry=available")
    }

    func testPreparationPersistsPOSIXCauseBehindGenericDeferral() throws {
        let fixture = try StorageFixture(fast:true),project = try fixture.project(),router = fixture.router!
        let projectID = project["id"] as! String
        XCTAssertThrowsError(try router.withTicketCleanupPreparation({_ -> TicketCleanupPreparedPass? in
            try router.beginTicketCleanupPreparation(project:projectID)
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(EMFILE))
        }) {_,_,_ in XCTFail("A failed preparation cannot commit")})
        let state = try router.dbQueue.read {try router.ticketCleanupPreparationState($0,project:projectID)}
        XCTAssertEqual(state["state"] as? String,"deferred")
        XCTAssertEqual(state["last_failure_reason"] as? String,"CLEANUP_PREPARATION_UNAVAILABLE")
        let failure = try XCTUnwrap(state["last_failure"] as? JSON)
        XCTAssertEqual(failure["code"] as? String,"CLEANUP_PREPARATION_UNAVAILABLE")
        XCTAssertEqual(failure["error_domain"] as? String,NSPOSIXErrorDomain)
        XCTAssertEqual((failure["posix_errno"] as? NSNumber)?.int32Value,EMFILE)
        XCTAssertNotNil(state["next_attempt_at"] as? String)
    }

    func testReadLaneDeferralRetainsSQLiteEngineIdentity() throws {
        let fixture = try StorageFixture(fast:true),project = try fixture.project(),router = fixture.router!
        let projectID = project["id"] as! String
        XCTAssertThrowsError(try router.withTicketCleanupPreparation({db -> TicketCleanupPreparedPass? in
            try router.beginTicketCleanupPreparation(project:projectID)
            try db.execute(sql:"SELECT * FROM deliberately_missing_cleanup_table")
            return nil
        }) {_,_,_ in XCTFail("A failed read cannot commit")}) {error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_READ_LANE_UNAVAILABLE")
        }
        let state = try router.dbQueue.read {try router.ticketCleanupPreparationState($0,project:projectID)}
        XCTAssertEqual(state["last_failure_reason"] as? String,"CLEANUP_READ_LANE_UNAVAILABLE")
        let failure = try XCTUnwrap(state["last_failure"] as? JSON)
        XCTAssertEqual(failure["code"] as? String,"CLEANUP_READ_LANE_UNAVAILABLE")
        XCTAssertEqual((failure["sqlite_result_code"] as? NSNumber)?.int32Value,1)
        XCTAssertEqual((failure["sqlite_extended_result_code"] as? NSNumber)?.int32Value,1)
    }
}
