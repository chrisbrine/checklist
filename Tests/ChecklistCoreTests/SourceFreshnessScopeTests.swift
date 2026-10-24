import XCTest
@testable import ChecklistCore

/// Synthetic command fixture; no installed application or native observation is claimed.
final class SubmissionEvidenceFixture {
    let storage: ReadPerformanceFixture, workspace: URL, project: JSON
    var router: CommandRouter { storage.router }
    init(_ ticket: String,symlinkedParent: Bool = false) throws {
        storage = try ReadPerformanceFixture(ticket)
        let parent = storage.directory.appendingPathComponent("root-alias")
        if symlinkedParent { try FileManager.default.createSymbolicLink(atPath:parent.path,withDestinationPath:storage.directory.path) }
        workspace = (symlinkedParent ? parent : storage.directory).appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        project = try storage.call("project_create",["name":"Synthetic submission evidence","key_prefix":"SE","root_path":workspace.path])
    }
    func call(_ method: String,_ input: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = method == "review_context" ? input.filter {["task_id","review_request_id","target_manifest_id","gate","evidence_refs"].contains($0.key)} : input
        p["project_id"] = project["id"]
        if !CommandRouter.readMethods.contains(method) { p["command_id"] = UUID().uuidString }
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? storage.owner)["data"] as! JSON
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
        _ = try SourceGit.run(f.workspace.path,["init"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"])
        _ = try SourceGit.run(f.workspace.path,["add","."], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"])
        _ = try f.call("review_context",f.selectors(s),r)
        _ = try SourceGit.run(f.workspace.path,["-c","maintenance.auto=false","-c","gc.auto=0","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-m","same bytes"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"])
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
    func testInstructionSymlinkTargetEditMustStaleScopedReview() throws {
        let f = try SubmissionEvidenceFixture("Reviewer-T-CL141")
        try f.write("src/file.swift");try f.write("rules.md","Original project instructions")
        try FileManager.default.createSymbolicLink(atPath:f.workspace.appendingPathComponent("AGENTS.md").path,withDestinationPath:"rules.md")
        let author = try f.worker("author"),task = try f.ready(),attempt = try f.claim(task,author,scopes:[["path":"src","access":"write"]])
        let submitted = try f.call("work_submit",f.submissionInput(attempt,author),author),reviewer = try f.worker("reviewer")
        _ = try f.call("review_context",f.selectors(submitted),reviewer)
        try f.write("rules.md","Changed project instructions")
        XCTAssertThrowsError(try f.call("review_context",f.selectors(submitted),reviewer),"Changed resolved AGENTS.md content must stale the target") {
            XCTAssertEqual(($0 as? CoreError)?.code,"EVIDENCE_STALE")
        }
        XCTAssertThrowsError(try f.call("work_claim",f.selectors(submitted),reviewer),"A stale target must refuse a review claim") {
            XCTAssertEqual(($0 as? CoreError)?.code,"EVIDENCE_STALE")
        }
    }
    func testReadScopeSymlinkRetargetMustStaleScopedReview() throws {
        let f = try SubmissionEvidenceFixture("Reviewer-T-CL141",symlinkedParent:true)
        try f.write("src/file.swift");try f.write("one.txt","first");try f.write("two.txt","second")
        let link = f.workspace.appendingPathComponent("dependency.txt")
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"one.txt")
        let author = try f.worker("author"),task = try f.ready(),attempt = try f.claim(task,author,scopes:[["path":"src","access":"write"],["path":link.path,"access":"read"]])
        let declared = URL(fileURLWithPath:f.router.reservationKey(link.deletingLastPathComponent().path)).appendingPathComponent(link.lastPathComponent).path
        XCTAssertEqual((attempt["file_scopes"] as? [JSON])?.first {$0["access"] as? String == "read"}?["declared_path"] as? String,declared)
        let submitted = try f.call("work_submit",f.submissionInput(attempt,author),author),reviewer = try f.worker("reviewer")
        _ = try f.call("review_context",f.selectors(submitted),reviewer)
        try FileManager.default.removeItem(at:link);try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"two.txt")
        XCTAssertThrowsError(try f.call("review_context",f.selectors(submitted),reviewer),"Changed declared read dependency link must stale the target") {
            XCTAssertEqual(($0 as? CoreError)?.code,"EVIDENCE_STALE")
        }
        XCTAssertThrowsError(try f.call("work_claim",f.selectors(submitted),reviewer),"A stale target must refuse a review claim") {
            XCTAssertEqual(($0 as? CoreError)?.code,"EVIDENCE_STALE")
        }
    }
    func testScopedSymlinkChainsRetainResolvedIdentityAndAliasDiagnostics() throws {
        let inputs: [(String,String?)] = [("AGENTS.md",nil),("nested/CLAUDE.md",nil),("dependency.txt","read"),("write-dependency.txt","write"),("src/dependency.txt",nil)]
        for (alias,access) in inputs {
            let f = try SubmissionEvidenceFixture("CL-141",symlinkedParent:true)
            try f.write("src/file.swift");try f.write("one.txt","same bytes");try f.write("two.txt","same bytes");try f.write("links/unrelated.txt")
            let middle = f.workspace.appendingPathComponent("links/middle.txt"),link = f.workspace.appendingPathComponent(alias)
            try FileManager.default.createDirectory(at:link.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.createSymbolicLink(atPath:middle.path,withDestinationPath:"../one.txt")
            let target = alias.contains("/") ? "../links/middle.txt" : "links/middle.txt"
            try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:target)
            var scopes: [JSON] = [["path":"src","access":"write"]]
            if let access {scopes.append(["path":link.path,"access":access])}
            let author = try f.worker("author"),task = try f.ready(),claimed = try f.claim(task,author,scopes:scopes)
            // A lane-only scope adjustment must also retain the declared file aliases.
            _ = try f.call("work_scope_adjust",["attempt_id":claimed["id"]!,"claim_token":claimed["claim_token"]!,"lane_scopes":[]],author)
            let s = try f.call("work_submit",f.submissionInput(claimed,author),author),r = try f.worker("reviewer")
            let context = try f.call("review_context",f.selectors(s),r),relevance = try XCTUnwrap(context["source_relevance"] as? JSON)
            let input = try XCTUnwrap((relevance["symlink_inputs"] as? [JSON])?.first {$0["path"] as? String == alias})
            XCTAssertEqual(input["resolved_path"] as? String,"one.txt");XCTAssertEqual(input["sha256"] as? String,ChecklistCore.hash(Data("same bytes".utf8)))
            XCTAssertEqual(try jsonString(input["link_chain"]!),try jsonString([["path":alias,"target":target,"sha256":ChecklistCore.hash(Data(target.utf8))],["path":"links/middle.txt","target":"../one.txt","sha256":ChecklistCore.hash(Data("../one.txt".utf8))]]))
            try f.write("links/unrelated.txt","unrelated edit");_ = try f.call("review_context",f.selectors(s),r)
            try f.write("one.txt","changed resolved bytes")
            stale({_ = try f.call("review_context",f.selectors(s),r)},path:alias)
            stale({_ = try f.call("work_claim",f.selectors(s),r)},path:alias)
            try f.write("one.txt","same bytes")
            for destination in ["../two.txt",".././one.txt"] {
                try FileManager.default.removeItem(at:middle);try FileManager.default.createSymbolicLink(atPath:middle.path,withDestinationPath:destination)
                stale({_ = try f.call("review_context",f.selectors(s),r)},path:alias)
                stale({_ = try f.call("work_claim",f.selectors(s),r)},path:alias)
            }
        }
    }
    func testBatchClaimKeepsDeclaredSymlinkScopeAlias() throws {
        let f = try SubmissionEvidenceFixture("CL-141",symlinkedParent:true)
        try f.write("src/file.swift");try f.write("other/file.swift");try f.write("one.txt");try f.write("two.txt")
        let alias = f.workspace.appendingPathComponent("dependency.txt")
        try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"one.txt")
        let tasks = try [f.ready(),f.ready()],author = try f.worker("author")
        var group = try f.call("triage_create",["name":"Synthetic alias batch","phase":"implementation"])
        for task in tasks {
            _ = try f.call("group_membership",["group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"])
            group = try f.record(group["id"]!,"group")
        }
        let members: [JSON] = try tasks.enumerated().map {index,task in
            let current = try f.record(task["id"]!,"task")
            let scopes: [JSON] = index == 0 ? [["path":"src","access":"write"],["path":alias.path,"access":"read"]] : [["path":"other","access":"write"]]
            return ["task_id":current["id"]!,"expected_revision":current["revision"]!,"file_scopes":scopes]
        }
        let batch = try f.call("batch_prepare",["triage_id":group["id"]!,"expected_revision":group["revision"]!,"phase":"implementation","tasks":members],author)
        let declared = URL(fileURLWithPath:f.router.reservationKey(alias.deletingLastPathComponent().path)).appendingPathComponent(alias.lastPathComponent).path
        let frozen = try XCTUnwrap((batch["members"] as? [JSON])?.first {$0["task_id"] as? String == tasks[0]["id"] as? String})
        XCTAssertEqual((frozen["file_scopes"] as? [JSON])?.first {$0["access"] as? String == "read"}?["declared_path"] as? String,declared)
        let result = try f.call("batch_claim",["batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],author)
        let attempt = try XCTUnwrap((result["claims"] as? [JSON])?.first {$0["task_id"] as? String == tasks[0]["id"] as? String})
        let scope = try XCTUnwrap((attempt["file_scopes"] as? [JSON])?.first {$0["access"] as? String == "read"})
        XCTAssertEqual(scope["declared_path"] as? String,declared)
        XCTAssertEqual(scope["canonical_key"] as? String,f.router.reservationKey(f.workspace.appendingPathComponent("one.txt").path))
        XCTAssertEqual(strings(f.router.sourceRelevance(root:f.workspace.path,attempt:attempt,additional:[]),"scopes"),["dependency.txt","one.txt","src"])
        let claims = result["claims"] as! [JSON]
        let submitted = try f.call("batch_submit",["batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"members":try claims.map {try f.submissionInput($0,author)}],author)["results"] as! [JSON]
        let reviewer = try f.worker("reviewer")
        var reviewGroup = try f.call("triage_create",["name":"Synthetic alias review","phase":"review"])
        for task in tasks {
            _ = try f.call("group_membership",["group_id":reviewGroup["id"]!,"expected_revision":reviewGroup["revision"]!,"task_id":task["id"]!,"action":"add"])
            reviewGroup = try f.record(reviewGroup["id"]!,"group")
        }
        let reviewMembers: [JSON] = try submitted.map {target in
            var member = f.selectors(target).filter {$0.key != "phase"}
            member["expected_revision"] = try f.record(member["task_id"]!,"task")["revision"]
            return member
        }
        let prepare: JSON = ["triage_id":reviewGroup["id"]!,"expected_revision":reviewGroup["revision"]!,"phase":"review","tasks":reviewMembers]
        let reviewBatch = try f.call("batch_prepare",prepare,reviewer)
        try FileManager.default.removeItem(at:alias);try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"two.txt")
        let target = try XCTUnwrap(submitted.first {($0["task"] as? JSON)?["id"] as? String == tasks[0]["id"] as? String})
        stale({_ = try f.call("review_context",f.selectors(target),reviewer)},path:"dependency.txt")
        stale({_ = try f.call("work_claim",f.selectors(target),reviewer)},path:"dependency.txt")
        stale({_ = try f.call("batch_claim",["batch_id":reviewBatch["id"]!,"expected_revision":reviewBatch["revision"]!,"policy_revision":reviewBatch["policy_revision"]!],reviewer)},path:"dependency.txt")
        stale({_ = try f.call("batch_prepare",prepare,reviewer)},path:"dependency.txt")
        for task in tasks { XCTAssertNil(try f.record(task["id"]!,"task")["active_attempt_id"],"A stale batch must not claim any member") }
    }

    func testScopeAdjustmentKeepsReadSymlinkUnderAliasedParent() throws { try adjustedAliasRetarget("work_scope_adjust") }
    func testCheckpointScopeChangeKeepsReadSymlinkUnderAliasedParent() throws { try adjustedAliasRetarget("work_checkpoint") }
    func adjustedAliasRetarget(_ method: String) throws {
        let f = try SubmissionEvidenceFixture("CL-141",symlinkedParent:true)
        try f.write("src/file.swift");try f.write("one.txt");try f.write("two.txt")
        let alias = f.workspace.appendingPathComponent("dependency.txt")
        try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"one.txt")
        let author = try f.worker("author"),task = try f.ready(),attempt = try f.claim(task,author,scopes:[["path":"src","access":"write"]])
        var input: JSON = ["attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"file_scopes":[["path":"src","access":"write"],["path":alias.path,"access":"read"]]]
        if method == "work_checkpoint" { input["progress"] = "Declare the aliased read dependency" }
        let adjusted = try f.call(method,input,author)
        let declared = URL(fileURLWithPath:f.router.reservationKey(alias.deletingLastPathComponent().path)).appendingPathComponent(alias.lastPathComponent).path
        XCTAssertEqual((adjusted["file_scopes"] as? [JSON])?.first {$0["access"] as? String == "read"}?["declared_path"] as? String,declared)
        let physical = f.router.reservationKey(f.workspace.path)
        XCTAssertNotEqual(f.workspace.path.lowercased(),physical.lowercased(),"The fixture must exercise a symlinked parent without TMPDIR")
        XCTAssertEqual(strings(f.router.sourceRelevance(root:f.workspace.path,attempt:adjusted,additional:[]),"scopes"),["dependency.txt","one.txt","src"])
        XCTAssertEqual(try jsonString(f.router.sourceRelevance(root:f.workspace.path,attempt:adjusted,additional:[])),try jsonString(f.router.sourceRelevance(root:physical,attempt:adjusted,additional:[])))
        let s = try f.call("work_submit",f.submissionInput(attempt,author),author),r = try f.worker("reviewer")
        _ = try f.call("review_context",f.selectors(s),r)
        try FileManager.default.removeItem(at:alias);try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"two.txt")
        stale({_ = try f.call("review_context",f.selectors(s),r)},path:"dependency.txt")
        stale({_ = try f.call("work_claim",f.selectors(s),r)},path:"dependency.txt")
    }

    func testStoredDeclaredAliasesUsePhysicalRootCoordinates() throws {
        let f = try SubmissionEvidenceFixture("CL-141",symlinkedParent:true)
        try f.write("one.txt")
        let alias = f.workspace.appendingPathComponent("dependency.txt")
        try FileManager.default.createSymbolicLink(atPath:alias.path,withDestinationPath:"one.txt")
        // Existing attempts/batches can still contain a lexical declared_path. Reading
        // relevance normalizes its parent, without resolving dependency.txt itself.
        let attempt: JSON = ["file_scopes":[["path":f.router.reservationKey(alias.path),"declared_path":alias.path,"access":"read"]]]
        var roots = [f.workspace.path,f.workspace.resolvingSymlinksInPath().path]
        var links: [URL] = []
        defer {for link in links {try? FileManager.default.removeItem(at:link)}}
        for base in ["/private/tmp","/private/var/tmp"] {
            let physical = URL(fileURLWithPath:base).appendingPathComponent("cl141-"+UUID().uuidString)
            try FileManager.default.createSymbolicLink(atPath:physical.path,withDestinationPath:f.workspace.resolvingSymlinksInPath().path);links.append(physical)
            roots += [physical.path,String(physical.path.dropFirst("/private".count))]
        }
        for root in roots { XCTAssertEqual(strings(f.router.sourceRelevance(root:root,attempt:attempt,additional:[]),"scopes"),["dependency.txt","one.txt"]) }
    }
}
