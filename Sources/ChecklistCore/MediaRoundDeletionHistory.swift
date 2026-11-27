import Foundation
import GRDB

/// Select history on the reader. Large histories retain event identities and
/// command digests while discarding content that has no remaining consumer.
struct MediaRoundDeletionHistory {
    static let entryLimit = 4096
    static let passLimit = 1024
    static let redactedEventKind = "media_history_redacted"

    struct CommandIdentity: Hashable, Codable {
        let principal: Data
        let command: Data

        init(principal: Data, command: Data) {
            self.principal = principal
            self.command = command
        }

        init(_ principal: String, _ command: String) {
            self.principal = Data(principal.utf8)
            self.command = Data(command.utf8)
        }

        init(_ row: Row) {
            principal = row["locked_principal"]
            command = row["locked_command"]
        }
    }

    private enum Protection: Int {
        case disposable = 0, succeeded, failed, importRecovery, retained
    }

    private struct CommandWork {
        let principal: String
        let id: String
        let bytes: Int
        let protection: Protection
        let settledBinding: String?

        var identity: CommandIdentity { CommandIdentity(principal, id) }
    }

    var events: [String] = []
    var commands: [(String, String)] = []
    private var projectedResults: [CommandIdentity: String] = [:]
    var continuing = false
    var more = false
    var projectsFinal = false

    static let progressPrefix = "media-round-deletion-history:"
    static let projectionProgressField = "_media_history_progress"

    static func progressKey(project: String, round: String) throws -> String {
        progressPrefix + hash(Data(try jsonString([project, round]).utf8))
    }

    private static func matches(_ payload: String) -> String {
        "EXISTS(SELECT 1 FROM json_tree(CASE WHEN json_valid(\(payload)) THEN CASE WHEN json_type(\(payload))='object' THEN \(payload) ELSE '{}' END ELSE '{}' END) j WHERE (j.type='text' AND CAST(j.atom AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))) OR (typeof(j.key)='text' AND CAST(j.key AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))))"
    }

    private static func matchingEvents(_ columns: String) -> String {
        """
        SELECT \(columns) FROM events WHERE project_id=CAST(? AS TEXT) AND (
            CAST(entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))
            OR CASE WHEN kind GLOB 'media_*' AND kind<>'\(redactedEventKind)' THEN \(matches("data")) ELSE 0 END)
        """
    }

    static func select(_ db: Database, project: String, owned: Set<Data>, progressKey: String, continuing: Bool = false, writerLimit: Int = passLimit, ordinaryLimit: Int = entryLimit, ordinaryBytes: Int? = nil, projectFinal: Bool = false) throws -> Self {
        let tokens = try jsonString(owned.map { String(decoding: $0, as: UTF8.self) })
        if !continuing, !projectFinal,
           let ordinary = try selectOrdinary(db, project: project, tokens: tokens, limit:min(ordinaryLimit,writerLimit == passLimit ? entryLimit : writerLimit),workBytes:ordinaryBytes) { return ordinary }
        return try selectPass(db, project: project, tokens: tokens, progressKey: progressKey, limit: writerLimit, projectFinal: projectFinal)
    }

    private static let eventWorkBytes = """
        length(CAST(id AS BLOB))+length(CAST(project_id AS BLOB))+COALESCE(length(CAST(entity_id AS BLOB)),0)
          +length(CAST(actor AS BLOB))+length(CAST(kind AS BLOB))+length(CAST(occurred_at AS BLOB))+length(CAST(data AS BLOB))
        """
    private static let commandWorkBytes = """
        length(CAST(principal AS BLOB))+length(CAST(command_id AS BLOB))+length(CAST(digest AS BLOB))+length(CAST(result AS BLOB))
        """

