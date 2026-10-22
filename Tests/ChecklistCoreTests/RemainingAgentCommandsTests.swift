import XCTest
import AppKit
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func cl135Record(_ id: String,_ type: String) throws -> JSON { try router.dbQueue.read {try router.record($0,id,type:type)} }
    func cl135Lock(_ p: JSON,_ locked: Bool) throws {
        var policy = try currentPolicy(p);policy["agent_rule_changes"] = locked ? "owner_only" : "allowed"
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"policy":policy])
    }
    func cl135Finding(_ p: JSON,_ t: JSON) throws -> JSON {
        let f: JSON = ["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"state":"open","severity":"blocking","revision":1]
        try router.dbQueue.write { try router.save($0,f,type:"finding") };return f
    }
    func testCL135WaiversKeepAgentProvenanceAndDoNotCreateHumanAnswers() throws {
        let (p,agent) = try agentChangeFixture(),t = try task(p),f = try cl135Finding(p,t)
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Synthetic direction","requires_action":true])
        let inputs: [(String,JSON)] = [("finding_waive",["finding_id":f["id"]!,"expected_revision":f["revision"]!,"reason":"No longer applies"]),("direction_waive",["message_id":note["id"]!,"expected_revision":note["revision"]!,"reason":"Reconciled direction"])]
        try cl135Lock(p,true)
        for (method,input) in inputs { assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call(method,input.merging(["project_id":p["id"]!]) {_,n in n},agent)} }
        try cl135Lock(p,false)
        let waived = try call("finding_waive",inputs[0].1.merging(["project_id":p["id"]!]) {_,n in n},agent)
        let resolution = try cl135Record(waived["latest_resolution_id"] as! String,"finding_resolution")
        let disposition = try call("direction_waive",inputs[1].1.merging(["project_id":p["id"]!]) {_,n in n},agent)
        for record in [resolution,disposition] {
            XCTAssertEqual(record["origin"] as? String,"agent");XCTAssertEqual(record["waiver_kind"] as? String,"agent_waiver")
            XCTAssertEqual(record["actor"] as? String,agent.principal);XCTAssertEqual(record["session_id"] as? String,agent.sessionID)
        }
        assertCode("FORBIDDEN") {_ = try self.call("human_request_answer",["project_id":p["id"]!],agent)}
        XCTAssertEqual(try cl135Record(note["id"] as! String,"message")["origin"] as? String,"human_ui")
    }
    func testCL135RecoveryKeepsEveryStopGuardAndFencesTheOldClaim() throws {
        let (p,agent) = try agentChangeFixture(),t = try ready(p,task(p))
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!],agent)
        let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]),job = uuid()
        try router.dbQueue.write {try router.save($0,["id":job,"project_id":p["id"]!,"task_id":t["id"]!,"attempt_id":claim["id"]!,"state":"interrupted","process_stop_unverified":true,"revision":1],type:"source_execution")}
        var input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":current["revision"]!,"action":"confirm_stopped_revoke","reason":"Synthetic explicit stop receipt"]
        try cl135Lock(p,true)
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("work_recover",input,agent)}
        try cl135Lock(p,false)
        assertCode("RECOVERY_REQUIRED") {_ = try self.call("work_recover",input,agent)}
        input["observation_refs"] = ["process-group-stop"];input["file_state_refs"] = ["inspected-output"]
        assertCode("RECOVERY_REQUIRED") {_ = try self.call("work_recover",input,agent)}
        input["source_execution_ids"] = [job];input["expected_source_execution_revisions"] = [job:2]
        assertCode("REVISION_CONFLICT") {_ = try self.call("work_recover",input,agent)}
        XCTAssertEqual(try cl135Record(claim["id"] as! String,"attempt")["state"] as? String,"active")
        input["expected_source_execution_revisions"] = [job:1]
        _ = try call("work_recover",input,agent)
        let attempt = try cl135Record(claim["id"] as! String,"attempt"),execution = try cl135Record(job,"source_execution")
        XCTAssertEqual(attempt["recovery_origin"] as? String,"agent");XCTAssertEqual(attempt["recovered_by"] as? String,agent.principal)
        XCTAssertEqual(execution["stop_verification_origin"] as? String,"agent");XCTAssertFalse(bool(execution,"process_stop_unverified"))
        assertCode("STALE_CLAIM") {_ = try self.call("work_checkpoint",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"obsolete"],agent)}
    }
    func testCL135IconCommandsConfineFilesAndHonorTheSwitch() throws {
        let (p,agent) = try agentChangeFixture()
        let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
        let bytes = image.representation(using:.png,properties:[:])!,inside = URL(fileURLWithPath:agent.workspace!).appendingPathComponent("icon.png"),outside = directory.appendingPathComponent("outside.png")
        try bytes.write(to:inside);try bytes.write(to:outside)
        let link = inside.deletingLastPathComponent().appendingPathComponent("escape.png");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        for path in [outside.path,link.path] { assertCode("FILE_ACCESS_REQUIRED") {_ = try self.call("project_icon_import",["project_id":p["id"]!,"path":path,"expected_revision":try self.currentProjectRevision(p)],agent)} }
        try cl135Lock(p,true)
        for method in ["project_icon_import","project_icon_clear"] { assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call(method,["project_id":p["id"]!,"path":inside.path,"expected_revision":try self.currentProjectRevision(p)].filter {method == "project_icon_import" || $0.key != "path"},agent)} }
        try cl135Lock(p,false)
        let imported = try call("project_icon_import",["project_id":p["id"]!,"path":inside.path,"expected_revision":try currentProjectRevision(p)],agent)
        XCTAssertNotNil(imported["icon_asset"]);XCTAssertNil(imported["icon_path"])
        let cleared = try call("project_icon_clear",["project_id":p["id"]!,"expected_revision":imported["revision"]!],agent)
        XCTAssertNil(cleared["icon_asset"]);XCTAssertEqual(try Data(contentsOf:outside),bytes)
    }
    func testCL135SnoozeAndRelationImportHonorSwitchAndAttribution() throws {
        let (p,agent) = try agentChangeFixture(),t = try task(p),other = try task(p,"Other")
        let request = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"title":"Synthetic question","questions":[["id":"q","prompt":"Which option?"]]],agent)
        try cl135Lock(p,true)
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("human_request_snooze",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"snoozed":true],agent)}
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("relation_import",["project_id":p["id"]!,"expected_revision":try self.currentProjectRevision(p),"relations":[]],agent)}
        try cl135Lock(p,false)
        let snoozed = try call("human_request_snooze",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"snoozed":true],agent)
        XCTAssertTrue(bool(snoozed,"owner_snoozed"));XCTAssertEqual(snoozed["state"] as? String,"pending");XCTAssertTrue((snoozed["responses"] as? [JSON] ?? []).isEmpty)
        let result = try call("relation_import",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"relations":[["id":uuid(),"source_task_id":t["id"]!,"target_task_id":other["id"]!,"relation":"related_to","origin":"human_ui"]],"aliases":[["id":uuid(),"task_id":t["id"]!,"namespace":"fixture","alias":"old-1","origin":"human_ui"]]],agent)
        for record in (result["relations"] as! [JSON]) + (result["aliases"] as! [JSON]) { XCTAssertEqual(record["origin"] as? String,"agent");XCTAssertEqual(record["imported_by"] as? String,agent.principal) }
    }
    func testCL135AttachmentHoldReleaseKeepsOtherReadersProtected() throws {
        let (p,agent) = try agentChangeFixture(),t = try task(p)
        let file = URL(fileURLWithPath:agent.workspace!).appendingPathComponent("report.txt");try Data("report".utf8).write(to:file)
        var a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path],agent)
        a = try call("attachment_update",["project_id":p["id"]!,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":"keep_original"],agent)
        let own = uuid(),foreign = uuid()
        try router.dbQueue.write {db in
            for (id,author) in [(own,agent.principal),(foreign,"someone-else")] {try router.save(db,["id":id,"project_id":p["id"]!,"kind":"reader","attachment_id":a["id"]!,"author":author,"state":"active","expires_at":Date().addingTimeInterval(300).timeIntervalSince1970,"revision":1],type:"storage_hold")}
        }
        try cl135Lock(p,true)
        for action in ["describe","keep_original","release_own_hold","unlink","restore_link"] {
            assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("attachment_update",["project_id":p["id"]!,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":action],agent)}
        }
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("attachment_read_release",["project_id":p["id"]!,"read_hold_id":own],agent)}
        try cl135Lock(p,false)
        let released = try call("attachment_update",["project_id":p["id"]!,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":"release_own_hold"],agent)
        XCTAssertFalse(bool(released,"keep_original"));XCTAssertEqual(released["hold_release_origin"] as? String,"agent")
        assertCode("FORBIDDEN") {_ = try self.call("attachment_read_release",["project_id":p["id"]!,"read_hold_id":foreign],agent)}
        XCTAssertEqual(try call("attachment_read_release",["project_id":p["id"]!,"read_hold_id":own],agent)["release_origin"] as? String,"agent")
        XCTAssertEqual(try cl135Record(foreign,"storage_hold")["state"] as? String,"active")
    }
    func testCL135ProjectDiagnosticsExcludeOtherProjectsAndGlobalReceipts() throws {
        let (p,agent) = try agentChangeFixture(),foreign = try project("Private project")
        _ = try task(p);_ = try task(foreign);_ = try task(foreign)
        let summary = try call("diagnostics_summary",["project_id":p["id"]!],agent),counts = summary["record_counts"] as! [String:Int]
        XCTAssertEqual(counts["task"],1);XCTAssertNil(counts["command_receipt"])
        assertCode("FORBIDDEN") {_ = try self.call("diagnostics_summary",["project_id":foreign["id"]!],agent)}
        try cl135Lock(p,true)
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("diagnostics_summary",["project_id":p["id"]!],agent)}
    }
    func testCL135CatalogKeepsGrantCreationAndPathBasedExportClosed() throws {
        let (p,agent) = try agentChangeFixture(),names = Set(router.toolCatalog(agent).compactMap {$0["name"] as? String})
        for method in ["work_recover","finding_waive","direction_waive","project_icon_import","project_icon_clear","archive_storage_settings","cleanup_job_list","cleanup_job_get","cleanup_job_cancel","cleanup_job_retry","attachment_update","attachment_read_release","relation_import","human_request_snooze","diagnostics_summary"] {XCTAssertTrue(names.contains(method),method)}
        for method in ["project_create","export_project","human_request_answer"] {XCTAssertFalse(names.contains(method));assertCode("FORBIDDEN") {_ = try self.call(method,["project_id":p["id"]!],agent)}}
    }
}

extension CoreTests {
    func testCL135ArchiveSettingsAndEveryJobCommandHonorSwitchAndRevisions() throws {
        let (p,agent) = try agentChangeFixture(),t = try task(p)
        func settings(_ actor: Caller) throws -> JSON {
            let current = try cl135Record(p["id"] as! String,"project")
            return try call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":current["revision"]!,"settings_revision":current["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]],actor)
        }
        try cl135Lock(p,true)
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try settings(agent)}
        for method in ["cleanup_job_list","cleanup_job_get","cleanup_job_cancel","cleanup_job_retry"] {
            let input: JSON = method == "cleanup_job_list" ? ["task_id":t["id"]!] : ["cleanup_job_id":"missing","expected_revision":1]
            assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call(method,input.merging(["project_id":p["id"]!]) {_,n in n},agent)}
        }
        assertCode("HUMAN_CHANNEL_REQUIRED") {_ = try self.call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"cleanup":true],agent)}
        try cl135Lock(p,false)
        _ = try settings(agent)
        let file = URL(fileURLWithPath:agent.workspace!).appendingPathComponent("large.txt");try Data("cleanup fixture".utf8).write(to:file)
        let attachment = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path],agent)
        let preview = try call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t["id"]!],agent)
        XCTAssertGreaterThan(int(preview,"clean_bytes"),0)
        assertCode("CLEANUP_PREVIEW_REQUIRED") {_ = try self.call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"cleanup":true],agent)}
        _ = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!],agent)
        let jobs = try call("cleanup_job_list",["project_id":p["id"]!,"task_id":t["id"]!],agent)["cleanup_jobs"] as! [JSON],job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(try call("cleanup_job_get",["project_id":p["id"]!,"cleanup_job_id":job["id"]!],agent)["state"] as? String,"queued")
        // Exercise retry from a real suspended state without waiting or unlinking fixture bytes.
        try router.dbQueue.write { db in
            let raw = try router.record(db,job["id"] as! String,type:"cleanup_job");var value = try ArchiveCleanupJob(record:raw)
            let id = try ArchiveAttachmentID(attachment["id"] as! String)
            try value.recordFailure(id:id,code:.admissionUnavailable);try value.recordFailure(id:id,code:.admissionUnavailable)
            try router.save(db,value.record(revision:try router.nextCleanupJobRevision(raw)),type:"cleanup_job")
        }
        let suspended = try cl135Record(job["id"] as! String,"cleanup_job")
        assertCode("REVISION_CONFLICT") {_ = try self.call("cleanup_job_retry",["project_id":p["id"]!,"cleanup_job_id":job["id"]!,"expected_revision":1],agent)}
        let retried = try call("cleanup_job_retry",["project_id":p["id"]!,"cleanup_job_id":job["id"]!,"expected_revision":suspended["revision"]!],agent)
        XCTAssertEqual(retried["state"] as? String,"queued")
        let canceled = try call("cleanup_job_cancel",["project_id":p["id"]!,"cleanup_job_id":job["id"]!,"expected_revision":retried["revision"]!],agent)
        XCTAssertEqual(canceled["state"] as? String,"canceled");XCTAssertEqual(try Data(contentsOf:file),Data("cleanup fixture".utf8))
    }
}
