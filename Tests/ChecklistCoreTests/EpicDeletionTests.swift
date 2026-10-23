import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private func deletionFingerprint(excluding: Set<String> = []) throws -> String {
        try router.dbQueue.read { db in
            var rows: [String] = []
            for table in ["metadata","records","commands","events","cursors"] {
                let columns = try Row.fetchAll(db,sql:"PRAGMA table_info(\(table))").map { $0["name"] as String }
                let values = columns.map { "typeof(\($0)) || ':' || hex(CAST(\($0) AS BLOB))" }.joined(separator:" || '|' || ")
                for row in try Row.fetchAll(db,sql:"SELECT rowid AS position, \(values) AS bytes FROM \(table) ORDER BY rowid") {
                    let key = table + ":" + String(row["position"] as Int64)
                    if !excluding.contains(key) { rows.append(key + ":" + (row["bytes"] as String)) }
                }
            }
            return ChecklistCore.hash(Data(rows.joined(separator:"\n").utf8))
        }
    }
    func testEpicDeleteActiveAndArchivedPreservesEveryOtherRowAndReplay() throws {
        let (p,agent) = try agentChangeFixture(),pid = p["id"]!
        _ = try task(p,"Unrelated ticket");_ = try project("Unrelated project","OTHER")
        for archived in [false,true] {
            var epic = try call("epic_create",["project_id":pid,"name":"Mistaken empty Epic"],agent)
            if archived { epic = try call("epic_edit",["project_id":pid,"epic_id":epic["id"]!,"expected_revision":epic["revision"]!,"archived":true],agent) }
            let gid = epic["id"] as! String,command = UUID().uuidString
            let removed: Set<String> = try router.dbQueue.read { db in
                var keys = Set(try Int64.fetchAll(db,sql:"SELECT rowid FROM records WHERE id=?",arguments:[gid]).map {"records:\($0)"})
                keys.formUnion(try Int64.fetchAll(db,sql:"SELECT seq FROM events WHERE entity_id=?",arguments:[gid]).map {"events:\($0)"});return keys
            }
            // Make unrelated pruning due: neither deletion nor retry may run it.
            try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
                try router.save(db,["id":uuid(),"project_id":pid,"revision":1,"task_id":"missing-ticket","task_revision":1,"created_at":"2000-01-01T00:00:00Z"],type:"cleanup_preview")
                try db.execute(sql:"INSERT INTO cursors(token,principal,scope,sequence,incarnation,created_at) VALUES (?,?,?,?,?,0)",arguments:[uuid(),"legacy","scope",0,router.incarnation])
                return .commit
            } }
            router.lastRoutinePrune = nil
            let before = try deletionFingerprint(excluding:removed)
            let sequence = try router.dbQueue.read { try Int64.fetchOne($0,sql:"SELECT seq FROM sqlite_sequence WHERE name='events'")! }
            let input: JSON = ["project_id":pid,"epic_id":gid,"expected_revision":epic["revision"]!]
            let result = try call("epic_delete",input,agent,command)
            XCTAssertEqual(result["deleted"] as? Bool,true);XCTAssertEqual(result["expected_revision"] as? Int,epic["revision"] as? Int)
            XCTAssertEqual(result["origin"] as? String,"agent");XCTAssertEqual(result["actor"] as? String,agent.principal)
            let added: Set<String> = try router.dbQueue.read { db in
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE id=?",arguments:[gid]),0)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE entity_id=?",arguments:[gid]),0)
                let event = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT seq,entity_id,actor,occurred_at,data FROM events WHERE kind='epic_deleted' ORDER BY seq DESC LIMIT 1"))
                XCTAssertEqual(event["entity_id"] as String,pid as! String);XCTAssertEqual(event["actor"] as String,agent.principal)
                XCTAssertFalse((event["occurred_at"] as String).isEmpty)
                let data = jsonObject(event["data"]);XCTAssertEqual(data["key"] as? String,epic["key"] as? String);XCTAssertEqual(data["name"] as? String,epic["name"] as? String)
                XCTAssertEqual(try Int64.fetchOne(db,sql:"SELECT seq FROM sqlite_sequence WHERE name='events'"),sequence+1)
                let receipt = try XCTUnwrap(Int64.fetchOne(db,sql:"SELECT rowid FROM commands WHERE command_id=?",arguments:[command]))
                return ["events:\(event["seq"] as Int64)","commands:\(receipt)"]
            }
            XCTAssertEqual(try deletionFingerprint(excluding:added),before,"Every other stored row must retain its exact bytes and rowid")
            let after = try deletionFingerprint()
            router.lastRoutinePrune = nil
            XCTAssertEqual(try call("epic_delete",input,agent,command)["epic_id"] as? String,gid)
            XCTAssertEqual(try deletionFingerprint(),after,"A lost-reply retry must not add another event")
        }
        XCTAssertEqual(try call("epic_create",["project_id":pid,"name":"Next"])["key"] as? String,"AR-E3")
    }
    func testEpicDeleteRefusesCurrentAndHistoricalMembershipFromEveryPath() throws {
        let p = try project()
        for route in ["create","edit","membership"] {
            let epic = try call("epic_create",["project_id":p["id"]!,"name":route]),gid = epic["id"] as! String
            var ticket = route == "create" ? try call("task_create",["project_id":p["id"]!,"title":"Member","epic_id":gid]) : try task(p)
            if route == "edit" { ticket = try call("task_edit",["project_id":p["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!,"patch":["epic_id":gid]]) }
            if route == "membership" { _ = try call("group_membership",["project_id":p["id"]!,"group_id":gid,"expected_revision":1,"task_id":ticket["id"]!,"action":"add"]);ticket = try call("task_get",["project_id":p["id"]!,"task_id":ticket["id"]!]) }
            var current = try call("epic_list",["project_id":p["id"]!,"key":epic["key"]!])["groups"] as! [JSON]
            assertCode("EPIC_HAS_TICKETS") { _ = try self.call("epic_delete",["project_id":p["id"]!,"epic_id":gid,"expected_revision":current[0]["revision"]!]) }
            _ = try call("task_edit",["project_id":p["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!,"patch":["epic_id":NSNull()]])
            current = try call("epic_list",["project_id":p["id"]!,"key":epic["key"]!])["groups"] as! [JSON]
            let before = try deletionFingerprint()
            assertCode("EPIC_HELD_TICKETS") { _ = try self.call("epic_delete",["project_id":p["id"]!,"epic_id":gid,"expected_revision":current[0]["revision"]!]) }
            XCTAssertEqual(try deletionFingerprint(),before)
        }
    }
    func testEpicDeleteRefusesReferencesAndUnprovedLegacyHistoryWithoutWrites() throws {
        let p = try project()
        for source in ["record","event","own_event_reference","event_entity","legacy"] {
            let epic = try call("epic_create",["project_id":p["id"]!,"name":source]),gid = epic["id"] as! String
            try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
                if source == "legacy" { var old = epic;old["revision"] = 3;try router.save(db,old,type:"group") }
                else if source == "event" { try router.event(db,caller:owner,project:p["id"] as? String,entity:p["id"] as? String,kind:"fixture_reference",data:["nested":["epic_id":gid]]) }
                else if source == "event_entity" {
                    let target = try String.fetchOne(db,sql:"SELECT id FROM events WHERE entity_id=?",arguments:[gid])!
                    try router.event(db,caller:owner,project:p["id"] as? String,entity:target,kind:"fixture_event_reference")
                }
                else {
                    let target = source == "record" ? gid : try String.fetchOne(db,sql:"SELECT id FROM events WHERE entity_id=?",arguments:[gid])!
                    try router.save(db,["id":uuid(),"project_id":p["id"]!,"revision":1,"nested":[target:true]],type:"message")
                }
                return .commit
            } }
            let before = try deletionFingerprint()
            assertCode(source == "legacy" ? "EPIC_HISTORY_UNPROVEN" : "EPIC_REFERENCED") { _ = try self.call("epic_delete",["project_id":p["id"]!,"epic_id":gid,"expected_revision":source == "legacy" ? 3 : 1]) }
            XCTAssertEqual(try deletionFingerprint(),before)
        }
    }
    func testEpicDeleteRequiresRevisionScopeWorkerAndProjectPermission() throws {
        let (p,agent) = try agentChangeFixture(),epic = try call("epic_create",["project_id":p["id"]!,"name":"Empty"])
        let input: JSON = ["project_id":p["id"]!,"epic_id":epic["id"]!,"expected_revision":1]
        var missing = input;missing.removeValue(forKey:"expected_revision")
        assertCode("INVALID_INPUT") { _ = try self.call("epic_delete",missing,agent) }
        var stale = input;stale["expected_revision"] = 2
        assertCode("REVISION_CONFLICT") { _ = try self.call("epic_delete",stale,agent) }
        let other = try project("Other","O");var foreign = input;foreign["project_id"] = other["id"]!
        assertCode("NOT_FOUND") { _ = try self.call("epic_delete",foreign) }
        assertCode("FORBIDDEN") { _ = try self.call("epic_delete",foreign,agent) }
        let triage = try call("triage_create",["project_id":p["id"]!,"name":"Triage"]);var wrong = input;wrong["epic_id"] = triage["id"]!
        assertCode("INVALID_INPUT") { _ = try self.call("epic_delete",wrong,agent) }
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[p["id"] as! String])
        XCTAssertFalse(router.toolCatalog(assistant).contains {$0["name"] as? String == "epic_delete"})
        assertCode("FORBIDDEN") { _ = try self.call("epic_delete",input,assistant) }
        var policy = try currentPolicy(p);policy["agent_rule_changes"] = "owner_only"
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":policy])
        assertCode("HUMAN_CHANNEL_REQUIRED") { _ = try self.call("epic_delete",input,agent) }
    }
}

extension CoreTests {
    func testEpicDeleteIndexedThirtyThousandRecordsAndEventsAndConcurrentRead() throws {
        let p = try project(),pid = p["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Performance target"]),gid = epic["id"] as! String
        try router.dbQueue.write { db in
            // Generated retained corpus in this disposable component store only.
            try db.execute(sql:"""
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<30000)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT 'padding-record-'||x,?, 'message',1,
                  json_object('id','padding-record-'||x,'project_id',?,'revision',1,'nested',json_object('target','unrelated-'||x),'body','Retained synthetic padding') FROM n
                """,arguments:[pid,pid])
            try db.execute(sql:"""
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<30000)
                INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
                SELECT 'padding-event-'||x,?,'padding-record-'||x,'fixture','padding','2026-10-22T00:00:00Z',json_object('nested',json_object('id','unrelated-'||x)) FROM n
                """,arguments:[pid])
            for (sql,args,index) in [
                ("SELECT 1 FROM epic_guard_members WHERE project=? AND epic=?",StatementArguments([Data(pid.utf8),Data(gid.utf8)]),"epic_guard_membership"),
                ("SELECT id,kind FROM events WHERE project_id=CAST(? AS TEXT) AND entity_id=CAST(? AS TEXT) ORDER BY seq LIMIT 10001",StatementArguments([Data(pid.utf8),Data(gid.utf8)]),"events_scope"),
                ("SELECT source_id FROM epic_guard_refs WHERE target=?",StatementArguments([Data(gid.utf8)]),"epic_guard_incoming")
            ] {
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql,arguments:args).map { $0["detail"] as String }.joined(separator:"\n")
                XCTAssertTrue(plan.contains("SEARCH"),plan);XCTAssertTrue(plan.contains(index),plan)
                XCTAssertFalse(plan.contains("SCAN records") || plan.contains("SCAN events"),plan)
            }
        }
        XCTAssertTrue(CommandRouter.runsOutsideSerialQueue("epic_delete"),"The real service must dispatch deletion outside its serial coordinator queue")
        // A deterministic barrier inside deletion proves that the read really
        // overlaps the writer, even when the indexed guard takes only milliseconds.
        let reached = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        try router.dbQueue.writeWithoutTransaction { db in
            db.add(function:DatabaseFunction("fixture_epic_delete_barrier",argumentCount:0) { _ in
                reached.signal()
                guard release.wait(timeout:.now()+5) == .success else {throw CoreError("FIXTURE_TIMEOUT","Concurrent read did not finish")}
                return 0
            })
            try db.execute(sql:"CREATE TEMP TRIGGER fixture_delete_barrier BEFORE DELETE ON main.records WHEN OLD.id='\(gid)' BEGIN SELECT fixture_epic_delete_barrier(); END")
        }
        defer {release.signal()}
        let finished = expectation(description:"bounded deletion"),r = router!,c = owner
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos:.userInitiated).async {
            defer {finished.fulfill()}
            do {
                let reply = try r.handle(method:"epic_delete",params:["project_id":pid,"epic_id":gid,"expected_revision":1,"command_id":UUID().uuidString],caller:c)
                XCTAssertEqual((reply["data"] as? JSON)?["deleted"] as? Bool,true)
            } catch {XCTFail("Deletion failed: \(error)")}
        }
        XCTAssertEqual(reached.wait(timeout:.now()+2),.success)
        let readStart = ProcessInfo.processInfo.systemUptime
        let info = try call("service_info")
        let readSeconds = ProcessInfo.processInfo.systemUptime-readStart
        XCTAssertEqual(info["name"] as? String,"Checklist")
        XCTAssertLessThan(readSeconds,0.5,"A read must answer while epic_delete is still in flight")
        release.signal()
        wait(for:[finished],timeout:2)
        let deleteSeconds = ProcessInfo.processInfo.systemUptime-start
        XCTAssertLessThan(deleteSeconds,1.0,"30,000 records + 30,000 events: deletion bound is one second including the read barrier")
        print("CL-245 r2 records=30000 events=30000 delete_seconds=\(deleteSeconds) concurrent_service_info_seconds=\(readSeconds)")
    }

    func testEpicDeleteLegacyBackfillAndCrossProjectAndGlobalReferenceProof() throws {
        for source in ["record_value","record_key","event_value","event_entity","global","foreign","none"] {
            let p = try project("Legacy " + source,"L"),pid = p["id"] as! String
            let epic = try call("epic_create",["project_id":pid,"name":source]),gid = epic["id"] as! String
            let sourceID = uuid()
            try router.dbQueue.write { db in
                let eventID = try String.fetchOne(db,sql:"SELECT id FROM events WHERE project_id=? AND entity_id=?",arguments:[pid,gid])!
                let target = source == "record_key" || source == "event_entity" ? eventID : gid
                let project: String? = source == "global" ? nil : source == "foreign" ? "foreign-project" : pid
                if source == "event_value" || source == "event_entity" {
                    try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES (?,?,?,'fixture','reference','2026-10-22',?)",arguments:[sourceID,project,source == "event_entity" ? target : pid,try jsonString(["nested":["value":target]])])
                } else if source != "none" {
                    let nested: JSON = source == "record_key" ? [target:true] : ["value":target]
                    try db.execute(sql:"INSERT INTO records VALUES (?,?, 'message',1,?)",arguments:[sourceID,project,try jsonString(["id":sourceID,"project_id":project as Any? ?? NSNull(),"revision":1,"nested":nested])])
                }
            }
            try router.closeStore()
            router = try CommandRouter(root:directory)
            let before = try deletionFingerprint()
            // Clear pending without a request-path scan: exercise the very same
            // finite page worker directly, bounded by this tiny fixture's rows.
            var pages = 0
            for _ in 0..<1000 {
                pages += 1
                let more = try router.epicReferenceIndex.buildPage(router)
                if !more {break}
            }
            XCTAssertLessThan(pages,1000)
            XCTAssertEqual(try deletionFingerprint(),before,"Backfill changes no durable bytes")
            if source == "none" {
                XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
            } else {
                assertCode("EPIC_REFERENCED") {_ = try self.call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])}
                XCTAssertEqual(try deletionFingerprint(),before)
                try router.dbQueue.write { db in
                    try db.execute(sql:"DELETE FROM \(source.hasPrefix("event") ? "events" : "records") WHERE id=?",arguments:[sourceID])
                }
                XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
            }
        }
    }

    func testEpicDeletePendingAndUnavailableIndexRefuseWithoutDurableChanges() throws {
        let p = try project(),pid = p["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Pending"]),gid = epic["id"] as! String
        try router.closeStore();router = try CommandRouter(root:directory)
        let before = try deletionFingerprint()
        do {_ = try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1]);XCTFail("Legacy proof must refuse while pending")}
        catch let error as CoreError {XCTAssertEqual(error.code,"EPIC_HISTORY_UNPROVEN");XCTAssertEqual(error.details["reason"] as? String,"reference_index_pending")}
        XCTAssertEqual(try deletionFingerprint(),before)
        // Finish finite pages directly; the background continuation can safely
        // interleave because both run on the sole writer.
        for _ in 0..<100 {
            if try !router.epicReferenceIndex.buildPage(router) {break}
        }
        let invalid = uuid()
        try router.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO records VALUES (?,?,'message',1,?)",arguments:[invalid,pid,String(repeating:"x",count:EpicReferenceIndex.maximumPayloadBytes+1)])
        }
        let invalidBefore = try deletionFingerprint()
        do {_ = try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1]);XCTFail("Oversized unproved payload must refuse")}
        catch let error as CoreError {XCTAssertEqual(error.code,"EPIC_HISTORY_UNPROVEN");XCTAssertEqual(error.details["reason"] as? String,"reference_index_unavailable");XCTAssertEqual(error.details["source_id"] as? String,invalid)}
        XCTAssertEqual(try deletionFingerprint(),invalidBefore)
        try router.dbQueue.write {try $0.execute(sql:"DELETE FROM records WHERE id=?",arguments:[invalid])}
        XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
    }

    func testEpicDeleteReferenceIndexTracksUpsertAndRollbackAndExecutionBudget() throws {
        let p = try project(),pid = p["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Transactional"]),gid = epic["id"] as! String
        let source = uuid()
        try router.dbQueue.writeWithoutTransaction {db in
            try db.inTransaction {
                try router.save(db,["id":source,"project_id":pid,"revision":1,"nested":[gid:gid]],type:"message")
                return .rollback
            }
        }
        let before = try deletionFingerprint()
        XCTAssertThrowsError(try router.dbQueue.writeWithoutTransaction { db in
            try EpicReferenceIndex.withBudget(db,seconds:0) {
                try db.inTransaction {
                    try router.save(db,["id":source,"project_id":pid,"revision":1,"epic_id":gid],type:"message")
                    _ = try Int.fetchOne(db,sql:"WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT sum(x) FROM n")
                    return .commit
                }
            }
        }) {XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"reference_budget_exceeded")}
        XCTAssertEqual(try deletionFingerprint(),before)
        try router.dbQueue.write {db in
            try router.save(db,["id":source,"project_id":pid,"revision":1,"epic_id":gid],type:"message")
            // The ordinary save uses records UPSERT. Duplicate JSON values/keys
            // and the outer conflict policy must not break its TEMP triggers.
            try router.save(db,["id":source,"project_id":pid,"revision":2,"nested":["a":"repeated","b":"repeated"]],type:"message")
        }
        try router.dbQueue.write { db in
            try db.execute(sql:"INSERT OR REPLACE INTO records VALUES (?,?,'message',3,?)",arguments:[source,pid,try jsonString(["id":source,"project_id":pid,"revision":3,"epic_id":gid])])
            try db.execute(sql:"INSERT OR REPLACE INTO records VALUES (?,?,'message',4,?)",arguments:[source,pid,try jsonString(["id":source,"project_id":pid,"revision":4,"body":"No retained link"])])
        }
        XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
    }
}


