import Foundation
import GRDB
import SQLite3

/// A read proof spends one deadline across SQLite and Swift work on a snapshot.
struct CleanupObservationDeadline {
    static let preparedSeconds: TimeInterval = 300
    static let writerSeconds: TimeInterval = 5
    let expiresAt: TimeInterval
    let failure: CoreError

    init(seconds: TimeInterval, failure: CoreError) {
        expiresAt = ProcessInfo.processInfo.systemUptime + seconds
        self.failure = failure
    }

    func check() throws {
        guard ProcessInfo.processInfo.systemUptime < expiresAt else {throw failure}
    }

    func observing<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        try check()
        var limit = expiresAt
        return try withUnsafeMutablePointer(to:&limit) {pointer in
            sqlite3_progress_handler(db.sqliteConnection,1000,{context in
                guard let context else {return 1}
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to:TimeInterval.self).pointee ? 1 : 0
            },pointer)
            defer {sqlite3_progress_handler(db.sqliteConnection,0,nil,nil)}
            do {
                let value = try body()
                try check()
                return value
            } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                try check()
                throw error
            }
        }
    }
}
