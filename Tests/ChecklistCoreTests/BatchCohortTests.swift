import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func cohortProject() throws -> JSON {
        let workspace = directory.appendingPathComponent("cohort-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        return try call("project_create",["name":"Synthetic shared batch","key_prefix":"CO","root_path":workspace.path])
    }
    func cohortWorker(_ p: JSON,_ name: String = UUID().uuidString) throws -> Caller {
        let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"provider":"codex","role":"worker","installation":name,"workspace":p["root_path"]!,"execution_domain":"synthetic:"+name])
        return Caller(role:"worker",installation:name,projectIDs:[p["id"] as! String],sessionID:sid,workspace:p["root_path"] as? String,executionDomain:"synthetic:"+name)
    }
    func sharedBatch(_ p: JSON,_ worker: Caller,paths: [String] = ["src/shared.swift","src/shared.swift"]) throws -> JSON {
        let group = try triage(p),tasks = try paths.map {_ in try ready(p,task(p))}
        for task in tasks { try addTriage(p,group,task) }
        return try prepareImplementationBatch(p,group,tasks,worker,scopes:paths.map {[["path":$0,"access":"write"]]})
    }
    func cohortAuth(_ p: JSON,_ claim: JSON) -> JSON { ["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!] }
    func outsiderClaim(_ p: JSON,_ t: JSON,_ worker: Caller,path: String = "src/shared.swift") throws -> JSON {
        try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"file_scopes":[["path":path,"access":"write"]]],worker)
    }
    func testSharedBatchNormalizesBeforePrepareAndClaimsFullScopesRetainingMembership() throws {
        for paths in [["src/shared.swift","src/shared.swift"],["src","src/shared.swift"]] {
            let p = try cohortProject(),worker = try cohortWorker(p),before = try call("snapshot"),batch = try sharedBatch(p,worker,paths:paths)
            let prepared = try call("snapshot")
            XCTAssertEqual(try jsonString(before["attempts"]!),try jsonString(prepared["attempts"]!))
            let frozen = try router.dbQueue.read {try jsonString(router.record($0,batch["id"] as! String,type:"batch"))}
            let claimed = try claimFixedBatch(p,batch,worker),claims = claimed["claims"] as! [JSON]
            XCTAssertEqual(claims.count,2);XCTAssertNotEqual(claims[0]["id"] as? String,claims[1]["id"] as? String)
            for (member,claim) in zip(batch["members"] as! [JSON],claims) {
                XCTAssertEqual(try jsonString(member["file_scopes"]!),try jsonString(claim["file_scopes"]!))
                XCTAssertEqual((claim["file_scopes"] as! [JSON])[0]["access"] as? String,"write")
            }
            XCTAssertEqual(strings(try currentTriage(p,["id":batch["triage_id"]!]),"task_ids").count,2)
            XCTAssertEqual(frozen,try router.dbQueue.read {try jsonString(router.record($0,batch["id"] as! String,type:"batch"))})
        }
    }
    func testSharedBatchSymlinkAndCaseAliasesUsePhysicalVolumeRules() throws {
        let p = try cohortProject(),root = URL(fileURLWithPath:p["root_path"] as! String),worker = try cohortWorker(p)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Real"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("alias").path,withDestinationPath:root.appendingPathComponent("Real").path)
        var paths = ["Real/file.swift","alias/file.swift"]
        let insensitive = try root.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        if insensitive { paths.append("real/FILE.swift") }
        let batch = try sharedBatch(p,worker,paths:paths),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
        XCTAssertEqual(Set(claims.map {($0["file_scopes"] as! [JSON])[0]["canonical_key"] as! String}).count,1)
    }
    func testSharedBatchExternalUnionSurvivesPartialReleaseAndIndividualSubmission() throws {
        for submit in [false,true] {
            let p = try cohortProject(),worker = try cohortWorker(p),other = try cohortWorker(p),batch = try sharedBatch(p,worker),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
            let outside = try ready(p,task(p))
            // Same session in a different batch, and another session, cannot join this cohort.
            for caller in [worker,other] {
                XCTAssertThrowsError(try outsiderClaim(p,outside,caller)) { error in
                    let e = error as! CoreError;XCTAssertEqual(e.code,"SCOPE_CONFLICT")
                    XCTAssertEqual(e.details["candidate_task_id"] as? String,outside["id"] as? String)
                    XCTAssertNotNil(e.details["conflicting_key"]);XCTAssertNotNil(e.details["path"])
                }
                assertCode("SCOPE_CONFLICT") { _ = try self.sharedBatch(p,caller) }
            }
            if submit {
                var input = try batchArtifactInput(p,claims[0]);input["project_id"] = p["id"]
                _ = try call("work_submit",input,worker)
                XCTAssertEqual(strings(try currentTriage(p,["id":batch["triage_id"]!]),"task_ids").count,1)
            } else {
                _ = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":[["attempt_id":claims[0]["id"]!,"claim_token":claims[0]["claim_token"]!]],"reason":"Partial release"],worker)
                XCTAssertEqual(strings(try currentTriage(p,["id":batch["triage_id"]!]),"task_ids").count,2)
            }
            assertCode("SCOPE_CONFLICT") {_ = try self.outsiderClaim(p,outside,other)}
            _ = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":[["attempt_id":claims[1]["id"]!,"claim_token":claims[1]["claim_token"]!]],"reason":"Last owner release"],worker)
            _ = try outsiderClaim(p,outside,other)
        }
    }
    func testSharedBatchPreexistingWriterAndLateMemberConflictRollbackWithTicketDiagnostics() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),other = try cohortWorker(p),outside = try ready(p,task(p)),batch = try sharedBatch(p,worker,paths:["safe.swift","src/shared.swift"])
        _ = try outsiderClaim(p,outside,other)
        let before = try batchClaimState(p,batch)
        XCTAssertThrowsError(try claimFixedBatch(p,batch,worker)) { error in
            let e = error as! CoreError;XCTAssertEqual(e.code,"SCOPE_CONFLICT")
            XCTAssertEqual(e.details["conflicting_task_id"] as? String,outside["id"] as? String)
            XCTAssertNotNil(e.details["candidate_key"]);XCTAssertNotNil(e.details["candidate_batch_id"])
        }
        XCTAssertEqual(try batchClaimState(p,batch),before)
        let members: [JSON] = (batch["members"] as! [JSON]).map {["task_id":$0["task_id"]!,"expected_revision":$0["task_revision"]!,"file_scopes":$0["file_scopes"]!]}
        let current = try currentTriage(p,["id":batch["triage_id"]!])
        assertCode("SCOPE_CONFLICT") {_ = try self.call("batch_prepare",["project_id":p["id"]!,"triage_id":batch["triage_id"]!,"expected_revision":current["revision"]!,"phase":"implementation","tasks":members],worker)}
        XCTAssertEqual(try batchClaimState(p,batch),before)
    }
    func testSharedBatchScopeAdjustmentDoesNotExpandFrozenOverlapAndNarrowingWorks() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker,paths:["src/a.swift","src"]),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
        var input = cohortAuth(p,claims[0]);input["file_scopes"] = [["path":"src","access":"write"]]
        let before = try batchClaimState(p,batch)
        assertCode("SCOPE_CONFLICT") {_ = try self.call("work_scope_adjust",input,worker)}
        XCTAssertEqual(try batchClaimState(p,batch),before)
        input["file_scopes"] = [["path":"src/a.swift","access":"write"]]
        _ = try call("work_scope_adjust",input,worker)
        input["file_scopes"] = [["path":"src/a.swift","access":"read"]]
        _ = try call("work_scope_adjust",input,worker)
    }
    func testSharedBatchCopiedCohortCannotTransferThroughChildHandoffOrTakeover() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),other = try cohortWorker(p),batch = try sharedBatch(p,worker),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
        var delegate = cohortAuth(p,claims[0]);delegate["child_session_id"] = other.sessionID!;delegate["file_scopes"] = [["path":"src/shared.swift","access":"write"]]
        let offer = try call("work_delegate",delegate,worker),before = try batchClaimState(p,batch)
        assertCode("SCOPE_CONFLICT") {_ = try self.call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],other)}
        XCTAssertEqual(try batchClaimState(p,batch),before)
        var handoff = cohortAuth(p,claims[0]);handoff["target_session_id"] = other.sessionID!;handoff["summary"] = "Continue this work"
        let handoffOffer = try call("work_handoff_offer",handoff,worker),handoffBefore = try batchClaimState(p,batch)
        assertCode("SCOPE_CONFLICT") {_ = try self.call("work_handoff_accept",["project_id":p["id"]!,"offer_id":handoffOffer["id"]!],other)}
        XCTAssertEqual(try batchClaimState(p,batch),handoffBefore)
        let t = try call("task_get",["project_id":p["id"]!,"task_id":claims[0]["task_id"]!])
        var takeover: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"reason":"Replace with a narrowed writer"]
        assertCode("SCOPE_CONFLICT") {_ = try self.call("work_takeover",takeover,other)}
        XCTAssertEqual(try batchClaimState(p,batch),handoffBefore)
        takeover["file_scopes"] = [["path":"separate.swift","access":"write"]]
        let replacement = try call("work_takeover",takeover,other)
        XCTAssertEqual(replacement["session_id"] as? String,other.sessionID)
        // An inherited batch ID still cannot expand back into the remaining cohort.
        var expand = cohortAuth(p,replacement);expand["file_scopes"] = [["path":"src/shared.swift","access":"write"]]
        assertCode("SCOPE_CONFLICT") {_ = try self.call("work_scope_adjust",expand,other)}
    }
    func testSharedBatchRestartReconstructsUnionAndReplayFencesGeneration() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker),command = UUID().uuidString,claims = try claimFixedBatch(p,batch,worker,command)["claims"] as! [JSON]
        router = nil;router = try TestStore.router(root:directory)
        var auth = cohortAuth(p,claims[0]);auth["file_scopes"] = [["path":"src/shared.swift","access":"write"]]
        _ = try call("work_scope_adjust",auth,worker)
        let replay = try claimFixedBatch(p,batch,worker,command)["claims"] as! [JSON]
        XCTAssertEqual(replay.map {$0["id"] as! String},claims.map {$0["id"] as! String})
        assertCode("STALE_CLAIM") {_ = try self.call("work_scope_adjust",auth,worker)}
        try router.dbQueue.write {db in var session = try router.record(db,worker.sessionID!,type:"session");session["authorization_generation"] = UUID().uuidString;try router.save(db,session,type:"session")}
        let staleReplay = try claimFixedBatch(p,batch,worker,command)["claims"] as! [JSON]
        XCTAssertTrue(staleReplay.allSatisfy {$0["claim_token"] == nil})
        let outside = try ready(p,task(p));assertCode("SCOPE_CONFLICT") {_ = try self.outsiderClaim(p,outside,worker)}
    }
}

