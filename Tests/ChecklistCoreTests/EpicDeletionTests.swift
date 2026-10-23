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
