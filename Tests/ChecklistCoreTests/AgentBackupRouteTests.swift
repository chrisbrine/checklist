import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class AgentBackupRouteTests: XCTestCase {
    private func worker(_ f: StorageFixture,_ project: JSON) throws -> Caller {
        let session = try f.call("session_register",["project_id":project["id"]!,"label":"Agent backup test","provider":"codex","role":"worker","installation":"agent-backup-test","workspace":f.workspace.path])["data"] as! JSON
        return Caller(role:"worker",installation:"agent-backup-test",projectIDs:[project["id"] as! String],sessionID:session["id"] as? String,workspace:f.workspace.path)
    }

    func testAllowedAgentBackupPublishesVerifiedSnapshotWithAgentProvenance() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p),command = UUID().uuidString
        let reply = try f.call("backup_create",["project_id":p["id"]!,"reason":"Core route acceptance"],command:command,caller:c)
        let data = reply["data"] as! JSON,destination = URL(fileURLWithPath:data["path"] as! String)
        XCTAssertEqual(destination.path,f.root.appendingPathComponent("backups/snapshot-" + command.lowercased()).path)
        XCTAssertEqual(data["status"] as? String,"complete")
        let files = try StorageObjectFiles(root:destination)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        let verified = try StorageSnapshot.verify(files,operation:UUID(uuidString:manifest.operationID)!,budget:.production())
        XCTAssertEqual(verified,data["manifest_sha256"] as? String)
        try f.router!.dbQueue.read {db in
            let event = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT actor,data FROM events WHERE kind='backup_created'"))
            XCTAssertEqual(event["actor"] as String,c.principal)
            XCTAssertEqual(jsonObject(event["data"])["origin"] as? String,"agent")
            XCTAssertEqual(jsonObject(event["data"])["session_id"] as? String,c.sessionID)
        }
    }

    func testBackupHistoryScopesProvenancePaginationAndCurrentGrants() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p),pid = p["id"] as! String
        let command = UUID().uuidString
        let first = try f.call("backup_create",["project_id":pid],command:command,caller:c)["data"] as! JSON
        let ownerCommand = UUID().uuidString
        let second = try f.call("backup_create",["path":f.base.appendingPathComponent("owner-backup").path],command:ownerCommand)["data"] as! JSON
        let input: JSON = ["project_id":pid,"entity":"backup","limit":1]
        let page = try f.call("history_list",input,caller:c)["data"] as! JSON
        let agentEvent = try XCTUnwrap((page["events"] as! [JSON]).first)
        let agent = agentEvent["data"] as! JSON
        XCTAssertEqual(agentEvent["actor"] as? String,c.principal)
        XCTAssertEqual(agent["origin"] as? String,"agent")
        XCTAssertEqual(agent["session_id"] as? String,c.sessionID)
        XCTAssertEqual(agent["command_id"] as? String,command)
        XCTAssertEqual(agent["operation_id"] as? String,first["operation_id"] as? String)
        XCTAssertEqual(agent["manifest_sha256"] as? String,first["manifest_sha256"] as? String)
        for key in ["captured_at","verified_at"] { XCTAssertNotNil(agent[key] as? String) }
        XCTAssertNotNil(agentEvent["occurred_at"] as? String)
        XCTAssertEqual(page["has_more"] as? Bool,true)
        let next = try f.call("history_list",["project_id":pid,"entity":"backup","cursor":page["next_cursor"]!,"limit":1],caller:c)["data"] as! JSON
        let ownerEvent = try XCTUnwrap((next["events"] as! [JSON]).first),owner = ownerEvent["data"] as! JSON
        XCTAssertEqual(ownerEvent["actor"] as? String,f.owner.principal)
        XCTAssertEqual(owner["origin"] as? String,"human_ui")
        XCTAssertEqual(owner["session_id"] as? String,"")
        XCTAssertEqual(owner["command_id"] as? String,ownerCommand)
        XCTAssertEqual(owner["operation_id"] as? String,second["operation_id"] as? String)
        XCTAssertEqual(owner["manifest_sha256"] as? String,second["manifest_sha256"] as? String)
        for key in ["captured_at","verified_at"] { XCTAssertNotNil(owner[key] as? String) }
        XCTAssertEqual(next["has_more"] as? Bool,false)
        XCTAssertTrue((next["messages"] as! [JSON]).isEmpty)
        for data in [agent,owner] { for key in ["project_ids","path","source_root","store_id"] {XCTAssertNil(data[key])} }
        _ = try f.call("backup_create",["project_id":pid],command:command,caller:c)
        XCTAssertEqual(((try f.call("history_list",["project_id":pid,"entity":"backup"],caller:c)["data"] as! JSON)["events"] as! [JSON]).count,2)

        let workspace = f.base.appendingPathComponent("later-workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let later = try f.call("project_create",["name":"After snapshot","key_prefix":"LATE","root_path":workspace.path])["data"] as! JSON
        let laterID = later["id"] as! String
        XCTAssertTrue(((try f.call("history_list",["project_id":laterID,"entity":"backup"])["data"] as! JSON)["events"] as! [JSON]).isEmpty)
        let denied = Caller(role:"worker",installation:c.installation,projectIDs:[],sessionID:c.sessionID,workspace:f.workspace.path)
        let assistant = Caller(role:"assistant",installation:"backup-reader",projectIDs:[pid],assistantGrants:[pid:["read":true]])
        for caller in [denied,assistant] {
            XCTAssertThrowsError(try f.call("history_list",["project_id":pid,"entity":"backup"],caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        }
        XCTAssertThrowsError(try f.call("history_list",["project_id":laterID,"entity":"backup"],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        XCTAssertThrowsError(try f.call("history_list",["project_id":pid,"entity":"project","cursor":page["next_cursor"]!],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        XCTAssertThrowsError(try f.call("history_list",["project_id":pid,"entity":"backup","cursor":page["next_cursor"]!])) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
    }

    func testOwnerBackupHistoryUsesCapturedMembershipWhenProjectAppearsBeforeCompletion() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p),pid = p["id"] as! String
        var laterID: String?
        var budget = StorageSnapshotBudget.production()
        budget.observe = {phase in
            if phase == "manifest_written" {
                let workspace = f.base.appendingPathComponent("concurrent-project")
                try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
                laterID = (try f.call("project_create",["name":"During backup","key_prefix":"DUR","root_path":workspace.path])["data"] as! JSON)["id"] as? String
            }
        }
        _ = try f.router!.executeStorageBackup(params:["command_id":UUID().uuidString,"path":f.base.appendingPathComponent("owner-concurrent").path],caller:f.owner,budget:budget)
        let later = try XCTUnwrap(laterID)
        let captured = (try f.call("history_list",["project_id":pid,"entity":"backup"],caller:c)["data"] as! JSON)["events"] as! [JSON]
        XCTAssertEqual(captured.count,1)
        let excluded = (try f.call("history_list",["project_id":later,"entity":"backup"])["data"] as! JSON)["events"] as! [JSON]
        XCTAssertTrue(excluded.isEmpty)
    }

    func testLegacyAgentBackupHistoryHydratesRetainedReceiptWithoutGuessingOwnerScope() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p),pid = p["id"] as! String,command = UUID().uuidString
        _ = try f.call("backup_create",["project_id":pid],command:command,caller:c)
        _ = try f.call("backup_create",["path":f.base.appendingPathComponent("legacy-owner").path])
        try f.router!.dbQueue.write {db in
            for row in try Row.fetchAll(db,sql:"SELECT id,data FROM events WHERE kind='backup_created'") {
                var data = jsonObject(row["data"])
                for key in ["command_id","captured_at","verified_at","project_ids"] {data.removeValue(forKey:key)}
                try db.execute(sql:"UPDATE events SET data=? WHERE id=?",arguments:[try jsonString(data),row["id"] as String])
            }
        }
        let events = (try f.call("history_list",["project_id":pid,"entity":"backup"],caller:c)["data"] as! JSON)["events"] as! [JSON]
        XCTAssertEqual(events.count,1)
        let data = try XCTUnwrap(events.first?["data"] as? JSON)
        XCTAssertEqual(data["command_id"] as? String,command)
        XCTAssertNotNil(data["captured_at"] as? String);XCTAssertNotNil(data["verified_at"] as? String)
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"UPDATE commands SET result='{}' WHERE command_id=?",arguments:[command])
            try db.execute(sql:"DELETE FROM metadata WHERE key GLOB 'backup-generation:*'")
        }
        let retained = (try f.call("history_list",["project_id":pid,"entity":"backup"],caller:c)["data"] as! JSON)["events"] as! [JSON]
        XCTAssertEqual(retained.count,1)
        XCTAssertNil((retained[0]["data"] as! JSON)["command_id"])
        XCTAssertNil((retained[0]["data"] as! JSON)["captured_at"])
    }

    func testAgentBackupRefusesOwnerOnlyProjectPolicyWithoutPublishing() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p)
        try f.router!.dbQueue.write {db in
            var project = try f.router!.record(db,p["id"] as! String,type:"project"),policy = project["policy"] as! JSON
            policy["agent_rule_changes"] = "owner_only";project["policy"] = policy;try f.router!.save(db,project,type:"project")
        }
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
    }

    func testAgentBackupRefusesAssistantCallerWithoutPublishing() throws {
        let f = try StorageFixture(),p = try f.project()
        let c = Caller(role:"assistant",installation:"agent-backup-assistant",projectIDs:[p["id"] as! String])
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
    }

    func testAgentBackupRefusesArbitraryAndEscapingDestinationsWithoutPublishing() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p)
        for input: JSON in [["path":f.base.appendingPathComponent("outside").path],["qualification_name":"../outside"]] {
            var params = input;params["project_id"] = p["id"]!
            XCTAssertThrowsError(try f.call("backup_create",params,caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("outside").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
    }

    func testAgentBackupKeepsCapturedGenerationWhileWorkerWritesDuringCopyAndVerification() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),c = try worker(f,p),router = f.router!
        let pid = p["id"] as! String,tid = t["id"] as! String,source = f.workspace.appendingPathComponent("concurrent.bin")
        let bytes = Data(repeating:23,count:32 * 1024);try bytes.write(to:source)
        let attachment = try f.call("attachment_add",["project_id":pid,"task_id":tid,"path":source.path],caller:c)["data"] as! JSON
        let copying = DispatchSemaphore(value:0),verifying = DispatchSemaphore(value:0),resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"Agent backup completes"),command = UUID().uuidString
        let destination = f.root.appendingPathComponent("backups/qualification-core-concurrent/snapshot-" + command.lowercased())
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            var budget = StorageSnapshotBudget.production()
            budget.observe = {event in
                if event == "copying_objects" || event == "manifest_written" {
                    (event == "copying_objects" ? copying : verifying).signal()
                    guard resume.wait(timeout:.now()+15) == .success else {throw StorageSnapshotFailure.canceled}
                }
            }
            do {
                let reply = try router.executeStorageBackup(params:["command_id":command,"project_id":pid,"qualification_name":"core-concurrent"],caller:c,budget:budget)
                XCTAssertEqual((reply["data"] as? JSON)?["status"] as? String,"complete")
            } catch {XCTFail("Agent backup: \(error)")}
        }
        defer {resume.signal();resume.signal()}
        XCTAssertEqual(copying.wait(timeout:.now()+15),.success)
        _ = try f.call("message_send",["project_id":pid,"task_id":tid,"body":"Core during copy","kind":"note"],caller:c)
        let edited = try f.call("task_edit",["project_id":pid,"task_id":tid,"expected_revision":t["revision"]!,"patch":["title":"Changed after capture"]],caller:c)["data"] as! JSON
        XCTAssertEqual(edited["title"] as? String,"Changed after capture")
        resume.signal()
        XCTAssertEqual(verifying.wait(timeout:.now()+15),.success)
        _ = try f.call("message_send",["project_id":pid,"task_id":tid,"body":"Core during verification","kind":"note"],caller:c)
        resume.signal();wait(for:[finished],timeout:30)
        let files = try StorageObjectFiles(root:destination)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        _ = try StorageSnapshot.verify(files,operation:UUID(uuidString:manifest.operationID)!,budget:.production())
        let object = try XCTUnwrap(manifest.objects.first {$0.descriptor.authorities.contains("attachment:" + (attachment["id"] as! String) + ":original")})
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("managed/" + object.descriptor.relativePath)),bytes)
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:config);defer {try? copy.close()}
        try copy.read {db in
            XCTAssertEqual(try router.record(db,tid,type:"task")["title"] as? String,t["title"] as? String)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message'"),0)
        }
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='message'")},2)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
    }
}
