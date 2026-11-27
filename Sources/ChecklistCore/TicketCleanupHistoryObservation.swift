import Foundation
import GRDB

/// Pass-local observations only. They are built and consumed in the same read
/// snapshot; neither history nor command payloads survive into another pass.
struct TicketCleanupEventObservation {
    fileprivate var selected: CleanupHistoryRows = CleanupHistoryRows()
    fileprivate var tasks = Set<String>()
    var errors: [String:CoreError] {selected.errors}

    func events(task: String,matching keys: Set<Data>) throws -> [Row] {
        if let error = selected.errors[task] {throw error}
        guard tasks.contains(task) else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A same-pass ticket history observation is required.")}
        return try (selected.members[task] ?? []).compactMap {index in
            guard let observed = selected.rows[index] else {return nil}
            let entity = (observed.row["entity_id"] as String?).map {Data($0.utf8)}
            guard entity.map({keys.contains($0)}) == true || !observed.tokens.isDisjoint(with:keys) else {return nil}
            return observed.row
        }
    }
}

struct TicketCleanupCommandObservation {
    var commands: [String:[Row]] = [:]
    var errors: [String:CoreError] = [:]
}

private struct CleanupObservedHistoryRow {
    let row: Row
    let tokens: Set<Data>
    let charge: Int
}

/// Store one copy of each shared payload, with bounded per-ticket admission.
/// Refusing one ticket releases its exclusive payloads and leaves others usable.
private struct CleanupHistoryRows {
    static let byteLimit = 64 * 1024 * 1024
    var rows: [Int:CleanupObservedHistoryRow] = [:]
    var members: [String:[Int]] = [:]
    var recipients: [Int:Set<String>] = [:]
    var errors: [String:CoreError] = [:]
    var ticketBytes: [String:Int] = [:]
    var retainedBytes = 0
    var nextIndex = 0

    mutating func fail(_ tasks: Set<String>,_ error: CoreError) {
        for task in tasks where errors[task] == nil {
            errors[task] = error;ticketBytes[task] = nil
            for index in members.removeValue(forKey:task) ?? [] {
                recipients[index]?.remove(task)
                if recipients[index]?.isEmpty == true {
                    retainedBytes -= rows.removeValue(forKey:index)?.charge ?? 0
                    recipients[index] = nil
                }
            }
        }
    }

    mutating func add(_ row: Row,tokens: Set<Data>,bytes: Int,tasks: Set<String>,commands: Bool = false) {
        var admitted = tasks.filter {errors[$0] == nil}
        let rowOverflow = Set(admitted.filter {(members[$0]?.count ?? 0) >= CommandRouter.ticketCleanupSelectedHistoryRowLimit})
        fail(rowOverflow,CommandRouter.ticketCleanupSelectedHistoryLimit(commands:commands))
        admitted.subtract(rowOverflow)
        let oversized = Set(admitted.filter {(ticketBytes[$0] ?? 0) + bytes > TicketCleanupInventory.byteLimit})
        fail(oversized,CoreError("CLEANUP_INVENTORY_LIMIT",commands ? "Selected command results exceed the 16 MiB cleanup bound." : "Selected ticket history exceeds the 16 MiB cleanup bound."))
        admitted.subtract(oversized)
        guard !admitted.isEmpty else {return}
        // Include a conservative charge for Data/Set/dictionary entries, rather
        // than counting only JSON bytes while retaining a large token graph.
        let tokenCharge = tokens.reduce(0) {$0 + $1.count + 96}
        let charge = bytes + tokenCharge + admitted.count * 128 + 256
        guard retainedBytes + charge <= Self.byteLimit else {
            fail(admitted,CoreError("CLEANUP_INVENTORY_LIMIT","The shared cleanup history exceeds its memory bound; this ticket is deferred."))
            return
        }
        let index = nextIndex;nextIndex += 1
        rows[index] = CleanupObservedHistoryRow(row:row.copy(),tokens:tokens,charge:charge)
        recipients[index] = admitted;retainedBytes += charge
        for task in admitted {members[task,default:[]].append(index);ticketBytes[task,default:0] += bytes}
    }
}

extension CommandRouter {
    static let ticketCleanupSelectedHistoryRowLimit = 4096

    static func ticketCleanupSelectedHistoryLimit(commands: Bool) -> CoreError {
        let work = commands ? "cached command results" : "ticket history events"
        return CoreError("PURGE_LIMIT","A ticket exceeds the cleanup limit of 4,096 selected " + work + ".",
                         details:["limit":commands ? "selected_command_rows" : "selected_history_rows","maximum":ticketCleanupSelectedHistoryRowLimit])
    }

