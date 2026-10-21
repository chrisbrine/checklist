import XCTest
@testable import ChecklistApp

final class CaptureAttachmentTests: XCTestCase {
    @MainActor func testWindowProjectStoreAndTaskDraftsStaySeparateWithStableReceiptIDs() throws {
        let a = isolatedDefaults("CaptureAttachments").preferences
        let b = isolatedDefaults("CaptureAttachments").preferences
        let destination = CaptureAttachmentDestination(storeIncarnation:"store",projectID:"project",taskID:nil)
        let file = CaptureAttachment(destination:destination,url:URL(fileURLWithPath:"/owned-selection.txt"),mode:"managed")
        CaptureAttachmentDrafts.save([file],destination:destination,preferences:a)
        let restored = try XCTUnwrap(CaptureAttachmentDrafts.load(destination,preferences:a).first)
        XCTAssertEqual(restored.id,file.id);XCTAssertEqual(restored.commandID,file.commandID)
        XCTAssertTrue(CaptureAttachmentDrafts.load(destination,preferences:b).isEmpty)
        for other in [CaptureAttachmentDestination(storeIncarnation:"replacement",projectID:"project",taskID:nil),
                      .init(storeIncarnation:"store",projectID:"other",taskID:nil),
                      .init(storeIncarnation:"store",projectID:"project",taskID:"created")] {
            XCTAssertTrue(CaptureAttachmentDrafts.load(other,preferences:a).isEmpty)
        }
        CaptureAttachmentDrafts.save([file],destination:destination,preferences:b)
        CaptureAttachmentDrafts.accepted(restored,preferences:a)
        XCTAssertTrue(CaptureAttachmentDrafts.load(destination,preferences:a).isEmpty)
        XCTAssertEqual(CaptureAttachmentDrafts.load(destination,preferences:b).first?.commandID,file.commandID)
    }
    @MainActor func testExactOpaqueDestinationAndBoundedSelectionRejectCrossDestinationRecords() throws {
        let preferences = isolatedDefaults("CaptureAttachments").preferences
        let original = CaptureAttachmentDestination(storeIncarnation:"s",projectID:"\u{00e9}",taskID:"t")
        let alias = CaptureAttachmentDestination(storeIncarnation:"s",projectID:"e\u{0301}",taskID:"t")
        XCTAssertNotEqual(original,alias)
        var files = (0..<25).map {CaptureAttachment(destination:original,url:URL(fileURLWithPath:"/selection-\($0)"),mode:"reference")}
        files.insert(CaptureAttachment(destination:alias,url:URL(fileURLWithPath:"/foreign-selection"),mode:"reference"),at:0)
        CaptureAttachmentDrafts.save(files,destination:original,preferences:preferences)
        XCTAssertEqual(CaptureAttachmentDrafts.load(original,preferences:preferences).count,20)
        XCTAssertTrue(CaptureAttachmentDrafts.load(alias,preferences:preferences).isEmpty)
    }
    func testSelectionCleanupNeverDeletesExternalOriginalEvenIfMarkedOwned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let original = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try Data([1,2,3]).write(to:original)
        let file = CaptureAttachment(destination:.init(storeIncarnation:"s",projectID:"p",taskID:nil),url:original,mode:"managed",ownedStaging:true)
        file.removeOwnedStaging()
        XCTAssertEqual(try Data(contentsOf:original),Data([1,2,3]))
    }
}
