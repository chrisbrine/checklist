import XCTest
import AppKit
import GRDB
@testable import ChecklistCore

final class ProjectImportTests: XCTestCase {
    private let format = "synthetic-board/1"
    private func source(_ f: StorageFixture,_ doc: JSON,name: String = "source") throws -> URL {
        let dir = f.workspace.appendingPathComponent(name);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:doc,options:.sortedKeys).write(to:dir.appendingPathComponent(doc["format"] as? String == "checklist-project" ? "project.json" : "bundle.json"));return dir
    }
    private func input(_ f: StorageFixture,_ p: JSON,_ dir: URL,format: String = "synthetic-board/1",namespace: String = "fixture") throws -> JSON {
        let router = f.router!,pid = p["id"] as! String
        let current = try router.dbQueue.read {try router.record($0,pid,type:"project")}
        let epic = try router.dbQueue.read {try router.records($0,type:"group",project:pid).first {$0["kind"] as? String == "epic"}!}
        return ["project_id":pid,"path":dir.path,"source_format":format,"source_namespace":namespace,"expected_revision":current["revision"]!,"epic_id":epic["id"]!]
    }
    private func commit(_ f: StorageFixture,_ params: JSON,command: String = UUID().uuidString) throws -> JSON {
        var p = params;let preview = try f.call("import_preview",p)["data"] as! JSON;p["preview_digest"] = preview["preview_digest"]
        return try f.call("import_commit",p,command:command)["data"] as! JSON
    }
    private func basic(_ items: [JSON] = [["id":"DEMO-1","title":"Synthetic","state":"queued"]]) -> JSON {["format":format,"meta":["exported_at":"2026-01-02T12:00:00Z"],"items":items,"events":[]]}
    func testSyntheticReadersAndAllFiveVerdictLayoutsRetainRawHistoryWithoutExecution() throws {
        let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples/legacy-import-plan.json")
        let fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! JSON
        let f = try StorageFixture()
        for row in fixtures["cases"] as! [JSON] where row["id"] as? String != "backup-selection" {
            var doc = row["input"] as! JSON
            if doc["format"] == nil {doc["format"] = format}
            let selected = doc["format"] as! String,dir = try source(f,doc,name:row["id"] as! String)
            let bundle = try TransferBundle.read(path:dir.path,format:selected,namespace:"synthetic")
            XCTAssertEqual(try jsonString(bundle.document),try jsonString(doc))
            if doc["events"] == nil {XCTAssertTrue(bundle.diagnostics.contains {$0["code"] as? String == "event_history_unavailable"})}
            if row["id"] as? String == "event-actions" {XCTAssertEqual(bundle.entries.filter {$0.family == "events"}.count,3);XCTAssertTrue(bundle.diagnostics.contains {$0["code"] as? String == "unresolved_relation"})}
            if row["id"] as? String == "note-substates" {XCTAssertEqual(bundle.diagnostics.filter {($0["code"] as? String ?? "").hasPrefix("unverified_note_hint:")}.count,7)}
            if row["id"] as? String == "media-review-store" {XCTAssertTrue(bundle.diagnostics.contains {$0["code"] as? String == "unknown_signature_algorithm"});XCTAssertTrue(bundle.files.contains {$0.availability == "unavailable_or_pruned"})}
        }
        let shapes = fixtures["verdict_shapes"] as! [JSON]
        var doc = basic();doc["verdict_exports"] = shapes.map {["format":$0["id"]!,"version":1,"payload":$0["input"]!]}
        doc["hooks"] = ["after_import":"touch SHOULD-NOT-EXIST"]
        let dir = try source(f,doc,name:"verdicts"),bundle = try TransferBundle.read(path:dir.path,format:format,namespace:"synthetic")
        XCTAssertEqual(bundle.entries.filter {$0.family == "verdict_exports"}.count,6)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("SHOULD-NOT-EXIST").path))
        XCTAssertThrowsError(try TransferBundle.verdicts(["rounds":[]],shape:"single-verdict"))
        XCTAssertThrowsError(try TransferBundle.verdicts([],shape:"unknown"))
    }
    func testPreviewReportsCountsHashTimestampAliasesParkedTagsMissingFilesLongNotesAndHistoricalSessions() throws {
        let f = try StorageFixture(),p = try f.project()
        let long = String(repeating:"é long note ",count:2_000)
        var doc = basic([["id":"ONE","title":"One","state":"parked","parked_subtype":"Later","tags":["future"],"note":long,"depends_on":["missing"]],["id":"TWO","title":"Two","state":"parked","parked_subtype":"Ideas","tags":["future-two"]],["id":"THREE","title":"Three","state":"running","agent":"Owner","endpoint":"unix:/untrusted"]])
        doc["events"] = [["event_seq":1,"task":"ONE","body":"same"],["event_seq":2,"task":"ONE","body":"same"]];doc["work_packages"] = [["id":"pkg","Plan":"Keep","Kind":"Asset","Current":"A","Remaining":"B","Acceptance":["C"],"Evidence":"missing.txt","Limits":"D"]]
        let dir = try source(f,doc),params = try input(f,p,dir),before = try Data(contentsOf:dir.appendingPathComponent("bundle.json"))
        let preview = try f.call("import_preview",params)["data"] as! JSON
        XCTAssertEqual((preview["counts"] as! [String:Int])["events"],2);XCTAssertEqual((preview["source_sha256"] as! String).count,64)
        XCTAssertEqual(preview["source_time"] as? String,"2026-01-02T12:00:00Z")
        XCTAssertTrue((preview["status_proposals"] as! [String]).contains("parked:Later"));XCTAssertTrue((preview["status_proposals"] as! [String]).contains("parked:Ideas"))
        let codes = (preview["diagnostics"] as! [JSON]).compactMap {$0["code"] as? String}
        XCTAssertTrue(codes.contains("long_note_preserved"));XCTAssertTrue(codes.contains("historical_work_requires_reconciliation"));XCTAssertTrue(codes.contains("unresolved_relation"))
        _ = try commit(f,params)
        try f.router!.dbQueue.read {db in
            XCTAssertTrue(try f.router!.records(db,type:"attempt").isEmpty);XCTAssertTrue(try f.router!.records(db,type:"session").isEmpty)
            let tasks = try f.router!.records(db,type:"task",project:p["id"] as? String)
            XCTAssertEqual(tasks.first {$0["source_id"] as? String == "ONE"}?["imported_note"] as? String,long)
            let statuses = try f.router!.records(db,type:"status",project:p["id"] as? String).filter {($0["name"] as? String ?? "").hasPrefix("Imported parked:")}
            XCTAssertEqual(statuses.count,2);XCTAssertEqual(Set(statuses.compactMap {$0["category"] as? String}),["parked"])
            XCTAssertEqual(try f.router!.records(db,type:"tag",project:p["id"] as? String).count,2)
            XCTAssertEqual(try f.router!.records(db,type:"import_record").filter {$0["source_family"] as? String == "events"}.count,2)
        }
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("bundle.json")),before)
    }
    func testChangedSourceOrDestinationAndDuplicateIdentitiesRefuseAtomically() throws {
        for scenario in ["source","destination","duplicate","alias"] {
            let f = try StorageFixture(),p = try f.project()
            let doc = scenario == "duplicate" ? basic([["id":"A"],["id":"A"]]) : scenario == "alias" ? basic([["id":"A","aliases":["SAME"]],["id":"B","aliases":["same"]]]) : basic()
            let dir = try source(f,doc);var params = try input(f,p,dir)
            let preview = try f.call("import_preview",params)["data"] as! JSON;params["preview_digest"] = preview["preview_digest"]
            if scenario == "source" {var changed = doc;changed["events"] = [["event_seq":1,"body":"new"]];_ = try source(f,changed)}
            if scenario == "destination" {_ = try f.task(p)}
            let count = try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records")}
            XCTAssertThrowsError(try f.call("import_commit",params))
            XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records")},count)
        }
    }
    func testSameCommandAndNewCommandReplayRetainSeparateEqualTextEvents() throws {
        let f = try StorageFixture(),p = try f.project();var doc = basic()
        doc["events"] = [["event_seq":41,"body":"identical"],["event_seq":42,"body":"identical"]]
        let dir = try source(f,doc);var params = try input(f,p,dir)
        params["preview_digest"] = (try f.call("import_preview",params)["data"] as! JSON)["preview_digest"]
        let command = UUID().uuidString,first = try f.call("import_commit",params,command:command)
        try f.reopen()
        try FileManager.default.moveItem(at:dir,to:dir.appendingPathExtension("moved"))
        XCTAssertEqual(try f.call("import_commit",params,command:command)["replayed"] as? Bool,true)
        try FileManager.default.moveItem(at:dir.appendingPathExtension("moved"),to:dir)
        let second = try f.call("import_commit",params)["data"] as! JSON
        XCTAssertEqual(second["receipt_id"] as? String,(first["data"] as! JSON)["receipt_id"] as? String)
        XCTAssertEqual(second["source_replayed"] as? Bool,true)
        XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.records($0,type:"import_record").filter {$0["source_family"] as? String == "events"}.count},2)
    }
    func testRollbackRemovesOnlyUntouchedImportAndRefusesLaterNotes() throws {
        for changed in [false,true] {
            let f = try StorageFixture(),p = try f.project(),existing = try f.task(p)
            let dir = try source(f,basic()),result = try commit(f,input(f,p,dir)),rid = result["receipt_id"] as! String
            if changed {_ = try f.call("message_send",["project_id":p["id"]!,"task_id":existing["id"]!,"body":"Keep later work"])}
            let params: JSON = ["project_id":p["id"]!,"receipt_id":rid,"expected_revision":1]
            if changed {XCTAssertThrowsError(try f.call("import_rollback",params)) {XCTAssertEqual(($0 as? CoreError)?.code,"IMPORT_ROLLBACK_CHANGED")}}
            else {
                _ = try f.call("import_rollback",params)
                XCTAssertEqual(try f.router!.dbQueue.read {try f.router!.records($0,type:"task").count},1)
                XCTAssertEqual((try f.call("task_get",["project_id":p["id"]!,"task_id":existing["id"]!])["data"] as! JSON)["title"] as? String,existing["title"] as? String)
                XCTAssertEqual((try f.call("import_receipt_get",["project_id":p["id"]!,"receipt_id":rid])["data"] as! JSON)["state"] as? String,"rolled_back")
            }
        }
    }
    func testFullCanonicalRoundTripRetainsHistorySettingsMembershipIconAndFilesWithoutAuthority() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),pid = p["id"] as! String
        let bytes = Data([1,2,3,4]),file = f.workspace.appendingPathComponent("original.bin");try bytes.write(to:file)
        _ = try f.call("attachment_add",["project_id":pid,"task_id":t["id"]!,"path":file.path])
        _ = try f.call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Historical owner decision; never a fresh grant"])
        let image = NSImage(size:NSSize(width:32,height:32));image.lockFocus();NSColor.systemBlue.setFill();NSBezierPath(rect:NSRect(x:0,y:0,width:32,height:32)).fill();image.unlockFocus()
        let png = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!,icon = f.workspace.appendingPathComponent("icon.png");try png.write(to:icon)
        let current = try f.router!.dbQueue.read {try f.router!.record($0,pid,type:"project")}
        _ = try f.call("project_icon_import",["project_id":pid,"expected_revision":current["revision"]!,"path":icon.path])
        let export = f.workspace.appendingPathComponent("canonical")
        _ = try f.call("export_project",["project_id":pid,"path":export.path])
        var document = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        let sourceProject = document["project"] as! JSON
        document["session"] = [["id":"fake-host","project_id":pid,"revision":1,"role":"owner","endpoint":"unix:/fake","label":"You","state":"connected"]]
        document["review"] = [["id":"fake-review","verdict":"pass","reviewer":"You"]]
        document["finding"] = [["id":"finding","body":"Retain this finding"]]
        try JSONSerialization.data(withJSONObject:document,options:.sortedKeys).write(to:export.appendingPathComponent("project.json"))
        let result = try commit(f,input(f,p,export,format:"checklist-project/1",namespace:"canonical"))
        let rid = result["receipt_id"] as! String
        try f.router!.dbQueue.read {db in
            let archive = try f.router!.records(db,type:"import_record").filter {$0["import_receipt_id"] as? String == rid}
            let envelope = archive.first {$0["source_family"] as? String == "envelope"}!["payload"] as! JSON
            XCTAssertEqual(try jsonString(envelope),try jsonString(document))
            XCTAssertEqual(try jsonString((envelope["project"] as! JSON)["policy"]!),try jsonString(sourceProject["policy"]!))
            XCTAssertTrue(try f.router!.records(db,type:"session").isEmpty);XCTAssertTrue(try f.router!.records(db,type:"review").isEmpty)
            let imported = try f.router!.records(db,type:"attachment").first {$0["import_receipt_id"] as? String == rid}!
            XCTAssertEqual(try f.router!.managedRead(imported["path"] as! String,family:"objects",maximum:100),bytes)
            let importedProject = try f.router!.record(db,pid,type:"project")
            XCTAssertEqual(try f.router!.managedRead(importedProject["icon_path"] as! String,family:"icons",maximum:1_000_000),try Data(contentsOf:export.appendingPathComponent(sourceProject["icon_path"] as! String)))
            XCTAssertNotNil(try f.router!.records(db,type:"task").first {$0["import_receipt_id"] as? String == rid}?["epic_id"])
        }
        let second = f.workspace.appendingPathComponent("roundtrip");_ = try f.call("export_project",["project_id":pid,"path":second.path])
        let roundtrip = try TransferBundle.read(path:second.path,format:"checklist-project/1",namespace:"again")
        XCTAssertTrue(roundtrip.entries.contains {$0.family == "import_record" && ($0.payload["payload"] as? JSON)?["format"] as? String == "checklist-project"})
    }
    func testMalformedUnsupportedAndUncontainedFilesDoNotReadOrExecute() throws {
        let f = try StorageFixture(),p = try f.project();var doc = basic();doc["evidence"] = "../outside";doc["original"] = "/etc/passwd"
        let dir = try source(f,doc)
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("link"),withDestinationURL:f.workspace)
        doc["path"] = "link/outside";_ = try source(f,doc)
        let bundle = try TransferBundle.read(path:dir.path,format:format,namespace:"fixture")
        XCTAssertTrue(bundle.files.allSatisfy {$0.bytes == nil})
        XCTAssertThrowsError(try TransferBundle.read(path:dir.path,format:"guessed/1",namespace:"fixture"))
        _ = try source(f,["format":format,"items":"wrong shape"])
        XCTAssertThrowsError(try TransferBundle.read(path:dir.path,format:format,namespace:"fixture"))
        let assistant = Caller(role:"assistant",installation:"untrusted",projectIDs:[p["id"] as! String])
        XCTAssertThrowsError(try f.call("import_preview",input(f,p,dir),caller:assistant)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
    }
    func testCyclesAndChangedFileIdentityCannotCommitAndWrongProjectDigestRefuses() throws {
        let f = try StorageFixture(),p = try f.project()
        let cyclic = basic([["id":"A","depends_on":["B"]],["id":"B","depends_on":["A"]]])
        let dir = try source(f,cyclic),params = try input(f,p,dir)
        XCTAssertThrowsError(try commit(f,params)) {XCTAssertEqual(($0 as? CoreError)?.code,"RELATION_CYCLE")}
        XCTAssertTrue(try f.router!.dbQueue.read {try f.router!.records($0,type:"task").isEmpty})
        _ = try source(f,basic())
        let bundle = try TransferBundle.read(path:dir.path,format:format,namespace:"fixture")
        _ = try source(f,basic([["id":"changed"]]))
        XCTAssertThrowsError(try bundle.validateSource())
        var first = try input(f,p,dir)
        first["preview_digest"] = (try f.call("import_preview",first)["data"] as! JSON)["preview_digest"]
        let other = try f.call("project_create",["name":"Other synthetic destination","key_prefix":"OTHER"])["data"] as! JSON;first["project_id"] = other["id"]
        XCTAssertThrowsError(try f.call("import_commit",first))
    }

    func testOlderBackupZeroFamilyCountsAndImportedHistoryBackupRestore() throws {
        let f = try StorageFixture(),p = try f.project(),dir = try source(f,basic())
        let snapshot = f.base.appendingPathComponent("before-import")
        _ = try f.call("backup_create",["path":snapshot.path])
        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! JSON
        var counts = manifest["recordFamilies"] as! [String:Int];counts.removeValue(forKey:"import_record");counts.removeValue(forKey:"import_receipt");manifest["recordFamilies"] = counts
        try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:manifestURL)
        let operation = UUID(uuidString:manifest["operationID"] as! String)!
        _ = try StorageSnapshot.verify(StorageObjectFiles(root:snapshot),operation:operation,budget:.production())
        let imported = try commit(f,input(f,p,dir)),after = f.base.appendingPathComponent("after-import")
        _ = try f.call("backup_create",["path":after.path])
        let preview = try f.call("restore_preview",["path":after.path])["data"] as! JSON
        let restored = try f.call("restore_create",["path":after.path,"manifest_sha256":preview["manifest_sha256"]!])["data"] as! JSON
        let root = URL(fileURLWithPath:restored["path"] as! String),copy = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root));defer {try? copy.closeStore()}
        XCTAssertEqual(try copy.dbQueue.read {try copy.records($0,type:"import_receipt").first?["id"] as? String},imported["receipt_id"] as? String)
        XCTAssertEqual(try copy.dbQueue.read {try copy.records($0,type:"import_record").count},2)
    }

    func testWorkerImportUsesActualWorkspaceAndProjectPolicyWithoutImportingAuthority() throws {
        let f = try StorageFixture(),p = try f.project(),pid = p["id"] as! String
        let session = try f.call("session_register",["project_id":pid,"label":"Existing fixture worker","provider":"codex","role":"worker","installation":"import-worker","workspace":f.workspace.path])["data"] as! JSON
        let worker = Caller(role:"worker",installation:"import-worker",projectIDs:[pid],sessionID:session["id"] as? String,workspace:f.workspace.path)
        let dir = try source(f,basic()),params = try input(f,p,dir)
        let names = f.router!.toolCatalog(worker).compactMap {$0["name"] as? String}
        XCTAssertTrue(names.contains("import_preview"));XCTAssertTrue(names.contains("import_commit"))
        let preview = try f.call("import_preview",params,caller:worker)["data"] as! JSON
        var commit = params;commit["preview_digest"] = preview["preview_digest"]
        let result = try f.call("import_commit",commit,caller:worker)["data"] as! JSON
        let receipt = try f.call("import_receipt_get",["project_id":pid,"receipt_id":result["receipt_id"]!],caller:worker)["data"] as! JSON
        XCTAssertEqual(receipt["origin"] as? String,"agent");XCTAssertEqual(receipt["created_by"] as? String,worker.principal)
        var outside = params;outside["path"] = f.base.path
        XCTAssertThrowsError(try f.call("import_preview",outside,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"FILE_ACCESS_REQUIRED")}
        try f.router!.dbQueue.write {db in var project = try f.router!.record(db,pid,type:"project"),policy = project["policy"] as! JSON;policy["agent_rule_changes"] = "owner_only";project["policy"] = policy;try f.router!.save(db,project,type:"project")}
        XCTAssertThrowsError(try f.call("import_preview",params,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")}
    }

    func testMissingExportOriginalStaysExplicitlyUnavailableThroughExportAndBackup() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),pid = p["id"] as! String
        let original = f.workspace.appendingPathComponent("original.bin");try Data([9,8,7]).write(to:original)
        _ = try f.call("attachment_add",["project_id":pid,"task_id":t["id"]!,"path":original.path])
        let exported = f.workspace.appendingPathComponent("missing-original");_ = try f.call("export_project",["project_id":pid,"path":exported.path])
        let document = try JSONSerialization.jsonObject(with:Data(contentsOf:exported.appendingPathComponent("project.json"))) as! JSON
        let attachment = (document["attachment"] as! [JSON])[0]
        try FileManager.default.removeItem(at:exported.appendingPathComponent(attachment["path"] as! String))
        let result = try commit(f,input(f,p,exported,format:"checklist-project/1",namespace:"missing"))
        let imported = try f.router!.dbQueue.read {try f.router!.records($0,type:"attachment").first {$0["import_receipt_id"] as? String == result["receipt_id"] as? String}!}
        XCTAssertEqual(imported["availability"] as? String,"unavailable");XCTAssertNil(imported["path"])
        _ = try f.call("export_project",["project_id":pid,"path":f.workspace.appendingPathComponent("after-missing").path])
        _ = try f.call("backup_create",["path":f.base.appendingPathComponent("missing-backup").path])
    }

}
