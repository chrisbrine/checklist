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
        var budget = StorageSnapshotBudget.production()
        budget.observe = {event in
            if event == "copying_objects" || event == "manifest_written" {
                (event == "copying_objects" ? copying : verifying).signal()
                guard resume.wait(timeout:.now()+15) == .success else {throw StorageSnapshotFailure.canceled}
            }
        }
        DispatchQueue.global().async {
            defer {finished.fulfill()}
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
