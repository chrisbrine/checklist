import XCTest
import Foundation
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class ServiceRouteTimingTests: XCTestCase {
    func testRouteTimingPreservesAuthenticationFailureAndRecordsCompletedPhase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        let coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
        defer {connection.invalidate()}
        let request: [String:Any] = ["method":"task_get","installation":"missing","credential":"synthetic"]
        let timing = ServiceCallTiming()
        for diagnostic in [nil,timing] {
            XCTAssertThrowsError(try coordinator.route(request,connection:connection,timing:diagnostic)) { error in
                XCTAssertEqual((error as? ChecklistError)?.code,"SETUP_REQUIRED")
            }
        }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with:timing.encode(["error":["code":"SETUP_REQUIRED"]])) as? [String:Any])
        let fields = try XCTUnwrap(result["_checklist_timing"] as? [String:Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fields["route_lifecycle_ms"] as? Double),0)
        XCTAssertNil(fields["route_native_identity_ms"])
        XCTAssertNil(fields["route_current_session_ms"])
        XCTAssertNil(fields["route_registration_receipt_ms"])
        XCTAssertEqual((result["error"] as? [String:Any])?["code"] as? String,"SETUP_REQUIRED")
    }
}
