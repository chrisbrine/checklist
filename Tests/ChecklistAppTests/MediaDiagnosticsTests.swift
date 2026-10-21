import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

final class MediaDiagnosticsTests: XCTestCase {
    func testEveryRegisteredMediaFamilySurvivesTheClosedDiagnosticsProjection() {
        XCTAssertTrue(MediaRecordRegistry.families.isSubset(of:DiagnosticsExport.countKeys))
        let counts = Dictionary(uniqueKeysWithValues:MediaRecordRegistry.families.map { ($0,1) })
        let report = DiagnosticsExport.report(buildMetadata:[:],appVersion:nil,bundleVersion:nil,
            serviceSummary:["service":["state":"responsive"],"record_counts":counts],recentErrors:[])
        for type in MediaRecordRegistry.families { XCTAssertEqual(report.recordCounts[type],1) }
        XCTAssertNil(report.recordCounts["future_media_family"])
    }
}