extension CoreTests {
    func testSharedBatchStillEnforcesLaneCapacityAndReviewWriteExclusion() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),group = try triage(p),tasks = try [ready(p,task(p)),ready(p,task(p))]
        for task in tasks {try addTriage(p,group,task)}
        let current = try currentTriage(p,group)
        let members: [JSON] = tasks.map {["task_id":$0["id"]!,"expected_revision":$0["revision"]!,"file_scopes":[["path":"shared","access":"write"]],"lane_scopes":[["lane_id":"compiler","units":1]]]}
        let before = try call("snapshot")
        assertCode("LANE_FULL") {_ = try self.call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"phase":"implementation","tasks":members],worker)}
        let after = try call("snapshot");for key in ["tasks","attempts","groups","events"] {XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!))}
        let batch = try prepareImplementationBatch(p,group,tasks,worker,scopes:tasks.map {_ in [["path":"shared","access":"write"]]}),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}],worker)
        let review = try triage(p,phase:"review"),reviewer = try cohortWorker(p)
        for task in tasks {try addTriage(p,review,task)}
        let reviewInputs = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":review["id"]!],reviewer)
        let reviewMembers = (reviewInputs["tasks"] as! [JSON]).map { row -> JSON in var row = row;row["file_scopes"] = [["path":"shared","access":"write"]];return row }
        assertCode("SCOPE_CONFLICT") {_ = try self.call("batch_prepare",["project_id":p["id"]!,"triage_id":review["id"]!,"expected_revision":reviewInputs["triage_revision"]!,"phase":"review","tasks":reviewMembers],reviewer)}
    }
    func testSharedBatchSourceTargetsKeepEachTicketsOwnHashAndFreshness() throws {
        router = nil;try FileManager.default.removeItem(at:directory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        router = try TestStore.router(root:directory.appendingPathComponent("service"))
        let p = try cohortProject(),root = URL(fileURLWithPath:p["root_path"] as! String),file = root.appendingPathComponent("src/shared.swift"),worker = try cohortWorker(p)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("first result".utf8).write(to:file)
        let batch = try sharedBatch(p,worker),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
        func submit(_ claim: JSON) throws -> JSON {
            var input = cohortAuth(p,claim);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":JSON()]
            return try call("work_submit",input,worker)
        }
        let first = try submit(claims[0])
        try Data("second result".utf8).write(to:file)
        let second = try submit(claims[1])
        let manifests = try router.dbQueue.read {db in try [first,second].map {try router.record(db,$0["manifest_id"] as! String,type:"manifest")}}
        let captures = manifests.map {($0["evidence"] as! JSON)["source_capture"] as! JSON}
        XCTAssertNotEqual(captures[0]["sha256"] as? String,captures[1]["sha256"] as? String)
        let outcomes = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!])["outcomes"] as! [JSON]
        XCTAssertEqual(outcomes[0]["state"] as? String,"stale");XCTAssertNotEqual(outcomes[1]["state"] as? String,"stale")
    }
}
