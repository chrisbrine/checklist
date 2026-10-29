import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    private func p321HistoryReferenceGraphs(_ tasks: [JSON],_ inventories: [String:TicketCleanupInventory]) throws -> [String:TicketPurgeReferenceGraph] {
        var graphs: [String:TicketPurgeReferenceGraph] = [:]
        for task in tasks {
            let tid = task["id"] as! String
            graphs[tid] = try router.ticketPurgeReferenceGraph(task:task,inventory:XCTUnwrap(inventories[tid]))
        }
        return graphs
    }

    func testP321SharedEventObservationMatchesIndividualPlansAndPreservesSharedHistory() throws {
        let (project,first,_) = try fixture(),pid = project["id"] as! String,tid = first["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Other history owner"])
        let privateID = "private-é",similarID = "private-e\u{301}",sharedID = uuid()
        try write {db in
            try self.router.save(db,["id":privateID,"project_id":pid,"task_id":tid,"revision":1,"body":"Private"],type:"message")
            try self.router.save(db,["id":sharedID,"project_id":pid,"task_id":tid,"revision":1,"body":"Shared"],type:"message")
            try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":second["id"]!,"revision":1,"reference":sharedID],type:"message")
            for (entity,data) in [(privateID,["body":"Private event"] as JSON),(sharedID,["body":"Shared event"]),(uuid(),[privateID:"Nested exact reference"]),(uuid(),[similarID:"Distinct UTF-8 reference"])] {
                try self.router.event(db,caller:self.owner,project:pid,entity:entity,kind:"history_observation_fixture",data:data)
            }
        }
        try router.readers!.read {db in
            let tasks = [first,second],batch = try self.router.ticketCleanupInventories(db,tasks:tasks)
            let graphs = try self.p321HistoryReferenceGraphs(tasks,batch.inventories)
            var scans = 0
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("FROM events WHERE project_id=? ORDER BY seq LIMIT 100001") {scans += 1}}
            let observation = try self.router.ticketCleanupEventObservation(db,tasks:tasks,inventories:batch.inventories,referenceGraphs:graphs)
            db.trace(nil)
            XCTAssertEqual(scans,1);XCTAssertTrue(observation.errors.isEmpty)
            for task in tasks {
                let inventory = try XCTUnwrap(batch.inventories[task["id"] as! String])
                let expected = try self.router.ticketPurgePlan(db,task:task,inventory:inventory)
                let actual = try self.router.ticketPurgePlan(db,task:task,inventory:inventory,historyObservation:observation,referenceGraph:graphs[task["id"] as! String])
                XCTAssertEqual(actual.events.map {$0["seq"] as Int64},expected.events.map {$0["seq"] as Int64})
                XCTAssertEqual(actual.digest,expected.digest)
                if task["id"] as? String == tid {
                    XCTAssertTrue(actual.events.contains {($0["entity_id"] as String?) == privateID})
                    XCTAssertFalse(actual.events.contains {($0["entity_id"] as String?) == sharedID})
                    XCTAssertFalse(actual.events.contains {($0["data"] as String).contains("Distinct UTF-8")})
                }
            }
        }
    }

    func testP321SharedCommandObservationMatchesIndividualPlansAndUsesOneStream() throws {
        let (project,first,_) = try fixture(),pid = project["id"] as! String,tid = first["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Other command owner"])
        let privateID = "command-é",similarID = "command-e\u{301}",exact = uuid(),distinct = uuid(),both = uuid()
        try write {db in
            try self.router.save(db,["id":privateID,"project_id":pid,"task_id":tid,"revision":1,"body":"Private"],type:"message")
            for (command,result) in [(exact,["nested":[privateID:"Exact"]] as JSON),(distinct,["nested":[similarID:"Distinct"]]),(both,["tasks":[tid,second["id"] as! String]])] {
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[self.owner.principal,command,"fixture",try jsonString(result)])
            }
        }
        try router.readers!.read {db in
            let tasks = [first,second],batch = try self.router.ticketCleanupInventories(db,tasks:tasks)
            let graphs = try self.p321HistoryReferenceGraphs(tasks,batch.inventories)
            var plans: [String:TicketPurgePlan] = [:]
            for task in tasks {plans[task["id"] as! String] = try self.router.ticketPurgePlan(db,task:task,inventory:batch.inventories[task["id"] as! String],referenceGraph:graphs[task["id"] as! String])}
            var scans = 0
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("FROM commands LIMIT 100001") {scans += 1}}
            let actual = try self.router.ticketPurgeExpiringCommands(db,tasks:tasks,plans:plans)
            db.trace(nil)
            XCTAssertEqual(scans,1);XCTAssertTrue(actual.errors.isEmpty)
            for task in tasks {
                let key = task["id"] as! String
                let expected = try self.router.ticketPurgeExpiringCommands(db,task:task,plan:try XCTUnwrap(plans[key]))
                XCTAssertEqual((actual.commands[key] ?? []).map {$0["cleanup_row"] as Int64},expected.map {$0["cleanup_row"] as Int64})
            }
            let ids = Set((actual.commands[tid] ?? []).map {$0["command_id"] as String})
            XCTAssertTrue(ids.contains(exact));XCTAssertTrue(ids.contains(both));XCTAssertFalse(ids.contains(distinct))
        }
    }

    func testP321SharedHistoryBoundsRefuseOnlyOversizedTicket() throws {
        let (project,first,_) = try fixture(),pid = project["id"] as! String,tid = first["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Unaffected history owner"]),other = second["id"] as! String
        let padding = String(repeating:"x",count:3_000_000)
        try write {db in
            for _ in 0..<6 {
                try self.router.event(db,caller:self.owner,project:pid,entity:tid,kind:"history_bound_fixture",data:["task_id":tid,"body":padding])
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[self.owner.principal,uuid(),"fixture",try jsonString(["task_id":tid,"body":padding])])
            }
            try self.router.event(db,caller:self.owner,project:pid,entity:other,kind:"history_bound_fixture",data:["task_id":other,"body":"Small retained history"])
        }
        try router.readers!.read {db in
            let tasks = [first,second],batch = try self.router.ticketCleanupInventories(db,tasks:tasks)
            let graphs = try self.p321HistoryReferenceGraphs(tasks,batch.inventories)
            let events = try self.router.ticketCleanupEventObservation(db,tasks:tasks,inventories:batch.inventories,referenceGraphs:graphs)
            XCTAssertEqual(events.errors[tid]?.code,"CLEANUP_INVENTORY_LIMIT");XCTAssertNil(events.errors[other])
            XCTAssertThrowsError(try events.events(task:tid,matching:[Data(tid.utf8)]))
            XCTAssertTrue(try events.events(task:other,matching:[Data(other.utf8)]).contains {($0["data"] as String).contains("Small retained history")})
            // A command observation needs only the exact removed set. Avoid
            // planning the deliberately oversized event history for this case.
            let small = try self.router.ticketPurgePlan(db,task:second,inventory:batch.inventories[other],historyObservation:events,referenceGraph:graphs[other])
            let plans = [tid:small,other:small]
            let commands = try self.router.ticketPurgeExpiringCommands(db,tasks:tasks,plans:plans)
            XCTAssertEqual(commands.errors[tid]?.code,"CLEANUP_INVENTORY_LIMIT");XCTAssertNil(commands.errors[other])
            XCTAssertNotNil(commands.commands[other]);XCTAssertNil(commands.commands[tid])
        }
    }

    func testP321ExactHistoryAdmissionDoesNotStarveTicketWithLargeForeignProtectedHistory() throws {
        let (project,first,_) = try fixture(category:"canceled",age:20),pid = project["id"] as! String,tid = first["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Foreign protection owner"]),shared = uuid()
        let padding = String(repeating:"x",count:3_000_000)
        try write {db in
            try self.router.save(db,["id":shared,"project_id":pid,"task_id":tid,"revision":1,"body":"Shared owned message"],type:"message")
            try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":second["id"]!,"revision":1,"reference":shared],type:"message")
            // These rows exceed the per-ticket history budget together, but
            // refer exclusively to the shared record kept by the exact graph.
            for _ in 0..<6 {try self.router.event(db,caller:self.owner,project:pid,entity:shared,kind:"large_shared_history_fixture",data:["body":padding])}
        }
        try router.readers!.read {db in
            let tasks = [first,second],batch = try self.router.ticketCleanupInventories(db,tasks:tasks)
            let graphs = try self.p321HistoryReferenceGraphs(tasks,batch.inventories)
            let graph = try XCTUnwrap(graphs[tid])
            XCTAssertTrue(graph.owned.contains(Data(shared.utf8)))
            XCTAssertTrue(graph.shared.contains {$0.key == Data(shared.utf8)})
            XCTAssertFalse(graph.removed.contains {$0.key == Data(shared.utf8)})
            let observed = try self.router.ticketCleanupEventObservation(db,tasks:tasks,inventories:batch.inventories,referenceGraphs:graphs)
            XCTAssertTrue(observed.errors.isEmpty)
            let inventory = try XCTUnwrap(batch.inventories[tid])
            let expected = try self.router.ticketPurgePlan(db,task:first,inventory:inventory)
            let actual = try self.router.ticketPurgePlan(db,task:first,inventory:inventory,historyObservation:observed,referenceGraph:graph)
            XCTAssertEqual(actual.digest,expected.digest)
            XCTAssertEqual(actual.events.map {$0["seq"] as Int64},expected.events.map {$0["seq"] as Int64})
            XCTAssertFalse(actual.events.contains {($0["entity_id"] as String?) == shared})
        }
    }

}
