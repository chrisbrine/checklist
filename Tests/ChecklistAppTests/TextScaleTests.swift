import XCTest
@testable import ChecklistApp

final class TextScaleTests: XCTestCase {
    func testScaleUsesSupportedStepsAndRejectsInvalidPreferences() {
        XCTAssertEqual(TextScale.normalized(1.49), 1.5)
        XCTAssertEqual(TextScale.normalized(-10), 0.85)
        XCTAssertEqual(TextScale.normalized(100), 2)
        for invalid in [Double.nan, .infinity, -.infinity] { XCTAssertEqual(TextScale.normalized(invalid), 1) }
    }
    func testEveryStepCanBeReachedAndCommandsClampAtBothEnds() {
        var value = 0.85
        for expected in TextScale.steps.dropFirst() {
            value = TextScale.stepping(value, by: 1)
            XCTAssertEqual(value, expected)
        }
        XCTAssertEqual(TextScale.stepping(value, by: 1), 2)
        for expected in TextScale.steps.dropLast().reversed() {
            value = TextScale.stepping(value, by: -1)
            XCTAssertEqual(value, expected)
        }
        XCTAssertEqual(TextScale.stepping(value, by: -1), 0.85)
    }
}
