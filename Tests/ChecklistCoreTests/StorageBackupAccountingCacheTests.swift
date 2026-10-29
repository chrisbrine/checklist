import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-343: synthetic receipts only, in the owned ArchiveCleanupExecutionTests store.
extension ArchiveCleanupExecutionTests {
    var accountingCache: StorageBackupAccountingCache { StorageBackupAccountingCache.shared(root:router.root) }
    /// Writes `count` complete synthetic receipts; receipt r lists `entries` keys
    /// starting at r*overlap (duplicates across receipts) plus the real original.
    func insertSyntheticReceipts(_ f: (project: JSON,task: JSON,files: [JSON]),count: Int,entries: Int,overlap: Int = 1000,from first: Int = 0,state: String = "complete") throws {
        let a = f.files[0],relative = String((a["path"] as! String).dropFirst(router.root.path.count + 1))
        try router.dbQueue.writeWithoutTransaction { db in
            for r in first..<(first + count) {
                var objects: [JSON] = [["path":relative,"sha256":a["sha256"]!,"size":a["size"]!]]
                for i in (r * overlap)..<(r * overlap + entries) { objects.append(["path":relative,"sha256":String(format:"%064x",i),"size":i]) }
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + receiptID(r),try jsonString(["state":state,"format":1,"operation_id":receiptID(r),"known_at":String(format:"2026-10-29T00:%02d:00Z",r % 60),"manifest_sha256":String(repeating:"a",count:64),"objects":objects])])
            }
        }
    }
    func receiptID(_ r: Int) -> String { String(format:"00000000-0000-0000-0000-%012d",r) }
    func listObservation(_ f: (project: JSON,task: JSON,files: [JSON])) throws -> (observation: String?,bytes: Int64?,seconds: Double) {
        let start = Date()
        let list = try call("cleanup_job_list",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        let seconds = Date().timeIntervalSince(start),job = try XCTUnwrap((list["cleanup_jobs"] as? [JSON])?.first)
        return (job["backup_retention_observation"] as? String,try? ArchiveCleanupJob.integer(job["known_backup_retained_logical_original_bytes"]),seconds)
    }
    func fullDecodeOriginals() throws -> Set<Data>? { try router.dbQueue.read {db in try? router.storageBackupRetentionIndex(db).originals} }
    func warmOriginals() throws -> Set<Data>? {
        try router.dbQueue.read {db in try router.storageBackupAccounting(db)?.originals}
    }

    func testBackupAccountingColdAnswerThenWarmHitEqualsFullDecode() throws {
        let f = try fixture();_ = try archive(f)
        try insertSyntheticReceipts(f,count:4,entries:300,overlap:100)
        let cold = try listObservation(f)
        XCTAssertEqual(cold.observation,"unavailable");XCTAssertNil(cold.bytes)
        XCTAssertTrue(accountingCache.waitUntilIdle())
        let warm = try listObservation(f)
        XCTAssertEqual(warm.observation,"verified_at_backup_current_presence_unverified");XCTAssertEqual(warm.bytes,64)
        let full = try XCTUnwrap(try fullDecodeOriginals())
        XCTAssertEqual(try warmOriginals(),full);XCTAssertEqual(full.count,601)
        let (builds,parsed) = (accountingCache.buildCount,accountingCache.parsedReceiptCount)
        XCTAssertEqual(builds,1);XCTAssertEqual(parsed,4)
        _ = try listObservation(f);_ = try call("cleanup_job_get",["project_id":f.project["id"]!,"cleanup_job_id":(try listJobID(f))])
        XCTAssertEqual(accountingCache.buildCount,builds);XCTAssertEqual(accountingCache.parsedReceiptCount,parsed)
        // A non-complete receipt makes both computations unavailable; removing it restores accounting without reparsing others.
        try insertSyntheticReceipts(f,count:1,entries:10,from:9,state:"pending")
        XCTAssertEqual(try listObservation(f).observation,"unavailable");XCTAssertTrue(accountingCache.waitUntilIdle())
        XCTAssertNil(try fullDecodeOriginals());XCTAssertEqual(try listObservation(f).observation,"unavailable")
        XCTAssertEqual(accountingCache.parsedReceiptCount,parsed + 1)
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:["backup-generation:" + receiptID(9)])}
        _ = try listObservation(f);XCTAssertTrue(accountingCache.waitUntilIdle())
        XCTAssertEqual(try listObservation(f).bytes,64);XCTAssertEqual(try warmOriginals(),full)
        XCTAssertEqual(accountingCache.parsedReceiptCount,parsed + 1)
    }
    func listJobID(_ f: (project: JSON,task: JSON,files: [JSON])) throws -> String {
        let list = try call("cleanup_job_list",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        return try XCTUnwrap((list["cleanup_jobs"] as? [JSON])?.first?["id"] as? String)
    }
    func testBackupAccountingFingerprintChangesOnAddCompleteRemoveAndUpdatesIncrementally() throws {
        let f = try fixture();_ = try archive(f)
        func fp() throws -> StorageBackupAccountingCache.Fingerprint { try router.dbQueue.read {try StorageBackupAccountingCache.fingerprint($0,incarnation:router.incarnation)} }
        let empty = try fp()
        try insertSyntheticReceipts(f,count:2,entries:50,overlap:25)
        let added = try fp();XCTAssertNotEqual(added,empty);XCTAssertEqual(added.rows.count,2)
        // Completion in place (UPDATE keeps rowid and key) and by INSERT OR REPLACE.
        try insertSyntheticReceipts(f,count:1,entries:50,from:5,state:"pending")
        let pending = try fp()
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"UPDATE metadata SET value=replace(value,'\"state\":\"pending\"','\"state\":\"complete\"') WHERE key=?",arguments:["backup-generation:" + receiptID(5)])}
        let completed = try fp();XCTAssertNotEqual(completed,pending);XCTAssertEqual(completed.rows.map(\.rowid),pending.rows.map(\.rowid))
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) SELECT key,value FROM metadata WHERE key=?",arguments:["backup-generation:" + receiptID(5)])}
        let replaced = try fp();XCTAssertNotEqual(replaced,completed)
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:["backup-generation:" + receiptID(0)])}
        let removed = try fp();XCTAssertNotEqual(removed,replaced);XCTAssertEqual(removed.rows.count,2)
        // Warm, then one added receipt parses only that receipt; a removal parses none.
        _ = try listObservation(f);XCTAssertTrue(accountingCache.waitUntilIdle())
        let parsed = accountingCache.parsedReceiptCount;XCTAssertEqual(parsed,2)
        try insertSyntheticReceipts(f,count:1,entries:50,from:7)
        XCTAssertEqual(try listObservation(f).observation,"unavailable");XCTAssertTrue(accountingCache.waitUntilIdle())
        XCTAssertEqual(accountingCache.parsedReceiptCount,parsed + 1);XCTAssertEqual(try warmOriginals(),try fullDecodeOriginals())
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:["backup-generation:" + receiptID(1)])}
        _ = try listObservation(f);XCTAssertTrue(accountingCache.waitUntilIdle())
        XCTAssertEqual(accountingCache.parsedReceiptCount,parsed + 1);XCTAssertEqual(try warmOriginals(),try fullDecodeOriginals())
        XCTAssertEqual(try listObservation(f).bytes,64)
    }
    func testBackupAccountingTenConcurrentCallersShareOneBuildAndColdCallsDoNotWait() throws {
        let f = try fixture();_ = try archive(f)
        try insertSyntheticReceipts(f,count:3,entries:100)
        let gate = DispatchSemaphore(value:0),cache = accountingCache
        cache.beforeReceiptRead = {gate.wait()}
        defer {cache.beforeReceiptRead = nil}
        let results = NSLock();var observations: [String?] = [],slowest = 0.0,errors = 0
        DispatchQueue.concurrentPerform(iterations:10) {_ in
            do {let r = try listObservation(f);results.lock();observations.append(r.observation);slowest = max(slowest,r.seconds);results.unlock()}
            catch {results.lock();errors += 1;results.unlock()}
        }
        XCTAssertEqual(errors,0);XCTAssertEqual(observations.count,10)
        XCTAssertTrue(observations.allSatisfy {$0 == "unavailable"});XCTAssertLessThan(slowest,2)
        XCTAssertEqual(cache.buildCount,1)
        cache.beforeReceiptRead = nil;for _ in 0..<3 {gate.signal()}
        XCTAssertTrue(cache.waitUntilIdle());XCTAssertEqual(cache.buildCount,1)
        XCTAssertEqual(try listObservation(f).bytes,64);XCTAssertEqual(cache.parsedReceiptCount,3)
    }
    /// The one-time background warm-up is a Debug full parse; under a 10-worker run it can
    /// exceed two minutes, so this perf case waits longer. Request timings stay bounded.
    func testScaledReceiptsListTiming() throws {
        try QualificationSuite.requireEnabled()
        let f = try fixture();_ = try archive(f)
        try insertSyntheticReceipts(f,count:20,entries:20_000)
        let cold = try listObservation(f);XCTAssertEqual(cold.observation,"unavailable")
        let warmStart = Date();XCTAssertTrue(accountingCache.waitUntilIdle(timeout:900));let warmUp = Date().timeIntervalSince(warmStart)
        let warm20 = try listObservation(f);XCTAssertEqual(warm20.bytes,64)
        let oldStart = Date();let full = try fullDecodeOriginals();let old = Date().timeIntervalSince(oldStart)
        XCTAssertTrue(try warmOriginals() == full) // Avoid printing 400k keys on failure.
        try insertSyntheticReceipts(f,count:20,entries:20_000,from:20)
        _ = try listObservation(f);XCTAssertTrue(accountingCache.waitUntilIdle(timeout:900))
        let warm40 = try listObservation(f);XCTAssertEqual(warm40.bytes,64)
        XCTAssertLessThan(cold.seconds,1);XCTAssertLessThan(warm20.seconds,1);XCTAssertLessThan(warm40.seconds,1)
        print("CL343_TIMING cleanup_job_list receipts=20 entries=20000 cold_seconds=\(String(format:"%.3f",cold.seconds)) warm_seconds=\(String(format:"%.3f",warm20.seconds)) warm40_seconds=\(String(format:"%.3f",warm40.seconds)) background_warmup_wait_seconds=\(String(format:"%.3f",warmUp)) old_full_decode_seconds=\(String(format:"%.3f",old))")
    }
}
