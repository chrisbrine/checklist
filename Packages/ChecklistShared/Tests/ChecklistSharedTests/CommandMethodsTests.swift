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

    func testCaptureIsMutationAndReviewPreparationRetainsReadClassification() {
        for reads in [CommandMethods.coreReads, CommandMethods.serviceReads] {
            XCTAssertFalse(reads.contains("task_create"))
            XCTAssertTrue(reads.contains("review_prepare"))
        }
        XCTAssertFalse(CommandMethods.coreReads.contains("connection_list"))
        XCTAssertFalse(CommandMethods.coreReads.contains("task_handoff_prepare"))
    }
}
