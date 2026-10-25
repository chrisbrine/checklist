import ChecklistTestSupport
import XCTest
import Foundation
import CoreFoundation
import GRDB
@testable import ChecklistCore

final class MediaListQueryTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()
    let decisions = MediaDecisionTests()
    func schema() -> JSON {
        checks.schema(fields:[checks.field("character"),checks.field("animation_label"),
            ["id":"direction","kind":"choice","choices":["N","NE","E","S"]],checks.field("number",kind:"number"),checks.field("flag",kind:"boolean")])
    }
    var list: JSON {["visible_columns":["character","animation_label","direction"],"group_by":["character","animation_label"],"sort":[["field_id":"direction","order":"declared_choice_order"]]]}
    func page(_ f: Fixture,_ round: JSON,list: JSON? = nil,filter: JSON? = nil,cursor: String? = nil,limit: Int = 100,as caller: Caller? = nil) throws -> JSON {
        var p: JSON = ["round_id":round["id"]!,"list":list ?? self.list,"limit":limit];p["cursor"] = cursor;p["filter"] = filter
        return try f.call("media_item_page",p,as:caller)
    }
    func show(_ f: Fixture,_ round: JSON,_ item: JSON,expanded: Bool = true,size: Int = 8,targets: [String]? = nil,cursor: String? = nil,as caller: Caller? = nil) throws -> JSON {
        var options: JSON = ["enabled":true,"page_size":size];options["target_ids"] = targets
        var p: JSON = ["round_id":round["id"]!,"item_id":item["id"]!,"expanded":expanded,"examples":options];p["cursor"] = cursor
        return try f.call("media_approved_examples",p,as:caller)
    }
    func seed(_ f: Fixture,_ round: JSON,count: Int,ids: [String]? = nil) throws {
        try f.router.dbQueue.write {db in
            let (type,context) = try f.router.mediaRoundParts(db,round)
            for index in 0..<count {
                let id = ids?[index] ?? String(format:"item-%04d",index)
                var item = f.router.mediaRecord(["round_id":round["id"]!,"title":"Item \(index)","state":"draft","order":index],project:f.project,caller:f.worker,references:[f.router.mediaRef("media_round",round)])
                item["id"] = id
                // Canonical owned fixture; the deliberately unreadable candidate below makes
                // decoding any candidate/original in the query an observable test failure.
                let shape = try f.router.mediaTargetShape(db,item:item,title:"Item \(index)",metadata:["character":index < count/2 ? "hero":"villain","animation_label":"walk","direction":["E","N","NE"][index%3],"number":index,"flag":index%2 == 0],candidates:[],typeRevision:type,context:context)
                let target = try f.router.mediaTarget(db,item:item,shape:shape,caller:f.worker)
                item["draft_target_id"] = target["id"];item["record_references"] = (item["record_references"] as! [JSON]) + [f.router.mediaRef("media_item_target",target)]
                try f.router.mediaWrite(db,item,type:"media_item")
            }
        }
    }
    func testThousandItemBoundedGroupedPagesFreezeOrderAcrossInsertsAndUpdates() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(),type = try f.type(schema()),round = try f.round(type)
        // Leave room for one live insert after the first page.
        try seed(f,round,count:999)
        let first = try page(f,round),firstRows = first["rows"] as! [JSON]
        XCTAssertEqual(firstRows.count,100);XCTAssertEqual(first["total"] as? Int,999)
        XCTAssertEqual((firstRows[0]["metadata"] as! JSON)["direction"] as? String,"N")
        let oldCursor = try XCTUnwrap(first["next_cursor"] as? String)
        let laterID = "item-0900",item = try f.record(laterID,"media_item")
        _ = try f.call("media_item_update",["item_id":laterID,"expected_revision":item["revision"]!,"title":"New live title","metadata":["character":"aaa","animation_label":"idle","direction":"S"]])
        _ = try f.item(round,title:"New live insert",metadata:["character":"aaa","animation_label":"idle","direction":"N"])
        var rows = firstRows,cursor: String? = oldCursor
        while let next = cursor {
            let response = try page(f,round,cursor:next),part = response["rows"] as! [JSON]
            XCTAssertLessThanOrEqual(part.count,100);XCTAssertEqual(response["total"] as? Int,999)
            rows += part;cursor = response["next_cursor"] as? String
        }
        XCTAssertEqual(rows.count,999);XCTAssertEqual(Set(rows.map {$0["id"] as! String}).count,999)
        XCTAssertEqual(rows.first {$0["id"] as? String == laterID}?["title"] as? String,"Item 900")
        let expected = try f.router.dbQueue.read {db -> [String] in
            let revision = try f.router.scoped(db,round["type_revision_id"] as! String,f.project,type:"media_review_type_revision")
            let schema = try MediaReviewSchema.parse(revision["schema"] as! JSON),config = try MediaListConfiguration.parse(list,schema:schema)
            let items = try rows.map {row -> MediaListItem in
                let target = try f.router.scoped(db,row["target_id"] as! String,f.project,type:"media_item_target")
                let metadata = try (target["metadata"] as! JSON).reduce(into:[MediaReviewID:MediaMetadataValue]()) {result,entry in
                    let id = try MediaReviewID(entry.key);result[id] = try schema.validateValue(entry.value,fieldID:id)
                }
                return .init(id:try MediaReviewID(row["id"] as! String),title:target["title"] as! String,order:row["order"] as! Int,metadata:metadata)
            }
            return try config.project(items,schema:schema).compactMap {if case .item(let item) = $0 {return item.id.rawValue};return nil}
        }
        XCTAssertEqual(rows.map {$0["id"] as! String},expected)
        XCTAssertEqual((try page(f,round))["total"] as? Int,1000)
        XCTAssertThrowsError(try page(f,round,limit:101))
        let group = firstRows[0]["group_path"] as! [JSON]
        XCTAssertEqual(group.map {$0["item_count"] as! Int},[499,499])
        try f.router.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('unreadable-original',?,'media_candidate',1,?)",arguments:[f.project,"{invalid original payload " + String(repeating:"x",count:256*1024)])
        }
        let counts = try f.call("media_item_counts",["round_id":round["id"]!,"filter":["metadata":["flag":true,"number":2]]])
        XCTAssertEqual(counts["total"] as? Int,1);XCTAssertNil(counts["rows"])
        XCTAssertFalse(try jsonString(first).contains("invalid original"));XCTAssertFalse(try jsonString(firstRows).contains("candidate_ids"))
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:firstRows).count,100_000)
    }
    func testByteExactIDsGroupingMissingAndDescendingAndScopedCursors() throws {
        let f = try Fixture(),type = try f.type(schema()),round = try f.round(type)
        try seed(f,round,count:5,ids:["é","e\u{301}","a","b","missing"])
        try f.router.dbQueue.write {db in
            for (id,metadata) in [("é",["character":"e\u{301}","animation_label":"idle","direction":"N"]),("e\u{301}",["character":"e\u{301}","animation_label":"idle","direction":"N"]),("a",["character":"é","animation_label":"idle","direction":"N"]),("b",["character":"e\u{301}","animation_label":"idle","direction":"E"]),("missing",[:])] {
                let item = try f.router.record(db,id,type:"media_item")
                // Replace the mutable head with a fresh immutable target, using normal domain input.
                _ = try f.router.mediaCommand(db,method:"media_item_update",p:["item_id":id,"expected_revision":item["revision"]!,"metadata":metadata],c:f.worker,project:f.project)
            }
        }
        let first = try page(f,round,limit:1),cursor = first["next_cursor"] as! String
        var ids = (first["rows"] as! [JSON]).map {$0["id"] as! String},next: String? = cursor
        while let value = next {let r = try page(f,round,cursor:value,limit:1);ids += (r["rows"] as! [JSON]).map {$0["id"] as! String};next = r["next_cursor"] as? String}
        XCTAssertEqual(ids.map {Data($0.utf8)},["e\u{301}","é","b","a","missing"].map {Data($0.utf8)})
        let descending: JSON = ["sort":[["field_id":"direction","order":"descending"]]]
        XCTAssertEqual(((try page(f,round,list:descending))["rows"] as! [JSON]).last?["id"] as? String,"missing")
        checks.checkError("CURSOR_RESET") {try page(f,round,list:descending,cursor:cursor,limit:1)}
        checks.checkError("CURSOR_RESET") {try page(f,round,cursor:cursor + "x",limit:1)}
        checks.checkError("CURSOR_RESET") {try page(f,round,cursor:cursor,limit:1,as:f.worker)}
        let workerFirst = try page(f,round,limit:1,as:f.worker),workerCursor = workerFirst["next_cursor"] as! String
        try f.router.dbQueue.write {db in var session = try f.router.record(db,f.worker.sessionID!,type:"session");session["authorization_generation"] = uuid();try f.router.save(db,f.router.revised(session),type:"session")}
        checks.checkError("CURSOR_RESET") {try page(f,round,cursor:workerCursor,limit:1,as:f.worker)}
        try f.router.closeStore();f.router = try TestStore.router(root:f.root,serviceLease:f.storage.lease);f.storage.router = f.router
        XCTAssertEqual(((try page(f,round,cursor:cursor,limit:1))["rows"] as! [JSON]).count,1)
        // Keep the key but change the logical incarnation passed to the production cursor
        // binding, equivalent to a restored store's authority fence.
        let principal = Caller(role:"owner",installation:"other-owner",projectIDs:[])
        checks.checkError("CURSOR_RESET") {try page(f,round,cursor:cursor,limit:1,as:principal)}
    }
    func acceptedHistory(_ count: Int = 10) throws -> (Fixture,JSON,JSON,JSON) {
        let (f,old) = try decisions.setup(count)
        _ = try f.call("media_decide",decisions.params(f,old))
        let type = try f.rows("media_review_type")[0],current = try f.round(type),item = try f.item(current)
        return (f,old,current,item)
    }
    func testExamplesStayCollapsedUntilShowThenCapPageAndNeverGrantApproval() throws {
        try QualificationSuite.requireEnabled()
        let (f,old,current,item) = try acceptedHistory(70)
        let before = try f.allState()
        let collapsed = try show(f,current,item,expanded:false)
        XCTAssertTrue((collapsed["examples"] as! [JSON]).isEmpty);XCTAssertTrue(collapsed["collapsed"] as! Bool)
        let defaultHidden = try f.call("media_approved_examples",["round_id":current["id"]!,"item_id":item["id"]!])
        XCTAssertTrue(defaultHidden["collapsed"] as! Bool)
        var response = try show(f,current,item),examples = response["examples"] as! [JSON]
        XCTAssertEqual(examples.count,8);XCTAssertEqual(response["capped"] as? Bool,true)
        while let cursor = response["next_cursor"] as? String {
            response = try show(f,current,item,cursor:cursor);let part = response["examples"] as! [JSON]
            XCTAssertLessThanOrEqual(part.count,8);examples += part
        }
        XCTAssertEqual(examples.count,64);XCTAssertEqual(Set(examples.map {$0["target_id"] as! String}).count,64)
        for example in examples {XCTAssertEqual(example["grants_current_approval"] as? Bool,false);XCTAssertTrue((example["historical_context_label"] as! String).contains("Historical"));XCTAssertEqual(example["round_id"] as? String,old["id"] as? String)}
        XCTAssertEqual(try f.allState(),before)
        var invalid: JSON = ["round_id":current["id"]!,"item_id":item["id"]!,"expanded":true,"examples":["enabled":true,"page_size":9]]
        XCTAssertThrowsError(try f.call("media_approved_examples",invalid));invalid["expanded"] = 1
        XCTAssertThrowsError(try f.call("media_approved_examples",invalid))
    }
    func testExamplesExcludeReversalsStaleBasisAndForeignIDAndDigestProbes() throws {
        let (f,old,current,item) = try acceptedHistory(3),oldRows = try f.get(old)["items"] as! [JSON]
        let targetIDs = oldRows.map {($0["published_target"] as! JSON)["id"] as! String}
        _ = try f.call("media_decide",decisions.params(f,try f.get(old),ids:[oldRows[0]["id"] as! String],disposition:"needs_look"))
        _ = try f.call("media_item_update",["item_id":oldRows[1]["id"]!,"expected_revision":oldRows[1]["revision"]!,"candidates":[["slots":[["slot_id":"text","text":"Changed basis"]]]]])
        _ = try f.publish(old)
        let shown = try show(f,current,item,targets:targetIDs)
        XCTAssertEqual((shown["examples"] as! [JSON]).map {$0["target_id"] as! String},[targetIDs[2]])
        let foreignRoot = f.base.appendingPathComponent("foreign-project");try FileManager.default.createDirectory(at:foreignRoot,withIntermediateDirectories:true)
        let foreignProject = (try f.router.handle(method:"project_create",params:["command_id":uuid(),"name":"Private examples","root_path":foreignRoot.path],caller:f.owner)["data"] as! JSON)["id"] as! String
        let otherType = try f.call("media_type_create",["project_id":foreignProject,"title":"Private type","schema":checks.schema()])
        _ = try f.call("media_type_adopt",["project_id":foreignProject,"type_id":otherType["id"]!,"type_revision_id":otherType["draft_revision_id"]!,"expected_revision":otherType["revision"]!,"observed_type_token":otherType["observed_type_token"]!])
        let otherRound = try f.call("media_round_create",["project_id":foreignProject,"type_id":otherType["id"]!,"title":"Private round"])
        let otherItem = try f.call("media_item_create",["project_id":foreignProject,"round_id":otherRound["id"]!,"title":"Private example","candidates":[["slots":[["slot_id":"text","text":"PRIVATE CONTENT"]]]]])
        var foreign = try f.call("media_round_get",["project_id":foreignProject,"round_id":otherRound["id"]!])
        var publication = f.observation(foreign);publication["project_id"] = foreignProject;publication["items"] = f.selection(foreign,publish:true)
        foreign = try f.call("media_round_publish",publication)
        var acceptance = decisions.params(f,foreign);acceptance["project_id"] = foreignProject
        _ = try f.call("media_decide",acceptance)
        let privateTarget = ((foreign["items"] as! [JSON])[0]["published_target"] as! JSON)["id"] as! String
        // Caller has no grant to the foreign project; explicit scoped probes cannot expose it.
        checks.checkError("FORBIDDEN") {try f.call("media_approved_examples",["project_id":foreignProject,"round_id":otherRound["id"]!,"item_id":otherItem["id"]!,"expanded":true],as:f.worker)}
        let unknown = try show(f,current,item,targets:[privateTarget,uuid(),String(repeating:"a",count:64)])
        XCTAssertTrue((unknown["examples"] as! [JSON]).isEmpty)
        XCTAssertFalse(try jsonString(unknown).contains("PRIVATE"))
        let sameType = try f.type(checks.schema()),sameRound = try f.round(sameType),sameItem = try f.item(sameRound)
        let wrongType = try show(f,sameRound,sameItem,targets:[targetIDs[2]])
        XCTAssertTrue((wrongType["examples"] as! [JSON]).isEmpty)
        checks.checkError("INVALID_INPUT") {try f.call("media_approved_examples",["round_id":current["id"]!,"item_id":item["id"]!,"sha256":String(repeating:"a",count:64),"expanded":true])}
        let first = try show(f,current,item,size:1)
        if let cursor = first["next_cursor"] as? String {
            _ = try f.call("media_decide",decisions.params(f,try f.get(old),ids:[oldRows[2]["id"] as! String],disposition:"needs_look"))
            let next = try show(f,current,item,size:1,cursor:cursor);XCTAssertTrue((next["examples"] as! [JSON]).isEmpty)
        }
    }
    func testDisplayHideGroupAndSortPreserveDecisionButExplicitMaterialAdoptionStalesIt() throws {
        let (f,old,current,item) = try acceptedHistory(1)
        let published = try f.publish(current);_ = try f.call("media_decide",decisions.params(f,published))
        let before = try f.get(current),decisionID = ((before["items"] as! [JSON])[0]["decision"] as! JSON)["id"] as! String
        let state = try f.allState()
        XCTAssertTrue(((try page(f,current,list:[:],filter:["hidden_item_ids":[item["id"]!]]))["rows"] as! [JSON]).isEmpty)
        _ = try page(f,current,list:["sort":[["key":"title","order":"descending"]]])
        XCTAssertEqual(try f.allState(),state)
        XCTAssertEqual((try f.get(current)["items"] as! [JSON])[0]["disposition"] as? String,"accepted")
        let example = (try show(f,current,item)["examples"] as! [JSON])[0]
        var p = f.observation(before);p["manifest_id"] = (before["manifest"] as! JSON)["id"];p["manifest_digest"] = (before["manifest"] as! JSON)["digest"]
        p["item_id"] = item["id"];p["expected_item_revision"] = (before["items"] as! [JSON])[0]["revision"]
        p["reference_target_id"] = example["target_id"];p["reference_decision_id"] = example["decision_id"];p["reference_slot_id"] = "text";p["slot_id"] = "text"
        let adopted = try f.call("media_material_reference_adopt",p)
        XCTAssertEqual(adopted["decision_stale"] as? Bool,true)
        let after = (try f.get(current)["items"] as! [JSON])[0]
        XCTAssertEqual(after["disposition"] as? String,"stale");XCTAssertEqual((after["decision"] as! JSON)["id"] as? String,decisionID)
        XCTAssertEqual((after["published_target"] as! JSON)["id"] as? String,adopted["target_id"] as? String)
        _ = try f.call("media_item_update",["item_id":item["id"]!,"expected_revision":after["revision"]!,"title":"Cosmetic rename"])
        let again = try f.publish(current)
        XCTAssertEqual(((again["items"] as! [JSON])[0]["published_target"] as! JSON)["review_basis_signature"] as? String,(after["published_target"] as! JSON)["review_basis_signature"] as? String)
        XCTAssertEqual((try f.get(old)["items"] as! [JSON])[0]["disposition"] as? String,"accepted")
        let adoptedTarget = try f.record(adopted["target_id"] as! String,"media_item_target")
        XCTAssertTrue((adoptedTarget["record_references"] as! [JSON]).contains {$0["type"] as? String == "media_item_target" && $0["id"] as? String == example["target_id"] as? String})
        try f.router.dbQueue.read {db in try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db,project:f.project))}
        for method in ["media_item_page","media_item_counts","media_approved_examples","media_material_reference_adopt","media_example_read_lease"] {
            checks.checkError("FORBIDDEN") {try f.router.handle(method:method,params:["command_id":uuid(),"project_id":f.project],caller:f.worker)}
        }
        XCTAssertFalse(try jsonString(f.router.handle(method:"tool_catalog",params:[:],caller:f.worker)).contains("media_item_page"))
    }
    func testManagedExamplesRequireAvailableTypedWinnerReferenceAndExactCurrentLease() throws {
        let f = try Fixture(),intakeTests = MediaFrozenIntakeTests(),type = try f.type(intakeTests.imageSchema()),old = try f.round(type)
        let path = f.workspace.appendingPathComponent("example.png");try intakeTests.png.write(to:path)
        var intake = try f.call("media_intake_preview",["round_id":old["id"]!,"sources":[["path":path.path]]],as:f.worker)
        let plan = intake["plan"] as! JSON
        intake = try f.call("media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":plan["id"]!,"plan_digest":plan["digest"]!],as:f.worker)
        _ = try f.call("media_intake_capture",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":intake["plan_id"]!,"row_ids":intake["remaining_row_ids"]!],as:f.worker)
        let published = try f.publish(old);_ = try f.call("media_decide",decisions.params(f,published))
        let current = try f.round(type),item = try f.call("media_item_create",["round_id":current["id"]!,"title":"New comparison"])
        let before = try f.allState(),example = try XCTUnwrap((show(f,current,item)["examples"] as! [JSON]).first)
        XCTAssertEqual(try f.allState(),before)
        let reference = (example["original_references"] as! [JSON])[0]
        var leaseParams: JSON = ["round_id":current["id"]!,"target_id":example["target_id"]!,"decision_id":example["decision_id"]!,"reference_id":reference["reference_id"]!,"seconds":10]
        var wrong = leaseParams;wrong["reference_id"] = uuid()
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",wrong)}
        wrong = leaseParams;wrong["reference_id"] = reference["sha256"]
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",wrong)}
        let lease = try f.call("media_example_read_lease",leaseParams,as:f.worker)
        let hold = try f.record(lease["lease_id"] as! String,"storage_hold")
        XCTAssertEqual(hold["owner_reference_id"] as? String,reference["reference_id"] as? String)
        XCTAssertEqual(hold["author"] as? String,f.worker.principal);XCTAssertEqual(hold["incarnation"] as? String,f.router.incarnation)
        XCTAssertNotNil(hold["session_generation"])
        _ = try f.call("media_example_read_release",["lease_id":lease["lease_id"]!],as:f.worker)
        XCTAssertEqual(try f.record(lease["lease_id"] as! String,"storage_hold")["state"] as? String,"released")
        let attachment = lease["attachment"] as! JSON,original = try f.router.managedURL(attachment["path"] as! String,family:"objects").path
        let bytes = try Data(contentsOf:URL(fileURLWithPath:original));try FileManager.default.removeItem(atPath:original)
        XCTAssertTrue((try show(f,current,item)["examples"] as! [JSON]).isEmpty)
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",leaseParams)}
        try bytes.write(to:URL(fileURLWithPath:original))
        XCTAssertEqual((try show(f,current,item)["examples"] as! [JSON]).count,1)
        try f.router.dbQueue.write {db in
            var stored = try f.router.record(db,reference["reference_id"] as! String,type:"storage_hold")
            stored["state"] = "released";try f.router.save(db,f.router.revised(stored),type:"storage_hold")
        }
        XCTAssertTrue((try show(f,current,item)["examples"] as! [JSON]).isEmpty)
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",leaseParams)}
        try f.router.dbQueue.write {db in
            var stored = try f.router.record(db,reference["reference_id"] as! String,type:"storage_hold")
            stored["state"] = "active";try f.router.save(db,f.router.revised(stored),type:"storage_hold")
        }
        _ = try f.call("media_decide",decisions.params(f,try f.get(old),disposition:"needs_look"))
        XCTAssertTrue((try show(f,current,item)["examples"] as! [JSON]).isEmpty)
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",leaseParams)}
        leaseParams["decision_id"] = uuid();checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",leaseParams)}
    }
    func testMatchingUsesDeclaredTypedMetadataAndCurrentContextAuthority() throws {
        let f = try Fixture(),type = try f.type(schema()),old = try f.round(type)
        _ = try f.item(old,metadata:["character":"hero","animation_label":"walk","direction":"N"])
        _ = try f.item(old,metadata:["character":"hero","animation_label":"walk","direction":"E"])
        let accepted = try f.publish(old);_ = try f.call("media_decide",decisions.params(f,accepted))
        let current = try f.round(type),item = try f.item(current,metadata:["character":"hero","animation_label":"walk","direction":"N"])
        let p: JSON = ["round_id":current["id"]!,"item_id":item["id"]!,"expanded":true,
            "examples":["enabled":true,"match_fields":["character","animation_label","direction"]]]
        XCTAssertEqual((try f.call("media_approved_examples",p)["examples"] as! [JSON]).count,1)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":old["id"]!,"body":"Changed historical review context"])
        XCTAssertTrue((try f.call("media_approved_examples",p)["examples"] as! [JSON]).isEmpty)
        try f.router.dbQueue.write {db in
            var session = try f.router.record(db,f.worker.sessionID!,type:"session")
            session["state"] = "revoked";try f.router.save(db,f.router.revised(session),type:"session")
        }
        XCTAssertThrowsError(try f.call("media_approved_examples",p,as:f.worker))
    }
    func testNumericGroupCountsTreatEquivalentNumbersAsOneBucket() throws {
        let f = try Fixture(),type = try f.type(schema()),round = try f.round(type)
        _ = try f.item(round,metadata:["number":1])
        _ = try f.item(round,metadata:["number":1.0])
        _ = try f.item(round,metadata:["number":2])
        let response = try page(f,round,list:["visible_columns":["number"],"group_by":["number"]])
        let rows = response["rows"] as! [JSON]
        XCTAssertEqual(rows.map {($0["group_path"] as! [JSON])[0]["item_count"] as! Int},[2,2,1])
    }
    func testBooleanVisibleMetadataAndGroupValuesRetainDeclaredType() throws {
        let definition = schema(),parsed = try MediaReviewSchema.parse(definition)
        let f = try Fixture(),type = try f.type(definition),round = try f.round(type)
        for (number,flag) in [false,true].enumerated() {
            _ = try f.item(round,metadata:["flag":flag,"number":number])
        }
        let config: JSON = ["visible_columns":["flag","number"],"group_by":["flag","number"]]
        // The lightweight projection must retain the same types for Draft and published targets.
        for published in [false,true] {
            if published {_ = try f.publish(round)}
            let before = try f.allState(),response = try page(f,round,list:config)
            let rows = response["rows"] as! [JSON]
            XCTAssertEqual(response["total"] as? Int,2)
            XCTAssertEqual(response["counts"] as? [String:Int],["pending":2])
            XCTAssertEqual(rows.count,2)
            for (index,row) in rows.enumerated() {
                let metadata = row["metadata"] as! JSON,groups = row["group_path"] as! [JSON]
                let expected = index == 1
                XCTAssertEqual(Set(metadata.keys),["flag","number"])
                for value in [metadata["flag"]!,groups[0]["value"]!] {
                    XCTAssertEqual(CFGetTypeID(try XCTUnwrap(value as? NSNumber)),CFBooleanGetTypeID())
                    XCTAssertEqual(try parsed.validateValue(value,fieldID:MediaReviewID("flag")),.boolean(expected))
                }
                for value in [metadata["number"]!,groups[1]["value"]!] {
                    XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(value as? NSNumber)),CFBooleanGetTypeID())
                    XCTAssertEqual(try parsed.validateValue(value,fieldID:MediaReviewID("number")),.number(Double(index)))
                }
                XCTAssertEqual(groups.map {$0["item_count"] as! Int},[1,1])
            }
            for flag in [false,true] {
                let counts = try f.call("media_item_counts",["round_id":round["id"]!,"list":config,"filter":["metadata":["flag":flag]]])
                XCTAssertEqual(counts["total"] as? Int,1)
                XCTAssertEqual(counts["counts"] as? [String:Int],["pending":1]);XCTAssertNil(counts["rows"])
            }
            XCTAssertEqual(try f.allState(),before)
        }
    }
    func testNumericZeroAndOneVisibleMetadataAndGroupsStayNumeric() throws {
        let definition = schema(),parsed = try MediaReviewSchema.parse(definition)
        let f = try Fixture(),type = try f.type(definition),round = try f.round(type)
        for number in [1,0] {_ = try f.item(round,metadata:["number":number])}
        let response = try page(f,round,list:["visible_columns":["number"],"group_by":["number"]])
        let rows = response["rows"] as! [JSON]
        XCTAssertEqual(rows.count,2)
        for (index,row) in rows.enumerated() {
            let metadata = row["metadata"] as! JSON,group = (row["group_path"] as! [JSON])[0]
            for value in [metadata["number"]!,group["value"]!] {
                XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(value as? NSNumber)),CFBooleanGetTypeID())
                XCTAssertEqual(try parsed.validateValue(value,fieldID:MediaReviewID("number")),.number(Double(index)))
            }
            XCTAssertEqual(group["item_count"] as? Int,1)
        }
    }
    func testBooleanGroupingKeepsMissingLastAndByteExactStableIDTies() throws {
        let f = try Fixture(),type = try f.type(schema()),round = try f.round(type)
        let ids = ["é","e\u{301}","z-true","a-true","missing-2","missing-1"]
        try seed(f,round,count:ids.count,ids:ids)
        for (index,id) in ids.enumerated() {
            var metadata: JSON = ["character":"hero"]
            if index < 4 {metadata["flag"] = index >= 2}
            let item = try f.record(id,"media_item")
            _ = try f.call("media_item_update",["item_id":id,"expected_revision":item["revision"]!,"metadata":metadata])
        }
        let parsed = try MediaReviewSchema.parse(schema())
        let config: JSON = ["visible_columns":["flag"],"group_by":["character","flag"]]
        var rows: [JSON] = [],cursor: String?
        repeat {
            let response = try page(f,round,list:config,cursor:cursor,limit:1)
            rows += response["rows"] as! [JSON];cursor = response["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(rows.map {Data(($0["id"] as! String).utf8)},["e\u{301}","é","a-true","z-true","missing-1","missing-2"].map {Data($0.utf8)})
        for (index,row) in rows.enumerated() {
            let metadata = row["metadata"] as! JSON,groups = row["group_path"] as! [JSON]
            XCTAssertEqual(groups.map {$0["item_count"] as! Int},[6,2])
            if index < 4 {
                for value in [metadata["flag"]!,groups[1]["value"]!] {
                    XCTAssertEqual(try parsed.validateValue(value,fieldID:MediaReviewID("flag")),.boolean(index >= 2))
                }
            } else {
                XCTAssertTrue(metadata["flag"] is NSNull);XCTAssertTrue(groups[1]["value"] is NSNull)
            }
        }
        let descending = try page(f,round,list:["sort":[["field_id":"flag","order":"descending"]]])["rows"] as! [JSON]
        XCTAssertEqual(descending.map {Data(($0["id"] as! String).utf8)},["a-true","z-true","e\u{301}","é","missing-1","missing-2"].map {Data($0.utf8)})
    }
    func testAdoptedHistoricalMaterialMustAlsoHaveAvailableOriginals() throws {
        let f = try Fixture(),intakeTests = MediaFrozenIntakeTests(),type = try f.type(intakeTests.imageSchema())
        func capturedRound(_ name: String) throws -> JSON {
            let round = try f.round(type),path = f.workspace.appendingPathComponent(name + ".png")
            var bytes = intakeTests.png;bytes.append(Data(name.utf8));try bytes.write(to:path)
            var intake = try f.call("media_intake_preview",["round_id":round["id"]!,"sources":[["path":path.path]]],as:f.worker)
            let plan = intake["plan"] as! JSON
            intake = try f.call("media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":plan["id"]!,"plan_digest":plan["digest"]!],as:f.worker)
            _ = try f.call("media_intake_capture",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":intake["plan_id"]!,"row_ids":intake["remaining_row_ids"]!],as:f.worker)
            let published = try f.publish(round);_ = try f.call("media_decide",decisions.params(f,published));return try f.get(round)
        }
        let source = try capturedRound("source"),derived = try capturedRound("derived"),current = try f.round(type)
        let item = try f.call("media_item_create",["round_id":current["id"]!,"title":"Current comparison"])
        let sourceExample = (try show(f,current,item)["examples"] as! [JSON]).first {$0["round_id"] as? String == source["id"] as? String}!
        let derivedItem = (derived["items"] as! [JSON])[0]
        var p = f.observation(derived);p["manifest_id"] = (derived["manifest"] as! JSON)["id"];p["manifest_digest"] = (derived["manifest"] as! JSON)["digest"]
        p["item_id"] = derivedItem["id"];p["expected_item_revision"] = derivedItem["revision"]
        p["reference_target_id"] = sourceExample["target_id"];p["reference_decision_id"] = sourceExample["decision_id"];p["reference_slot_id"] = "image";p["slot_id"] = "image"
        _ = try f.call("media_material_reference_adopt",p)
        _ = try f.call("media_decide",decisions.params(f,try f.get(derived)))
        let examples = try show(f,current,item)["examples"] as! [JSON]
        XCTAssertEqual(examples.count,2)
        let example = examples.first {$0["round_id"] as? String == derived["id"] as? String}!,reference = (example["original_references"] as! [JSON])[0]
        let sourceReference = (sourceExample["original_references"] as! [JSON])[0],original = try f.record(sourceReference["attachment_id"] as! String,"attachment")
        let ownOriginal = try f.record(reference["attachment_id"] as! String,"attachment")
        XCTAssertNotEqual(original["sha256"] as? String,ownOriginal["sha256"] as? String)
        try FileManager.default.removeItem(at:try f.router.managedURL(original["path"] as! String,family:"objects"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try f.router.managedURL(ownOriginal["path"] as! String,family:"objects").path))
        XCTAssertTrue((try show(f,current,item)["examples"] as! [JSON]).isEmpty)
        checks.checkError("NOT_FOUND") {try f.call("media_example_read_lease",["round_id":current["id"]!,"target_id":example["target_id"]!,"decision_id":example["decision_id"]!,"reference_id":reference["reference_id"]!])}
    }
}
