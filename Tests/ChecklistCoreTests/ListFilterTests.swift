import XCTest
import GRDB
@testable import ChecklistCore

final class ListFilterTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    var project: JSON!
    var first: JSON!
    var second: JSON!
    var third: JSON!
    var epic: JSON!
    var triage: JSON!
    var worker: Caller!
    let owner = Caller(role:"owner",installation:"list-filter-tests",projectIDs:[])
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/ListFilterTests/\(uuid())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        router = try CommandRouter(root:root)
        let workspace = root.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        project = try call("project_create",["name":"List filters","key_prefix":"CL","root_path":workspace.path])
        epic = try call("epic_create",["project_id":project["id"]!,"name":"Primary Epic"])
        first = try call("task_create",["project_id":project["id"]!,"key":"CL-14","title":"First matching ticket","epic_id":epic["id"]!])
        second = try call("task_create",["project_id":project["id"]!,"key":"CL-141","title":"Second matching ticket","epic_id":epic["id"]!])
        third = try call("task_create",["project_id":project["id"]!,"key":"CL-2","title":"Third matching ticket"])
        // Retained legacy reads still support the No Epic filter; new creation requires one.
        try router.dbQueue.writeWithoutTransaction {db in try db.execute(sql:"UPDATE records SET data=json_remove(data,'$.epic_id') WHERE id=?",arguments:[third["id"] as! String])}
        triage = try call("triage_create",["project_id":project["id"]!,"name":"Current handling"])
        for task in [first!,third!] {
            triage = try call("group_membership",["project_id":project["id"]!,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":task["id"]!,"action":"add"])
        }
        let sid = uuid()
        _ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"list-worker"])
        worker = Caller(role:"worker",installation:"list-worker",projectIDs:[project["id"] as! String],sessionID:sid,workspace:workspace.path)
    }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:root) }
    @discardableResult func call(_ method: String,_ params: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = params;if !CommandRouter.readMethods.contains(method) {p["command_id"] = uuid()}
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? owner)["data"] as! JSON
    }
    func page(_ filters: JSON = [:],_ caller: Caller? = nil) throws -> JSON {
        var p = filters;p["project_id"] = project["id"]!
        return try call("task_list",p,caller ?? worker)
    }
    func ids(_ filters: JSON = [:]) throws -> Set<String> {Set((try page(filters)["tasks"] as! [JSON]).compactMap {$0["id"] as? String})}
    func testTaskFiltersAloneAndCombinedWithExistingFilters() throws {
        XCTAssertEqual(try ids(["triage_id":triage["id"]!]),[first["id"] as! String,third["id"] as! String])
        XCTAssertEqual(try ids(["epic_id":epic["id"]!]),[first["id"] as! String,second["id"] as! String])
        XCTAssertEqual(try ids(["keys":["cl-14","CL-2"]]),[first["id"] as! String,third["id"] as! String])
        let filters: JSON = ["triage_id":triage["id"]!,"epic_id":epic["id"]!,"keys":["cl-14","CL-141"],"text":"matching","status_ids":[first["status_id"]!],"archived":false]
        XCTAssertEqual(try ids(filters),[first["id"] as! String])
        var wrong = filters;wrong["text"] = "Second";XCTAssertEqual(try ids(wrong),[])
        wrong = filters;wrong["status_ids"] = ["missing"];XCTAssertEqual(try ids(wrong),[])
        wrong = filters;wrong["archived"] = true;XCTAssertEqual(try ids(wrong),[])
    }
    func testKeysAreExactCaseInsensitiveAndEmptySelectsNone() throws {
        XCTAssertEqual(try ids(["keys":["cl-14"]]),[first["id"] as! String])
        XCTAssertEqual(try ids(["keys":["CL-1"]]),[])
        XCTAssertEqual(try ids(["keys":[String]()]),[])
        for invalid: Any in ["CL-14",[14],[String](repeating:"CL-14",count:201)] {
            XCTAssertThrowsError(try page(["keys":invalid])) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
        }
    }
    func testKeysMatchUnicodeCaseWithoutSubstringExpansion() throws {
        let task = try call("task_create",["project_id":project["id"]!,"key":"CL-Ä","title":"Unicode key"])
        XCTAssertEqual(try ids(["keys":["cl-ä"]]),[task["id"] as! String])
    }
    func testFieldsProjectionAndEmptyFieldsKeepPageMetadata() throws {
        let full = try page(),projected = try page(["fields":["title"],"limit":1])
        let row = try XCTUnwrap((projected["tasks"] as! [JSON]).first)
        XCTAssertEqual(Set(row.keys),["id","key","revision","title"])
        XCTAssertEqual(projected["total"] as? Int,3);XCTAssertEqual(projected["has_more"] as? Bool,true);XCTAssertTrue(projected["next_cursor"] is String)
        XCTAssertEqual(try jsonString(page(["fields":[String]()])["tasks"]!),try jsonString(full["tasks"]!))
        let allFields = Set((full["tasks"] as! [JSON]).flatMap {Array($0.keys)})
        XCTAssertEqual(try (page(["fields":allFields.sorted()])["tasks"] as! [JSON]).count,3)
    }
    func testUnknownFieldsListSortedValidNamesIncludingOnEmptyResults() throws {
        for (method,params) in [("task_list",["project_id":project["id"]!,"keys":["missing"],"fields":["bogus"]]),("triage_list",["project_id":project["id"]!,"key":"missing","fields":["bogus"]])] {
            XCTAssertThrowsError(try call(method,params,worker)) { error in
                guard let error = error as? CoreError else {return XCTFail("\(error)")}
                XCTAssertEqual(error.code,"INVALID_INPUT")
                let valid = error.details["valid_fields"] as! [String]
                XCTAssertEqual(valid,valid.sorted());XCTAssertTrue(valid.contains("revision"));XCTAssertTrue(valid.contains(method == "task_list" ? "title" : "name"))
                XCTAssertTrue(error.message.contains(valid.joined(separator:", ")))
            }
        }
        XCTAssertThrowsError(try page(["fields":[1]],owner)) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
    }
    func testTriageIDKeyAndFieldProjection() throws {
        _ = try call("triage_create",["project_id":project["id"]!,"name":"Other handling"])
        let selected = try call("triage_list",["project_id":project["id"]!,"triage_id":triage["id"]!],worker)["groups"] as! [JSON]
        XCTAssertEqual(selected.count,1);XCTAssertEqual(selected[0]["id"] as? String,triage["id"] as? String)
        let projected = try call("triage_list",["project_id":project["id"]!,"triage_id":triage["id"]!,"fields":["name","task_ids"]],worker)["groups"] as! [JSON]
        XCTAssertEqual(Set(projected[0].keys),["id","key","revision","name","task_ids"])
        XCTAssertEqual(Set(projected[0]["task_ids"] as! [String]),[first["id"] as! String,third["id"] as! String])
        XCTAssertTrue((try call("triage_list",["project_id":project["id"]!,"triage_id":triage["id"]!,"key":"missing"],worker)["groups"] as! [JSON]).isEmpty)
        let byKey = try call("triage_list",["project_id":project["id"]!,"key":(triage["key"] as! String).lowercased(),"fields":["name"]],worker)["groups"] as! [JSON]
        XCTAssertEqual(byKey.count,1)
    }
    func testForeignGroupsAndWrongGroupKindsAreRefused() throws {
        let foreign = try call("project_create",["name":"Foreign","key_prefix":"FG"])
        let otherTriage = try call("triage_create",["project_id":foreign["id"]!,"name":"Foreign Triage"]),otherEpic = try call("epic_create",["project_id":foreign["id"]!,"name":"Foreign Epic"])
        for (method,key,id) in [("task_list","triage_id",otherTriage["id"]!),("task_list","epic_id",otherEpic["id"]!),("triage_list","triage_id",otherTriage["id"]!)] {
            XCTAssertThrowsError(try call(method,["project_id":project["id"]!,key:id],worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"NOT_FOUND")}
        }
        XCTAssertThrowsError(try page(["triage_id":epic["id"]!])) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
    }
    func testFilteredPagingAndCursorBinding() throws {
        let filters: JSON = ["epic_id":epic["id"]!,"fields":["title"],"limit":1]
        let firstPage = try page(filters);XCTAssertEqual(firstPage["total"] as? Int,2)
        var next = filters;next["cursor"] = firstPage["next_cursor"]!
        let secondPage = try page(next);XCTAssertEqual(secondPage["has_more"] as? Bool,false)
        let firstID = (firstPage["tasks"] as! [JSON])[0]["id"] as! String
        XCTAssertNotEqual((secondPage["tasks"] as! [JSON])[0]["id"] as? String,firstID)
        for change: JSON in [["fields":["brief"]],["keys":["CL-14"]],["triage_id":triage["id"]!]] {
            var changed = next;changed.merge(change) {_,new in new}
            XCTAssertThrowsError(try page(changed)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        }
    }
    func testOwnerViewAndEpicListKeepFullRows() throws {
        let view: JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]
        let page = try self.page(["view":view],owner)["tickets_page"] as! JSON
        XCTAssertEqual(page["matched_count"] as? Int,3)
        XCTAssertTrue((page["tasks"] as! [JSON]).allSatisfy {$0["brief"] != nil && $0["status_category"] != nil})
        let epics = try call("epic_list",["project_id":project["id"]!],worker)["groups"] as! [JSON]
        XCTAssertEqual(epics.count,1);XCTAssertNotNil(epics[0]["members"])
    }
    func testWorkerAndAssistantCatalogDeclareListArrays() throws {
        let assistant = Caller(role:"assistant",installation:"list-assistant",projectIDs:[project["id"] as! String],assistantGrants:[project["id"] as! String:["read":true]])
        for caller in [worker!,assistant] {
            let tool = router.toolCatalog(caller).first {$0["name"] as? String == "task_list"}!
            let properties = (tool["inputSchema"] as! JSON)["properties"] as! JSON
            for name in ["keys","fields"] {XCTAssertEqual((properties[name] as! JSON)["type"] as? String,"array")}
            for name in ["epic_id","triage_id"] {XCTAssertNotNil(properties[name])}
        }
    }
}
