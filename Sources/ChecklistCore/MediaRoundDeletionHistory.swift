import Foundation
import GRDB

/// Project event and command-result matching stays on the reader. Only exact
/// matches cross into the bounded, atomic deletion plan.
struct MediaRoundDeletionHistory {
    var events: [String] = []
    var commands: [(String,String)] = []

    private static func matches(_ payload: String) -> String {
        "EXISTS(SELECT 1 FROM json_tree(CASE WHEN json_valid(\(payload)) THEN CASE WHEN json_type(\(payload))='object' THEN \(payload) ELSE '{}' END ELSE '{}' END) j WHERE (j.type='text' AND CAST(j.atom AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))) OR (typeof(j.key)='text' AND CAST(j.key AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))))"
    }

    static func select(_ db: Database,project: String,owned: Set<Data>) throws -> Self {
        var result = Self(),identityBytes = 0
        let tokens = try jsonString(owned.map {String(decoding:$0,as:UTF8.self)})
        func admit(_ bytes: Int) throws {
            guard result.events.count + result.commands.count < 4096 else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","The round matches more than 4,096 events and command results; nothing was removed.")
            }
            guard bytes <= TicketCleanupInventory.byteLimit - identityBytes else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","The round's matched event and command identities exceed 16 MiB; nothing was removed.")
            }
            identityBytes += bytes
        }
        let events = try String.fetchCursor(db,sql:"""
            SELECT id FROM events WHERE project_id=CAST(? AS TEXT) AND (
                CAST(entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))
                OR CASE WHEN kind GLOB 'media_*' THEN \(matches("data")) ELSE 0 END)
            """,arguments:[Data(project.utf8),tokens,tokens,tokens])
        while let id = try events.next() {
            try admit(id.utf8.count)
            result.events.append(id)
        }
        let commands = try Row.fetchCursor(db,sql:"SELECT principal,command_id FROM commands WHERE " + matches("result"),arguments:[tokens,tokens])
        while let row = try commands.next() {
            let principal: String = row["principal"],id: String = row["command_id"]
            try admit(principal.utf8.count + id.utf8.count)
            result.commands.append((principal,id))
        }
        return result
    }
}
