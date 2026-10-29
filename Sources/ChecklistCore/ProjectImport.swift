import ChecklistDomain
import Foundation
import GRDB

extension CommandRouter {
    static let projectImportMethods: Set<String> = ["import_preview","import_commit","import_rollback","import_receipt_get"]

    /// Opaque, project-scoped revision boundary: includes same-revision row writes
    /// and ordinary notes (which need not revise their ticket). Never expose seq.
    func importDestinationDigest(_ db: Database,_ pid: String) throws -> String {
        let rows = try Row.fetchCursor(db,sql:"SELECT CAST(id AS BLOB) AS id,revision,CAST(data AS BLOB) AS data FROM records WHERE project_id=CAST(? AS TEXT) AND type!='import_receipt' ORDER BY id COLLATE BINARY",arguments:[Data(pid.utf8)])
        var parts: [String] = []
        while let row = try rows.next() {parts.append(autoreleasepool {hash(row["id"] as Data) + ":" + hash(row["data"] as Data)})}
        let event = try Int64.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events WHERE project_id=CAST(? AS TEXT)",arguments:[Data(pid.utf8)]) ?? 0
        return hash(Data((parts.joined(separator:"\n") + ":" + String(event)).utf8))
    }
    private func importAuthorization(_ db: Database,_ params: JSON,_ caller: Caller,write: Bool) throws -> (String,JSON) {
        try worker(caller)
        let pid = try scope(db,params,caller,write:write),project = try record(db,pid,type:"project")
        try requireAgentEditAuthority(db,project:project,caller:caller)
        return (pid,project)
    }
    func executeProjectImport(method: String,params: JSON,caller: Caller) throws -> JSON {
        if method == "import_receipt_get" {
            return try readForPreparation {db in
                let (pid,_) = try importAuthorization(db,params,caller,write:false)
                var receipt = try scoped(db,text(params,"receipt_id"),pid,type:"import_receipt")
                receipt["records"] = try records(db,type:"import_record",project:pid).filter {$0["import_receipt_id"] as? String == receipt["id"] as? String}
                return ["data":receipt]
            }
        }
        let (pid,_) = try readForPreparation {try importAuthorization($0,params,caller,write:!Self.readMethods.contains(method))}
        let command = Self.readMethods.contains(method) ? "" : try text(params,"command_id",max:100)
        if !command.isEmpty,UUID(uuidString:command) == nil {throw CoreError("INVALID_INPUT","command_id must be a UUID.")}
        let intent = hash(Data((method + (try jsonString(params))).utf8))
        if !command.isEmpty,let replay = try dbQueue.read({db -> JSON? in
            guard let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) else {return nil}
            guard row["digest"] as String == intent else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID belongs to another intent.")}
            let result = jsonObject(row["result"])
            if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
            return result.merging(["replayed":true]) {_,new in new}
        }) {return replay}
        if method == "import_rollback" {return try importTransaction(method:method,params:params,caller:caller,command:command,intent:intent,bundle:nil)}
        let path = try text(params,"path"),format = try text(params,"source_format"),namespace = try text(params,"source_namespace",max:500)
        if !caller.isOwner {
            guard let workspace = caller.workspace,containsPath(workspace,SafeFileRead.normalizedPrivatePrefix(URL(fileURLWithPath:path).standardizedFileURL.path)) else {throw CoreError("FILE_ACCESS_REQUIRED","Selected import must be inside the enrolled workspace.")}
        }
        // Prepare hashes of the exact selected bytes outside the SQL writer.
        let bundle = try TransferBundle.read(path:path,format:format,namespace:namespace)
        if method == "import_preview" {
            return try readForPreparation {db in
                _ = try importAuthorization(db,params,caller,write:false)
                let destination = try importDestinationDigest(db,pid)
                let digest = try importPreviewDigest(bundle:bundle,destination:destination,params:params)
                let timestamp = bundle.document["exported_at"] ?? (bundle.document["meta"] as? JSON)?["exported_at"] ?? NSNull()
                let counts = Dictionary(grouping:bundle.entries,by:{$0.family}).mapValues(\.count)
                let statuses = Set(bundle.entries.filter {$0.family == "task"}.map {($0.payload["state"] as? String ?? "queued") + ":" + ($0.payload["parked_subtype"] as? String ?? $0.payload["area"] as? String ?? "")}).sorted()
                return ["data":["format":"checklist-intermediate/1","source_schema":bundle.schema,"source_namespace":namespace,"source_sha256":bundle.sourceHash,"source_time":timestamp,"destination_revision":try record(db,pid,type:"project")["revision"]!,"preview_digest":digest,"counts":counts,"status_proposals":statuses,"alias_proposals":bundle.entries.filter {$0.family == "task"}.map {["source_id":$0.sourceID,"alias":$0.payload["key"] ?? $0.sourceID,"aliases":$0.payload["aliases"] ?? []]},"tag_proposals":bundle.entries.filter {$0.family == "task"}.map {["source_id":$0.sourceID,"tags":$0.payload["tags"] ?? $0.payload["tag_ids"] ?? []]},"diagnostics":bundle.diagnostics,"blockers":bundle.blockers,"files":bundle.files.map {["path":$0.path,"sha256":$0.sha256 ?? "","availability":$0.availability]},"authority":"historical_unverified","canonical_bundle":["format":"checklist-intermediate","version":1,"records":bundle.entries.map {["family":$0.family,"source_id":$0.sourceID,"payload":$0.payload]},"source_envelope":bundle.document]]]
            }
        }
        return try importTransaction(method:method,params:params,caller:caller,command:command,intent:intent,bundle:bundle)
    }
    private func importPreviewDigest(bundle: TransferBundle,destination: String,params: JSON) throws -> String {
        hash(Data((bundle.schema + "\n" + bundle.namespace + "\n" + bundle.sourceHash + "\n" + destination + "\n" + (params["epic_id"] as? String ?? "")).utf8))
    }
    func importTransaction(method: String,params: JSON,caller: Caller,command: String,intent: String,bundle: TransferBundle?) throws -> JSON {
        try ArchiveStorageGate.withExclusive(root:root) { _ in
            // Revalidate after waiting for the gate, before any imported bytes or
            // rows are written. The transaction consumes only this verified read.
            let bundle = try bundle?.validateSource()
            if let bundle {
                // Content-addressed immutable copies are durable before SQL publication.
                // Interrupted/unreferenced copies are retained; rollback never unlinks
                // bytes which another record, backup or concurrent import may retain.
                let files = try StorageObjectFiles(root:root)
                for file in bundle.files where file.bytes != nil {
                    let destination = "objects/import-" + file.sha256!
                    if let existing = try? files.read(destination,maximum:TransferBundle.byteLimit) {
                        guard hash(existing) == file.sha256 else {throw CoreError("IMPORT_OBJECT_CONFLICT","An immutable imported file failed verification.")}
                    } else {try files.writeNew(destination,bytes:file.bytes!)}
                }
            }
            return try dbQueue.writeWithoutTransaction { db in
                var output: JSON = [:]
                try withValidatedDomainTransaction(db) {
                    let (pid,project) = try importAuthorization(db,params,caller,write:true)
                    try requirePendingCommandIntent(db,command:command,digest:intent,caller:caller)
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[caller.principal,command]) {
                        guard row["digest"] as String == intent else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID belongs to another intent.")}
                        let result = jsonObject(row["result"]);if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                        output = result.merging(["replayed":true]) {_,new in new};return .commit
                    }
                    let data: JSON
                    if method == "import_rollback" {data = try rollbackProjectImport(db,params,caller,pid:pid,project:project)}
                    else {data = try commitProjectImport(db,params,caller,pid:pid,project:project,bundle:bundle!)}
                    output = ["data":data,"command_id":command]
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[caller.principal,command,intent,try jsonString(output)])
                    return .commit
                }
                return output
        }}
    }
    private func commitProjectImport(_ db: Database,_ params: JSON,_ caller: Caller,pid: String,project: JSON,bundle: TransferBundle) throws -> JSON {
        // Namespace is unique in the destination, including after rollback.
        // Different command IDs replay the same source instead of duplicating it.
        if let prior = try records(db,type:"import_receipt",project:pid).first(where:{$0["source_namespace"] as? String == bundle.namespace}) {
            guard prior["source_sha256"] as? String == bundle.sourceHash,prior["state"] as? String == "committed" else {throw CoreError("IMPORT_SOURCE_CONFLICT",
                "This source namespace already has a different or rolled-back import. Select an explicit new namespace after reconciliation.")}
            return ["receipt_id":prior["id"]!,"source_replayed":true]
        }
        try revision(params,project)
        let expected = try importPreviewDigest(bundle:bundle,destination:importDestinationDigest(db,pid),params:params)
        guard try text(params,"preview_digest",max:64) == expected else {throw CoreError("IMPORT_PREVIEW_CHANGED","Source, mapping or destination changed after preview; regenerate the preview.")}
        guard bundle.blockers.isEmpty else {throw CoreError("IMPORT_MAPPING_REQUIRED","Resolve duplicate source identities/aliases before committing.",details:["blockers":bundle.blockers])}
        let receiptID = uuid(),sourceTasks = bundle.entries.filter {$0.family == "task"}
        let sourceProject = bundle.entries.first {$0.family == "project"}?.payload ?? [:]
        var created: [String] = [],mapping: [String:String] = [:]
        for entry in bundle.entries {mapping[ImportRecordContext.key(entry.family,entry.sourceID)] = uuid()}
        func store(_ value: JSON,_ family: String) throws {
            try save(db,value,type:family)
            created.append(try StoredRecord(value,family:family).string("id"))
        }
        // Existing destination authority/settings switch/root always stay local.
        // Source settings/policies/decisions remain exact in the inert archive.
        let fallbackEpic: String?
        if sourceTasks.isEmpty {fallbackEpic = nil}
        else if let epic = params["epic_id"] as? String {fallbackEpic = try requiredEpicID(db,project:pid,value:epic)}
        else if bundle.schema == "checklist-project/1" {fallbackEpic = nil}
        else {throw CoreError("EPIC_REQUIRED","Map legacy tasks to an explicit destination Epic in both preview and commit.")}
        let time = now()
        let context = ImportRecordContext(projectID:pid,receiptID:receiptID,namespace:bundle.namespace,time:time,mapping:mapping)
        let taxonomy = try createImportTaxonomy(bundle.entries,context:context,store:store)
        let number = try createImportTasks(db,sourceTasks,context:context,project:project,caller:caller,
                                          fallbackEpic:fallbackEpic,taxonomy:taxonomy,store:store)
        try createImportRelations(bundle.entries,context:context,store:store)
        for relation in try records(db,type:"relation",project:pid) where relation["import_receipt_id"] as? String == receiptID {try validateRelation(db,relation,project:pid)}
        try createImportAttachments(bundle,context:context,store:store)
        try archiveImportRecords(bundle,context:context,store:store)
        var nextProject = project
        nextProject["next_number"] = number
        if sourceProject["brief"] != nil {nextProject["brief"] = sourceProject["brief"];nextProject["imported_context_origin"] = "historical_unverified"}
        if let path = sourceProject["icon_path"] as? String,let file = bundle.files.first(where:{$0.path == path}),let bytes = file.bytes,let asset = sourceProject["icon_asset"] as? JSON {
            guard hash(bytes) == asset["sha256"] as? String else {throw CoreError("IMPORT_CHECKSUM_MISMATCH","Source icon differs from its export checksum.")}
            // Managed icons have a dedicated family; copy from verified bytes.
            let name = "icons/import-" + file.sha256! + ".png",files = try StorageObjectFiles(root:root)
            if (try? files.read(name,maximum:TransferBundle.byteLimit)) == nil {try files.writeNew(name,bytes:bytes)}
            nextProject["icon_path"] = name;nextProject["icon_asset"] = asset
        }
        nextProject = revised(nextProject);try save(db,nextProject,type:"project")
        try event(db,caller:caller,project:pid,entity:receiptID,kind:"project_imported",
            data:["source_namespace":bundle.namespace,"source_sha256":bundle.sourceHash,
            "authority":"historical_unverified"])
        let post = try importDestinationDigest(db,pid)
        let receipt: JSON = ["id":receiptID,"project_id":pid,"revision":1,"state":"committed",
            "source_namespace":bundle.namespace,"source_sha256":bundle.sourceHash,"source_schema":bundle.schema,
            "created_ids":created,"previous_project":project,"post_digest":post,"diagnostics":bundle.diagnostics,
            "files":bundle.files.map {["path":$0.path,"sha256":$0.sha256 ?? "","availability":$0.availability]},
            "origin":caller.isOwner ? "human_ui" : "agent","created_by":caller.principal,
            "created_at":time]
        try save(db,receipt,type:"import_receipt")
        return ["receipt_id":receiptID,"created_records":created.count,"task_count":sourceTasks.count,"source_sha256":bundle.sourceHash,"authority":"historical_unverified"]
    }
    private struct ImportRecordContext {
        let projectID: String
        let receiptID: String
        let namespace: String
        let time: String
        let mapping: [String:String]

        static func key(_ family: String,_ id: String) -> String {hash(Data((family + "\0" + id).utf8))}

        func mapped(_ family: String,_ id: String?) -> String? {
            id.flatMap {mapping[Self.key(family,$0)]}
        }
    }

    private struct ImportTaxonomy {
        let statusMap: [String:String]
        let tagMap: [String:String]
    }

    private func createImportTaxonomy(_ entries: [TransferBundle.Entry],context: ImportRecordContext,
                                      store: (JSON,String) throws -> Void) throws -> ImportTaxonomy {
        let pid = context.projectID,receiptID = context.receiptID,time = context.time
        var statusMap: [String:String] = [:],tagMap: [String:String] = [:]
        for entry in entries where ["status","tag","group"].contains(entry.family) {
            let raw = entry.payload,id = context.mapped(entry.family,entry.sourceID)!
            var value: JSON = ["id":id,"project_id":pid,"revision":1,"name":raw["name"] ?? "Imported","import_receipt_id":receiptID,"origin":"import","created_at":time,"updated_at":time]
            if entry.family == "status" {
                let category = raw["category"] as? String ?? "parked"
                guard TicketStatusCategory.wireValues.contains(category) else {throw CoreError("IMPORT_MAPPING_REQUIRED","Unsupported source status category.")}
                value["category"] = category;value["sort_order"] = raw["sort_order"] ?? 0;statusMap[entry.sourceID] = id
            }
            if entry.family == "tag" {tagMap[entry.sourceID] = id}
            if entry.family == "group" {
                value["kind"] = raw["kind"] as? String == "epic" ? "epic" : "triage"
                value["task_ids"] = strings(raw,"task_ids").compactMap {context.mapped("task",$0)}
                value["brief"] = raw["brief"] ?? ""
                value["phase"] = raw["phase"] ?? "implementation"
                value["archived"] = raw["archived"] ?? false
            }
            for field in ["color","description","purpose","key"] {value[field] = raw[field]}
            try store(value,entry.family)
        }
        return ImportTaxonomy(statusMap:statusMap,tagMap:tagMap)
    }

    private func createImportTasks(_ db: Database,_ sourceTasks: [TransferBundle.Entry],context: ImportRecordContext,
                                   project: JSON,caller: Caller,fallbackEpic: String?,taxonomy: ImportTaxonomy,
                                   store: (JSON,String) throws -> Void) throws -> Int {
        let pid = context.projectID,receiptID = context.receiptID
        var statusMap = taxonomy.statusMap,tagMap = taxonomy.tagMap
        var number = int(project,"next_number",default:1)
        for entry in sourceTasks {
            let raw = entry.payload,id = context.mapped("task",entry.sourceID)!
            let sid = try resolveImportStatus(raw,context:context,statusMap:&statusMap,store:store)
            let tags = try resolveImportTags(raw,context:context,tagMap:&tagMap,store:store)
            let epic = context.mapped("group",raw["epic_id"] as? String) ?? fallbackEpic
            guard let epic else {throw CoreError("EPIC_REQUIRED","Every imported task needs an explicit same-project primary Epic mapping.")}
            _ = try requiredEpicID(db,project:pid,value:epic)
            let task = importedTaskRecord(entry,id:id,statusID:sid,tags:tags,epic:epic,number:number,
                                          context:context,project:project,caller:caller)
            try store(task,"task");number += 1
            let aliasID = uuid();try store(["id":aliasID,"project_id":pid,"revision":1,
                "task_id":id,"namespace":context.namespace,"alias":raw["key"] ?? entry.sourceID,
                "state":"active","origin":"import","import_receipt_id":receiptID],"task_alias")
            for ref in strings(raw,"depends_on") {
                var relation: JSON = ["id":uuid(),"project_id":pid,"revision":1,"source_task_id":id,
                    "relation":"depends_on","required":true,"state":"active","origin":"import",
                    "source_reference":ref,"import_receipt_id":receiptID]
                if let target = context.mapped("task",ref) {relation["target_task_id"] = target}
                else {relation["state"] = "unresolved";relation["target_legacy_ref"] = ref}
                try store(relation,"relation")
            }
        }
        return number
    }

    private func resolveImportStatus(_ raw: JSON,context: ImportRecordContext,statusMap: inout [String:String],
                                     store: (JSON,String) throws -> Void) throws -> String {
        let pid = context.projectID,receiptID = context.receiptID
        var sid = (raw["status_id"] as? String).flatMap {statusMap[$0]}
        if sid == nil {
            let state = raw["state"] as? String ?? "queued",subtype = raw["parked_subtype"] as? String ?? raw["area"] as? String ?? ""
            let signature = state + ":" + subtype
            if let prior = statusMap[signature] {sid = prior}
            else {
                let category: String
                switch state {
                case "done":category = "done"
                case LegacyStoredValue.canceled,"canceled","split":category = "canceled"
                case "parked","later","blocked","you":category = "parked"
                default:category = "queued"
                }
                let newID = uuid();try store(["id":newID,"project_id":pid,"revision":1,
                    "name":"Imported " + signature,"category":category,"sort_order":999,
                    "origin":"import","import_receipt_id":receiptID],"status")
                statusMap[signature] = newID
                sid = newID
            }
        }
        return sid!
    }

    private func resolveImportTags(_ raw: JSON,context: ImportRecordContext,tagMap: inout [String:String],
                                   store: (JSON,String) throws -> Void) throws -> [String] {
        let pid = context.projectID,receiptID = context.receiptID
        var tags = strings(raw,"tag_ids").compactMap {tagMap[$0]}
        for name in strings(raw,"tags") {
            if tagMap[name] == nil {let tagID = uuid();tagMap[name] = tagID;try store(["id":tagID,"project_id":pid,"revision":1,"name":name,"origin":"import","import_receipt_id":receiptID],"tag")}
            tags.append(tagMap[name]!)
        }
        return tags
    }

    private func importedTaskRecord(_ entry: TransferBundle.Entry,id: String,statusID: String,tags: [String],epic: String,
                                    number: Int,context: ImportRecordContext,project: JSON,caller: Caller) -> JSON {
        let raw = entry.payload,pid = context.projectID,receiptID = context.receiptID,time = context.time
        let kind = raw["kind"] as? String ?? "work"
        let ticketKey = "\(project["key_prefix"] as? String ?? "TASK")-\(number)"
        var task: JSON = ["id":id,"project_id":pid,"revision":1,"key":ticketKey,"title":raw["title"] ?? entry.sourceID,
            "brief":raw["brief"] ?? raw["detail"] ?? "","acceptance":raw["acceptance"] ?? [],
            "acceptance_revision":1,"kind":TicketKind.wireValues.contains(kind) ? kind : "work",
            "readiness":"draft","status_id":statusID,"tag_ids":tags,"epic_id":epic,"priority":"normal",
            "archived":raw["archived"] ?? false,"trashed":false,"origin":"import","created_by":caller.principal,
            "created_at":time,"updated_at":time,"import_receipt_id":receiptID,"source_id":entry.sourceID,
            "historical_unverified":true]
        if let note = raw["note"] {task["imported_note"] = note}
        if let state = raw["state"] {task["imported_state"] = state}
        return task
    }

    private func createImportRelations(_ entries: [TransferBundle.Entry],context: ImportRecordContext,
                                       store: (JSON,String) throws -> Void) throws {
        let pid = context.projectID,receiptID = context.receiptID
        for entry in entries where entry.family == "relation" {
            let raw = entry.payload
            guard let source = context.mapped("task",raw["source_task_id"] as? String) else {continue}
            var relation: JSON = ["id":context.mapped("relation",entry.sourceID)!,"project_id":pid,
                "revision":1,"source_task_id":source,"relation":raw["relation"] ?? "related_to",
                "required":raw["required"] ?? false,"state":raw["state"] ?? "active","origin":"import",
                "import_receipt_id":receiptID]
            if let target = context.mapped("task",raw["target_task_id"] as? String) {relation["target_task_id"] = target}
            else {relation["state"] = raw["state"] as? String == "removed" ? "removed" : "unresolved";relation["target_legacy_ref"] = raw["target_legacy_ref"] ?? raw["target_task_id"] ?? "missing"}
            try store(relation,"relation")
        }
    }

    private func createImportAttachments(_ bundle: TransferBundle,context: ImportRecordContext,
                                         store: (JSON,String) throws -> Void) throws {
        let pid = context.projectID,receiptID = context.receiptID,time = context.time
        for entry in bundle.entries where entry.family == "attachment" {
            let raw = entry.payload
            guard let tid = context.mapped("task",raw["task_id"] as? String) else {continue}
            var attachment: JSON = ["id":context.mapped("attachment",entry.sourceID)!,"project_id":pid,
                "revision":1,"task_id":tid,"name":raw["name"] ?? "Imported file","mode":"managed",
                "origin":"import","import_receipt_id":receiptID,"availability":"unavailable",
                "created_at":time]
            if let file = bundle.files.first(where:{$0.path == raw["path"] as? String}),file.bytes != nil {
                guard raw["sha256"] as? String == file.sha256 else {throw CoreError("IMPORT_CHECKSUM_MISMATCH","An available attachment differs from its export checksum.")}
                attachment["path"] = "objects/import-" + file.sha256!;attachment["sha256"] = file.sha256!;attachment["size"] = file.bytes!.count;attachment["availability"] = "available"
            } else {
                let prior = raw["availability"] as? String ?? "unavailable"
                attachment["availability"] = ["original_cleaned","original_missing","unavailable","damaged"].contains(prior) ? prior : "unavailable"
                attachment["source_reference_unavailable"] = true
            }
            if let preview = bundle.files.first(where:{$0.path == raw["preview_path"] as? String}),preview.bytes != nil {attachment["preview_path"] = "objects/import-" + preview.sha256!}
            for field in ["description","content_type","media_type"] {attachment[field] = raw[field]}
            try store(attachment,"attachment")
        }
    }

    private func archiveImportRecords(_ bundle: TransferBundle,context: ImportRecordContext,
                                      store: (JSON,String) throws -> Void) throws {
        let pid = context.projectID,receiptID = context.receiptID
        for entry in bundle.entries {
            try store(["id":uuid(),"project_id":pid,"revision":1,"import_receipt_id":receiptID,
                "source_namespace":bundle.namespace,"source_family":entry.family,"source_id":entry.sourceID,
                "payload":entry.payload,"authority":"historical_unverified"],"import_record")
        }
        // Preserve the entire envelope too: unknown fields, settings, decision
        // logs and future source tags cannot disappear behind a mapping allowlist.
        try store(["id":uuid(),"project_id":pid,"revision":1,"import_receipt_id":receiptID,
            "source_namespace":bundle.namespace,"source_family":"envelope","source_id":"/",
            "payload":bundle.document,"authority":"historical_unverified"],"import_record")
    }

    private func rollbackProjectImport(_ db: Database,_ params: JSON,_ caller: Caller,pid: String,project: JSON) throws -> JSON {
        var receipt = try scoped(db,text(params,"receipt_id"),pid,type:"import_receipt")
        try revision(params,receipt)
        guard receipt["state"] as? String == "committed",try importDestinationDigest(db,pid) == receipt["post_digest"] as? String else {throw CoreError("IMPORT_ROLLBACK_CHANGED","Destination work changed after import. Preserve it and preview compensating reconciliation instead.")}
        for id in strings(receipt,"created_ids") {try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT)",arguments:[Data(id.utf8),Data(pid.utf8)])}
        var previous = try StoredRecord(receipt,family:"import_receipt").object("previous_project")
        previous["revision"] = int(project,"revision")+1
        previous["updated_at"] = now()
        try save(db,previous,type:"project")
        receipt = revised(receipt);receipt["state"] = "rolled_back";receipt["rolled_back_by"] = caller.principal;try save(db,receipt,type:"import_receipt")
        try event(db,caller:caller,project:pid,entity:receipt["id"] as? String,kind:"project_import_rolled_back",data:["preserved_managed_bytes":true])
        return ["receipt_id":receipt["id"]!,"state":"rolled_back","revision":receipt["revision"]!,"preserved_managed_bytes":true]
    }
}
