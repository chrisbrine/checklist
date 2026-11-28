import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class MaintenanceWriterAdmissionTests: XCTestCase {
    func testForegroundArrivalDuringReservationCannotMakeMaintenanceWaitBehindIt() throws {
        let reserved = DispatchSemaphore(value:0), enterMaintenance = DispatchSemaphore(value:0)
        let waiting = DispatchSemaphore(value:0), enteredWriter = DispatchSemaphore(value:0)
        let releaseWriter = DispatchSemaphore(value:0), maintenanceFinished = DispatchSemaphore(value:0)
        let adapter = GRDBTransactionAdapter(queue:try DatabaseQueue(),beforeMaintenanceEntry:{
            reserved.signal()
            _ = enterMaintenance.wait(timeout:.now()+10)
        },beforeForegroundWait:{waiting.signal()})
        let maintenance = DispatchQueue(label:"test.maintenance-writer-entry")
        let foreground = DispatchQueue(label:"test.foreground-writer-entry")
        defer {
            enterMaintenance.signal()
            releaseWriter.signal()
            maintenance.sync {}
            foreground.sync {}
            try? adapter.close()
        }
        maintenance.async {
            defer {maintenanceFinished.signal()}
            do {
                let result = try adapter.tryMaintenanceWrite(label:"test-maintenance",deadline:.init(seconds:10)) { _,_ in
                    XCTFail("A reservation must yield to a queued foreground writer.")
                    return true
                }
                XCTAssertNil(result)
            } catch {XCTFail("Unexpected maintenance error: \(error)")}
        }
        guard reserved.wait(timeout:.now()+5) == .success else {return XCTFail("Maintenance did not reserve a turn.")}
        foreground.async {
            adapter.writeWithoutTransaction { _ in
                enteredWriter.signal()
                _ = releaseWriter.wait(timeout:.now()+10)
            }
        }
        guard waiting.wait(timeout:.now()+5) == .success else {return XCTFail("Foreground write did not reach admission.")}
        XCTAssertEqual(enteredWriter.wait(timeout:.now()),.timedOut)
        enterMaintenance.signal()
        XCTAssertEqual(enteredWriter.wait(timeout:.now()+5),.success)
        XCTAssertEqual(maintenanceFinished.wait(timeout:.now()+5),.success)
    }
}
