import Foundation
import GRDB

/// A deletion has a durable visibility boundary and a separate physical removal
/// cursor. The same store transaction advances the cursor and applies its work.
struct MediaRoundDeletionGraph {
    static let rowLimit = 64
    static let byteLimit = 256 * 1024
    static let journalChunkBytes = 192 * 1024
    static let prefix = "media-round-deletion-graph:"
    static let memberPrefix = "media-round-deletion-member:"
    static let keptPrefix = "media-round-deletion-kept:"
    private static let successorMarkerPrefix = "media-round-deletion-successor:"
    static let firstReceiptField = "_media_deletion_receipt"

    struct Progress: Codable, Equatable {
        enum Phase: String, Codable { case staging, deleting, retiring }
        let project: String
        let round: String
        let predecessor: String?
        let revision: Int
        let receipt: String
        let visibilityPrincipal: String
        let visibilityCommand: String
        let visibilityEpoch: String
        let total: Int
        let slices: Int
        var pass: Int
        var handoffWitnessCount: Int? = nil
        var phase: Phase = .staging
        var staged = 0
        var next = 0
        var sliceOffset = 0
        var removed = 0

        func validate(project: String, round: String) throws {
            guard EnvelopeStorageIdentity.equal(self.project,project), EnvelopeStorageIdentity.equal(self.round,round),
                  revision > 0, UUID(uuidString:receipt) != nil, UUID(uuidString:visibilityCommand) != nil,
                  UUID(uuidString:visibilityEpoch) != nil, !visibilityPrincipal.isEmpty, pass > 0, slices > 0,
                  staged >= 0, next >= 0, next <= slices, sliceOffset >= 0, sliceOffset < rowLimit,
                  next < slices || sliceOffset == 0, total > 0, total <= 100_000,
                  removed >= 0, removed <= total,
                  (handoffWitnessCount ?? 0) >= 0,
                  (handoffWitnessCount ?? 0) == 0 || predecessor != nil,
                  phase != .staging || (staged > 0 && next == 0 && sliceOffset == 0 && removed == 0),
                  phase != .deleting || staged > 0,
                  phase != .retiring || (next == slices && removed == total) else {
                throw StoreRecovery.required("media_deletion_graph_progress_invalid")
            }
        }

        var view: JSON {
            ["deleted":false,"deletion_state":"deleting","project_id":project,"round_id":round,
             "removed_records":removed,"total_records":total,"expected_revision":revision]
        }
    }

    struct Shard: Codable {
        let bytes: Data
        let members: [String]
    }

    struct Change: Codable {
        let id: String
        let data: String?
        let revision: Int64?
        let position: Int64
    }

    struct Slice: Codable {
        enum Kind: String, Codable { case descriptor, audit, receipt, detach, erase }
        let kind: Kind
        let changes: [Change]
        var groupEnds: [Int] = []

        func batchEnd(after offset: Int, limit: Int) -> Int {
            guard !groupEnds.isEmpty else {return changes.count}
            // Never split reciprocal import and attachment identities.
            let end = offset + limit
            return groupEnds.last(where: {$0 > offset && $0 <= end})
                ?? groupEnds.first(where: {$0 > offset}) ?? changes.count
        }

        var members: [String] { kind == .erase ? changes.map(\.id) : [] }
    }

    struct Work: Codable {
        let slices: [Slice]
        let fence: MediaRoundDeletionFence
        let kept: Set<Data>
        let handoffOnlyIDs: Set<Data>
    }

    static func successorPrefix(project: String, predecessor: String) throws -> String {
        let key = try MediaRoundDeletionHistory.progressKey(project:project,round:predecessor)
        return successorMarkerPrefix + key.dropFirst(MediaRoundDeletionHistory.progressPrefix.count) + ":"
    }

    static func key(_ historyKey: String) -> String {
        prefix + historyKey.dropFirst(MediaRoundDeletionHistory.progressPrefix.count)
    }

    static func shardKey(_ key: String, _ index: Int) -> String {
        key + ":shard:" + String(index)
    }

    static func handoffWitnessPrefix(_ key: String) -> String {
        key + ":handoff:"
    }