    /// Small domain transactions also bound the payload pages they will erase.
    /// The default identity limit remains available to compare the old selector.
    private static func selectOrdinary(_ db: Database, project: String, tokens: String, limit: Int, workBytes: Int?) throws -> Self? {
        var result = Self(), remaining = workBytes ?? TicketCleanupInventory.byteLimit
        func admit(_ bytes: Int) -> Bool {
            guard result.events.count + result.commands.count < limit, bytes <= remaining else {return false}
            remaining -= bytes
            return true
        }
        let eventBytes = workBytes == nil ? "length(CAST(id AS BLOB))" : eventWorkBytes
        let events = try Row.fetchCursor(db,sql:matchingEvents("id," + eventBytes + " AS work_bytes"),
                                         arguments:[Data(project.utf8),tokens,tokens,tokens])
        while let row = try events.next() {
            guard admit(row["work_bytes"]) else {return nil}
            result.events.append(row["id"])
        }
        let commandBytes = workBytes == nil ? "length(CAST(principal AS BLOB))+length(CAST(command_id AS BLOB))" : commandWorkBytes
        let commands = try Row.fetchCursor(db,sql:"SELECT principal,command_id," + commandBytes + " AS work_bytes FROM commands WHERE " + matches("result"),
                                           arguments:[tokens,tokens])
        while let row = try commands.next() {
            guard admit(row["work_bytes"]) else {return nil}
            result.commands.append((row["principal"],row["command_id"]))
        }
        return result
    }

    private static func oversized(_ message: String) -> CoreError {
        CoreError("CLEANUP_INVENTORY_LIMIT", message)
    }

    // Import recovery needs data only after commit and before settlement. Other
    // round-owned import states need at most the journal pair and intent digest.
    // Independent consumers can still need the payload after round removal.
    private static func matchingCommands() -> String {
        """
        WITH dependents AS (
            SELECT CAST(json_extract(data,'$.parent_principal') AS BLOB) p,
                   CAST(json_extract(data,'$.parent_command_id') AS BLOB) c,
                   CASE WHEN owned_import
                       THEN CASE WHEN \(MediaRoundDeletionImportRecovery.needsReceiptSQL("data"))
                           THEN \(Protection.importRecovery.rawValue) ELSE 0 END
                       ELSE \(Protection.retained.rawValue) END protection,
                   CASE WHEN owned_import AND json_extract(data,'$.state')='settled'
                       THEN json_array(id,json_extract(data,'$.attachment_id'),json_extract(data,'$.intent_digest')) END settlement
            FROM (
                SELECT id,data,json_extract(data,'$.kind')='attachment_import'
                    AND CAST(id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) owned_import
                FROM records WHERE type='storage_job' AND CASE WHEN json_valid(data) THEN
                    json_type(data,'$.parent_principal')='text' AND json_type(data,'$.parent_command_id')='text' ELSE 0 END
            )
            UNION ALL
            SELECT CAST(json_extract(value,'$.principal') AS BLOB),CAST(json_extract(value,'$.command_id') AS BLOB),\(operationCommandProtection),NULL
            FROM metadata WHERE \(operationKey)
            UNION ALL
            SELECT CAST(json_extract(value,'$.principal') AS BLOB),CAST(json_extract(value,'$.error_result_command_id') AS BLOB),\(operationErrorProtection),NULL
            FROM metadata WHERE \(operationKey)
        ), protection AS MATERIALIZED (
            SELECT p,c,MAX(protection) locked,MAX(settlement) settlement FROM dependents
            WHERE (protection>0 OR settlement IS NOT NULL) AND p IS NOT NULL AND c IS NOT NULL GROUP BY p,c
        )
        SELECT principal,command_id,length(CAST(principal AS BLOB))+length(CAST(command_id AS BLOB))+length(CAST(digest AS BLOB))+length(CAST(result AS BLOB)) work_bytes,
            CASE WHEN json_valid(result) THEN CASE WHEN \(resultHasOtherConsumer)
                THEN \(Protection.retained.rawValue) ELSE COALESCE(locked,0) END ELSE \(Protection.retained.rawValue) END protection,
            CASE WHEN settlement IS NOT NULL AND json_valid(result) THEN CASE
                WHEN CAST(json_extract(settlement,'$[2]') AS BLOB)=CAST(digest AS BLOB)
                 AND CAST(json_extract(settlement,'$[1]') AS BLOB)=CAST(json_extract(result,'$.data.id') AS BLOB)
                THEN json_extract(settlement,'$[0]') || ':' || json_extract(settlement,'$[1]') END END settled_binding
        FROM commands AS journal LEFT JOIN protection ON p=CAST(journal.principal AS BLOB) AND c=CAST(journal.command_id AS BLOB)
        WHERE \(matches("result"))
        ORDER BY journal.rowid
        """
    }

