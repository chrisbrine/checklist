import XCTest
import Darwin
import ChecklistIPC
@testable import ChecklistApp

final class LocalDraftInstanceTests: XCTestCase {
    func testLiveDraftsAndFinderKeepFormerRootUnderCustomEnvironment() throws {
        let previous = ProcessInfo.processInfo.environment["CHECKLIST_DATA_ROOT"]
        setenv("CHECKLIST_DATA_ROOT","/tmp/checklist-custom-service-root",1)
        defer {
            if let previous { setenv("CHECKLIST_DATA_ROOT",previous,1) }
            else { unsetenv("CHECKLIST_DATA_ROOT") }
        }
        let instance = try ChecklistInstance()
        let former = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Checklist")
        XCTAssertNil(instance.slot)
        XCTAssertEqual(instance.root.path,"/tmp/checklist-custom-service-root")
        XCTAssertEqual(instance.ownerDataRoot.path,former.path,"This is the Finder action's actual target")
        XCTAssertEqual(LocalDraftJournal.directory(for:instance).path,former.appendingPathComponent("OwnerDrafts").path)
        XCTAssertEqual(LocalDraftJournal.defaultDirectory.path,former.appendingPathComponent("OwnerDrafts").path)
    }
    func testEveryTestSlotKeepsDraftsAndFinderInItsOwnRoot() throws {
        for slot in 1...4 {
            let instance = try ChecklistInstance(slotValue:slot,environment:["CHECKLIST_DATA_ROOT":"/tmp/custom-live"])
            XCTAssertEqual(instance.ownerDataRoot,instance.root)
            XCTAssertEqual(LocalDraftJournal.directory(for:instance),instance.root.appendingPathComponent("OwnerDrafts"))
        }
    }
}
