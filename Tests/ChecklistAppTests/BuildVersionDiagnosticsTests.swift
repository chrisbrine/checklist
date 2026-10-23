import XCTest
@testable import ChecklistApp

final class BuildVersionDiagnosticsTests: XCTestCase {
    func testDiagnosticsUsesTheFullBundledVersionAndPreservesAppleOrdinal() throws {
        let report = DiagnosticsExport.report(buildMetadata: ["version": "0.0.1.1", "build_id": "0123456789abcdef"], appVersion: "0.0.1", bundleVersion: "118", serviceSummary: ["service": ["version": "0.0.1.1", "state": "responsive"]], recentErrors: [])
        XCTAssertEqual(report.versions.app, "0.0.1.1")
        XCTAssertEqual(report.versions.bundle, "118")
        XCTAssertEqual(report.versions.buildID, "0123456789abcdef")
        XCTAssertEqual(report.service.version, report.versions.app)
    }
}
