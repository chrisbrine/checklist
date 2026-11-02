import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class AttachmentReadOperationTests: XCTestCase {
    private static let maximumChangedFileSize = 8 * 1024 * 1024 + 1
    private func data(_ value: JSON) throws -> JSON {try XCTUnwrap(value["data"] as? JSON)}
    private func fixture(mode: String = "managed") throws -> (StorageFixture,JSON,Caller) {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),pid = project["id"] as! String
        let source = f.workspace.appendingPathComponent("read.txt")
        try Data("CL-401 exact file bytes".utf8).write(to:source)
        let attachment = try data(f.call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":source.path,"mode":mode]))
        let installation = "attachment-operation-reader"
        let session = try data(f.call("session_register",["project_id":pid,"label":"Read fixture","provider":"codex","role":"worker","installation":installation,"workspace":f.workspace.path]))
        let caller = Caller(role:"worker",installation:installation,projectIDs:[pid],sessionID:session["id"] as? String,workspace:f.workspace.path)
        return (f,attachment,caller)
    }
    private func read(_ f: StorageFixture,_ attachment: JSON,_ caller: Caller,representation: String = "original") throws -> (JSON,JSON) {
        let queue = DispatchQueue(label:"CL-401-read"),command = uuid()
        f.router!.configureCommandOperations(on:queue)
        let params: JSON = ["command_id":command,"project_id":attachment["project_id"]!,"attachment_id":attachment["id"]!,"representation":representation]
        let accepted = try data(f.call("attachment_read",params,caller:caller))
        let done = DispatchSemaphore(value:0);queue.async {done.signal()}
        XCTAssertEqual(done.wait(timeout:.now()+30),.success)
        let status: JSON = ["project_id":attachment["project_id"]!,"operation_id":accepted["operation_id"]!]
        return (params,status)
    }

    func testWholeFileRepliesAreByteFreeDurablyAndStableAcrossReplayAndRestart() throws {
        for representation in ["original","preview"] {
            let (f,attachment,caller) = try fixture()
            let (params,status) = try read(f,attachment,caller,representation:representation)
            let first = try data(f.call("operation_get",status,caller:caller))
            XCTAssertEqual(first["state"] as? String,"succeeded")
            let deadline = try XCTUnwrap(first["result_expires_at"] as? String)
            XCTAssertNotNil(ISO8601DateFormatter().date(from:deadline))
            let result = try XCTUnwrap(first["result"] as? JSON)
            XCTAssertEqual(try data(result)["content_base64"] as? String,Data("CL-401 exact file bytes".utf8).base64EncodedString())
            XCTAssertNil(result["_attachment_read"])
            try f.router!.dbQueue.read {db in
                let receipt = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,params["command_id"] as! String]))
                XCTAssertFalse(receipt.contains("content_base64"));XCTAssertFalse(receipt.contains(Data("CL-401 exact file bytes".utf8).base64EncodedString()))
            }
            // A later description cannot replace the metadata of the accepted reply.
            try f.router!.dbQueue.write {db in
                var value = try f.router!.record(db,attachment["id"] as! String,type:"attachment");value["description"] = "new metadata"
                try f.router!.save(db,value,type:"attachment")
            }
            XCTAssertEqual(try jsonString(data(f.call("operation_get",status,caller:caller))["result"] as! JSON),try jsonString(result))
            XCTAssertEqual(try data(f.call("attachment_read",params,caller:caller))["operation_id"] as? String,status["operation_id"] as? String)
            try f.reopen()
            XCTAssertEqual(try jsonString(data(f.call("operation_get",status,caller:caller))["result"] as! JSON),try jsonString(result))
            XCTAssertEqual(try data(f.call("command_status",["project_id":attachment["project_id"]!,"command_id":params["command_id"]!],caller:caller))["result_expires_at"] as? String,deadline)
        }
    }

    func testReadRechecksAuthorizationIdentityCleanupAndExpiry() throws {
        let (f,attachment,caller) = try fixture(),router = f.router!
        let (_,status) = try read(f,attachment,caller)
        let other = Caller(role:"worker",installation:"other",projectIDs:caller.projectIDs,sessionID:caller.sessionID,workspace:caller.workspace)
        XCTAssertThrowsError(try f.call("operation_get",status,caller:other))
        let file = try router.managedURL(attachment["path"] as! String,family:"objects")
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        try Data("replacement".utf8).write(to:file)
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"SOURCE_CHANGED")}
        try Data(count:Self.maximumChangedFileSize).write(to:file)
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"SOURCE_CHANGED")}
        try router.dbQueue.write {db in
            var value = try router.record(db,attachment["id"] as! String,type:"attachment");value.removeValue(forKey:"path")
            try router.save(db,value,type:"attachment")
        }
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"ORIGINAL_CLEANED")}
        try router.dbQueue.read {db in
            let operation = try XCTUnwrap(router.operationRecord(db,id:status["operation_id"] as! String))
            let receipt = jsonObject(try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,operation["command_id"] as! String])))
            XCTAssertThrowsError(try router.attachmentOperationResult(db,receipt,operation:operation,caller:caller,at:Date().addingTimeInterval(86_401))) {XCTAssertEqual(($0 as? CoreError)?.code,"ATTACHMENT_READ_EXPIRED")}
        }
        try router.dbQueue.write {db in
            var session = try router.record(db,caller.sessionID!,type:"session");session["authorization_generation"] = uuid()
            try router.save(db,session,type:"session")
        }
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"CONNECTION_REVOKED")}
    }

    func testSeparatePreviewUsesTheDeliveredHashAndMissingFileRefusesReplay() throws {
        let (f,attachment,caller) = try fixture(),router = f.router!
        let relative = "objects/" + uuid() + ".preview.png",file = router.root.appendingPathComponent(relative)
        let bytes = Data("separate preview bytes".utf8)
        try bytes.write(to:file)
        try router.dbQueue.write {db in
            var value = try router.record(db,attachment["id"] as! String,type:"attachment");value["preview_path"] = relative
            try router.save(db,value,type:"attachment")
        }
        let (_,status) = try read(f,attachment,caller,representation:"preview")
        let payload = try data(f.call("operation_get",status,caller:caller))
        XCTAssertEqual(try data(payload["result"] as! JSON)["content_base64"] as? String,bytes.base64EncodedString())
        try FileManager.default.moveItem(at:file,to:file.appendingPathExtension("moved"))
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"MANAGED_FILE_UNAVAILABLE")}
    }

    func testExternalReferenceReplayRechecksWorkspaceAndRefusesSymlinkSwap() throws {
        let (f,attachment,caller) = try fixture(mode:"external_reference")
        let (_,status) = try read(f,attachment,caller)
        XCTAssertNotNil(try data(f.call("operation_get",status,caller:caller))["result"])
        let outside = Caller(role:caller.role,installation:caller.installation,projectIDs:caller.projectIDs,sessionID:caller.sessionID,workspace:f.base.appendingPathComponent("outside").path)
        XCTAssertThrowsError(try f.call("operation_get",status,caller:outside))
        let source = URL(fileURLWithPath:attachment["path"] as! String)
        try FileManager.default.moveItem(at:source,to:source.appendingPathExtension("moved"))
        let foreign = f.base.appendingPathComponent("foreign.txt")
        try Data("foreign bytes".utf8).write(to:foreign)
        try FileManager.default.createSymbolicLink(at:source,withDestinationURL:foreign)
        XCTAssertThrowsError(try f.call("operation_get",status,caller:caller))
    }

    func testLegacyCleanupIsBoundedKeepsIntentAndPreservesUnrelatedReplies() throws {
        let (f,attachment,caller) = try fixture(),router = f.router!
        let (_,status) = try read(f,attachment,caller)
        let oldDate = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-86_401))
        let encoded = Data("legacy file bytes".utf8).base64EncodedString()
        try router.dbQueue.write {db in
            let original = try XCTUnwrap(router.operationRecord(db,id:status["operation_id"] as! String))
            for index in 0..<7 {
                let command = uuid(),id = CommandRouter.commandOperationID(principal:caller.principal,command:command)
                var operation = original;operation["command_id"] = command;operation["operation_id"] = id;operation["finished_at"] = index == 5 ? now() : oldDate
                if index != 6 {try router.saveOperation(db,operation)}
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,operation["digest"] as! String,try jsonString(["data":["id":attachment["id"]!,"content_base64":encoded]])])
            }
        }
        try router.dbQueue.read {db in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT m.value,c.result FROM metadata m JOIN commands c ON c.command_id=json_extract(m.value,'$.command_id') AND c.principal=json_extract(m.value,'$.principal') WHERE m.key GLOB 'command-operation:*' AND json_extract(m.value,'$.finished_at')=? LIMIT 1",arguments:[oldDate]))
            XCTAssertThrowsError(try router.attachmentOperationResult(db,jsonObject(row["result"]),operation:jsonObject(row["value"]),caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"ATTACHMENT_READ_EXPIRED")}
        }
        XCTAssertEqual(try router.dbQueue.write {try router.pruneAttachmentReadResults($0)},4)
        XCTAssertEqual(try router.dbQueue.write {try router.pruneAttachmentReadResults($0)},2)
        XCTAssertEqual(try router.dbQueue.write {try router.pruneAttachmentReadResults($0)},0)
        try router.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM commands WHERE json_extract(result,'$.attachment_read_expired')=1"),6)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM commands WHERE json_type(result,'$.data.content_base64')='text'"),1)
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT principal,command_id,digest,result FROM commands WHERE json_extract(result,'$.attachment_read_expired')=1 LIMIT 1"))
            let id = CommandRouter.commandOperationID(principal:row["principal"],command:row["command_id"])
            let operation = try XCTUnwrap(router.operationRecord(db,id:id))
            XCTAssertEqual(row["digest"] as String,operation["digest"] as? String)
            XCTAssertThrowsError(try router.attachmentOperationResult(db,jsonObject(row["result"]),operation:operation,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"ATTACHMENT_READ_EXPIRED")}
        }
    }
}
