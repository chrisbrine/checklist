import XCTest
import GRDB
import ChecklistTestSupport
@testable import ChecklistCore

final class TestStoreTests: XCTestCase {
    private static let populated = TestStore.Template(name: "TestStoreTests.populated") { router, workspace in
        let owner = Caller(role:"owner",installation:"prepared-store-fixture",projectIDs:[])
        let project = try router.handle(method:"project_create",params:["command_id":UUID().uuidString,"name":"Prepared","key_prefix":"PT","root_path":workspace.path],caller:owner)["data"] as! JSON
        let input: JSON = ["command_id":UUID().uuidString,"project_id":project["id"]!,"title":"Private prepared fixture"]
        let task = try router.handle(method:"task_create",params:fixtureTaskInput(router,method:"task_create",input:input),caller:owner)["data"] as! JSON
        let file = workspace.appendingPathComponent("evidence.txt");try Data("prepared bytes".utf8).write(to:file)
        _ = try router.handle(method:"attachment_add",params:["command_id":UUID().uuidString,"project_id":project["id"]!,"task_id":task["id"]!,"path":file.path],caller:owner)
        _ = try router.handle(method:"message_send",params:["command_id":UUID().uuidString,"project_id":project["id"]!,"task_id":task["id"]!,"body":"Literal workspace provenance: " + workspace.path],caller:owner)
    }
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

    func testPreparedCopiesHavePrivateFilesWorkspaceAndCanonicalAuthority() throws {
        let root = directory();defer {try? FileManager.default.removeItem(at:root)}
        let firstWorkspace = root.appendingPathComponent("first-workspace"),secondWorkspace = root.appendingPathComponent("second-workspace")
        let first = try TestStore.router(root:root.appendingPathComponent("first"),template:Self.populated,workspace:firstWorkspace)
        let second = try TestStore.router(root:root.appendingPathComponent("second"),template:Self.populated,workspace:secondWorkspace)
        defer {try? first.closeStore();try? second.closeStore()}
        XCTAssertNotEqual(first.incarnation,second.incarnation)
        XCTAssertNotEqual(first.cursorKey.withUnsafeBytes {Data($0)},second.cursorKey.withUnsafeBytes {Data($0)})
        let firstProject = try first.dbQueue.read {try XCTUnwrap(first.records($0,type:"project").first)}
        let secondProject = try second.dbQueue.read {try XCTUnwrap(second.records($0,type:"project").first)}
        XCTAssertEqual(firstProject["root_path"] as? String,firstWorkspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(secondProject["root_path"] as? String,secondWorkspace.resolvingSymlinksInPath().path)
        XCTAssertFalse(containsPath(first.root.path,firstWorkspace.path));XCTAssertFalse(containsPath(second.root.path,secondWorkspace.path))
        let firstMessage = try first.dbQueue.read {try XCTUnwrap(first.records($0,type:"message").first)}
        let secondMessage = try second.dbQueue.read {try XCTUnwrap(second.records($0,type:"message").first)}
        XCTAssertEqual(firstMessage["body"] as? String,secondMessage["body"] as? String,"Literal evidence text must not undergo workspace relocation")
        XCTAssertFalse((firstMessage["body"] as! String).contains(firstWorkspace.path))
        let attachment = try first.dbQueue.read {try XCTUnwrap(first.records($0,type:"attachment").first)}
        let path = attachment["path"] as! String
        try Data("changed first workspace".utf8).write(to:firstWorkspace.appendingPathComponent("evidence.txt"))
        try Data("changed first managed object".utf8).write(to:first.root.appendingPathComponent(path))
        XCTAssertEqual(try Data(contentsOf:secondWorkspace.appendingPathComponent("evidence.txt")),Data("prepared bytes".utf8))
        XCTAssertEqual(try second.managedRead(path,family:"objects",maximum:1024),Data("prepared bytes".utf8))
        try first.dbQueue.write {try $0.execute(sql:"DELETE FROM records WHERE type='message'")}
        XCTAssertEqual(try second.dbQueue.read {try second.records($0,type:"message").count},1)
        XCTAssertTrue(try second.dbQueue.read {db in
            try second.records(db,type:"storage_job").allSatisfy {$0["incarnation"] as? String == second.incarnation}
        })
        let third = try TestStore.router(root:root.appendingPathComponent("third"),template:Self.populated,workspace:root.appendingPathComponent("third-workspace"))
        defer {try? third.closeStore()}
        XCTAssertEqual(try third.managedRead(path,family:"objects",maximum:1024),Data("prepared bytes".utf8),"Neither private copy may modify the published template")

        // Filesystem-only templates also copy into an existing workspace and
        // isolate private Git-like metadata from siblings and future copies.
        let files = TestStore.DirectoryTemplate(name: "TestStoreTests.files") { path in
            try FileManager.default.createDirectory(at:path.appendingPathComponent(".git"),withIntermediateDirectories:true)
            try Data("base".utf8).write(to:path.appendingPathComponent(".git/index"))
        }
        let a = root.appendingPathComponent("files-a"),b = root.appendingPathComponent("files-b"),c = root.appendingPathComponent("files-c")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
        try Data("unrelated".utf8).write(to:a.appendingPathComponent("keep.txt"))
        try files.copy(to:a);try files.copy(to:b)
        try Data("private mutation".utf8).write(to:a.appendingPathComponent(".git/index"))
        try files.copy(to:c)
        XCTAssertEqual(try Data(contentsOf:b.appendingPathComponent(".git/index")),Data("base".utf8))
        XCTAssertEqual(try Data(contentsOf:c.appendingPathComponent(".git/index")),Data("base".utf8))
        XCTAssertEqual(try Data(contentsOf:a.appendingPathComponent("keep.txt")),Data("unrelated".utf8))
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
        let preparedWarm = try TestStore.router(root:root.appendingPathComponent("prepared-warm"),durable:false,template:Self.populated,workspace:root.appendingPathComponent("prepared-workspace-warm"));try preparedWarm.closeStore()
        var samples: [Double] = [], baseline: [Double] = [],prepared: [Double] = []
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
            let start = ProcessInfo.processInfo.systemUptime
            let populated = try TestStore.router(root:root.appendingPathComponent("prepared-\(index)"),durable:false,template:Self.populated,workspace:root.appendingPathComponent("prepared-workspace-\(index)"))
            prepared.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            try populated.closeStore()
        }
        print("CL-266 store_setup_ms baseline_median=\(baseline.sorted()[baseline.count / 2]) template_median=\(samples.sorted()[samples.count / 2]) baseline=\(baseline) template=\(samples)")
        print("CL-358 populated_store_setup_ms median=\(prepared.sorted()[prepared.count / 2]) samples=\(prepared)")
    }
}
