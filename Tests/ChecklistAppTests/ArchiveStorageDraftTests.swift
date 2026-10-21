import XCTest
@testable import ChecklistApp

final class ArchiveStorageDraftTests: XCTestCase {
    func testDefaultsAndBytePrecisionRoundTripWithoutRounding() throws {
        let defaults = ArchiveStorageDraft()
        XCTAssertEqual((defaults.value?["large_original_bytes"] as? NSNumber)?.int64Value,20 * 1_048_576)
        let draft = ArchiveStorageDraft(["preset":"keep_originals","large_original_bytes":Int64(1_048_577),"retained_budget_bytes":Int64(0)])
        XCTAssertEqual(draft.unit,1);XCTAssertEqual(draft.threshold,"1048577")
        XCTAssertEqual(draft.preset,"keep_originals")
        XCTAssertEqual((draft.value?["large_original_bytes"] as? NSNumber)?.int64Value,1_048_577)
        XCTAssertEqual((draft.value?["retained_budget_bytes"] as? NSNumber)?.int64Value,0)
    }
    func testInvalidAndOverflowingEditsCannotBecomeCanonicalSettings() {
        for text in ["", "0", "-1", "1.5", " 20", "20 ", "１", "9223372036854775808"] {
            var draft = ArchiveStorageDraft();draft.threshold = text
            XCTAssertNil(draft.value,text)
        }
        var draft = ArchiveStorageDraft();draft.threshold = String(Int64.max)
        XCTAssertNil(draft.value)
        draft.unit = 1;XCTAssertNotNil(draft.value)
        draft.budget = "-1";XCTAssertNil(draft.value)
        draft.budget = "0";draft.preset = "unknown";XCTAssertNil(draft.value)
    }
}