    static func load<T: Decodable>(_ db: Database,_ key: String,as type: T.Type) throws -> T? {
        guard let value = try Data.fetchOne(db,sql:"SELECT CAST(value AS BLOB) FROM metadata WHERE key=?",arguments:[key]) else {return nil}
        do { return try JSONDecoder().decode(type,from:value) }
        catch { throw StoreRecovery.required("media_deletion_graph_journal_invalid") }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding:try JSONEncoder().encode(value),as:UTF8.self)
    }

    static func save<T: Encodable>(_ db: Database,_ key: String,_ value: T) throws {
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try encode(value)])
    }

    static func visibleSQL(_ table: String = "records") -> String {
        """
        NOT EXISTS (SELECT 1 FROM metadata member JOIN metadata deletion ON deletion.key=member.value
          WHERE member.key='\(memberPrefix)'||\(table).id AND json_extract(deletion.value,'$.phase') IN ('deleting','retiring'))
        """
    }

    static func mayOwn(_ type: String) -> Bool {
        MediaRecordRegistry.families.contains(type) || ["attachment","storage_job","storage_hold"].contains(type)
    }

    static func detachMedia(_ row: PurgeRow,_ witness: MediaRoundDeletionFence.Record) throws -> Change {
        // Keep the exact typed identity and immutable revision until every
        // selected media envelope has dropped its edges. The store and backup
        // can still resolve incoming dependencies during these passes.
        guard let project = row.project else {throw StoreRecovery.required("media_deletion_graph_journal_invalid")}
        var tombstone: JSON = ["id":row.id,"project_id":project,"revision":witness.revision,"record_references":[JSON]()]
        if row.type == "media_round" { tombstone["state"] = "deleting" }
        return .init(id:row.id,data:try jsonString(tombstone),revision:witness.revision,position:witness.position)
    }

    /// Storage dependencies have a fixed shape. Drop holds first, then each
    /// attachment and its exact reciprocal import, then the exclusive owners.
    /// The round identity is last. Media cycles have already been detached.
    static func eraseGroups(_ rows: [PurgeRow], round: String) -> [[PurgeRow]] {
        var groups: [[PurgeRow]] = []
        let attachments = Dictionary(uniqueKeysWithValues:rows.filter {$0.type == "attachment"}.map {($0.key,$0)})
        let imports = rows.filter {$0.type == "storage_job" && $0.value["kind"] as? String == "attachment_import"}
        var reciprocal: [Data:PurgeRow] = [:]
        groups += rows.filter {MediaRecordRegistry.families.contains($0.type) && $0.type != "media_round"}.map {[$0]}
        groups += rows.filter {$0.type == "storage_hold"}.map {[$0]}
        for job in imports {
            if let id = job.value["attachment_id"] as? String,let attachment = attachments[Data(id.utf8)],
               EnvelopeStorageIdentity.equal(attachment.value["storage_job_id"] as? String,job.id) {
                reciprocal[attachment.key] = job
            } else {groups.append([job])}
        }
        groups += rows.filter {$0.type == "attachment"}.map { row in
            reciprocal[row.key].map {[$0,row]} ?? [row]
        }
        groups += rows.filter {$0.type == "storage_job" && $0.value["kind"] as? String != "attachment_import"}.map {[$0]}
        // Structural traversal can encounter another family of round record in
        // retained legacy data. Only our root must stay until the very end.
        groups += rows.filter {$0.type == "media_round" && !EnvelopeStorageIdentity.equal($0.id,round)}.map {[$0]}
        groups += rows.filter {$0.type == "media_round" && EnvelopeStorageIdentity.equal($0.id,round)}.map {[$0]}
        return groups
    }

    static func slices(_ kind: Slice.Kind, groups: [[(Change,Int)]]) -> [Slice] {
        var result: [Slice] = [], changes: [Change] = [], groupEnds: [Int] = [], bytes = 0
        for group in groups {
            let charge = group.reduce(0) {$0 + $1.1}
            if !changes.isEmpty && (changes.count + group.count > rowLimit || bytes + charge > byteLimit) {
                result.append(.init(kind:kind,changes:changes,groupEnds:groupEnds))
                changes = []
                groupEnds = []
                bytes = 0
            }
            changes += group.map(\.0)
            groupEnds.append(changes.count)
            bytes += charge
        }
        if !changes.isEmpty {result.append(.init(kind:kind,changes:changes,groupEnds:groupEnds))}
        return result
    }
}
