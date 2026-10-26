import XCTest
import GRDB
import ChecklistTestSupport
@testable import ChecklistCore

final class TestStoreTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CL266-" + UUID().uuidString)
    }

    func testCopiesHavePrivateRowsIdentitiesAndCursorKeys() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try TestStore.router(root: root.appendingPathComponent("first"))
        let second = try TestStore.router(root: root.appendingPathComponent("second"))
        defer { try? first.closeStore(); try? second.closeStore() }
        XCTAssertNotEqual(first.incarnation, second.incarnation)
        XCTAssertNotEqual(first.cursorKey.withUnsafeBytes { Data($0) }, second.cursorKey.withUnsafeBytes { Data($0) })
        let owner = Caller(role: "owner", installation: "fast-store-fixture", projectIDs: [])
        _ = try first.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "Private", "key_prefix": "FS"], caller: owner)
        let reply = try second.handle(method: "project_list", params: [:], caller: owner)["data"] as! JSON
        XCTAssertEqual((reply["projects"] as! [JSON]).count, 0)
    }

    func testReopeningKeepsExistingIdentityAndData() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var router = try TestStore.router(root: root)
        let identity = router.incarnation
        let owner = Caller(role: "owner", installation: "fast-store-reopen", projectIDs: [])
        _ = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "Retained", "key_prefix": "FS"], caller: owner)
        try router.closeStore()
        router = try TestStore.router(root: root); defer { try? router.closeStore() }
        XCTAssertEqual(router.incarnation, identity)
        let reply = try router.handle(method: "project_list", params: [:], caller: owner)["data"] as! JSON
        XCTAssertEqual((reply["projects"] as! [JSON]).count, 1)
    }

    func testConcurrentCopiesAreIndependent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = LockedTestState((identities: Set<String>(), errors: [String]()))
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                let router = try TestStore.router(root: root.appendingPathComponent(String(index)))
                defer { try? router.closeStore() }
                state.withLock { _ = $0.identities.insert(router.incarnation) }
            } catch { state.withLock { $0.errors.append(String(describing: error)) } }
        }
        XCTAssertEqual(state.snapshot.errors, []); XCTAssertEqual(state.snapshot.identities.count, 12)
    }

    func testUnitSynchronizationDoesNotChangeProductionOrQualification() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let unit = try TestStore.router(root: root.appendingPathComponent("unit"), durable: false)
        let qualified = try TestStore.router(root: root.appendingPathComponent("qualified"), durable: true)
        let production = try CommandRouter(root: root.appendingPathComponent("production"))
        defer { try? unit.closeStore(); try? qualified.closeStore(); try? production.closeStore() }
        for (router, synchronization) in [(unit, 1), (qualified, 2), (production, 2)] {
            try router.dbQueue.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA synchronous"), synchronization)
                XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
                XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
            }
        }
    }

    func testWarmStoreSetupReportsPairedMedians() throws {
        try QualificationSuite.requireEnabled()
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let warm = try TestStore.router(root: root.appendingPathComponent("warm"), durable: false); try warm.closeStore()
        var samples: [Double] = [], baseline: [Double] = []
        for index in 0..<25 {
            func sample(fast: Bool) throws {
                let path = root.appendingPathComponent((fast ? "fast-" : "base-") + String(index))
                let start = ProcessInfo.processInfo.systemUptime
                let router = try fast ? TestStore.router(root: path, durable: false) : CommandRouter(root: path)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if fast { samples.append(elapsed) } else { baseline.append(elapsed) }
                try router.closeStore()
            }
            // Alternate order so a warm page cache cannot decide the comparison.
            try sample(fast: index % 2 == 0); try sample(fast: index % 2 != 0)
        }
        print("CL-266 store_setup_ms baseline_median=\(baseline.sorted()[baseline.count / 2]) template_median=\(samples.sorted()[samples.count / 2]) baseline=\(baseline) template=\(samples)")
    }
}
