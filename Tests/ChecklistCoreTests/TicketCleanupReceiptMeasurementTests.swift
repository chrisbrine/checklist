import XCTest
import GRDB
@testable import ChecklistCore

/// Opt-in measurement uses only an explicitly supplied owned store copy.
final class TicketCleanupReceiptMeasurementTests: XCTestCase {
    func testOwnedStoreReceiptRead() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_RECEIPT_MEASURE_ROOT"],
              let projectID = ProcessInfo.processInfo.environment["CHECKLIST_RECEIPT_MEASURE_PROJECT_ID"] else {throw XCTSkip("Requires an owned store copy and its project ID")}
        let router = try CommandRouter(root:URL(fileURLWithPath:path))
        defer {try? router.closeStore()}
        let owner = Caller(role:"owner",installation:"receipt-measurement",projectIDs:[])
        for run in 1...3 {
            let start = ProcessInfo.processInfo.systemUptime
            let reply = try router.handle(method:"ticket_cleanup_receipts",params:["project_id":projectID],caller:owner)
            let service = ProcessInfo.processInfo.systemUptime-start
            let bytes = try JSONSerialization.data(withJSONObject:reply,options:[.sortedKeys]).count
            if let page = reply["data"] as? JSON,page["limit"] != nil {
                XCTAssertLessThan(service,1);XCTAssertLessThanOrEqual(bytes,256*1024)
                for value in page["receipts"] as? [JSON] ?? [] {
                    let original = try router.dbQueue.read {db in try router.ticketCleanupPassProjection(db,receipt:router.record(db,value["id"] as! String,type:"storage_job"))}
                    XCTAssertEqual(try jsonString(value["summary"]!),try jsonString(original["summary"]!))
                    XCTAssertEqual(value["bytes_state"] as? String,original["bytes_state"] as? String)
                }
            }
            print("CL260 run=\(run) service_seconds=\(service) response_bytes=\(bytes)")
        }
    }
}
