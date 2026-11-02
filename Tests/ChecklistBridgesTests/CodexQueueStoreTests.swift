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
    private func database(_ root: URL, _ name: String = "state_5.sqlite", schema: String = "CREATE TABLE threads(id TEXT PRIMARY KEY, source TEXT, originator TEXT, archived INTEGER NOT NULL DEFAULT 0, rollout_path TEXT, updated_at INTEGER NOT NULL DEFAULT 0)") throws -> DatabaseQueue {
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
            try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[thread,source,originator]) }
            let observation = store(root).observe(threadID:thread)
            XCTAssertEqual(observation.reason,reason)
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observation,enabled:true,timeout:5,effects:effects))
        }
        XCTAssertEqual(effects.calls,0)
        try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[thread,"vscode","anything"]) }
        let observation = store(root).observe(threadID:thread)
        XCTAssertEqual(observation.host,.nativeApp)
        _ = try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observation,enabled:true,timeout:5,effects:effects)
        XCTAssertEqual(effects.calls,1)
        try db.close()
    }
    func testExternalSourceStorageMustBeTextWithoutCrashingOrQueueing() throws {
        let root = try directory(),db = try database(root),effects = Queue()
        for expression in ["X'FFFE'", "X'7673636F6465'", "NULL"] {
            try db.write { try $0.execute(sql:"INSERT OR REPLACE INTO threads(id,source,originator) VALUES (?,\(expression),NULL)",arguments:[thread]) }
            let observed = store(root).observe(threadID:thread)
            XCTAssertEqual(observed.reason,.schemaUnrecognized)
            XCTAssertThrowsError(try CodexQueueRelay.send(content:"Synthetic",registration:registration(),observation:observed,enabled:true,timeout:5,effects:effects))
        }
        XCTAssertEqual(effects.calls,0);try db.close()
    }

    func testMissingExactRowInvalidIDAndUnknownShapeRefuse() throws {
        let root = try directory(),db = try database(root)
        try db.write { try $0.execute(sql:"INSERT INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[UUID().uuidString.lowercased(),"vscode","codex_work_desktop"]) }
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
        try old.write { try $0.execute(sql:"INSERT INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
        XCTAssertEqual(store(root).observe(threadID:thread).reason,.databaseVersionUnsupported,"Do not read a stale retained supported file after a rename")
        try renamed.close();try old.close()
    }
    func testReadFailureLockedAndUnsafeFileHaveDistinctReasonsAndNoQueueCalls() throws {
        let corrupt = try directory()
        try Data("not SQLite".utf8).write(to:corrupt.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(store(corrupt).observe(threadID:thread).reason,.databaseReadError)
        let root = try directory(),db = try database(root)
        try db.write { try $0.execute(sql:"INSERT INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
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
        try db.write { try $0.execute(sql:"INSERT INTO threads(id,source,originator) VALUES (?,?,?)",arguments:[thread,"vscode","desktop"]) }
        try db.close()
        let path = root.appendingPathComponent("state_5.sqlite"),before = try Data(contentsOf:path)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:path.path)
        XCTAssertEqual(store(root).observe(threadID:thread).host,.nativeApp)
        XCTAssertEqual(try Data(contentsOf:path),before)
    }
    func testArchivedThreadRefusesAndRecentAppThreadsAreBounded() throws {
        let root = try directory(),db = try database(root)
        try db.write { database in
            for index in 0..<10 {
                try database.execute(sql:"INSERT INTO threads(id,source,originator,updated_at) VALUES (?,?,?,?)",arguments:[String(format:"00000000-0000-4000-8000-%012d",index),"vscode","d",1000+index])
            }
            try database.execute(sql:"INSERT INTO threads(id,source,originator,updated_at,archived) VALUES (?,?,?,?,1)",arguments:[thread,"vscode","d",9000])
            try database.execute(sql:"INSERT INTO threads(id,source,originator,updated_at) VALUES (?,?,?,?)",arguments:["00000000-0000-4000-8000-0000000000ee","exec","d",9000])
            try database.execute(sql:"INSERT INTO threads(id,source,originator,updated_at) VALUES (?,?,?,?)",arguments:["00000000-0000-4000-8000-0000000000dd","vscode","d",5])
        }
        let archived = store(root).observe(threadID:thread)
        XCTAssertEqual(archived.reason,.threadArchived);XCTAssertEqual(archived.host,.unproven)
        let recent = try XCTUnwrap(store(root).recentAppThreads(updatedSince:100,limit:3))
        XCTAssertEqual(recent,["00000000-0000-4000-8000-000000000009","00000000-0000-4000-8000-000000000008","00000000-0000-4000-8000-000000000007"])
        XCTAssertNil(store(root.appendingPathComponent("missing")).recentAppThreads(updatedSince:0,limit:3))
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

    /// F10: names only unarchived app rows. An exec enrollment gets no line.
    func testOmittedThreadsNameOnlyAppRowsAndTheirCause() throws {
        let root = try directory(),db = try database(root)
        let ranked = "00000000-0000-4000-8000-0000000000a1",stale = "00000000-0000-4000-8000-0000000000a2",exec = "00000000-0000-4000-8000-0000000000a3",archived = "00000000-0000-4000-8000-0000000000a4"
        try db.write { database in
            for (id,source,updated,flag) in [(ranked,"vscode",900,0),(stale,"vscode",5,0),(exec,"exec",900,0),(archived,"vscode",900,1)] {
                try database.execute(sql:"INSERT INTO threads(id,source,originator,updated_at,archived) VALUES (?,?,?,?,?)",arguments:[id,source,"d",updated,flag])
            }
        }
        XCTAssertEqual(store(root).omittedAppThreads(candidates:[stale.uppercased(),ranked,exec,archived,"not-a-uuid"],updatedSince:100),[.init(id:ranked,stale:false),.init(id:stale,stale:true)])
        XCTAssertEqual(store(root).omittedAppThreads(candidates:[],updatedSince:100),[])
        XCTAssertNil(store(root.appendingPathComponent("missing")).omittedAppThreads(candidates:[ranked],updatedSince:100))
        try db.close()
    }

    // B1: Codex starts one turn per item, so the route adds no item to a thread that still has one.
    private let queueSchema = "CREATE TABLE queued_items(id TEXT PRIMARY KEY, thread_id TEXT)"
    private func item(_ db: DatabaseQueue,_ id: String,_ thread: String) throws {
        try db.write { try $0.execute(sql:"INSERT INTO queued_items(id,thread_id) VALUES (?,?)",arguments:[id,thread]) }
    }
    func testThreadItemsCountOnlyTheExactThread() throws {
        let root = try directory(),db = try database(root,"queue_1.sqlite",schema:queueSchema)
        XCTAssertEqual(store(root).threadItems(threadID:thread),.empty)
        try item(db,"other","00000000-0000-4000-8000-000000000999")
        try item(db,"prefix",thread+"-extra")
        try item(db,"case","00000000-0000-4000-8000-00000000ABCD")
        XCTAssertEqual(store(root).threadItems(threadID:"00000000-0000-4000-8000-00000000abcd"),.empty,"The comparison is binary, on the stored lowercase form")
        XCTAssertEqual(store(root).threadItems(threadID:thread),.empty,"Another thread's row does not count")
        try item(db,"one",thread)
        XCTAssertEqual(store(root).threadItems(threadID:thread),.occupied(1))
        XCTAssertEqual(store(root).threadItems(threadID:thread.uppercased()),.occupied(1),"The UUID form of the argument does not matter")
        try item(db,"two",thread)
        XCTAssertEqual(store(root).threadItems(threadID:thread),.occupied(2))
        try db.close()
    }
    func testThreadItemsReadFailureNamesItsReason() throws {
        let missing = try directory()
        XCTAssertEqual(store(missing).threadItems(threadID:thread),.empty,"Codex creates the queue file at its first queue call, so an existing Codex home with no file holds no item")
        XCTAssertEqual(store(missing.appendingPathComponent("absent")).threadItems(threadID:thread),.failed(.databaseMissing),"A missing Codex home still refuses")
        XCTAssertEqual(store(missing).threadItems(threadID:"not-a-uuid"),.failed(.recipientInvalid))
        let shape = try directory(),wrong = try database(shape,"queue_1.sqlite",schema:"CREATE TABLE queued_items(id TEXT PRIMARY KEY, other TEXT)")
        XCTAssertEqual(store(shape).threadItems(threadID:thread),.failed(.schemaUnrecognized));try wrong.close()
        let newer = try directory(),first = try database(newer,"queue_1.sqlite",schema:queueSchema),second = try database(newer,"queue_2.sqlite",schema:queueSchema)
        XCTAssertEqual(store(newer).threadItems(threadID:thread),.failed(.databaseVersionUnsupported));try first.close();try second.close()
        let lock = try directory(),locked = try database(lock,"queue_1.sqlite",schema:queueSchema)
        try locked.writeWithoutTransaction { db in
            try db.execute(sql:"BEGIN EXCLUSIVE")
            XCTAssertEqual(store(lock).threadItems(threadID:thread),.failed(.databaseLocked))
            try db.execute(sql:"COMMIT")
        }
        XCTAssertEqual(store(lock).threadItems(threadID:thread),.empty);try locked.close()
    }
    func testPreflightWithAFixtureQueueAllowsOnlyAThreadWithNoItem() throws {
        let host = CodexProcess(pid:7,executable:"/Applications/ChatGPT.app/Contents/Resources/codex",role:.appHost)
        let vscode = CodexQueueObservation(host:.nativeApp,reason:.sourceVscode,source:"vscode")
        func result(_ root: URL) -> CodexQueuePreflight {
            CodexQueueRoute.preflight(registrationProven:true,enabled:true,observation:vscode,scan:{ CodexHostScan(hosts:[host],holders:[]) },hostVerified:{ _ in true },threadItems:{ store(root).threadItems(threadID:thread) })
        }
        func refusal(_ root: URL) -> CodexQueueReason? { if case .refused(let value) = result(root) { return value.reason };return nil }
        let root = try directory(),db = try database(root,"queue_1.sqlite",schema:queueSchema)
        XCTAssertEqual(result(root),.allowed(vscode,executable:host.executable))
        try item(db,"other","00000000-0000-4000-8000-000000000999")
        XCTAssertEqual(result(root),.allowed(vscode,executable:host.executable))
        try item(db,"one",thread)
        XCTAssertEqual(refusal(root),.queueOccupied)
        try db.writeWithoutTransaction { database in
            try database.execute(sql:"BEGIN EXCLUSIVE")
            XCTAssertEqual(refusal(root),.databaseLocked)
            try database.execute(sql:"COMMIT")
        }
        try db.close()
        XCTAssertNil(refusal(try directory()),"An existing Codex home with no queue file holds no item")
    }
}
