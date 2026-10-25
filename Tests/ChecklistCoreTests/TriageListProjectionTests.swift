import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Current-schema template, with retained history rather than a live-store copy.
private final class TriageListFixture {
    let store: ReadPerformanceFixture
    let pid: String
    init(count: Int) throws {
        store = try ReadPerformanceFixture("CL-254-triages")
        pid = try store.call("project_create",["name":"Triage list template","key_prefix":"TL"])["id"] as! String
        let statuses = try store.router.dbQueue.read {try store.router.records($0,type:"status",project:pid)}
        var rows: [(String,JSON)] = []
        for i in 0..<count {
            let gid = "triage-\(i)", ids = ["task-\(i)-0","task-\(i)-1"]
            for (j,id) in ids.enumerated() {
                rows.append(("task",["id":id,"project_id":pid,"key":"TL-\(i*2+j+1)","title":id,"revision":1,"status_id":statuses[(i+j)%statuses.count]["id"]!,"created_at":"2026-01-01T00:00:00Z"]))
                for n in 0..<3 {
                    rows.append(("finding",["id":"finding-\(i)-\(j)-\(n)","project_id":pid,"task_id":id,"cause_id":"cause-\(j)","revision":1]))
                }
            }
            var group: JSON = ["id":gid,"project_id":pid,"key":"TL-T\(i+1)","name":gid,"kind":"triage","revision":1,"phase":"implementation","members":ids.map {["task_id":$0,"handling_phase":"implementation"]},"task_ids":ids,"archived":i%3 == 0,"created_at":"2026-01-01T00:00:00Z"]
            if i%4 == 0 { group.removeValue(forKey:"phase") }
            if i%5 == 0 { group["orchestration"] = ["state":"active","session_id":"missing","session_authorization_generation":"old"] }
            rows.append(("group",group))
            for n in 0..<4 {
                let mid = "membership-\(i)-\(n)"
                rows.append(("triage_membership_interval",["id":mid,"project_id":pid,"triage_id":gid,"task_id":ids[n%2],"revision":1]))
                if n%2 == 0 {rows.append(("triage_membership_exit",["id":"exit-\(i)-\(n)","project_id":pid,"triage_id":gid,"membership_id":mid,"revision":1]))}
            }
            for n in 0..<3 {
                let bid = "batch-\(i)-\(n)"
                rows.append(("batch",["id":bid,"project_id":pid,"triage_id":gid,"revision":1,"phase":"implementation","created_at":"2026-01-01T00:00:00Z","triage_revision":1,"members":ids.map {["task_id":$0]},"digest":"digest-\(bid)"]))
                if n == 1 {rows.append(("batch_claim",["id":"claim-\(i)","project_id":pid,"batch_id":bid,"revision":1]))}
                if n == 2 {rows.append(("batch_disposition",["id":"discard-\(i)","project_id":pid,"batch_id":bid,"revision":1]))}
            }
        }
        try store.save(rows)
    }
    func list(_ input: JSON = [:]) throws -> JSON {
        var p = input;p["project_id"] = pid
        return try store.call("triage_list",p)
    }
}

final class TriageListProjectionTests: XCTestCase {
    func testEveryProjectedFieldMatchesFullRowsAndOrder() throws {
        let f = try TriageListFixture(count:3)
        let full = try f.list(),rows = full["groups"] as! [JSON]
        XCTAssertEqual(rows.compactMap {$0["id"] as? String},["triage-0","triage-1","triage-2"])
        // triage_list is unpaged: preserve its complete ordered groups envelope.
        XCTAssertEqual(Set(full.keys),["groups"])
        for fields in CommandRouter.triageListFields.sorted().map({[$0]}) + [["name","status_category","member_count"],["phase","active_attention","membership_history","batches"]] {
            let projected = try f.list(["fields":fields])
            let expected = f.store.router.listProjection(rows,fields:Set(fields).union(["id","key","revision"]))
            XCTAssertEqual(try jsonString(projected["groups"]!),try jsonString(expected),fields.joined(separator:","))
            XCTAssertEqual(Set(projected.keys),Set(full.keys))
        }
        XCTAssertEqual(try jsonString(f.list(["fields":[String]()]) ),try jsonString(full))
        let batches = rows[0]["batches"] as! [JSON]
        XCTAssertEqual(batches.compactMap {$0["lifecycle"] as? String},["prepared","claimed","discarded"])
        XCTAssertEqual((rows[0]["membership_history"] as! [JSON]).count,4)
        XCTAssertEqual((rows[0]["member_warnings"] as! [JSON]).count,2)
    }

    func testSelectedRowsUnknownFieldsAndCommittedChanges() throws {
        let f = try TriageListFixture(count:2)
        let fields = ["name","status_category","member_count"]
        XCTAssertEqual((try f.list(["key":"tl-t2","fields":fields])["groups"] as! [JSON]).map {$0["id"] as! String},["triage-1"])
        XCTAssertTrue((try f.list(["key":"missing","fields":fields])["groups"] as! [JSON]).isEmpty)
        XCTAssertThrowsError(try f.list(["key":"missing","fields":["unknown"]])) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
        let foreign = try f.store.call("project_create",["name":"Foreign","key_prefix":"FG"])
        let other = try f.store.call("triage_create",["project_id":foreign["id"]!,"name":"Foreign"])
        XCTAssertThrowsError(try f.list(["triage_id":other["id"]!,"fields":fields])) {XCTAssertEqual(($0 as? CoreError)?.code,"NOT_FOUND")}
        _ = try f.list(["fields":fields])
        var group = try f.store.router.dbQueue.read {try f.store.router.record($0,"triage-0",type:"group")}
        do {
            group["members"] = [JSON]();group["task_ids"] = [String]();group["revision"] = 2
            try f.store.save([("group",group)])
        }
        let changed = (try f.list(["triage_id":"triage-0","fields":fields])["groups"] as! [JSON])[0]
        XCTAssertEqual(changed["member_count"] as? Int,0);XCTAssertEqual(changed["status_category"] as? String,"empty")
    }
}

final class TriageListTimingTests: XCTestCase {
    func testProjectedRealSizeTriagesWithinServiceBudget() throws {
        let f = try TriageListFixture(count:250)
        var samples: [Double] = []
        var load = [Double](repeating:0,count:3);getloadavg(&load,3)
        print("L254b template triages=250 members=500 intervals=1000 exits=500 batches=750 findings=1500 load=\(load)")
        for run in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let reply = try f.list(["fields":["name","status_category","member_count"]])
            let seconds = ProcessInfo.processInfo.systemUptime-start
            samples.append(seconds)
            XCTAssertEqual((reply["groups"] as! [JSON]).count,250)
            print("L254b run=\(run) service_ms=\(seconds*1000) bytes=\(try JSONSerialization.data(withJSONObject:reply).count)")
        }
        let medianSeconds = samples.sorted()[2]
        print("L254b median_ms=\(medianSeconds*1000)")
        XCTAssertLessThan(medianSeconds,0.5)
        XCTAssertLessThan(samples.max()!,1)
    }
}