extension CoreTests {
    func testEpicDeleteRealSizeBackfillResumesExpiredSlices() throws {
        let p = try project(),pid = p["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Real-size legacy proof"]),gid = epic["id"] as! String
        try router.dbQueue.write { db in
            // Seed a pre-index store, rather than qualifying only trigger writes.
            for name in try String.fetchAll(db,sql:"SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'epic_guard_%'") {
                try db.execute(sql:"DROP TRIGGER \(name)")
            }
            try db.execute(sql:"""
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<8600)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT 'retained-record-'||x,?,'message',1,json_object('body','Synthetic retained message','nested',json_object('target','elsewhere-'||x)) FROM n
                """,arguments:[pid])
            try db.execute(sql:"""
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000)
                INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
                SELECT 'retained-event-'||x,?,'retained-record-'||x,'fixture','padding','2026-10-22',json_object('nested',json_object('target','elsewhere-'||x)) FROM n
                """,arguments:[pid])
            let payload = try jsonString(["body":String(repeating:"x",count:1_700_000),"nested":Dictionary(uniqueKeysWithValues:(0..<8000).map {("key-\($0)","value-\($0)")})])
            XCTAssertLessThan(payload.utf8.count,EpicReferenceIndex.maximumPayloadBytes)
            try db.execute(sql:"INSERT INTO records(rowid,id,project_id,type,revision,data) VALUES (-1,'large-proof-record',?,'message',1,?)",arguments:[pid,payload])
            try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES ('large-proof-event',?,?,'fixture','padding','2026-10-22',?)",arguments:[pid,pid,payload])
        }
        try router.closeStore();router = try CommandRouter(root:directory)
        let before = try deletionFingerprint(),start = ProcessInfo.processInfo.systemUptime
        // The first legacy row is large-proof-record (rowid -1). A zero
        // slice budget simulates a host descheduled past its deadline, even for
        // a single large row. It must commit one unit and retain the remainder.
        XCTAssertTrue(try router.epicReferenceIndex.buildPage(router,seconds:0))
        try router.dbQueue.read { db in
            XCTAssertNil(try Int64.fetchOne(db,sql:"SELECT position FROM epic_guard_progress WHERE kind=0"))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM epic_guard_refs WHERE source_id=CAST('large-proof-record' AS BLOB)"),1)
        }
        do {_ = try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1]);XCTFail("Proof is still pending")}
        catch let error as CoreError {XCTAssertEqual(error.details["reason"] as? String,"reference_index_pending")}
        // Exercise the actual background continuations, sampling ordinary reads
        // while they run. This finite fixture wait never drives the backfill.
        var pending = true,reads = 0,maxRead: TimeInterval = 0
        while pending && ProcessInfo.processInfo.systemUptime-start<120 {
            let readStart = ProcessInfo.processInfo.systemUptime
            _ = try call("service_info")
            maxRead = max(maxRead,ProcessInfo.processInfo.systemUptime-readStart);reads += 1
            pending = try router.dbQueue.read {try Bool.fetchOne($0,sql:"SELECT EXISTS(SELECT 1 FROM epic_guard_progress WHERE high_water IS NOT NULL AND (position IS NULL OR position<high_water))")!}
            if pending {Thread.sleep(forTimeInterval:0.01)}
        }
        let seconds = ProcessInfo.processInfo.systemUptime-start
        XCTAssertFalse(pending);XCTAssertLessThan(seconds,120);XCTAssertLessThan(maxRead,2)
        XCTAssertEqual(try deletionFingerprint(),before)
        XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
        print("CL-245 r3 records=8600 events=20000 large_payloads=2 exhausted_source=large-proof-record slice_budget=0 backfill_seconds=\(seconds) ordinary_reads=\(reads) max_read_seconds=\(maxRead)")
    }
}


