import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func discardBatch(_ p: JSON,_ batch: JSON,_ caller: Caller? = nil,command: String? = nil,reason: String = "Superseded preparation") throws -> JSON {
        try call("batch_discard",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"reason":reason],caller,command)
    }
    func testDiscardPreservesFrozenSnapshotAndDomainStateAndAllProjectionsAfterRestart() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker),before = try call("snapshot")
        let groupsBefore = try router.dbQueue.read {try jsonString(router.records($0,type:"group"))}
        let frozen = try router.dbQueue.read {try jsonString(router.record($0,batch["id"] as! String,type:"batch"))}
        XCTAssertEqual(batch["lifecycle"] as? String,"prepared")
        let discarded = try discardBatch(p,batch,worker),disposition = discarded["disposition"] as! JSON
        XCTAssertEqual(discarded["lifecycle"] as? String,"discarded");XCTAssertEqual(disposition["actor"] as? String,worker.principal)
        XCTAssertEqual(disposition["session_id"] as? String,worker.sessionID);XCTAssertEqual(disposition["reason"] as? String,"Superseded preparation")
        XCTAssertEqual(disposition["triage_id"] as? String,batch["triage_id"] as? String)
        let after = try call("snapshot")
        for key in ["tasks","attempts"] {XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!))}
        XCTAssertEqual(groupsBefore,try router.dbQueue.read {try jsonString(router.records($0,type:"group"))})
        XCTAssertEqual(frozen,try router.dbQueue.read {try jsonString(router.record($0,batch["id"] as! String,type:"batch"))})
        router = nil;router = try TestStore.router(root:directory)
        let get = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!],worker)
        let list = try call("batch_list",["project_id":p["id"]!,"triage_id":batch["triage_id"]!],worker)["batches"] as! [JSON]
        let groups = try call("triage_list",["project_id":p["id"]!],worker)["groups"] as! [JSON]
        let summary = (groups.first {$0["id"] as? String == batch["triage_id"] as? String}!["batches"] as! [JSON])[0]
        for value in [get,list[0],summary] {
            XCTAssertEqual(value["lifecycle"] as? String,"discarded");XCTAssertEqual(try jsonString(value["disposition"]!),try jsonString(disposition))
        }
        for method in ["batch_claim","batch_complete_passing","batch_retriage_remaining"] {
            var input: JSON = ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1]
            if method == "batch_claim" {input["policy_revision"] = batch["policy_revision"]}
            assertCode("BATCH_DISCARDED") {_ = try self.call(method,input,worker)}
        }
        XCTAssertEqual(try jsonString(after["attempts"]!),try jsonString(call("snapshot")["attempts"]!))
    }
    func testDiscardReviewPreparationAndClaimedEverRefusalsIncludingReleasedAndCompleted() throws {
        let value = try submittedArtifact(),p = value.project,group = try triage(p,phase:"review"),reviewer = Caller(role:"owner",installation:"discard-reviewer",projectIDs:[])
        try addTriage(p,group,value.task)
        let reviewBatch = try prepareReviewBatch(p,group,[value.task],reviewer)
        XCTAssertEqual(try discardBatch(p,reviewBatch,reviewer)["lifecycle"] as? String,"discarded")
        assertCode("BATCH_DISCARDED") {_ = try self.claimFixedBatch(p,reviewBatch,reviewer)}
        for complete in [false,true] {
            let p = try cohortProject(),worker = try cohortWorker(p)
            _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
            let batch = try sharedBatch(p,worker),claims = try claimFixedBatch(p,batch,worker)["claims"] as! [JSON]
            XCTAssertEqual(try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!])["lifecycle"] as? String,"claimed")
            assertCode("BATCH_ALREADY_CLAIMED") {_ = try self.discardBatch(p,batch,worker)}
            if complete {
                _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}],worker)
                let completed = try call("batch_complete_passing",batchPassingCompletionInput(p,batch,worker),worker)
                XCTAssertEqual(strings(completed,"completed_task_ids").count,2)
            } else {
                _ = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":claims.map {["attempt_id":$0["id"]!,"claim_token":$0["claim_token"]!]},"reason":"All released"],worker)
            }
            let before = try batchClaimState(p,batch)
            assertCode("BATCH_ALREADY_CLAIMED") {_ = try self.discardBatch(p,batch,worker)}
            XCTAssertEqual(try batchClaimState(p,batch),before)
            // A historical attempt is sufficient even if its dispatch receipt is absent.
            try router.dbQueue.write {try $0.execute(sql:"DELETE FROM records WHERE type='batch_claim' AND project_id=?",arguments:[p["id"] as! String])}
            assertCode("BATCH_ALREADY_CLAIMED") {_ = try self.discardBatch(p,batch,worker)}
        }
    }
    func testDiscardInputAuthorityAndRevisionRefusalsHaveNoEffects() throws {
        let p = try cohortProject(),foreign = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker),before = try batchClaimState(p,batch)
        var input: JSON = ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1]
        for reason in [nil,"", "  \n "] as [String?] {input["reason"] = reason;assertCode("INVALID_INPUT") {_ = try self.call("batch_discard",input,worker)}}
        input["reason"] = "Unused";input["expected_revision"] = 2
        assertCode("REVISION_CONFLICT") {_ = try self.call("batch_discard",input,worker)}
        input["expected_revision"] = 1
        input["project_id"] = foreign["id"]
        assertCode("NOT_FOUND") {_ = try self.call("batch_discard",input)}
        input["project_id"] = p["id"]
        let assistant = Caller(role:"assistant",installation:"unqualified",projectIDs:[p["id"] as! String])
        assertCode("FORBIDDEN") {_ = try self.call("batch_discard",input,assistant)}
        let ungranted = Caller(role:"worker",installation:worker.installation,projectIDs:[],sessionID:worker.sessionID,workspace:worker.workspace,executionDomain:worker.executionDomain)
        assertCode("FORBIDDEN") {_ = try self.call("batch_discard",input,ungranted)}
        try router.dbQueue.write {db in var s = try router.record(db,worker.sessionID!,type:"session");s["provider"] = "unsupported";try router.save(db,s,type:"session")}
        assertCode("UNVERIFIED_SESSION") {_ = try self.call("batch_discard",input,worker)}
        XCTAssertEqual(try batchClaimState(p,batch),before)
        XCTAssertTrue(try router.dbQueue.read {try router.records($0,type:"batch_disposition",project:(p["id"] as! String))}.isEmpty)
    }
    func testDiscardReplayAndRepeatedFreshCommandKeepOneImmutableDispositionAndEvent() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),other = try cohortWorker(p),batch = try sharedBatch(p,worker),command = UUID().uuidString
        // Ordinary eligible project worker may discard someone else's unused plan.
        let discarded = try discardBatch(p,batch,other,command:command),replay = try discardBatch(p,batch,other,command:command)
        XCTAssertEqual(try jsonString(discarded),try jsonString(replay))
        let repeated = try discardBatch(p,batch,worker,reason:"Different later reason")
        XCTAssertEqual(try jsonString(discarded["disposition"]!),try jsonString(repeated["disposition"]!))
        let marker = discarded["disposition"] as! JSON
        try router.dbQueue.read {db in
            XCTAssertEqual(try router.records(db,type:"batch_disposition",project:(p["id"] as! String)).count,1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE project_id=? AND kind='batch_discarded'",arguments:[p["id"] as! String]),1)
        }
        XCTAssertThrowsError(try router.dbQueue.write {db in var changed = marker;changed["reason"] = "changed";try router.save(db,changed,type:"batch_disposition")})
    }
    func testDiscardWriterRecordSurvivesCanonicalExportAndVerifiedBackup() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker),marker = try discardBatch(p,batch,worker)["disposition"] as! JSON
        let exported = directory.appendingPathComponent("export")
        _ = try call("export_project",["project_id":p["id"]!,"path":exported.path])
        let contents = try JSONSerialization.jsonObject(with:Data(contentsOf:exported.appendingPathComponent("project.json"))) as! JSON
        XCTAssertEqual(try jsonString((contents["batch_disposition"] as! [JSON])[0]),try jsonString(marker))
        let backup = try call("backup_create",["path":directory.deletingLastPathComponent().appendingPathComponent("batch-backup-"+UUID().uuidString).path])
        XCTAssertEqual(backup["status"] as? String,"complete")
        // The backup path is returned by the actual storage boundary; inspect its
        // canonical SQLite snapshot independently rather than fabricating an envelope.
        let path = backup["path"] as! String
        defer {try? FileManager.default.removeItem(atPath:path)}
        let files = FileManager.default.enumerator(at:URL(fileURLWithPath:path),includingPropertiesForKeys:nil)!.compactMap {$0 as? URL}
        let database = try XCTUnwrap(files.first {$0.lastPathComponent == "database.sqlite"})
        var configuration = Configuration();configuration.readonly = true;configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:database.path,configuration:configuration)
        try copy.read {db in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT "+CommandRouter.canonicalRecordColumns+" FROM records WHERE type='batch_disposition'"))
            let envelope = try GRDBRecordEnvelopeAdapter.decode(row)
            XCTAssertEqual(envelope.type,"batch_disposition");XCTAssertEqual(try jsonString(envelope.object),try jsonString(marker))
        }
    }
    func testDiscardDiscoveryRequiresReasonAndRevision() throws {
        let tools = try call("tool_catalog")["tools"] as! [JSON],tool = try XCTUnwrap(tools.first {$0["name"] as? String == "batch_discard"})
        XCTAssertTrue(Set(strings(tool["inputSchema"] as! JSON,"required")).isSuperset(of:["project_id","batch_id","expected_revision","reason","command_id"]))
    }
}
