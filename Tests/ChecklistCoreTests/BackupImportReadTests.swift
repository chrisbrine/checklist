import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

private final class BackupImportReadOperation: @unchecked Sendable {
    let run: () throws -> Void
    init(_ run: @escaping () throws -> Void) {self.run = run}
}

final class BackupImportReadTests: XCTestCase {
    private func fixture() throws -> (StorageFixture,JSON,JSON,JSON) {
        let f = try StorageFixture(fast:true),p = try f.project()
        let source = f.workspace.appendingPathComponent("synthetic-import")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["format":"synthetic-board/1","items":[["id":"DEMO-1","title":"Synthetic import","state":"queued"]],"events":[]]).write(to:source.appendingPathComponent("bundle.json"))
        let pid = p["id"] as! String
        let epic = try f.router!.dbQueue.read {try f.router!.records($0,type:"group",project:pid).first {$0["kind"] as? String == "epic"}!}
        var params: JSON = ["project_id":pid,"path":source.path,"source_format":"synthetic-board/1","source_namespace":"backup-read-fixture","expected_revision":p["revision"]!,"epic_id":epic["id"]!]
        params["preview_digest"] = (try f.call("import_preview",params)["data"] as! JSON)["preview_digest"]
        let receipt = try f.call("import_commit",params)["data"] as! JSON
        params.removeValue(forKey:"preview_digest")
        return (f,p,params,["project_id":pid,"receipt_id":receipt["receipt_id"]!])
    }
    private func worker(_ f: StorageFixture,_ p: JSON) throws -> Caller {
        let installation = "backup-import-worker",pid = p["id"] as! String
        let s = try f.call("session_register",["project_id":pid,"label":"Synthetic import reader","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path])["data"] as! JSON
        return Caller(role:"worker",installation:installation,projectIDs:[pid],sessionID:s["id"] as? String,workspace:f.workspace.path)
    }
    /// Exercise the public router under a real SQLite writer lease. Release even
    /// on a regression so a blocked read fails without stranding the test runner.
    private func duringCapture(_ router: CommandRouter,_ body: @escaping () throws -> Void) throws {
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),answered = DispatchSemaphore(value:0)
        let writer = expectation(description:"SQLite writer released"),reader = expectation(description:"reader finished")
        try router.backupWrites.beginCapture()
        defer {router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)}
        let operation = BackupImportReadOperation(body)
        DispatchQueue.global().async {
            do {try router.dbQueue.writeWithoutTransaction {db in
                try db.execute(sql:"BEGIN IMMEDIATE")
                defer {try? db.execute(sql:"ROLLBACK")}
                entered.signal();_ = release.wait(timeout:.now()+10)
            }} catch {XCTFail("Writer lease failed: \(error)");entered.signal()}
            writer.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        DispatchQueue.global().async {
            do {try operation.run()} catch {XCTFail("Read failed: \(error)")}
            answered.signal();reader.fulfill()
        }
        let result = answered.wait(timeout:.now()+1)
        release.signal()
        wait(for:[writer,reader],timeout:5)
        XCTAssertEqual(result,.success,"A safe import read waited for the SQLite writer")
        XCTAssertFalse(FileManager.default.fileExists(atPath:router.root.appendingPathComponent("backup-write-queue").path))
    }
    private func assertRead(_ f: StorageFixture,_ method: String,_ params: JSON,caller: Caller? = nil,expected: JSON? = nil) throws {
        let before = Date(),reply = try f.call(method,params,caller:caller)
        print("P320e \(method) \(caller?.role ?? "owner") response_ms=\(Date().timeIntervalSince(before)*1000)")
        let data = try XCTUnwrap(reply["data"] as? JSON),admission = reply["write_admission"] as? JSON
        XCTAssertNotEqual(data["state"] as? String,"locked")
        if let expected {XCTAssertEqual(try jsonString(data),try jsonString(expected))}
        if method == "import_preview" {XCTAssertNotNil(data["preview_digest"]);XCTAssertEqual(data["source_namespace"] as? String,"backup-read-fixture")}
        else {XCTAssertEqual(data["id"] as? String,params["receipt_id"] as? String);XCTAssertFalse((data["records"] as? [JSON] ?? []).isEmpty)}
        XCTAssertEqual(admission?["locked"] as? Bool,true)
        XCTAssertEqual(admission?["reason"] as? String,"backup_in_progress")
        XCTAssertNil(reply["command_outcome"])
    }
    func testPreviewAnswersDuringActualBackupWriterLease() throws {
        let (f,_,preview,_) = try fixture()
        let start = Date(),expected = try f.call("import_preview",preview)["data"] as! JSON
        print("P320e import_preview baseline_ms=\(Date().timeIntervalSince(start)*1000)")
        try duringCapture(f.router!) {try self.assertRead(f,"import_preview",preview,expected:expected)}
    }
    func testReceiptAnswersDuringActualBackupWriterLease() throws {
        let (f,_,_,receipt) = try fixture()
        let start = Date(),expected = try f.call("import_receipt_get",receipt)["data"] as! JSON
        print("P320e import_receipt_get baseline_ms=\(Date().timeIntervalSince(start)*1000)")
        try duringCapture(f.router!) {try self.assertRead(f,"import_receipt_get",receipt,expected:expected)}
    }
    func testWorkerImportReadsKeepCurrentAuthorityDuringActualBackupWriterLease() throws {
        let (f,p,preview,receipt) = try fixture(),caller = try worker(f,p)
        try duringCapture(f.router!) {
            try self.assertRead(f,"import_preview",preview,caller:caller)
            try self.assertRead(f,"import_receipt_get",receipt,caller:caller)
        }
    }

    func testImportReadAuthorizationRechecksCurrentSessionAndPolicyDuringCapture() throws {
        for scenario in ["revoked","ended","role","quarantined","domain","policy","missing"] {
            let (f,p,preview,receipt) = try fixture(),caller = try worker(f,p),router = f.router!
            _ = try f.call("import_preview",preview,caller:caller)
            _ = try f.call("import_receipt_get",receipt,caller:caller)
            try router.dbQueue.write {db in
                if scenario == "policy" {
                    var project = try router.record(db,p["id"] as! String,type:"project"),policy = project["policy"] as! JSON
                    policy["agent_rule_changes"] = "owner_only";project["policy"] = policy;try router.save(db,project,type:"project")
                } else if scenario == "missing" {
                    try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[caller.sessionID!])
                } else {
                    var session = try router.record(db,caller.sessionID!,type:"session")
                    if scenario == "role" {session["role"] = "assistant"}
                    else if scenario == "quarantined" {session["restore_quarantined"] = true}
                    else if scenario == "domain" {session["execution_domain"] = "different-host"}
                    else {session["state"] = scenario}
                    try router.save(db,session,type:"session")
                }
            }
            let code = scenario == "policy" ? "HUMAN_CHANNEL_REQUIRED" : (scenario == "quarantined" ? "CONNECTION_REVOKED" : "FORBIDDEN")
            try duringCapture(router) {
                for (method,params) in [("import_preview",preview),("import_receipt_get",receipt)] {
                    XCTAssertThrowsError(try f.call(method,params,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,code,scenario)}
                }
            }
        }
    }
    func testImportReadGrantWorkspaceAssistantAndReceiptScopeRemainExactDuringCapture() throws {
        let (f,p,preview,receipt) = try fixture(),registered = try worker(f,p),pid = p["id"] as! String
        let callers: [(Caller,String)] = [
            (Caller(role:"worker",installation:registered.installation,projectIDs:[],sessionID:registered.sessionID,workspace:f.workspace.path),"FORBIDDEN"),
            (Caller(role:"worker",installation:registered.installation,projectIDs:[pid],sessionID:registered.sessionID,workspace:f.base.path),"ROOT_MISMATCH"),
            (Caller(role:"assistant",installation:"synthetic-assistant",projectIDs:[pid],workspace:f.workspace.path,assistantGrants:[pid:["read":true]]),"FORBIDDEN")]
        let other = try f.call("project_create",["name":"Other receipt scope","key_prefix":"OT"])["data"] as! JSON
        var foreignReceipt = receipt;foreignReceipt["project_id"] = other["id"]!
        var outside = preview;outside["path"] = f.base.path
        try duringCapture(f.router!) {
            for (caller,code) in callers {
                for (method,params) in [("import_preview",preview),("import_receipt_get",receipt)] {
                    XCTAssertThrowsError(try f.call(method,params,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,code)}
                }
            }
            XCTAssertThrowsError(try f.call("import_preview",outside,caller:registered)) {XCTAssertEqual(($0 as? CoreError)?.code,"FILE_ACCESS_REQUIRED")}
            XCTAssertThrowsError(try f.call("import_receipt_get",foreignReceipt)) {XCTAssertEqual(($0 as? CoreError)?.code,"NOT_FOUND")}
        }
    }
    func testAllSafeNativeMediaReadsAnswerDuringActualBackupWriterLease() throws {
        let helper = MediaReworkTests(),(f,type,round,ids) = try helper.setup(2)
        try helper.decide(f,round,ids[0],"changes_requested")
        try helper.decide(f,round,ids[1],"accepted")
        let epic = try helper.epic(f),draft = try f.round(type),draftItem = try f.item(draft)
        let intake = try f.call("media_intake_preview",["round_id":draft["id"]!,"text":"Synthetic intake"])
        let routes: [(String,JSON)] = [
            ("media_navigation",[:]),("media_round_page",["type_id":type["id"]!,"state":"open"]),
            ("media_round_header",["round_id":round["id"]!]),("media_item_get",["round_id":round["id"]!,"item_id":ids[0]]),
            ("media_publication_preview",["round_id":draft["id"]!]),("media_type_get",["type_id":type["id"]!]),
            ("media_intake_get",["intake_id":intake["id"]!]),("media_item_page",["round_id":round["id"]!]),
            ("media_item_counts",["round_id":round["id"]!]),("media_approved_examples",["round_id":draft["id"]!,"item_id":draftItem["id"]!,"expanded":true,"examples":["enabled":true]]),
            ("media_rework_preview",["round_id":round["id"]!,"epic_id":epic,"items":[["item_id":ids[0]]]])]
        XCTAssertEqual(Set(routes.map { $0.0 }),CommandRouter.mediaOwnerPoolReads)
        // CL-331/333 worker reads (PM1) use the same pooled snapshot with current worker authority.
        let ownIntake = try XCTUnwrap(f.router.handle(method:"media_intake_preview",params:["project_id":f.project,"command_id":uuid(),"round_id":draft["id"]!,"text":"Synthetic worker intake"],caller:f.worker)["data"] as? JSON)
        let workerRoutes: [(String,JSON)] = [
            ("media_type_list",[:]),("media_type_get",["type_id":type["id"]!]),("media_round_get",["round_id":round["id"]!]),
            ("media_decision_list",["round_id":round["id"]!]),("media_intake_get",["intake_id":ownIntake["id"]!])]
        XCTAssertEqual(Set(workerRoutes.map { $0.0 }),CommandRouter.mediaWorkerReads)
        let assistant = Caller(role:"assistant",installation:"synthetic-assistant",projectIDs:[f.project])
        let before = try f.allState()
        try duringCapture(f.router) {
            for (method,input) in routes {
                var params = input;params["project_id"] = f.project
                let start = Date(),reply = try f.router.handle(method:method,params:params,caller:f.owner)
                print("P320e \(method) response_ms=\(Date().timeIntervalSince(start)*1000)")
                let data = try XCTUnwrap(reply["data"] as? JSON)
                XCTAssertNotEqual(data["state"] as? String,"locked",method)
                if method == "media_publication_preview" {XCTAssertEqual((data["items"] as? [JSON])?.count,1)}
                if method == "media_approved_examples" {XCTAssertEqual((data["examples"] as? [JSON])?.count,1);XCTAssertEqual(data["collapsed"] as? Bool,false)}
                XCTAssertEqual((reply["write_admission"] as? JSON)?["reason"] as? String,"backup_in_progress",method)
                // Owner-only routes stay refused for workers; shared names are checked below.
                for caller in [f.worker,assistant] where caller.role == "assistant" || !CommandRouter.mediaWorkerReads.contains(method) {
                    XCTAssertThrowsError(try f.router.handle(method:method,params:params,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN",method)}
                }
            }
            for (method,input) in workerRoutes {
                var params = input;params["project_id"] = f.project
                let start = Date(),reply = try f.router.handle(method:method,params:params,caller:f.worker)
                print("P52a \(method) worker response_ms=\(Date().timeIntervalSince(start)*1000)")
                let data = try XCTUnwrap(reply["data"] as? JSON),admission = reply["write_admission"] as? JSON
                XCTAssertNotEqual(data["state"] as? String,"locked",method)
                XCTAssertEqual(admission?["locked"] as? Bool,true,method)
                XCTAssertEqual(admission?["reason"] as? String,"backup_in_progress",method)
                XCTAssertNil(reply["command_outcome"],method)
                switch method {
                case "media_type_list":XCTAssertEqual((data["types"] as? [JSON])?.count,1)
                case "media_type_get":XCTAssertEqual(data["id"] as? String,type["id"] as? String)
                case "media_round_get":XCTAssertEqual((data["items"] as? [JSON])?.count,2)
                case "media_decision_list":XCTAssertEqual((data["rows"] as? [JSON])?.count,2)
                default:XCTAssertEqual(data["id"] as? String,ownIntake["id"] as? String)
                }
                XCTAssertThrowsError(try f.router.handle(method:method,params:params,caller:assistant)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN",method)}
            }
            // A worker reads only its own intake, also during the lease.
            XCTAssertThrowsError(try f.router.handle(method:"media_intake_get",params:["project_id":f.project,"intake_id":intake["id"]!],caller:f.worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        }
        XCTAssertEqual(try f.allState(),before,"Media reads must not create holds or mutate canonical state")
    }
    func testPairingReceiptAuthorityAnswersDuringActualBackupWriterLeaseAndRejectsRevocation() throws {
        let f = try StorageFixture(fast:true),p = try f.project(),router = f.router!,pid = p["id"] as! String,sid = uuid()
        let original: JSON = ["command_id":uuid(),"installation":"pairtest","project_ids":[pid],"workspace":f.workspace.path,"provider":"codex","role":"worker"]
        _ = try router.commitConnectionRegistration(intent:original,caller:f.owner,preparePersistence:{_ in
            ConnectionRegistrationPreparation(sessionParameters:["project_id":pid,"project_ids":[pid],"session_id":sid,"installation":"pairtest/generation","provider":"codex","role":"worker","workspace":f.workspace.path],installation:"pairtest",mcpExecutable:"/synthetic/Checklist.app/checklist")
        },rollback:{})
        let digest = ChecklistCore.hash(Data(("connection_pair" + (try jsonString(original))).utf8))
        func current(_ session: String = sid,_ installation: String = "pairtest",_ principal: String? = nil) throws -> Bool {
            try router.connectionRegistrationIsCurrent(commandID:original["command_id"] as! String,digest:digest,sessionID:session,installation:installation,receiptPrincipal:principal ?? f.owner.principal,caller:f.owner)
        }
        try duringCapture(router) {
            XCTAssertTrue(try current())
            XCTAssertFalse(try current("foreign-session"))
            XCTAssertFalse(try current(sid,"foreign-installation"))
            XCTAssertFalse(try current(sid,"pairtest","foreign-principal"))
        }
        let session = try router.dbQueue.read {try router.record($0,sid,type:"session")}
        _ = try f.call("session_update",["project_id":pid,"session_id":sid,"expected_revision":session["revision"]!,"state":"revoked"])
        try duringCapture(router) {XCTAssertFalse(try current())}
    }
}