extension CoreTests {
    func testEpicDeleteBackfillSlicesFenceChangedSourcesAndNameMalformedRows() throws {
        let p = try project(),pid = p["id"] as! String
        let epic = try call("epic_create",["project_id":pid,"name":"Slice fencing"]),gid = epic["id"] as! String
        try router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO records(rowid,id,project_id,type,revision,data) VALUES (-1,'slice-source',?,'message',1,?)",arguments:[pid,try jsonString(["links":[gid,"stale-target"]])])
        }
        try router.closeStore();router = try CommandRouter(root:directory)
        XCTAssertTrue(try router.epicReferenceIndex.buildPage(router,seconds:0))
        // Same revision, and repeated replacement/deletion, must still fence a
        // parsed source. A revision-only comparison would resurrect stale links.
        try router.dbQueue.write { db in
            try db.execute(sql:"UPDATE records SET data='{}' WHERE id='slice-source'")
            try db.execute(sql:"INSERT OR REPLACE INTO records VALUES ('slice-source',?,'message',1,'{}')",arguments:[pid])
            try db.execute(sql:"DELETE FROM records WHERE id='slice-source'")
            try db.execute(sql:"INSERT INTO records VALUES ('slice-source',?,'message',1,'{}')",arguments:[pid])
        }
        var more = true
        for _ in 0..<100 where more {more = try router.epicReferenceIndex.buildPage(router)}
        XCTAssertFalse(more)
        try router.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM epic_guard_refs WHERE source_id=CAST('slice-source' AS BLOB)"),0)
        }
        for (table,kind) in [("records","record"),("events","event")] {
            try router.dbQueue.write { db in
                if table == "records" {try db.execute(sql:"INSERT INTO records VALUES ('malformed-proof-source',?,'message',1,'{')",arguments:[pid])}
                else {try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES ('malformed-proof-source',?,?,'fixture','padding','2026-10-22','{')",arguments:[pid,pid])}
            }
            let before = try deletionFingerprint()
            do {_ = try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1]);XCTFail("Malformed proof must refuse")}
            catch let error as CoreError {
                XCTAssertEqual(error.details["reason"] as? String,"reference_index_unavailable")
                XCTAssertEqual(error.details["source_kind"] as? String,kind)
                XCTAssertEqual(error.details["source_id"] as? String,"malformed-proof-source")
                XCTAssertTrue(error.message.contains("malformed-proof-source"))
            }
            XCTAssertEqual(try deletionFingerprint(),before)
            try router.dbQueue.write {try $0.execute(sql:"DELETE FROM \(table) WHERE id='malformed-proof-source'")}
        }
        XCTAssertEqual(try call("epic_delete",["project_id":pid,"epic_id":gid,"expected_revision":1])["deleted"] as? Bool,true)
    }
}
