import XCTest
import GRDB
@testable import ChecklistCore

final class ActiveDescendantReadScopeTests: XCTestCase {
    func testActiveGraphMatchesRetainedHistoryTraversalAndRefreshesAfterWrite() throws {
        let f = try ReadPerformanceFixture("CL-251-descendants"),r = f.router,pid = "project"
        let root: JSON = ["id":"root","project_id":pid,"revision":1,"state":"active"]
        func attempt(_ id: String,_ parent: String,_ state: String = "active",project: String = "project") -> (String,JSON) {
            ("attempt",["id":id,"project_id":project,"revision":1,"state":state,"parent_attempt_id":parent])
        }
        try f.save([("attempt",root),attempt("child","root"),attempt("grandchild","child"),
                    attempt("ended","root","released"),attempt("behind-ended","ended"),
                    attempt("unrelated","elsewhere"),attempt("foreign","root",project:"other"),
                    attempt("cycle","cycle"),attempt("root-nul","root\0tail"),attempt("accent","é")]
                    + (0..<128).map {attempt("retained-\($0)","root","released")})
        func descendants() throws -> [String] {
            try r.dbQueue.read {try r.activeDescendants($0,attempt:root).map {$0["id"] as! String}}
        }
        XCTAssertEqual(try descendants(),["child","grandchild"])
        try r.dbQueue.write {db in
            var child = try r.record(db,"child",type:"attempt")
            child["state"] = "released";try r.save(db,r.revised(child),type:"attempt")
        }
        XCTAssertEqual(try descendants(),[],"No descendant behind an ended parent may survive a new snapshot")
    }

    func testCandidateSelectionPreservesFoundationDuplicateStateAndMalformedFailure() throws {
        let f = try ReadPerformanceFixture("CL-251-descendant-selection"),r = f.router
        let root: JSON = ["id":"root","project_id":"project","revision":1,"state":"active"]
        try f.save([("attempt",root),("attempt",["id":"child","project_id":"project","revision":1,"state":"active","parent_attempt_id":"root"])])
        try r.dbQueue.write {db in
            // SQLite's first-value json_extract alone would hide this active child.
            let raw = #"{"id":"child","project_id":"project","revision":1,"state":"released","st\u0061te":"active","parent_attempt_id":"root"}"#
            try db.execute(sql:"UPDATE records SET data=? WHERE id='child'",arguments:[raw])
            let expected = try r.records(db,type:"attempt",project:"project").filter {$0["state"] as? String == "active" && $0["parent_attempt_id"] as? String == "root"}
            XCTAssertEqual(try r.activeDescendants(db,attempt:root).map {$0["id"] as! String},expected.map {$0["id"] as! String})
            try db.execute(sql:"UPDATE records SET data='{' WHERE id='child'")
            XCTAssertThrowsError(try r.activeDescendants(db,attempt:root)) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")}
        }
    }
}