    private static let operationKey = "key GLOB 'command-operation:*'"

    // Match the canonical journal slots read by operationPayload. A failed
    // operation with an inline error already carries its outcome.
    private static let operationCommandProtection = operationProtection(.succeeded, terminalConsumer: "json_extract(value,'$.state')='succeeded'")
    private static let operationErrorProtection = operationProtection(.failed, terminalConsumer: """
        json_extract(value,'$.state')='failed' AND json_type(value,'$.error') IS NULL
        AND json_type(value,'$.error_result_command_id')='text'
        """)

    private static func operationProtection(_ terminal: Protection, terminalConsumer: String) -> String {
        """
        CASE WHEN json_valid(value) THEN CASE
            WHEN json_extract(value,'$.state') IN ('queued','running') OR json_extract(value,'$.recoverable')=1 THEN \(Protection.retained.rawValue)
            WHEN \(terminalConsumer) THEN \(terminal.rawValue)
            ELSE 0 END
        ELSE 0 END
        """
    }

    private static let resultHasOtherConsumer = """
        json_type(result,'$.data.policy') IS NOT NULL
        OR json_type(result,'$._connection_registration') IS NOT NULL
        OR (json_extract(result,'$.data.kind')='task_bulk_edit' AND json_extract(result,'$.data.preview')=0)
        OR json_type(result,'$.data.takeover_notices[0].message_id')='text'
        OR json_type(result,'$.data.handoff_notices[0].message_id')='text'
        OR json_extract(result,'$.data.origin')='automatic_backup_retention'
        OR (json_type(result,'$.data.operation_id')='text' AND json_type(result,'$.data.manifest_sha256')='text')
        """

