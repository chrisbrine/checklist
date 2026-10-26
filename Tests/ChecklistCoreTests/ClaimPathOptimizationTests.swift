import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func testClaimSelectedProjectionRetainsClaimAndContextFacts() throws {
        let p = try project("Claim projection", "CP"), t = try ready(p,task(p)), group = try triage(p)
        try addTriage(p,group,t)
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        let projected = try XCTUnwrap(claim["task"] as? JSON), context = try XCTUnwrap(claim["context"] as? JSON)
        let contextual = try XCTUnwrap(context["task"] as? JSON)
        for key in ["id","revision","active_attempt_id","status_category","prerequisite_blockers","pickup_eligible","work_health"] {
            XCTAssertEqual(try jsonString(["value":projected[key] ?? NSNull()]),try jsonString(["value":contextual[key] ?? NSNull()]),key)
        }
        XCTAssertEqual(projected["status_category"] as? String,"active")
        XCTAssertEqual(projected["active_attempt_id"] as? String,claim["id"] as? String)
        XCTAssertTrue(strings(try currentTriage(p,group),"task_ids").isEmpty)
        XCTAssertNotNil(claim["claim_token"])
        assertCode("CLAIM_CONFLICT") {_ = try self.call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":projected["revision"]!])}
    }

    func testClaimPrerequisiteGuardKeepsOrderingOnlyUnresolvedAndSupersededRules() throws {
        let p = try project("Claim prerequisites", "CG"), t = try ready(p,task(p)), target = try ready(p,task(p))
        func edge(_ required: Bool, state: String = "active") throws {
            try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
                try router.save(db,["id":"claim-prerequisite","project_id":p["id"]!,"source_task_id":t["id"]!,"target_task_id":target["id"]!,"relation":"depends_on","required":required,"state":state,"revision":1],type:"relation")
                return .commit
            }}
        }
        try edge(false)
        try router.dbQueue.read {try router.requirePrerequisitesSatisfied($0,task:t)}
        try edge(true)
        assertCode("DEPENDENCY_UNSATISFIED") {try self.router.dbQueue.read {try self.router.requirePrerequisitesSatisfied($0,task:t)}}
        try edge(true,state:"unresolved")
        assertCode("DEPENDENCY_UNSATISFIED") {try self.router.dbQueue.read {try self.router.requirePrerequisitesSatisfied($0,task:t)}}
        try edge(true,state:"removed")
        try router.dbQueue.read {try router.requirePrerequisitesSatisfied($0,task:t)}
        var superseded = t; superseded["disposition"] = "superseded"
        assertCode("TASK_SUPERSEDED") {try self.router.dbQueue.read {try self.router.requirePrerequisitesSatisfied($0,task:superseded)}}
    }

    func testBatchClaimContextSeesEveryNewAttemptAfterSelectionInvalidation() throws {
        let p = try project("Fresh batch contexts", "FC"), group = try triage(p)
        let tasks = try (0..<2).map {_ in try ready(p,task(p))}
        for task in tasks {try addTriage(p,group,task)}
        let batch = try prepareImplementationBatch(p,group,tasks)
        let claims = try XCTUnwrap(claimFixedBatch(p,batch)["claims"] as? [JSON])
        XCTAssertEqual(claims.count,2)
        for claim in claims {
            let context = try XCTUnwrap(claim["context"] as? JSON)
            let attempts = try XCTUnwrap(context["attempts"] as? [JSON])
            XCTAssertEqual(attempts.compactMap {$0["id"] as? String},[claim["id"] as! String])
            XCTAssertEqual((context["counts"] as? JSON)?["attempts"] as? Int,1)
            XCTAssertEqual((context["handler"] as? JSON)?["id"] as? String,claim["id"] as? String)
        }
    }

    func testBatchClaimLateMemberRevisionRefusalLeavesFirstUnclaimedAndMembershipIntact() throws {
        let p = try project("Atomic claim", "AC"), group = try triage(p)
        let tasks = try (0..<2).map {_ in try ready(p,task(p))}
        for t in tasks {try addTriage(p,group,t)}
        let batch = try prepareImplementationBatch(p,group,tasks)
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":tasks[1]["id"]!,"expected_revision":tasks[1]["revision"]!,"patch":["title":"Changed after preparation"]])
        assertCode("REVISION_CONFLICT") {_ = try self.claimFixedBatch(p,batch)}
        for t in tasks {
            let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
            XCTAssertNil(current["active_attempt_id"])
            XCTAssertEqual(current["status_category"] as? String,"queued")
        }
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),Set(tasks.map {$0["id"] as! String}))
        try router.dbQueue.read {db in
            XCTAssertFalse(try router.records(db,type:"batch_claim",project:p["id"] as? String).contains {$0["batch_id"] as? String == batch["id"] as? String})
        }
    }
}