    /// Match exact JSON string values and keys when a payload is too large or
    /// too deep to admit in Swift. Invalid JSON cannot prove irrelevance.
    static func ticketCleanupMatchingPayloadKeys(_ db: Database,payloadSQL: String,position: Int64,keys: String) throws -> Set<Data>? {
        let valid = try Bool.fetchOne(db,sql:"SELECT json_valid(payload) FROM (" + payloadSQL + ")",arguments:[position]) == true
        guard valid else {return nil}
        let rows = try Data.fetchCursor(db,sql:"""
            WITH targets AS MATERIALIZED (SELECT CAST(value AS BLOB) value FROM json_each(?))
            SELECT CAST(token.atom AS BLOB)
            FROM (\(payloadSQL)) AS source,json_tree(source.payload) AS token
            WHERE token.type='text' AND CAST(token.atom AS BLOB) IN (SELECT value FROM targets)
            UNION
            SELECT CAST(token.key AS BLOB)
            FROM (\(payloadSQL)) AS source,json_tree(source.payload) AS token
            WHERE typeof(token.key)='text' AND CAST(token.key AS BLOB) IN (SELECT value FROM targets)
            """,arguments:[keys,position,position])
        var matched = Set<Data>()
        while let key = try rows.next() {matched.insert(key)}
        return matched
    }

    /// Binds the removal keys as a JSON array three times. Cleanup writes one
    /// outcome row per removed file, and those rows name a ticket and a receipt
    /// only. A row that names no removal key cannot join the plan.
    static let ticketCleanupHistoryRowSQL = "CASE WHEN kind<>'ticket_evidence_cleanup_outcome' OR NOT json_valid(data) THEN 1 WHEN CAST(entity_id AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) THEN 1 WHEN CAST(json_extract(data,'$.task_id') AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) THEN 1 WHEN CAST(json_extract(data,'$.receipt_id') AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)) THEN 1 ELSE 0 END"

    /// Event payloads are parsed/tokenized once for the selected projects, then
    /// admitted only against the exact removal closure. History belonging to
    /// foreign-protected shared records cannot consume a ticket's history budget.
    func ticketCleanupEventObservation(_ db: Database,tasks: [JSON],inventories: [String:TicketCleanupInventory],referenceGraphs: [String:TicketPurgeReferenceGraph]? = nil) throws -> TicketCleanupEventObservation {
        guard tasks.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 tickets per observation.")}
        var projects: [String:Set<String>] = [:],needles: [String:[Data:Set<String>]] = [:]
        for task in tasks {
            let stored = try StoredRecord(task,family:"task"),tid = try stored.string("id"),pid = try stored.string("project_id")
            guard let inventory = inventories[tid] else {continue}
            let graph: TicketPurgeReferenceGraph
            if let referenceGraphs {
                // The batch has already recorded per-ticket graph failures.
                // Never retry a failed graph while observing another ticket.
                guard let selectedGraph = referenceGraphs[tid] else {continue}
                graph = selectedGraph
            } else {graph = try ticketPurgeReferenceGraph(task:task,inventory:inventory)}
            guard graph.taskID == Data(tid.utf8),graph.projectID == Data(pid.utf8) else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A same-ticket cleanup graph is required.")}
            projects[pid,default:[]].insert(tid)
            let removed = Set(graph.removed.map(\.key)).union([Data(tid.utf8)])
            for key in removed {needles[pid,default:[:]][key,default:[]].insert(tid)}
        }
        var result = TicketCleanupEventObservation()
        for tickets in projects.values {result.tasks.formUnion(tickets)}
        guard !projects.isEmpty else {return result}
        for pid in projects.keys.sorted() {
            let targets = projects[pid] ?? []
            let projectNeedles = needles[pid] ?? [:]
            let keys = try jsonString(projectNeedles.keys.map {String(decoding:$0,as:UTF8.self)})
            let cursor = try Row.fetchCursor(db,sql:"""
                SELECT project_id,seq,id,entity_id,length(CAST(data AS BLOB)) AS payload_bytes,
                    CASE WHEN length(CAST(data AS BLOB))<=? THEN data END AS data
                FROM events WHERE project_id=? AND
                """ + " " + Self.ticketCleanupHistoryRowSQL + " ORDER BY seq",arguments:[TicketCleanupInventory.rowByteLimit,pid,keys,keys,keys])
            while let row = try cursor.next() {
                guard targets.contains(where:{result.selected.errors[$0] == nil}) else {break}
                try autoreleasepool {
                    let entity = (row["entity_id"] as String?).map {Data($0.utf8)}
                    var matched = entity.flatMap {projectNeedles[$0]} ?? []
                    let payloadSQL = "SELECT data AS payload FROM events WHERE seq=?"
                    func refuse(_ error: CoreError) throws {
                        guard let exact = try Self.ticketCleanupMatchingPayloadKeys(db,payloadSQL:payloadSQL,position:row["seq"],keys:keys) else {
                            result.selected.fail(targets,error);return
                        }
                        for key in exact {matched.formUnion(projectNeedles[key] ?? [])}
                        result.selected.fail(matched,error)
                    }
                    guard let data: String = row["data"] else {
                        try refuse(CoreError("CLEANUP_INVENTORY_LIMIT","A selected history event exceeds the 4 MiB payload bound."));return
                    }
                    var tokens = Set<Data>(),budget = 2000000
                    do {try TicketCleanupInventory.strings(jsonObject(data),{tokens.insert(Data($0.utf8))},budget:&budget)}
                    catch let error as CoreError {
                        try refuse(CoreError(error.code,error.message,details:["limit":budget < 0 ? "history_row_tokens" : "history_row_depth","maximum":budget < 0 ? 2000000 : 64]));return
                    }
                    for key in tokens {matched.formUnion(projectNeedles[key] ?? [])}
                    result.selected.add(row,tokens:tokens,bytes:row["payload_bytes"],tasks:matched)
                }
            }
        }
        return result
    }

