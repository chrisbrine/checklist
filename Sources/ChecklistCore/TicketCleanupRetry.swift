import Foundation
import GRDB

/// A token distinguishes a new wake from the retry observed by preparation,
/// including when the same ticket changes while it was observed as open.
struct TicketCleanupRetry {
    let deadline: Double
    let token: String
    init(at time: Date) {deadline = time.timeIntervalSince1970;token = uuid()}
    init(deadline: Double,token: String) {self.deadline = deadline;self.token = token}
    var value: JSON {["deadline":deadline,"token":token]}
}

extension TicketCleanupPreparedPass {
    func revalidated(_ db: Database,router: CommandRouter) throws -> Self {
        try fence.validate(db)
        return try router.revalidateTicketCleanupPass(db,prepared:self)
    }
}

extension CommandRouter {
    /// Retry only tickets whose own selected records changed. Other prepared
    /// tickets keep their original snapshot and commit in the same short chunk.
    func revalidateTicketCleanupPass(_ db: Database,prepared: TicketCleanupPreparedPass) throws -> TicketCleanupPreparedPass {
        var selection = prepared.selection
        var items = selection["items"] as? [JSON] ?? [],retryIDs = selection["retry_task_ids"] as? [String] ?? []
        for index in items.indices {
            guard items[index]["action"] as? String != "keep",let id = items[index]["task_id"] as? String,
                  let fence = prepared.itemFences[id] else {continue}
            do {try fence.validate(db)} catch let error as CoreError where error.code == "CLEANUP_CONCURRENT_WRITE" {
                items[index]["action"] = "keep";items[index]["reason"] = "fenced_by_concurrent_write"
                items[index]["fence_reason"] = error.details["reason"] ?? error.code
                retryIDs.append(id)
            }
        }
        selection["items"] = items;selection["retry_task_ids"] = retryIDs
        selection["selected_bytes"] = items.filter {$0["action"] as? String != "keep"}.reduce(Int64(0)) {$0 + ((($1["summary"] as? JSON)?["pending_bytes"] as? NSNumber)?.int64Value ?? 0)}
        return TicketCleanupPreparedPass(fence:prepared.fence,project:prepared.project,selection:selection,plans:prepared.plans,expiredCommands:prepared.expiredCommands,itemFences:prepared.itemFences)
    }

    func ticketCleanupRetryEntries(_ db: Database,project: String) throws -> [String:TicketCleanupRetry] {
        let value = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-retries:" + project]) ?? "{}")
        return try value.mapValues {raw in
            if let legacy = raw as? NSNumber {return TicketCleanupRetry(deadline:legacy.doubleValue,token:"legacy")}
            guard let entry = raw as? JSON,let deadline = entry["deadline"] as? Double,let token = entry["token"] as? String,!token.isEmpty else {
                throw CoreError("CLEANUP_RETRY_INVALID","Cleanup retry scheduling needs repair; bytes retained.")
            }
            return TicketCleanupRetry(deadline:deadline,token:token)
        }
    }
    func ticketCleanupRetries(_ db: Database,project: String) throws -> [String:Double] {
        try ticketCleanupRetryEntries(db,project:project).mapValues(\.deadline)
    }
    func saveTicketCleanupRetries(_ db: Database,project: String,entries: [String:TicketCleanupRetry]) throws {
        try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-retries:" + project,try jsonString(entries.mapValues(\.value))])
    }
}