final class ClaimPathOptimizationTests: XCTestCase {
    /// Approximation only: immutable backup, recorded task dictionaries, no claims installed.
    func testReadOnlyClaimComponentProfile() throws {
        try QualificationSuite.requireEnabled()
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_ONLY_DATABASE"],let fixturePath = ProcessInfo.processInfo.environment["CHECKLIST_BATCH_PROFILE_FIXTURE"] else {throw XCTSkip("Requires owned immutable snapshot and recorded batch fixture")}
        let native = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:fixturePath))) as? JSON)
        let tasks = try XCTUnwrap(native["tasks"] as? [JSON]).map {source -> JSON in
            var task = source;task.removeValue(forKey:"active_attempt_id");task.removeValue(forKey:"active_verification_request_id");return task
        }
        let fixture = try ReadPerformanceFixture("CL-287-claim-profile")
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase {db in try SchemaMigrations.installStorageCollation(db);CommandRouter.installTicketSearchFunctions(db)}
        let pool = try DatabasePool(path:path,configuration:configuration);defer {try? pool.close()}
        let caller = Caller(role:"owner",installation:"CL-287-diagnostic",projectIDs:[])
        print("CL-287 profile: read-only recorded preclaim dictionaries, no transient claims; owner diagnostic caller; no native admission or installed timing claim")
        for phase in ["prerequisite_guard","full_projection","selected_projection","compact_context","batch_compact_context","attempt_window","evidence_measures","membership_before","category_fence"] {
            try pool.read {db in
                var profiles: [(String,TimeInterval)] = []
                db.trace(options:.profile) {if case .profile(let statement,let duration) = $0 {profiles.append((statement.expandedSQL,duration))}}
                defer {db.trace(options:[])}
                let start = ProcessInfo.processInfo.systemUptime
                if phase == "batch_compact_context" {
                    try fixture.router.withTaskRecordSelection(db,tasks:tasks) {
                        for task in tasks {_ = try fixture.router.compactTaskContext(db,task:task,caller:caller)}
                    }
                } else {
                for task in tasks {
                    switch phase {
                    case "prerequisite_guard": try fixture.router.requirePrerequisitesSatisfied(db,task:task)
                    case "full_projection": _ = try fixture.router.taskProjection(db,task)
                    case "selected_projection": _ = try fixture.router.selectedTaskProjection(db,task:task)
                    case "compact_context": _ = try fixture.router.compactTaskContext(db,task:task,caller:caller)
                    case "attempt_window": _ = try fixture.router.scopedTaskRows(db,type:"attempt",task:task,limit:26,descending:true)
                    case "evidence_measures": _ = try fixture.router.evidenceMeasuresContext(db,task:task)
                    case "membership_before": _ = try fixture.router.currentTriageMemberships(db,project:task["project_id"] as! String)
                    default: _ = try fixture.router.implementationClaimCategory(db,task:task)
                    }
                }
                }
                print("CL-287 phase=\(phase) members=\(tasks.count) wall_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000) statements=\(profiles.count)")
                var totals: [String:(Int,TimeInterval)] = [:]
                for (sql,duration) in profiles {let old = totals[sql] ?? (0,0);totals[sql] = (old.0+1,old.1+duration)}
                for (sql,total) in totals.sorted(by:{$0.value.1 > $1.value.1}).prefix(10) {print("CL-287 SQL phase=\(phase) count=\(total.0) total_ms=\(total.1*1000) \(sql)")}
            }
        }
    }
}
