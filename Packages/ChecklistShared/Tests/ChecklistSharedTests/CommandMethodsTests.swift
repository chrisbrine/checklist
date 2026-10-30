import XCTest
import ChecklistContracts

final class CommandMethodsTests: XCTestCase {
    func testServiceAddsOnlyItsConnectionAndHandoffReads() {
        XCTAssertEqual(CommandMethods.serviceReads.subtracting(CommandMethods.coreReads),
                       ["connection_list", "task_handoff_prepare"])
        XCTAssertTrue(CommandMethods.coreReads.isSubset(of: CommandMethods.serviceReads))
    }

    func testMediaClassificationIsSubsetOfBothDispatchReadSets() {
        XCTAssertFalse(CommandMethods.mediaOwnerReads.isEmpty)
        XCTAssertTrue(CommandMethods.mediaOwnerReads.isSubset(of: CommandMethods.coreReads))
        XCTAssertTrue(CommandMethods.mediaOwnerReads.isSubset(of: CommandMethods.serviceReads))
        XCTAssertTrue(CommandMethods.mediaOwnerReads.contains("media_example_read_release"))
    }

    func testInternalMediaReadClassificationRetainsItsDistinctDispatchSet() {
        XCTAssertEqual(CommandMethods.mediaInternalReads, [
            "media_type_get", "media_round_get", "media_intake_get", "media_bulk_get",
            "media_item_page", "media_item_counts", "media_approved_examples",
        ])
        XCTAssertEqual(CommandMethods.mediaInternalReads.subtracting(CommandMethods.mediaOwnerReads),
                       ["media_round_get"])
        for method in ["media_navigation", "media_original_read", "media_example_read_lease", "media_example_read_release"] {
            XCTAssertTrue(CommandMethods.mediaOwnerReads.contains(method))
            XCTAssertFalse(CommandMethods.mediaInternalReads.contains(method))
        }
    }

    func testCaptureIsMutationAndReviewPreparationRetainsReadClassification() {
        for reads in [CommandMethods.coreReads, CommandMethods.serviceReads] {
            XCTAssertFalse(reads.contains("task_create"))
            XCTAssertTrue(reads.contains("review_prepare"))
        }
        XCTAssertFalse(CommandMethods.coreReads.contains("connection_list"))
        XCTAssertFalse(CommandMethods.coreReads.contains("task_handoff_prepare"))
    }
}
