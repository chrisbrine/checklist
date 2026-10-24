import XCTest
@testable import ChecklistCore

final class PlaytestBundleTests: XCTestCase {
    var directory: URL!,router: CommandRouter!
    let owner = Caller(role:"owner",installation:"playtest-author",projectIDs:[])
    let critic = Caller(role:"owner",installation:"playtest-reviewer",projectIDs:[])
    override func setUpWithError() throws {
        directory = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ChecklistCoreTests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        router = try CommandRouter(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ input: JSON,_ actor: Caller? = nil) throws -> JSON {
        var input = method == "work_submit" ? try fixtureAcceptanceEvidence(router,input:input) : input;if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        let response = try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:input),caller:actor ?? owner)
        return try XCTUnwrap(response["data"] as? JSON)
    }
    func record(_ id: Any,_ type: String) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:type) } }
    func assertCode(_ code: String,_ body: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line) }
    }
    func ref(_ file: JSON) -> JSON { ["artifact_id":file["id"]!,"sha256":file["sha256"]!] }
    func attach(_ p: JSON,_ t: JSON,_ name: String,_ body: String,_ actor: Caller? = nil,mode: String = "managed") throws -> JSON {
        let file = directory.appendingPathComponent(UUID().uuidString + "-" + name);try Data(body.utf8).write(to:file)
        return try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path,"name":name,"mode":mode],actor)
    }
    func prepared(kind: String = "playtest") throws -> (JSON,JSON,JSON,JSON) {
        let p = try call("project_create",["name":"Synthetic playtest bundle","key_prefix":"PT"])
        var t = try call("task_create",["project_id":p["id"]!,"title":"Synthetic exact-build run","brief":"Retain a complete playtest bundle","acceptance":["Player reaches checkpoint","Restart restores checkpoint"],"kind":kind])
        t = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["readiness":"ready"]])
        let a = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        return (p,t,a,try bundle(p,t))
    }
    func bundle(_ p: JSON,_ t: JSON,buildID: String = "synthetic-1") throws -> JSON {
        let build = try attach(p,t,"build.txt","Synthetic build identity " + buildID)
        return ["build":ref(build).merging(["build_id":buildID,"version":"1.0","platform":"macOS synthetic"]) { _,new in new },"scenario":ref(try attach(p,t,"scenario.md","Synthetic: walk to checkpoint, restart, observe state.")),"state_files":[ref(try attach(p,t,"state.json","{\"checkpoint\":1,\"synthetic\":true}"))],"screenshots":[ref(try attach(p,t,"screenshot.txt","Synthetic screenshot placeholder; not native visual evidence."))],"log":ref(try attach(p,t,"playtest.log","Synthetic run: checkpoint reached; restart restored."))]
    }
    func submit(_ p: JSON,_ a: JSON,_ bundle: JSON) throws -> JSON {
        try call("work_submit",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["kind":"artifact","playtest_bundle":bundle]])
    }
    func claimReview(_ p: JSON,_ s: JSON) throws -> JSON {
        let t = s["task"] as! JSON
        return try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"review","review_request_id":(s["review_request_ids"] as! [String])[0],"target_manifest_id":s["manifest_id"]!,"gate":"review"],critic)
    }
    func reviewInput(_ p: JSON,_ s: JSON,_ a: JSON,verdict: String = "pass") throws -> JSON {
        let t = try record((s["task"] as! JSON)["id"]!,"task"),report = try call("review_evidence_add",["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"title":"Synthetic playtest review","body":"Fixture-only assessment; no native game was run."],critic)
        let manifest = try record(s["manifest_id"]!,"manifest")
        var assessment = try fixtureReviewAssessment(router,task:t,manifest:manifest,artifact:report)
        if verdict == "reject" { var rows = assessment["acceptance"] as! [JSON];rows[0]["result"] = "fail";assessment["acceptance"] = rows }
        return ["project_id":p["id"]!,"attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"review_request_id":a["review_request_id"]!,"target_manifest_id":a["manifest_id"]!,"gate":"review","verdict":verdict,"checks":[],"review_assessment":assessment]
    }

    func testCompleteBundleStoresAllHashesInExistingTargetAndSurvivesRestart() throws {
        let (p,t,a,input) = try prepared(),s = try submit(p,a,input),m = try record(s["manifest_id"]!,"manifest"),e = m["evidence"] as! JSON,raw = e["playtest_bundle"] as! JSON,b = try PlaytestBundle.parse(raw,stored:true)
        XCTAssertEqual(b.files.count,5);XCTAssertEqual((e["artifact_refs"] as? [JSON])?.count,5);XCTAssertNotNil(UUID(uuidString:raw["id"] as! String))
        XCTAssertEqual(m["digest"] as? String,ChecklistCore.hash(Data(try jsonString(e).utf8)))
        for ref in b.files { let file = try record(ref["artifact_id"]!,"attachment");XCTAssertEqual(file["sha256"] as? String,ref["sha256"] as? String) }
        router = try CommandRouter(root:directory.appendingPathComponent("store"))
        let current = try record(t["id"]!,"task")
        _ = try router.dbQueue.read { try router.validateManifestTarget($0,task:current,manifestID:s["manifest_id"] as! String) }
    }
    func testMalformedMissingAndDuplicateFilesFailWithoutPartialManifest() throws {
        let (p,_,a,b) = try prepared()
        for key in ["build","scenario","state_files","screenshots","log"] { var missing = b;missing.removeValue(forKey:key);assertCode("INVALID_INPUT") { _ = try self.submit(p,a,missing) } }
        var empty = b;empty["state_files"] = [];assertCode("INVALID_INPUT") { _ = try self.submit(p,a,empty) }
        var duplicate = b;duplicate["log"] = b["scenario"];assertCode("INVALID_INPUT") { _ = try self.submit(p,a,duplicate) }
        var unknown = b;unknown["id"] = UUID().uuidString;assertCode("INVALID_INPUT") { _ = try self.submit(p,a,unknown) }
        XCTAssertTrue(try router.dbQueue.read { try router.records($0,type:"manifest",project:p["id"] as? String).isEmpty })
    }
    func testWrongKindForeignExternalAndMismatchedFilesAreRejected() throws {
        let (p,t,a,b) = try prepared(kind:"work")
        assertCode("INVALID_INPUT") { _ = try self.submit(p,a,b) }
        let (pp,tt,aa,bb) = try prepared()
        var wrongHash = bb;var log = wrongHash["log"] as! JSON;log["sha256"] = String(repeating:"0",count:64);wrongHash["log"] = log
        assertCode("EVIDENCE_STALE") { _ = try self.submit(pp,aa,wrongHash) }
        var foreign = bb;foreign["log"] = b["log"];assertCode("NOT_FOUND") { _ = try self.submit(pp,aa,foreign) }
        var external = bb;external["log"] = ref(try attach(pp,tt,"external.log","Do not remove",mode:"reference"))
        assertCode("EVIDENCE_STALE") { _ = try self.submit(pp,aa,external) }
        XCTAssertNotNil(t["id"])
    }
    func testPassAndRejectRequireExactlyOnePassOrFailPerAcceptance() throws {
        let (p,_,a,b) = try prepared(),s = try submit(p,a,b),reviewer = try claimReview(p,s)
        var input = try reviewInput(p,s,reviewer,verdict:"reject"),assessment = input["review_assessment"] as! JSON
        input.removeValue(forKey:"review_assessment");assertCode("REVIEW_ASSESSMENT_REQUIRED") { _ = try self.call("review_record",input,self.critic) }
        let complete = assessment["acceptance"] as! [JSON]
        assessment["acceptance"] = Array(complete.prefix(1));input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") { _ = try self.call("review_record",input,self.critic) }
        var blocked = complete;blocked[0]["result"] = "blocked";assessment["acceptance"] = blocked;input["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_REQUIRED") { _ = try self.call("review_record",input,self.critic) }
        assessment["acceptance"] = complete;input["review_assessment"] = assessment
        let result = try call("review_record",input,critic)
        XCTAssertEqual(((result["review_assessment"] as? JSON)?["acceptance"] as? [JSON])?.compactMap { $0["result"] as? String },["fail","pass"])
        XCTAssertEqual((result["task"] as? JSON)?["status_category"] as? String,"queued")
    }
    func testChangedBuildRequiresNewRunAttachmentsAndStoredBundleCannotBeResubmitted() throws {
        let (p,_,a,b) = try prepared(),s = try submit(p,a,b),reviewer = try claimReview(p,s)
        _ = try call("review_record",reviewInput(p,s,reviewer,verdict:"reject"),critic)
        let t = try record((s["task"] as! JSON)["id"]!,"task"),next = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        var changed = b;var build = b["build"] as! JSON;build["build_id"] = "synthetic-2";changed["build"] = build
        assertCode("PLAYTEST_BUILD_CHANGED") { _ = try self.submit(p,next,changed) }
        let stored = ((try record(s["manifest_id"]!,"manifest"))["evidence"] as! JSON)["playtest_bundle"] as! JSON
        assertCode("INVALID_INPUT") { _ = try self.submit(p,next,stored) }
        let fresh = try bundle(p,t,buildID:"synthetic-2"),new = try submit(p,next,fresh)
        XCTAssertNotEqual(new["manifest_id"] as? String,s["manifest_id"] as? String)
        let current = try record(t["id"]!,"task")
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.router.dbQueue.read { try self.router.validateManifestTarget($0,task:current,manifestID:s["manifest_id"] as! String) } }
    }
    func testChangedOriginalBuildBytesInvalidateExactBundle() throws {
        let (p,_,a,b) = try prepared(),s = try submit(p,a,b),build = try record((b["build"] as! JSON)["artifact_id"]!,"attachment")
        try Data("Changed build".utf8).write(to:try router.managedURL(build["path"] as! String,family:"objects"))
        assertCode("EVIDENCE_STALE") { _ = try self.claimReview(p,s) }
    }
    func testCitedOnlyRetentionUsesOrdinaryKeepOriginalAndCleanupPreview() throws {
        let (p,_,a,b) = try prepared(),s = try submit(p,a,b),reviewer = try claimReview(p,s)
        var input = try reviewInput(p,s,reviewer),assessment = input["review_assessment"] as! JSON
        let screenshot = (b["screenshots"] as! [JSON])[0]
        var rows = assessment["acceptance"] as! [JSON];rows[0]["evidence_refs"] = (rows[0]["evidence_refs"] as! [JSON]) + [screenshot]
        assessment["acceptance"] = rows;input["review_assessment"] = assessment;input["retain_cited_files"] = true
        let r = try call("review_record",input,critic)
        XCTAssertEqual((r["retained_artifact_refs"] as? [JSON])?.count,1)
        let screenshotFile = try record(screenshot["artifact_id"]!,"attachment");XCTAssertTrue(bool(screenshotFile,"keep_original"))
        let settings = try call("project_settings_get",["project_id":p["id"]!])
        _ = try call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":settings["revision"]!,"settings_revision":settings["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]])
        let t = try record((s["task"] as! JSON)["id"]!,"task"),preview = try call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t["id"]!]),selected = preview["attachment_ids"] as! [String]
        XCTAssertFalse(selected.contains(screenshot["artifact_id"] as! String));XCTAssertTrue(selected.contains((b["log"] as! JSON)["artifact_id"] as! String))
        XCTAssertTrue((preview["holds"] as! [JSON]).contains { $0["attachment_id"] as? String == screenshot["artifact_id"] as? String && ($0["reasons"] as? [String] ?? []).contains("keepOriginal") })
        _ = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        // Advance the durable deadline only in this owned test store; no public
        // command accepts a clock override or a caller-created deletion plan.
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                var job = try XCTUnwrap(router.records(db,type:"cleanup_job",project:p["id"] as? String).last)
                job["enqueued_at_ms"] = Int64(1);job["not_before_ms"] = Int64(2);job["revision"] = try router.nextCleanupJobRevision(job)
                try router.save(db,job,type:"cleanup_job");return .commit
            }
        }
        for _ in 0..<6 { try router.runStorageMaintenance() }
        XCTAssertTrue(FileManager.default.fileExists(atPath:try router.managedURL(screenshotFile["path"] as! String,family:"objects").path))
        XCTAssertEqual(try record((b["log"] as! JSON)["artifact_id"]!,"attachment")["availability"] as? String,"original_cleaned")
        let archived = try record(t["id"]!,"task")
        assertCode("EVIDENCE_STALE") { _ = try self.router.dbQueue.read { try self.router.validateManifestTarget($0,task:archived,manifestID:s["manifest_id"] as! String) } }
    }
    func testBundleDigestDetectsCorruptedMetadataAndCatalogUsesExistingCommands() throws {
        let (p,_,a,b) = try prepared(),s = try submit(p,a,b),m = try record(s["manifest_id"]!,"manifest")
        var raw = ((m["evidence"] as! JSON)["playtest_bundle"] as! JSON);var build = raw["build"] as! JSON;build["platform"] = "Different";raw["build"] = build
        assertCode("EVIDENCE_STALE") { _ = try PlaytestBundle.parse(raw,stored:true) }
        let tools = router.toolCatalog(Caller(role:"worker",installation:"catalog",projectIDs:[]))
        let record = tools.first { $0["name"] as? String == "review_record" }!
        XCTAssertNotNil(((record["inputSchema"] as? JSON)?["properties"] as? JSON)?["retain_cited_files"])
        XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").hasPrefix("playtest_") })
    }
}
