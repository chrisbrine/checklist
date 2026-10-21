import Foundation
import CoreFoundation
import GRDB

/// Ephemeral index of one complete, canonically decoded SQL observation. It is
/// never retained across commands or across the final deletion revalidation.
struct ArchiveCleanupReferenceIndex {
    let graph: [JSON]
    let reverse: [Data: [Int]]
    static let bookkeeping: Set<String> = ["cleanup_job","cleanup_preview","event","checkpoint","policy_revision","taxonomy_revision","project_context_revision","finding_resolution","triage_membership_interval","triage_membership_exit"]

    init(_ graph: [JSON]) throws {
        self.graph = graph
        let bookkeeping = Self.bookkeeping
        var reverse: [Data:[Int]] = [:],edgeCount = 0
        func indexStrings(_ value: Any,row: Int,depth: Int = 0) throws {
            guard depth <= 64,edgeCount < 2_000_000 else { throw CoreError("REFERENCE_GRAPH_LIMIT", "The current reference graph exceeds the cleanup safety bound; originals retained.") }
            if let s = value as? String { reverse[Data(s.utf8),default:[]].append(row);edgeCount += 1 }
            else if let a = value as? [Any] { for v in a { try indexStrings(v,row:row,depth:depth+1) } }
            else if let o = value as? JSON { for v in o.values { try indexStrings(v,row:row,depth:depth+1) } }
        }
        for (index,value) in graph.enumerated() {
            let type = value["record_type"] as? String ?? ""
            if bookkeeping.contains(type) { continue }
            if type == "storage_job",["attachment_import","archive_cleanup_delete","archive_cleanup_cursor"].contains(value["kind"] as? String ?? "") { continue }
            try indexStrings(value,row:index)
        }
        self.reverse = reverse
    }
}

