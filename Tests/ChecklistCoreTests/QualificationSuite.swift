import XCTest
import Foundation

/// Scale, timing and soak coverage. Kept in its original test classes so all
/// fixture helpers and assertions remain identical to the ordinary test build.
enum QualificationSuite {
    static func requireEnabled() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1" else {
            throw XCTSkip("Qualification suite: run script/affected_tests.py --full --qualification")
        }
    }
}
