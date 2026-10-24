import XCTest
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
        let lock = NSLock(); var identities = Set<String>(), errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                let router = try TestStore.router(root: root.appendingPathComponent(String(index)))
                defer { try? router.closeStore() }
                lock.withLock { _ = identities.insert(router.incarnation) }
            } catch { lock.withLock { errors.append(String(describing: error)) } }
        }
        XCTAssertEqual(errors, []); XCTAssertEqual(identities.count, 12)
    }

    func testWarmStoreSetupReportsPairedMedians() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let warm = try TestStore.router(root: root.appendingPathComponent("warm")); try warm.closeStore()
        var samples: [Double] = [], baseline: [Double] = []
        for index in 0..<25 {
            func sample(fast: Bool) throws {
                let path = root.appendingPathComponent((fast ? "fast-" : "base-") + String(index))
                let start = ProcessInfo.processInfo.systemUptime
                let router = try fast ? TestStore.router(root: path) : CommandRouter(root: path)
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
