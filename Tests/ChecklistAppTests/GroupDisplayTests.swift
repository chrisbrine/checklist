import XCTest
@testable import ChecklistApp

final class GroupDisplayTests: XCTestCase {
    func testGroupLabelsIncludeKeyAndDefensivelyFallBackToName() {
        XCTAssertEqual(ProductionGroups.label(Record(values:["id":"g","key":"CL-T7","name":"Fixes"])),"CL-T7 Fixes")
        XCTAssertEqual(ProductionGroups.label(Record(values:["id":"e","key":"CL-E3","name":"Assets"])),"CL-E3 Assets")
        XCTAssertEqual(ProductionGroups.label(Record(values:["id":"old","name":"Legacy"])),"Legacy")
    }
}
