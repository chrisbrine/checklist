import XCTest
import GRDB
@testable import ChecklistCore

final class ReadSnapshotCacheTests: XCTestCase {
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
            func read() throws -> JSON {
                try reader.read { db in try r.readSnapshotCache.withSnapshot(db,caller:f.owner) {
                    let first = try r.record(db,id,type:type)
                    XCTAssertEqual(try jsonString(first),try jsonString(r.record(db,id,type:type)))
                    return first
                }}
            }
            XCTAssertEqual(try read()["revision"] as? Int,1)
            value["revision"] = 2;value["name"] = "changed";value["archived"] = true
            // No event: data_version must cover writes, not only event cursors.
            try f.save([(type,value)])
            XCTAssertEqual(try read()["revision"] as? Int,2,kind)
            try r.dbQueue.writeWithoutTransaction {db in
                try r.withValidatedDomainTransaction(db) {
                    var rolled = value;rolled["revision"] = 3
                    try r.save(db,rolled,type:type);return .rollback
                }
            }
            XCTAssertEqual(try read()["revision"] as? Int,2,"rollback \(kind)")
            try r.dbQueue.write {try $0.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
            XCTAssertThrowsError(try read(),"delete \(kind)")
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