extension CommandRouter {
    /// Reuse only within one current SQL observation; never across commands or
    /// the durable-intent/final-unlink transaction boundary.
    func archiveCleanupReferenceRows(_ db: Database) throws -> [JSON] {
        var graph: [JSON] = []
        let cursor = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records ORDER BY rowid")
        while let row = try cursor.next() {
            guard graph.count < 250_000 else { throw CoreError("REFERENCE_GRAPH_LIMIT", "The current reference graph exceeds the cleanup safety bound; originals are retained.") }
            let decoded = try GRDBRecordEnvelopeAdapter.decode(row)
            var value = decoded.object; value["record_type"] = decoded.type
            graph.append(value)
        }
        return graph
    }
    /// Enumerate the actual persisted reference graph, including foreign-project
    /// links to the same physical object. Only bounded reason codes leave here.
    /// Unknown/corrupt rows throw; absence of knowledge never authorizes unlink.
    func completeArchiveCleanupHolds(_ db: Database,attachment a: JSON,task: JSON,considerArchiving: Bool = false,currentGraph: [JSON]? = nil, currentIndex: ArchiveCleanupReferenceIndex? = nil) throws -> Set<ArchiveCleanupJob.Hold> {
        let aid = a["id"] as! String,tid = task["id"] as! String
        var holds = Set<ArchiveCleanupJob.Hold>()
        if a["mode"] as? String != "managed" { holds.insert(.externalOriginal) }
        if bool(a,"keep_original") { holds.insert(.keepOriginal) }
        if task["active_attempt_id"] != nil { holds.insert(.activeWork) }
        if task["active_verification_request_id"] != nil { holds.insert(.activeVerification) }
        if !considerArchiving && !bool(task,"archived") { holds.insert(.sharedLiveReference) }
        let referenceIndex = try currentIndex ?? ArchiveCleanupReferenceIndex(currentGraph ?? archiveCleanupReferenceRows(db))
        let graph = referenceIndex.graph
        let tasks = graph.filter { $0["record_type"] as? String == "task" }
        func taskIsLive(_ id: Any?) -> Bool {
            guard let id = id as? String else { return false }
            if cleanupJobEqual(id,tid) && considerArchiving { return false }
            guard let linked = tasks.first(where: { cleanupJobEqual($0["id"],id) }) else { return true }
            return !bool(linked,"archived") && !bool(linked,"trashed") || linked["active_attempt_id"] != nil || linked["active_verification_request_id"] != nil
        }
        let path = a["path"] as? String ?? ""
        let relative = (try? ManagedPaths.relative(path,family:"objects",root:root)) ?? ""
        let absolute = relative.isEmpty ? "" : root.appendingPathComponent(relative).path
        func mentions(_ value: Any,allowDigest: Bool = false) -> Bool {
            if let s = value as? String {
                return cleanupJobEqual(s,aid) || !path.isEmpty && cleanupJobEqual(s,path) || !relative.isEmpty && cleanupJobEqual(s,relative) || !absolute.isEmpty && cleanupJobEqual(s,absolute) || allowDigest && cleanupJobEqual(s,a["sha256"])
            }
            if let array = value as? [Any] { return array.contains { mentions($0,allowDigest:allowDigest) } }
            if let object = value as? JSON { return object.values.contains { mentions($0,allowDigest:allowDigest) } }
            return false
        }
        // Trace transitive artifact/manifest/capture/build references, rather
        // than assuming every active consumer stores an attachment ID directly.
        let bookkeeping = ArchiveCleanupReferenceIndex.bookkeeping
        let reverse = referenceIndex.reverse
        var pending = [Data(aid.utf8)] + (path.isEmpty ? [] : [Data(path.utf8)]) + (relative.isEmpty ? [] : [Data(relative.utf8)]) + (absolute.isEmpty ? [] : [Data(absolute.utf8)]),seen = Set<Data>(),referencing = Set<Int>()
        while let token = pending.popLast() {
            if !seen.insert(token).inserted { continue }
            for index in reverse[token] ?? [] where referencing.insert(index).inserted {
                if let id = graph[index]["id"] as? String { pending.append(Data(id.utf8)) }
            }
        }
        let activeStates: Set<String> = ["active","queued","running","pending","human_pending","blocked","interrupted","capturing","staging","reserved"]
        let activeReviews = graph.filter { $0["record_type"] as? String == "review_request" && activeStates.contains($0["state"] as? String ?? "") }
        for (rowIndex,value) in graph.enumerated() {
            let type = value["record_type"] as? String ?? ""
            if type == "attachment" {
                if cleanupJobEqual(value["id"],aid) { continue }
                if !bool(value,"unlinked"), value["availability"] as? String == "available", mentions(value["path"] ?? "") { holds.insert(.sharedLiveReference) }
                continue
            }
            if bookkeeping.contains(type) { continue }
            if type == "storage_job",value["kind"] as? String == "attachment_import" {
                if mentions(value) {
                    let committed = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=? AND digest=?)",arguments:[value["parent_principal"] as? String ?? "",value["parent_command_id"] as? String ?? "",value["intent_digest"] as? String ?? ""]) ?? false
                    if !committed { holds.insert(.pendingImport) }
                }
                continue
            }
            if type == "storage_job",value["kind"] as? String == "media_attachment_owner" { continue }
            if type == "storage_job",value["kind"] as? String == "archive_cleanup_delete" || value["kind"] as? String == "archive_cleanup_cursor" { continue }
            if type == "storage_hold" {
                guard value["state"] as? String == "active",mentions(value) else { continue }
                if let expiry = value["expires_at"] as? NSNumber,CFGetTypeID(expiry) != CFBooleanGetTypeID(),expiry.doubleValue.isFinite,expiry.doubleValue <= Date().timeIntervalSince1970 { continue }
                // Canonical media references are durable, project-independent physical protection.
                // Releasing a staging reference cannot weaken its replacement target reference.
                if value["kind"] as? String == "media_reference" { holds.insert(.sharedLiveReference) }
                else { holds.insert(value["kind"] as? String == "backup" ? .backupCapture : .activeReader) };continue
            }
            guard referencing.contains(rowIndex) else { continue }
            switch type {
            case "project": holds.insert(.sharedLiveReference) // Current icon/settings asset.
            case "request":
                if value["state"] as? String == "pending" { holds.insert(.pendingHumanInspection) }
                else if taskIsLive(value["task_id"]) { holds.insert(.sharedLiveReference) }
            case "manifest":
                if activeReviews.contains(where: { cleanupJobEqual($0["manifest_id"],value["id"]) }) { holds.insert(.currentReview) }
                else if taskIsLive(value["task_id"]) { holds.insert(.sharedLiveReference) }
            case "source_execution", "source_capture":
                if activeStates.contains(value["state"] as? String ?? "") || bool(value,"process_stop_unverified") { holds.insert(.activeBuild) }
                else if taskIsLive(value["task_id"]) { holds.insert(.sharedLiveReference) }
            default:
                if activeStates.contains(value["state"] as? String ?? "") || taskIsLive(value["task_id"]) { holds.insert(.sharedLiveReference) }
            }
        }
        return holds
    }
}
