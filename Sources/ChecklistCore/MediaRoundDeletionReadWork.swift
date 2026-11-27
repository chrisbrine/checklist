import Foundation
import GRDB

struct MediaRoundDeletionReferences {
    var rows: [JSON] = []
    var ids = Set<Data>()
    var rowsRead = 0

    mutating func merge(_ other: Self) {
        rows.append(contentsOf:other.rows)
        ids.formUnion(other.ids)
        rowsRead += other.rowsRead
    }
}

final class MediaRoundDeletionReferenceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0

    func charge(_ count: Int) throws {
        try lock.withLock {
            guard count <= TicketCleanupInventory.rowByteLimit else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","A selected deletion hold exceeds the 4 MiB payload limit; nothing was removed.")
            }
            guard count <= TicketCleanupInventory.byteLimit - bytes else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected deletion holds exceed the 16 MiB reference limit; nothing was removed.")
            }
            bytes += count
        }
    }
}

enum MediaRoundDeletionReadPiece {
    case references(MediaRoundDeletionReferences, TimeInterval)
    case history(MediaRoundDeletionHistory, TimeInterval)
}

enum MediaRoundDeletionReadWork {
    static let partitions = 3
    // Larger deletions can share the CPU without multiplying four extra read
    // connections for every accepted operation. Others keep the serial scan.
    private static let splitSlots = DispatchSemaphore(value:2)
    private static let referenceQueue = DispatchQueue(label:"org.checklist.media-deletion-references",qos:.utility,attributes:.concurrent,autoreleaseFrequency:.workItem)

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<MediaRoundDeletionReadPiece,Error>?]
        init() {values = Array(repeating:nil,count:MediaRoundDeletionReadWork.partitions + 1)}
        func save(_ value: Result<MediaRoundDeletionReadPiece,Error>,index: Int) {
            lock.withLock {values[index] = value}
        }
        func get() throws -> [MediaRoundDeletionReadPiece]? {
            try lock.withLock {
                let completed = try values.compactMap {$0}.map {try $0.get()}
                return completed.count == values.count ? completed : nil
            }
        }
    }

    /// Pin exactly the caller's WAL snapshot. A SQLite connection that cannot
    /// share it falls back to the original read transaction. Review failures
    /// from the work itself remain errors and never become a serial retry.
    static func perform(_ source: Database,read: @escaping @Sendable (Database,Int) throws -> MediaRoundDeletionReadPiece) throws -> [MediaRoundDeletionReadPiece]? {
        guard try Bool.fetchOne(source,sql:"SELECT EXISTS(SELECT 1 FROM records LIMIT 1 OFFSET 8192)") == true,
              splitSlots.wait(timeout:.now()) == .success else {return nil}
        defer {splitSlots.signal()}
        var configuration = source.configuration
        configuration.maximumReaderCount = partitions + 1
        configuration.qos = .utility
        guard let snapshot = try? DatabaseSnapshotPool(source,configuration:configuration) else {return nil}
        defer {try? snapshot.close()}
        let results = Results()
        @Sendable func observe(_ index: Int) {
            // Failure before running the closure means the same snapshot could
            // not open. Keep the primary observer's exact snapshot for fallback.
            if let result = try? snapshot.read({db in Result {try read(db,index)}}) {
                results.save(result,index:index)
            }
        }
        // Fan out reference scans below ordinary request priority. History uses
        // the caller's deletion worker so it can proceed while the scans run.
        let referenceScans = DispatchGroup()
        for index in 0..<partitions {
            referenceQueue.async(group:referenceScans,qos:.utility,flags:.enforceQoS) {observe(index)}
        }
        observe(partitions)
        referenceScans.wait()
        return try results.get()
    }
}