    /// One global command-result stream for every aged purge in a selection.
    /// Match complete UTF-8 string/key tokens, preserving byte-exact identity.
    func ticketPurgeExpiringCommands(_ db: Database,tasks: [JSON],plans: [String:TicketPurgePlan]) throws -> TicketCleanupCommandObservation {
        guard tasks.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 tickets per observation.")}
        var needles: [Data:Set<String>] = [:],targets = Set<String>()
        for task in tasks {
            let tid = try StoredRecord(task,family:"task").string("id")
            guard let plan = plans[tid] else {continue}
            targets.insert(tid)
            for key in Set(plan.removed.map(\.key)).union([Data(tid.utf8)]) {needles[key,default:[]].insert(tid)}
        }
        var selected = CleanupHistoryRows()
        guard !targets.isEmpty else {return TicketCleanupCommandObservation()}
        let keys = try jsonString(needles.keys.map {String(decoding:$0,as:UTF8.self)})
        let cursor = try Row.fetchCursor(db,sql:"""
            SELECT rowid AS cleanup_row,principal,command_id,CAST(principal AS BLOB) AS cleanup_principal,
                   CAST(command_id AS BLOB) AS cleanup_command_id,
                   length(CAST(result AS BLOB)) AS result_bytes,
                   CASE WHEN length(CAST(result AS BLOB))<=? THEN result END AS result
            FROM commands
            """,arguments:[TicketCleanupInventory.rowByteLimit])
        while let row = try cursor.next() {
            guard targets.contains(where:{selected.errors[$0] == nil}) else {break}
            try autoreleasepool {
                func refuse(_ error: CoreError) throws {
                    let payloadSQL = "SELECT result AS payload FROM commands WHERE rowid=?"
                    guard let exact = try Self.ticketCleanupMatchingPayloadKeys(db,payloadSQL:payloadSQL,position:row["cleanup_row"],keys:keys) else {
                        selected.fail(targets,error);return
                    }
                    var matched = Set<String>()
                    for key in exact {matched.formUnion(needles[key] ?? [])}
                    selected.fail(matched,error)
                }
                guard let data: String = row["result"] else {
                    try refuse(CoreError("CLEANUP_INVENTORY_LIMIT","A selected command result exceeds the 4 MiB payload bound."));return
                }
                var tokens = Set<Data>(),budget = 2000000
                do {try TicketCleanupInventory.strings(jsonObject(data),{tokens.insert(Data($0.utf8))},budget:&budget)}
                catch let error as CoreError {
                    try refuse(CoreError(error.code,error.message,details:["limit":budget < 0 ? "command_row_tokens" : "command_row_depth","maximum":budget < 0 ? 2000000 : 64]));return
                }
                var matched = Set<String>()
                for key in tokens {matched.formUnion(needles[key] ?? [])}
                selected.add(row,tokens:[],bytes:row["result_bytes"],tasks:matched,commands:true)
            }
        }
        var result = TicketCleanupCommandObservation(errors:selected.errors)
        for task in targets where selected.errors[task] == nil {result.commands[task] = (selected.members[task] ?? []).compactMap {selected.rows[$0]?.row}}
        return result
    }
}
