import XCTest
@testable import ChecklistCore

/// Synthetic command fixture; no installed application or native observation is claimed.
final class SubmissionEvidenceFixture {
    let storage: ReadPerformanceFixture, workspace: URL, project: JSON
    var router: CommandRouter { storage.router }
    init(_ ticket: String) throws {
        storage = try ReadPerformanceFixture(ticket);workspace = storage.directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        project = try storage.call("project_create",["name":"Synthetic submission evidence","key_prefix":"SE","root_path":workspace.path])
    }
    func call(_ method: String,_ input: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = method == "review_context" ? input.filter {["task_id","review_request_id","target_manifest_id","gate","evidence_refs"].contains($0.key)} : input
        p["project_id"] = project["id"]
        if !CommandRouter.readMethods.contains(method) { p["command_id"] = UUID().uuidString }
        return try router.handle(method:method,params:p,caller:caller ?? storage.owner)["data"] as! JSON
    }
    func record(_ id: Any,_ type: String) throws -> JSON { try router.dbQueue.read { try router.record($0,id as! String,type:type) } }
    func worker(_ label: String) throws -> Caller {
        let sid = UUID().uuidString,installation = "synthetic-"+label
        _ = try call("session_register",["session_id":sid,"installation":installation,"provider":"codex","role":"worker","workspace":workspace.path,"execution_domain":"synthetic-host"])
        return Caller(role:"worker",installation:installation,projectIDs:[project["id"] as! String],sessionID:sid,workspace:workspace.path,executionDomain:"synthetic-host")
    }
    func write(_ path: String,_ contents: String = "fixture") throws {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(contents.utf8).write(to:url)
    }
    func ready(_ acceptance: [String] = []) throws -> JSON {
        let task = try call("task_create",["title":"Synthetic evidence","brief":"A bounded observable result","acceptance":acceptance])
        return try call("task_edit",["task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
    }
    func claim(_ task: JSON,_ author: Caller,scopes: [JSON] = []) throws -> JSON {
        try call("work_claim",["task_id":task["id"]!,"expected_revision":task["revision"]!,"file_scopes":scopes],author)
    }
    func submissionInput(_ attempt: JSON,_ author: Caller) throws -> JSON {
        let task = try record(attempt["task_id"]!,"task"),context = try call("task_context",["task_id":task["id"]!],author)
        return ["attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":task["acceptance_revision"]!,"direction_cursor":context["direction_cursor"]!,"evidence_manifest":["kind":"source","source_capture":[:]]]
    }
    func selectors(_ submitted: JSON) -> JSON {
        let task = submitted["task"] as! JSON
        return ["task_id":task["id"]!,"expected_revision":task["revision"]!,"phase":"review","review_request_id":(submitted["review_request_ids"] as! [String])[0],"target_manifest_id":submitted["manifest_id"]!,"gate":"review"]
    }
}

final class SourceFreshnessScopeTests: XCTestCase {
    func submitted(_ scopes: [JSON] = [["path":"src","access":"write"],["path":"dependency.txt","access":"read"]]) throws -> (SubmissionEvidenceFixture,JSON,Caller) {
        let f = try SubmissionEvidenceFixture("CL-141")
        try f.write("src/file.swift");try f.write("dependency.txt");try f.write("other.txt");try f.write("AGENTS.md")
        let author = try f.worker("author"),task = try f.ready(),attempt = try f.claim(task,author,scopes:scopes)
        let submitted = try f.call("work_submit",f.submissionInput(attempt,author),author)
        return (f,submitted,try f.worker("reviewer"))
    }
    func stale(_ body: () throws -> Void,path: String,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) {
            XCTAssertEqual(($0 as? CoreError)?.code,"EVIDENCE_STALE",file:file,line:line)
            XCTAssertTrue(($0 as? CoreError)?.message.contains(path) == true,file:file,line:line)
        }
    }
    func testUnrelatedEditKeepsContextAndReviewClaimValid() throws {
        let (f,s,r) = try submitted();try f.write("other.txt","changed")
        let context = try f.call("review_context",f.selectors(s),r),scope = try XCTUnwrap(context["source_relevance"] as? JSON)
        XCTAssertEqual(scope["mode"] as? String,"scoped");XCTAssertEqual(strings(scope,"scopes"),["dependency.txt","src"])
        _ = try f.call("work_claim",f.selectors(s),r)
    }
    func testWriteScopeEditRefusesContextClaimAndVerdictWithPath() throws {
        let (f,s,r) = try submitted();try f.write("src/file.swift","changed")
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"src/file.swift")
        stale({_ = try f.call("work_claim",f.selectors(s),r)},path:"src/file.swift")
        try f.write("src/file.swift")
        let a = try f.call("work_claim",f.selectors(s),r),context = try f.call("task_context",["task_id":a["task_id"]!],r)
        try f.write("src/file.swift","changed after claim")
        var verdict = f.selectors(s).filter {["review_request_id","target_manifest_id","gate"].contains($0.key)};verdict.merge(["attempt_id":a["id"]!,"claim_token":a["claim_token"]!,"verdict":"blocked","reason":"Synthetic stale check","direction_cursor":context["direction_cursor"]!]) {_,new in new}
        stale({_ = try f.call("review_record",verdict,r)},path:"src/file.swift")
    }
    func testReadScopeAndInstructionsAreRelevant() throws {
        for path in ["dependency.txt","AGENTS.md","nested/CLAUDE.md","new/AGENTS.md"] {
            let (f,s,r) = try submitted();try f.write(path,"changed")
            stale({_ = try f.call("review_context",f.selectors(s),r)},path:path)
        }
    }
    func testNewAndMissingDirectoryEntriesAreRelevant() throws {
        let (f,s,r) = try submitted();try f.write("src/new.swift")
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"src/new.swift")
        try FileManager.default.removeItem(at:f.workspace.appendingPathComponent("src/new.swift"))
        try FileManager.default.removeItem(at:f.workspace.appendingPathComponent("src/file.swift"))
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"src/file.swift")
    }
    func testAdditionalPathAndCaseInsensitiveScopesAreRelevant() throws {
        let f = try SubmissionEvidenceFixture("CL-141");try f.write("Mixed/File.swift");try f.write("extra.txt")
        let author = try f.worker("author"),task = try f.ready(),attempt = try f.claim(task,author,scopes:[["path":"Mixed","access":"write"]])
        var input = try f.submissionInput(attempt,author);input["evidence_manifest"] = ["source_capture":["additional_paths":["extra.txt"]]]
        let s = try f.call("work_submit",input,author),r = try f.worker("reviewer")
        try f.write("extra.txt","changed");stale({_ = try f.call("review_context",f.selectors(s),r)},path:"extra.txt")
        try f.write("extra.txt");try f.write("Mixed/File.swift","changed")
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"Mixed/File.swift")
    }
    func testGitHeadAndIndexChangeWithoutRelevantByteChangesStaysFresh() throws {
        let (f,s,r) = try submitted()
        _ = try SourceGit.run(f.workspace.path,["init"])
        _ = try SourceGit.run(f.workspace.path,["add","."])
        _ = try f.call("review_context",f.selectors(s),r)
        _ = try SourceGit.run(f.workspace.path,["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-m","same bytes"])
        _ = try f.call("review_context",f.selectors(s),r);_ = try f.call("work_claim",f.selectors(s),r)
    }
    func testExecutableBitAndSymlinkTargetAreRelevant() throws {
        let (f,s,r) = try submitted()
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:f.workspace.appendingPathComponent("src/file.swift").path)
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"src/file.swift")
        let g = try SubmissionEvidenceFixture("CL-141");try g.write("one.txt");try g.write("two.txt")
        let link = g.workspace.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"one.txt")
        let author = try g.worker("link-author"),task = try g.ready(),attempt = try g.claim(task,author,scopes:[["path":"link.txt","access":"read"]])
        var input = try g.submissionInput(attempt,author);input["evidence_manifest"] = ["source_capture":["additional_paths":["link.txt"]]]
        let target = try g.call("work_submit",input,author),critic = try g.worker("link-reviewer")
        try FileManager.default.removeItem(at:link);try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"two.txt")
        stale({_ = try g.call("review_context",g.selectors(target),critic)},path:"link.txt")
    }
    func testNoScopeAndLegacyCapturesKeepWholeInventoryRule() throws {
        for legacy in [false,true] {
            let (f,s,r) = try submitted(legacy ? [["path":"src","access":"write"]] : [])
            let m = try f.record(s["manifest_id"]!,"manifest"),ref = (m["evidence"] as! JSON)["source_capture"] as! JSON
            var capture = try f.record(ref["id"]!,"source_capture")
            if legacy { capture.removeValue(forKey:"relevance");capture.removeValue(forKey:"relevant_sha256");try f.storage.save([("source_capture",capture)]) }
            else { XCTAssertEqual((capture["relevance"] as? JSON)?["mode"] as? String,"whole") }
            try f.write("other.txt","changed")
            stale({_ = try f.call("review_context",f.selectors(s),r)},path:"source")
        }
    }
}
