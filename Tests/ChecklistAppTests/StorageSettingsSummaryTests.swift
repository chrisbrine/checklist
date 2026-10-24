import XCTest
@testable import ChecklistApp

final class StorageSettingsSummaryTests: XCTestCase {
    func testPreviewShowsSourceCaptureTimeAndVerificationTime() {
        let rows = StorageSettingsSummary.preview(["path":"/backup","source_root":"/source-installation","store_id":"store-id","captured_at":"2026-10-23T12:34:56Z","verified_at":"2026-10-24T01:02:03Z"])
        XCTAssertEqual(rows.first {$0.label == "Source installation"}?.value,"/source-installation")
        XCTAssertEqual(rows.first {$0.label == "Captured"}?.value,"2026-10-23T12:34:56Z")
        XCTAssertEqual(rows.first {$0.label == "Verified now"}?.value,"2026-10-24T01:02:03Z")
        XCTAssertEqual(StorageSettingsSummary.preview([:]).first {$0.label == "Captured"}?.value,"Not recorded")
    }
    func testStorageSummaryKeepsLogicalAllocationAndUnknownReclamationDistinct() {
        let rows = StorageSettingsSummary.retained(["observed_copy_count":2,"unmeasured_backup_count":3,"logical_bytes_at_verification":4096,"allocated_file_bytes_at_verification":8192])
        XCTAssertEqual(rows.first {$0.label == "Measured copies"}?.value,"2")
        XCTAssertEqual(rows.first {$0.label == "Older backups without measurements"}?.value,"3")
        XCTAssertEqual(rows.first {$0.label == "Recorded logical file lengths"}?.value,StorageSettingsSummary.bytes(4096))
        XCTAssertEqual(rows.first {$0.label == "Recorded allocated file blocks"}?.value,StorageSettingsSummary.bytes(8192))
        XCTAssertEqual(rows.first {$0.label == "Exclusive physical storage"}?.value,"Not measured")
        XCTAssertEqual(rows.first {$0.label == "Space reclaimable by deletion"}?.value,"Not measured")
        XCTAssertEqual(StorageSettingsSummary.retained([:]).first {$0.label == "Recorded logical file lengths"}?.value,"Not measured")
    }
    func testLastVerificationShowsReceiptTimeAndPreservesMissingMeasurement() {
        let rows = StorageSettingsSummary.observation(["verified_at":"2026-10-23T12:34:56Z","path":"/last-verified-copy"])
        XCTAssertEqual(rows.first {$0.label == "Verified"}?.value,"2026-10-23T12:34:56Z")
        XCTAssertEqual(rows.first {$0.label == "Copy"}?.value,"/last-verified-copy")
        XCTAssertEqual(rows.first {$0.label == "Logical file lengths"}?.value,"Not measured")
        XCTAssertEqual(StorageSettingsSummary.observation(nil),[.init(label:"Verification",value:"None recorded")])
    }
}
