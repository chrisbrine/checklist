import Foundation
import GRDB
import ImageIO

/// Command-local values. File reads/decodes, hashes and import finalization finish before
/// the canonical snapshot is prepared. None of this is a second durable store.
struct PreparedMediaResources {
    struct Capture {
        let owner: MediaAttachmentOwner
        let prepared: ManagedAttachmentPreparation
        let encodedReceipt: String
    }
    var nativeOwnerProjection = false
    var preview: [JSON] = []
    var captures: [String:Capture] = [:]
    var errors: [String:String] = [:]
    var originals: [PreparedAttachmentOriginal] = []
    func allows(_ envelope: DecodedEnvelope) -> Bool {
        let value = envelope.object
        if envelope.type == "storage_job" { return value["kind"] as? String == "media_attachment_owner" || captures.values.contains { $0.prepared.job["id"] as? String == envelope.id } }
        if envelope.type == "storage_hold" { return value["kind"] as? String == "media_reference" }
        if envelope.type == "attachment" { return captures.values.contains { $0.prepared.attachment["id"] as? String == envelope.id } }
        return false
    }
}

extension CommandRouter {
    /// Deliberately private to the internal router seam. Even an owner input is a selected
    /// regular file, never a directory traversal, URL fetch or a new filesystem grant.
    func mediaInspectFile(_ path: String,caller: Caller,project: JSON,managed: Bool = false,reserveRead: ((Int) throws -> Void)? = nil) throws -> JSON {
        let path = managed ? try managedURL(path,family:"objects").path : path
        guard path.hasPrefix("/"),path.utf8.count <= 4096 else { throw CoreError("FILE_ACCESS_REQUIRED","Select an absolute local file.") }
        let url = StoreDirectory.anchoredRoot(URL(fileURLWithPath:path))
        if managed {
            guard path.hasPrefix(root.path + "/objects/") else { throw CoreError("FORBIDDEN","Expected a managed original.") }
        } else if !caller.isOwner {
            guard let workspace = caller.workspace,let base = project["root_path"] as? String,
                  containsPath(canonical(workspace),canonical(path)),containsPath(base,canonical(path)) else { throw CoreError("FILE_ACCESS_REQUIRED","Select within the enrolled workspace.") }
        }
        func identity() throws -> FileIdentity? { managed ? try managedIdentity(path) : FileIdentity(path:url.path) }
        guard let before = try identity() else { throw CoreError("MEDIA_SOURCE_UNAVAILABLE","The selected regular file is unavailable.") }
        guard before.size >= 0,before.size <= 500 * 1024 * 1024 else { throw StorageSnapshotFailure.limit }
        let size = Int(before.size)
        // Reserve before reading: failed reads/decodes consume the same preview budget.
        // Read only the observed length so a growing/replaced source cannot exceed it.
        try reserveRead?(size)
        let bytes = try StorageObjectFiles(root:url.deletingLastPathComponent()).openRegular(url.lastPathComponent) { descriptor in
            let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
            var bytes = Data()
            while bytes.count < size {
                guard let chunk = try file.read(upToCount:min(65_536,size - bytes.count)),!chunk.isEmpty else {break}
                bytes.append(chunk)
            }
            return bytes
        }
        guard bytes.count == size,(try identity()) == before else { throw CoreError("SOURCE_CHANGED","The source changed during preview.") }
        let kind: String
        if let image = CGImageSourceCreateWithData(bytes as CFData,nil),CGImageSourceGetCount(image) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any] ?? [:]
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0,height > 0,width <= 16_000_000 / height,
                  CGImageSourceCreateImageAtIndex(image,0,[kCGImageSourceShouldCache:false] as CFDictionary) != nil else { throw CoreError("MEDIA_UNSUPPORTED","Image decoding or dimensions exceed the bounded intake capability.") }
            kind = "image"
        } else if ["txt","md"].contains(url.pathExtension.lowercased()),bytes.count <= 256 * 1024,String(data:bytes,encoding:.utf8) != nil {
            kind = "text"
        } else {
            // Byte-only PCM WAV validation cannot follow a playlist, reference movie
            // or embedded remote URL. Broader native codecs remain explicitly unsupported.
            guard MediaIntakeWAV.validate(bytes) else { throw CoreError("MEDIA_UNSUPPORTED","Unsupported selected media.") }
            kind = "audio"
        }
        guard (try identity()) == before else { throw CoreError("SOURCE_CHANGED","The selected source changed during validation.") }
        var result: JSON = ["path":url.path,"sha256":hash(bytes),"size":bytes.count,"media_kind":kind]
        if kind == "text" { result["text"] = String(data:bytes,encoding:.utf8)! }
        return result
    }

    func prepareMediaResources(method: String,params p: JSON,caller c: Caller) throws -> PreparedMediaResources {
        var resources = PreparedMediaResources()
        // These methods have no media bytes to prepare. Ordinary canonical preparation
        // below still performs their authority, receipt and context validation.
        guard ["media_intake_preview","media_intake_capture","media_round_publish","media_context_reconcile"].contains(method) else {return resources}
        // Authorize and reconcile a committed command BEFORE any source access. Intent
        // conflicts also precede file work, including other methods' pending journals.
        let snapshot: (String,JSON,JSON?)? = try dbQueue.read { db in
            let pid = try self.mediaAccess(db,p,c,write:true)
            let command = try text(p,"command_id",max:100),digest = hash(Data((method + (try jsonString(p))).utf8))
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
            if let row = try Row.fetchOne(db,sql:"SELECT digest FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT","The command has another intent.") };return nil
            }
            var intake: JSON?
            if method == "media_intake_preview" { _ = try self.scoped(db,try text(p,"round_id"),pid,type:"media_round") }
            if method == "media_intake_capture" {
                let selected = try self.scoped(db,try text(p,"intake_id"),pid,type:"media_intake")
                try self.mediaCaptureSelection(db,p:p,intake:selected,caller:c)
                intake = selected
            }
            return (pid,try self.record(db,pid,type:"project"),intake)
        }
        guard let (pid,project,intake) = snapshot else { return resources }
        if method == "media_intake_preview" {
            guard p["mapping"] == nil || p["mapping"] is JSON else { throw CoreError("INVALID_INPUT","Mapping must be an object.") }
            let inputs = [p["sources"],p["text"],p["tsv"]].filter {$0 != nil}
            guard inputs.count == 1 else { throw CoreError("INVALID_INPUT","Select files, paste lines or paste literal TSV.") }
            if let sources = p["sources"] as? [JSON] {
                guard !sources.isEmpty,sources.count <= 1000 else { throw CoreError("INVALID_INPUT","Select 1 to 1,000 files.") }
                var total = 0
                for (index,source) in sources.enumerated() {
                    guard Set(source.keys).isSubset(of:["path","columns"]),let path = source["path"] as? String,path.utf8.count <= 4096 else { throw CoreError("INVALID_INPUT","Use bounded selected local paths and scalar columns.") }
                    guard source["columns"] == nil || source["columns"] is JSON else { throw CoreError("INVALID_INPUT","Columns must be an object of bounded scalars.") }
                    let columns = source["columns"] as? JSON ?? [:]
                    for key in ["title","slot","group"] where columns[key] != nil { _ = try text(columns,key,max:key == "title" ? 2000 : 256) }
                    let url = URL(fileURLWithPath:path)
                    var row: JSON = ["source_index":index,"name":url.lastPathComponent,"stem":url.deletingPathExtension().lastPathComponent,"path":path,"columns":source["columns"] ?? [:]]
                    do {
                        let inspected = try mediaInspectFile(path,caller:c,project:project,reserveRead:{ size in
                            guard size <= 1024 * 1024 * 1024 - total else { throw CoreError("CAPACITY_EXCEEDED","Selected preview exceeds 1 GiB of inspected originals.") }
                            total += size
                        })
                        row.merge(inspected) {_,new in new};row["status"] = "valid"
                    } catch let error as CoreError where error.code == "CAPACITY_EXCEEDED" { throw error }
                    catch { row["status"] = (error as? CoreError)?.code == "MEDIA_UNSUPPORTED" ? "unsupported" : "missing";row["error_code"] = (error as? CoreError)?.code ?? "MEDIA_SOURCE_UNAVAILABLE" }
                    resources.preview.append(row)
                }
                resources.preview.sort { a,b in
                    let first = a["name"] as! String,second = b["name"] as! String
                    let order = first.compare(second,options:[.numeric,.literal],locale:Locale(identifier:"en_US_POSIX"))
                    if order != .orderedSame {return order == .orderedAscending}
                    if Data(first.utf8) != Data(second.utf8) {return Data(first.utf8).lexicographicallyPrecedes(Data(second.utf8))}
                    return int(a,"source_index") < int(b,"source_index")
                }
            } else if let text = p["text"] as? String {
                guard text.utf8.count <= 1024 * 1024 else { throw CoreError("INVALID_INPUT","Pasted lines exceed 1 MiB.") }
                resources.preview = text.components(separatedBy:"\n").enumerated().filter { !$0.element.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.map { index,line in
                    ["source_index":index,"name":"Pasted line \(index + 1)","stem":String(line.prefix(200)),"text":line,"sha256":hash(Data(line.utf8)),"size":line.utf8.count,"media_kind":"text","status":"valid","columns":JSON()]
                }
            } else if let tsv = p["tsv"] as? String {
                // CRLF is one Swift Character, so hasSuffix("\n") does not
                // detect it. Count with the same literal splitting as the parser.
                let lines = tsv.components(separatedBy:"\n")
                let count = lines.count - (lines.last == "" ? 2 : 1)
                guard (1...1000).contains(count) else { throw CoreError("INVALID_INPUT","Paste 1 to 1,000 TSV entries.") }
                let parsed = try MediaIntakeSourceRow.tsv(tsv,rowIDs:(0..<count).map {try MediaReviewID("row-\($0)")})
                resources.preview = try parsed.map { row in
                    guard Set(row.columns.map(\.id)).count == row.columns.count else { throw CoreError("INVALID_INPUT","TSV column names must be unambiguous for durable capture.") }
                    let columns = Dictionary(row.columns.map {($0.id.rawValue,$0.value)},uniquingKeysWith:{a,_ in a})
                    for key in ["title","slot","group"] where (columns[key] as? String)?.isEmpty == false { _ = try text(columns,key,max:key == "title" ? 2000 : 256) }
                    guard let text = columns["text"] as? String,!text.isEmpty else { throw CoreError("INVALID_INPUT","TSV row \(row.sourceIndex + 1) needs nonempty literal text in the text column.") }
                    return ["source_index":row.sourceIndex,"name":"TSV row \(row.sourceIndex + 1)","stem":columns["title"] ?? String(text.prefix(200)),"text":text,"sha256":hash(Data(text.utf8)),"size":text.utf8.count,"media_kind":"text","status":"valid","columns":columns]
                }
            } else { throw CoreError("INVALID_INPUT","Invalid selected source input.") }
            guard !resources.preview.isEmpty,resources.preview.count <= 1000,resources.preview.allSatisfy({int($0,"size") <= ($0["media_kind"] as? String == "text" ? 256 * 1024 : 500 * 1024 * 1024)}) else { throw CoreError("INVALID_INPUT","Input exceeds the row/text limit.") }
            var seen: [String:Int] = [:]
            for i in resources.preview.indices {
                if let sha = resources.preview[i]["sha256"] as? String {
                    if let first = seen[sha] {resources.preview[i]["status"] = "duplicate";resources.preview[i]["duplicate_source_index"] = int(resources.preview[first],"source_index")}
                    else {seen[sha] = i}
                }
            }
        }
        if method == "media_intake_capture",let intake {
            // Reserve the enclosing command before staging even the first row. A crash
            // leaves both this intent and each original row's import UUID recoverable.
            try ArchiveStorageGate.withExclusive(root:root) { _ in try dbQueue.write { db in
                let command = p["command_id"] as! String,digest = hash(Data((method + (try jsonString(p))).utf8))
                _ = try self.mediaAccess(db,p,c,write:true)
                try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
                let key = try self.pendingStorageCommandKey(principal:c.principal,command:command)
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try jsonString(["kind":method,"intent_digest":digest])])
            } }
            let rows = try dbQueue.read { db in try self.mediaCaptureSelection(db,p:p,intake:intake,caller:c) }
            let owner = MediaAttachmentOwner(id:intake["attachment_owner_id"] as! String,kind:.intake,revision:1)
            for row in rows where row["capture_state"] as? String != "committed" && row["path"] is String && row["media_kind"] as? String != "text" {
                let id = row["id"] as! String
                do {
                    guard let prepared = try prepareMediaAttachmentImport(project:pid,owner:owner,commandID:row["import_command_id"] as! String,path:row["path"] as! String,caller:c,expectedSHA256:row["sha256"] as? String) else { throw CoreError("MANAGED_IMPORT_RECOVERY_REQUIRED","Reconcile the original row receipt.") }
                    // Revalidate the managed copy, never substitute changed chooser bytes.
                    let validation = try mediaInspectFile(prepared.attachment["path"] as! String,caller:c,project:project,managed:true)
                    guard validation["sha256"] as? String == row["sha256"] as? String,validation["media_kind"] as? String == row["media_kind"] as? String else { throw CoreError("SOURCE_CHANGED","Captured media differs from the frozen preview.") }
                    resources.captures[id] = .init(owner:owner,prepared:prepared,encodedReceipt:try jsonString(["data":prepared.attachment]))
                } catch { resources.errors[id] = (error as? CoreError)?.code ?? "MEDIA_SOURCE_UNAVAILABLE" }
            }
            // Selected UTF-8 files use their frozen text, but still revalidate the original
            // before capture. Pasted text has no external source to reread.
            for row in rows where row["capture_state"] as? String != "committed" && row["media_kind"] as? String == "text" && row["path"] is String {
                do { guard try mediaInspectFile(row["path"] as! String,caller:c,project:project)["sha256"] as? String == row["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","Selected text changed.") } }
                catch {resources.errors[row["id"] as! String] = (error as? CoreError)?.code ?? "MEDIA_SOURCE_UNAVAILABLE"}
            }
        }
        if method == "media_round_publish" || method == "media_context_reconcile" {
            // A publication must account for every included intake row, even if a
            // caller supplies a smaller selection of otherwise valid Drafts.
            let attachments: [JSON] = try dbQueue.read { db in
                try self.owner(c)
                let round = try self.scoped(db,try text(p,"round_id"),pid,type:"media_round")
                try self.mediaObserve(db,p,round:round,caller:c,allowAttention:method == "media_context_reconcile")
                if method == "media_round_publish" { try self.mediaValidateIntakePublication(db,round:round,selection:p["items"] as? [JSON] ?? []) }
                let ids = Set((p["items"] as? [JSON] ?? []).compactMap {$0["item_id"] as? String})
                var byID: [String:JSON] = [:]
                for item in try self.mediaItems(db,round:round) where method == "media_context_reconcile" || ids.contains(item["id"] as! String) {
                    let target = try self.scoped(db,item["draft_target_id"] as! String,pid,type:"media_item_target")
                    for reference in strings(target,"attachment_reference_ids") {
                        let owner = try self.mediaOwnerValue(db,id:target["attachment_owner_id"] as! String,project:pid)
                        let (_,a) = try self.mediaAttachmentReference(db,project:pid,id:reference,owner:owner,caller:c)
                        byID[a["id"] as! String] = a
                    }
                };return Array(byID.values)
            }
            resources.originals = try attachments.map(prepareAttachmentOriginal)
        }
        return resources
    }

    func mediaOwnerValue(_ db: Database,id: String,project: String) throws -> MediaAttachmentOwner {
        let value = try scoped(db,id,project,type:"storage_job")
        guard let kind = MediaAttachmentOwnerKind(rawValue:value["owner_kind"] as? String ?? "") else { throw CoreError("ATTACHMENT_OWNER_STALE","Unknown media owner.") }
        return .init(id:id,kind:kind,revision:int(value,"revision"))
    }
    func mediaPreparedOwner(_ db: Database,project: String,kind: MediaAttachmentOwnerKind,caller: Caller) throws -> JSON {
        let value: JSON = ["id":uuid(),"project_id":project,"kind":"media_attachment_owner","owner_kind":kind.rawValue,"state":kind == .target ? "draft" : "active","revision":1,"author":caller.principal,"created_at":now()]
        try save(db,value,type:"storage_job");return value
    }
    func mediaIntakeRows(_ db: Database,intake: JSON) throws -> [JSON] {
        try strings(intake,"row_ids").map {try scoped(db,$0,intake["project_id"] as! String,type:"media_intake_row")}
    }
    func mediaIntakeView(_ db: Database,intake: JSON) throws -> JSON {
        var result = intake;let rows = try mediaIntakeRows(db,intake:intake)
        let groups = Dictionary(grouping:rows.filter {$0["disposition"] as? String == "include"},by:{Data(($0["group_id"] as! String).utf8)})
        result["groups"] = try groups.values.map { members -> JSON in
            let ordered = members.sorted {int($0,"order") < int($1,"order")},first = ordered[0]
            let committed = try members.first {$0["capture_state"] as? String == "committed"}.map {try scoped(db,$0["item_id"] as! String,intake["project_id"] as! String,type:"media_item")}
            return ["group_id":first["group_id"]!,"title":committed?["title"] ?? first["title"]!,"order":committed?["order"] ?? first["order"]!,"row_ids":ordered.map {$0["id"]!},"slot_ids":ordered.map {$0["slot_id"] ?? NSNull()}]
        }.sorted {int($0,"order") < int($1,"order")}
        result["rows"] = rows;result["plan"] = try scoped(db,intake["plan_id"] as! String,intake["project_id"] as! String,type:"media_intake_plan")
        result["committed_row_ids"] = rows.filter {$0["capture_state"] as? String == "committed"}.map {$0["id"]!}
        result["remaining_row_ids"] = rows.filter {$0["capture_state"] as? String != "committed" && $0["disposition"] as? String == "include"}.map {$0["id"]!}
        result["skipped_row_ids"] = rows.filter {$0["disposition"] as? String == "skip"}.map {$0["id"]!}
        return result
    }
    @discardableResult func mediaCaptureSelection(_ db: Database,p: JSON,intake: JSON,caller: Caller) throws -> [JSON] {
        try mediaRevision(p,intake)
        guard intake["author"] as? String == caller.principal || caller.isOwner else { throw CoreError("FORBIDDEN","Capture belongs to its original intake author.") }
        let planID = try text(p,"plan_id")
        guard intake["confirmed_plan_id"] as? String == intake["plan_id"] as? String,planID == intake["plan_id"] as? String else { throw CoreError("MEDIA_PLAN_REQUIRED","Confirm the exact current included/skipped mapping first.") }
        guard let ids = p["row_ids"] as? [String],!ids.isEmpty,ids.count <= 200,Set(ids).count == ids.count else { throw CoreError("INVALID_INPUT","Select 1 to 200 distinct original row IDs.") }
        let rows = try mediaIntakeRows(db,intake:intake),byID = Dictionary(uniqueKeysWithValues:rows.map {($0["id"] as! String,$0)})
        return try ids.map {id in
            _ = try text(["row_id":id],"row_id")
            guard let row = byID[id],row["disposition"] as? String == "include" else { throw CoreError("INVALID_INPUT","Capture only explicitly included rows from this intake.") };return row
        }
    }
    func mediaApplyMapping(_ rows: [JSON],mapping: JSON,schema: MediaReviewSchema,resolutions: [JSON]) throws -> [JSON] {
        let plan = try MediaIntakePlan.parse(mapping,schema:schema)
        let inputs = try rows.enumerated().map { index,row in
            MediaIntakeSourceRow(id:try MediaReviewID(row["id"] as! String),sourceIndex:int(row,"source_index"),stem:plan.input == .selectedFiles ? row["stem"] as? String : nil,columns:try (row["columns"] as? JSON ?? [:]).map {.init(id:try MediaReviewID($0.key),value:$0.value)})
        }
        let mapped = try plan.map(inputs,schema:schema)
        for resolution in resolutions { _ = try text(resolution,"row_id") }
        guard Set(resolutions.compactMap {$0["row_id"] as? String}).count == resolutions.count,
              resolutions.allSatisfy({r in rows.contains {$0["id"] as? String == r["row_id"] as? String && $0["capture_state"] as? String != "committed"}}) else { throw CoreError("INVALID_INPUT","Resolve only distinct uncommitted rows of this intake.") }
        return try zip(rows,mapped).map { original,mapped in
            if original["capture_state"] as? String == "committed" {return original}
            var row = original,metadata: JSON = [:]
            for (id,value) in mapped.metadata {
                switch value {case .text(let v):metadata[id.rawValue] = v;case .number(let v):metadata[id.rawValue] = v;case .boolean(let v):metadata[id.rawValue] = v;case .choice(let v):metadata[id.rawValue] = v.rawValue}
            }
            row["metadata"] = metadata;row["mapping_errors"] = mapped.diagnostics.map { ["field_id":$0.fieldID.rawValue,"reason":$0.reason.rawValue] }
            let compatible = schema.slots.filter {$0.kind.rawValue == row["media_kind"] as? String}
            if row["slot_id"] == nil,compatible.count == 1 {row["slot_id"] = compatible[0].id.rawValue}
            if let resolution = resolutions.first(where:{$0["row_id"] as? String == row["id"] as? String}) {
                guard Set(resolution.keys).isSubset(of:["row_id","disposition","slot_id","group_id","title"]),let disposition = resolution["disposition"] as? String,["include","skip"].contains(disposition) else { throw CoreError("INVALID_INPUT","Resolve explicitly to include or skip.") }
                row["disposition"] = disposition
                for key in ["slot_id","group_id","title"] {if resolution[key] != nil {row[key] = try text(resolution,key,max:key == "title" ? 2000 : 256)}}
            }
            if row["disposition"] as? String == "include" {
                guard row["status"] as? String == "valid" || row["status"] as? String == "duplicate",mapped.diagnostics.isEmpty,
                      compatible.contains(where:{$0.id.rawValue == row["slot_id"] as? String}) else {
                    row["disposition"] = "unresolved";row["resolution_error"] = "MEDIA_MAPPING_REQUIRED";return row
                }
            }
            row.removeValue(forKey:"resolution_error")
            return row
        }
    }
    func mediaSavePlan(_ db: Database,intake: inout JSON,rows: [JSON],mapping: JSON,caller: Caller) throws {
        let pid = intake["project_id"] as! String,revision = int(intake,"plan_revision") + 1
        let entries = rows.map {row -> JSON in
            var entry = row
            for key in ["record_references","revision","author","origin","created_at","author_session_id"] {entry.removeValue(forKey:key)}
            return entry
        }
        let previous = try (intake["plan_id"] as? String).map {try scoped(db,$0,pid,type:"media_intake_plan")}
        let shape: JSON = ["intake_id":intake["id"]!,"plan_revision":revision,"mapping":mapping,"rows":entries]
        let plan = mediaRecord(shape.merging(["digest":try MediaCanonical.signature(shape)]) {_,b in b},project:pid,caller:caller,references:[mediaRef("media_intake",intake)] + rows.map {mediaRef("media_intake_row",$0)} + (previous.map {[mediaRef("media_intake_plan",$0)]} ?? []))
        try mediaWrite(db,plan,type:"media_intake_plan")
        for var row in rows where row["capture_state"] as? String != "committed" {
            row["plan_id"] = plan["id"];row["mapping_revision"] = revision;row["capture_state"] = "uncommitted"
            row.removeValue(forKey:"capture_error")
            row["record_references"] = [mediaRef("media_intake",intake),mediaRef("media_intake_plan",plan)]
            if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE id=?)",arguments:[row["id"] as! String]) == true {row = revised(row)}
            try mediaWrite(db,row,type:"media_intake_row")
        }
        intake["plan_id"] = plan["id"];intake["plan_revision"] = revision;intake.removeValue(forKey:"confirmed_plan_id")
        intake["record_references"] = (intake["record_references"] as? [JSON] ?? []) + [mediaRef("media_intake_plan",plan)]
        try mediaWrite(db,intake,type:"media_intake")
    }
    func mediaIntakeCommand(_ db: Database,method: String,p: JSON,c: Caller,project pid: String,resources: PreparedMediaResources) throws -> JSON {
        if method == "media_intake_preview" {
            let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
            guard round["state"] as? String == "draft" || round["state"] as? String == "open" else { throw CoreError("MEDIA_ROUND_CLOSED","Intake needs an editable round.") }
            let (type,_) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse(type["schema"] as! JSON)
            let owner = try mediaPreparedOwner(db,project:pid,kind:.intake,caller:c)
            var intake = mediaRecord(["round_id":round["id"]!,"attachment_owner_id":owner["id"]!,"state":"preview","plan_revision":0],project:pid,caller:c,references:[mediaRef("media_round",round),mediaRef("storage_job",owner),mediaRef("media_review_type_revision",type)])
            var rows: [JSON] = resources.preview.enumerated().map {index,source in
                let columns = source["columns"] as? JSON ?? [:]
                var row = mediaRecord(source,project:pid,caller:c,references:[mediaRef("media_intake",intake)])
                row["order"] = index;row["title"] = columns["title"] ?? source["stem"] ?? source["name"]
                row["title"] = try? text(row,"title",max:2000)
                if row["title"] == nil {row["title"] = "Untitled selected file"}
                row["group_id"] = (columns["group"] as? String).flatMap {$0.isEmpty ? nil : $0} ?? row["id"]!;row["slot_id"] = columns["slot"]
                row["capture_state"] = "uncommitted";row["disposition"] = source["status"] as? String == "valid" ? "include" : "unresolved"
                row["import_command_id"] = uuid();return row
            }
            let mapping = p["mapping"] as? JSON ?? ["input":p["sources"] != nil ? "selected_files" : p["tsv"] != nil ? "tsv" : "explicit_metadata"]
            rows = try mediaApplyMapping(rows,mapping:mapping,schema:schema,resolutions:[])
            if p["tsv"] != nil || p["text"] != nil,
               let row = rows.first(where:{!($0["mapping_errors"] as? [JSON] ?? []).isEmpty}),
               let error = (row["mapping_errors"] as? [JSON])?.first {
                let reason: String
                switch error["reason"] as? String {
                case "missingValue": reason = "a value is missing"
                case "ambiguousColumn": reason = "the source column is ambiguous"
                default: reason = "the value is invalid for this field"
                }
                throw CoreError("INVALID_INPUT","Pasted row \(int(row,"source_index") + 1), field \(error["field_id"] as? String ?? "metadata"): \(reason). Correct the pasted data or mapping before previewing.")
            }
            intake["row_ids"] = rows.map {$0["id"]!};try mediaSavePlan(db,intake:&intake,rows:rows,mapping:mapping,caller:c)
            return try mediaIntakeView(db,intake:intake)
        }
        var intake = try scoped(db,try text(p,"intake_id"),pid,type:"media_intake");try mediaRevision(p,intake)
        guard c.isOwner || intake["author"] as? String == c.principal else { throw CoreError("FORBIDDEN","Only this intake's author or owner may change its plan.") }
        let round = try scoped(db,intake["round_id"] as! String,pid,type:"media_round")
        guard ["draft","open"].contains(round["state"] as? String ?? "") else { throw CoreError("MEDIA_ROUND_CLOSED","Closed round intake is immutable.") }
        if method == "media_intake_revise" {
            let (type,_) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse(type["schema"] as! JSON)
            let old = try scoped(db,intake["plan_id"] as! String,pid,type:"media_intake_plan")
            guard p["mapping"] == nil || p["mapping"] is JSON else { throw CoreError("INVALID_INPUT","Mapping must be an object.") }
            let mapping = p["mapping"] as? JSON ?? old["mapping"] as! JSON
            guard p["resolutions"] == nil || p["resolutions"] is [JSON] else { throw CoreError("INVALID_INPUT","Use bounded row resolutions.") }
            let rows = try mediaApplyMapping(mediaIntakeRows(db,intake:intake),mapping:mapping,schema:schema,resolutions:p["resolutions"] as? [JSON] ?? [])
            intake = revised(intake);try mediaSavePlan(db,intake:&intake,rows:rows,mapping:mapping,caller:c)
        } else if method == "media_intake_confirm" {
            let plan = try scoped(db,intake["plan_id"] as! String,pid,type:"media_intake_plan")
            guard try text(p,"plan_id") == plan["id"] as? String,p["plan_digest"] as? String == plan["digest"] as? String else { throw CoreError("MEDIA_PLAN_REQUIRED","Confirm the current exact plan digest.") }
            let rows = try mediaIntakeRows(db,intake:intake)
            guard rows.allSatisfy({["include","skip"].contains($0["disposition"] as? String ?? "")}) else { throw CoreError("MEDIA_MAPPING_REQUIRED","Resolve every included/skipped row, duplicate and slot first.") }
            let grouped = Dictionary(grouping:rows.filter {$0["disposition"] as? String == "include"},by:{Data(($0["group_id"] as! String).utf8)})
            let (type,_) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse(type["schema"] as! JSON)
            for group in grouped.values {
                guard group.count <= schema.maxCandidates,Set(try group.map {Data(try jsonString($0["metadata"] as! JSON).utf8)}).count == 1 else { throw CoreError("MEDIA_MAPPING_REQUIRED","Grouped candidates need compatible metadata and bounded candidate count.") }
            }
            intake["confirmed_plan_id"] = plan["id"];intake["state"] = "capturing";intake = revised(intake);try mediaWrite(db,intake,type:"media_intake")
        } else if method == "media_intake_capture" {
            let selected = try mediaCaptureSelection(db,p:p,intake:intake,caller:c)
            var committed: [String] = [],failed: [String] = []
            for var row in selected where row["capture_state"] as? String != "committed" {
                let id = row["id"] as! String
                if let error = resources.errors[id] {
                    row["capture_state"] = "failed";row["capture_error"] = ["code":String(error.prefix(100)),"message":"The frozen source was not captured. Reconcile this row before retrying."]
                    try mediaWrite(db,revised(row),type:"media_intake_row");failed.append(id);continue
                }
                try mediaCaptureRow(db,row:&row,intake:intake,round:round,caller:c,resources:resources)
                committed.append(id)
            }
            let rows = try mediaIntakeRows(db,intake:intake)
            let remaining = rows.filter {$0["disposition"] as? String == "include" && $0["capture_state"] as? String != "committed"}.map {$0["id"]!}
            let chunk = mediaRecord(["intake_id":intake["id"]!,"plan_id":intake["plan_id"]!,"selected_row_ids":selected.map {$0["id"]!},"committed_row_ids":committed,"failed_row_ids":failed,"uncommitted_row_ids":remaining],project:pid,caller:c,references:[mediaRef("media_intake",intake),["type":"media_intake_plan","id":intake["plan_id"]!,"revision":1]] + selected.map {mediaRef("media_intake_row",$0)})
            try mediaWrite(db,chunk,type:"media_intake_chunk")
            intake["chunk_ids"] = strings(intake,"chunk_ids") + [chunk["id"] as! String];intake["state"] = remaining.isEmpty ? "captured" : "partial"
            intake["record_references"] = (intake["record_references"] as! [JSON]) + [mediaRef("media_intake_chunk",chunk)]
            intake = revised(intake);try mediaWrite(db,intake,type:"media_intake")
        } else {throw CoreError("UNSUPPORTED_METHOD","Unknown intake command.")}
        return try mediaIntakeView(db,intake:intake)
    }
    func mediaCaptureRow(_ db: Database,row: inout JSON,intake: JSON,round: JSON,caller: Caller,resources: PreparedMediaResources) throws {
        let pid = intake["project_id"] as! String
        // An explicit group key is local to this intake; equal names/content never join.
        let peers = try mediaIntakeRows(db,intake:intake)
        let existing = peers.first {$0["capture_state"] as? String == "committed" && EnvelopeStorageIdentity.equal($0["group_id"] as? String,row["group_id"] as? String)}
        var item: JSON,previous: JSON?
        if let existing {
            item = try scoped(db,existing["item_id"] as! String,pid,type:"media_item")
            previous = try scoped(db,item["draft_target_id"] as! String,pid,type:"media_item_target")
            // Never extend a group whose original Draft ownership was published/released.
            if let ownerID = previous?["attachment_owner_id"] as? String,try mediaOwnerValue(db,id:ownerID,project:pid).kind == .target {throw CoreError("MEDIA_PLAN_REQUIRED","Finish this frozen group before publication.")}
            item = revised(item)
        } else {
            guard try mediaItems(db,round:round).count < 1000 else {throw CoreError("CAPACITY_EXCEEDED","A round holds at most 1,000 items.")}
            let first = peers.filter {$0["disposition"] as? String == "include" && EnvelopeStorageIdentity.equal($0["group_id"] as? String,row["group_id"] as? String)}.min {int($0,"order") < int($1,"order")}!
            item = mediaRecord(["round_id":round["id"]!,"title":first["title"]!,"state":"draft","order":first["order"]!,"intake_id":intake["id"]!],project:pid,caller:caller,references:[mediaRef("media_round",round),mediaRef("media_intake",intake)])
        }
        let (type,context) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse(type["schema"] as! JSON)
        var references: [JSON] = [mediaRef("media_item",item)],slot: JSON = ["slot_id":row["slot_id"]!,"sha256":row["sha256"]!]
        var ownerID = previous?["attachment_owner_id"] as? String,referenceIDs = strings(previous ?? [:],"attachment_reference_ids")
        if row["media_kind"] as? String == "text" {slot["text"] = row["text"]!;slot["encoding"] = "utf-8-exact-v1"}
        else {
            guard let capture = resources.captures[row["id"] as! String] else {throw CoreError("MEDIA_CAPTURE_REQUIRED","A prepared original is required.")}
            let prepared = capture.prepared
            try save(db,prepared.attachment,type:"attachment")
            var job = prepared.job;job["state"] = "committed";job["completed_at"] = now();try save(db,revised(job),type:"storage_job")
            let intakeReference = try addMediaAttachmentReference(db,project:pid,owner:capture.owner,attachment:prepared.attachment,caller:caller)
            if ownerID == nil {ownerID = try mediaPreparedOwner(db,project:pid,kind:.draftItem,caller:caller)["id"] as? String}
            let draftOwner = try mediaOwnerValue(db,id:ownerID!,project:pid)
            let draftReference = try addMediaAttachmentReference(db,project:pid,owner:draftOwner,attachment:prepared.attachment,caller:caller)
            var released = intakeReference;released["state"] = "released";try save(db,revised(released),type:"storage_hold")
            referenceIDs.append(draftReference["id"] as! String)
            slot["attachment_id"] = prepared.attachment["id"];slot["media_kind"] = row["media_kind"];slot["size"] = row["size"]
            // Original ownership stays explicit in immutable candidate history even after
            // handover releases that reference. The target carries the active holds.
            slot["reference_id"] = draftReference["id"];slot["owner_id"] = ownerID
            references += [mediaRef("attachment",prepared.attachment),mediaRef("storage_job",job),mediaRef("storage_hold",intakeReference),mediaRef("storage_hold",draftReference)]
        }
        let candidate = mediaRecord(["item_id":item["id"]!,"slots":[slot],"content_signature":try MediaCanonical.signature([slot]),"source_name":row["name"]!,"intake_row_id":row["id"]!],project:pid,caller:caller,references:references + [mediaRef("media_intake_row",row)])
        try mediaWrite(db,candidate,type:"media_candidate")
        var candidates = try strings(previous ?? [:],"candidate_ids").map {try scoped(db,$0,pid,type:"media_candidate")};candidates.append(candidate)
        candidates.sort { ($0["id"] as! String) < ($1["id"] as! String) }
        guard candidates.count <= schema.maxCandidates else {throw CoreError("MEDIA_MAPPING_REQUIRED","The frozen group exceeds the type's candidate limit.")}
        let shape = try mediaTargetShape(db,item:item,title:item["title"] as! String,metadata:row["metadata"] as! JSON,candidates:candidates,typeRevision:type,context:context)
        var ownedShape = shape;ownedShape["attachment_owner_id"] = ownerID;ownedShape["attachment_reference_ids"] = referenceIDs
        let target = try mediaTarget(db,item:item,shape:ownedShape,caller:caller,previous:previous)
        item["draft_target_id"] = target["id"];item["record_references"] = (item["record_references"] as! [JSON]) + [mediaRef("media_item_target",target)]
        try mediaWrite(db,item,type:"media_item")
        row["capture_state"] = "committed";row["item_id"] = item["id"];row["target_id"] = target["id"];row["candidate_id"] = candidate["id"]
        row.removeValue(forKey:"capture_error")
        row["record_references"] = (row["record_references"] as! [JSON]) + [mediaRef("media_item",item),mediaRef("media_item_target",target),mediaRef("media_candidate",candidate)]
        try mediaWrite(db,revised(row),type:"media_intake_row")
    }
    func mediaValidateIntakePublication(_ db: Database,round: JSON,selection: [JSON]) throws {
        let selected = Set(selection.compactMap {$0["item_id"] as? String})
        for intake in try records(db,type:"media_intake",project:(round["project_id"] as! String)) where intake["round_id"] as? String == round["id"] as? String {
            guard intake["confirmed_plan_id"] as? String == intake["plan_id"] as? String else {throw CoreError("MEDIA_PLAN_REQUIRED","Confirm every intake's current mapping before publication.")}
            for row in try mediaIntakeRows(db,intake:intake) {
                guard row["disposition"] as? String == "skip" || row["disposition"] as? String == "include" && row["capture_state"] as? String == "committed" && selected.contains(row["item_id"] as? String ?? "") else {throw CoreError("MEDIA_CAPTURE_REQUIRED","Publish the complete included captured intake; unresolved rows remain Draft.")}
            }
        }
    }
    /// Runs in the ephemeral preparation workspace. The real writer rechecks the
    /// snapshot plus each prepared original's exact identity under the deletion gate.
    /// New references, target, source release, manifest, event and receipt share a commit.
    func mediaPublishOwnership(_ db: Database,shape: JSON,caller: Caller,resources: PreparedMediaResources) throws -> JSON {
        let ids = strings(shape,"attachment_reference_ids")
        guard !ids.isEmpty else {return shape}
        let sourceRecord = try record(db,shape["attachment_owner_id"] as! String,type:"storage_job")
        let pid = sourceRecord["project_id"] as! String
        let source = try mediaOwnerValue(db,id:sourceRecord["id"] as! String,project:pid)
        let target = try mediaPreparedOwner(db,project:pid,kind:.target,caller:caller)
        let destination = MediaAttachmentOwner(id:target["id"] as! String,kind:.target,revision:1)
        var replacements: [String] = []
        for id in ids {
            var (reference,a) = try mediaAttachmentReference(db,project:pid,id:id,owner:source,caller:caller)
            guard resources.originals.contains(where:{$0.attachment["id"] as? String == a["id"] as? String && $0.attachment["sha256"] as? String == a["sha256"] as? String}) else {throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","An included original was not prepared.")}
            let replacement = try addMediaAttachmentReference(db,project:pid,owner:destination,attachment:a,caller:caller)
            replacements.append(replacement["id"] as! String)
            // Published historical owners retain their independent references.
            if source.kind != .target {reference["state"] = "released";try save(db,revised(reference),type:"storage_hold")}
        }
        var published = target;published["state"] = "published";try save(db,revised(published),type:"storage_job")
        var result = shape;result["attachment_owner_id"] = destination.id;result["attachment_reference_ids"] = replacements
        return result
    }
}

