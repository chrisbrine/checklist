import Foundation
import Darwin

/// Versioned, inert intermediate representation. No imported payload is a command,
/// canonical authority record, host identity or a current review verdict.
struct TransferBundle {
    struct Entry {let family: String;let sourceID: String;let payload: JSON}
    struct File {let path: String;let sha256: String?;let bytes: Data?;let availability: String}
    let schema: String
    let namespace: String
    let document: JSON
    let entries: [Entry]
    let files: [File]
    let sourceHash: String
    let diagnostics: [JSON]
    let blockers: [String]
    let source: StorageObjectFiles
    let identities: [(String,FileIdentity?)]
    let sourceHashes: [String:String]

    /// Hash the single commit read of each available source, then parse only
    /// those verified bytes. Metadata alone cannot fence an in-place rewrite.
    func validateSource() throws -> Self {
        let current = try StorageObjectFiles(root:source.root)
        var original = stat(),selected = stat()
        guard fstat(source.descriptor,&original) == 0,fstat(current.descriptor,&selected) == 0,original.st_dev == selected.st_dev,original.st_ino == selected.st_ino else {throw CoreError("IMPORT_PREVIEW_CHANGED","The selected source folder changed.")}
        var verified: [String:Data] = [:]
        for (path,identity) in identities {
            let present = try? current.openRegular(path) {FileIdentity(descriptor:$0)}
            guard present == identity else {throw CoreError("IMPORT_PREVIEW_CHANGED","A selected source file changed after it was read.")}
            if let expected = sourceHashes[path],verified[path] == nil {
                guard let bytes = try? current.read(path,maximum:Self.byteLimit),hash(bytes) == expected else {throw CoreError("IMPORT_PREVIEW_CHANGED","A selected source file content changed after preparation.",details:["path":path])}
                verified[path] = bytes
            }
        }
        return try Self.read(source:current,format:schema,namespace:namespace,snapshot:verified)
    }

