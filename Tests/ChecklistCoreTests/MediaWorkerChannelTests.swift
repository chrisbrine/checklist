import XCTest
import Foundation
import GRDB
import ChecklistContracts
@testable import ChecklistCore

/// Public worker routes over the owned template fixture. Owner publication and
/// decisions below are fixture actions, never claims of native authentication.
final class MediaWorkerChannelTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let intakeChecks = MediaFrozenIntakeTests()

    func worker(_ f: Fixture,_ method: String,_ input: JSON = [:],as caller: Caller? = nil,command: String? = nil) throws -> JSON {
        var p = input;p["project_id"] = p["project_id"] ?? f.project
        if !MediaWorkerContract.readMethods.contains(method) {p["command_id"] = command ?? uuid()}
        let reply = try f.router.handle(method:method,params:p,caller:caller ?? f.worker)
        if !MediaWorkerContract.readMethods.contains(method) {XCTAssertEqual(reply["command_id"] as? String,p["command_id"] as? String)}
        return try XCTUnwrap(reply["data"] as? JSON)
    }
    func round(_ f: Fixture,_ type: JSON) throws -> JSON {
        try worker(f,"media_round_create",["type_id":type["id"]!,"title":"Worker animation round"])
    }
    func get(_ f: Fixture,_ round: JSON,limit: Int = 100,cursor: String? = nil) throws -> JSON {
        var p: JSON = ["round_id":round["id"]!,"limit":limit];p["cursor"] = cursor
        return try worker(f,"media_round_get",p)
    }
    func confirm(_ f: Fixture,_ intake: JSON) throws -> JSON {
        let plan = intake["plan"] as! JSON
        return try worker(f,"media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":plan["id"]!,"plan_digest":plan["digest"]!])
    }
    func capture(_ f: Fixture,_ intake: JSON) throws -> JSON {
        try worker(f,"media_intake_capture",intakeChecks.captureParams(intake))
    }
    func decisions(_ f: Fixture,_ round: JSON,limit: Int = 100,cursor: String? = nil,as caller: Caller? = nil) throws -> JSON {
        var p: JSON = ["round_id":round["id"]!,"limit":limit];p["cursor"] = cursor
        return try worker(f,"media_decision_list",p,as:caller)
    }
    func suggestion(_ view: JSON,_ item: JSON,disposition: String = "accepted") -> JSON {
        let manifest = view["manifest"] as! JSON
        var p: JSON = ["round_id":view["id"]!,"expected_revision":view["revision"]!,"observed_context_token":view["observed_context_token"]!,
            "manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,"disposition":disposition,
            "items":[["item_id":item["id"]!,"expected_revision":item["expected_revision"]!,"target_id":item["target_id"]!,"review_basis_signature":item["review_basis_signature"]!]]]
        if disposition == "accepted" {p["winner_id"] = strings(item,"candidate_ids")[0]}
        return p
    }
    func secondWorker(_ f: Fixture) throws -> Caller {
        let id = uuid()
        let session = try f.router.handle(method:"session_register",params:["command_id":uuid(),"project_id":f.project,"provider":"codex","label":"Other fixture worker","session_id":id,"workspace":f.workspace.path],caller:f.owner)["data"] as! JSON
        return Caller(role:"worker",installation:"other-media-worker",projectIDs:[f.project],sessionID:session["id"] as? String,workspace:f.workspace.path)
    }
    func assertSafeDecision(_ decision: JSON,file: StaticString = #filePath,line: UInt = #line) {
        for key in ["author","author_session_id","origin","record_references","context_id","context_signature","review_basis_base64","material_definition_signature","type_revision_id","manifest_id","manifest_digest","no_follow_up_reason"] {
            XCTAssertNil(decision[key],key,file:file,line:line)
        }
        XCTAssertNotNil(decision["decision_id"],file:file,line:line)
        XCTAssertNotNil(decision["decided_at"],file:file,line:line)
    }

    func testWorkerCreatesAdoptedDraftAndCapturesThreeManagedImagesWithTypeMetadata() throws {
        let f = try Fixture()
        var schema = intakeChecks.imageSchema()
        schema["fields"] = [checks.field("character",required:true),checks.field("animation_label",required:true),
            ["id":"direction","kind":"choice","required":true,"material":true,"choices":["N","NE","E"]]]
        let type = try f.type(schema),created = try round(f,type)
        XCTAssertEqual(created["state"] as? String,"draft")
        XCTAssertEqual(created["origin"] as? String,"agent")
        XCTAssertEqual(created["author_session_id"] as? String,f.worker.sessionID)
        let publicType = try worker(f,"media_type_get",["type_id":type["id"]!])
        XCTAssertNil(publicType["observed_type_token"]);XCTAssertNil(publicType["adoptions"])
        XCTAssertFalse(try jsonString(publicType).contains("record_references"))
        let listed = try worker(f,"media_type_list")["types"] as! [JSON]
        XCTAssertEqual(listed.count,1);XCTAssertEqual(try jsonString(listed[0]),try jsonString(publicType))
        var sources: [JSON] = []
        let directions = ["N","NE","E"]
        for index in directions.indices {
            var source = try intakeChecks.source(f,"take-\(index).png",index)
            source["columns"] = ["character":"hero","animation":"walk","facing":directions[index]]
            sources.append(source)
        }
        let mapping: JSON = ["input":"selected_files","assignments":[
            ["field_id":"character","source":["kind":"column","column_id":"character"]],
            ["field_id":"animation_label","source":["kind":"column","column_id":"animation"]],
            ["field_id":"direction","source":["kind":"column","column_id":"facing"]]]]
        var intake = try worker(f,"media_intake_preview",["round_id":created["id"]!,"sources":sources,"mapping":mapping])
        let preview = intake["rows"] as! [JSON]
        XCTAssertEqual(preview.count,3)
        XCTAssertTrue(preview.allSatisfy {$0["status"] as? String == "valid"})
        intake = try worker(f,"media_intake_revise",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,
            "resolutions":preview.map {["row_id":$0["id"]!,"disposition":"include"]}])
        intake = try capture(f,confirm(f,intake))
        XCTAssertEqual(strings(intake,"committed_row_ids").count,3)
        XCTAssertTrue(strings(intake,"remaining_row_ids").isEmpty)
        XCTAssertEqual((try worker(f,"media_intake_get",["intake_id":intake["id"]!]))["id"] as? String,intake["id"] as? String)
        let view = try get(f,created),items = view["items"] as! [JSON]
        XCTAssertEqual(items.count,3);XCTAssertEqual(try jsonString(items),try jsonString(view["rows"] as! [JSON]))
        XCTAssertEqual(Set(items.compactMap {($0["metadata"] as? JSON)?["direction"] as? String}),Set(directions))
        for item in items {
            let metadata = item["metadata"] as! JSON
            XCTAssertEqual(metadata["character"] as? String,"hero");XCTAssertEqual(metadata["animation_label"] as? String,"walk")
            XCTAssertNotNil(item["target_id"]);XCTAssertEqual(strings(item,"candidate_ids").count,1)
            XCTAssertEqual(item["disposition"] as? String,"pending");XCTAssertNil(item["decision"])
        }
        for family in ["media_round","media_intake","media_intake_plan","media_intake_row","media_intake_chunk","media_item","media_item_target","media_candidate"] {
            let records = try f.rows(family);XCTAssertFalse(records.isEmpty,family)
            for record in records {
                XCTAssertEqual(record["origin"] as? String,"agent",family)
                XCTAssertEqual(record["author"] as? String,f.worker.principal,family)
                XCTAssertEqual(record["author_session_id"] as? String,f.worker.sessionID,family)
            }
        }
        let attachments = try f.rows("attachment")
        XCTAssertEqual(attachments.count,3)
        for attachment in attachments {
            let path = attachment["path"] as! String
            XCTAssertTrue(path.hasPrefix("objects/"))
            let bytes = try Data(contentsOf:f.router.managedURL(path,family:"objects"))
            XCTAssertEqual(ChecklistCore.hash(bytes),attachment["sha256"] as? String)
            XCTAssertEqual(bytes.count,int(attachment,"size"))
            XCTAssertTrue(sources.contains {source in (try? Data(contentsOf:URL(fileURLWithPath:source["path"] as! String))) == bytes})
        }
        XCTAssertTrue(try f.rows("media_round_manifest").isEmpty)
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        try f.router.dbQueue.read {try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes($0,project:f.project))}
    }

    func testWorkerPreparedRoundNeedsOnlyOwnerPublicationAndThenPagesForReview() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),created = try round(f,type)
        var intake = try worker(f,"media_intake_preview",["round_id":created["id"]!,"text":"take one\ntake two\ntake three"])
        intake = try capture(f,confirm(f,intake))
        XCTAssertEqual(strings(intake,"committed_row_ids").count,3)
        let ownerBefore = try f.router.handle(method:"media_round_page",params:["project_id":f.project,"type_id":type["id"]!,"state":"draft"],caller:f.owner)["data"] as! JSON
        XCTAssertTrue((ownerBefore["rows"] as! [JSON]).contains {$0["id"] as? String == created["id"] as? String})
        let preview = try f.router.handle(method:"media_publication_preview",params:["project_id":f.project,"round_id":created["id"]!],caller:f.owner)["data"] as! JSON
        var p = f.observation(preview["round"] as! JSON)
        p["project_id"] = f.project;p["command_id"] = uuid()
        p["items"] = (preview["items"] as! [JSON]).map {row in row.filter {["item_id","expected_revision","target_id","review_basis_signature"].contains($0.key)}}
        let published = try f.router.handle(method:"media_round_publish",params:p,caller:f.owner)["data"] as! JSON
        XCTAssertEqual(published["state"] as? String,"open")
        let page = try get(f,created,limit:2),first = page["items"] as! [JSON]
        XCTAssertEqual(first.count,2);XCTAssertEqual(page["has_more"] as? Bool,true)
        let next = try get(f,created,limit:2,cursor:page["next_cursor"] as? String)
        let second = next["items"] as! [JSON]
        XCTAssertEqual(second.count,1);XCTAssertEqual(next["has_more"] as? Bool,false)
        XCTAssertEqual(Set((first + second).compactMap {$0["id"] as? String}).count,3)
        for item in first + second {
            let detail = try f.router.handle(method:"media_item_get",params:["project_id":f.project,"round_id":created["id"]!,"item_id":item["id"]!],caller:f.owner)["data"] as! JSON
            XCTAssertEqual(detail["published"] as? Bool,true);XCTAssertFalse((detail["candidates"] as! [JSON]).isEmpty)
        }
    }

    func testPreparedIntakeReceiptsReplayAfterOwnerPublicationWithoutSourceAccess() throws {
        let f = try Fixture(),created = try round(f,f.type(intakeChecks.imageSchema()))
        let source = try intakeChecks.source(f,"replay.png",1)
        let previewInput: JSON = ["round_id":created["id"]!,"sources":[source]]
        let previewCommand = uuid(),captureCommand = uuid()
        let preview = try worker(f,"media_intake_preview",previewInput,command:previewCommand)
        let confirmed = try confirm(f,preview),captureInput = intakeChecks.captureParams(confirmed)
        let captured = try worker(f,"media_intake_capture",captureInput,command:captureCommand)
        _ = try f.publish(created)
        try FileManager.default.removeItem(at:URL(fileURLWithPath:source["path"] as! String))
        let before = try f.allState()
        for (method,input,command,original) in [("media_intake_preview",previewInput,previewCommand,preview),
            ("media_intake_capture",captureInput,captureCommand,captured)] {
            let replay = try worker(f,method,input,command:command)
            XCTAssertEqual(replay["replayed"] as? Bool,true)
            var semantic = replay;semantic.removeValue(forKey:"replayed")
            XCTAssertEqual(try jsonString(semantic),try jsonString(original))
        }
        XCTAssertEqual(try f.allState(),before)
        checks.checkError("MEDIA_ROUND_NOT_DRAFT") {try worker(f,"media_intake_preview",previewInput)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testWorkerAuthorityRefusalsHaveNoCanonicalWrites() throws {
        let f = try Fixture(),unadopted = try f.type(checks.schema(),adopt:false,as:f.worker)
        var before = try f.allState()
        checks.checkError("MEDIA_TYPE_NOT_ADOPTED") {try round(f,unadopted)}
        XCTAssertEqual(try f.allState(),before)
        let type = try f.adoptType(unadopted),created = try round(f,type)
        let denied = Caller(role:"worker",installation:f.worker.installation,projectIDs:[],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        before = try f.allState()
        checks.checkError("FORBIDDEN") {try worker(f,"media_round_create",["type_id":type["id"]!,"title":"Outside grant"],as:denied)}
        checks.checkError("FORBIDDEN") {try worker(f,"media_round_get",["round_id":created["id"]!],as:denied)}
        for method in ["media_round_publish","media_decide","media_type_adopt","media_context_approve","media_context_reconcile"] {
            checks.checkError("FORBIDDEN") {try worker(f,method,["round_id":created["id"]!])}
        }
        for key in ["origin","author","author_session_id"] {
            var p: JSON = ["type_id":type["id"]!,"title":"Forged owner"];p[key] = "human_ui"
            checks.checkError("INVALID_INPUT") {try worker(f,"media_round_create",p)}
        }
        XCTAssertEqual(try f.allState(),before)
        XCTAssertTrue(try f.rows("media_round_manifest").isEmpty);XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
    }

    func testWorkerCannotReadOrCaptureAnotherIntakeOrFileOutsideWorkspace() throws {
        let f = try Fixture(),type = try f.type(intakeChecks.imageSchema()),created = try round(f,type)
        let other = try secondWorker(f),source = try intakeChecks.source(f,"inside.png",1)
        let intake = try worker(f,"media_intake_preview",["round_id":created["id"]!,"sources":[source]])
        let before = try f.allState()
        checks.checkError("FORBIDDEN") {try worker(f,"media_intake_get",["intake_id":intake["id"]!],as:other)}
        checks.checkError("FORBIDDEN") {try worker(f,"media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":(intake["plan"] as! JSON)["id"]!,"plan_digest":(intake["plan"] as! JSON)["digest"]!],as:other)}
        XCTAssertEqual(try f.allState(),before)
        let outside = f.base.appendingPathComponent("outside.png")
        try intakeChecks.png.write(to:outside)
        let refused = try worker(f,"media_intake_preview",["round_id":created["id"]!,"sources":[["path":outside.path]]])
        let row = (refused["rows"] as! [JSON])[0]
        XCTAssertEqual(row["status"] as? String,"missing");XCTAssertEqual(row["error_code"] as? String,"FILE_ACCESS_REQUIRED")
        XCTAssertNil(row["sha256"]);XCTAssertTrue(try f.rows("attachment").isEmpty)
        checks.checkError("MEDIA_MAPPING_REQUIRED") {try confirm(f,refused)}
        let publishedRound = try round(f,f.type(checks.schema()))
        _ = try f.item(publishedRound,as:f.worker);_ = try f.publish(publishedRound)
        let afterPublish = try f.allState()
        checks.checkError("MEDIA_ROUND_NOT_DRAFT") {try worker(f,"media_intake_preview",["round_id":publishedRound["id"]!,"sources":[source]])}
        XCTAssertEqual(try f.allState(),afterPublish)
    }

    func testSuggestionAppearsInOwnerItemWithoutChangingOwnerDecisionHead() throws {
        let f = try Fixture(),created = try round(f,f.type(checks.schema()))
        _ = try f.item(created,texts:["take one","take two"],as:f.worker);_ = try f.publish(created)
        let view = try get(f,created),item = (view["items"] as! [JSON])[0]
        var p = suggestion(view,item);p["note"] = "Prefer this take for the held ending."
        let saved = (try worker(f,"media_suggest",p)["decisions"] as! [JSON])[0]
        XCTAssertEqual(saved["origin"] as? String,"agent");XCTAssertEqual(saved["author_session_id"] as? String,f.worker.sessionID)
        XCTAssertEqual(saved["author"] as? String,f.worker.principal)
        XCTAssertNil((try f.record(item["id"] as! String,"media_item"))["last_decision_id"])
        XCTAssertTrue(try f.rows("media_owner_decision").isEmpty)
        XCTAssertTrue((try decisions(f,created)["rows"] as! [JSON]).isEmpty)
        let detail = try f.router.handle(method:"media_item_get",params:["project_id":f.project,"round_id":created["id"]!,"item_id":item["id"]!],caller:f.owner)["data"] as! JSON
        let suggestions = detail["suggestions"] as! [JSON]
        XCTAssertEqual(suggestions.count,1);XCTAssertEqual(suggestions[0]["id"] as? String,saved["id"] as? String)
        XCTAssertEqual(suggestions[0]["note"] as? String,p["note"] as? String)
        XCTAssertFalse((suggestions[0]["source_label"] as? String ?? "").isEmpty)
        XCTAssertEqual(detail["disposition"] as? String,"pending");XCTAssertNil(detail["decision"])
        let before = try f.allState()
        checks.checkError("FORBIDDEN") {try worker(f,"media_decide",p)}
        XCTAssertEqual(try f.allState(),before)
        let refreshed = try get(f,created),refreshedItem = (refreshed["items"] as! [JSON])[0]
        XCTAssertEqual(refreshedItem["revision"] as? Int,item["revision"] as? Int)
        XCTAssertEqual(refreshedItem["disposition"] as? String,"pending")
    }

    func testDecisionCursorPagesExactOwnerResultsAndRetainsEndForLaterReversal() throws {
        let f = try Fixture(),created = try round(f,f.type(checks.schema()))
        for title in ["A","B","C"] {_ = try f.item(created,title:title,texts:["one","two"],as:f.worker)}
        _ = try f.publish(created)
        let initial = try get(f,created)
        XCTAssertTrue((initial["items"] as! [JSON]).allSatisfy {$0["disposition"] as? String == "pending"})
        let empty = try decisions(f,created,limit:1)
        XCTAssertTrue((empty["rows"] as! [JSON]).isEmpty);XCTAssertEqual(empty["has_more"] as? Bool,false)
        let startingCursor = try XCTUnwrap(empty["next_cursor"] as? String)
        let ids = (initial["items"] as! [JSON]).map {$0["id"] as! String}
        var expected: [JSON] = []
        for (index,disposition) in ["accepted","changes_requested","needs_look"].enumerated() {
            var p = f.decisionParams(try f.get(created),ids:[ids[index]],disposition:disposition)
            p["note"] = "Owner decision \(index)"
            if disposition == "changes_requested" {p["none_fit"] = true}
            expected.append((try f.call("media_decide",p)["decisions"] as! [JSON])[0])
        }
        var cursor = startingCursor,observed: [JSON] = []
        for pageIndex in 0..<3 {
            let page = try decisions(f,created,limit:1,cursor:cursor),rows = page["rows"] as! [JSON]
            XCTAssertEqual(rows.count,1);XCTAssertEqual(page["has_more"] as? Bool,pageIndex < 2)
            observed += rows;cursor = try XCTUnwrap(page["next_cursor"] as? String)
        }
        XCTAssertEqual(observed.compactMap {$0["decision_id"] as? String},expected.compactMap {$0["id"] as? String})
        for (actual,owner) in zip(observed,expected) {
            for key in ["item_id","target_id","disposition","winner_id","note","none_fit"] {
                XCTAssertEqual(try jsonString(["value":actual[key] ?? NSNull()]),try jsonString(["value":owner[key] ?? NSNull()]),key)
            }
            XCTAssertEqual(actual["decided_at"] as? String,owner["created_at"] as? String)
            assertSafeDecision(actual)
        }
        let end = try decisions(f,created,limit:1,cursor:cursor)
        XCTAssertTrue((end["rows"] as! [JSON]).isEmpty)
        let retainedEnd = try XCTUnwrap(end["next_cursor"] as? String)
        var reversalInput = f.decisionParams(try f.get(created),ids:[ids[0]],disposition:"excluded")
        reversalInput["note"] = "Owner reversed the choice"
        let reversed = (try f.call("media_decide",reversalInput)["decisions"] as! [JSON])[0]
        let appended = try decisions(f,created,limit:1,cursor:retainedEnd),reversal = (appended["rows"] as! [JSON])[0]
        XCTAssertEqual(reversal["decision_id"] as? String,reversed["id"] as? String)
        XCTAssertEqual(reversal["disposition"] as? String,"excluded");XCTAssertEqual(reversal["note"] as? String,"Owner reversed the choice")
        let current = try get(f,created),row = (current["items"] as! [JSON]).first {$0["id"] as? String == ids[0]}!
        XCTAssertEqual(row["disposition"] as? String,"excluded")
        XCTAssertEqual((row["decision"] as? JSON)?["decision_id"] as? String,reversed["id"] as? String)
        XCTAssertFalse(try jsonString(current).contains("record_references"))
        for key in ["context","context_sources","attention_sources","type_revision","review_basis_base64"] {XCTAssertNil(current[key],key)}
    }

    func testDecisionCursorRejectsTamperForeignScopeCallerAndGrantGeneration() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),created = try round(f,type)
        let page = try decisions(f,created,limit:1),cursor = try XCTUnwrap(page["next_cursor"] as? String)
        let otherRound = try round(f,type),other = try secondWorker(f)
        checks.checkError("CURSOR_RESET") {try decisions(f,otherRound,limit:1,cursor:cursor)}
        checks.checkError("CURSOR_RESET") {try decisions(f,created,limit:1,cursor:cursor,as:other)}
        let offset = cursor.index(cursor.startIndex,offsetBy:cursor.count / 2)
        var tampered = cursor;tampered.replaceSubrange(offset...offset,with:cursor[offset] == "A" ? "B" : "A")
        checks.checkError("CURSOR_RESET") {try decisions(f,created,limit:1,cursor:tampered)}
        let denied = Caller(role:"worker",installation:f.worker.installation,projectIDs:[],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        checks.checkError("FORBIDDEN") {try decisions(f,created,limit:1,cursor:cursor,as:denied)}
        let foreignWorkspace = f.base.appendingPathComponent("foreign-workspace")
        try FileManager.default.createDirectory(at:foreignWorkspace,withIntermediateDirectories:true)
        let foreign = try f.router.handle(method:"project_create",params:["command_id":uuid(),"name":"Foreign media fixture","key_prefix":"FOREIGN","root_path":foreignWorkspace.path],caller:f.owner)["data"] as! JSON
        checks.checkError("FORBIDDEN") {try worker(f,"media_decision_list",["project_id":foreign["id"]!,"round_id":created["id"]!,"cursor":cursor])}
        try f.router.dbQueue.write {db in
            var session = try f.router.record(db,f.worker.sessionID!,type:"session")
            session["authorization_generation"] = uuid();try f.router.save(db,f.router.revised(session),type:"session")
        }
        checks.checkError("CURSOR_RESET") {try decisions(f,created,limit:1,cursor:cursor)}
        let fresh = try decisions(f,created,limit:1)
        XCTAssertTrue((fresh["rows"] as! [JSON]).isEmpty)
        try f.router.dbQueue.write {db in
            var session = try f.router.record(db,f.worker.sessionID!,type:"session")
            session["state"] = "revoked";try f.router.save(db,f.router.revised(session),type:"session")
        }
        checks.checkError("RECIPIENT_CHANGED") {try decisions(f,created,limit:1,cursor:fresh["next_cursor"] as? String)}
    }

    func testWorkerRoundReadOmitsOwnerIdentityAndPrivateContextBodies() throws {
        let f = try Fixture(),type = try f.type(checks.schema()),created = try f.round(type)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":created["id"]!,"body":"PRIVATE_OWNER_CONTEXT_BODY"])
        _ = try f.reconcile(created)
        _ = try f.item(created);_ = try f.publish(created)
        let view = try get(f,created),encoded = try jsonString(view)
        XCTAssertEqual(view["origin"] as? String,"human_ui")
        for key in ["author","author_session_id","context","context_sources","attention_sources","record_references","type_revision"] {XCTAssertNil(view[key],key)}
        XCTAssertFalse(encoded.contains("PRIVATE_OWNER_CONTEXT_BODY"))
        XCTAssertFalse(encoded.contains(f.owner.principal))
        XCTAssertFalse(encoded.contains("record_references"))
    }
}
