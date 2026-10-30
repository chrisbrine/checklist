import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-360: an agent applies the rule the owner stated in a recorded answer.
final class BackupRetentionAnswerTests: XCTestCase {
    private let label = "Newest 3, plus one per day for 3 days (about 6 snapshots, 15 GB)"
    private func fixture() throws -> StorageFixture {
        let f = try StorageFixture(open:false);try f.close()
        let lease = try StorageServiceLease(root:f.root)
        f.router = try CommandRouter(root:f.root,serviceLease:lease,automaticBackupRetentionTrashRoot:f.workspace);f.lease = lease
        return f
    }
    private func worker(_ f: StorageFixture,_ project: JSON,workspace: URL? = nil) throws -> Caller {
        let path = (workspace ?? f.workspace).path
        let session = try f.call("session_register",["project_id":project["id"]!,"label":"Retention answer test","provider":"codex","role":"worker","installation":"retention-answer-test","workspace":path])["data"] as! JSON
        return Caller(role:"worker",installation:"retention-answer-test",projectIDs:[project["id"] as! String],sessionID:session["id"] as? String,workspace:path)
    }
    private func request(_ f: StorageFixture,_ project: JSON,_ c: Caller,labels: [String]) throws -> JSON {
        let task = try f.task(project)
        let options: [JSON] = labels.enumerated().map {["id":"option\($0.offset)","label":$0.element]}
        return try f.call("human_request_create",["project_id":project["id"]!,"task_id":task["id"]!,"title":"Retention \(UUID().uuidString)","questions":[["id":"rule","type":"choice","prompt":"Retention \(UUID().uuidString)","options":options,"allow_custom":true]]],caller:c)["data"] as! JSON
    }
    /// Answers through the owner channel and returns the stored response ID.
    private func answer(_ f: StorageFixture,_ r: JSON,option: Int? = 0,custom: String? = nil) throws -> String {
        var item: JSON = ["question_id":"rule"]
        if let option {item["option_ids"] = ["option\(option)"]}
        if let custom {item["custom_text"] = custom}
        let reply = try f.call("human_request_answer",["project_id":r["project_id"]!,"request_id":r["id"]!,"expected_revision":r["revision"]!,"answers":[item]])["data"] as! JSON
        return try XCTUnwrap((reply["responses"] as? [JSON])?.last?["id"] as? String)
    }
    private func apply(_ f: StorageFixture,_ project: JSON,_ c: Caller,request: String,response: String,command: String = UUID().uuidString.lowercased(),extra: JSON = [:]) throws -> JSON {
        var input: JSON = ["project_id":project["id"]!,"request_id":request,"response_id":response];input.merge(extra) {_,new in new}
        return try f.call("backup_retention_apply_answer",input,command:command,caller:c)
    }
    private func refused(_ reason: String,file: StaticString = #filePath,line: UInt = #line,_ body: () throws -> Void) {
        XCTAssertThrowsError(try body(),file:file,line:line) {error in
            let core = error as? CoreError
            XCTAssertEqual(core?.code,StorageAutomaticBackupRetention.answerRefused,file:file,line:line)
            XCTAssertEqual(core?.details["reason"] as? String,reason,file:file,line:line)
            XCTAssertFalse(core?.message.isEmpty ?? true,file:file,line:line)
        }
    }
    private func settings(_ f: StorageFixture) throws -> JSON {try f.call("backup_retention_get")["data"] as! JSON}
    private func snapshot(_ f: StorageFixture,_ name: String) throws -> JSON {
        let destination = f.root.appendingPathComponent("backups/snapshot-" + name)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        return try f.call("backup_create",["path":destination.path])["data"] as! JSON
    }
    private func age(_ f: StorageFixture,_ snapshot: JSON) throws {
        try f.router!.dbQueue.write {db in
            let key = "backup-generation:" + (snapshot["operation_id"] as! String)
            var receipt = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])))
            var summary = receipt["summary"] as! JSON;summary["captured_at"] = "2000-01-01T00:00:00Z";receipt["summary"] = summary
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(receipt),key])
        }
    }
    /// A response can come only from the owner channel, so the refusal test edits the stored record.
    private func editRequest(_ f: StorageFixture,_ r: JSON,_ change: (inout JSON) -> Void) throws {
        try f.router!.dbQueue.write {db in
            var stored = try f.router!.scoped(db,r["id"] as! String,r["project_id"] as! String,type:"request")
            change(&stored);try f.router!.save(db,stored,type:"request")
        }
    }

    func testRuleFormAndBounds() {
        let accepted: [(String,Int,Int)] = [(label,3,3),("Newest 3, plus one per day for 3 days",3,3),("Newest 1000, plus one per day for 366 days",1000,366),("Newest 1, plus one per day for 1 day",1,1)]
        for (text,newest,days) in accepted {
            let rule = StorageBackupRetentionPolicy.stated(in:text)
            XCTAssertEqual(rule?.newestCount,newest,text);XCTAssertEqual(rule?.dailyDays,days,text)
        }
        for text in ["","Keep a few","newest 3, plus one per day for 3 days","Newest 0, plus one per day for 3 days","Newest 3, plus one per day for 0 days","Newest 1001, plus one per day for 3 days","Newest 3, plus one per day for 367 days","Newest 99999999999999999999, plus one per day for 3 days","Newest -3, plus one per day for 3 days","Newest 3, plus one per day for 3 days and delete the rest","Please: Newest 3, plus one per day for 3 days"] {
            XCTAssertNil(StorageBackupRetentionPolicy.stated(in:text),text)
        }
    }

    func testOwnerAnswerConfirmsRuleWithProvenanceAndReplayIsSafe() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        let r = try request(f,p,c,labels:[label,"Keep everything"]),rid = r["id"] as! String,response = try answer(f,r)
        let command = UUID().uuidString.lowercased()
        let reply = try apply(f,p,c,request:rid,response:response,command:command),data = reply["data"] as! JSON
        XCTAssertEqual(data["newest_count"] as? Int,3);XCTAssertEqual(data["daily_days"] as? Int,3)
        XCTAssertEqual(data["request_id"] as? String,rid);XCTAssertEqual(data["response_id"] as? String,response)
        XCTAssertEqual(data["already_applied"] as? Bool,false)
        let current = try settings(f),confirmation = try XCTUnwrap(current["owner_confirmation"] as? JSON)
        XCTAssertEqual(current["newest_count"] as? Int,3);XCTAssertEqual(current["daily_days"] as? Int,3)
        XCTAssertEqual(current["automatic_prune"] as? Bool,true);XCTAssertEqual(current["owner_confirmed"] as? Bool,true)
        XCTAssertEqual(confirmation["source"] as? String,"owner_answer");XCTAssertEqual(confirmation["request_id"] as? String,rid)
        XCTAssertEqual(confirmation["response_id"] as? String,response);XCTAssertEqual(confirmation["principal"] as? String,c.principal)
        XCTAssertTrue(try StorageAutomaticBackupRetention.isConfirmed(current,root:f.root,incarnation:f.router!.incarnation))
        XCTAssertFalse(try StorageAutomaticBackupRetention.isConfirmed(current,root:f.workspace,incarnation:f.router!.incarnation))
        // The same command returns its receipt; a new command changes nothing.
        XCTAssertEqual(try apply(f,p,c,request:rid,response:response,command:command)["replayed"] as? Bool,true)
        XCTAssertEqual((try apply(f,p,c,request:rid,response:response)["data"] as! JSON)["already_applied"] as? Bool,true)
        XCTAssertEqual((try settings(f)["owner_confirmation"] as? JSON)?["command_id"] as? String,command)
        let events = try f.router!.dbQueue.read {try Row.fetchAll($0,sql:"SELECT actor,project_id FROM events WHERE kind='backup_retention_answer_applied'")}
        XCTAssertEqual(events.count,1);XCTAssertEqual(events.first?["actor"] as String?,c.principal)
        let history = try XCTUnwrap(try settings(f)["automatic_prune_history"] as? [JSON])
        XCTAssertEqual(history.first?["status"] as? String,"rule_confirmed_from_answer");XCTAssertEqual(history.first?["request_id"] as? String,rid)
    }

    func testAnswersThatAreNotTheOwnersRuleAreRefused() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        // Agent origin.
        let agent = try request(f,p,c,labels:[label]),agentResponse = try answer(f,agent)
        try editRequest(f,agent) {stored in
            var responses = stored["responses"] as! [JSON];responses[0]["origin"] = "agent";stored["responses"] = responses
        }
        refused("response_not_from_owner") {_ = try self.apply(f,p,c,request:agent["id"] as! String,response:agentResponse)}
        // Incomplete response and unanswered request.
        let open = try request(f,p,c,labels:[label])
        refused("response_not_on_request") {_ = try self.apply(f,p,c,request:open["id"] as! String,response:agentResponse)}
        let partial = try request(f,p,c,labels:[label]),partialResponse = try answer(f,partial)
        try editRequest(f,partial) {stored in
            var responses = stored["responses"] as! [JSON];responses[0]["complete"] = false;stored["responses"] = responses
        }
        refused("answer_not_complete") {_ = try self.apply(f,p,c,request:partial["id"] as! String,response:partialResponse)}
        // Label that states no rule, and a label out of bounds.
        for text in ["Keep a few backups","Newest 0, plus one per day for 3 days"] {
            let r = try request(f,p,c,labels:[text]),response = try answer(f,r)
            refused("no_rule_in_answer") {_ = try self.apply(f,p,c,request:r["id"] as! String,response:response)}
        }
        // The agent cannot supply numbers.
        let good = try request(f,p,c,labels:[label]),goodResponse = try answer(f,good)
        XCTAssertThrowsError(try apply(f,p,c,request:good["id"] as! String,response:goodResponse,extra:["newest_count":1,"daily_days":0])) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
        // A response from another request.
        let other = try request(f,p,c,labels:[label])
        refused("response_not_on_request") {_ = try self.apply(f,p,c,request:other["id"] as! String,response:goodResponse)}
        XCTAssertEqual(try settings(f)["owner_confirmed"] as? Bool,false)
        XCTAssertEqual(try settings(f)["newest_count"] as? Int,5)
    }

    func testRequestInAnotherProjectIsRefused() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        let otherRoot = f.base.appendingPathComponent("other-workspace",isDirectory:true)
        try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
        let second = try f.call("project_create",["name":"Other fixture","key_prefix":"OF","root_path":otherRoot.path])["data"] as! JSON
        _ = try f.call("epic_create",["project_id":second["id"]!,"name":"Other tickets"])
        let otherWorker = try worker(f,second,workspace:otherRoot)
        let r = try request(f,second,otherWorker,labels:[label]),response = try answer(f,r)
        refused("request_not_in_project") {_ = try self.apply(f,p,c,request:r["id"] as! String,response:response)}
        XCTAssertThrowsError(try apply(f,second,c,request:r["id"] as! String,response:response))
        XCTAssertEqual(try settings(f)["owner_confirmed"] as? Bool,false)
    }

    func testAppliedRuleMovesOldBackupToFixtureTrashAndKeepsPins() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        let old = try snapshot(f,"old"),pinned = try snapshot(f,"pinned")
        try age(f,old);try age(f,pinned)
        _ = try f.call("backup_pin",["path":pinned["path"]!,"pinned":true])
        let r = try request(f,p,c,labels:["Newest 1, plus one per day for 1 day"]),response = try answer(f,r)
        _ = try apply(f,p,c,request:r["id"] as! String,response:response)
        // Applying the rule moves no files.
        XCTAssertTrue(FileManager.default.fileExists(atPath:old["path"] as! String))
        let latest = try snapshot(f,"new")
        XCTAssertEqual(latest["status"] as? String,"complete")
        XCTAssertFalse(FileManager.default.fileExists(atPath:old["path"] as! String))
        XCTAssertTrue(FileManager.default.fileExists(atPath:pinned["path"] as! String))
        XCTAssertTrue(FileManager.default.fileExists(atPath:latest["path"] as! String))
        let last = try XCTUnwrap(try settings(f)["last_automatic_prune"] as? JSON)
        XCTAssertEqual(last["status"] as? String,"complete");XCTAssertEqual(last["moved_count"] as? Int,1)
        let entry = try XCTUnwrap((last["moved_to_trash"] as? [JSON])?.first)
        XCTAssertTrue((entry["trash_path"] as? String)?.hasPrefix(f.workspace.path + "/") == true)
    }

    func testOwnerSaveReplacesRuleAndAnOlderAnswerCannotComeBack() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        let first = try request(f,p,c,labels:[label]),firstResponse = try answer(f,first)
        _ = try apply(f,p,c,request:first["id"] as! String,response:firstResponse)
        let unused = try request(f,p,c,labels:["Newest 9, plus one per day for 9 days"]),unusedResponse = try answer(f,unused)
        Thread.sleep(forTimeInterval:1.1)
        _ = try f.call("backup_retention_set",["newest_count":7,"daily_days":2])
        var current = try settings(f)
        XCTAssertEqual(current["newest_count"] as? Int,7)
        XCTAssertEqual((current["owner_confirmation"] as? JSON)?["source"] as? String,"authenticated_app")
        refused("newer_rule_exists") {_ = try self.apply(f,p,c,request:first["id"] as! String,response:firstResponse)}
        refused("newer_rule_exists") {_ = try self.apply(f,p,c,request:unused["id"] as! String,response:unusedResponse)}
        current = try settings(f);XCTAssertEqual(current["newest_count"] as? Int,7)
        // A later answer is the owner's newest decision.
        Thread.sleep(forTimeInterval:1.1)
        let later = try request(f,p,c,labels:["Other"]),laterResponse = try answer(f,later,option:nil,custom:"Newest 4, plus one per day for 2 days")
        _ = try apply(f,p,c,request:later["id"] as! String,response:laterResponse)
        current = try settings(f)
        XCTAssertEqual(current["newest_count"] as? Int,4);XCTAssertEqual(current["daily_days"] as? Int,2)
        XCTAssertEqual((current["owner_confirmation"] as? JSON)?["response_id"] as? String,laterResponse)
    }

    func testAnswerAppliedInAnotherInstallationDoesNotCarryOver() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        let r = try request(f,p,c,labels:[label]),response = try answer(f,r)
        _ = try apply(f,p,c,request:r["id"] as! String,response:response)
        try f.router!.dbQueue.write {db in
            var stored = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='backup-retention-settings'")))
            var confirmation = stored["owner_confirmation"] as! JSON;confirmation["source_root"] = "/other/store";stored["owner_confirmation"] = confirmation
            try db.execute(sql:"UPDATE metadata SET value=? WHERE key='backup-retention-settings'",arguments:[try jsonString(stored)])
        }
        refused("answer_from_other_installation") {_ = try self.apply(f,p,c,request:r["id"] as! String,response:response)}
        XCTAssertEqual(try settings(f)["automatic_prune"] as? Bool,false)
    }

    func testAgentsCannotUseOwnerCommandsAndAssistantsCannotApply() throws {
        let f = try fixture(),p = try f.project(),c = try worker(f,p)
        for (method,params) in [("backup_retention_set",["newest_count":1,"daily_days":0] as JSON),("backup_pin",["path":"/x","pinned":true]),("backup_prune",["preview_sha256":String(repeating:"0",count:64)]),("backup_retention_get",[:]),("backup_prune_preview",[:])] {
            XCTAssertThrowsError(try f.call(method,params,caller:c),method)
        }
        let tools = f.router!.toolCatalog(c),names = Set(tools.compactMap {$0["name"] as? String})
        XCTAssertTrue(names.contains("backup_retention_apply_answer"))
        XCTAssertTrue(names.isDisjoint(with:CommandRouter.storageBackupPruningMethods))
        let entry = try XCTUnwrap(tools.first {$0["name"] as? String == "backup_retention_apply_answer"}),schema = entry["inputSchema"] as! JSON
        XCTAssertEqual(Set(schema["required"] as! [String]),["project_id","command_id","request_id","response_id"])
        XCTAssertNil((schema["properties"] as! JSON)["newest_count"]);XCTAssertNil((schema["properties"] as! JSON)["daily_days"])
        let assistant = Caller(role:"assistant",installation:"retention-answer-test",projectIDs:[p["id"] as! String])
        XCTAssertFalse(f.router!.toolCatalog(assistant).contains {$0["name"] as? String == "backup_retention_apply_answer"})
        XCTAssertThrowsError(try f.call("backup_retention_apply_answer",["project_id":p["id"]!,"request_id":UUID().uuidString,"response_id":UUID().uuidString],caller:assistant))
    }
}
