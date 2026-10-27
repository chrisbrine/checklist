import XCTest
import GRDB
@testable import ChecklistCore

// CL-125: one orchestrator per Triage, one Triage per ticket, moves with the work
// (docs/triage-orchestrators.md). Synthetic projects and templates only.
extension EvidenceAuthorityTests {
    private func triageRecord(_ p: JSON,_ id: Any) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:"group") } }
    private func memberIDs(_ p: JSON,_ id: Any) throws -> [String] { try router.dbQueue.read { router.triageMemberIDs(try router.record($0,id as! String,type:"group")) } }
    private func exits(_ p: JSON,_ task: JSON) throws -> [String] {
        try router.dbQueue.read { try router.records($0,type:"triage_membership_exit",project:p["id"] as? String) }
            .filter {$0["task_id"] as? String == task["id"] as? String}.compactMap {$0["reason"] as? String}
    }
    private func startOwn(_ p: JSON,_ caller: Caller,name: String? = nil) throws -> JSON {
        var input: JSON = ["project_id":p["id"]!,"action":"start"];if let name { input["name"] = name }
        return try call("triage_orchestrate",input,caller)
    }
    private func add(_ p: JSON,_ group: Any,_ task: JSON,_ caller: Caller? = nil) throws -> JSON {
        let current = try triageRecord(p,group)
        return try call("group_membership",["project_id":p["id"]!,"group_id":group,"expected_revision":current["revision"]!,"task_id":task["id"]!,"action":"add"],caller)
    }
    private func fresh(_ p: JSON,_ task: JSON) throws -> JSON { try router.dbQueue.read { try router.record($0,task["id"] as! String,type:"task") } }
    private func move(_ p: JSON,_ task: JSON,_ caller: Caller,_ event: TriageMembershipEvent) throws {
        try fixtureMembershipWrite { db in try router.applyTriageMembership(db,task:try router.record(db,task["id"] as! String,type:"task"),caller:caller,event:event) }
    }
    private func fixtureMembershipWrite(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) { try body(db);return .commit } }
    }

    func testOrchestrateStartCreatesCallersTriageAndRefusesSecondActiveTriage() throws {
        let p = try project(), orchestrator = try native(p,"orchestrator",domain:"host-a"), other = try native(p,"other",domain:"host-b")
        let own = try startOwn(p,orchestrator)
        XCTAssertEqual((own["orchestrator"] as? JSON)?["session_id"] as? String,orchestrator.sessionID)
        XCTAssertEqual(own["plan"] as? Bool,false);XCTAssertEqual(own["member_count"] as? Int,0)
        XCTAssertTrue((own["name"] as! String).hasPrefix("Codex · "))
        XCTAssertEqual(own["phase"] as? NSNull,NSNull());XCTAssertEqual(own["phase_source"] as? String,"none")
        assertCode("TRIAGE_ORCHESTRATOR_CONFLICT") { _ = try self.startOwn(p,orchestrator) }
        let plan = try call("triage_create",["project_id":p["id"]!,"name":"Pass 5","phase":"review"])
        XCTAssertEqual(plan["plan"] as? Bool,true);XCTAssertTrue(plan["phase"] is NSNull,"A new Triage has no phase.")
        let planInput: JSON = ["project_id":p["id"]!,"triage_id":plan["id"]!,"expected_revision":plan["revision"]!,"action":"start"]
        assertCode("TRIAGE_ORCHESTRATOR_CONFLICT") { _ = try self.call("triage_orchestrate",planInput,orchestrator) }
        let started = try call("triage_orchestrate",planInput,other)
        XCTAssertEqual((started["orchestrator"] as? JSON)?["session_id"] as? String,other.sessionID)
        // Retry of the same command returns the same receipt.
        let named = try startOwn(p,try native(p,"third",domain:"host-c"),name:"Review lane")
        XCTAssertEqual(named["name"] as? String,"Review lane")
        let takeover: JSON = ["project_id":p["id"]!,"triage_id":own["id"]!,"expected_revision":try triageRecord(p,own["id"]!)["revision"]!,"action":"takeover","reason":"Take over"]
        assertCode("TRIAGE_ORCHESTRATOR_CONFLICT") { _ = try self.call("triage_orchestrate",takeover,other) }
        assertCode("INVALID_INPUT") { _ = try self.call("triage_orchestrate",["project_id":p["id"]!,"action":"finish","reason":"x"],orchestrator) }
        // Finish of an empty Triage archives it with history; a Triage with tickets becomes a plan.
        let finished = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":own["id"]!,"expected_revision":try triageRecord(p,own["id"]!)["revision"]!,"action":"finish","reason":"Done here"],orchestrator)
        XCTAssertEqual(finished["archived"] as? Bool,true);XCTAssertEqual(finished["plan"] as? Bool,true)
        let task = try ready(p);_ = try add(p,started["id"]!,task,other)
        let ended = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":started["id"]!,"expected_revision":try triageRecord(p,started["id"]!)["revision"]!,"action":"finish","reason":"Hand on"],other)
        XCTAssertEqual(ended["archived"] as? Bool,false);XCTAssertEqual(ended["plan"] as? Bool,true);XCTAssertEqual(strings(ended,"task_ids"),[task["id"] as! String])
        // After finish the conversation can start again.
        XCTAssertEqual((try startOwn(p,orchestrator)["orchestrator"] as? JSON)?["session_id"] as? String,orchestrator.sessionID)
    }

    func testOrchestratorClaimsMoveTicketsAndOtherSessionsKeepMembership() throws {
        let p = try project(), a = try native(p,"orchestrator-a",domain:"host-a"), b = try native(p,"orchestrator-b",domain:"host-b"), helper = try native(p,"helper",domain:"host-h")
        let triageA = try startOwn(p,a), triageB = try startOwn(p,b)
        let first = try ready(p), second = try ready(p), third = try ready(p)
        let plan = try call("triage_create",["project_id":p["id"]!,"name":"Pass 1"])
        _ = try add(p,plan["id"]!,first,helper)
        // Rule 7 and 5: the orchestrator's claim takes the ticket out of the plan; the plan empties and archives.
        let firstNow = try fresh(p,first)
        _ = try call("work_claim",["project_id":p["id"]!,"task_id":first["id"]!,"expected_revision":firstNow["revision"]!],a)
        XCTAssertEqual(try memberIDs(p,triageA["id"]!),[first["id"] as! String])
        XCTAssertEqual(try triageRecord(p,plan["id"]!)["archived"] as? Bool,true)
        XCTAssertEqual(try exits(p,first),["plan_claim"])
        // Only the orchestrator or the owner adds tickets to an orchestrated Triage.
        assertCode("TRIAGE_ORCHESTRATED") { _ = try self.add(p,triageA["id"]!,second,helper) }
        _ = try add(p,triageA["id"]!,second,a)
        // Rule 6: a claim by a session that orchestrates nothing leaves the ticket in place.
        let secondNow = try fresh(p,second)
        _ = try call("work_claim",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":secondNow["revision"]!],helper)
        XCTAssertEqual(Set(try memberIDs(p,triageA["id"]!)),Set([first["id"] as! String,second["id"] as! String]))
        // Another orchestrator's takeover moves the ticket (closed and opened intervals).
        let held = try fresh(p,second), project = try router.dbQueue.read { try router.record($0,p["id"] as! String,type:"project") }
        _ = try call("work_takeover",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":held["revision"]!,"reason":"Coordinator handles it","policy_revision":project["policy_revision"] ?? 1],b)
        XCTAssertEqual(try memberIDs(p,triageB["id"]!),[second["id"] as! String])
        XCTAssertEqual(try exits(p,second),["other_orchestrator"])
        // Rule 8: individual status changes keep membership; canceled leaves.
        _ = try add(p,triageA["id"]!,third,a)
        var thirdNow = try fresh(p,third)
        let parked = try router.dbQueue.read { try router.status($0,p["id"] as! String,"parked") }
        _ = try call("task_transition",["project_id":p["id"]!,"task_id":third["id"]!,"expected_revision":thirdNow["revision"]!,"target_status_id":parked["id"]!,"reason":"Later"],a)
        XCTAssertTrue(try memberIDs(p,triageA["id"]!).contains(third["id"] as! String))
        thirdNow = try fresh(p,third)
        let canceled = try router.dbQueue.read { try router.status($0,p["id"] as! String,"canceled") }
        _ = try call("task_transition",["project_id":p["id"]!,"task_id":third["id"]!,"expected_revision":thirdNow["revision"]!,"target_status_id":canceled["id"]!,"reason":"Not needed"],a)
        XCTAssertFalse(try memberIDs(p,triageA["id"]!).contains(third["id"] as! String))
        XCTAssertEqual(try exits(p,third),["canceled"])
        let listed = try (call("triage_list",["project_id":p["id"]!])["groups"] as! [JSON]).first {$0["id"] as? String == triageA["id"] as? String}!
        XCTAssertEqual((listed["member_counts_by_status"] as? JSON)?["active"] as? Int,1)
    }

    func testSubmissionRecordsReturnTriageAndVerdictReturnsWork() throws {
        let p = try project(), a = try native(p,"implementing",domain:"host-a"), b = try native(p,"reviewing",domain:"host-b")
        let triageA = try startOwn(p,a), triageB = try startOwn(p,b), task = try ready(p)
        _ = try add(p,triageA["id"]!,task,a)
        try move(p,task,a,.submission)
        XCTAssertEqual(try router.dbQueue.read { db in router.triageMember(try router.record(db,triageA["id"] as! String,type:"group"),taskID:task["id"] as! String)?["return_triage_id"] as? String },triageA["id"] as? String)
        // A review claim by another orchestrator moves the ticket and carries the return Triage.
        try move(p,task,b,.claim(review:true))
        XCTAssertEqual(try memberIDs(p,triageB["id"]!),[task["id"] as! String]);XCTAssertTrue(try memberIDs(p,triageA["id"]!).isEmpty)
        XCTAssertFalse(try triageRecord(p,triageA["id"]!)["archived"] as? Bool ?? false,"An orchestrated empty Triage stays.")
        try move(p,task,b,.verdictReturn)
        XCTAssertEqual(try memberIDs(p,triageA["id"]!),[task["id"] as! String]);XCTAssertTrue(try memberIDs(p,triageB["id"]!).isEmpty)
        XCTAssertEqual(try exits(p,task),["other_orchestrator","verdict_return"])
        // Return Triage without an orchestrator: the ticket leaves to no Triage.
        try move(p,task,a,.submission);try move(p,task,b,.claim(review:true))
        _ = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":triageA["id"]!,"expected_revision":try triageRecord(p,triageA["id"]!)["revision"]!,"action":"finish","reason":"Paused"],a)
        XCTAssertEqual(try triageRecord(p,triageA["id"]!)["archived"] as? Bool,true)
        try move(p,task,b,.verdictReturn)
        XCTAssertTrue(try memberIDs(p,triageB["id"]!).isEmpty);XCTAssertTrue(try memberIDs(p,triageA["id"]!).isEmpty)
        // Idempotent retry: a second verdict move with no membership changes nothing.
        let before = try exits(p,task);try move(p,task,b,.verdictReturn);XCTAssertEqual(try exits(p,task),before)
    }

    private func openIntervalTriages(_ p: JSON,_ task: JSON) throws -> [String] {
        try router.dbQueue.read { db in
            let closed = Set(try router.records(db,type:"triage_membership_exit",project:p["id"] as? String).compactMap {$0["membership_id"] as? String})
            return try router.records(db,type:"triage_membership_interval",project:p["id"] as? String)
                .filter {$0["task_id"] as? String == task["id"] as? String && !closed.contains($0["id"] as? String ?? "")}.compactMap {$0["triage_id"] as? String}
        }
    }
    private func orchestratorSubmit(_ p: JSON,_ caller: Caller) throws -> JSON {
        let attempt = try claim(p,ready(p),caller:caller)
        var input = auth(p,attempt);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
        return try call("work_submit",input,caller)
    }
    private func rejectInput(_ p: JSON,_ review: JSON) throws -> JSON {
        let manifest = try router.dbQueue.read { try router.record($0,review["manifest_id"] as! String,type:"manifest") }
        let source = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
        var reject = reviewInput(p,review,verdict:"reject")
        reject["findings"] = [["client_ref":"gap","description":"Expected result absent","severity":"normal","evidence_refs":[["source_capture_id":source["id"]!,"sha256":source["sha256"]!]]]]
        return reject
    }

    // Rule 10 through review_record: a reject moves the ticket back to its return Triage; a pass without Done stays;
    // a return Triage without an orchestrator sends the ticket to no Triage.
    func testRejectThroughReviewRecordMovesTicketToReturnTriage() throws {
        try sourceFixture()
        var p = try project()
        p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":["review"],"review_batch_policy":"hold_passing_for_batch"]])
        let a = try native(p,"implementing",domain:"codex:cl125-a"), b = try native(p,"reviewing",domain:"claude:cl125-b",provider:"claude")
        let triageA = try startOwn(p,a), triageB = try startOwn(p,b)
        let rejected = try orchestratorSubmit(p,a), task = rejected["task"] as! JSON
        XCTAssertEqual(try memberIDs(p,triageA["id"]!),[task["id"] as! String])
        let review = try reviewClaim(p,rejected,b)
        XCTAssertEqual(try memberIDs(p,triageB["id"]!),[task["id"] as! String]);XCTAssertTrue(try memberIDs(p,triageA["id"]!).isEmpty)
        _ = try call("review_record",try rejectInput(p,review),b)
        XCTAssertEqual(try fresh(p,task)["status_id"] as? String,try router.dbQueue.read { try router.status($0,p["id"] as! String,"queued")["id"] as? String })
        XCTAssertEqual(try memberIDs(p,triageA["id"]!),[task["id"] as! String]);XCTAssertTrue(try memberIDs(p,triageB["id"]!).isEmpty)
        XCTAssertEqual(try exits(p,task),["other_orchestrator","verdict_return"])
        XCTAssertEqual(try openIntervalTriages(p,task),[triageA["id"] as! String],"The reject closes B's interval and opens one in A.")
        // A pass that does not mark Done keeps the ticket in the reviewer's Triage.
        let passed = try orchestratorSubmit(p,a), passTask = passed["task"] as! JSON, passReview = try reviewClaim(p,passed,b)
        // A native reviewer attaches its report from inside its workspace (ignored by the source capture).
        let report = workspace.appendingPathComponent("private/cl125-review.md");try Data("Synthetic reviewer inspected this exact source target.".utf8).write(to:report)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":passTask["id"]!,"path":report.path],b)
        let passManifest = try router.dbQueue.read { try router.record($0,passReview["manifest_id"] as! String,type:"manifest") }
        var pass = reviewInput(p,passReview,verdict:"pass");pass["review_assessment"] = try fixtureReviewAssessment(router,task:try fresh(p,passTask),manifest:passManifest,artifact:artifact)
        let recorded = try call("review_record",pass,b)
        XCTAssertEqual((recorded["completion"] as? JSON)?["completed"] as? Bool,false)
        XCTAssertEqual(try memberIDs(p,triageB["id"]!),[passTask["id"] as! String])
        XCTAssertEqual(try exits(p,passTask),["other_orchestrator"])
        // Return Triage without an orchestrator: the reject sends the ticket to no Triage.
        let orphan = try orchestratorSubmit(p,a), orphanTask = orphan["task"] as! JSON, orphanReview = try reviewClaim(p,orphan,b)
        _ = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":triageA["id"]!,"expected_revision":try triageRecord(p,triageA["id"]!)["revision"]!,"action":"finish","reason":"Paused"],a)
        XCTAssertNil(try router.dbQueue.read { router.triageOrchestratorSession(try router.record($0,triageA["id"] as! String,type:"group")) })
        _ = try call("review_record",try rejectInput(p,orphanReview),b)
        XCTAssertFalse(try memberIDs(p,triageA["id"]!).contains(orphanTask["id"] as! String));XCTAssertFalse(try memberIDs(p,triageB["id"]!).contains(orphanTask["id"] as! String))
        XCTAssertEqual(try exits(p,orphanTask),["other_orchestrator","verdict_return"]);XCTAssertTrue(try openIntervalTriages(p,orphanTask).isEmpty)
    }

    // Rule 10 through batch_review_record: the reviewer's explicit add keeps the return Triage, and a reject moves each ticket back.
    func testRejectThroughBatchReviewRecordMovesTicketsToReturnTriage() throws {
        try sourceFixture()
        let p = try project(), a = try native(p,"batch-implementing",domain:"codex:cl125-batch-a"), b = try native(p,"batch-reviewing",domain:"claude:cl125-batch-b",provider:"claude")
        let triageA = try startOwn(p,a), triageB = try startOwn(p,b)
        let tasks = try (0..<2).map { _ in try orchestratorSubmit(p,a)["task"] as! JSON }
        XCTAssertEqual(Set(try memberIDs(p,triageA["id"]!)),Set(tasks.map {$0["id"] as! String}))
        for task in tasks { _ = try add(p,triageB["id"]!,task,b) }
        XCTAssertTrue(try memberIDs(p,triageA["id"]!).isEmpty)
        XCTAssertEqual(try router.dbQueue.read { db in router.triageMember(try router.record(db,triageB["id"] as! String,type:"group"),taskID:tasks[0]["id"] as! String)?["return_triage_id"] as? String },triageA["id"] as? String)
        let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":triageB["id"]!],b)
        let batch = try call("batch_prepare",["project_id":p["id"]!,"triage_id":triageB["id"]!,"expected_revision":read["triage_revision"]!,"phase":"review","tasks":read["tasks"]!],b)
        let claims = try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],b)["claims"] as! [JSON]
        let inputs = try claims.map { try rejectInput(p,$0) }
        _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"members":inputs],b)
        XCTAssertEqual(Set(try memberIDs(p,triageA["id"]!)),Set(tasks.map {$0["id"] as! String}));XCTAssertTrue(try memberIDs(p,triageB["id"]!).isEmpty)
        for task in tasks {
            XCTAssertEqual(try exits(p,task),["other_orchestrator","verdict_return"])
            XCTAssertEqual(try openIntervalTriages(p,task),[triageA["id"] as! String])
        }
    }

    func testStoreUpgradePlanFollowsCL269Rules() throws {
        let active: JSON = ["state":"active","session_id":"s1","started_at":"2026-10-01T00:00:00Z"]
        func group(_ id: String,_ members: [(String,String)],orchestration: JSON? = nil,legacy: Bool = false,archived: Bool = false) -> JSON {
            var value: JSON = ["id":id,"project_id":"p","kind":"triage","key":"T-"+id,"name":id,"revision":3,"created_at":"2026-09-0"+id.suffix(1)+"T00:00:00Z","archived":archived,"phase":"implementation"]
            if legacy { value["members"] = [JSON]();value["task_ids"] = members.map {$0.0} }
            else { value["members"] = members.map { ["task_id":$0.0,"joined_at":$0.1,"membership_id":"m-"+id+$0.0] as JSON } }
            if let orchestration { value["orchestration"] = orchestration }
            return value
        }
        let groups = [group("g1",[("t1","2026-10-01"),("t2","2026-10-01")],orchestration:active),
                      group("g2",[("t1","2026-10-05"),("t3","2026-10-05")]),
                      group("g3",[("t2","2026-10-02")]),
                      group("g4",[]),
                      group("g5",[],orchestration:active),
                      group("g6",[("t4","")],legacy:true),
                      group("g7",[("t5","2026-10-01")]),group("g8",[("t5","2026-10-03")]),
                      ["id":"e1","project_id":"p","kind":"epic","revision":1,"members":[["task_id":"t1"]]]]
        var counter = 0
        let plan = TriageMembershipUpgrade.plan(project:"p",groups:groups,now:"2026-10-27T00:00:00Z") { counter += 1;return "new-\(counter)" }
        let byID = Dictionary(uniqueKeysWithValues: plan.groups.map {($0["id"] as! String,$0)})
        // Rule 3: the orchestrated membership wins; otherwise the newest.
        XCTAssertEqual(Set(plan.exits.map {"\($0["triage_id"]!):\($0["task_id"]!)"}),["g2:t1","g3:t2","g7:t5"])
        XCTAssertTrue(plan.exits.allSatisfy {$0["reason"] as? String == "upgrade_single_membership"})
        XCTAssertEqual(strings(byID["g2"]!,"task_ids"),["t3"])
        // Rule 5: empty Triages with no orchestrator archive; an orchestrated empty Triage stays.
        XCTAssertEqual(byID["g3"]?["archived"] as? Bool,true);XCTAssertEqual(byID["g4"]?["archived"] as? Bool,true);XCTAssertEqual(byID["g7"]?["archived"] as? Bool,true)
        XCTAssertNil(byID["g5"]);XCTAssertNil(byID["g1"]);XCTAssertNil(byID["e1"])
        // Legacy task_ids gain member records; phase stays as a history label.
        XCTAssertEqual((byID["g6"]?["members"] as? [JSON])?.first?["task_id"] as? String,"t4")
        XCTAssertEqual(byID["g2"]?["phase"] as? String,"implementation");XCTAssertEqual(byID["g2"]?["revision"] as? Int,4)
        XCTAssertTrue(plan.intervals.isEmpty,"Members with interval IDs reuse them.")
        XCTAssertEqual(plan.events.filter {$0.kind == "triage_archived_automatically"}.count,3)
        // Running the plan on its own result changes nothing (idempotent).
        let merged = groups.map { byID[$0["id"] as! String] ?? $0 }
        let again = TriageMembershipUpgrade.plan(project:"p",groups:merged,now:"2026-10-28T00:00:00Z") { "unused" }
        XCTAssertTrue(again.groups.isEmpty);XCTAssertTrue(again.exits.isEmpty);XCTAssertTrue(again.events.isEmpty)
        // A legacy membership without an interval gains one before its exit.
        let legacy = TriageMembershipUpgrade.plan(project:"p",groups:[group("g1",[("t9","")],orchestration:active,legacy:true),group("g2",[("t9","")],legacy:true)],now:"n") { "id" }
        XCTAssertEqual(legacy.intervals.count,1);XCTAssertEqual(legacy.intervals.first?["history_source"] as? String,"legacy_membership_observation")
    }

    func testSchemaLedgerAcceptsFourAndRefusesFutureVersions() throws {
        XCTAssertEqual(SchemaMigrations.currentSchema,4)
        XCTAssertEqual(SchemaMigrations.ledgers(4).compactMap {$0["migration_id"] as? String}.last,"0004-triage-orchestrator-membership")
        XCTAssertEqual(SchemaMigrations.triageMembershipLedger["from_version"] as? Int,3)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db);try db.execute(sql:"PRAGMA user_version=5")
            XCTAssertThrowsError(try SchemaMigrations.inspect(db))
        }
    }
}
