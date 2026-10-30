import Foundation
import GRDB
import CoreFoundation
import Darwin

/// Pins the backup's own named entry after checking its bytes on the read lane.
/// The writer rechecks identity only; it never opens the original store as a
/// fallback for a missing backup payload.
final class TicketCleanupBackupCopy {
    let files: StorageObjectFiles
    let path: String
    let identity: stat
    let regular: TicketObjectRemovalVerification?
    let manifest: TicketObjectRemovalVerification
    let link: String?
    init(root: URL,object: JSON,manifest: TicketObjectRemovalVerification,check: () throws -> Void = {}) throws {
        guard let relative = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {throw StorageSnapshotFailure.unsupportedAuthority}
        files = try StorageObjectFiles(root:root,pinRootForGates:true);path = "managed/" + relative;self.manifest = manifest
        guard manifest.root == Data(files.root.path.utf8),manifest.relative == Data("manifest.json".utf8) else {throw StorageSnapshotFailure.sourceChanged}
        var beforeLink: stat?
        if object["kind"] as? String == "symlink" {
            let (parent,name) = try files.parent(path);defer {Darwin.close(parent)}
            var before = stat()
            guard fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW) == 0,before.st_mode & S_IFMT == S_IFLNK else {throw StorageSnapshotFailure.incomplete}
            beforeLink = before
            try check()
            guard let target = object["link_target"] as? String,Int64(target.utf8.count) == size,hash(Data(target.utf8)) == sha,try files.linkTarget(path) == target else {throw StorageSnapshotFailure.sourceChanged}
            regular = nil;link = target
        } else {
            guard let verified = try TicketObjectRemovalVerification(root:root,relative:path,sha256:sha,size:size,check:check) else {throw StorageSnapshotFailure.incomplete}
            regular = verified;link = nil
        }
        let (parent,name) = try files.parent(path);defer {Darwin.close(parent)}
        var entry = stat()
        guard fstatat(parent,name,&entry,AT_SYMLINK_NOFOLLOW) == 0,entry.st_mode & S_IFMT == (link == nil ? S_IFREG : S_IFLNK) else {throw StorageSnapshotFailure.incomplete}
        if let regular {guard TicketObjectRemovalVerification.same(regular.identity,entry) else {throw StorageSnapshotFailure.sourceChanged}}
        if let beforeLink {guard Self.sameLink(beforeLink,entry) else {throw StorageSnapshotFailure.sourceChanged}}
        identity = entry
    }
    func isCurrent() -> Bool {
        do {
            try files.requireNamedRoot(files.root)
            let (manifestParent,manifestName) = try files.parent("manifest.json");defer {Darwin.close(manifestParent)}
            var manifestEntry = stat()
            guard fstatat(manifestParent,manifestName,&manifestEntry,AT_SYMLINK_NOFOLLOW) == 0,TicketObjectRemovalVerification.same(manifest.identity,manifestEntry) else {return false}
            let (parent,name) = try files.parent(path);defer {Darwin.close(parent)}
            var entry = stat()
            guard fstatat(parent,name,&entry,AT_SYMLINK_NOFOLLOW) == 0 else {return false}
            if let regular {return TicketObjectRemovalVerification.same(regular.identity,entry)}
            return Self.sameLink(identity,entry)
        } catch {return false}
    }
    private static func sameLink(_ a: stat,_ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFLNK && b.st_mode & S_IFMT == S_IFLNK && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

/// A captured authority, not a path sweep. The semantic transaction saves these
/// descriptors before removing their canonical owners. Other ticket lifecycles
/// can enqueue the same bounded intent without acquiring another unlink path.
struct TicketObjectDeletionReferenceIndex {
    let graph: [JSON]
    let reverse: [Data:Set<Int>]
    let projects: Set<Int>
    static let historyContainers: Set<String> = ["group","batch","batch_claim","delivery","cleanup_job","cleanup_preview"]
    init(_ graph: [JSON], tokens: [Data:Set<Data>]? = nil,historicalOwners: Set<Data> = []) throws {
        self.graph = graph
        var reverse: [Data:Set<Int>] = [:],projects = Set<Int>(),edges = 0
        func visit(_ value: Any,row: Int,depth: Int = 0) throws {
            edges += 1
            guard depth <= 64,edges <= 2000000 else {throw CoreError("REFERENCE_GRAPH_LIMIT","The object ownership inventory exceeds the safe deletion limit.")}
            if let s = value as? String {
                let token = Data(s.utf8)
                if !(Self.historyContainers.contains(graph[row]["record_type"] as? String ?? "") && historicalOwners.contains(token)) {reverse[token,default:[]].insert(row)}
            }
            else if let a = value as? [Any] {for v in a {try visit(v,row:row,depth:depth+1)}}
            else if let d = value as? JSON {for (key,v) in d {
                let token = Data(key.utf8)
                if !(Self.historyContainers.contains(graph[row]["record_type"] as? String ?? "") && historicalOwners.contains(token)) {reverse[token,default:[]].insert(row)}
                try visit(v,row:row,depth:depth+1)
            }}
        }
        for (index,value) in graph.enumerated() {
            if value["record_type"] as? String == "project" {projects.insert(index)}
            if value["record_type"] as? String == "storage_job",["ticket_object_delete","archive_cleanup_delete","archive_cleanup_cursor"].contains(value["kind"] as? String ?? "") {continue}
            if let tokens,let id = value["id"] as? String {
                for token in tokens[Data(id.utf8)] ?? [] where !(Self.historyContainers.contains(value["record_type"] as? String ?? "") && historicalOwners.contains(token)) {reverse[token,default:[]].insert(index)}
            } else {try visit(value,row:index)}
        }
        self.reverse = reverse;self.projects = projects
    }
}

struct TicketObjectDeletionPlan {
    var objects: [JSON]
    var summary: JSON { CommandRouter.ticketObjectDeletionSummary(objects) }
}

extension CommandRouter {
    static let ticketObjectDeletionKind = "ticket_object_delete"
    static let ticketObjectDeletionRetryReasons: Set<String> = ["backup_authority","remaining_record","backup_required","backup_copy_unavailable","backup_authority_unavailable"]
    static func ticketObjectDeletionReasonsRetryable(_ reasons: Set<String>) -> Bool {
        !reasons.isEmpty && reasons.allSatisfy {ticketObjectDeletionRetryReasons.contains($0) || $0.hasPrefix("backup_index_error:")}
    }
    // The same readiness predicate drives selection and the one-shot deadline.
    // A retained purge is observed once per completed backup generation, so an
    // unavailable copy or a genuine shared owner cannot become a polling loop.
    static let ticketObjectDeletionReadySQL = """
        json_valid(records.data) AND json_extract(records.data,'$.kind')='ticket_object_delete' AND (
            json_extract(records.data,'$.state')='pending' OR (
                json_extract(records.data,'$.state')='completed' AND json_extract(records.data,'$.cause')='task_purge'
                AND (COALESCE(json_extract(records.data,'$.cleanup_policy_version'),0)<2 OR COALESCE((SELECT CAST(value AS INTEGER) FROM metadata WHERE key='ticket-cleanup-backup-seen:'||records.id),-1)<COALESCE((SELECT MAX(rowid) FROM metadata WHERE key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete'),0))
                AND EXISTS(SELECT 1 FROM json_each(records.data,'$.objects') object WHERE json_extract(object.value,'$.state')='retained'
                    AND json_type(object.value,'$.reasons')='array' AND json_array_length(object.value,'$.reasons')>0
                    AND NOT EXISTS(SELECT 1 FROM json_each(object.value,'$.reasons') reason WHERE reason.type!='text' OR (reason.value NOT IN ('backup_authority','remaining_record','backup_required','backup_copy_unavailable','backup_authority_unavailable') AND reason.value NOT GLOB 'backup_index_error:*')))
            ))
        """
    func ticketCleanupBackupGenerationRow(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db,sql:"SELECT COALESCE(MAX(rowid),0) FROM metadata WHERE key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete'") ?? 0
    }

    /// Preserve transitive byte use by another real record. Batch/group/delivery
    /// pointers keep historical metadata, while their direct pathname references
    /// still participate in the ordinary final byte-reference index.
    func ticketCleanupProtectedOwners(_ graph: [JSON],owners: Set<Data>,tokens: [Data:Set<Data>]? = nil) throws -> Set<Data> {
        var edges: [Data:Set<Data>] = [:],protected = Set<Data>(),budget = 2000000
        for value in graph {
            guard let id = value["id"] as? String else {continue}
            let key = Data(id.utf8),type = value["record_type"] as? String ?? ""
            var references: Set<Data>
            if let known = tokens?[key] {references = known.intersection(owners)}
            else {
                references = []
                try TicketCleanupInventory.strings(value,{token in let bytes = Data(token.utf8);if owners.contains(bytes) {references.insert(bytes)}},budget:&budget)
            }
            edges[key] = references
            let bookkeeping = TicketObjectDeletionReferenceIndex.historyContainers.contains(type) || type == "storage_job" && ([Self.ticketObjectDeletionKind,"archive_cleanup_delete","archive_cleanup_cursor"].contains(value["kind"] as? String ?? "") || value["kind"] as? String == "attachment_import" && ["committed","settled"].contains(value["state"] as? String ?? "")) || type == "storage_hold" && value["state"] as? String != "active"
            if !owners.contains(key) && !bookkeeping {protected.formUnion(references)}
        }
        var pending = Array(protected)
        while let key = pending.popLast() {for target in edges[key] ?? [] where protected.insert(target).inserted {pending.append(target)}}
        return protected
    }

    static func ticketObjectDeletionSummary(_ objects: [JSON]) -> JSON {
        var totals: JSON = [:]
        for state in ["pending","removed","already_missing","retained"] {
            let selected = objects.filter { $0["state"] as? String == state }
            totals[state + "_count"] = selected.count
            totals[state + "_bytes"] = selected.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        }
        var reasons: [String: (count: Int, bytes: Int64)] = [:]
        for object in objects where object["state"] as? String == "retained" {
            for reason in object["reasons"] as? [String] ?? [] {
                var count = reasons[reason] ?? (count: 0, bytes: 0)
                count.count += 1
                count.bytes += (object["size"] as? NSNumber)?.int64Value ?? 0
                reasons[reason] = count
            }
        }
        totals["retained_reasons"] = reasons.mapValues { ["count": $0.count, "bytes": $0.bytes] as JSON }
        totals["physical_reclamation"] = "unmeasured"
        return totals
    }

    /// Retention is transitive through captured links, whatever caused the hold.
    /// Pending links also block unlink of their targets until the links are gone.
    /// Rebuild this graph at each unlink boundary, including resumed old intents.
    static func retainTicketObjectDeletionLinkTargets(_ objects: inout [JSON]) -> Set<String> {
        var entries: [String:StorageSnapshotObject] = [:],closures: [Int:[String]] = [:]
        var uncertainCaptures = Set<String>(),uncertainAll = false
        func capturePrefix(_ path: String) -> String? {
            guard let parts = try? StorageObjectFiles.parts(path) else {return nil}
            if parts.count >= 3,parts[0] == "source-build-cache" {return parts.prefix(2).joined(separator:"/")}
            guard parts.count >= 5,parts[0] == "source-captures",parts[3] == "source" else {return nil}
            return parts.prefix(4).joined(separator:"/")
        }
        for object in objects {
            guard let path = object["relative_path"] as? String else {continue}
            entries[path] = .init(relativePath:path,kind:object["kind"] as? String ?? "",expectedSHA256:object["sha256"] as? String,expectedSize:(object["size"] as? NSNumber)?.int64Value,executable:object["executable"] as? Bool == true,linkTarget:object["link_target"] as? String,authorities:[])
        }
        let cachePaths = entries.keys.filter {$0.hasPrefix("source-build-cache/")}
        var cacheVisits = 0
        for index in objects.indices where objects[index]["kind"] as? String == "symlink" && ["pending","retained"].contains(objects[index]["state"] as? String ?? "") {
            guard let path = objects[index]["relative_path"] as? String else {uncertainAll = true;continue}
            do {
                // An ambiguous or changed link may have a different live target.
                // Its recorded chain alone cannot authorize deleting its capture.
                guard !(objects[index]["reasons"] as? [String] ?? []).contains("ambiguous_identity"),objects[index]["last_failure"] as? String != "CLEANUP_IDENTITY_CHANGED" else {throw StorageSnapshotFailure.unsupportedAuthority}
                closures[index] = try path.hasPrefix("source-build-cache/") ? sourceBuildCacheLinkClosure(path,entries:entries,cachePaths:cachePaths,visits:&cacheVisits) : StorageSnapshotAuthority.capturedLinkClosure(path,entries:entries)
            } catch {
                if let capture = capturePrefix(path) {uncertainCaptures.insert(capture)} else {uncertainAll = true}
            }
        }
        for index in objects.indices where objects[index]["state"] as? String == "pending" {
            let capture = (objects[index]["relative_path"] as? String).flatMap(capturePrefix)
            if uncertainAll || capture.map({uncertainCaptures.contains($0)}) == true {
                objects[index]["state"] = "retained";objects[index]["reasons"] = ["link_closure_unavailable"]
            }
        }
        var retainedTargets = Set<String>(),pendingTargets = Set<String>()
        for (index,closure) in closures where objects[index]["state"] as? String == "retained" {retainedTargets.formUnion(closure.dropFirst())}
        for index in objects.indices where objects[index]["state"] as? String == "pending" {
            if let path = objects[index]["relative_path"] as? String,retainedTargets.contains(path) {
                objects[index]["state"] = "retained";objects[index]["reasons"] = ["retained_link_target"]
            }
        }
        for (index,closure) in closures where objects[index]["state"] as? String == "pending" {pendingTargets.formUnion(closure.dropFirst())}
        return pendingTargets
    }

    /// Cache aliases may resolve to directories (SwiftPM's debug alias). Only
    /// recorded descendants inside this exact cache entry enter the closure.
    private static func sourceBuildCacheLinkClosure(_ path: String,entries: [String:StorageSnapshotObject],cachePaths: [String],visits totalVisits: inout Int) throws -> [String] {
        let parts = try StorageObjectFiles.parts(path)
        guard parts.count >= 3,parts[0] == "source-build-cache" else {throw StorageSnapshotFailure.unsupportedAuthority}
        let prefix = Array(parts.prefix(2))
        var visiting = Set<String>(),closure = Set<String>(),visits = totalVisits
        defer {totalVisits = visits}
        guard visits < 2000000 else {throw StorageSnapshotFailure.limit}
        func visit(_ path: String,depth: Int) throws {
            visits += 1;guard visits <= 2000000 else {throw StorageSnapshotFailure.limit}
            guard depth <= 32,!visiting.contains(path),let entry = entries[path] else {throw StorageSnapshotFailure.unsupportedAuthority}
            if closure.contains(path) {return}
            visiting.insert(path);defer {visiting.remove(path)}
            closure.insert(path)
            guard entry.kind == "symlink" else {return}
            guard let target = entry.linkTarget,!target.isEmpty,!target.hasPrefix("/"),!target.contains("\0"),StorageObjectFiles.sha(Data(target.utf8)) == entry.expectedSHA256 else {throw StorageSnapshotFailure.unsupportedAuthority}
            var destination = try StorageObjectFiles.parts(path);destination.removeLast()
            for part in target.split(separator:"/") {
                // Lexical parent reduction must never skip a symlinked parent.
                guard entries[destination.joined(separator:"/")]?.kind != "symlink" else {throw StorageSnapshotFailure.unsupportedAuthority}
                if part == "." {continue}
                if part == ".." {guard destination.count > 2 else {throw StorageSnapshotFailure.unsupportedAuthority};destination.removeLast()}
                else {destination.append(String(part))}
            }
            guard Array(destination.prefix(2)) == prefix else {throw StorageSnapshotFailure.unsupportedAuthority}
            let resolved = destination.joined(separator:"/")
            if entries[resolved] != nil {try visit(resolved,depth:depth+1)}
            else {
                // A directory has no unlink descriptor; protect every inventoried
                // descendant, including any further link chains. Never follow it.
                for candidate in cachePaths {
                    visits += 1;guard visits <= 2000000 else {throw StorageSnapshotFailure.limit}
                    if candidate.hasPrefix(resolved + "/") {
                        guard !visiting.contains(candidate) else {throw StorageSnapshotFailure.unsupportedAuthority}
                        if !closure.contains(candidate) {try visit(candidate,depth:depth+1)}
                    }
                }
            }
        }
        try visit(path,depth:0)
        return [path] + closure.filter {$0 != path}.sorted()
    }

    /// Capture candidate descriptors once before a selected batch observes backup indexes.
    func ticketObjectDeletionObjects(_ db: Database,owned: [(String,JSON)]) throws -> [JSON] {
        let files = try StorageObjectFiles(root:root)
        var objects: [String:JSON] = [:]
        func add(path: String?, family: String, owner: String, representation: String, sha: String? = nil, size: Int64? = nil, link: String? = nil, capture: String? = nil, executable: Bool = false, reason: String? = nil) throws {
            guard objects.count < 100000 else { throw CoreError("PURGE_LIMIT","The managed object inventory exceeds the safe purge limit.") }
            var item: JSON = ["owner_ids":[owner],"representation":representation,"kind":link == nil ? "file" : "symlink","executable":executable,"state":"pending","size":max(0,size ?? 0)]
            if let path {item["stored_path"] = path;item["name"] = URL(fileURLWithPath:path).lastPathComponent}
            var reasons = reason.map {[$0]} ?? []
            if let path,let relative = try? managedRelative(path,family:family) {
                item["relative_path"] = relative
                if let capture {item["capture_path"] = capture}
                if let link {item["link_target"] = link;item["sha256"] = sha;item["size"] = Int64(link.utf8.count)}
                else if let sha,let size,size >= 0 {item["sha256"] = sha;item["size"] = size}
                else if ["original","source_capture"].contains(representation) {reasons.append("identity_unavailable")}
                else {
                    // Previews and capture sidecars have no immutable digest field.
                    // Capture their exact current descriptor; unlink verifies it again.
                    do {let bytes = try files.read(relative,maximum:StorageSnapshotBudget.manifestByteLimit);item["sha256"] = hash(bytes);item["size"] = Int64(bytes.count)}
                    catch {reasons.append("identity_unavailable")}
                }
            } else if reasons.isEmpty {reasons.append("outside_managed_store")}
            if reasons.isEmpty,let relative = item["relative_path"] as? String {
                do {if try !files.regularOrLinkExists(relative) {item["state"] = "already_missing"}}
                catch {reasons.append("identity_unavailable")}
            }
            if !reasons.isEmpty {item["state"] = "retained";item["reasons"] = reasons}
            let key = item["relative_path"] as? String ?? "unavailable:" + owner + ":" + representation
            if var prior = objects[key] {
                prior["owner_ids"] = Array(Set((prior["owner_ids"] as? [String] ?? []) + [owner])).sorted()
                if prior["sha256"] as? String != item["sha256"] as? String || (prior["size"] as? NSNumber) != (item["size"] as? NSNumber) {prior["state"] = "retained";prior["reasons"] = ["ambiguous_identity"]}
                let retained = Set((prior["reasons"] as? [String] ?? []) + (item["reasons"] as? [String] ?? []))
                if !retained.isEmpty {prior["state"] = "retained";prior["reasons"] = retained.sorted()}
                objects[key] = prior
            } else {objects[key] = item}
        }
        func capture(_ value: JSON, owner: String) throws {
            guard let path = value["snapshot_path"] as? String,let entries = value["files"] as? [JSON],let cid = value["id"] as? String,let pid = value["project_id"] as? String,
                  let relative = try? managedRelative(path,family:"source-captures"),
                  ["source-captures/" + pid + "/" + cid + "/source","source-captures/project-" + hash(Data(pid.utf8)) + "/" + cid + "/source"].contains(relative) else {
                try add(path:nil,family:"source-captures",owner:owner,representation:"source_capture",reason:"unsupported_source_capture");return
            }
            for entry in entries where entry["kind"] as? String != "deleted" {
                guard let name = entry["path"] as? String,(try? StorageObjectFiles.parts(name)) != nil,
                      let sha = entry["sha256"] as? String,["file","symlink"].contains(entry["kind"] as? String ?? "") else {
                    try add(path:nil,family:"source-captures",owner:owner,representation:"source_capture",reason:"unsupported_source_capture");continue
                }
                try add(path:relative + "/" + name,family:"source-captures",owner:owner,representation:"source_capture",sha:sha,size:(entry["size"] as? NSNumber)?.int64Value,link:entry["target"] as? String,capture:relative,executable:bool(entry,"executable"))
            }
            try add(path:String(relative.dropLast("/source".count)) + "/manifest.json",family:"source-captures",owner:owner,representation:"capture_manifest",capture:relative)
            for key in Array(objects.keys) where objects[key]?["capture_path"] as? String == relative {
                guard var object = objects[key] else { continue }
                object["owner_ids"] = Array(Set((object["owner_ids"] as? [String] ?? []) + [cid,owner])).sorted()
                objects[key] = object
            }
        }
        for (type,value) in owned {
            let id = (try StoredRecord(value, family: "value").string("id"))
            if type == "attachment" {
                try add(path:value["path"] as? String,family:"objects",owner:id,representation:"original",sha:value["sha256"] as? String,size:(value["size"] as? NSNumber)?.int64Value,reason:value["mode"] as? String == "managed" ? (bool(value,"keep_original") ? "keep_original" : nil) : "external_original")
                if let path = value["preview_path"] as? String {try add(path:path,family:"objects",owner:id,representation:"preview",reason:value["mode"] as? String == "managed" ? nil : "external_original")}
            } else if type == "source_capture" {try capture(value,owner:id)}
            else if type == "manifest",let evidence = value["evidence"] as? JSON,let source = evidence["source_capture"] as? JSON {try capture(source,owner:id)}
        }
        for item in try sourceBuildCacheDeletionObjects(db,owned:owned) {
            if let path = item["relative_path"] as? String {objects[path] = item}
        }
        return Array(objects.values)
    }

    func ticketObjectDeletionPlan(_ db: Database, owned: [(String,JSON)], remaining: [JSON], referenceTokens: [Data:Set<Data>]? = nil,historicalOwners: Set<Data> = [],backupObservation: TicketCleanupBackupObservation? = nil,candidateObjects: [JSON]? = nil,mediaAuthorityComplete: Bool? = nil) throws -> TicketObjectDeletionPlan {
        let objects = try candidateObjects ?? ticketObjectDeletionObjects(db,owned:owned)
        let backup: StorageBackupRetentionIndex?
        if let backupObservation {backup = backupObservation.index}
        else {backup = observeTicketCleanupBackupRetentionIndex(db,objects:objects)}
        let references = try TicketObjectDeletionReferenceIndex(remaining,tokens:referenceTokens,historicalOwners:historicalOwners)
        let mediaComplete = mediaAuthorityComplete ?? ((try? ticketCleanupValidateMediaAuthority(db)) != nil)
        var result: [JSON] = []
        for var item in objects {
            if item["state"] as? String == "pending" {
                let holds = try ticketObjectDeletionHolds(db,object:item,references:references,backup:backup,mediaAuthorityComplete:mediaComplete)
                if !holds.isEmpty {item["state"] = "retained";item["reasons"] = holds.sorted()}
            }
            result.append(item)
        }
        _ = Self.retainTicketObjectDeletionLinkTargets(&result)
        // The executor also checks pending dependencies before choosing an unlink;
        // lexical link order alone cannot protect chains or retained links.
        result.sort {let a = $0["kind"] as? String == "symlink",b = $1["kind"] as? String == "symlink";return a != b ? a : ($0["stored_path"] as? String ?? "") < ($1["stored_path"] as? String ?? "")}
        return .init(objects:result)
    }

    func ticketObjectDeletionHolds(_ db: Database, object: JSON, references: TicketObjectDeletionReferenceIndex, backup: StorageBackupRetentionIndex?,mediaAuthorityComplete: Bool) throws -> Set<String> {
        guard let relative = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {return ["identity_unavailable"]}
        var holds = try sourceBuildCacheDeletionHolds(db,object:object)
        if !mediaAuthorityComplete {holds.insert("media_authority_unavailable")}
        let absolute = root.appendingPathComponent(relative).path
        var tokens = Set((object["owner_ids"] as? [String] ?? []).map {Data($0.utf8)})
        tokens.formUnion([relative,absolute,object["stored_path"] as? String ?? ""].filter {!$0.isEmpty}.map {Data($0.utf8)})
        if let cache = object["cache_path"] as? String {tokens.formUnion([Data(cache.utf8),Data(root.appendingPathComponent(cache).path.utf8)])}
        if let capture = object["capture_path"] as? String {tokens.formUnion([Data(capture.utf8),Data(root.appendingPathComponent(capture).path.utf8)])}
        var matched = Set<Int>()
        for token in tokens {matched.formUnion(references.reverse[token] ?? [])}
        // Typed holds can name a content digest instead of a path/record ID.
        matched.formUnion((references.reverse[Data(sha.utf8)] ?? []).filter {references.graph[$0]["record_type"] as? String == "storage_hold"})
        for index in matched.union(references.projects) {
            let value = references.graph[index]
            let type = value["record_type"] as? String ?? ""
            if type == "project",let path = value["root_path"] as? String {
                let workspace = URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path
                let target = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL.path
                if target == workspace || target.hasPrefix(workspace + "/") {holds.insert("workspace_file")}
            }
            if ["cleanup_job","cleanup_preview"].contains(type) {continue}
            if type == "storage_job" {
                let kind = value["kind"] as? String ?? ""
                if [Self.ticketObjectDeletionKind,"archive_cleanup_delete","archive_cleanup_cursor"].contains(kind) {continue}
                if kind == "attachment_import",["committed","settled"].contains(value["state"] as? String ?? "") {continue}
            }
            if type == "storage_hold" {
                guard value["state"] as? String == "active" else {continue}
                if let expiry = value["expires_at"] as? NSNumber,CFGetTypeID(expiry) != CFBooleanGetTypeID(),expiry.doubleValue.isFinite,expiry.doubleValue <= Date().timeIntervalSince1970 {continue}
                if matched.contains(index) {holds.insert(value["kind"] as? String == "backup" ? "backup_authority" : value["kind"] as? String == "media_reference" ? "media_owner" : "reader_lease")}
                continue
            }
            if matched.contains(index) {holds.insert(type == "storage_job" ? "pending_storage_owner" : "remaining_record")}
        }
        if let backup {
            let key = StorageBackupRetentionIndex.key(path:relative,sha:sha,size:size)
            if let failure = backup.cleanupFailureReason {holds.insert(failure)}
            else if !backup.hasIndependentCopy(key) {holds.insert("backup_required")}
            else if backup.checkedCopies.contains(key),backup.verifiedCopies[key]?.isCurrent() != true {holds.insert("backup_copy_unavailable")}
        } else {holds.insert("backup_authority_unavailable")}
        return holds
    }

    func enqueueTicketObjectDeletion(_ db: Database, project: String, task: String, cause: String, plan: TicketObjectDeletionPlan) throws -> JSON {
        guard db.isInsideTransaction else {throw CoreError("STORAGE_TRANSACTION_REQUIRED","Object deletion intent must commit with its semantic command.")}
        let id = uuid()
        let generation = try ticketCleanupBackupGenerationRow(db)
        let receipt: JSON = ["id":id,"project_id":project,"task_id":task,"kind":Self.ticketObjectDeletionKind,"cause":cause,"state":plan.objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed","revision":1,"created_at":now(),"objects":plan.objects,"summary":plan.summary,"cleanup_policy_version":2]
        try save(db,receipt,type:"storage_job")
        if cause == "task_purge" {try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-backup-seen:" + id,String(generation)])}
        return receipt
    }

    /// A command retry keeps its original semantic receipt, and observes this
    /// separately durable byte receipt without rewriting the command's intent.
    func addingTicketObjectDeletionReceipt(_ db: Database, output: JSON) throws -> JSON {
        guard var data = output["data"] as? JSON,let id = data["byte_deletion_receipt_id"] as? String else {return output}
        let receipt = try record(db,id,type:"storage_job")
        data["byte_deletion"] = receipt
        data["managed_bytes_action"] = receipt["state"] as? String == "completed" ? "completed" : "pending"
        if var counts = data["counts"] as? JSON {counts["managed_bytes_deleted"] = (receipt["summary"] as? JSON)?["removed_bytes"] ?? 0;data["counts"] = counts}
        var result = output;result["data"] = data;return result
    }
}
