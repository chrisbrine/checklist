import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class EpicIndexFixtureTests: XCTestCase {
    func testProductAndDurableDefaultsInstallTheRealIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-index-default-" + uuid())
        defer { _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let production = try CommandRouter(root:root.appendingPathComponent("production"))
        let durable = try TestStore.router(root:root.appendingPathComponent("durable"),durable:true,trackEpicReferences:false)
        let deletion = try TestStore.router(root:root.appendingPathComponent("deletion"),durable:false,trackEpicReferences:true)
        let unit = try TestStore.router(root:root.appendingPathComponent("unit"),durable:false)
        defer { try? unit.closeStore() }
        XCTAssertEqual(unit.fixtureOmitsEpicReferenceIndex,ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] != "1")
        defer { try? production.closeStore();try? durable.closeStore();try? deletion.closeStore() }
        for router in [production,durable,deletion] {
            XCTAssertFalse(router.fixtureOmitsEpicReferenceIndex)
            try router.dbQueue.read { db in
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'epic_guard_%'"),6)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM epic_guard_progress"),2)
            }
        }
    }

    func testOmittedIndexFailsExplicitlyBeforeDeletionCanBeTested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-index-unit-" + uuid())
        defer { _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        // Exercise the explicit internal seam independently of the factory's
        // qualification environment override.
        let router = try CommandRouter(root:root,serviceLease:nil,cliCommand:"/Applications/Checklist.app/Contents/MacOS/checklist",
                                       providerPlugins:.bundled,automaticBackupRetentionTrashRoot:nil,fixtureTrackEpicReferences:false)
        defer { try? router.closeStore() }
        XCTAssertTrue(router.fixtureOmitsEpicReferenceIndex)
        let owner = Caller(role:"owner",installation:"epic-index-unit",projectIDs:[])
        let project = try router.handle(method:"project_create",params:["name":"Unit","key_prefix":"EI","command_id":uuid()],caller:owner)["data"] as! JSON
        let epic = try router.handle(method:"epic_create",params:["project_id":project["id"]!,"name":"Unused","command_id":uuid()],caller:owner)["data"] as! JSON
        let before = try router.dbQueue.read { try router.record($0,epic["id"] as! String,type:"group") }
        XCTAssertThrowsError(try router.handle(method:"epic_delete",params:["project_id":project["id"]!,"epic_id":epic["id"]!,"expected_revision":epic["revision"]!,"command_id":uuid()],caller:owner)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"FIXTURE_EPIC_INDEX_DISABLED")
        }
        XCTAssertEqual(try router.dbQueue.read { try jsonString(router.record($0,epic["id"] as! String,type:"group")) },try jsonString(before))
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'epic_guard_%'") },0)
    }
}
