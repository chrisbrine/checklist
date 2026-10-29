import Foundation
import GRDB

/// Pass-local observations only. They are built and consumed in the same read
/// snapshot; neither history nor command payloads survive into another pass.
struct TicketCleanupEventObservation {
    fileprivate var selected: CleanupHistoryRows = CleanupHistoryRows()
    fileprivate var projects: [String:String] = [:]
    fileprivate var tokenCounts: [String:Int] = [:]
    fileprivate var entityTokenCounts: [String:[Data:Int]] = [:]
    var errors: [String:CoreError] {selected.errors}

    func events(task: String,matching keys: Set<Data>,tokenBudget: Int = 2000000) throws -> [Row] {
        if let error = selected.errors[task] {throw error}
        guard let project = projects[task] else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A same-pass ticket history observation is required.")}
        // The original planner does not traverse a payload whose entity alone
        // matches. Preserve its aggregate traversal bound without re-tokenizing.
        let direct = keys.reduce(0) {$0 + (entityTokenCounts[project]?[$1] ?? 0)}
        guard (tokenCounts[project] ?? 0) - direct <= tokenBudget else {throw CoreError("PURGE_LIMIT","The reference inventory exceeds the safe purge limit. No content was removed.")}
        var bytes = 0
        return try (selected.members[task] ?? []).compactMap {index in
            guard let observed = selected.rows[index] else {return nil}
            let entity = (observed.row["entity_id"] as String?).map {Data($0.utf8)}
            guard entity.map({keys.contains($0)}) == true || !observed.tokens.isDisjoint(with:keys) else {return nil}
            bytes += observed.bytes
            guard bytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected ticket history exceeds the memory bound.")}
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
    let bytes: Int
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

    mutating func add(_ row: Row,tokens: Set<Data>,bytes: Int,tasks: Set<String>,retainTokens: Bool) {
        var admitted = tasks.filter {errors[$0] == nil}
        let oversized = Set(admitted.filter {(ticketBytes[$0] ?? 0) + bytes > TicketCleanupInventory.byteLimit})
        fail(oversized,CoreError("CLEANUP_INVENTORY_LIMIT","Selected ticket history exceeds the memory bound."))
        admitted.subtract(oversized)
        guard !admitted.isEmpty else {return}
        // Include a conservative charge for Data/Set/dictionary entries, rather
        // than counting only JSON bytes while retaining a large token graph.
        let tokenCharge = retainTokens ? tokens.reduce(0) {$0 + $1.count + 96} : 0
        let charge = bytes + tokenCharge + admitted.count * 128 + 256
        guard retainedBytes + charge <= Self.byteLimit else {
            fail(admitted,CoreError("CLEANUP_INVENTORY_LIMIT","The shared cleanup history exceeds its memory bound; this ticket is deferred."))
            return
        }
        let index = nextIndex;nextIndex += 1
        rows[index] = CleanupObservedHistoryRow(row:row.copy(),tokens:retainTokens ? tokens : [],bytes:bytes,charge:charge)
        recipients[index] = admitted;retainedBytes += charge
        for task in admitted {members[task,default:[]].append(index);ticketBytes[task,default:0] += bytes}
    }
}

extension CommandRouter {
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
        for (pid,tickets) in projects {for tid in tickets {result.projects[tid] = pid}}
        guard !projects.isEmpty else {return result}
        for pid in projects.keys.sorted() {
            let targets = projects[pid] ?? []
            let cursor = try Row.fetchCursor(db,sql:"SELECT project_id,seq,id,entity_id,data FROM events WHERE project_id=? ORDER BY seq LIMIT 100001",arguments:[pid])
            var count = 0
            while let row = try cursor.next() {
                guard targets.contains(where:{result.selected.errors[$0] == nil}) else {break}
                count += 1
                guard count <= 100000 else {
                    result.selected.fail(targets,CoreError("PURGE_LIMIT","The ticket history exceeds the safe purge limit."));break
                }
                try autoreleasepool {
                    let data: String = row["data"],bytes = data.utf8.count
                    guard bytes <= TicketCleanupInventory.rowByteLimit else {
                        result.selected.fail(targets,CoreError("CLEANUP_INVENTORY_LIMIT","A history row exceeds the memory bound."));return
                    }
                    var tokens = Set<Data>(),budget = 2000000
                    try TicketCleanupInventory.strings(jsonObject(data),{tokens.insert(Data($0.utf8))},budget:&budget)
                    let tokenCount = 2000000-budget
                    result.tokenCounts[pid,default:0] += tokenCount
                    var matched = Set<String>()
                    if let entity: String = row["entity_id"] {
                        let key = Data(entity.utf8)
                        if let entityTasks = needles[pid]?[key] {
                            matched.formUnion(entityTasks)
                            result.entityTokenCounts[pid,default:[:]][key,default:0] += tokenCount
                        }
                    }
                    for key in tokens {matched.formUnion(needles[pid]?[key] ?? [])}
                    result.selected.add(row,tokens:tokens,bytes:bytes,tasks:matched,retainTokens:true)
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
        let cursor = try Row.fetchCursor(db,sql:"SELECT rowid AS cleanup_row,principal,command_id,CAST(principal AS BLOB) AS cleanup_principal,CAST(command_id AS BLOB) AS cleanup_command_id,result FROM commands LIMIT 100001")
        var count = 0
        while let row = try cursor.next() {
            guard targets.contains(where:{selected.errors[$0] == nil}) else {break}
            count += 1
            guard count <= 100000 else {selected.fail(targets,CoreError("PURGE_LIMIT","The command history exceeds the safe purge limit."));break}
            try autoreleasepool {
                let data: String = row["result"],bytes = data.utf8.count
                guard bytes <= TicketCleanupInventory.rowByteLimit else {
                    selected.fail(targets,CoreError("CLEANUP_INVENTORY_LIMIT","A command history row exceeds the memory bound."));return
                }
                var tokens = Set<Data>(),budget = 2000000
                try TicketCleanupInventory.strings(jsonObject(data),{tokens.insert(Data($0.utf8))},budget:&budget)
                var matched = Set<String>()
                for key in tokens {matched.formUnion(needles[key] ?? [])}
                selected.add(row,tokens:[],bytes:bytes,tasks:matched,retainTokens:false)
            }
        }
        var result = TicketCleanupCommandObservation(errors:selected.errors)
        for task in targets where selected.errors[task] == nil {result.commands[task] = (selected.members[task] ?? []).compactMap {selected.rows[$0]?.row}}
        return result
    }
}
