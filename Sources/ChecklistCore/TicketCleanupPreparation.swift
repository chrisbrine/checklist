import Foundation
import GRDB

/// Only the maintenance lane owns this cache. Refresh against one read snapshot;
/// unchanged canonical rows reuse their decoded payload and exact UTF-8 edges.
/// A cache is never deletion authority: the writer generation must still match.
final class TicketCleanupReferenceCache {
    struct Entry {
        let envelope: EnvelopeRow
        let bytes: Data
        let row: PurgeRow
        let tokens: Set<Data>
        let visits: Int
    }
    private var entries: [Data:Entry] = [:]
    func refresh(_ db: Database) throws -> TicketCleanupInventory {
        var next: [Data:Entry] = [:],rows: [PurgeRow] = [],tokens: [Data:Set<Data>] = [:],edges = 0
        let cursor = try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid")
        while let raw = try cursor.next() {
            guard rows.count < 100000 else {throw CoreError("PURGE_LIMIT","The reference inventory exceeds the safe cleanup limit; bytes retained.")}
            let envelope = try GRDBRecordEnvelopeAdapter.input(raw)
            guard case .text(let rawID) = envelope.id,case .text(let rawType) = envelope.type,
                  case .text(let rawData) = envelope.data else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
            let key = Data(rawID.utf8),bytes = Data(rawData.utf8)
            let projectBytes: Data?
            switch envelope.project {
            case .null:projectBytes = nil
            case .text(let project):projectBytes = Data(project.utf8)
            default:throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlProject))
            }
            let entry: Entry
            if let prior = entries[key],prior.bytes == bytes,prior.envelope.revision == envelope.revision,
               Data(prior.row.type.utf8) == Data(rawType.utf8),prior.row.project.map({Data($0.utf8)}) == projectBytes {
                entry = prior
            } else {
                let value = try GRDBRecordEnvelopeAdapter.decode(raw)
                var found = Set<Data>(),visits = 0
                func visit(_ value: Any,depth: Int = 0) throws {
                    visits += 1
                    guard depth <= 64,visits <= 2000000 else {throw CoreError("REFERENCE_GRAPH_LIMIT","The object ownership inventory exceeds the safe cleanup limit.")}
                    if let s = value as? String {found.insert(Data(s.utf8))}
                    else if let a = value as? [Any] {for v in a {try visit(v,depth:depth+1)}}
                    else if let d = value as? JSON {for (k,v) in d {found.insert(Data(k.utf8));try visit(v,depth:depth+1)}}
                }
                let bookkeeping = value.type == "storage_job" && value.object["kind"] as? String == "ticket_object_delete"
                if !bookkeeping {try visit(value.object);found.insert(Data("record_type".utf8));found.insert(Data(value.type.utf8))}
                entry = Entry(envelope:envelope,bytes:bytes,row:PurgeRow(id:value.id,type:value.type,project:value.projectID,value:value.object),tokens:found,visits:visits)
            }
            edges += entry.visits
            guard edges <= 2000000 else {throw CoreError("REFERENCE_GRAPH_LIMIT","The object ownership inventory exceeds the safe cleanup limit.")}
            next[key] = entry;rows.append(entry.row);tokens[key] = entry.tokens
        }
        entries = next
        return TicketCleanupInventory(rows:rows,tokens:tokens)
    }
}
struct TicketCleanupInventory {
    let rows: [PurgeRow]
    let tokens: [Data:Set<Data>]
}
struct TicketCleanupPreparedPass {
    let project: JSON
    let selection: JSON
    let plans: [String:TicketPurgePlan]
    let expiredCommands: [String:[Row]]
}
struct TicketCleanupPreparedDeletion {
    let receipt: JSON
    let references: TicketObjectDeletionReferenceIndex
    let backup: StorageBackupRetentionIndex?
    let mediaAuthorityComplete: Bool
    let candidatePath: String?
    let verification: TicketObjectRemovalVerification?
    let verificationFailure: Error?
}

