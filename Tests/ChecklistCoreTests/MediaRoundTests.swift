import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// Real canonical store/router seams using the established owned-store harness. No app,
/// live service, synthetic storage ticket or trusted-owner assertion from agent text.
final class MediaRoundTests: XCTestCase {
    final class Fixture {
        // Reuse the established owned-store harness: Foundation rewrites every tmp
        // spelling to /tmp, which the real no-follow walker correctly refuses.
        let storage: StorageFixture
        let base: URL,workspace: URL,root: URL
        var router: CommandRouter
        let owner: Caller
        var worker: Caller
        let project: String
        init() throws {
            storage = try StorageFixture()
            base = storage.base;workspace = storage.workspace;root = storage.root
            router = storage.router!;owner = storage.owner
            project = try storage.project()["id"] as! String
            let session = try router.handle(method:"session_register",params:["command_id":uuid(),"project_id":project,"provider":"codex","label":"Actual fixture worker","session_id":"media-fixture-worker","workspace":workspace.path],caller:owner)["data"] as! JSON
            worker = Caller(role:"worker",installation:"media-owned-worker",projectIDs:[project],sessionID:session["id"] as? String ?? "media-fixture-worker",workspace:workspace.path)
        }
        func call(_ method: String,_ p: JSON = [:],as caller: Caller? = nil,command: String? = nil) throws -> JSON {
            var p = p;p["project_id"] = p["project_id"] ?? project
            if !["media_round_get","media_type_get"].contains(method) {p["command_id"] = command ?? uuid()}
            return try router.executeMediaCommand(method:method,params:p,caller:caller ?? owner)
        }
        func rows(_ type: String) throws -> [JSON] {try router.dbQueue.read {try router.records($0,type:type,project:project)}}
        func record(_ id: String,_ type: String) throws -> JSON {try router.dbQueue.read {try router.record($0,id,type:type)}}
        func allState() throws -> String {
            try router.dbQueue.read { db in
                let rows = try Row.fetchAll(db,sql:"SELECT id,type,revision,data FROM records ORDER BY id").map { r -> JSON in ["id":r["id"] as String,"type":r["type"] as String,"revision":r["revision"] as Int,"data":r["data"] as String] }
                let events = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events")!,commands = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands")!,cursors = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM cursors")!
                return try jsonString(["rows":rows,"events":events,"commands":commands,"cursors":cursors])
            }
        }
        func type(_ schema: JSON? = nil,adopt: Bool = true,as caller: Caller? = nil) throws -> JSON {
            var p: JSON = ["title":"Story"];p["schema"] = schema
            let t = try call("media_type_create",p,as:caller)
            return adopt ? try adoptType(t) : t
        }
        func adoptType(_ type: JSON) throws -> JSON {
            let t = try call("media_type_get",["type_id":type["id"]!])
            return try call("media_type_adopt",["type_id":t["id"]!,"type_revision_id":t["draft_revision_id"]!,"expected_revision":t["revision"]!,"observed_type_token":t["observed_type_token"]!])
        }
        func round(_ type: JSON,as caller: Caller? = nil) throws -> JSON { try call("media_round_create",["type_id":type["id"]!,"title":"First pass"],as:caller) }
        func get(_ round: JSON,as caller: Caller? = nil) throws -> JSON {try call("media_round_get",["round_id":round["id"]!],as:caller)}
        func item(_ round: JSON,title: String = "Item",metadata: JSON = [:],texts: [String] = ["Exact text\r\n"],as caller: Caller? = nil) throws -> JSON {
            try call("media_item_create",["round_id":round["id"]!,"title":title,"metadata":metadata,"candidates":texts.map {["slots":[["slot_id":"text","text":$0]]]}],as:caller)
        }
        func observation(_ round: JSON) -> JSON { ["round_id":round["id"]!,"expected_revision":round["revision"]!,"observed_context_token":round["observed_context_token"]!] }
        func selection(_ round: JSON,publish: Bool = false) -> [JSON] {
            (round["items"] as! [JSON]).compactMap { item in
                guard let t = item[publish ? "draft_target" : "published_target"] as? JSON else {return nil}
                let basis = publish ? (item["publication_preview"] as! JSON)["review_basis_signature"]! : t["review_basis_signature"]!
                return ["item_id":item["id"]!,"expected_revision":item["revision"]!,"target_id":t["id"]!,"review_basis_signature":basis]
            }
        }
        func publish(_ round: JSON) throws -> JSON {
            let r = try get(round);var p = observation(r);p["items"] = selection(r,publish:true);return try call("media_round_publish",p)
        }
        func decisionParams(_ round: JSON,ids: [String]? = nil,disposition: String = "accepted") -> JSON {
            var p = observation(round);let m = round["manifest"] as! JSON
            p["manifest_id"] = m["id"];p["manifest_digest"] = m["digest"]
            p["items"] = selection(round).filter {ids == nil || ids!.contains($0["item_id"] as! String)}
            p["disposition"] = disposition
            if disposition == "accepted",let row = (round["items"] as! [JSON]).first(where:{ ids == nil || ids!.contains($0["id"] as! String) }) { p["winner_id"] = strings(row["published_target"] as! JSON,"candidate_ids").first }
            return p
        }
        func acceptEach(_ round: JSON) throws {
            for row in try get(round)["items"] as! [JSON] {
                let r = try get(round);_ = try call("media_decide",decisionParams(r,ids:[row["id"] as! String]))
            }
        }
        func reconcile(_ round: JSON,action: String = "migrate") throws -> JSON {
            let r = try get(round);var p = observation(r);p["attention_ids"] = r["attention_ids"];p["action"] = action;p["reason"] = "Explicit owner scope: this round"
            return try call("media_context_reconcile",p)
        }
    }
    func schema(fields: [JSON] = []) -> JSON {
        ["schema_version":1,"id":"server-replaced","name":"Story","fields":fields,"slots":[["id":"text","kind":"text","required":true]],"layout":["kind":"text_compare","primary_slot_id":"text"]]
    }
    func field(_ id: String,required: Bool = false,kind: String = "short_text",material: Bool = true) -> JSON { ["id":id,"kind":kind,"required":required,"material":material] }
    func checkError(_ code: String,_ body: () throws -> Any,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,code,"\($0)",file:file,line:line) }
    }
    func revise(_ f: Fixture,_ t: JSON,_ definition: JSON,rubric: String? = nil) throws -> JSON {
        let current = try f.call("media_type_get",["type_id":t["id"]!]);var s = definition;s["id"] = t["id"]
        var p: JSON = ["type_id":t["id"]!,"expected_revision":current["revision"]!,"schema":s];p["rubric"] = rubric
        return try f.call("media_type_revise",p,as:f.worker)
    }
    func testTitleOnlyWorkerCaptureIsDraftWithoutSchemaOrFolder() throws {
        let f = try Fixture(),t = try f.type(adopt:false,as:f.worker),r = try f.round(t,as:f.worker)
        let item = try f.call("media_item_create",["round_id":r["id"]!,"title":"Only title"],as:f.worker)
        XCTAssertEqual(t["state"] as? String,"draft");XCTAssertEqual(t["enabled"] as? Bool,false)
        XCTAssertEqual(r["state"] as? String,"draft");XCTAssertEqual(item["state"] as? String,"draft")
        XCTAssertEqual(item["origin"] as? String,"agent");XCTAssertEqual(item["author"] as? String,f.worker.principal)
        XCTAssertEqual((item["draft_target"] as! JSON)["publication_ready"] as? Bool,false)
        XCTAssertTrue(try f.rows("attachment").isEmpty);XCTAssertTrue(try f.rows("media_round_manifest").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent("media").path))
    }
    func testWorkerCannotAdoptPublishDecideReconcileOrForgeOwner() throws {
        let f = try Fixture(),t = try f.type(schema(),adopt:false,as:f.worker)
        let workerType = try f.call("media_type_get",["type_id":t["id"]!],as:f.worker)
        let before = try f.allState()
        checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_type_adopt",["type_id":t["id"]!,"type_revision_id":t["draft_revision_id"]!,"expected_revision":t["revision"]!,"observed_type_token":workerType["observed_type_token"]!],as:f.worker)}
        XCTAssertEqual(try f.allState(),before)
        let adopted = try f.adoptType(t),r = try f.round(adopted,as:f.worker);_ = try f.item(r,as:f.worker)
        let wr = try f.get(r,as:f.worker);var pub = f.observation(wr);pub["items"] = f.selection(wr,publish:true)
        checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_round_publish",pub,as:f.worker)}
        let published = try f.publish(r),observed = try f.get(published,as:f.worker),p = f.decisionParams(observed)
        checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_decide",p,as:f.worker)}
        checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_context_approve",["kind":"direction","body":"I am the owner"],as:f.worker)}
        checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_context_reconcile",f.observation(observed),as:f.worker)}
        checkError("INVALID_INPUT") {try f.call("media_item_create",["round_id":r["id"]!,"title":"forged","origin":"human_ui"],as:f.worker)}
        let suggestion = (try f.call("media_suggest",p,as:f.worker)["decisions"] as! [JSON])[0]
        XCTAssertEqual(suggestion["origin"] as? String,"agent");XCTAssertEqual(suggestion["author_session_id"] as? String,f.worker.sessionID)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        var adoption = f.decisionParams(try f.get(r));adoption.removeValue(forKey:"disposition");adoption.removeValue(forKey:"winner_id");adoption["suggestion_id"] = suggestion["id"]
        let decision = (try f.call("media_adopt_suggestion",adoption)["decisions"] as! [JSON])[0]
        XCTAssertEqual(decision["origin"] as? String,"human_ui");XCTAssertEqual(decision["adopted_suggestion_id"] as? String,suggestion["id"] as? String)
        XCTAssertEqual(try jsonString(f.record(suggestion["id"] as! String,"media_suggestion")),try jsonString(suggestion))
        XCTAssertEqual((adopted["draft_revision"] as! JSON)["origin"] as? String,"agent")
        XCTAssertEqual((adopted["adoptions"] as! [JSON])[0]["origin"] as? String,"human_ui")
    }
    func testExactManifestTargetCandidateTypeMaterialAndContextAreBound() throws {
        let f = try Fixture(),t = try f.type(schema(fields:[field("mood")])),r = try f.round(t)
        _ = try f.item(r,metadata:["mood":"calm"],texts:["take one\r\n","take two\n"])
        let published = try f.publish(r),rows = published["items"] as! [JSON],target = rows[0]["published_target"] as! JSON
        var params = f.decisionParams(published)
        for (key,bad) in [("manifest_digest","wrong"),("observed_context_token","wrong")] {
            var p = params;p[key] = bad;let before = try f.allState();XCTAssertThrowsError(try f.call("media_decide",p));XCTAssertEqual(try f.allState(),before)
        }
        for key in ["target_id","review_basis_signature"] {
            var p = params,selection = p["items"] as! [JSON];selection[0][key] = "wrong";p["items"] = selection
            let before = try f.allState();checkError("MEDIA_BASIS_CHANGED") {try f.call("media_decide",p)};XCTAssertEqual(try f.allState(),before)
        }
        params["winner_id"] = "foreign-take";checkError("INVALID_INPUT") {try f.call("media_decide",params)}
        params["winner_id"] = strings(target,"candidate_ids")[1]
        let cmd = uuid(),decision = (try f.call("media_decide",params,command:cmd)["decisions"] as! [JSON])[0]
        for key in ["review_basis_signature","content_signature","material_definition_signature","context_signature","type_revision_id","context_id","candidate_ids","review_basis_base64"] { XCTAssertEqual(try jsonString(["v":decision[key]!]),try jsonString(["v":target[key]!]),key) }
        XCTAssertEqual(decision["target_id"] as? String,target["id"] as? String)
        XCTAssertEqual(try f.call("media_decide",params,command:cmd)["replayed"] as? Bool,true)
        XCTAssertEqual(try f.rows("media_owner_decision").count,1)
        checkError("REVISION_CONFLICT") {try f.call("media_decide",params)}
        var changed = params;changed["note"] = "different";checkError("IDEMPOTENCY_CONFLICT") {try f.call("media_decide",changed,command:cmd)}
    }
    func testRelevantDirectionFencesStaleAndFreshCommandsWithZeroRecordsUntilReconciled() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r)
        let published = try f.publish(r),oldParams = f.decisionParams(published)
        _ = try f.call("media_context_approve",["kind":"direction","type_id":t["id"]!,"body":"No flashing frames"])
        let changed = try f.get(r);XCTAssertEqual((changed["attention"] as! [JSON]).count,1)
        let before = try f.allState()
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",oldParams)}
        var finish = f.observation(published);finish["manifest_id"] = (published["manifest"] as! JSON)["id"];finish["manifest_digest"] = (published["manifest"] as! JSON)["digest"]
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_round_finish",finish)}
        var pub = f.observation(published);pub["items"] = f.selection(published,publish:true)
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_round_publish",pub)}
        checkError("MEDIA_CONTEXT_ATTENTION") {try f.call("media_decide",f.decisionParams(changed))}
        XCTAssertEqual(try f.allState(),before)
        let reconciled = try f.reconcile(r)
        XCTAssertTrue(strings(reconciled,"attention_ids").isEmpty)
        XCTAssertNotEqual(published["observed_context_token"] as? String,reconciled["observed_context_token"] as? String)
        _ = try f.call("media_decide",f.decisionParams(reconciled));XCTAssertEqual(try f.rows("media_owner_decision").count,1)
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",oldParams)}
    }
    func testScopedMigrationStalesOnlyAffectedItemAndKeepsImmutableHistory() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t)
        let a = try f.item(r,title:"A"),b = try f.item(r,title:"B");_ = try f.publish(r);try f.acceptEach(r)
        let history = try f.rows("media_owner_decision"),targets = try f.rows("media_item_target"),old = try f.get(r)
        _ = try f.call("media_context_approve",["kind":"rubric","round_id":r["id"]!,"item_ids":[a["id"]!],"body":"New rule for A"])
        let migrated = try f.reconcile(r),rows = migrated["items"] as! [JSON]
        XCTAssertEqual(rows.first {$0["id"] as? String == a["id"] as? String}?["disposition"] as? String,"stale")
        XCTAssertEqual(rows.first {$0["id"] as? String == b["id"] as? String}?["disposition"] as? String,"accepted")
        XCTAssertEqual((migrated["reconciliation"] as! JSON)["affected_item_ids"] as? [String],[a["id"] as! String])
        for value in history {XCTAssertEqual(try jsonString(f.record(value["id"] as! String,"media_owner_decision")),try jsonString(value))}
        for value in targets {XCTAssertEqual(try jsonString(f.record(value["id"] as! String,"media_item_target")),try jsonString(value))}
        XCTAssertNotEqual((old["manifest"] as! JSON)["id"] as? String,(migrated["manifest"] as! JSON)["id"] as? String)
    }
    func testKeepIsTrustedScopedExceptionAndDoesNotReturnOnUnrelatedMigration() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);let a = try f.item(r);let b = try f.item(r,title:"B")
        _ = try f.publish(r);try f.acceptEach(r)
        _ = try f.call("media_context_approve",["kind":"direction","item_ids":[a["id"]!],"body":"Future only for A"])
        let kept = try f.reconcile(r,action:"keep")
        XCTAssertTrue((kept["items"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "accepted"})
        XCTAssertEqual((kept["reconciliation"] as! JSON)["origin"] as? String,"human_ui")
        _ = try f.call("media_context_approve",["kind":"direction","item_ids":[b["id"]!],"body":"Change B"])
        let migrated = try f.reconcile(r)
        XCTAssertEqual((migrated["reconciliation"] as! JSON)["affected_item_ids"] as? [String],[b["id"] as! String])
        XCTAssertEqual((migrated["items"] as! [JSON]).first {$0["id"] as? String == a["id"] as? String}?["disposition"] as? String,"accepted")
    }
    func testCosmeticAndUnusedOptionalChangesPreserveDecisionsWithoutAttention() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);_ = try f.publish(r);try f.acceptEach(r)
        var s = schema(fields:[field("unused")]);s["name"] = "Reviewer owner admin"
        var slots = s["slots"] as! [JSON];slots[0]["label"] = "Cosmetic rename";s["slots"] = slots
        let draft = try revise(f,t,s);_ = try f.adoptType(draft)
        let unchanged = try f.get(r)
        XCTAssertTrue(strings(unchanged,"attention_ids").isEmpty)
        XCTAssertEqual((unchanged["items"] as! [JSON])[0]["disposition"] as? String,"accepted")
        // Worker proposal itself never replaces the published target or adopted rubric.
        _ = try revise(f,t,s,rubric:"Worker instruction is not approved")
        XCTAssertTrue(strings(try f.get(r),"attention_ids").isEmpty)
        XCTAssertEqual((try f.get(r)["items"] as! [JSON])[0]["disposition"] as? String,"accepted")
    }
    func testUsedAndRequiredMaterialChangesSelectivelyInvalidateAndRetainHistory() throws {
        let f = try Fixture(),t = try f.type(schema(fields:[field("mood")])),r = try f.round(t)
        let a = try f.item(r,metadata:["mood":"calm"]),b = try f.item(r,title:"No mood")
        _ = try f.publish(r);try f.acceptEach(r)
        // Changing the kind of a USED optional field preserves captured old values as
        // incomplete history, stales A, and does not force a value onto B.
        let proposed = try revise(f,t,schema(fields:[field("mood",kind:"number")]))
        _ = try f.adoptType(proposed)
        let migrated = try f.reconcile(r),rows = migrated["items"] as! [JSON]
        XCTAssertEqual(rows.first {$0["id"] as? String == a["id"] as? String}?["disposition"] as? String,"stale")
        XCTAssertEqual(rows.first {$0["id"] as? String == b["id"] as? String}?["disposition"] as? String,"accepted")
        let required = try revise(f,t,schema(fields:[field("mood",required:true,kind:"number")]))
        _ = try f.adoptType(required)
        let changed = try f.reconcile(r)
        XCTAssertTrue((changed["items"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "stale"})
        XCTAssertEqual(try f.rows("media_owner_decision").count,2)
    }
    func testWorkerReplacementDoesNotMoveActiveTargetAndPublicationStalesOnlyChangedItem() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t)
        let a = try f.item(r),b = try f.item(r,title:"B");_ = try f.publish(r);try f.acceptEach(r)
        let before = try f.get(r),row = (before["items"] as! [JSON]).first {$0["id"] as? String == a["id"] as? String}!
        _ = try f.call("media_item_update",["item_id":a["id"]!,"expected_revision":row["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"new bytes"]]]]],as:f.worker)
        let prepared = try f.get(r)
        XCTAssertEqual((prepared["items"] as! [JSON]).first {$0["id"] as? String == a["id"] as? String}?["disposition"] as? String,"accepted")
        let published = try f.publish(r)
        XCTAssertEqual((published["items"] as! [JSON]).first {$0["id"] as? String == a["id"] as? String}?["disposition"] as? String,"stale")
        XCTAssertEqual((published["items"] as! [JSON]).first {$0["id"] as? String == b["id"] as? String}?["disposition"] as? String,"accepted")
    }
    func testBulkConflictAndLateReceiptFailureRollBackWholeCommand() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);_ = try f.item(r,title:"B");let published = try f.publish(r)
        var p = f.decisionParams(published,disposition:"needs_look"),selection = p["items"] as! [JSON];selection[1]["target_id"] = "wrong";p["items"] = selection
        let before = try f.allState();checkError("MEDIA_BASIS_CHANGED") {try f.call("media_decide",p)};XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TEMP TRIGGER cl112_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned receipt failure');END")}
        p = f.decisionParams(published,disposition:"needs_look")
        XCTAssertThrowsError(try f.call("media_decide",p));XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cl112_receipt_failure")}
        _ = try f.call("media_decide",p);XCTAssertEqual(try f.rows("media_owner_decision").count,2)
    }
    func testProjectApprovalHookGlobalPinsAndAgentTextStaySeparate() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);_ = try f.publish(r);try f.acceptEach(r)
        var project = try f.record(f.project,"project")
        _ = try f.router.handle(method:"project_edit",params:["command_id":uuid(),"project_id":f.project,"expected_revision":project["revision"]!,"brief":"Approved global brief","pinned_decisions":[["body":"Global rule"],["body":"Task-only rule","task_kinds":["asset"]]]],caller:f.owner)
        XCTAssertFalse(strings(try f.get(r),"attention_ids").isEmpty)
        _ = try f.reconcile(r)
        let approved = try f.rows("media_review_context").last {$0["kind"] as? String == "project_approval"}!
        XCTAssertEqual(((approved["approved_context"] as! JSON)["pinned_decisions"] as! [JSON]).count,1)
        project = try f.record(f.project,"project")
        _ = try f.router.handle(method:"project_edit",params:["command_id":uuid(),"project_id":f.project,"expected_revision":project["revision"]!,"brief":"Agent proposal, not an approval"],caller:f.worker)
        XCTAssertTrue(strings(try f.get(r),"attention_ids").isEmpty)
        XCTAssertEqual(try f.rows("media_review_context").filter {$0["kind"] as? String == "project_approval"}.count,1)
        // An ordinary informational note does not enter the media applicability resolver.
        let task = try f.router.handle(method:"task_create",params:fixtureTaskInput(f.router,method:"task_create",input:["command_id":uuid(),"project_id":f.project,"title":"Informational note fixture"]),caller:f.owner)["data"] as! JSON
        _ = try f.router.handle(method:"message_send",params:["command_id":uuid(),"project_id":f.project,"task_id":task["id"]!,"body":"FYI, no new media direction"],caller:f.owner)
        XCTAssertTrue(strings(try f.get(r),"attention_ids").isEmpty)
        // A type name such as Owner/Reviewer has no effect on this worker's authority.
        let named = try f.type(adopt:false,as:f.worker);XCTAssertEqual(named["origin"] as? String,"agent")
    }
    func testTokensBindCallerRoundGrantAndIncarnationAndWorkerDispatchStaysDisabled() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);let published = try f.publish(r)
        let workerView = try f.get(r,as:f.worker)
        var p = f.decisionParams(published);p["observed_context_token"] = workerView["observed_context_token"]
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",p)}
        let r2 = try f.round(t);var wrong = f.observation(published);wrong["round_id"] = r2["id"];wrong["attention_ids"] = [];wrong["action"] = "keep";wrong["reason"] = "wrong round"
        checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_context_reconcile",wrong)}
        let fake = Caller(role:"worker",installation:"media-owned-worker",projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.workspace.path + "/different")
        let fakeView = try f.get(r,as:fake);XCTAssertNotEqual(fakeView["observed_context_token"] as? String,workerView["observed_context_token"] as? String)
        try f.router.dbQueue.write { db in
            var s = try f.router.record(db,f.worker.sessionID!,type:"session");s["authorization_generation"] = uuid();try f.router.save(db,f.router.revised(s),type:"session")
        }
        XCTAssertNotEqual((try f.get(r,as:f.worker))["observed_context_token"] as? String,workerView["observed_context_token"] as? String)
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[f.project],assistantGrants:[f.project:["read":true]])
        checkError("FORBIDDEN") {try f.get(r,as:assistant)}
        checkError("FORBIDDEN") {try f.router.handle(method:"media_round_create",params:["command_id":uuid(),"project_id":f.project,"type_id":t["id"]!,"title":"Cannot dispatch"],caller:f.worker)}
        let catalog = try f.router.handle(method:"tool_catalog",params:[:],caller:f.worker)
        XCTAssertFalse(try jsonString(catalog).contains("media_round_create"));XCTAssertFalse(try jsonString(catalog).contains("media_decide"))
    }
    func testPublishedFamiliesExportAndBackupRetainExactImmutableHistory() throws {
        let f = try Fixture(),t = try f.type(schema(),as:f.worker),r = try f.round(t);_ = try f.item(r,as:f.worker);_ = try f.publish(r)
        let w = try f.get(r,as:f.worker);_ = try f.call("media_suggest",f.decisionParams(w),as:f.worker)
        try f.acceptEach(r)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":r["id"]!,"body":"Keep for a successor round"]);_ = try f.reconcile(r,action:"keep")
        let exported = f.base.appendingPathComponent("export"),backup = f.base.appendingPathComponent("backup")
        _ = try f.router.handle(method:"export_project",params:["command_id":uuid(),"project_id":f.project,"path":exported.path],caller:f.owner)
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:exported.appendingPathComponent("project.json"))) as! JSON
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:backup.appendingPathComponent("database.sqlite").path,configuration:config);defer {try? copy.close()}
        let copied = try copy.read {try MediaRecordRegistry.envelopes($0)}
        for type in ["media_review_type","media_review_type_revision","media_round","media_round_manifest","media_review_context","media_context_attention","media_context_reconciliation","media_item","media_item_target","media_candidate","media_owner_decision","media_suggestion"] {
            let actual = try f.rows(type);XCTAssertFalse(actual.isEmpty,type)
            for row in actual {
                XCTAssertEqual(try jsonString((json[type] as! [JSON]).first {$0["id"] as? String == row["id"] as? String}!),try jsonString(row))
                XCTAssertEqual(try jsonString(copied.first {$0.id == row["id"] as? String}!.object),try jsonString(row))
            }
        }
        let target = try f.rows("media_item_target")[0]
        try f.router.dbQueue.write { db in
            var changed = target;changed["title"] = "Overwrite forbidden"
            XCTAssertThrowsError(try f.router.save(db,changed,type:"media_item_target"))
        }
        try f.router.closeStore();f.router = try CommandRouter(root:f.root)
        XCTAssertEqual((try f.get(r)["items"] as! [JSON])[0]["disposition"] as? String,"accepted")
    }
    func testNoInferredAcceptanceOrFilePathPublicationAndClosedRoundStaysFrozen() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);let published = try f.publish(r)
        var finish = f.observation(published);finish["manifest_id"] = (published["manifest"] as! JSON)["id"];finish["manifest_digest"] = (published["manifest"] as! JSON)["digest"]
        checkError("MEDIA_UNRESOLVED") {try f.call("media_round_finish",finish)}
        XCTAssertEqual((try f.get(r)["items"] as! [JSON])[0]["disposition"] as? String,"pending")
        checkError("MEDIA_CAPTURE_REQUIRED") {try f.call("media_item_create",["round_id":r["id"]!,"title":"Path is not captured media","candidates":[["slots":[["slot_id":"text","path":"/tmp/latest"]]]]])}
        try f.acceptEach(r);_ = try f.call("media_round_finish",finish)
        XCTAssertEqual((try f.get(r))["state"] as? String,"closed")
        checkError("MEDIA_ROUND_CLOSED") {try f.item(r)}
        XCTAssertEqual(try f.rows("media_owner_decision").count,1)
    }
    func testPreexistingProjectContextRequiresExplicitAdoptionAndDraftSchemaWasReallyAdopted() throws {
        let f = try Fixture()
        var project = try f.record(f.project,"project")
        _ = try f.router.handle(method:"project_edit",params:["command_id":uuid(),"project_id":f.project,"expected_revision":project["revision"]!,"brief":"Preexisting owner brief"],caller:f.owner)
        let t = try f.type(schema()),r = try f.round(t);_ = try f.item(r)
        checkError("MEDIA_PROJECT_CONTEXT_REQUIRED") {try f.publish(r)}
        project = try f.record(f.project,"project")
        _ = try f.call("media_context_approve",["kind":"project","expected_project_revision":project["revision"]!])
        _ = try f.reconcile(r);_ = try f.publish(r)
        // A different proposal cannot give an unadopted pinned schema publication authority.
        let draftType = try f.type(schema(),adopt:false,as:f.worker),draftRound = try f.round(draftType)
        _ = try f.item(draftRound)
        var cosmetic = schema();cosmetic["name"] = "Renamed proposal"
        _ = try revise(f,draftType,cosmetic);_ = try f.adoptType(draftType)
        XCTAssertFalse(strings(try f.get(draftRound),"attention_ids").isEmpty)
        _ = try f.reconcile(draftRound,action:"keep")
        checkError("MEDIA_TYPE_NOT_ADOPTED") {try f.publish(draftRound)}
    }
    func testBulkAcceptanceNamesEachWinnerAndBooleanRevisionRefuses() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t);_ = try f.item(r);_ = try f.item(r,title:"B");let published = try f.publish(r)
        var p = f.decisionParams(published);p.removeValue(forKey:"winner_id")
        p["items"] = (p["items"] as! [JSON]).map { entry -> JSON in
            var e = entry;let row = (published["items"] as! [JSON]).first {$0["id"] as? String == e["item_id"] as? String}!
            e["winner_id"] = strings(row["published_target"] as! JSON,"candidate_ids")[0];return e
        }
        let decisions = try f.call("media_decide",p)["decisions"] as! [JSON];XCTAssertEqual(decisions.count,2)
        XCTAssertEqual(Set(decisions.compactMap {$0["winner_id"] as? String}).count,2)
        let title = try f.type(adopt:false);var malformed: JSON = ["type_id":title["id"]!,"expected_revision":true,"title":"No"]
        let before = try f.allState();checkError("REVISION_REQUIRED") {try f.call("media_type_revise",malformed)};XCTAssertEqual(try f.allState(),before)
        malformed["expected_revision"] = title["revision"];_ = try f.call("media_type_revise",malformed)
    }
    func testCanonicalGoldenExactUnicodeNewlinesAndNumericNormalization() throws {
        XCTAssertEqual(String(data:try MediaCanonical.bytes(["x":1]),encoding:.utf8),"28:checklist.media.canonical.v16:object1:11:x6:number1:1")
        XCTAssertEqual(try MediaCanonical.bytes(["n":1]),try MediaCanonical.bytes(["n":1.0]))
        XCTAssertEqual(try MediaCanonical.bytes(["n":-0.0]),try MediaCanonical.bytes(["n":0]))
        XCTAssertNotEqual(try MediaCanonical.bytes(["s":"é"]),try MediaCanonical.bytes(["s":"e\u{301}"]))
        XCTAssertNotEqual(try MediaCanonical.bytes(["s":"line\r\n"]),try MediaCanonical.bytes(["s":"line\n"]))
        XCTAssertThrowsError(try MediaCanonical.bytes(["n":Double.infinity]))
        XCTAssertNotEqual(try MediaCanonical.bytes(["b":true]),try MediaCanonical.bytes(["b":1]))
    }
    func testSupersedingInstructionAwayFromEmptyDraftMustFenceIt() throws {
        let h = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let t = try f.type(h.schema()), r = try f.round(t)
        let old = try f.call("media_context_approve",["kind":"direction","round_id":r["id"]!,"body":"Old direction"])
        _ = try f.reconcile(r)
        let other = try f.round(t)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":other["id"]!,"body":"Only the other round now","supersedes_id":old["id"]!])
        let view = try f.get(r)
        XCTAssertFalse(strings(view,"attention_ids").isEmpty,"Removal of an applicable approved instruction must create attention even before the first Draft item")
        _ = try f.item(r)
        let before = try f.allState()
        XCTAssertThrowsError(try f.publish(r),"Publication must not silently use the superseded direction")
        XCTAssertEqual(try f.allState(),before)
        let reconciled = try f.reconcile(r)
        XCTAssertTrue(strings(reconciled["context"] as! JSON,"source_ids").isEmpty)
        _ = try f.publish(r)
    }
    func testRevertedTypeAdoptionMustNotMigrateToSupersededRubric() throws {
        let h = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let t = try f.type(h.schema()), r = try f.round(t)
        _ = try f.item(r); _ = try f.publish(r); try f.acceptEach(r)
        let strict = try h.revise(f,t,h.schema(),rubric:"Strict temporary rubric")
        _ = try f.adoptType(strict)
        let reverted = try h.revise(f,t,h.schema(),rubric:"")
        let adopted = try f.adoptType(reverted)
        let pending = strings(try f.get(r),"attention_ids")
        XCTAssertEqual(pending.count,2,"The reversion must supersede the intermediate pending adoption")
        let historical = try f.record(strict["draft_revision_id"] as! String,"media_review_type_revision")
        let result = try f.reconcile(r)
        XCTAssertEqual(result["type_revision_id"] as? String,adopted["adopted_revision_id"] as? String,"Migrate must not select a superseded intermediate adoption")
        XCTAssertEqual((result["items"] as! [JSON])[0]["disposition"] as? String,"accepted","Returning to the identical rubric must preserve the unaffected decision")
        let revision = try f.record(result["type_revision_id"] as! String,"media_review_type_revision")
        XCTAssertEqual(revision["rubric"] as? String,"")
        XCTAssertEqual(strings(result["reconciliation"] as! JSON,"attention_ids"),pending)
        XCTAssertEqual(try jsonString(f.record(strict["draft_revision_id"] as! String,"media_review_type_revision")),try jsonString(historical))
        for id in pending { XCTAssertEqual(try f.record(id,"media_context_attention")["state"] as? String,"reconciled") }
    }
    func testNonStringCandidateMustRefuseWithoutWriting() throws {
        let h = MediaRoundTests(), f = try MediaRoundTests.Fixture()
        let t = try f.type(h.schema()), r = try f.round(t)
        let before = try f.allState()
        XCTAssertThrowsError(try f.call("media_item_create",["round_id":r["id"]!,"title":"Invalid text","candidates":[["slots":[["slot_id":"text","text":123]]]]]),"An integer is not exact captured UTF-8 text")
        XCTAssertEqual(try f.allState(),before,"Malformed captured material must not silently write a different value")
    }
    func testMalformedTextVariantsRefuseAndEmptyExactTextRemainsValid() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t)
        let malformedValues: [Any] = [123,true,NSNull(),["text"],["value":"text"]]
        for malformed in malformedValues {
            let before = try f.allState()
            checkError("INVALID_INPUT") { try f.call("media_item_create",["round_id":r["id"]!,"title":"Malformed","candidates":[["slots":[["slot_id":"text","text":malformed]]]]]) }
            XCTAssertEqual(try f.allState(),before)
        }
        let item = try f.item(r,texts:["","  e\u{301}\r\n\t "])
        let candidates = try strings(item["draft_target"] as! JSON,"candidate_ids").map {try f.record($0,"media_candidate")}
        let captured = candidates.map {($0["slots"] as! [JSON])[0]["text"] as! String}
        XCTAssertEqual(Set(captured.map {Data($0.utf8)}),Set([Data(),Data("  e\u{301}\r\n\t ".utf8)]))
        _ = try f.publish(r)
    }
    func testPreparedMediaCommandRejectsInterveningSameRevisionEditWithoutWriting() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t),item = try f.item(r)
        let input: JSON = ["project_id":f.project,"command_id":uuid(),"item_id":item["id"]!,"expected_revision":item["revision"]!,"title":"Prepared edit"]
        let prepared = try XCTUnwrap(f.router.prepareMediaCommand(method:"media_item_update",params:input,caller:f.owner))
        defer {try? prepared.observer.close()}
        try f.router.dbQueue.write { db in
            var current = try f.router.record(db,item["id"] as! String,type:"media_item")
            current["title"] = "Intervening edit at the same revision"
            try f.router.mediaWrite(db,current,type:"media_item")
        }
        let before = try f.allState()
        try f.router.dbQueue.write { db in
            checkError("MEDIA_CONTEXT_CHANGED") {try prepared.commit(db)}
        }
        XCTAssertEqual(try f.allState(),before)
        // A fresh command prepares again rather than reusing obsolete material.
        _ = try f.call("media_item_update",["item_id":item["id"]!,"expected_revision":item["revision"]!,"title":"Fresh edit"])
    }
    func testPendingStorageIntentIsCheckedBeforeMediaPreparation() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t),command = uuid()
        try f.router.dbQueue.write { db in
            let key = try f.router.pendingStorageCommandKey(principal:f.owner.principal,command:command)
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:[key,try jsonString(["intent_digest":"reserved-storage-intent"])])
        }
        let before = try f.allState()
        checkError("IDEMPOTENCY_CONFLICT") {
            try f.call("media_item_create",["round_id":r["id"]!,"title":"Malformed but reserved","candidates":[["slots":[["slot_id":"text","text":123]]]]],command:command)
        }
        XCTAssertEqual(try f.allState(),before)
    }
    func testLargeRetainedHistoryDoesNotHoldWriterDuringPreparation() throws {
        let f = try Fixture(),t = try f.type(schema()),r = try f.round(t),item = try f.item(r)
        let baselineStart = Date()
        let first = try f.call("media_item_update",["item_id":item["id"]!,"expected_revision":item["revision"]!,"title":"Baseline"])
        let baseline = Date().timeIntervalSince(baselineStart)
        let other = try f.item(r,title:"Unrelated retained history",texts:[String(repeating:"x",count:256 * 1024)])
        let prior = try f.record(strings(other["draft_target"] as! JSON,"candidate_ids")[0],"media_candidate")
        try f.router.dbQueue.write { db in
            for _ in 0..<200 {
                var row = prior;row["id"] = uuid()
                try f.router.mediaWrite(db,row,type:"media_candidate")
            }
        }
        let started = DispatchSemaphore(value:0),done = DispatchSemaphore(value:0)
        var commandError: Error?,signaled = false,historyScans = 0
        f.router.dbQueue.writeWithoutTransaction { db in
            db.trace(options:[.statement]) { event in
                guard case .statement(let statement) = event else {return}
                if statement.sql.hasPrefix("BEGIN IMMEDIATE"),!signaled {signaled = true;started.signal()}
                if statement.sql.contains("FROM records"),statement.sql.contains("ORDER BY id COLLATE BINARY") {historyScans += 1}
            }
        }
        let overallStart = Date()
        DispatchQueue.global().async {
            do {_ = try f.call("media_item_update",["item_id":first["id"]!,"expected_revision":first["revision"]!,"title":"Tiny edit after history"])} catch {commandError = error}
            done.signal()
        }
        XCTAssertEqual(started.wait(timeout:.now()+30),.success)
        let waitStart = Date()
        _ = try f.router.dbQueue.writeWithoutTransaction {try Int.fetchOne($0,sql:"SELECT 1")}
        let writerWait = Date().timeIntervalSince(waitStart)
        XCTAssertEqual(done.wait(timeout:.now()+30),.success)
        f.router.dbQueue.writeWithoutTransaction {$0.trace(nil)}
        if let commandError {throw commandError}
        XCTAssertEqual(historyScans,0,"No full-history read/validation may run on the writer connection")
        XCTAssertLessThan(writerWait,0.5,"A tiny edit must not keep another writer waiting on retained history")
        let current = try f.record(item["id"] as! String,"media_item")
        XCTAssertEqual(current["title"] as? String,"Tiny edit after history")
        print("CL112_WRITER_MEASUREMENT baseline_seconds=\(baseline) retained_candidate_bytes=\(201 * 256 * 1024) concurrent_writer_wait_seconds=\(writerWait) total_seconds=\(Date().timeIntervalSince(overallStart))")
    }
}
