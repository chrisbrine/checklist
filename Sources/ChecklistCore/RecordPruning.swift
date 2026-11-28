import Foundation
import GRDB
import SQLite3
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

/// CL-72: routine records have a retention period. The service schedules the
/// individual reader preparations and writer steps on its maintenance lane.
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
    static let cursorPruneBatch = 1_000
    static let prunedResult = "{\"pruned\":true,\"retention_days\":30}"
    static let routinePruneStepBudget: TimeInterval = 0.2

    /// `budgetStops` counts steps that SQLite stopped at the time limit (no change kept).
    struct PruneCounts: Equatable { var cursors = 0, commandResults = 0, cleanupPreviews = 0, attachmentReadResults = 0, budgetStops = 0 }

    /// Old command results that pruning may replace with the tombstone. A result stays when
    /// it carries a policy or a connection registration, when a storage job names its command
    /// as parent, or when any storage job has unreadable data (then nothing is pruned).
    ///
    /// Materialize each job once. SQLite can probe a single non-null key in the
    /// membership list without the fallback scans of a row-value NOT IN.
    static let prunableCommandResultsSQL = """
        WITH job_parents AS MATERIALIZED (
          SELECT \(pruneJobParentSQL("r")) AS parent
          FROM records r INDEXED BY records_scope WHERE r.type='storage_job'
        )
        SELECT c.rowid FROM commands c WHERE c.rowid <= ? AND c.result <> ?
          AND CASE WHEN json_valid(c.result) THEN json_type(c.result,'$.data.policy') IS NULL AND json_type(c.result,'$._connection_registration') IS NULL ELSE 0 END
          AND COALESCE(CASE WHEN json_valid(c.result) THEN
              CASE WHEN json_type(c.result,'$.pruned')='true' THEN json_extract(c.result,'$.\(MediaRoundDeletionHistory.projectionProgressField)') END END,'')
              NOT IN (SELECT key FROM metadata WHERE key GLOB '\(MediaRoundDeletionHistory.progressPrefix)*')
          AND NOT EXISTS (SELECT 1 FROM job_parents WHERE parent IS NULL)
          AND json_array(c.command_id,c.principal) NOT IN (SELECT parent FROM job_parents WHERE parent IS NOT NULL)
          ORDER BY c.rowid
        """

    static func pruneJobParentSQL(_ alias: String) -> String {
        """
        CASE WHEN json_valid(\(alias).data) THEN
          CASE WHEN json_extract(\(alias).data,'$.parent_command_id') IS NOT NULL
                 AND json_extract(\(alias).data,'$.parent_principal') IS NOT NULL
            THEN json_array(CAST(json_extract(\(alias).data,'$.parent_command_id') AS TEXT) || '',
                            CAST(json_extract(\(alias).data,'$.parent_principal') AS TEXT) || '')
            ELSE '' END
        END
        """
    }

    /// Runs `body` while SQLite stops any statement that runs past `seconds`; returns nil when
    /// SQLite stopped it (the open transaction rolls back). Same mechanism as
    /// `EpicReferenceIndex.withBudget`, without its Epic-specific error.
    static func withPruneStepBudget<T>(_ db: Database, seconds: TimeInterval, _ body: () throws -> T) throws -> T? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(seconds, 0) * 1_000_000_000)
        let box = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        box.initialize(to: deadline)
        sqlite3_progress_handler(db.sqliteConnection, 1000, { context in
            guard let context else { return 1 }
            return DispatchTime.now().uptimeNanoseconds >= context.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
        }, box)
        defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil); box.deinitialize(count: 1); box.deallocate() }
        do { return try body() }
        catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT { return nil }
    }

    /// The commands table has no timestamp. Each pass records (time, highest rowid) at most
    /// hourly in `metadata`; a row at or below the newest mark older than the retention
    /// period is older than that period.
    func commandRetentionCutoff(_ db: Database, now: TimeInterval, refresh: Bool = true) throws -> Int64? {
        let raw = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'")
        var marks = Self.decodeCommandRetentionMarks(raw)
        if !refresh { return marks.last { now - $0[0] >= Self.commandResultRetention }.map { Int64($0[1]) } }
        if marks.last.map({ now - $0[0] >= Self.commandMarkInterval }) ?? true {
            let top = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid),0) FROM commands") ?? 0
            marks.append([now, Double(top)])
        }
        let expired = marks.filter { now - $0[0] >= Self.commandResultRetention }
        // Keep the newest expired mark (the cutoff) and every newer mark.
        marks = Array(marks.drop { mark in now - mark[0] >= Self.commandResultRetention && mark != expired.last })
        let encoded = try jsonString(marks)
        if encoded != raw {
            try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks',?)", arguments: [encoded])
        }
        return expired.last.map { Int64($0[1]) }
    }

    private static func decodeCommandRetentionMarks(_ raw: String?) -> [[Double]] {
        guard let raw, let marks = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[Double]] else { return [] }
        return marks.filter { $0.count == 2 && $0[0].isFinite && $0[1] >= 0 && $0[1] < Double(Int64.max) && $0[1].rounded(.down) == $0[1] }
    }

    static func isPrunedResult(_ result: JSON) -> Bool { result["pruned"] as? Bool == true && result["data"] == nil }

    static func expiredCommandError(_ command: String) -> CoreError {
        CoreError("COMMAND_RESULT_EXPIRED", "This command's stored reply is no longer available. Read the current state before starting a new command.", details: ["command_id": command])
    }
}