/// Closed local PCM capability for this gated capture slice. Unknown chunks are skipped
/// by their checked length, never interpreted as paths or executable metadata.
enum MediaIntakeWAV {
    static func validate(_ data: Data) -> Bool {
        guard data.count >= 44 else {return false}
        func word(_ i: Int) -> Int {Int(data[i]) | Int(data[i + 1]) << 8}
        func dword(_ i: Int) -> Int {word(i) | word(i + 2) << 16}
        guard data.prefix(4) == Data("RIFF".utf8),data[8..<12] == Data("WAVE".utf8),dword(4) == data.count - 8 else {return false}
        var index = 12,rate = 0,alignment = 0,payload = 0,format = false,foundData = false
        while index + 8 <= data.count {
            let name = data[index..<(index + 4)],length = dword(index + 4),start = index + 8
            guard length <= data.count - start else {return false}
            if name == Data("fmt ".utf8) {
                guard !format,length >= 16,word(start) == 1,(1...2).contains(word(start + 2)),[8,16,24,32].contains(word(start + 14)) else {return false}
                alignment = word(start + 12);rate = dword(start + 8)
                guard alignment == word(start + 2) * word(start + 14) / 8,dword(start + 4) > 0,dword(start + 4) <= 192000,rate == dword(start + 4) * alignment else {return false}
                format = true
            } else if name == Data("data".utf8) {guard !foundData else {return false};foundData = true;payload = length}
            index = start + length + (length % 2)
        }
        return index == data.count && format && foundData && payload > 0 && payload % alignment == 0 && payload <= rate * 1800
    }
}
