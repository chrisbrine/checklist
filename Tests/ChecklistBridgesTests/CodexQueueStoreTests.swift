import XCTest
import Darwin
import GRDB
@testable import ChecklistBridges

final class CodexQueueStoreTests: XCTestCase {
    private let thread = "00000000-0000-4000-8000-000000000413"
    private func directory() throws -> URL {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = source.deletingLastPathComponent().appendingPathComponent("q/cl413-stores/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func database(_ root: URL, _ name: String = "state_5.sqlite", schema: String = "CREATE TABLE threads(id TEXT PRIMARY KEY, source TEXT, originator TEXT)") throws -> DatabaseQueue {
        let db = try DatabaseQueue(path:root.appendingPathComponent(name).path)
        try db.write { try $0.execute(sql:schema) }
        return db
    }
    private func store(_ root: URL) -> CodexQueueStore { .init(directory:root) }
    private final class Queue: CodexQueueTransportEffects {
        var calls = 0
        func queue(content: String, registration: NativeLifecycleRegistration, timeout: TimeInterval) throws -> CodexQueueReceipt {
            calls += 1;return .init(exitStatus:0,byteCount:content.utf8.count,itemID:"synthetic-item")
        }
    }
    private func registration() throws -> NativeLifecycleRegistration {
        try XCTUnwrap(NativeLifecycleRegistration(provider:"codex",sessionID:thread,executionDomain:"codex:24680:5:0",registryPath:nil))
    }
    func testSourceDecidesNotOriginatorAndEveryRefusalMakesNoQueueCall() throws {
        let root = try directory(),db = try database(root),effects = Queue()
        let cases: [(String,String,CodexQueueReason)] = [("exec","Codex Desktop",.sourceExec),("mcp","codex_work_desktop",.sourceMCP),
            ("{\"subagent\":{\"thread_spawn\":{}}}","codex_work_desktop",.sourceSubagent),("unknown","codex_work_desktop",.sourceUnknown)]
        for (source,originator,reason) in cases {
            try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads VALUES (?,?,?)",arguments:[thread,source,originator]) }
            let observation = store(root).observe(threadID:thread)
            XCTAssertEqual(observation.reason,reason)
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observation,enabled:true,timeout:5,effects:effects))
        }
        XCTAssertEqual(effects.calls,0)
        try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads VALUES (?,?,?)",arguments:[thread,"vscode","anything"]) }
        let observation = store(root).observe(threadID:thread)
        XCTAssertEqual(observation.host,.nativeApp)
        _ = try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observation,enabled:true,timeout:5,effects:effects)
        XCTAssertEqual(effects.calls,1)
        try db.close()
    }
    func testExternalSourceStorageMustBeTextWithoutCrashingOrQueueing() throws {
        let root = try directory(),db = try database(root),effects = Queue()
        for expression in ["X'FFFE'", "X'7673636F6465'", "NULL"] {
            try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads VALUES (?,\(expression),NULL)",arguments:[thread]) }
            let observed = store(root).observe(threadID:thread)
            XCTAssertEqual(observed.reason,.schemaUnrecognized)
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observed,enabled:true,timeout:5,effects:effects))
        }
        XCTAssertEqual(effects.calls,0);try db.close()
    }

    func testMissingExactRowInvalidIDAndUnknownShapeRefuse() throws {
        let root = try directory(),db = try database(root)
        try db.write { try $0.execute(sql:"INSERT INTO threads VALUES (?,?,?)",arguments:[UUID().uuidString.lowercased(),"vscode","codex_work_desktop"]) }
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.threadMissing)
        XCTAssertEqual(store(root).observe(threadID:"not-a-uuid").reason,.recipientInvalid)
        try db.close()
        for schema in ["CREATE TABLE threads(id TEXT PRIMARY KEY, originator TEXT)","CREATE TABLE threads(id TEXT, source TEXT, originator TEXT)","CREATE TABLE threads(id INTEGER PRIMARY KEY, source TEXT, originator TEXT)","CREATE VIEW threads AS SELECT 'id' id,'vscode' source,NULL originator"] {
            let folder = try directory(),other = try database(folder,schema:schema)
            XCTAssertEqual(store(folder).observe(threadID:thread).reason,.schemaUnrecognized)
            try other.close()
        }
    }
    func testExactSupportedFilenameAndNewerVersionFailClosed() throws {
        let root = try directory()
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseMissing)
        let renamed = try database(root,"state_6.sqlite")
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseVersionUnsupported)
        let old = try database(root)
        try old.write { try $0.execute(sql:"INSERT INTO threads VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseVersionUnsupported,"Do not read a stale retained supported file after a rename")
        try renamed.close();try old.close()
    }
    func testReadFailureLockedAndUnsafeFileHaveDistinctReasonsAndNoQueueCalls() throws {
        let corrupt = try directory()
        try Data("not SQLite".utf8).write(to:corrupt.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(store(corrupt).observe(threadID:thread).reason,.databaseReadError)
        let root = try directory(),db = try database(root)
        try db.write { try $0.execute(sql:"INSERT INTO threads VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
        try db.inDatabase { connection in
            try connection.execute(sql:"BEGIN EXCLUSIVE TRANSACTION")
            defer { try? connection.execute(sql:"ROLLBACK") }
            XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseLocked)
        }
        try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:root.appendingPathComponent("state_5.sqlite").path)
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseUnsafe)
        let effects = Queue()
        for reason in [CodexQueueReason.threadMissing,.databaseReadError,.databaseLocked,.schemaUnrecognized,.databaseMissing,.databaseVersionUnsupported,.databaseUnsafe] {
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:.init(reason:reason),enabled:true,timeout:5,effects:effects)) {
                XCTAssertEqual(($0 as? CodexQueueRefusal)?.observation.reason,reason)
            }
        }
        XCTAssertEqual(effects.calls,0)
        try db.close()
    }
    func testReadOnlyObservationPreservesDatabaseBytesAndNeedsNoWritePermission() throws {
        let root = try directory(),db = try database(root)
        try db.write { try $0.execute(sql:"INSERT INTO threads VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
        try db.close()
        let path = root.appendingPathComponent("state_5.sqlite"),before = try Data(contentsOf:path)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:path.path)
        XCTAssertEqual(store(root).observe(threadID:thread).host,.nativeApp)
        XCTAssertEqual(try Data(contentsOf:path),before)
    }
    func testExactQueueItemAndThreadAreBothRequired() throws {
        let root = try directory(),db = try database(root,"queue_1.sqlite",schema:"CREATE TABLE queued_items(id TEXT PRIMARY KEY, thread_id TEXT)")
        try db.write { try $0.execute(sql:"INSERT INTO queued_items VALUES (?,?)",arguments:["one",thread]) }
        XCTAssertEqual(store(root).item("one",threadID:thread),.pending)
        XCTAssertEqual(store(root).item("one",threadID:thread.uppercased()),.pending)
        XCTAssertEqual(store(root).item("two",threadID:thread),.removed)
        XCTAssertEqual(store(root).item("one",threadID:UUID().uuidString.lowercased()),.removed)
        try db.close()
    }
}
