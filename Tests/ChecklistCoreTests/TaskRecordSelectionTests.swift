import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class TaskRecordSelectionTests: XCTestCase {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write {db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:"CREATE TABLE records(id TEXT COLLATE checklist_storage_v2 PRIMARY KEY,project_id TEXT COLLATE checklist_storage_v2,type TEXT COLLATE checklist_storage_v2,revision INTEGER,data TEXT); CREATE INDEX records_scope ON records(project_id,type)")
        }
        return queue
    }
    private func insert(_ db: Database,id:String,project:String = "p",type:String = "manifest",task:String,extra:JSON = [:]) throws {
        var value = extra;value["id"] = id;value["project_id"] = project;value["task_id"] = task;value["revision"] = 1
        try db.execute(sql:"INSERT INTO records VALUES(CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),1,?)",arguments:[Data(id.utf8),Data(project.utf8),Data(type.utf8),try jsonString(value)])
    }
    private func task(_ id:String,project:String = "p") -> JSON {["id":id,"project_id":project]}

    func testSelectionKeepsByteExactUnicodeNULProjectAndDatabaseScopes() throws {
        let f = try ReadPerformanceFixture("CL-287-selection-identities"),queue = try database(),other = try database()
        try queue.write {db in
            let ids = ["é","e\u{301}","x\0suffix","x"]
            for (index,id) in ids.enumerated() {try insert(db,id:"m\(index)",task:id)}
            try insert(db,id:"foreign",project:"p\0other",task:ids[0])
            try f.router.withTaskRecordSelection(db,tasks:ids.map {task($0)}) {
                var selected = Set<Int64>()
                for id in ids {
                    let rows = try XCTUnwrap(f.router.selectedTaskRecordIDs(db,type:"manifest",task:task(id)))
                    XCTAssertEqual(rows.count,1);selected.formUnion(rows)
                }
                XCTAssertEqual(selected.count,4)
                XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:task("absent")))
                XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:task(ids[0],project:"p\0other")))
                try other.read {XCTAssertNil(try f.router.selectedTaskRecordIDs($0,type:"manifest",task:task(ids[0])))}
            }
            XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:task(ids[0])))
        }
    }

    func testRowsCountOrderPredicateAndWindowsMatchGenericQueries() throws {
        let f = try ReadPerformanceFixture("CL-287-selection-windows"),queue = try database(),t = task("selected")
        try queue.write {db in
            for index in 0..<31 {try insert(db,id:"m\(index)",task:"selected",extra:["state":index % 2 == 0 ? "kept":"other"])}
            try insert(db,id:"unrelated",task:"other")
            let full = try f.router.scopedTaskRows(db,type:"manifest",task:t,predicate:"json_extract(data,'$.state')='kept'",limit:7,descending:true)
            let count = try f.router.scopedTaskCount(db,type:"manifest",task:t,predicate:"json_extract(data,'$.state')='kept'")
            try f.router.withTaskRecordSelection(db,tasks:[t,task("empty")]) {
                XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:t)?.count,31)
                XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:task("empty")),[])
                XCTAssertEqual(try jsonString(f.router.scopedTaskRows(db,type:"manifest",task:t,predicate:"json_extract(data,'$.state')='kept'",limit:7,descending:true)),try jsonString(full))
                XCTAssertEqual(try f.router.scopedTaskCount(db,type:"manifest",task:t,predicate:"json_extract(data,'$.state')='kept'"),count)
            }
        }
    }

    func testInvalidationRebuildsNewAndMovedRowsAndRestoresNestedFrame() throws {
        let f = try ReadPerformanceFixture("CL-287-selection-invalidation"),queue = try database(),a = task("a"),b = task("b")
        try queue.write {db in
            try insert(db,id:"original",task:"a")
            try f.router.withTaskRecordSelection(db,tasks:[a]) {
                XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:a)?.count,1)
                try f.router.withTaskRecordSelection(db,tasks:[b]) {
                    XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:a))
                    XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:b),[])
                    try insert(db,id:"new",task:"a")
                    try db.execute(sql:"UPDATE records SET data=json_set(data,'$.task_id','b') WHERE id='original'")
                    f.router.invalidateTaskRecordSelection(db,type:"manifest")
                    XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:b)?.count,1)
                }
                let ids = try XCTUnwrap(f.router.selectedTaskRecordIDs(db,type:"manifest",task:a))
                XCTAssertEqual(ids.count,1)
                let selectedID = try String.fetchOne(db,sql:"SELECT id FROM records WHERE rowid=?",arguments:[ids[0]])
                XCTAssertEqual(selectedID,"new")
            }
            enum Expected: Error {case stop}
            XCTAssertThrowsError(try f.router.withTaskRecordSelection(db,tasks:[a]) {throw Expected.stop})
            XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:a))
        }
    }

    func testBudgetFallbackNeverReturnsPartialAndInvalidationReleasesBudget() throws {
        let f = try ReadPerformanceFixture("CL-287-selection-budget"),queue = try database(),t = task("t")
        try queue.write {db in
            for index in 0..<4097 {try insert(db,id:"a\(index)",task:"t")}
            try f.router.withTaskRecordSelection(db,tasks:[t]) {
                XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:t))
                try db.execute(sql:"DELETE FROM records WHERE id='a4096'")
                f.router.invalidateTaskRecordSelection(db,type:"manifest")
                XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"manifest",task:t)?.count,4096)
                try insert(db,id:"one-attempt",type:"attempt",task:"t")
                XCTAssertNil(try f.router.selectedTaskRecordIDs(db,type:"attempt",task:t))
                try db.execute(sql:"DELETE FROM records WHERE type='manifest'")
                f.router.invalidateTaskRecordSelection(db,type:"manifest")
                XCTAssertEqual(try f.router.selectedTaskRecordIDs(db,type:"attempt",task:t)?.count,1)
            }
        }
    }
}
