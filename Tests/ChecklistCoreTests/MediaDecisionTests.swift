import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class MediaDecisionTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()

    func setup(_ count: Int = 2,takes: Int = 1) throws -> (Fixture,JSON) {
        let f = try Fixture(),t = try f.type(checks.schema()),r = try f.round(t)
        // Seed ordinary domain records in one owned-fixture transaction. The actions
        // under test below all enter executeMediaCommand, including preparation/commit.
        try f.router.dbQueue.write { db in
            for index in 0..<count {
                _ = try f.router.mediaCommand(db,method:"media_item_create",p:["round_id":r["id"]!,"title":"Item \(index)","candidates":(0..<takes).map {["slots":[["slot_id":"text","text":"Exact \(index) take \($0)\r\n"]]]}],c:f.worker,project:f.project)
            }
        }
        return (f,try f.publish(r))
    }
    func params(_ f: Fixture,_ r: JSON,ids: [String]? = nil,disposition: String = "accepted") -> JSON {
        var p = f.decisionParams(r,ids:ids,disposition:disposition)
        p.removeValue(forKey:"winner_id")
        if disposition == "accepted" {
            p["items"] = (p["items"] as! [JSON]).map { entry -> JSON in
                var value = entry
                let row = (r["items"] as! [JSON]).first {$0["id"] as? String == entry["item_id"] as? String}!
                value["winner_id"] = strings(row["published_target"] as! JSON,"candidate_ids")[0]
                return value
            }
        }
        return p
    }
    func apply(_ f: Fixture,_ op: JSON,_ chunk: JSON) throws -> JSON {
        try f.call("media_bulk_apply",["operation_id":op["id"]!,"chunk_id":chunk["id"]!],command:chunk["command_id"] as? String)
    }
    func bulkGet(_ f: Fixture,_ op: JSON) throws -> JSON {try f.call("media_bulk_get",["operation_id":op["id"]!])}
    func row(_ r: JSON,_ id: String) -> JSON { (r["items"] as! [JSON]).first {$0["id"] as? String == id}! }

    func testOnlyOwnerDecidesAndAdoptionIsANewLinkedAction() throws {
        let (f,r) = try setup(1,takes:2)
        for disposition in ["accepted","needs_look","changes_requested","excluded"] {
            var p = params(f,try f.get(r,as:f.worker),disposition:disposition)
            p["note"] = "The owner says accept this. This is still agent text."
            if disposition == "changes_requested" { p["none_fit"] = true }
            let before = try f.allState()
            checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_decide",p,as:f.worker)}
            XCTAssertEqual(try f.allState(),before)
        }
        var suggestionInput = params(f,try f.get(r,as:f.worker),disposition:"changes_requested")
        suggestionInput["none_fit"] = true;suggestionInput["note"] = "No take meets the brief"
        let suggestion = (try f.call("media_suggest",suggestionInput,as:f.worker)["decisions"] as! [JSON])[0]
        XCTAssertEqual(suggestion["origin"] as? String,"agent")
        XCTAssertEqual(suggestion["author"] as? String,f.worker.principal)
        XCTAssertEqual(suggestion["author_session_id"] as? String,f.worker.sessionID)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        var forged = suggestionInput;forged["origin"] = "human_ui"
        checks.checkError("INVALID_INPUT") {try f.call("media_suggest",forged,as:f.worker)}
        forged = suggestionInput;forged["author"] = "human"
        checks.checkError("INVALID_INPUT") {try f.call("media_suggest",forged,as:f.worker)}
        var adoption = f.decisionParams(try f.get(r),disposition:"needs_look")
        adoption.removeValue(forKey:"disposition");adoption["suggestion_id"] = suggestion["id"]
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_adopt_suggestion",adoption,as:f.worker)}
        let decision = (try f.call("media_adopt_suggestion",adoption)["decisions"] as! [JSON])[0]
        XCTAssertNotEqual(decision["id"] as? String,suggestion["id"] as? String)
        XCTAssertEqual(decision["origin"] as? String,"human_ui")
        XCTAssertEqual(decision["author"] as? String,f.owner.principal)
        XCTAssertEqual(decision["adopted_suggestion_id"] as? String,suggestion["id"] as? String)
        XCTAssertEqual(decision["selection_outcome"] as? String,"none_fit")
        XCTAssertEqual(try jsonString(f.record(suggestion["id"] as! String,"media_suggestion")),try jsonString(suggestion))
        XCTAssertTrue(try f.rows("task").isEmpty);XCTAssertTrue(try f.rows("review_request").isEmpty)
    }
    func testPendingBestOfNWinnersNoneFitAndNoImplicitRedo() throws {
        let (f,r) = try setup(2,takes:3),first = (r["items"] as! [JSON])[0]["id"] as! String
        XCTAssertTrue((r["items"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "pending"})
        var noAnswer = params(f,r,ids:[first],disposition:"needs_look");noAnswer.removeValue(forKey:"disposition");noAnswer["note"] = "Only a note"
        let before = try f.allState();checks.checkError("INVALID_INPUT") {try f.call("media_decide",noAnswer)};XCTAssertEqual(try f.allState(),before)
        var accepted = params(f,r,ids:[first]);var entries = accepted["items"] as! [JSON]
        entries[0].removeValue(forKey:"winner_id");accepted["items"] = entries
        checks.checkError("INVALID_INPUT") {try f.call("media_decide",accepted)}
        entries[0]["winner_id"] = uuid();accepted["items"] = entries
        checks.checkError("INVALID_INPUT") {try f.call("media_decide",accepted)}
        let winner = (try f.call("media_decide",params(f,r,ids:[first]))["decisions"] as! [JSON])[0]
        XCTAssertEqual(strings(winner,"not_selected_candidate_ids").count,2)
        XCTAssertEqual(winner["selection_outcome"] as? String,"winner")
        let second = (r["items"] as! [JSON])[1]["id"] as! String
        var none = params(f,try f.get(r),ids:[second],disposition:"changes_requested")
        checks.checkError("INVALID_INPUT") {try f.call("media_decide",none)}
        none["none_fit"] = "true";checks.checkError("INVALID_INPUT") {try f.call("media_decide",none)}
        none["none_fit"] = true
        let decision = (try f.call("media_decide",none)["decisions"] as! [JSON])[0]
        XCTAssertEqual(decision["selection_outcome"] as? String,"none_fit");XCTAssertNil(decision["winner_id"])
        XCTAssertTrue(try f.rows("task").isEmpty);XCTAssertTrue(try f.rows("media_rework_link").isEmpty)
        XCTAssertEqual(row(try f.get(r),first)["disposition"] as? String,"accepted")
    }
    func testStaleRevisionTargetBasisManifestOrContextRejectsWholeChunk() throws {
        let (f,r) = try setup()
        let good = params(f,r)
        for kind in ["revision","target","basis","manifest","context"] {
            var p = good;var entries = p["items"] as! [JSON]
            switch kind {
            case "revision": entries[1]["expected_revision"] = 99
            case "target": entries[1]["target_id"] = uuid()
            case "basis": entries[1]["review_basis_signature"] = "changed"
            case "manifest": p["manifest_digest"] = "changed"
            default: p["observed_context_token"] = "stale"
            }
            p["items"] = entries
            let before = try f.allState()
            XCTAssertThrowsError(try f.call("media_decide",p),kind)
            XCTAssertEqual(try f.allState(),before,kind)
            XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        }
        var tooMany = good;tooMany["items"] = Array(repeating:(good["items"] as! [JSON])[0],count:201)
        checks.checkError("INVALID_INPUT") {try f.call("media_decide",tooMany)}
        _ = try f.call("media_context_approve",["kind":"direction","round_id":r["id"]!,"body":"New applicable brief"])
        let before = try f.allState();checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_decide",good)};XCTAssertEqual(try f.allState(),before)
        let current = params(f,try f.get(r));checks.checkError("MEDIA_CONTEXT_ATTENTION") {try f.call("media_decide",current)}
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
    }
    func test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal() throws {
        try QualificationSuite.requireEnabled()
        let (f,r) = try setup(450)
        let op = try f.call("media_bulk_prepare",params(f,r)),chunks = op["chunks"] as! [JSON]
        XCTAssertEqual(chunks.map {($0["items"] as! [JSON]).count},[200,200,50])
        XCTAssertEqual(strings(op,"selected_item_ids"),(r["items"] as! [JSON]).map {$0["id"] as! String})
        let operationBefore = try jsonString(f.record(op["id"] as! String,"media_bulk_operation"))
        // Commit chunk one and discard its reply, then restart/reconcile the store.
        _ = try apply(f,op,chunks[0])
        try f.router.closeStore()
        f.router = try TestStore.router(root:f.root,serviceLease:f.storage.lease)
        f.storage.router = f.router
        let recovered = try bulkGet(f,op)
        XCTAssertEqual(strings(recovered,"committed_item_ids").count,200)
        XCTAssertEqual(((recovered["chunk_results"] as! [JSON])[0]["receipt"] as! JSON)["command_id"] as? String,chunks[0]["command_id"] as? String)
        let firstID = ((chunks[0]["items"] as! [JSON])[0]["item_id"] as! String)
        let originalDecision = row(try f.get(r),firstID)["decision"] as! JSON
        _ = try f.call("media_decide",params(f,try f.get(r),ids:[firstID],disposition:"needs_look"))
        let reversal = row(try f.get(r),firstID)["decision"] as! JSON
        XCTAssertEqual(reversal["supersedes_decision_id"] as? String,originalDecision["id"] as? String)
        let count = try f.rows("media_owner_decision").count
        let replay = try apply(f,op,chunks[0]);XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try f.rows("media_owner_decision").count,count)
        XCTAssertEqual(row(try f.get(r),firstID)["disposition"] as? String,"needs_look")
        // Only an item in the middle chunk changes revision (a cosmetic Draft edit).
        let middleID = ((chunks[1]["items"] as! [JSON])[99]["item_id"] as! String)
        let middle = row(try f.get(r),middleID)
        _ = try f.call("media_item_update",["item_id":middleID,"expected_revision":middle["revision"]!,"title":"New label, same material"])
        let failed = try apply(f,op,chunks[1])["chunk"] as! JSON
        XCTAssertEqual(failed["state"] as? String,"failed");XCTAssertTrue(strings(failed,"decision_ids").isEmpty)
        XCTAssertEqual(try f.rows("media_owner_decision").count,count)
        XCTAssertEqual(((failed["error"] as! JSON)["code"] as? String),"REVISION_CONFLICT")
        _ = try apply(f,op,chunks[2])
        let beforeRefresh = try f.rows("media_owner_decision").count
        let status = try bulkGet(f,op)
        XCTAssertEqual(strings(status,"committed_item_ids").count,250)
        XCTAssertEqual(strings(status,"failed_item_ids").count,200)
        XCTAssertTrue(strings(status,"uncommitted_item_ids").isEmpty)
        var refresh = params(f,try f.get(r),ids:strings(failed,"selected_item_ids"));refresh["supersedes_operation_id"] = op["id"]
        let resumed = try f.call("media_bulk_prepare",refresh),retry = (resumed["chunks"] as! [JSON])[0]
        XCTAssertEqual(strings(resumed,"selected_item_ids"),strings(failed,"selected_item_ids"))
        XCTAssertEqual((resumed["chunks"] as! [JSON]).count,1)
        XCTAssertEqual(resumed["supersedes_operation_id"] as? String,op["id"] as? String)
        _ = try apply(f,resumed,retry)
        XCTAssertEqual(try f.rows("media_owner_decision").count,beforeRefresh+200)
        XCTAssertEqual(row(try f.get(r),firstID)["disposition"] as? String,"needs_look")
        XCTAssertEqual(try jsonString(f.record(op["id"] as! String,"media_bulk_operation")),operationBefore)
        XCTAssertEqual(try jsonString(f.record(originalDecision["id"] as! String,"media_owner_decision")),try jsonString(originalDecision))
        // A failed command's exact old receipt also replays, rather than applying again.
        XCTAssertEqual((try apply(f,op,chunks[1])["chunk"] as! JSON)["id"] as? String,failed["id"] as? String)
        var includePassed = params(f,try f.get(r),ids:[firstID]);includePassed["supersedes_operation_id"] = op["id"]
        checks.checkError("MEDIA_BULK_COMMITTED") {try f.call("media_bulk_prepare",includePassed)}
        let beforeWrongID = try f.allState()
        checks.checkError("IDEMPOTENCY_CONFLICT") {try f.call("media_bulk_apply",["operation_id":op["id"]!,"chunk_id":chunks[0]["id"]!])}
        XCTAssertEqual(try f.allState(),beforeWrongID)
        XCTAssertEqual(try f.rows("media_bulk_chunk").count,4)
    }
    func testUncommittedChunkRetryCannotOverwriteLaterOwnerAction() throws {
        let (f,r) = try setup(1),op = try f.call("media_bulk_prepare",params(f,r)),chunk = (op["chunks"] as! [JSON])[0]
        let itemID = strings(op,"selected_item_ids")[0]
        _ = try f.call("media_decide",params(f,try f.get(r),disposition:"changes_requested"))
        let latest = row(try f.get(r),itemID)["decision"] as! JSON
        let outcome = try apply(f,op,chunk)
        XCTAssertEqual((outcome["chunk"] as! JSON)["state"] as? String,"failed")
        XCTAssertEqual(try f.rows("media_owner_decision").count,1)
        XCTAssertEqual((row(try f.get(r),itemID)["decision"] as! JSON)["id"] as? String,latest["id"] as? String)
    }
    func testUnchangedPassSurvivesSiblingSuccessorAndHistoryCannotBeOverwritten() throws {
        let (f,r) = try setup(),ids = (r["items"] as! [JSON]).map {$0["id"] as! String}
        _ = try f.call("media_decide",params(f,r,ids:[ids[0]]))
        _ = try f.call("media_decide",params(f,try f.get(r),ids:[ids[1]],disposition:"changes_requested"))
        let pass = row(try f.get(r),ids[0])["decision"] as! JSON
        var sibling = row(try f.get(r),ids[1])
        _ = try f.call("media_item_update",["item_id":ids[1],"expected_revision":sibling["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Successor work"]]]]])
        let next = try f.publish(r)
        XCTAssertEqual(row(next,ids[0])["disposition"] as? String,"accepted")
        XCTAssertEqual((row(next,ids[0])["decision"] as! JSON)["id"] as? String,pass["id"] as? String)
        XCTAssertEqual(row(next,ids[1])["disposition"] as? String,"stale")
        sibling = row(next,ids[1]);_ = try f.call("media_decide",params(f,next,ids:[sibling["id"] as! String]))
        XCTAssertEqual(row(try f.get(r),ids[0])["disposition"] as? String,"accepted")
        try f.router.dbQueue.write { db in
            var changed = pass;changed["note"] = "Overwrite forbidden"
            XCTAssertThrowsError(try f.router.mediaWrite(db,changed,type:"media_owner_decision"))
        }
        XCTAssertEqual(try jsonString(f.record(pass["id"] as! String,"media_owner_decision")),try jsonString(pass))
        XCTAssertTrue(try f.rows("review_verdict").isEmpty)
    }
    func testBulkPreparationFenceAndLateReceiptFailureRollBackWholeChunk() throws {
        let (f,r) = try setup(),op = try f.call("media_bulk_prepare",params(f,r)),chunk = (op["chunks"] as! [JSON])[0]
        let input: JSON = ["project_id":f.project,"command_id":chunk["command_id"]!,"operation_id":op["id"]!,"chunk_id":chunk["id"]!]
        let prepared = try XCTUnwrap(f.router.prepareMediaCommand(method:"media_bulk_apply",params:input,caller:f.owner))
        defer {try? prepared.observer.close()}
        // Intervening commit to a media record the command read (its bulk operation): the
        // prepared result is never written. CL-307 (V43A): an unrelated write no longer fences;
        // MediaPreparationScaleTests covers that case.
        let opKey = Data((op["id"] as! String).utf8)
        let opData = try f.router.dbQueue.read { try XCTUnwrap(try Data.fetchOne($0,sql:"SELECT CAST(data AS BLOB) FROM records WHERE id=CAST(? AS TEXT)",arguments:[opKey])) }
        try f.router.dbQueue.write { db in
            try db.execute(sql:"UPDATE records SET data=json_set(data,'$.fixture_intervening_commit',json('true')) WHERE id=CAST(? AS TEXT)",arguments:[opKey])
        }
        let beforeFence = try f.allState()
        try f.router.dbQueue.write { db in checks.checkError("MEDIA_CONTEXT_CHANGED") {try prepared.commit(db)} }
        XCTAssertEqual(try f.allState(),beforeFence)
        try f.router.dbQueue.write { try $0.execute(sql:"UPDATE records SET data=CAST(? AS TEXT) WHERE id=CAST(? AS TEXT)",arguments:[opData,opKey]) }
        try f.router.dbQueue.write { db in
            try db.execute(sql:"CREATE TRIGGER cl114_fail_receipt BEFORE INSERT ON commands WHEN NEW.command_id='" + (chunk["command_id"] as! String) + "' BEGIN SELECT RAISE(ABORT,'fixture receipt failure'); END")
        }
        let beforeReceipt = try f.allState()
        XCTAssertThrowsError(try apply(f,op,chunk))
        XCTAssertEqual(try f.allState(),beforeReceipt)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty);XCTAssertTrue(try f.rows("media_bulk_chunk").isEmpty)
        XCTAssertEqual(strings(try bulkGet(f,op),"uncommitted_item_ids").count,2)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER cl114_fail_receipt")}
        _ = try apply(f,op,chunk)
        XCTAssertEqual(try f.rows("media_owner_decision").count,2)
    }
    func testBulkRecordsExportBackupImmutabilityAndPublicGate() throws {
        let (f,r) = try setup(2),op = try f.call("media_bulk_prepare",params(f,r)),chunk = (op["chunks"] as! [JSON])[0]
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_bulk_prepare",params(f,try f.get(r,as:f.worker)),as:f.worker)}
        checks.checkError("HUMAN_CHANNEL_REQUIRED") {try f.call("media_bulk_apply",["operation_id":op["id"]!,"chunk_id":chunk["id"]!],as:f.worker,command:chunk["command_id"] as? String)}
        _ = try apply(f,op,chunk)
        // Capture a real failed receipt as well as committed records.
        let another = try f.call("media_bulk_prepare",params(f,try f.get(r))),otherChunk = (another["chunks"] as! [JSON])[0]
        _ = try f.call("media_decide",params(f,try f.get(r),ids:[strings(another,"selected_item_ids")[0]],disposition:"needs_look"))
        XCTAssertEqual((try apply(f,another,otherChunk)["chunk"] as! JSON)["state"] as? String,"failed")
        let export = f.base.appendingPathComponent("export"),backup = f.base.appendingPathComponent("backup")
        _ = try f.router.handle(method:"export_project",params:["project_id":f.project,"command_id":uuid(),"path":export.path],caller:f.owner)
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:backup.appendingPathComponent("database.sqlite").path,configuration:config);defer {try? copy.close()}
        let copied = try copy.read {try MediaRecordRegistry.envelopes($0)}
        for family in ["media_bulk_operation","media_bulk_chunk","media_owner_decision"] {
            let records = try f.rows(family);XCTAssertFalse(records.isEmpty)
            for record in records {
                XCTAssertEqual(try jsonString((json[family] as! [JSON]).first {$0["id"] as? String == record["id"] as? String}!),try jsonString(record))
                XCTAssertEqual(try jsonString(copied.first {$0.id == record["id"] as? String}!.object),try jsonString(record))
                try f.router.dbQueue.write { db in
                    var changed = record;changed["note"] = "Cannot alter original intent or receipt"
                    XCTAssertThrowsError(try f.router.mediaWrite(db,changed,type:family))
                }
            }
        }
        // CL-349: the trusted owner channel only; agents have no route and no catalog entry.
        for method in ["media_bulk_prepare","media_bulk_get","media_bulk_apply"] {
            checks.checkError("FORBIDDEN") {try f.router.handle(method:method,params:["command_id":uuid(),"project_id":f.project],caller:f.worker)}
        }
        let catalog = try f.router.handle(method:"tool_catalog",params:[:],caller:f.worker)
        XCTAssertFalse(try jsonString(catalog).contains("media_bulk_"))
    }
}
