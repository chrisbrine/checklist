import Foundation
import GRDB

struct PreparedHumanRequestFiles {
    struct Selection {
        let path: String
        let identity: FileIdentity?
    }
    struct Import {
        let params: JSON
        let prepared: ManagedAttachmentPreparation
    }
    let digest: String
    let requestID: String
    let revision: Int
    let files: [JSON]
    let selections: [String:Selection]
    let imports: [String:Import]
}

extension CommandRouter {
    /// Stable child UUIDs preserve each selection's existing import job/receipt across
    /// a failed transaction, restart or lost reply. Neither the digest nor a new UUID
    /// can turn a changed enclosing intent into another import.
    func humanAnswerImportParams(_ p: JSON,request: JSON,file: JSON,path: String) throws -> JSON {
        let seed = try jsonString(["kind":"human_request_answer_file","command_id":p["command_id"]!,
            "request_id":request["id"]!,"file_request_id":file["file_request_id"]!,"path":path])
        let chars = Array(hash(Data(seed.utf8)).prefix(32))
        let command = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
        var input: JSON = ["project_id":request["project_id"]!,"task_id":request["task_id"]!,"path":path,"mode":"managed","command_id":command]
        input["expected_sha256"] = (file["path_sha256"] as? [String:String])?[path]
        return input
    }

