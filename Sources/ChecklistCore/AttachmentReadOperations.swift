import Foundation
import GRDB

extension CommandRouter {
    static let attachmentReadResultRetention: TimeInterval = 86_400
    static let attachmentReadPruneBatch = 4

    /// The command journal keeps the exact reply metadata and the delivered
    /// bytes' identity. It never keeps the bytes themselves (CL-401).
    func attachmentOperationReceipt(_ output: JSON,params: JSON,operation: inout JSON) throws -> JSON {
        var receipt = output
        guard var data = receipt["data"] as? JSON,let encoded = data.removeValue(forKey:"content_base64") as? String,
              let bytes = Data(base64Encoded:encoded) else {return output}
        let expiry = ISO8601DateFormatter().string(from:Date().addingTimeInterval(Self.attachmentReadResultRetention))
        receipt["data"] = data
        receipt["_attachment_read"] = ["representation":params["representation"] ?? "metadata","sha256":hash(bytes),"expires_at":expiry]
        operation["result_expires_at"] = expiry
        return receipt
    }

    static func attachmentReadExpired() -> CoreError {
        CoreError("ATTACHMENT_READ_EXPIRED","This attachment read reply has expired. Use a new command ID to read the current file.")
    }

    func attachmentOperationResult(_ db: Database,_ receipt: JSON,operation: JSON,caller: Caller,at time: Date = Date()) throws -> JSON {
        if bool(receipt,"attachment_read_expired") {throw Self.attachmentReadExpired()}
        guard let descriptor = receipt["_attachment_read"] as? JSON else {
            // Legacy receipts have no selected-representation identity. Retire
            // them rather than grant file access from a historical byte snapshot.
            if let data = receipt["data"] as? JSON,data["content_base64"] != nil {throw Self.attachmentReadExpired()}
            return receipt
        }
        guard let expiry = descriptor["expires_at"] as? String,let deadline = ISO8601DateFormatter().date(from:expiry),time < deadline else {throw Self.attachmentReadExpired()}
        guard var data = receipt["data"] as? JSON,let id = data["id"] as? String,let pid = operation["project_id"] as? String,
              let representation = descriptor["representation"] as? String,["preview","original"].contains(representation),
              let expected = descriptor["sha256"] as? String else {throw StoreRecovery.required("command_operation_invalid")}
        // Operation authorization is checked by the caller first. Recheck current
        // attachment/project authority too: retained metadata is never file authority.
        let params: JSON = ["project_id":pid,"attachment_id":id]
        _ = try scope(db,params,caller)
        let attachment = try scoped(db,id,pid,type:"attachment")
        guard attachment["task_id"] is String else {throw CoreError("ATTACHMENT_REFERENCE_REQUIRED","Taskless originals require a current owner reference; media commands are not enabled.")}
        let selected = representation == "preview" ? (attachment["preview_path"] as? String ?? attachment["path"] as? String) : attachment["path"] as? String
        if representation == "original" || attachment["preview_path"] == nil, let refusal = Self.cleanedOriginalRefusal(attachment) {throw refusal}
        guard let selected else {throw Self.cleanedOriginalError}
        let managed = attachment["mode"] as? String == "managed" || representation == "preview" && attachment["preview_path"] != nil
        let bytes: Data
        do {
            if managed {bytes = try managedRead(selected,family:"objects",maximum:Self.attachmentChunkLimit)}
            else {
                let project = try record(db,pid,type:"project")
                bytes = try SafeFileRead.read(selected,maximum:Self.attachmentChunkLimit,allowedRoots:agentReadRoots(caller,project:project)).bytes
            }
        } catch StorageSnapshotFailure.limit {
            throw CoreError("SOURCE_CHANGED","The file no longer matches the original attachment read reply.")
        } catch let error as CoreError where error.code == "FILE_TOO_LARGE" {
            throw CoreError("SOURCE_CHANGED","The file no longer matches the original attachment read reply.")
        } catch is StorageSnapshotFailure {
            throw CoreError("MANAGED_FILE_UNAVAILABLE","The managed file for the original attachment read reply is unavailable.")
        }
        guard hash(bytes) == expected else {throw CoreError("SOURCE_CHANGED","The file no longer matches the original attachment read reply.")}
        data["content_base64"] = bytes.base64EncodedString()
        var output = receipt;output.removeValue(forKey:"_attachment_read");output["data"] = data
        return output
    }

    /// No migration and no file deletion. At most four legacy replies lose their
    /// base64 field per ordinary retention pass. UUID, digest and reply metadata stay.
    @discardableResult
    func pruneAttachmentReadResults(_ db: Database) throws -> Int {
        try db.execute(sql:"""
            UPDATE commands SET result=json_set(json_remove(result,'$.data.content_base64'),'$.attachment_read_expired',json('true'))
            WHERE rowid IN (
              SELECT c.rowid FROM metadata m JOIN commands c
                ON c.principal=json_extract(m.value,'$.principal') AND c.command_id=json_extract(m.value,'$.command_id') AND c.digest=json_extract(m.value,'$.digest')
              WHERE m.key GLOB 'command-operation:*' AND json_valid(m.value)
                AND json_extract(m.value,'$.method')='attachment_read' AND json_extract(m.value,'$.state')='succeeded'
                AND CASE WHEN json_valid(c.result) THEN json_type(c.result,'$.data.content_base64')='text' ELSE 0 END
              ORDER BY c.rowid LIMIT ?)
            """,arguments:[Self.attachmentReadPruneBatch])
        return db.changesCount
    }
}
