import XCTest
@testable import ChecklistIPC
@testable import ChecklistApp

final class InstanceCacheRootTests: XCTestCase {
    func testLiveCacheAndAppDefaultsKeepFormerPaths() throws {
        let former = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for environment in [[:], ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"]] {
            let live = try ChecklistInstance(environment: environment)
            XCTAssertEqual(live.cachesRoot, former)
            XCTAssertEqual(live.cachesRoot.absoluteString, former.absoluteString)
        }
        XCTAssertNil(ChecklistInstance.current.slot)
        XCTAssertEqual(CaptureAttachment.staging, former.appendingPathComponent("ChecklistAttachmentDrafts", isDirectory: true))
        XCTAssertEqual(AuthorizedPreviewFile.defaultExternalWorkingCopyBase, former)
        XCTAssertEqual(AuthorizedPreviewFile.defaultExternalWorkingCopyBase.appendingPathComponent("Checklist/OpenCopies", isDirectory: true),
                       former.appendingPathComponent("Checklist/OpenCopies", isDirectory: true))
    }

    func testEverySlotCacheIsInsideItsFolderOutsideDataAndSeparateFromLive() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let live = try ChecklistInstance(environment: [:])
        var roots: [URL] = []
        for slot in 1...4 {
            let instance = try ChecklistInstance(slotValue: slot, environment: ["CHECKLIST_DATA_ROOT": "/tmp/checklist-custom-service-root"])
            let folder = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-\(slot)", isDirectory: true)
            XCTAssertEqual(instance.cachesRoot, folder.appendingPathComponent("caches", isDirectory: true))
            XCTAssertEqual(instance.cachesRoot.deletingLastPathComponent(), folder)
            XCTAssertTrue(try ChecklistInstance.rootsOverlap(instance.cachesRoot, folder))
            XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, instance.root))
            XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, live.cachesRoot))
            for other in roots {
                XCTAssertFalse(try ChecklistInstance.rootsOverlap(instance.cachesRoot, other))
            }
            roots.append(instance.cachesRoot)
        }
    }
}
