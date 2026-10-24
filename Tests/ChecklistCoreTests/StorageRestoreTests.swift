import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class StorageRestoreTests: XCTestCase {
    private func worker(_ f: StorageFixture,_ project: JSON) throws -> Caller {
        let session = try f.call("session_register",["project_id":project["id"]!,"label":"Backup fixture worker","provider":"codex","role":"worker","installation":"restore-test","workspace":f.workspace.path])["data"] as! JSON
        return Caller(role:"worker",installation:"restore-test",projectIDs:[project["id"] as! String],sessionID:session["id"] as? String,workspace:f.workspace.path)
    }
    private func backup(_ f: StorageFixture) throws -> URL {
        let url = f.base.appendingPathComponent("snapshot")
        _ = try f.call("backup_create",["path":url.path])
        return url
    }
    private func preview(_ f: StorageFixture,_ url: URL) throws -> JSON {
        try f.call("restore_preview",["path":url.path])["data"] as! JSON
    }
    private func restore(_ f: StorageFixture,_ url: URL,command: String = UUID().uuidString) throws -> JSON {
        let p = try preview(f,url)
        return try f.call("restore_create",["path":url.path,"manifest_sha256":p["manifest_sha256"]!],command:command)
    }
    func testAgentBackupIsConstrainedVerifiedIdempotentAndAttributed() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),c = try worker(f,p)
        let original = f.workspace.appendingPathComponent("file.bin");try Data([1,2,3]).write(to:original)
        _ = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":original.path])
        let command = UUID().uuidString,input: JSON = ["project_id":p["id"]!,"qualification_name":"round29","reason":"Qualification"]
        let first = try f.call("backup_create",input,command:command,caller:c),result = first["data"] as! JSON
        let destination = URL(fileURLWithPath:result["path"] as! String)
        XCTAssertTrue(destination.path.hasPrefix(f.root.appendingPathComponent("backups/qualification-round29").path + "/"))
        let files = try StorageObjectFiles(root:destination)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        XCTAssertEqual(manifest.recordFamilies?["attachment"],1)
        XCTAssertEqual(Set(manifest.recordFamilies!.keys),Set(EnvelopeFamily.catalog.keys))
        XCTAssertGreaterThan(manifest.tableRows?["events"] ?? 0,0)
        _ = try StorageSnapshot.verify(files,operation:UUID(uuidString:manifest.operationID)!,budget:.production())
        XCTAssertEqual(try f.call("backup_create",input,command:command,caller:c)["replayed"] as? Bool,true)
        try f.router!.dbQueue.read {db in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT actor,data FROM events WHERE kind='backup_created'"))
            XCTAssertEqual(row["actor"] as String,c.principal)
            XCTAssertEqual(jsonObject(row["data"])["origin"] as? String,"agent")
        }
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!,"path":f.base.appendingPathComponent("escape").path],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT")}
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!,"qualification_name":"../escape"],caller:c))
        let link = f.root.appendingPathComponent("backups/qualification-escape")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:f.workspace)
        let refusedCommand = uuid()
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!,"qualification_name":"escape"],command:refusedCommand,caller:c))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent("snapshot-" + refusedCommand).path))
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[p["id"] as! String])
        XCTAssertThrowsError(try f.call("backup_create",["project_id":p["id"]!],caller:assistant)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        try f.router!.dbQueue.write {db in
            var project = try f.router!.record(db,p["id"] as! String,type:"project"),policy = project["policy"] as! JSON
            policy["agent_rule_changes"] = "owner_only";project["policy"] = policy;try f.router!.save(db,project,type:"project")
        }
        XCTAssertThrowsError(try f.call("backup_create",input,caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")}
    }
    func testRestoreKeepsRecordsAndFilesButFencesSessionsClaimsCursorsAndDeliveries() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),c = try worker(f,p),router = f.router!
        let pid = p["id"] as! String,tid = t["id"] as! String
        let source = f.workspace.appendingPathComponent("original.bin"),bytes = Data([8,7,6]);try bytes.write(to:source)
        let attachment = try f.call("attachment_add",["project_id":pid,"task_id":tid,"path":source.path])["data"] as! JSON
        let ready = try f.call("task_edit",["project_id":pid,"task_id":tid,"expected_revision":t["revision"]!,"patch":["brief":"Preserve work","readiness":"ready"]])["data"] as! JSON
        let claimed = try f.call("work_claim",["project_id":pid,"task_id":tid,"expected_revision":ready["revision"]!,"policy_revision":p["policy_revision"]!,"phase":"implementation","file_scopes":[],"lane_scopes":[]],caller:c)["data"] as! JSON
        let note = try f.call("message_send",["project_id":pid,"task_id":tid,"body":"Pending at snapshot","kind":"note","recipient":["kind":"session","session_id":c.sessionID!]])
        let cursor = try f.call("project_list")["event_cursor"] as! String
        let originalIncarnation = router.incarnation
        let url = try backup(f),command = UUID().uuidString
        let restored = try restore(f,url,command:command)["data"] as! JSON
        let target = URL(fileURLWithPath:restored["path"] as! String)
        XCTAssertNotEqual(restored["store_incarnation"] as? String,originalIncarnation)
        XCTAssertEqual(router.incarnation,originalIncarnation)
        XCTAssertEqual(try f.call("task_get",["project_id":pid,"task_id":tid])["data"] as? JSON != nil,true)
        let lease = try StorageServiceLease(root:target),copy = try CommandRouter(root:target,serviceLease:lease)
        defer {try? copy.closeStore()}
        let sid = c.sessionID!,aid = claimed["id"] as! String
        try copy.dbQueue.read {db in
            let session = try copy.record(db,sid,type:"session")
            XCTAssertEqual(session["state"] as? String,"revoked");XCTAssertTrue(bool(session,"restore_quarantined"))
            let attempt = try copy.record(db,aid,type:"attempt")
            XCTAssertTrue(bool(attempt,"recovery_required"));XCTAssertNil(attempt["token_hash"])
            XCTAssertEqual(attempt["state"] as? String,"active") // A restore never proves external writers stopped.
            for delivery in try copy.records(db,type:"delivery") {
                XCTAssertEqual(delivery["state"] as? String,"quarantined")
                XCTAssertFalse(try copy.deliveryCurrent(db,delivery))
            }
            let a = try copy.record(db,attachment["id"] as! String,type:"attachment")
            let path = try XCTUnwrap(ManagedPaths.resolve(a["path"] as! String,family:"objects",root:target))
            XCTAssertEqual(try Data(contentsOf:path),bytes)
            XCTAssertEqual(try copy.records(db,type:"message").count,1)
            XCTAssertNotNil(note["data"])
            XCTAssertThrowsError(try copy.claimAttempt(db,["attempt_id":aid,"claim_token":claimed["claim_token"]!],c,pid)) {XCTAssertEqual(($0 as? CoreError)?.code,"STALE_CLAIM")}
        }
        XCTAssertThrowsError(try copy.handle(method:"changes_wait",params:["cursor":cursor],caller:f.owner)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        XCTAssertThrowsError(try copy.handle(method:"task_get",params:["project_id":pid,"task_id":tid],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"CONNECTION_REVOKED")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("connections.json").path))
        try FileManager.default.removeItem(at:url)
        let replay = try f.call("restore_create",["path":url.path,"manifest_sha256":restored["manifest_sha256"]!],command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
    }
    func testCorruptChecksumUnsupportedSchemaAndChangedPreviewNeverPublish() throws {
        for scenario in ["checksum","schema","preview","missing","object","family","table"] {
            let f = try StorageFixture(),p = try f.project();_ = try f.task(p)
            if scenario == "object" {
                let source = f.workspace.appendingPathComponent("original");try Data([4,5,6]).write(to:source)
                let t = try f.task(p)
                _ = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])
            }
            let url = try backup(f),preview = try preview(f,url),rootHash = try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
            if scenario == "object" {
                let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:url.appendingPathComponent("manifest.json")))
                try Data([0]).write(to:url.appendingPathComponent("managed/" + manifest.objects[0].descriptor.relativePath))
            }
            if ["family","table"].contains(scenario) {
                let file = url.appendingPathComponent("manifest.json")
                var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! JSON
                manifest[scenario == "family" ? "recordFamilies" : "tableRows"] = ["task":999]
                try JSONSerialization.data(withJSONObject:manifest).write(to:file)
            }
            if scenario == "checksum" {try Data([0]).write(to:url.appendingPathComponent("database.sqlite"))}
            if scenario == "schema" {
                let file = url.appendingPathComponent("manifest.json");var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! JSON
                manifest["schema"] = 99;try JSONSerialization.data(withJSONObject:manifest).write(to:file)
            }
            if scenario == "missing" {try FileManager.default.removeItem(at:url.appendingPathComponent("intent.json"))}
            XCTAssertThrowsError(try f.call("restore_create",["path":url.path,"manifest_sha256":scenario == "preview" ? String(repeating:"0",count:64) : preview["manifest_sha256"]!]))
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("restore").path))
            XCTAssertEqual(try f.router!.dbQueue.read {try SchemaMigrations.contentFingerprint($0)},rootHash)
        }
    }
    func testInterruptedCandidateRetryAndUncertainPublicationReconcileOriginalIntent() throws {
        for event in ["restore_before_publish","restore_published_before_flush"] {
            let f = try StorageFixture(),p = try f.project();_ = try f.task(p)
            let source = try backup(f),preview = try preview(f,source),command = uuid()
            let params: JSON = ["command_id":command,"path":source.path,"manifest_sha256":preview["manifest_sha256"]!]
            var budget = StorageSnapshotBudget.production()
            budget.observe = {if $0 == event {throw StorageSnapshotFailure.canceled}}
            XCTAssertThrowsError(try f.router!.executeStorageRestore(method:"restore_create",params:params,caller:f.owner,budget:budget)) {
                XCTAssertEqual(($0 as? CoreError)?.code,event == "restore_before_publish" ? "RESTORE_INVALID_BACKUP" : "OUTCOME_UNKNOWN")
            }
            let reply = try f.router!.handle(method:"restore_create",params:params,caller:f.owner)["data"] as! JSON
            XCTAssertEqual(reply["status"] as? String,"complete")
            let contents = try FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("restore").path)
            XCTAssertEqual(contents.filter {$0.hasPrefix("restored-")}.count,1)
            if event == "restore_before_publish" {XCTAssertEqual(contents.filter {$0.hasPrefix(".restore-incomplete-")}.count,1)}
            try f.reopen()
            XCTAssertEqual(try f.router!.handle(method:"restore_create",params:params,caller:f.owner)["replayed"] as? Bool,true)
        }
    }
    func testUncertainRestoreCannotReconcileCorruptedPublishedCandidate() throws {
        let f = try StorageFixture();_ = try f.project()
        let source = try backup(f),preview = try preview(f,source),command = uuid()
        let params: JSON = ["command_id":command,"path":source.path,"manifest_sha256":preview["manifest_sha256"]!]
        var budget = StorageSnapshotBudget.production()
        budget.observe = {if $0 == "restore_published_before_flush" {throw StorageSnapshotFailure.canceled}}
        XCTAssertThrowsError(try f.router!.executeStorageRestore(method:"restore_create",params:params,caller:f.owner,budget:budget))
        let parent = f.root.appendingPathComponent("restore")
        let candidate = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil).first {$0.lastPathComponent.hasPrefix("restored-")})
        try Data([0]).write(to:candidate.appendingPathComponent("checklist.sqlite"))
        XCTAssertThrowsError(try f.router!.handle(method:"restore_create",params:params,caller:f.owner))
        XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command])},0)
    }
    func testMediaHistoryAndManagedRepresentationsRestoreExactlyAcrossRestart() throws {
        let f = try MediaBackupTests().captured(),source = f.base.appendingPathComponent("restore-media-source")
        _ = try f.router.handle(method:"backup_create",params:["path":source.path,"command_id":uuid()],caller:f.owner)
        let preview = try f.router.handle(method:"restore_preview",params:["path":source.path],caller:f.owner)["data"] as! JSON
        let reply = try f.router.handle(method:"restore_create",params:["path":source.path,"manifest_sha256":preview["manifest_sha256"]!,"command_id":uuid()],caller:f.owner)["data"] as! JSON
        let root = URL(fileURLWithPath:reply["path"] as! String)
        let lease = try StorageServiceLease(root:root),copy = try CommandRouter(root:root,serviceLease:lease)
        try f.router.dbQueue.read {original in try copy.dbQueue.read {db in
            let query = "SELECT id,type,revision,data FROM records WHERE type LIKE 'media_%' OR type IN ('attachment','storage_hold') ORDER BY id"
            XCTAssertEqual(try Row.fetchAll(original,sql:query),try Row.fetchAll(db,sql:query))
            for attachment in try copy.records(db,type:"attachment") {
                let originalURL = try f.router.managedURL(attachment["path"] as! String,family:"objects")
                XCTAssertEqual(try Data(contentsOf:copy.managedURL(attachment["path"] as! String,family:"objects")),try Data(contentsOf:originalURL))
            }
        }}
        try copy.closeStore()
        let reopened = try CommandRouter(root:root,serviceLease:lease);defer {try? reopened.closeStore()}
        XCTAssertEqual(reopened.incarnation,reply["store_incarnation"] as? String)
    }
    func testRestoreIsAbsentFromWorkerCatalogAndRefusesNonOwner() throws {
        let f = try StorageFixture(),p = try f.project(),c = try worker(f,p)
        let catalog = f.router!.toolCatalog(c).compactMap {$0["name"] as? String}
        XCTAssertTrue(catalog.contains("backup_create"));XCTAssertFalse(catalog.contains("restore_create"));XCTAssertFalse(catalog.contains("restore_preview"))
        for method in ["restore_preview","restore_create"] {
            XCTAssertThrowsError(try f.call(method,["project_id":p["id"]!,"path":"/unused"],caller:c)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        }
    }
}
