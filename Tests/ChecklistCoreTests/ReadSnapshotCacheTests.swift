import XCTest
import GRDB
import SQLite3
@testable import ChecklistCore

private final class VersionWALHandle {
    let pointer:UnsafeMutablePointer<sqlite3_snapshot>
    let bytes:Data
    init?(_ db:Database) {
        var pointer:UnsafeMutablePointer<sqlite3_snapshot>?
        guard sqlite3_snapshot_get(db.sqliteConnection,"main",&pointer)==SQLITE_OK,let pointer else {return nil}
        self.pointer=pointer;bytes=Data(bytes:pointer,count:MemoryLayout<sqlite3_snapshot>.size)
    }
    deinit {sqlite3_snapshot_free(pointer)}
}

final class ReadSnapshotCacheTests: XCTestCase {
    func testOpaqueReadVersionChangesOnCommitAndCallerButSurvivesReaderChurnAndRollback() throws {
        let f = try ReadPerformanceFixture("CL-254-read-version"),r = f.router,reader = try XCTUnwrap(r.readers)
        func version(_ caller: Caller) throws -> String {
            try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:caller) {
                try XCTUnwrap(r.readSnapshotCache.readVersion(db))
            }}
        }
        let first = try version(f.owner)
        XCTAssertEqual(try version(f.owner),first)
        try f.save([("message",["id":"version-note","project_id":"project","revision":1])])
        let committed = try version(f.owner)
        XCTAssertNotEqual(committed,first,"A write with no event still changes the token")
        try r.dbQueue.writeWithoutTransaction {db in
            try db.inTransaction {try db.execute(sql:"DELETE FROM records WHERE id='version-note'");return .rollback}
        }
        XCTAssertEqual(try version(f.owner),committed)
        var changed = f.owner;changed.projectIDs = ["different-project"]
        XCTAssertNotEqual(try version(changed),committed)
        let restored = try version(f.owner)
        XCTAssertEqual(restored,committed,"An interleaved caller must not rotate unchanged display identity")
        try r.dbQueue.read {db in XCTAssertNil(r.readSnapshotCache.readVersion(db),"Writer reads do not issue cache authority")}
        var configuration = Configuration();configuration.readonly = true
        let other = try DatabaseQueue(path:r.root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? other.close()}
        try other.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            XCTAssertEqual(r.readSnapshotCache.readVersion(db),restored,"The same pinned WAL snapshot is comparable across readers")
        }}
    }

    func testInterleavedPoolReadersKeepScopeTokensAndPinnedOldReadCannotAliasNewCommit() throws {
        let f = try ReadPerformanceFixture("CL-254-pool-version"),r = f.router,reader = try XCTUnwrap(r.readers)
        try f.save([("message",["id":"pinned-version","project_id":"project","revision":1])])
        // Every observation field is accessed under lock, and the worker joins before teardown.
        final class Observation: @unchecked Sendable {
            let lock=NSLock();var before:String?;var after:String?;var error:Error?
        }
        let owner = f.owner // Value copy; fixture stays alive until reader joins.
        let values=Observation(),pinned=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),finished=expectation(description:"pinned reader finishes")
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            do {try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:owner) {
                XCTAssertEqual(try r.record(db,"pinned-version")["revision"] as? Int,1)
                values.lock.withLock {values.before=r.readSnapshotCache.readVersion(db)}
                pinned.signal()
                guard resume.wait(timeout:.now()+10) == .success else {throw NSError(domain:"PinnedReadTimeout",code:1)}
                values.lock.withLock {values.after=r.readSnapshotCache.readVersion(db)}
                XCTAssertEqual(try r.record(db,"pinned-version")["revision"] as? Int,1)
            }}} catch {values.lock.withLock {values.error=error};pinned.signal()}
        }
        defer {resume.signal()}
        XCTAssertEqual(pinned.wait(timeout:.now()+10),.success)
        let old=try XCTUnwrap(values.lock.withLock {values.before})
        var other=f.owner;other.installation="interleaved-bridge"
        for _ in 0..<12 {
            try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:other) {XCTAssertNotEqual(r.readSnapshotCache.readVersion(db),old)}}
            try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {XCTAssertEqual(r.readSnapshotCache.readVersion(db),old)}}
        }
        try f.save([("message",["id":"pinned-version","project_id":"project","revision":2])])
        let current=try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {try XCTUnwrap(r.readSnapshotCache.readVersion(db))}}
        XCTAssertNotEqual(current,old,"An eventless commit changes the pinned snapshot")
        resume.signal();wait(for:[finished],timeout:10)
        XCTAssertNil(values.lock.withLock {values.error})
        XCTAssertEqual(values.lock.withLock {values.after},old,"The precommit reader retains its own older identity")
        try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {XCTAssertEqual(r.readSnapshotCache.readVersion(db),current)}}
    }

    func testUnavailableWALSnapshotOmitsDisplayVersionWithoutAffectingReads() throws {
        let f=try ReadPerformanceFixture("CL-254-version-fallback"),path=f.router.root.appendingPathComponent("non-wal.sqlite").path
        let writer=try DatabaseQueue(path:path)
        try writer.write {try $0.execute(sql:"CREATE TABLE fixture(value); INSERT INTO fixture VALUES(1)")}
        try writer.close()
        var configuration=Configuration();configuration.readonly=true
        let reader=try DatabaseQueue(path:path,configuration:configuration)
        defer {try? reader.close()}
        try reader.read {db in try f.router.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            XCTAssertNil(f.router.readSnapshotCache.readVersion(db))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT value FROM fixture"),1)
        }}
        // After checkpoint SQLite may retain a valid snapshot header or report
        // no snapshot. Both preserve reads of the same committed contents.
        let pool=try XCTUnwrap(f.router.readers)
        let before=try pool.read {db in try f.router.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            (f.router.readSnapshotCache.readVersion(db),try Int.fetchOne(db,sql:"PRAGMA data_version"),VersionWALHandle(db))
        }}
        try f.router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"PRAGMA wal_checkpoint(TRUNCATE)")}
        try pool.read {db in try f.router.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            let after=f.router.readSnapshotCache.readVersion(db)
            let version=try Int.fetchOne(db,sql:"PRAGMA data_version"),handle=VersionWALHandle(db)
            let comparison=before.2.flatMap {old in handle.map {sqlite3_snapshot_cmp(old.pointer,$0.pointer)}}
            print("P9-r2 TRUNCATE before_data_version=\(String(describing:before.1)) after_data_version=\(String(describing:version)) token_stable=\(after == before.0) snapshot_cmp=\(String(describing:comparison)) opaque_bytes_equal=\(before.2?.bytes == handle?.bytes)")
            XCTAssertTrue(after == nil || after == before.0 || version != before.1)
            XCTAssertNotNil(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata"))
        }}
    }

    func testCommittedChangeThenCheckpointCannotAliasRetainedReaderVersion() throws {
        let f=try ReadPerformanceFixture("CL-254-commit-checkpoint"),r=f.router,pool=try XCTUnwrap(r.readers)
        try f.save([("message",["id":"checkpoint-version","project_id":"project","revision":1])])
        let before=try pool.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            (r.readSnapshotCache.readVersion(db),try r.record(db,"checkpoint-version")["revision"] as? Int)
        }}
        XCTAssertEqual(before.1,1)
        try f.save([("message",["id":"checkpoint-version","project_id":"project","revision":2])])
        try r.dbQueue.writeWithoutTransaction {try $0.execute(sql:"PRAGMA wal_checkpoint(TRUNCATE)")}
        try pool.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            let after=r.readSnapshotCache.readVersion(db)
            XCTAssertTrue(after == nil || after != before.0,"A committed change followed by checkpoint cannot reuse the old display token")
            XCTAssertEqual(try r.record(db,"checkpoint-version")["revision"] as? Int,2)
        }}
    }

    func testCheckpointAndSpilledRollbackNeverReusesChangedContentsAsCurrent() throws {
        let f=try ReadPerformanceFixture("CL-254-spilled-rollback"),r=f.router,reader=try XCTUnwrap(r.readers)
        try f.save((0..<128).map {("message",["id":"spill-\($0)","project_id":"project","revision":1,"body":String(repeating:"retained ",count:1024)] as JSON)})
        try r.dbQueue.writeWithoutTransaction {try $0.execute(sql:"PRAGMA wal_checkpoint(FULL)")}
        let before=try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {r.readSnapshotCache.readVersion(db)}}
        try r.dbQueue.writeWithoutTransaction {db in
            try db.execute(sql:"PRAGMA cache_size=1")
            defer {try? db.execute(sql:"PRAGMA cache_size=-2000")}
            try db.inTransaction {
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.temporary',?) WHERE type='message'",arguments:[String(repeating:"rolled back ",count:1024)])
                return .rollback
            }
        }
        try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            let after=r.readSnapshotCache.readVersion(db)
            print("P9-r2 checkpoint/spilled rollback before_version=\(before != nil) after_version=\(after != nil) stable=\(before == after)")
            XCTAssertTrue(after == nil || after == before,"A reset/empty WAL may omit identity; it must not invent a different committed snapshot")
            XCTAssertNil(try r.record(db,"spill-0")["temporary"])
            XCTAssertEqual(try r.record(db,"spill-0")["revision"] as? Int,1)
        }}
    }

    func testEveryCommittedFamilyAndEventInvalidatesAndRollbackDoesNotLeak() throws {
        let f = try ReadPerformanceFixture("CL-254-cache"),r = f.router
        let reader = try XCTUnwrap(r.readers)
        try f.save([("status",["id":"queued","project_id":"project","category":"queued","name":"Queued","revision":1]),
                    ("group",["id":"fixture-epic","project_id":"project","kind":"epic","name":"Fixture","revision":1])])
        let cases = [("task","ticket"),("group","Triage"),("group","Epic"),("status","status"),("message","note"),("project","settings"),("task","archive"),("task","purge")]
        for (index,item) in cases.enumerated() {
            let (type,kind) = item,id = "record-\(index)"
            var value: JSON = ["id":id,"project_id":"project","revision":1,"name":kind]
            if type == "task" {value["status_id"] = "queued";value["epic_id"] = "fixture-epic"}
            if type == "project" {value["project_id"] = id;value["settings"] = ["read_fixture":1]}
            if type == "group" {value["kind"] = kind.lowercased();value["task_ids"] = [] as [String]}
            if type == "message" {value["body"] = "original note"}
            try f.save([(type,value)])
            var observedVersion:String?
            func read() throws -> JSON {
                try reader.read { db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                    observedVersion=r.readSnapshotCache.readVersion(db)
                    let first = try r.record(db,id,type:type)
                    XCTAssertEqual(try jsonString(first),try jsonString(r.record(db,id,type:type)))
                    return first
                }}
            }
            XCTAssertEqual(try read()["revision"] as? Int,1)
            let originalVersion=try XCTUnwrap(observedVersion)
            value["revision"] = 2;value["name"] = "changed";value["archived"] = true
            // No event: data_version must cover writes, not only event cursors.
            try f.save([(type,value)])
            XCTAssertEqual(try read()["revision"] as? Int,2,kind)
            let committedVersion=try XCTUnwrap(observedVersion)
            XCTAssertNotEqual(committedVersion,originalVersion,kind)
            try r.dbQueue.writeWithoutTransaction {db in
                try r.withValidatedDomainTransaction(db) {
                    var rolled = value;rolled["revision"] = 3
                    try r.save(db,rolled,type:type);return .rollback
                }
            }
            XCTAssertEqual(try read()["revision"] as? Int,2,"rollback \(kind)")
            XCTAssertEqual(observedVersion,committedVersion,"rollback \(kind)")
            try r.dbQueue.write {try $0.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
            XCTAssertThrowsError(try read(),"delete \(kind)")
            XCTAssertNotEqual(observedVersion,committedVersion,"delete \(kind)")
        }
        try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {_ = try r.records(db,type:"message",project:"project")}}
        try r.dbQueue.write {try r.event($0,caller:f.owner,project:"project",entity:nil,kind:"event-only")}
        try reader.read {db in
            var sql: [String] = [];db.trace {if case .statement(let s) = $0 {sql.append(s.sql)}};defer {db.trace(nil)}
            try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {_ = try r.records(db,type:"message",project:"project")}
            XCTAssertTrue(sql.contains {$0.contains("FROM records WHERE type")})
        }
    }

    func testCacheIsScopedToExactCallerGrantProjectAndConnection() throws {
        let f = try ReadPerformanceFixture("CL-254-scope"),r = f.router,reader = try XCTUnwrap(r.readers)
        try f.save([("message",["id":"é","project_id":"one","revision":1]),("message",["id":"e\u{301}","project_id":"two","revision":1])])
        var caller = Caller(role:"assistant",installation:"same",projectIDs:["one"],assistantGrants:["one":["read":true]])
        func read(_ db: Database,_ pid: String) throws -> [JSON] {
            try r.readSnapshotCache.withSnapshot(db,caller:caller) {try r.records(db,type:"message",project:pid)}
        }
        try reader.read {db in
            XCTAssertEqual(try read(db,"one").first?["id"] as? String,"é")
            XCTAssertEqual(try read(db,"two").first?["id"] as? String,"e\u{301}")
            var queries = 0;db.trace {if case .statement(let s) = $0,s.sql.contains("FROM records WHERE type") {queries += 1}};defer {db.trace(nil)}
            _ = try read(db,"one");XCTAssertEqual(queries,0)
            caller.assistantGrants["one"]?["read"] = false
            _ = try read(db,"one");XCTAssertEqual(queries,1,"Grant changes cannot hit another caller namespace")
            caller.projectIDs = ["two"]
            _ = try read(db,"two");XCTAssertEqual(queries,2)
        }
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let second = try DatabaseQueue(path:r.root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? second.close()}
        try second.read {db in
            var queries = 0;db.trace {if case .statement(let s) = $0,s.sql.contains("FROM records WHERE type") {queries += 1}};defer {db.trace(nil)}
            _ = try read(db,"two");XCTAssertEqual(queries,1,"Different connections cannot alias equal numeric data_version values")
        }
        XCTAssertThrowsError(try r.handle(method:"task_list",params:["project_id":"one"],caller:caller))
    }

    func testOversizedQueriesAndWriterReadsBypassRetention() throws {
        try QualificationSuite.requireEnabled()
        let f = try ReadPerformanceFixture("CL-254-bounds"),r = f.router,reader = try XCTUnwrap(r.readers)
        try f.save((0..<2050).map {("message",["id":"large-\($0)","project_id":"project","revision":1] as JSON)})
        try reader.read {db in
            var queries = 0;db.trace {if case .statement(let s) = $0,s.sql.contains("FROM records WHERE type") {queries += 1}};defer {db.trace(nil)}
            try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                for _ in 0..<2 {XCTAssertEqual(try r.records(db,type:"message",project:"project").count,2050)}
            }
            XCTAssertEqual(queries,2,"Oversized corpora must bypass retention")
        }
        try r.dbQueue.read {db in
            var queries = 0;db.trace {if case .statement(let s) = $0,s.sql.contains("FROM records WHERE type") {queries += 1}};defer {db.trace(nil)}
            try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                for _ in 0..<2 {_ = try r.records(db,type:"message",project:"empty")}
            }
            XCTAssertEqual(queries,2,"Writer connections never cache even within an explicit frame")
        }
    }

    func testTaskKeyLookupSelectsOnlyMatchingScopedCanonicalRows() throws {
        let f = try ReadPerformanceFixture("CL-254-key"),r = f.router
        let p = try f.call("project_create",["name":"Lookup","key_prefix":"LOOK"]),pid = p["id"] as! String
        let epic = try f.call("epic_create",["project_id":pid,"name":"Lookup fixture"])
        let t = try f.call("task_create",["project_id":pid,"epic_id":epic["id"]!,"title":"Selected"]),tid = t["id"] as! String,key = t["key"] as! String
        try r.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO records VALUES('unrelated',?,'task',1,?)",arguments:[pid,"{\"key\":\"OTHER-1\"}"])
        }
        XCTAssertEqual(try f.call("task_get",["project_id":pid,"key":key])["id"] as? String,tid)
        var duplicate = t;duplicate["id"] = "duplicate"
        try f.save([("task",duplicate)])
        XCTAssertThrowsError(try f.call("task_get",["project_id":pid,"key":key])) {XCTAssertEqual(($0 as? CoreError)?.code,"AMBIGUOUS_TASK")}
    }

    func testSnapshotPinsGenerationAcrossConcurrentCommitAndNextReadSeesIt() throws {
        let f = try ReadPerformanceFixture("CL-254-snapshot"),r = f.router,reader = try XCTUnwrap(r.readers)
        try f.save([("message",["id":"one","project_id":"project","revision":1])])
        try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
            XCTAssertEqual(try r.record(db,"one")["revision"] as? Int,1)
            try f.save([("message",["id":"one","project_id":"project","revision":2])])
            XCTAssertEqual(try r.record(db,"one")["revision"] as? Int,1,"One read stays a consistent snapshot")
        }}
        try reader.read {db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {XCTAssertEqual(try r.record(db,"one")["revision"] as? Int,2)}}
    }

    func testRetiredGenerationReleasesDecodedPayloadWithoutCallerPoolDrain() throws {
        let f = try ReadPerformanceFixture("CL-254-retired-generation"),r = f.router
        let reader = try XCTUnwrap(r.readers)
        try f.save([("message",["id":"generation","project_id":"project","revision":1,
            "body":String(repeating:"retired payload ",count:8192)])])
        weak var retiredPayload: AnyObject?
        // A service request queue may inherit a pool that outlives many calls.
        // Check lifetime before that outer pool drains, not just the cache count.
        try autoreleasepool {
            try reader.read {db in
                try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                    let value = try r.record(db,"generation",type:"message")
                    retiredPayload = value["body"] as AnyObject
                }
            }
            XCTAssertNotNil(retiredPayload,"The current generation retains its payload")
            try r.dbQueue.write {db in try db.execute(sql:"DELETE FROM records WHERE id='generation'")}
            try reader.read {db in
                try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                    XCTAssertTrue(try r.records(db,type:"message",project:"project").isEmpty)
                }
            }
            XCTAssertTrue(retiredPayload == nil,"Replacing a generation must release its decoded payload before the caller's pool drains")
        }
    }

}