    private static func selectPass(_ db: Database, project: String, tokens: String, progressKey: String, limit: Int, projectFinal: Bool) throws -> Self {
        var pass = Self(continuing: true, projectsFinal: projectFinal), workBytes = 0
        func admit(_ charge: Int) throws -> Bool {
            guard charge <= TicketCleanupInventory.byteLimit else {
                throw oversized("A matched history row exceeds the 16 MiB work limit for one pass. The round remains present.")
            }
            guard pass.events.count + pass.commands.count < limit,
                  charge <= TicketCleanupInventory.byteLimit - workBytes else { return false }
            workBytes += charge
            return true
        }
        let events = try Row.fetchCursor(db, sql: matchingEvents("id," + eventWorkBytes + " AS work_bytes"), arguments: [Data(project.utf8),tokens,tokens,tokens])
        while let row = try events.next() {
            guard try admit(row["work_bytes"]) else { pass.more = true; return pass }
            pass.events.append(row["id"])
        }
        let malformed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE \(operationKey) AND NOT json_valid(value))")
        guard malformed != true else { throw StoreRecovery.required("command_operation_invalid") }
        let commands = try Row.fetchCursor(db, sql: matchingCommands(), arguments: [tokens,tokens,tokens])
        var reserved: [CommandWork] = []
        var finalBytes = 0
        while let row = try commands.next() {
            guard let protection = Protection(rawValue: row["protection"]) else {
                throw StoreRecovery.required("command_operation_invalid")
            }
            let item = CommandWork(principal:row["principal"],id:row["command_id"],bytes:row["work_bytes"],
                                   protection:protection,settledBinding:row["settled_binding"])
            switch item.protection {
            case .retained:
                throw CoreError("MEDIA_ROUND_REFERENCED", "A retained job, replay or recovery record still requires a matched command result. The round remains present.")
            case .disposable:
                guard try admit(item.bytes) else { pass.more = true; return pass }
                if item.settledBinding != nil {pass.projectedResults[item.identity] = try historyProjection(db,item,progressKey:nil)}
                pass.commands.append((item.principal, item.id))
            case .importRecovery:
                // The graph pass gates final removal on the same recovery states.
                continue
            case .succeeded, .failed:
                if reserved.count < limit, item.bytes <= TicketCleanupInventory.byteLimit - finalBytes {
                    reserved.append(item)
                    finalBytes += item.bytes
                    continue
                }
                // Keep the old final transaction when the reserved set fits.
                // If it cannot fit, move bounded terminal work into this pass.
                for candidate in reserved + [item] {
                    guard try admit(candidate.bytes) else { break }
                    pass.projectedResults[candidate.identity] = try historyProjection(db,candidate,progressKey:progressKey)
                    pass.commands.append((candidate.principal, candidate.id))
                }
                pass.more = true
                return pass
            }
        }
        if reserved.count > limit - pass.events.count - pass.commands.count || finalBytes > TicketCleanupInventory.byteLimit - workBytes {
            pass.more = true
        } else {
            for item in reserved {
                if projectFinal {pass.projectedResults[item.identity] = try historyProjection(db,item,progressKey:progressKey)}
                pass.commands.append((item.principal,item.id))
            }
        }
        return pass
    }

    private static func historyProjection(_ db: Database, _ item: CommandWork, progressKey: String?) throws -> String {
        // The ordinary replay routes already treat this as a tombstone. Only
        // operationPayload can read the projection, under its original digest,
        // scope and authority checks. The progress key contains no graph ID.
        var result = jsonObject(CommandRouter.prunedResult)
        result[projectionProgressField] = progressKey
        if let binding = item.settledBinding {
            result[MediaRoundDeletionImportRecovery.settlementField] = hash(Data(binding.utf8))
        }
        if item.protection == .failed {
            let row = try Row.fetchOne(db, sql: """
                SELECT json_extract(result,'$.error.code') code,
                    json_type(result,'$.error.retryable') retryable,
                    json_extract(result,'$.error.details.command_outcome') command_outcome
                FROM commands WHERE principal=? AND command_id=?
                """, arguments: [item.principal, item.id])
            guard let code: String = row?["code"], !code.isEmpty, code.utf8.count <= 96,
                  code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                throw StoreRecovery.required("command_operation_error_invalid")
            }
            result["_media_history_error_code"] = code
            result["_media_history_retryable"] = (row?["retryable"] as String?) == "true"
            if let outcome: String = row?["command_outcome"], ["unknown", "rejected"].contains(outcome) {
                result["_media_history_command_outcome"] = outcome
            }
        }
        return try jsonString(result)
    }

    static func activeProjection(_ db: Database, result: JSON) throws -> Bool {
        guard CommandRouter.isPrunedResult(result), let key = result[projectionProgressField] as? String,
              key.hasPrefix(progressPrefix) else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?)", arguments: [key]) == true
    }

    static func projectedError(_ result: JSON, command: String) throws -> JSON {
        guard let code = result["_media_history_error_code"] as? String else {
            throw StoreRecovery.required("command_operation_error_invalid")
        }
        var details: JSON = ["command_id": command, "result_redacted": true]
        details["command_outcome"] = result["_media_history_command_outcome"]
        return ["code": code, "message": "This operation failed. Its original error details were removed during round deletion.",
                "retryable": result["_media_history_retryable"] ?? false, "details": details]
    }

    /// The sole writer journals every changed job and operation while preparing.
    /// A new dependency may name the result without mentioning the round itself.
    func validateResultDependents(_ db: Database, journal: String, removed: Set<Data>) throws {
        guard continuing, !commands.isEmpty else { return }
        let selected = Set(commands.map { CommandIdentity($0.0, $0.1) })
        let jobs = try Row.fetchCursor(db, sql: """
            SELECT CAST(r.id AS BLOB) source_id,
                CAST(json_extract(r.data,'$.parent_principal') AS BLOB) locked_principal,
                CAST(json_extract(r.data,'$.parent_command_id') AS BLOB) locked_command
            FROM \(journal) changed JOIN records r ON r.id=CAST(changed.id AS TEXT)
            WHERE changed.kind=0 AND r.type='storage_job' AND CASE WHEN json_valid(r.data) THEN
                json_type(r.data,'$.parent_principal')='text' AND json_type(r.data,'$.parent_command_id')='text' ELSE 0 END
            """)
        while let row = try jobs.next() {
            let id: Data = row["source_id"]
            if !removed.contains(id), selected.contains(CommandIdentity(row)) {
                throw MediaRoundDeletionFence.changed("history_result_dependent",type:"storage_job",id:id)
            }
        }
        let operations = try Row.fetchCursor(db, sql: """
            SELECT CAST(m.key AS BLOB) source_id, json_valid(m.value) valid,
                CASE WHEN json_valid(m.value) THEN CAST(json_extract(m.value,'$.principal') AS BLOB) END locked_principal,
                CASE WHEN json_valid(m.value) THEN CAST(json_extract(m.value,'$.command_id') AS BLOB) END locked_command,
                CASE WHEN json_valid(m.value) THEN CAST(json_extract(m.value,'$.error_result_command_id') AS BLOB) END error_command,
                \(Self.operationCommandProtection) command_protection,
                \(Self.operationErrorProtection) error_protection
            FROM \(journal) changed JOIN metadata m ON m.key=CAST(changed.id AS TEXT)
            WHERE changed.kind=3 AND (NOT json_valid(m.value) OR (\(Self.operationKey)))
            """)
        let minimumProtection = more || projectsFinal ? Protection.succeeded.rawValue : Protection.retained.rawValue
        while let row = try operations.next() {
            let id: Data = row["source_id"]
            guard row["valid"] as Bool else {
                throw MediaRoundDeletionFence.changed("history_operation_invalid",type:"metadata",id:id)
            }
            let locksCommand = (row["command_protection"] as Int) >= minimumProtection
            let locksError = (row["error_protection"] as Int) >= minimumProtection
            guard locksCommand || locksError else {continue}
            guard let principal: Data = row["locked_principal"], let command: Data = row["locked_command"] else {
                throw MediaRoundDeletionFence.changed("history_operation_invalid",type:"metadata",id:id)
            }
            let error: Data? = row["error_command"]
            if locksCommand && selected.contains(CommandIdentity(principal:principal,command:command)) ||
                locksError && error.map({selected.contains(CommandIdentity(principal:principal,command:$0))}) == true {
                throw MediaRoundDeletionFence.changed("history_result_dependent",type:"metadata",id:id)
            }
        }
    }

    struct PreparedWrites {
        let events: String
        let commands: String
    }

    func prepareWrites() throws -> PreparedWrites {
        let replacements = commands.map { principal, id in
            let projection = (more || projectsFinal) ? projectedResults[CommandIdentity(principal,id)] : nil
            return [principal, id, projection ?? CommandRouter.prunedResult]
        }
        return try .init(events:jsonString(events),commands:jsonString(replacements))
    }

    func apply(_ db: Database) throws {
        try apply(db,writes:prepareWrites())
    }

    func apply(_ db: Database, writes: PreparedWrites) throws {
        if !events.isEmpty {
            let scope = "WHERE id IN (SELECT CAST(value AS TEXT) FROM json_each(?))"
            if continuing {
                try db.execute(sql:"UPDATE events SET entity_id=NULL,actor='system:media_history',kind='\(Self.redactedEventKind)',occurred_at='1970-01-01T00:00:00Z',data='{}' " + scope,arguments:[writes.events])
            } else {
                try db.execute(sql:"DELETE FROM events " + scope,arguments:[writes.events])
            }
            guard db.changesCount == events.count else {throw MediaRoundDeletionFence.changed("planned_event_changed",type:"event",id:Data())}
        }
        if !commands.isEmpty {
            try db.execute(sql:"""
                WITH work AS MATERIALIZED (
                    SELECT c.rowid AS position,json_extract(w.value,'$[2]') AS replacement
                    FROM json_each(?) w CROSS JOIN commands c
                    WHERE c.principal=CAST(json_extract(w.value,'$[0]') AS TEXT)
                      AND c.command_id=CAST(json_extract(w.value,'$[1]') AS TEXT)
                )
                UPDATE commands SET result=work.replacement FROM work WHERE commands.rowid=work.position
                """,arguments:[writes.commands])
            guard db.changesCount == commands.count else {throw MediaRoundDeletionFence.changed("planned_command_changed",type:"command",id:Data())}
        }
    }
}
