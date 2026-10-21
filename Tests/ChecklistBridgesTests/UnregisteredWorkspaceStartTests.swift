import XCTest
@testable import ChecklistBridges

final class UnregisteredWorkspaceStartTests: XCTestCase {
    let code = "PROJECT_SETUP_REQUIRED"

    func testServiceCodeIsUnchanged() {
        // Coordinator.bootstrap throws this code for a folder with no active project.
        XCTAssertEqual(UnregisteredWorkspaceStart.errorCode, code)
    }

    func testMCPAndToolDiscoveryStartLimited() {
        XCTAssertTrue(UnregisteredWorkspaceStart.applies(errorCode: code, command: "mcp", assistantRelay: false))
        XCTAssertTrue(UnregisteredWorkspaceStart.applies(errorCode: code, command: "tools", assistantRelay: false))
    }

    func testExplicitConnectionCommandsStayStrict() {
        for command in ["connect", "call", "service", "help", ""] {
            XCTAssertFalse(UnregisteredWorkspaceStart.applies(errorCode: code, command: command, assistantRelay: false), command)
        }
    }

    func testAssistantRelayStaysStrict() {
        XCTAssertFalse(UnregisteredWorkspaceStart.applies(errorCode: code, command: "mcp", assistantRelay: true))
        XCTAssertFalse(UnregisteredWorkspaceStart.applies(errorCode: code, command: "tools", assistantRelay: true))
    }

    func testOtherBootstrapFailuresStillStopStartup() {
        let codes = ["CONNECTION_REVOKED", "BINDING_CHANGED", "WORKSPACE_MISMATCH", "NATIVE_ROUTE_MISMATCH",
                     "NATIVE_SESSION_MISMATCH", "NATIVE_SESSION_REQUIRED", "NATIVE_CLIENT_REQUIRED", "SESSION_ID_CONFLICT",
                     "CONNECTION_REPAIR_REQUIRED", "CONNECTION_MODE_MISMATCH", "INVALID_CONNECTION_MODE", "AMBIGUOUS_PROJECT",
                     "PROJECT_REQUIRED", "SETUP_REQUIRED", "SERVICE_SETUP_REQUIRED", "SERVICE_UNAVAILABLE", "OUTCOME_UNKNOWN",
                     "project_setup_required", "PROJECT_SETUP_REQUIRED_X", ""]
        for other in codes {
            XCTAssertFalse(UnregisteredWorkspaceStart.applies(errorCode: other, command: "mcp", assistantRelay: false), other)
            XCTAssertFalse(UnregisteredWorkspaceStart.applies(errorCode: other, command: "tools", assistantRelay: false), other)
        }
    }

    func testNoticeNamesFolderAndSetupStep() {
        let notice = UnregisteredWorkspaceStart.notice(workspace: "/tmp/Unregistered Game")
        XCTAssertTrue(notice.hasPrefix(code + ":"))
        XCTAssertTrue(notice.contains("/tmp/Unregistered Game"))
        XCTAssertTrue(notice.contains("Only service_info is available"))
        XCTAssertTrue(notice.contains("add this folder as a project in the Checklist app"))
        XCTAssertFalse(notice.contains("\n"))
    }
}
