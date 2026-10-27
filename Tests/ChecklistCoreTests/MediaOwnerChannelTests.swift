import XCTest
import Foundation
@testable import ChecklistCore
import ChecklistIPC

final class MediaOwnerChannelTests: XCTestCase {
    typealias Fixture=MediaRoundTests.Fixture
    func owner(_ f:Fixture,_ method:String,_ params:JSON=[:],command:String?=nil) throws -> JSON {
        var p=params;p["project_id"]=f.project
        if !CommandRouter.mediaOwnerReads.contains(method) {p["command_id"]=command ?? uuid()}
        let reply=try f.router.handle(method:method,params:p,caller:f.owner)
        if !CommandRouter.mediaOwnerReads.contains(method) {XCTAssertEqual(reply["command_id"] as? String,p["command_id"] as? String)}
        _ = try CommandReply.decode(JSONSerialization.data(withJSONObject:reply),method:method,commandID:p["command_id"] as? String)
        return reply["data"] as! JSON
    }
    func testNativeOwnerBoundaryAndAllWorkerAssistantMediaCommandsDenied() throws {
        let f=try Fixture()
        XCTAssertEqual((try owner(f,"media_navigation")["enabled"] as! [JSON]).count,0)
        for role in [f.worker,Caller(role:"assistant",installation:"fixture",projectIDs:[f.project],assistantGrants:[f.project:["read":true]])] {
            for method in CommandRouter.mediaOwnerMethods {
                XCTAssertThrowsError(try f.router.handle(method:method,params:["project_id":f.project,"command_id":uuid(),"origin":"human_ui"],caller:role)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN",method)}
            }
            XCTAssertFalse(try jsonString(f.router.handle(method:"tool_catalog",params:[:],caller:role)).contains("media_"))
        }
        for method in ["media_suggest","media_material_reference_adopt","media_bulk_apply"] {
            XCTAssertThrowsError(try f.router.handle(method:method,params:["project_id":f.project,"command_id":uuid()],caller:f.owner))
        }
        XCTAssertThrowsError(try owner(f,"media_type_create",["title":"Story","origin":"human_ui"]))
    }
    func testTitleOnlySetupRetirementCannotStrandDraftOrOpenRoundAndHistoryStaysReadable() throws {
        let f=try Fixture(),type=try owner(f,"media_type_create",["title":"Optional"])
        let adopted=try owner(f,"media_type_adopt",["type_id":type["id"]!,"expected_revision":type["revision"]!,"type_revision_id":type["draft_revision_id"]!,"observed_type_token":type["observed_type_token"]!])
        let round=try owner(f,"media_round_create",["type_id":type["id"]!,"title":"Only round title"])
        let item=try owner(f,"media_item_create",["round_id":round["id"]!,"title":"Only item title"])
        XCTAssertEqual(item["state"] as? String,"draft")
        XCTAssertEqual((item["draft_target"] as! JSON)["publication_ready"] as? Bool,false)
        let before=try f.allState()
        XCTAssertThrowsError(try owner(f,"media_type_retire",["type_id":type["id"]!,"expected_revision":adopted["revision"]!])) {XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_ROUNDS_REMAIN")}
        XCTAssertEqual(try f.allState(),before)
        let canceled=try owner(f,"media_round_cancel",["round_id":round["id"]!,"expected_revision":round["revision"]!,"reason":"Synthetic check complete"])
        XCTAssertEqual(canceled["state"] as? String,"canceled")
        _ = try owner(f,"media_type_retire",["type_id":type["id"]!,"expected_revision":adopted["revision"]!])
        XCTAssertEqual((try owner(f,"media_navigation")["enabled"] as! [JSON]).count,0)
        let header=try owner(f,"media_round_header",["round_id":round["id"]!])
        XCTAssertNil(header["items"]);XCTAssertEqual(header["state"] as? String,"canceled")
        XCTAssertEqual((try owner(f,"media_item_get",["round_id":round["id"]!,"item_id":item["id"]!])["target"] as! JSON)["id"] as? String,(item["draft_target"] as! JSON)["id"] as? String)
        XCTAssertThrowsError(try owner(f,"media_round_create",["type_id":type["id"]!,"title":"Cannot strand new work"]))
    }
    func testBoundedProjectionExactPublicationOwnerDecisionAndContextConflictZeroWrites() throws {
        let f=try Fixture(),type=try f.type(MediaRoundTests().schema()),round=try f.round(type),created=try f.item(round)
        let preview=try owner(f,"media_publication_preview",["round_id":round["id"]!])
        let previewItem=(preview["items"] as! [JSON])[0]
        XCTAssertNil(previewItem["candidates"]);XCTAssertEqual(previewItem["publication_ready"] as? Bool,true)
        var publicationParams=f.observation(preview["round"] as! JSON)
        publicationParams["items"]=(preview["items"] as! [JSON]).map {row -> JSON in var row=row;row.removeValue(forKey:"title");row.removeValue(forKey:"publication_ready");return row}
        let compact=try owner(f,"media_round_publish",publicationParams)
        XCTAssertNil(compact["items"])
        let published=try f.get(round)
        XCTAssertThrowsError(try owner(f,"media_type_retire",["type_id":type["id"]!,"expected_revision":type["revision"]!]))
        let detail=try owner(f,"media_item_get",["round_id":round["id"]!,"item_id":created["id"]!])
        XCTAssertEqual(((detail["candidates"] as! [JSON])[0]["slots"] as! [JSON])[0]["text"] as? String,"Exact text\r\n")
        XCTAssertEqual(detail["disposition"] as? String,"pending")
        let params=f.decisionParams(published),command=uuid()
        let decision=try owner(f,"media_decide",params,command:command)
        let d=(decision["decisions"] as! [JSON])[0]
        XCTAssertEqual(d["origin"] as? String,"human_ui");XCTAssertEqual(d["author_session_id"] as? String,"human")
        let replay=try owner(f,"media_decide",params,command:command)
        XCTAssertEqual((replay["decisions"] as! [JSON])[0]["id"] as? String,d["id"] as? String)
        _ = try owner(f,"media_context_approve",["round_id":round["id"]!,"kind":"direction","body":"No flashing frames"])
        let before=try f.allState()
        XCTAssertThrowsError(try owner(f,"media_decide",params)) {XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")}
        XCTAssertEqual(try f.allState(),before)
        let foreign=try f.round(type)
        XCTAssertThrowsError(try owner(f,"media_item_get",["round_id":foreign["id"]!,"item_id":created["id"]!]))
    }
    func testNativeImageOriginalIsExactLeasedScopedAndAvailabilityIsHonest() throws {
        let helper=MediaFrozenIntakeTests(),f=try MediaFrozenIntakeTests.Fixture()
        let round=try f.round(f.type(helper.imageSchema()))
        var intake=try helper.preview(f,round,[helper.source(f,"synthetic.png")])
        intake=try helper.confirm(f,intake);_ = try helper.capture(f,intake)
        let published=try f.publish(round),item=(published["items"] as! [JSON])[0]
        func read(_ method:String,_ input:JSON) throws -> JSON {
            var p=input;p["project_id"]=f.project
            return try f.router.handle(method:method,params:p,caller:f.owner)["data"] as! JSON
        }
        let detail=try read("media_item_get",["round_id":round["id"]!,"item_id":item["id"]!])
        let original=(detail["originals"] as! [JSON])[0],target=detail["target"] as! JSON
        XCTAssertEqual(original["availability"] as? String,"available")
        let input:JSON=["round_id":round["id"]!,"item_id":item["id"]!,"target_id":target["id"]!,"reference_id":original["reference_id"]!]
        let bytes=try read("media_original_read",input)
        let decoded=try XCTUnwrap(Data(base64Encoded:bytes["base64"] as! String))
        XCTAssertEqual(ChecklistCore.hash(decoded),original["sha256"] as? String)
        XCTAssertTrue(decoded.starts(with:helper.png))
        let holds=try f.rows("storage_hold").filter {$0["kind"] as? String == "reader" && $0["state"] as? String == "active"}
        XCTAssertTrue(holds.isEmpty)
        var wrong=input;wrong["target_id"]=uuid();XCTAssertThrowsError(try read("media_original_read",wrong))
        let attachment=try f.record(original["attachment_id"] as! String,"attachment")
        let path=attachment["path"] as! String
        XCTAssertTrue(path.hasPrefix("objects/"),"Managed originals retain store-relative descriptors.")
        let url=try f.router.managedURL(path,family:"objects")
        XCTAssertEqual(try Data(contentsOf:url),decoded)
        try FileManager.default.removeItem(at:url)
        let missing=try read("media_item_get",["round_id":round["id"]!,"item_id":item["id"]!])
        XCTAssertEqual((missing["originals"] as! [JSON])[0]["availability"] as? String,"unavailable")
        XCTAssertThrowsError(try read("media_original_read",input))
    }

}
