import Foundation
import GRDB

/// Select history on the reader. Large histories retain event identities and
/// command digests while discarding content that has no remaining consumer.
struct MediaRoundDeletionHistory {
    static let entryLimit = 4096
    static let passLimit = 1024
    static let redactedEventKind = "media_history_redacted"

    struct CommandIdentity: Hashable {
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

    var events: [String] = []
    var commands: [(String, String)] = []
    var continuing = false
    var more = false

    static func progressKey(project: String, round: String) throws -> String {
        "media-round-deletion-history:" + hash(Data(try jsonString([project, round]).utf8))
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

    static func select(_ db: Database, project: String, owned: Set<Data>, continuing: Bool = false) throws -> Self {
        let tokens = try jsonString(owned.map { String(decoding: $0, as: UTF8.self) })
        if !continuing, let ordinary = try selectOrdinary(db, project: project, tokens: tokens) { return ordinary }
        return try selectPass(db, project: project, tokens: tokens)
    }

    /// Preserve the original single-commit plan inside its two admission bounds.
    private static func selectOrdinary(_ db: Database, project: String, tokens: String) throws -> Self? {
        var result = Self(), identityBytes = 0
        func admit(_ bytes: Int) -> Bool {
            guard result.events.count + result.commands.count < entryLimit,
                  bytes <= TicketCleanupInventory.byteLimit - identityBytes else { return false }
            identityBytes += bytes
            return true
        }
        let events = try String.fetchCursor(db, sql: matchingEvents("id"), arguments: [Data(project.utf8),tokens,tokens,tokens])
        while let id = try events.next() {
            guard admit(id.utf8.count) else { return nil }
            result.events.append(id)
        }
        let commands = try Row.fetchCursor(db, sql: "SELECT principal,command_id FROM commands WHERE " + matches("result"), arguments: [tokens,tokens])
        while let row = try commands.next() {
            let principal: String = row["principal"], id: String = row["command_id"]
            guard admit(principal.utf8.count + id.utf8.count) else { return nil }
            result.commands.append((principal,id))
        }
        return result
    }

    private static func oversized(_ message: String) -> CoreError {
        CoreError("CLEANUP_INVENTORY_LIMIT", message)
    }

    // Round-owned jobs and terminal operation receipts can wait for the final
    // pass. Active/recoverable operations and independent consumers can still
    // need their payload when the round's graph leaves.
    private static func matchingCommands() -> String {
        """
        WITH dependents AS (
            SELECT CAST(json_extract(data,'$.parent_principal') AS BLOB) p,
                   CAST(json_extract(data,'$.parent_command_id') AS BLOB) c,
                   CASE WHEN CAST(id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) THEN 1 ELSE 2 END protection
            FROM records WHERE type='storage_job' AND CASE WHEN json_valid(data) THEN
                json_type(data,'$.parent_principal')='text' AND json_type(data,'$.parent_command_id')='text' ELSE 0 END
            UNION ALL
            SELECT CAST(json_extract(value,'$.principal') AS BLOB),CAST(json_extract(value,'$.command_id') AS BLOB),\(operationCommandProtection)
            FROM metadata WHERE \(operationKey)
            UNION ALL
            SELECT CAST(json_extract(value,'$.principal') AS BLOB),CAST(json_extract(value,'$.error_result_command_id') AS BLOB),\(operationErrorProtection)
            FROM metadata WHERE \(operationKey)
        ), protection AS MATERIALIZED (
            SELECT p,c,MAX(protection) locked FROM dependents WHERE protection>0 AND p IS NOT NULL AND c IS NOT NULL GROUP BY p,c
        )
        SELECT principal,command_id,length(CAST(principal AS BLOB))+length(CAST(command_id AS BLOB))+length(CAST(digest AS BLOB))+length(CAST(result AS BLOB)) work_bytes,
            CASE WHEN json_valid(result) THEN CASE WHEN \(resultHasOtherConsumer)
                THEN 2 ELSE COALESCE(locked,0) END ELSE 2 END protection
        FROM commands AS journal LEFT JOIN protection ON p=CAST(journal.principal AS BLOB) AND c=CAST(journal.command_id AS BLOB)
        WHERE \(matches("result"))
        """
    }

    private static let operationKey = "key GLOB 'command-operation:*'"

    // Match the canonical journal slots read by operationPayload. A failed
    // operation with an inline error already carries its outcome.
    private static let operationCommandProtection = operationProtection(terminalConsumer: "json_extract(value,'$.state')='succeeded'")
    private static let operationErrorProtection = operationProtection(terminalConsumer: """
        json_extract(value,'$.state')='failed' AND json_type(value,'$.error') IS NULL
        AND json_type(value,'$.error_result_command_id')='text'
        """)

    private static func operationProtection(terminalConsumer: String) -> String {
        """
        CASE WHEN json_valid(value) THEN CASE
            WHEN json_extract(value,'$.state') IN ('queued','running') OR json_extract(value,'$.recoverable')=1 THEN 2
            WHEN \(terminalConsumer) THEN 1
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

    private static func selectPass(_ db: Database, project: String, tokens: String) throws -> Self {
        var pass = Self(continuing: true), workBytes = 0
        func admit(_ charge: Int) throws -> Bool {
            guard charge <= TicketCleanupInventory.byteLimit else {
                throw oversized("A matched history row exceeds the 16 MiB work limit for one pass. The round remains present.")
            }
            guard pass.events.count + pass.commands.count < passLimit,
                  charge <= TicketCleanupInventory.byteLimit - workBytes else { return false }
            workBytes += charge
            return true
        }
        let eventColumns = """
            id,length(CAST(id AS BLOB))+length(CAST(project_id AS BLOB))+COALESCE(length(CAST(entity_id AS BLOB)),0)
            +length(CAST(actor AS BLOB))+length(CAST(kind AS BLOB))+length(CAST(occurred_at AS BLOB))+length(CAST(data AS BLOB)) work_bytes
            """
        let events = try Row.fetchCursor(db, sql: matchingEvents(eventColumns), arguments: [Data(project.utf8),tokens,tokens,tokens])
        while let row = try events.next() {
            guard try admit(row["work_bytes"]) else { pass.more = true; return pass }
            pass.events.append(row["id"])
        }
        let malformed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE \(operationKey) AND NOT json_valid(value))")
        guard malformed != true else { throw StoreRecovery.required("command_operation_invalid") }
        let commands = try Row.fetchCursor(db, sql: matchingCommands(), arguments: [tokens,tokens,tokens])
        var finalOnly: [(String, String)] = []
        var finalBytes = 0
        while let row = try commands.next() {
            let item: (String, String) = (row["principal"],row["command_id"])
            let charge: Int = row["work_bytes"], protection: Int = row["protection"]
            guard protection != 2 else {
                throw CoreError("MEDIA_ROUND_REFERENCED", "A retained job, replay or recovery record still requires a matched command result. The round remains present.")
            }
            if protection == 1 {
                guard finalOnly.count < passLimit, charge <= TicketCleanupInventory.byteLimit - finalBytes else {
                    throw oversized("Command results required until the round is removed exceed one final history pass. The round remains present.")
                }
                finalOnly.append(item)
                finalBytes += charge
            } else {
                guard try admit(charge) else { pass.more = true; return pass }
                pass.commands.append(item)
            }
        }
        if finalOnly.count > passLimit - pass.events.count - pass.commands.count || finalBytes > TicketCleanupInventory.byteLimit - workBytes {
            pass.more = true
        } else {
            pass.commands.append(contentsOf: finalOnly)
        }
        return pass
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
        let minimumProtection = more ? 1 : 2
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

    func apply(_ db: Database) throws {
        for id in events {
            if continuing {
                try db.execute(sql: "UPDATE events SET entity_id=NULL,actor='system:media_history',kind=?,occurred_at='1970-01-01T00:00:00Z',data='{}' WHERE id=CAST(? AS TEXT)", arguments: [Self.redactedEventKind,Data(id.utf8)])
                guard db.changesCount == 1 else {throw MediaRoundDeletionFence.changed("planned_event_changed",type:"event",id:Data(id.utf8))}
            } else {
                try db.execute(sql: "DELETE FROM events WHERE id=CAST(? AS TEXT)", arguments: [Data(id.utf8)])
            }
        }
        for (principal,id) in commands {
            try db.execute(sql: "UPDATE commands SET result=? WHERE principal=? AND command_id=?", arguments: [CommandRouter.prunedResult,principal,id])
            if continuing,db.changesCount != 1 {throw MediaRoundDeletionFence.changed("planned_command_changed",type:"command",id:Data(id.utf8))}
        }
    }
}
