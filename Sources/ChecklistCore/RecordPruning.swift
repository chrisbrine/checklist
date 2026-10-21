import Foundation
import GRDB
import CryptoKit

/// CL-72: an opaque cursor that needs no stored row. It seals the event sequence and its
/// creation time with a store key, bound to the caller's principal, the view scope and the
/// store incarnation. The internal sequence stays private; a token is refused for another
/// caller or scope, after 24 hours, after a change of key and when altered.
enum SealedCursor {
    static let prefix = "c1."
    static let maximumAge: TimeInterval = 86_400

    static func binding(principal: String, scope: String, incarnation: String) -> Data {
        Data(SHA256.hash(data: Data((principal + "\u{0}" + scope + "\u{0}" + incarnation).utf8)))
    }

    static func seal(sequence: Int, created: TimeInterval, binding: Data, key: SymmetricKey) throws -> String {
        var payload = Data([1])
        withUnsafeBytes(of: UInt64(max(0, sequence)).bigEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: created.bitPattern.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(binding)
        let sealed = try ChaChaPoly.seal(payload, using: key).combined
        return prefix + sealed.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The sequence, or nil for any token this key and binding cannot accept.
    static func open(_ token: String, binding: Data, key: SymmetricKey, now: TimeInterval = Date().timeIntervalSince1970) -> Int? {
        guard token.hasPrefix(prefix), token.utf8.count <= 512 else { return nil }
        var text = String(token.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let combined = Data(base64Encoded: text), let box = try? ChaChaPoly.SealedBox(combined: combined),
              let payload = try? ChaChaPoly.open(box, using: key), payload.count == 1 + 8 + 8 + 32, payload.first == 1,
              payload.suffix(32) == binding else { return nil }
        let sequence = payload.dropFirst(1).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let created = Double(bitPattern: payload.dropFirst(9).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard created.isFinite, now >= created, now - created < maximumAge, sequence <= UInt64(Int.max) else { return nil }
        return Int(sequence)
    }

    /// One key per store, kept in `metadata`, so a service restart keeps open views valid.
    /// A store that cannot keep it uses a key for this router only.
    static func storeKey(_ db: Database) throws -> SymmetricKey {
        if let value = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='cursor_seal_key'"), let data = Data(base64Encoded: value), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0).base64EncodedString() }
        try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('cursor_seal_key',?)", arguments: [encoded])
        return key
    }
}

/// CL-72: routine records have a retention period. Each pass is bounded and runs in its
/// own short transaction after a command (at most every ten minutes) and at startup.
/// - Cursor rows: issued before sealed cursors; refused after 24 hours, deleted after that.
/// - Command results: kept 30 days for command_id replay. After that the result is
///   replaced by a tombstone; principal, command ID and digest stay, so a late retry is
///   refused with COMMAND_RESULT_EXPIRED and never runs twice. Results that other records
///   still read are kept: policy-bearing project results, pairing receipts and commands
///   that a storage job names.
/// - Cleanup previews: usable only while their ticket revision is current; a stale
///   preview is deleted, and a current one after one day.
extension CommandRouter {
    static let cursorRowRetention: TimeInterval = SealedCursor.maximumAge + 60
    static let commandResultRetention: TimeInterval = 30 * 86_400
    static let cleanupPreviewRetention: TimeInterval = 86_400
    static let commandMarkInterval: TimeInterval = 3_600
    static let routinePruneInterval: TimeInterval = 600
    static let pruneBatch = 500
    /// Cursor rows are deleted by rowid with no JSON work, so a larger batch stays short.
    static let cursorPruneBatch = 20_000
    static let prunedResult = "{\"pruned\":true,\"retention_days\":30}"

    struct PruneCounts: Equatable { var cursors = 0, commandResults = 0, cleanupPreviews = 0 }

    /// Runs when the interval passed; returns nil when it did not run.
    func pruneRoutineRecordsIfDue(_ db: Database, now: Date = Date()) -> PruneCounts? {
        if let last = lastRoutinePrune, now.timeIntervalSince(last) < Self.routinePruneInterval { return nil }
        lastRoutinePrune = now
        return try? pruneRoutineRecords(db, now: now)
    }

    @discardableResult
    func pruneRoutineRecords(_ db: Database, now: Date = Date()) throws -> PruneCounts {
        guard !db.isInsideTransaction else { throw CoreError("CLEANUP_TRANSACTION_REQUIRED", "Prune records after the semantic transaction commits.") }
        var counts = PruneCounts()
        let time = now.timeIntervalSince1970
        try db.inTransaction {
            try db.execute(sql: "DELETE FROM cursors WHERE rowid IN (SELECT rowid FROM cursors WHERE created_at < ? LIMIT ?)", arguments: [time - Self.cursorRowRetention, Self.cursorPruneBatch])
            counts.cursors = db.changesCount
            return .commit
        }
        try db.inTransaction {
            guard let cutoff = try commandRetentionCutoff(db, now: time) else { return .commit }
            try db.execute(sql: """
                UPDATE commands SET result=? WHERE rowid IN (SELECT c.rowid FROM commands c WHERE c.rowid <= ? AND c.result <> ?
                  AND CASE WHEN json_valid(c.result) THEN json_type(c.result,'$.data.policy') IS NULL AND json_type(c.result,'$._connection_registration') IS NULL ELSE 0 END
                  AND NOT EXISTS (SELECT 1 FROM records r WHERE r.type='storage_job' AND CASE WHEN json_valid(r.data) THEN json_extract(r.data,'$.parent_command_id')=c.command_id AND json_extract(r.data,'$.parent_principal')=c.principal ELSE 1 END)
                  ORDER BY c.rowid LIMIT ?)
                """, arguments: [Self.prunedResult, cutoff, Self.prunedResult, Self.pruneBatch])
            counts.commandResults = db.changesCount
            return .commit
        }
        try db.inTransaction {
            let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Self.cleanupPreviewRetention))
            try db.execute(sql: """
                DELETE FROM records WHERE rowid IN (SELECT p.rowid FROM records p LEFT JOIN records t ON t.type='task' AND t.id=CASE WHEN json_valid(p.data) THEN json_extract(p.data,'$.task_id') END
                  WHERE p.type='cleanup_preview' AND json_valid(p.data)
                  AND (t.id IS NULL OR json_extract(p.data,'$.task_revision') <> CASE WHEN json_valid(t.data) THEN json_extract(t.data,'$.revision') END
                       OR COALESCE(json_extract(p.data,'$.created_at'),'9999') < ?)
                  LIMIT ?)
                """, arguments: [cutoff, Self.pruneBatch])
            counts.cleanupPreviews = db.changesCount
            return .commit
        }
        return counts
    }

    /// The commands table has no timestamp. Each pass records (time, highest rowid) at most
    /// hourly in `metadata`; a row at or below the newest mark older than the retention
    /// period is older than that period.
    func commandRetentionCutoff(_ db: Database, now: TimeInterval) throws -> Int64? {
        var marks: [[Double]] = []
        if let raw = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'"),
           let decoded = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[Double]] { marks = decoded.filter { $0.count == 2 && $0[0].isFinite && $0[1] >= 0 } }
        if marks.last.map({ now - $0[0] >= Self.commandMarkInterval }) ?? true {
            let top = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid),0) FROM commands") ?? 0
            marks.append([now, Double(top)])
        }
        let expired = marks.filter { now - $0[0] >= Self.commandResultRetention }
        // Keep the newest expired mark (the cutoff) and every newer mark.
        marks = Array(marks.drop { mark in now - mark[0] >= Self.commandResultRetention && mark != expired.last })
        try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks',?)", arguments: [try jsonString(marks)])
        return expired.last.map { Int64($0[1]) }
    }

    static func isPrunedResult(_ result: JSON) -> Bool { result["pruned"] as? Bool == true && result["data"] == nil }

    static func expiredCommandError(_ command: String) -> CoreError {
        CoreError("COMMAND_RESULT_EXPIRED", "This command ID already ran more than 30 days ago. Its stored result is no longer kept; read the current state instead of retrying.", details: ["command_id": command])
    }
}