extension CommandRouter {
    /// Expensive graph/file observation runs without the object gate or writer.
    /// All supported writes use this router's writer connection. Its total-change
    /// counter also detects direct SQL, deletions, rolled-back attempts and new
    /// holds. Any intervening write discards preparation before semantic commit.
    func withTicketCleanupPreparation<T>(_ prepare: (Database) throws -> T?,commit: (Database,ArchiveStoragePermit,T) throws -> Void) throws {
        guard let readers else {return} // No safe read lane: retain, never fall back to a long writer scan.
        let generation = try dbQueue.read {($0.totalChangesCount,try Int.fetchOne($0,sql:"PRAGMA data_version"))}
        guard let prepared = try readers.read(prepare) else {return}
        try ArchiveStorageGate.withExclusive(root:root) {permit in
            try dbQueue.writeWithoutTransaction {db in
                guard db.totalChangesCount == generation.0,try Int.fetchOne(db,sql:"PRAGMA data_version") == generation.1,try !StorageSnapshotRetention.isActive(root:root) else {return}
                try commit(db,permit,prepared)
            }
        }
    }
    func runTicketLifecycleCleanup(at time: Date = Date()) throws {
        ticketCleanupMaintenanceLock.lock();defer {ticketCleanupMaintenanceLock.unlock()}
        try withTicketCleanupPreparation({try self.prepareTicketLifecycleCleanup($0,at:time)}) {db,_,prepared in
            try self.commitTicketLifecycleCleanup(db,prepared:prepared,at:time)
        }
    }
    func prepareTicketObjectDeletion(_ db: Database) throws -> TicketCleanupPreparedDeletion? {
        guard let raw = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='storage_job' AND json_valid(data) AND json_extract(data,'$.kind')='ticket_object_delete' AND json_extract(data,'$.state')='pending' ORDER BY rowid LIMIT 1") else {return nil}
        let receipt = try GRDBRecordEnvelopeAdapter.decode(raw).object
        let inventory = try ticketCleanupReferenceCache.refresh(db)
        let graph = try ticketCleanupDeletionReferences(db,receipt:receipt,inventory:inventory)
        let references = try TicketObjectDeletionReferenceIndex(graph,tokens:inventory.tokens)
        let backup = try? storageBackupRetentionIndex(db),mediaComplete = (try? MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db))) != nil
        var objects = receipt["objects"] as? [JSON] ?? []
        for i in objects.indices where objects[i]["state"] as? String == "pending" && objects[i]["kind"] as? String == "symlink" {
            let holds = try ticketObjectDeletionHolds(db,object:objects[i],references:references,backup:backup,mediaAuthorityComplete:mediaComplete)
            if !holds.isEmpty {objects[i]["state"] = "retained";objects[i]["reasons"] = holds.sorted()}
        }
        let targets = Self.retainTicketObjectDeletionLinkTargets(&objects)
        let candidate = objects.first {$0["state"] as? String == "pending" && !targets.contains($0["relative_path"] as? String ?? "")}
        var verification: TicketObjectRemovalVerification?,failure: Error?
        if let candidate,candidate["kind"] as? String == "file",
           try ticketObjectDeletionHolds(db,object:candidate,references:references,backup:backup,mediaAuthorityComplete:mediaComplete).isEmpty,
           let path = candidate["relative_path"] as? String,let sha = candidate["sha256"] as? String,let size = (candidate["size"] as? NSNumber)?.int64Value {
            do {verification = try TicketObjectRemovalVerification(root:root,relative:path,sha256:sha,size:size)} catch {failure = error}
        }
        return TicketCleanupPreparedDeletion(receipt:receipt,references:references,backup:backup,mediaAuthorityComplete:mediaComplete,candidatePath:candidate?["relative_path"] as? String,verification:verification,verificationFailure:failure)
    }
}
