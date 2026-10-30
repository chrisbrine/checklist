import XCTest
import ChecklistMCPServer
@testable import ChecklistCLI

final class CLIStartupTests: XCTestCase {
    func testOneShotCommandsDoNotReadSigningOrReplacementState() {
        for command in [nil, "call", "connect", "tools", "service", "help", "--help", "-h", "version", "--version", "unknown"] as [String?] {
            var captures = 0
            let result = CLIStartup.shimUpdate(for: command) { captures += 1; return self.fixture() }
            XCTAssertNil(result, "command: \(command ?? "nil")")
            XCTAssertEqual(captures, 0, "command: \(command ?? "nil")")
        }
    }

    func testMCPCapturesExactlyOnceBeforeDiscoveryAndRetainsMonitoring() throws {
        var captures = 0
        let result = try XCTUnwrap(CLIStartup.shimUpdate(for: "mcp") { captures += 1; return self.fixture() })
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(result.launchPath, "/synthetic/checklist")
        if case .replaced = result.check(false) {} else { XCTFail("MCP replacement monitoring was lost") }
    }

    private func fixture() -> ShimUpdateEnvironment {
        .init(launchPath: "/synthetic/checklist", check: { _ in .replaced }, run: { _,_ in
            XCTFail("Startup selection must never launch another process")
            return .init(status: 1, stdout: Data())
        })
    }
}
