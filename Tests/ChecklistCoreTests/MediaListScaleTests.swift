import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-307: the list index of a published round costs work linear in its items, and its
/// results equal those of the former per-item `json_each` manifest join.
final class MediaListScaleTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let lists = MediaListQueryTests()

    /// Disposition rule of `publish`: index is the item's position (item-0000 ...).
    static func expected(_ index: Int,published: Int) -> String {
        guard index < published else {return "pending"}
        if index % 3 == 0 || index % 5 == 0 || index % 7 == 0 {
            if index % 11 == 0 {return "stale"}
            return index % 3 == 0 ? "accepted" : index % 5 == 0 ? "changes_requested" : "excluded"
        }
        return index % 13 == 0 ? "stale" : "pending"
    }
    /// Seeds `count` items, publishes the first `count - unpublished` in one manifest and adds
    /// owner decisions (some on an older basis) and stale-predecessor marks per `expected`.
    func publish(_ f: Fixture,_ round: inout JSON,count: Int,unpublished: Int = 0) throws {
        try lists.seed(f,round,count:count)
        round = try f.router.dbQueue.write {db -> JSON in
            let (type,context) = try f.router.mediaRoundParts(db,round)
            let items = try f.router.mediaItems(db,round:round),published = count - unpublished
            let pairs = try items.prefix(published).map {($0,try f.router.scoped(db,$0["draft_target_id"] as! String,f.project,type:"media_item_target"))}
            var current = try f.router.scoped(db,round["id"] as! String,f.project,type:"media_round")
            _ = try f.router.mediaManifest(db,round:&current,targets:Array(pairs),typeRevision:type,context:context,caller:f.owner)
            current = f.router.revised(current);try f.router.mediaWrite(db,current,type:"media_round")
            for (index,item) in items.enumerated() {
                var next = item
                if index < published,index % 3 == 0 || index % 5 == 0 || index % 7 == 0 {
                    let target = pairs[index].1
                    let disposition = index % 3 == 0 ? "accepted" : index % 5 == 0 ? "changes_requested" : "excluded"
                    let basis = index % 11 == 0 ? "older-basis" : target["review_basis_signature"] as! String
                    let decision = f.router.mediaRecord(["item_id":item["id"]!,"target_id":target["id"]!,"disposition":disposition,
                        "review_basis_signature":basis,"origin":"human_ui"],project:f.project,caller:f.owner)
                    try f.router.mediaWrite(db,decision,type:"media_owner_decision")
                    next["last_decision_id"] = decision["id"]
                } else if index % 13 == 0 {
                    next["stale_predecessor_decision_id"] = "older-decision"
                } else {continue}
                try f.router.mediaWrite(db,f.router.revised(next),type:"media_item")
            }
            return current
        }
    }
    func pageAll(_ f: Fixture,_ round: JSON,filter: JSON? = nil) throws -> [JSON] {
        var rows: [JSON] = [],cursor: String? = nil
        repeat {
            let response = try lists.page(f,round,list:[:],filter:filter,cursor:cursor)
            rows += response["rows"] as! [JSON];cursor = response["next_cursor"] as? String
        } while cursor != nil
        return rows
    }
    static func key(_ row: JSON) -> [String] {
        ["\(row["id"]!)","\(row["revision"]!)","\(row["target_id"]!)","\(row["order"]!)","\(row["decision_id"] ?? "")","\(row["disposition"]!)"]
    }
    /// The former query, verbatim apart from the fixed ID order and the optional predicate.
    func oldIndex(_ f: Fixture,_ round: JSON,predicate: String = "1") throws -> [[String]] {
        try f.router.dbQueue.read {db in
            let round = try f.router.scoped(db,round["id"] as! String,f.project,type:"media_round")
            return try Row.fetchAll(db,sql:"""
            SELECT i.id,i.revision,t.id target_id,COALESCE(json_extract(i.data,'$.order'),0) item_order,
              d.id decision_id,CASE WHEN d.id IS NULL AND member.value IS NOT NULL AND json_extract(i.data,'$.stale_predecessor_decision_id') IS NOT NULL THEN 'stale' WHEN d.id IS NULL OR member.value IS NULL THEN 'pending' WHEN json_extract(d.data,'$.review_basis_signature') IS NOT json_extract(member.value,'$.review_basis_signature') THEN 'stale' ELSE json_extract(d.data,'$.disposition') END disposition
            FROM records i LEFT JOIN records m ON m.id=:manifest AND m.project_id=i.project_id AND m.type='media_round_manifest'
            LEFT JOIN json_each(m.data,'$.items') member ON json_extract(member.value,'$.item_id')=i.id
            JOIN records t ON t.id=COALESCE(json_extract(member.value,'$.target_id'),json_extract(i.data,'$.draft_target_id')) AND t.project_id=i.project_id AND t.type='media_item_target'
            LEFT JOIN records d ON d.id=json_extract(i.data,'$.last_decision_id') AND d.project_id=i.project_id AND d.type='media_owner_decision'
            WHERE i.type='media_item' AND i.project_id=:project AND json_extract(i.data,'$.round_id')=:round AND (\(predicate)) ORDER BY CAST(i.id AS BLOB)
            """,arguments:["project":f.project,"round":round["id"] as! String,"manifest":round["manifest_id"] as? String ?? ""]).map {
                ["\($0["id"] as String)","\($0["revision"] as Int)","\($0["target_id"] as String)","\($0["item_order"] as Int)","\(($0["decision_id"] as String?) ?? "")","\($0["disposition"] as String)"]
            }
        }
    }

    func testListIndexMatchesFormerManifestJoinOnSmallRound() throws {
        let f = try Fixture(),type = try f.type(lists.schema());var round = try f.round(type)
        try publish(f,&round,count:80,unpublished:6)
        let old = try oldIndex(f,round)
        XCTAssertEqual(Set(old.map {$0[5]}),["pending","accepted","changes_requested","excluded","stale"])
        XCTAssertEqual(old.map {$0[5]},(0..<80).map {Self.expected($0,published:74)})
        XCTAssertEqual(try pageAll(f,round).map(Self.key),old)
        for dispositions in [["pending"],["accepted"],["changes_requested"],["excluded"],["stale"],["needs_look"],["pending","stale"]] {
            XCTAssertEqual(try pageAll(f,round,filter:["dispositions":dispositions]).map(Self.key),old.filter {dispositions.contains($0[5])},"\(dispositions)")
        }
        let hero = "CAST((SELECT value FROM json_each(t.data,'$.metadata') WHERE key='character') AS BLOB)=CAST('hero' AS BLOB)"
        XCTAssertEqual(try pageAll(f,round,filter:["metadata":["character":"hero"],"hidden_item_ids":["item-0003","item-0077"]]).map(Self.key),
            try oldIndex(f,round,predicate:hero + " AND i.id NOT IN ('item-0003','item-0077')"))
        let counts = try f.call("media_item_counts",["round_id":round["id"]!])
        XCTAssertEqual(counts["total"] as? Int,80)
        XCTAssertEqual(counts["counts"] as? [String:Int],Dictionary(grouping:old,by:{$0[5]}).mapValues(\.count))
        // Round view and decision selection read the manifest members once (same results).
        let view = try f.router.dbQueue.read {try f.router.mediaRoundView($0,round:round,caller:f.owner)}
        XCTAssertEqual((view["items"] as! [JSON]).map {$0["disposition"] as! String},old.map {$0[5]})
        XCTAssertEqual((view["items"] as! [JSON]).filter {$0["published_target"] != nil}.count,74)
        // The plan probes the expanded manifest by key instead of re-reading it per item.
        let plan = try f.router.dbQueue.read {db -> [String] in
            let revision = try f.router.scoped(db,round["type_revision_id"] as! String,f.project,type:"media_review_type_revision")
            let schema = try MediaReviewSchema.parse(revision["schema"] as! JSON)
            let current = try f.router.scoped(db,round["id"] as! String,f.project,type:"media_round")
            let (sql,args) = try f.router.mediaListIndexStatement(["filter":["dispositions":["accepted"]]],round:current,list:try MediaListConfiguration.parse(lists.list,schema:schema),schema:schema)
            return try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql,arguments:args).map {$0["detail"] as String}
        }
        print("CL-307 list index plan:\n" + plan.joined(separator:"\n"))
        XCTAssertTrue(plan.contains("SEARCH i USING INDEX sqlite_autoindex_records_1 (id=?)"),"\(plan)")
        XCTAssertFalse(plan.contains {$0.hasPrefix("SCAN member") && $0.contains("JOIN")},"\(plan)")
        XCTAssertEqual(plan.filter {$0.hasPrefix("SCAN entry")}.count,1,"the manifest is expanded once: \(plan)")
    }

    /// 1 s on a normal host. On an oversubscribed host (load average above the core count,
    /// for example a combined round run) the bound scales with that factor; both are printed.
    static func bound() -> Double {
        var load = [0.0,0.0,0.0];_ = getloadavg(&load,3)
        return max(1.0,load[0] / Double(ProcessInfo.processInfo.activeProcessorCount))
    }
    func measure(_ f: Fixture,_ round: JSON,count: Int,published: Int) throws {
        func timed(_ label: String,bounded: Bool = true,_ body: () throws -> JSON) throws -> JSON {
            let start = Date(),result = try body(),seconds = Date().timeIntervalSince(start)
            let limit = Self.bound()
            print(String(format:"CL-307 %d items %@: %.3f s (bound %.2f s)",count,label,seconds,limit))
            if bounded {XCTAssertLessThanOrEqual(seconds,limit,"\(count) items \(label)")}
            return result
        }
        let expected = (0..<count).map {Self.expected($0,published:published)}
        let first = try timed("first page") {try lists.page(f,round)}
        XCTAssertEqual(first["total"] as? Int,count);XCTAssertEqual((first["rows"] as! [JSON]).count,100)
        XCTAssertEqual(first["counts"] as? [String:Int],Dictionary(grouping:expected,by:{$0}).mapValues(\.count))
        let accepted = try timed("Disposition filter (accepted)") {try lists.page(f,round,filter:["dispositions":["accepted"]])}
        XCTAssertEqual(accepted["total"] as? Int,expected.filter {$0 == "accepted"}.count)
        let pending = try timed("Pending filter") {try lists.page(f,round,filter:["dispositions":["pending"]])}
        XCTAssertEqual(pending["total"] as? Int,expected.filter {$0 == "pending"}.count)
        XCTAssertTrue((pending["rows"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "pending"})
        let next = try timed("next page") {try lists.page(f,round,cursor:first["next_cursor"] as? String)}
        XCTAssertEqual((next["rows"] as! [JSON]).count,100)
        XCTAssertTrue(Set((next["rows"] as! [JSON]).map {$0["id"] as! String}).isDisjoint(with:(first["rows"] as! [JSON]).map {$0["id"] as! String}))
        let pendingNext = try timed("Pending next page") {try lists.page(f,round,filter:["dispositions":["pending"]],cursor:pending["next_cursor"] as? String)}
        XCTAssertEqual((pendingNext["rows"] as! [JSON]).count,100)
        let counts = try timed("media_item_counts") {try f.call("media_item_counts",["round_id":round["id"]!,"list":lists.list])}
        XCTAssertEqual(counts["total"] as? Int,count)
        // Round view is not a list read (it builds every item's publication preview); time only.
        _ = try timed("round view",bounded:false) {try f.router.dbQueue.read {try f.router.mediaRoundView($0,round:round,caller:f.owner)}}
    }
    func testThousandItemPublishedRoundListIsFast() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(),type = try f.type(lists.schema());var round = try f.round(type)
        let start = Date();try publish(f,&round,count:1_000)
        print(String(format:"CL-307 seed 1000 items: %.1f s",Date().timeIntervalSince(start)))
        try measure(f,round,count:1_000,published:1_000)
    }
    func testFiveThousandItemPublishedRoundListIsFast() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(),type = try f.type(lists.schema());var round = try f.round(type)
        let start = Date();try publish(f,&round,count:5_000,unpublished:200)
        print(String(format:"CL-307 seed 5000 items: %.1f s",Date().timeIntervalSince(start)))
        try measure(f,round,count:5_000,published:4_800)
    }
}