    /// All source reads, hashing and staging occur here, before the answer's writer.
    /// The trusted answer repeats revision, form, authority and direction fences at commit.
    func prepareHumanRequestAnswerFiles(params p: JSON,caller c: Caller) throws -> PreparedHumanRequestFiles? {
        let digest = hash(Data(("human_request_answer" + (try jsonString(p))).utf8))
        let plan: (request: JSON,complete: Bool,isAnswer: Bool)? = try readForPreparation { db in
            let pid = try self.scope(db,p,c,write:true)
            try self.owner(c)
            let command = try text(p,"command_id",max:100)
            guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT","command_id must be a UUID.") }
            try self.requirePendingStorageCommand(db,command:command,digest:digest,caller:c)
            if try self.managedImportReceipt(db,principal:c.principal,command:command,digest:digest) != nil { return nil }
            let request = try self.scoped(db,try text(p,"request_id"),pid,type:"request")
            try self.revision(p,request)
            guard request["state"] as? String == "pending" else { throw CoreError("REQUEST_CHANGED","This request is no longer pending.") }
            let action = p["response"] as? String ?? p["action"] as? String ?? "answered"
            guard ["answered","send","clarification","clarify","cannot_do"].contains(action) else { throw CoreError("INVALID_INPUT","Choose Answer, Clarify or Cannot do.") }
            if let identity = p["form_identity"] as? String,identity != (try self.requestFormIdentity(request)) { throw CoreError("REQUEST_CHANGED","This answer belongs to an older form. Its draft has not been sent.") }
            let isAnswer = ["answered","send"].contains(action)
            if !isAnswer { _ = try text(p,"explanation",max:16000) }
            _ = try self.validatedRequestAnswers(request,params:p,requireComplete:isAnswer)
            let complete = isAnswer
            if complete,request["review_request_id"] != nil { try self.validateHumanGateDirection(db,request:request,params:p,caller:c) }
            return (request,complete,isAnswer)
        }
        guard let plan else { return nil }
        var selections: [String:PreparedHumanRequestFiles.Selection] = [:]
        var imports: [String:PreparedHumanRequestFiles.Import] = [:], attempted: [JSON] = []
        var reserved = false
        do {
            let files = try validatedRequestFiles(plan.request,params:p,requireComplete:plan.isAnswer,managedCopy:plan.complete ? { file,path in
                if !reserved {
                    try ArchiveStorageGate.withExclusive(root:self.root) { _ in try self.dbQueue.write { db in
                        _ = try self.scope(db,p,c,write:true);try self.owner(c)
                        let current = try self.scoped(db,plan.request["id"] as! String,plan.request["project_id"] as! String,type:"request")
                        try self.revision(p,current)
                        if current["review_request_id"] != nil { try self.validateHumanGateDirection(db,request:current,params:p,caller:c) }
                        let command = p["command_id"] as! String
                        try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
                        let key = try self.pendingStorageCommandKey(principal:c.principal,command:command)
                        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try jsonString(["kind":"human_request_answer","intent_digest":digest])])
                    } }
                    reserved = true
                }
                let input = try self.humanAnswerImportParams(p,request:plan.request,file:file,path:path)
                attempted.append(input)
                try ArchiveStorageGate.withExclusive(root:self.root) { _ in try self.dbQueue.write { db in
                    try self.requirePendingCommandIntent(db,command:input["command_id"] as! String,digest:hash(Data(("attachment_add" + (try jsonString(input))).utf8)),caller:c)
                } }
                let resolved = canonical(path), before = FileIdentity(path:resolved)
                let prepared: ManagedAttachmentPreparation
                do {
                    guard let value = try self.prepareManagedAttachmentImport(method:"attachment_add",params:input,caller:c,access:self.managedImportAccessOutsideWriter()) else { throw self.managedImportFailure("answer_import_receipt_without_answer") }
                    prepared = value
                } catch {
                    try? ArchiveStorageGate.withExclusive(root:self.root) { _ in try self.dbQueue.writeWithoutTransaction {
                        try self.recordManagedImportPreparationFailure($0,method:"attachment_add",params:input,caller:c,error:error)
                    } }
                    // Chooser failures retain the answer draft and never expose raw IO paths.
                    if error is CocoaError || error is StorageSnapshotFailure { throw CoreError("FILE_ACCESS_REQUIRED","A selected original cannot be read. Your draft remains saved.") }
                    throw error
                }
                guard FileIdentity(path:resolved) == before,canonical(path) == resolved else { throw CoreError("SOURCE_CHANGED","A selected original changed during import. Your draft remains saved.") }
                if let before { selections[path] = .init(path:resolved,identity:before) }
                imports[input["command_id"] as! String] = .init(params:input,prepared:prepared)
                return prepared.attachment["sha256"] as! String
            } : nil,observe: { path,identity in
                selections[path] = .init(path:canonical(path),identity:identity)
            })
            for file in files where file["mode"] as? String == "reference" {
                for path in strings(file,"paths") where selections[path] == nil { selections[path] = .init(path:canonical(path),identity:nil) }
            }
            return .init(digest:digest,requestID:plan.request["id"] as! String,revision:int(plan.request,"revision"),files:files,selections:selections,imports:imports)
        } catch {
            finishHumanAnswerImportStages(attempted,caller:c)
            throw error
        }
    }

    func preparedHumanRequestFiles(_ request: JSON,params p: JSON) throws -> [JSON] {
        guard let prepared = commandPreparation.humanRequestFiles,prepared.requestID == request["id"] as? String,
              prepared.revision == int(request,"revision"),prepared.digest == hash(Data(("human_request_answer" + (try jsonString(p))).utf8)) else { throw managedImportFailure("missing_answer_preparation") }
        for (raw,selected) in prepared.selections {
            guard canonical(raw) == selected.path else { throw CoreError("SOURCE_CHANGED","A selected original changed before the answer committed.") }
            if let identity = selected.identity {
                guard FileIdentity(path:selected.path) == identity else { throw CoreError("SOURCE_CHANGED","A selected original changed before the answer committed.") }
            } else {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath:selected.path,isDirectory:&directory),directory.boolValue else { throw CoreError("FILE_ACCESS_REQUIRED","A selected directory is unavailable.") }
            }
        }
        return prepared.files
    }

    func commitHumanAnswerImport(_ db: Database,params p: JSON,request: JSON,file: JSON,path: String,caller c: Caller) throws -> JSON {
        let input = try humanAnswerImportParams(p,request:request,file:file,path:path)
        guard let capture = commandPreparation.humanRequestFiles?.imports[input["command_id"] as! String] else { throw managedImportFailure("missing_answer_import") }
        let prepared = capture.prepared
        for (relative,identity) in prepared.observations {
            guard (try? managedIdentity(relative)) == identity else { throw managedImportFailure("prepared_original_changed") }
        }
        let previous = managedAttachmentPreparation
        managedAttachmentPreparation = prepared
        defer { managedAttachmentPreparation = previous }
        let attachment = try attachmentWrite(db,capture.params,c,"attachment_add")
        // Exact child receipts let the existing startup/maintenance machinery reconcile
        // these jobs. All children and the enclosing response/outbox commit together.
        try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,prepared.command,prepared.digest,try jsonString(["data":attachment])])
        return attachment
    }

    /// Remove only recorded stages belonging to these exact attempted child intents.
    /// Finalized originals/jobs stay recoverable; partial-file cleanup belongs to the
    /// existing importer. A cleanup error never replaces the command's semantic result.
    func finishHumanAnswerImportStages(_ inputs: [JSON],caller c: Caller) {
        guard !inputs.isEmpty else { return }
        try? ArchiveStorageGate.withExclusive(root:root) { _ in try dbQueue.writeWithoutTransaction { db in
            let files = try StorageObjectFiles(root:self.root)
            for input in inputs {
                let command = input["command_id"] as! String,digest = hash(Data(("attachment_add" + (try jsonString(input))).utf8))
                let key = try self.managedImportKey(principal:c.principal,command:command)
                guard let job = try? self.record(db,key,type:"storage_job"),job["parent_principal"] as? String == c.principal,job["intent_digest"] as? String == digest,
                      ["reserved","staging","finalized"].contains(job["state"] as? String ?? ""),try self.managedImportReceipt(db,principal:c.principal,command:command,digest:digest) == nil,job["objects"] != nil else { continue }
                for object in try self.managedImportObjects(job) { try self.removeManagedImportStage(db,files:files,path:object["stage"] as! String) }
            }
        } }
    }
}
