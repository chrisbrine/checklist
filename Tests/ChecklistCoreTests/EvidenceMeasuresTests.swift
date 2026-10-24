import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

final class EvidenceMeasuresTests: XCTestCase {
    var directory: URL!,router: CommandRouter!
    let owner = Caller(role:"owner",installation:"measures-author",projectIDs:[])
    let critic = Caller(role:"owner",installation:"measures-reviewer",projectIDs:[])
    let measure: JSON = ["name":"Triangles","unit":"triangles","limit":25000,"before":32000,"after":26000]
    override func setUpWithError() throws {
        directory = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ChecklistCoreTests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        router = try TestStore.router(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ input: JSON,_ actor: Caller? = nil) throws -> JSON {
        var input = input;if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        let response = try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:input),caller:actor ?? owner)
        return try XCTUnwrap(response["data"] as? JSON)
    }
    func record(_ id: Any,_ type: String) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:type) } }
    func prepared() throws -> (JSON,JSON,JSON,JSON) {
        let p = try call("project_create",["name":"Synthetic measured evidence","key_prefix":"ME"])
        var t = try call("task_create",["project_id":p["id"]!,"title":"Budget observation","brief":"Show measured values","acceptance":["Budget warning is visible"]])
        t = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["readiness":"ready"]])
        let a = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        let path = directory.appendingPathComponent("observed.txt");try Data("Synthetic measured output".utf8).write(to:path)
        let file = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":path.path])
        return (p,t,a,file)
    }
    func submit(_ p: JSON,_ a: JSON,_ file: JSON,measures: Any) throws -> JSON {
        try call("work_submit",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":file["id"]!,"sha256":file["sha256"]!]],"measures":measures]])
    }
    func testNumericBoundsEqualityAndSignedValues() throws {
        let parsed = try EvidenceMeasure.parse([measure]);XCTAssertTrue(parsed[0].overLimit)
        var equality = measure;equality["after"] = 25000
        XCTAssertFalse(try EvidenceMeasure.parse([equality])[0].overLimit)
        var signed = measure;signed["name"] = "Offset";signed["unit"] = "mm";signed["limit"] = -0.25;signed["before"] = -1.5;signed["after"] = -0.5
        XCTAssertEqual(try EvidenceMeasure.parse([signed])[0].before,-1.5)
        XCTAssertTrue(try EvidenceMeasure.parse(nil).isEmpty)
    }
    func testRejectsMalformedAmbiguousAndUnboundedMeasures() throws {
        var bad: [JSON] = []
        for key in ["limit","before","after"] { for value in [true,"12",Double.infinity,Double.nan,NSNull()] as [Any] { var row = measure;row[key] = value;bad.append(row) } }
        for (key,value) in [("name",""),("name"," Triangles"),("name","First\u{2028}second"),("unit","mm\n"),("unit","mm\u{2029}units"),("extra",1)] as [(String,Any)] { var row = measure;row[key] = value;bad.append(row) }
        var missing = measure;missing.removeValue(forKey:"after");bad.append(missing)
        for row in bad { XCTAssertThrowsError(try EvidenceMeasure.parse([row])) }
        XCTAssertThrowsError(try EvidenceMeasure.parse([measure,measure]))
        XCTAssertThrowsError(try EvidenceMeasure.parse(Array(repeating:measure,count:101)))
        XCTAssertThrowsError(try EvidenceMeasure.parse("not a list"))
        var imprecise = measure;imprecise["after"] = Int64(9_007_199_254_740_993)
        XCTAssertThrowsError(try EvidenceMeasure.parse([imprecise]),"Never round an integer overrun down to its limit.")
    }
    func testSubmissionStoresMeasuresInImmutableDigestAndContextWarnings() throws {
        let (p,t,a,file) = try prepared(),submission = try submit(p,a,file,measures:[measure]),manifest = try record(submission["manifest_id"]!,"manifest")
        let evidence = try XCTUnwrap(manifest["evidence"] as? JSON)
        XCTAssertEqual(manifest["digest"] as? String,ChecklistCore.hash(Data(try jsonString(evidence).utf8)))
        XCTAssertEqual((evidence["measures"] as? [JSON])?.first?["after"] as? Double,26000)
        let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!]),summary = try XCTUnwrap(context["evidence_measures"] as? JSON)
        XCTAssertEqual((summary["warnings"] as? [JSON])?.count,1);XCTAssertEqual(summary["advisory_only"] as? Bool,true)
        router = try TestStore.router(root:directory.appendingPathComponent("store"))
        XCTAssertEqual(try jsonString(record(submission["manifest_id"]!,"manifest")["evidence"]!),try jsonString(evidence))
    }
    func testInvalidSubmissionLeavesClaimAndNoManifest() throws {
        let (p,t,a,file) = try prepared();var invalid = measure;invalid["after"] = true
        XCTAssertThrowsError(try submit(p,a,file,measures:[invalid]))
        XCTAssertEqual(try record(t["id"]!,"task")["active_attempt_id"] as? String,a["id"] as? String)
        XCTAssertTrue(try router.dbQueue.read { try router.records($0,type:"manifest",project:p["id"] as? String).isEmpty })
    }
    func testReviewerReportHashCoversMeasuresAndRetainsProvenance() throws {
        let (p,_,a,file) = try prepared(),s = try submit(p,a,file,measures:[]),t = s["task"] as! JSON
        let reviewer = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"review","review_request_id":(s["review_request_ids"] as! [String])[0],"target_manifest_id":s["manifest_id"]!,"gate":"review"],critic)
        let input: JSON = ["project_id":p["id"]!,"attempt_id":reviewer["id"]!,"claim_token":reviewer["claim_token"]!,"title":"Budget review","body":"Independent synthetic observation.","measures":[measure]]
        let report = try call("review_evidence_add",input,critic),bytes = try Data(contentsOf:URL(fileURLWithPath:report["path"] as! String))
        XCTAssertEqual(report["sha256"] as? String,ChecklistCore.hash(bytes));XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("Triangles"))
        XCTAssertEqual(report["review_attempt_id"] as? String,reviewer["id"] as? String);XCTAssertEqual(report["target_manifest_id"] as? String,s["manifest_id"] as? String)
        XCTAssertEqual(report["author"] as? String,critic.principal)
        let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual(((context["evidence_measures"] as? JSON)?["warnings"] as? [JSON])?.first?["source_id"] as? String,report["id"] as? String)
        var bad = input;bad["measures"] = [measure,measure]
        XCTAssertThrowsError(try call("review_evidence_add",bad,critic))
    }
    func testCatalogAdvertisesMeasuresOnExistingCommands() throws {
        let catalog = router.toolCatalog(Caller(role:"worker",installation:"catalog",projectIDs:[]))
        let report = try XCTUnwrap(catalog.first { $0["name"] as? String == "review_evidence_add" })
        XCTAssertNotNil(((report["inputSchema"] as? JSON)?["properties"] as? JSON)?["measures"])
        let submit = try XCTUnwrap(catalog.first { $0["name"] as? String == "work_submit" })
        XCTAssertNotNil(((((submit["inputSchema"] as? JSON)?["properties"] as? JSON)?["evidence_manifest"] as? JSON)?["properties"] as? JSON)?["measures"])
    }
    func testSelectedTicketKeepsComparisonHistorySeparateFromCurrentAuthority() throws {
        let (p,t,a,file) = try prepared(),s = try submit(p,a,file,measures:[measure]),current = try record(t["id"]!,"task")
        let history = try router.dbQueue.read { try router.evidenceMeasureHistory($0,task:current,caller:owner) }
        XCTAssertEqual((history["manifests"] as? [JSON])?.first?["id"] as? String,s["manifest_id"] as? String)
        XCTAssertEqual(history["truncated"] as? Bool,false)
        let packet = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!,"detail_level":"ui"])
        let records = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!,"detail_level":"ui_records","selected_context_cursor":packet["context_cursor"]!])
        XCTAssertEqual(records["current_scope_only"] as? Bool,true)
        XCTAssertNotNil((records["collections"] as? JSON)?["evidence_measure_history"])
    }
}
