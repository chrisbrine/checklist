import Foundation

/// One charge across the selected record graph, history, command identities
/// and byte plan. Charges include room for decoded values and temporary indexes;
/// this measures retained work, not process RSS or the unrelated store corpus.
final class ManualTicketPurgeBudget {
    static let retainedByteLimit = 64 * 1024 * 1024
    static let writerSeconds: TimeInterval = CleanupObservationDeadline.writerSeconds
    let readDeadline = CleanupObservationDeadline(seconds:CleanupObservationDeadline.preparedSeconds,
        failure:CoreError("CLEANUP_INVENTORY_LIMIT",
            "Permanent ticket removal could not complete its reference proof within the time budget. No content was removed.",
            details:["limit":"observation_seconds","maximum":CleanupObservationDeadline.preparedSeconds]))
    private var retainedBytes = 0
    private let observe: ((String,TimeInterval) -> Void)?

    init(observe: ((String,TimeInterval) -> Void)? = nil) {self.observe = observe}

    static var writerLimit: CoreError {
        CoreError("PURGE_LIMIT","Permanent ticket removal exceeded its atomic writer time budget. No content was removed.",
                  details:["limit":"writer_seconds","maximum":writerSeconds])
    }

    func retain(_ bytes: Int) throws {
        try readDeadline.check()
        guard bytes <= Self.retainedByteLimit - retainedBytes else {
            throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected ticket exceeds the 64 MiB purge plan budget. No content was removed.",
                            details:["limit":"selected_plan_bytes","maximum":Self.retainedByteLimit])
        }
        retainedBytes += bytes
    }

    func retainPayload(_ bytes: Int, tokens: Set<Data>) throws {
        // Include full payload and digest serialization, plus decoded row,
        // dictionary/set entries and reference edges derived from its tokens.
        try retain(4 * bytes + tokens.reduce(512) {$0 + 2 * $1.count + 160})
    }

    func measuring<T>(_ phase: String,_ body: () throws -> T) rethrows -> T {
        guard let observe else {return try body()}
        let started = ProcessInfo.processInfo.systemUptime
        defer {observe(phase,ProcessInfo.processInfo.systemUptime-started)}
        return try body()
    }
}