    static let formats: Set<String> = ["checklist-project/1","synthetic-board/1","synthetic-client/1","synthetic-media/5"]
    static let byteLimit = 16 * 1024 * 1024
    static func read(path: String,format: String,namespace: String) throws -> Self {
        guard formats.contains(format),!namespace.isEmpty,namespace.utf8.count <= 500 else {throw CoreError("IMPORT_FORMAT_UNSUPPORTED","Select a supported explicit format/version and a stable source namespace.")}
        let source = try StorageObjectFiles(root:URL(fileURLWithPath:path,isDirectory:true))
        return try read(source:source,format:format,namespace:namespace,snapshot:nil)
    }
    private static func read(source: StorageObjectFiles,format: String,namespace: String,snapshot: [String:Data]?) throws -> Self {
        func readBytes(_ path: String) throws -> Data {
            if let snapshot {
                guard let bytes = snapshot[path] else {throw StorageSnapshotFailure.io}
                return bytes
            }
            return try source.read(path,maximum:byteLimit)
        }
        let documentPath = format == "checklist-project/1" ? "project.json" : "bundle.json"
        let initialIdentity = try source.openRegular(documentPath) {FileIdentity(descriptor:$0)}
        let bytes = try readBytes(documentPath)
        guard initialIdentity == (try source.openRegular(documentPath) {FileIdentity(descriptor:$0)}) else {throw CoreError("IMPORT_PREVIEW_CHANGED","Source changed while reading.")}
        var identities: [(String,FileIdentity?)] = [(documentPath,initialIdentity)]
        guard let doc = try JSONSerialization.jsonObject(with:bytes) as? JSON else {throw CoreError("IMPORT_SHAPE_INVALID","The selected bundle must be an object.")}
        if format == "checklist-project/1" {
            guard doc["format"] as? String == "checklist-project",int(doc,"schema_version") == 1,doc["project"] is JSON else {throw CoreError("IMPORT_SHAPE_INVALID","Expected a version-1 Checklist project export.")}
        } else {guard doc["format"] as? String == format else {throw CoreError("IMPORT_SHAPE_INVALID","The selected schema does not match the document.")}}
        var entries: [Entry] = [],diagnostics: [JSON] = [],blockers: [String] = [],sourceIDs = Set<Data>()
        func diagnostic(_ code: String,_ location: String) {diagnostics.append(["code":code,"location":location])}
        func add(_ family: String,_ value: JSON,_ location: String) {
            let explicit = value["id"] as? String ?? (family == "events" ? (value["event_seq"] as? NSNumber)?.stringValue : nil)
            let identity = explicit ?? location
            if !sourceIDs.insert(Data((family + "\0" + identity).utf8)).inserted {blockers.append("duplicate_source_identity:" + family + ":" + identity)}
            if explicit == nil {diagnostic("source_identity_is_json_location",location)}
            entries.append(.init(family:family,sourceID:identity,payload:value))
        }
        func array(_ key: String,required: Bool = false) throws -> [JSON] {
            guard let raw = doc[key] else {if required {throw CoreError("IMPORT_SHAPE_INVALID","Missing \(key) array.")};return []}
            guard let rows = raw as? [JSON],rows.count <= 20_000 else {throw CoreError("IMPORT_SHAPE_INVALID","Invalid or oversized \(key) array.")};return rows
        }
        if format == "checklist-project/1" {
            add("project",try exportedProject(doc),"/project")
            for family in CommandRouter.projectExportTypes + ["profiles","import_record","import_receipt"] where doc[family] != nil {
                // projectExportTypes may already include transfer families.
                if entries.contains(where:{$0.family == family}) {continue}
                for (i,row) in try array(family).enumerated() {add(family,row,"/" + family + "/\(i)")}
            }
        } else {
            for (i,row) in try array("items",required:format != "synthetic-media/5").enumerated() {
                guard let id = row["id"] as? String,!id.isEmpty else {throw CoreError("IMPORT_SHAPE_INVALID","Every task needs a source-local ID.")}
                add("task",row,"/items/\(i)")
            }
            for family in ["work_packages","verdicts","completion_evidence","completion_overrides","takes","sound_reviews","story_reviews"] {
                for (i,row) in try array(family).enumerated() {add(family,row,"/" + family + "/\(i)")}
            }
            for (i,export) in try array("verdict_exports").enumerated() {
                guard let shape = export["format"] as? String,int(export,"version") == 1,let payload = export["payload"] else {throw CoreError("IMPORT_SHAPE_INVALID","Verdict exports require format, version=1 and payload.")}
                let values = try verdicts(payload,shape:shape)
                for (j,value) in values.enumerated() {add("verdict_exports",value,"/verdict_exports/\(i)/\(j)")}
            }
        }
        if doc["exported_at"] == nil && (doc["meta"] as? JSON)?["exported_at"] == nil {diagnostic("source_time_unavailable","/")}
        if doc["events"] == nil {diagnostic("event_history_unavailable","/events")}
        for (i,row) in try array("events").enumerated() {add("events",row,"/events/\(i)")}
        guard entries.count <= 30_000 else {throw CoreError("IMPORT_SHAPE_INVALID","Too many intermediate records.")}
        let tasks = entries.filter {$0.family == "task"},taskIDs = Set(tasks.map {Data($0.sourceID.utf8)})
        var aliases: [Data:String] = [:]
        func alias(_ value: String,_ id: String) {
            let key = Data(value.lowercased().utf8)
            if let prior = aliases[key],prior != id {diagnostic("duplicate_alias",value);blockers.append("duplicate_alias:" + value)} else {aliases[key] = id}
        }
        for item in tasks {
            alias(item.payload["key"] as? String ?? item.sourceID,item.sourceID)
            for value in strings(item.payload,"aliases") {alias(value,item.sourceID)}
            let state = item.payload["state"] as? String ?? ""
            if ["active","doing","running","review"].contains(state) || item.payload["active_attempt_id"] != nil {diagnostic("historical_work_requires_reconciliation",item.sourceID)}
            if state == "you" {diagnostic("unverified_owner_intent",item.sourceID)}
            let note = item.payload["note"] as? String ?? ""
            if note.utf8.count > 4_000 {diagnostic("long_note_preserved",item.sourceID)}
            for hint in ["ready for integration:","paused","hold","split into","waits for","round ","p1/p2"] where note.lowercased().contains(hint) {diagnostic("unverified_note_hint:" + hint,item.sourceID)}
            for ref in strings(item.payload,"depends_on") where !taskIDs.contains(Data(ref.utf8)) {diagnostic("unresolved_relation",ref)}
        }
        var references = Set<String>()
        func inspect(_ value: Any,_ location: String,depth: Int = 0) throws {
            guard depth <= 64 else {throw CoreError("IMPORT_SHAPE_INVALID","Bundle nesting exceeds 64 levels.")}
            if let object = value as? JSON {
                for (key,child) in object {
                    if ["path","original","evidence","preview_path","icon_path"].contains(key.lowercased()),let path = child as? String,!path.isEmpty {references.insert(path)}
                    if ["task","task_ref","target_task_id","source_task_id"].contains(key),let ref = child as? String,!taskIDs.contains(Data(ref.utf8)) {diagnostic("unresolved_relation",location + "/" + key)}
                    if key == "algorithm",let name = child as? String,name != "sha256" {diagnostic("unknown_signature_algorithm",location)}
                    if ["signature","content_signature"].contains(key),child is NSNull {diagnostic("signature_unavailable",location)}
                    try inspect(child,location + "/" + key,depth:depth+1)
                }
            } else if let values = value as? [Any] {for (i,child) in values.enumerated() {try inspect(child,location + "/\(i)",depth:depth+1)}}
        }
        try inspect(doc,"")
        guard references.count <= 1_000 else {throw CoreError("IMPORT_SHAPE_INVALID","Too many file references.")}
        var files: [File] = [],total = bytes.count
        for path in references.sorted() {
            // Descriptor-relative no-follow read refuses absolute, traversal,
            // symlink, directory and FIFO inputs. No relinking or external read.
            var data: Data?
            let before = try? source.openRegular(path) {FileIdentity(descriptor:$0)}
            if !path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == ".." || $0 == "." || $0.isEmpty}) {data = try? readBytes(path)}
            let after = try? source.openRegular(path) {FileIdentity(descriptor:$0)}
            guard before == after else {throw CoreError("IMPORT_PREVIEW_CHANGED","Source changed while reading a referenced file.")}
            identities.append((path,after))
            total += data?.count ?? 0
            guard total <= 64 * 1024 * 1024 else {throw CoreError("IMPORT_SHAPE_INVALID","Selected import exceeds the 64 MiB aggregate limit.")}
            let availability = data == nil ? "unavailable_or_pruned" : "available"
            if data == nil {diagnostic("missing_file",path)}
            files.append(.init(path:path,sha256:data.map(hash),bytes:data,availability:availability))
        }
        var sourceHashes = Dictionary(uniqueKeysWithValues:files.compactMap {file in file.sha256.map {(file.path,$0)}})
        sourceHashes[documentPath] = hash(bytes)
        let fileIdentity = files.map {[$0.path,$0.sha256 ?? "unavailable"]}
        let sourceHash = hash(Data((hash(bytes) + (try jsonString(fileIdentity))).utf8))
        return Self(schema:format,namespace:namespace,document:doc,entries:entries,files:files,sourceHash:sourceHash,diagnostics:diagnostics,blockers:blockers,source:source,identities:identities,sourceHashes:sourceHashes)
    }

    private static func exportedProject(_ document: JSON) throws -> JSON {
        guard let project = document["project"] as? JSON else {
            throw CoreError("IMPORT_SHAPE_INVALID", "Expected a version-1 Checklist project export.")
        }
        return project
    }

    static func verdicts(_ payload: Any,shape: String) throws -> [JSON] {
        func invalid() -> CoreError {CoreError("IMPORT_SHAPE_INVALID","Verdict payload does not match its selected version-1 layout.")}
        switch shape {
        case "single-verdict":
            guard let row = payload as? JSON,row["task"] is String,row["verdict"] is String else {throw invalid()};return [row]
        case "verdict-list":guard let rows = payload as? [JSON],rows.allSatisfy({$0["task"] is String && ($0["result"] is String || $0["verdict"] is String)}) else {throw invalid()};return rows
        case "keyed-verdicts":
            guard let rows = payload as? [String:JSON] else {throw invalid()}
            return try rows.keys.sorted().map { key in
                guard let row = rows[key],row["review"] is String else { throw invalid() }
                return ["task":key,"raw":row]
            }
        case "round-envelope":
            guard let object = payload as? JSON,let rounds = object["rounds"] as? [JSON],rounds.allSatisfy({$0["round"] is NSNumber && $0["verdicts"] is [JSON]}) else {throw invalid()};return rounds
        case "direction-verdicts":
            guard let row = payload as? JSON,row["take"] is String,row["round"] is NSNumber,row["directions"] is [String:JSON] else {throw invalid()};return [row]
        default:throw CoreError("IMPORT_FORMAT_UNSUPPORTED","Select an explicit supported verdict layout; filenames never select a reader.")
        }
    }
}
