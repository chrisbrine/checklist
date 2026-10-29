import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-355: the cleanup's backup lookup uses the per-receipt index and equals the
/// earlier full descriptor scan. Synthetic receipts only.
extension TicketLifecycleCleanupTests {
    static func p355ResidentBytes() -> UInt64 {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) {$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static let fingerprintSQL = "octet_length(value) AS bytes"
    static let receiptReadSQL = "AS summary_manifest FROM metadata WHERE rowid=? AND key=?"
    var backupIndexCache: StorageBackupAccountingCache { StorageBackupAccountingCache.shared(root:router.root) }

    func insertCleanupReceipt(_ key: String,objects: [JSON],copy: String? = nil,manifest: String = String(repeating:"b",count:64),summaryManifest: String? = nil,state: String = "complete") throws {
        var value: JSON = ["state":state,"objects":objects]
        if let copy {value["manifest_sha256"] = manifest;value["summary"] = ["path":copy,"verification":"manifest_database_managed_files","manifest_sha256":summaryManifest ?? manifest]}
        try write {db in try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + key,try jsonString(value)])}
    }
    func cleanupEntry(_ path: String,_ n: Int) -> JSON { ["path":path,"sha256":String(format:"%064x",n),"size":n] }
    func cleanupWanted(_ path: String,_ n: Int) -> JSON { ["relative_path":path,"sha256":String(format:"%064x",n),"size":n] }
    /// Counts per-receipt value reads while running one cleanup lookup.
    func cleanupLookup(_ objects: [JSON]) throws -> (index: StorageBackupRetentionIndex,reads: Int) {
        var reads = 0
        let index = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains(Self.receiptReadSQL) {reads += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupBackupRetentionIndex(db,objects:objects)
        }
        return (index,reads)
    }
    func assertCleanupIndexEqualsFullScan(_ objects: [JSON],file: StaticString = #filePath,line: UInt = #line) {
        let new = Result {try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndex($0,objects:objects)}}
        let old = Result {try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndexFullScan($0,objects:objects)}}
        switch (new,old) {
        case (.success(let a),.success(let b)):
            XCTAssertEqual(a.originals,b.originals,file:file,line:line);XCTAssertEqual(a.copyPaths,b.copyPaths,file:file,line:line);XCTAssertEqual(a.copyManifests,b.copyManifests,file:file,line:line)
        case (.failure(let a),.failure(let b)):
            XCTAssertEqual("\(a)","\(b)",file:file,line:line)
        default: XCTFail("index \(new) differs from full scan \(old)",file:file,line:line)
        }
    }

    func testCleanupBackupIndexEqualsFullScanAcrossReceipts() throws {
        let (_,_,attachment) = try fixture()
        let real = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let absolute = router.root.standardizedFileURL.path + "/"
        try insertCleanupReceipt("p355-a",objects:[cleanupEntry("objects/p355/k1",1),cleanupEntry("objects/p355/k1",1),cleanupEntry("objects/p355/k2",2),cleanupEntry("objects/p355/u1",9)],copy:"/tmp/p355-copy-a")
        try insertCleanupReceipt("p355-b",objects:[cleanupEntry("objects/p355/k1",1),cleanupEntry(absolute + "objects/p355/k3",3),cleanupEntry("/elsewhere/objects/p355/k1",1)])
        try insertCleanupReceipt("p355-c",objects:[cleanupEntry("objects/p355/k2",2),cleanupEntry(absolute + "objects/p355/k3",3),cleanupEntry("objects/p355/alias",1),cleanupEntry("source-captures/p355/s1",5)],copy:"/tmp/p355-copy-c")
        try insertCleanupReceipt("p355-d",objects:[cleanupEntry("objects/p355/k2",2)],copy:"/tmp/p355-copy-a",manifest:String(repeating:"c",count:64))
        try insertCleanupReceipt("p355-e",objects:[cleanupEntry("objects/p355/k1",1)],copy:"/tmp/p355-copy-e",summaryManifest:String(repeating:"d",count:64))
        let wanted: [JSON] = [cleanupWanted("objects/p355/k1",1),cleanupWanted("objects/p355/k2",2),cleanupWanted("objects/p355/k3",3),cleanupWanted("objects/p355/k4",4),cleanupWanted("source-captures/p355/s1",5),
                              ["relative_path":real,"sha256":attachment["sha256"]!,"size":attachment["size"]!]]
        assertCleanupIndexEqualsFullScan(wanted);assertCleanupIndexEqualsFullScan([])
        let index = try cleanupLookup(wanted).index,k1 = StorageBackupRetentionIndex.key(path:"objects/p355/k1",sha:String(format:"%064x",1),size:1)
        XCTAssertEqual(index.copyPaths[k1]?.map(\.path),["/tmp/p355-copy-a","/tmp/p355-copy-a"],"duplicate entries keep their multiplicity; a mismatched manifest is not independent")
        XCTAssertEqual(index.copyManifests["/tmp/p355-copy-a"],String(repeating:"c",count:64));XCTAssertNil(index.copyManifests["/tmp/p355-copy-e"])
        XCTAssertFalse(index.originals.contains(StorageBackupRetentionIndex.key(path:"objects/p355/k4",sha:String(format:"%064x",4),size:4)))
        // An invalid receipt gives the same StoreRecovery outcome; the index never hides it.
        try insertCleanupReceipt("p355-z",objects:[["path":"objects/p355/bad","size":1]])
        assertCleanupIndexEqualsFullScan(wanted)
        XCTAssertThrowsError(try cleanupLookup(wanted)) {XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"backup_receipt_index_invalid")}
        XCTAssertThrowsError(try cleanupLookup([]))
        try write {db in try db.execute(sql:"DELETE FROM metadata WHERE key='backup-generation:p355-z'")}
        assertCleanupIndexEqualsFullScan(wanted)
    }

    func testCleanupBackupIndexUpdatesIncrementallyWithoutPerStepParse() throws {
        _ = try fixture()
        try insertCleanupReceipt("p355-a",objects:[cleanupEntry("objects/p355/k1",1),cleanupEntry("objects/p355/k2",2)],copy:"/tmp/p355-copy-a")
        try insertCleanupReceipt("p355-b",objects:[cleanupEntry("objects/p355/k2",2)])
        let wanted = [cleanupWanted("objects/p355/k1",1),cleanupWanted("objects/p355/k2",2),cleanupWanted("objects/p355/k3",3)]
        _ = try cleanupLookup(wanted)
        let parsed = backupIndexCache.parsedReceiptCount
        for _ in 0..<3 {XCTAssertEqual(try cleanupLookup(wanted).reads,0)}
        XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed,"a warm step parses no receipt")
        assertCleanupIndexEqualsFullScan(wanted)
        // Add: exactly the new receipt is read and parsed.
        try insertCleanupReceipt("p355-c",objects:[cleanupEntry("objects/p355/k3",3)],copy:"/tmp/p355-copy-c")
        XCTAssertEqual(try cleanupLookup(wanted).reads,1);XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed + 1)
        assertCleanupIndexEqualsFullScan(wanted)
        // Complete: a pending receipt is invalid until its in-place completion is parsed once.
        try insertCleanupReceipt("p355-d",objects:[cleanupEntry("objects/p355/k1",1)],copy:"/tmp/p355-copy-d",state:"pending")
        XCTAssertThrowsError(try cleanupLookup(wanted));XCTAssertThrowsError(try cleanupLookup(wanted))
        XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed + 2,"an invalid receipt is parsed once, then reported from the index")
        assertCleanupIndexEqualsFullScan(wanted)
        try write {db in try db.execute(sql:"UPDATE metadata SET value=json_set(value,'$.state','complete') WHERE key='backup-generation:p355-d'")}
        XCTAssertEqual(try cleanupLookup(wanted).reads,1);XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed + 3)
        assertCleanupIndexEqualsFullScan(wanted)
        // Remove: no receipt is parsed again.
        try write {db in try db.execute(sql:"DELETE FROM metadata WHERE key='backup-generation:p355-a'")}
        XCTAssertEqual(try cleanupLookup(wanted).reads,0);XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed + 3)
        assertCleanupIndexEqualsFullScan(wanted)
        XCTAssertNil(try cleanupLookup(wanted).index.copyPaths[StorageBackupRetentionIndex.key(path:"objects/p355/k2",sha:String(format:"%064x",2),size:2)])
    }

    func testBackupRetentionKeyFastPathMatchesJSONEncoding() {
        let paths = ["objects/p355/k1","objects/a b/c-d_e.f","source-captures/x/y","/abs/root/objects/z","objects/q\"uote","objects/back\\slash","objects/caf\u{e9}","objects/tab\tx","objects/del\u{7f}"]
        for path in paths {
            for (sha,size) in [(String(repeating:"a",count:64),Int64(0)),("sha/with/slash",Int64(-1)),("\u{1}",Int64.max)] {
                XCTAssertEqual(StorageBackupRetentionIndex.key(path:path,sha:sha,size:size),StorageBackupRetentionIndex.referenceKey(path:path,sha:sha,size:size),path)
            }
        }
    }

    /// Scaled per-step timing: 20 receipts x 20,000 entries, 200 wanted objects.
    func testScaledCleanupBackupLookupTiming() throws {
        try QualificationSuite.requireEnabled()
        _ = try fixture(backed:false)
        func insert(_ range: Range<Int>) throws {
            for r in range {try insertCleanupReceipt(String(format:"p355-scaled-%03d",r),objects:((r * 1000)..<(r * 1000 + 20_000)).map {cleanupEntry("objects/p355s/\($0)",$0)},copy:"/tmp/p355-scaled-\(r)")}
        }
        try insert(0..<20)
        let wanted = stride(from:0,to:40_000,by:200).map {cleanupWanted("objects/p355s/\($0)",$0)}
        func time<T>(_ body: () throws -> T) rethrows -> (T,Double) {let start = Date();let value = try body();return (value,Date().timeIntervalSince(start))}
        let (reference,before) = try time {try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndexFullScan($0,objects:wanted)}}
        let rssBefore = Self.p355ResidentBytes()
        let (cold,coldSeconds) = try time {try cleanupLookup(wanted)}
        let rssGrowth = Int64(Self.p355ResidentBytes()) - Int64(rssBefore)
        XCTAssertEqual(cold.reads,20)
        let parsed = backupIndexCache.parsedReceiptCount
        var warm: [Double] = []
        for _ in 0..<5 {
            let (step,seconds) = try time {try cleanupLookup(wanted)}
            XCTAssertEqual(step.reads,0);warm.append(seconds)
            XCTAssertEqual(step.index.originals,reference.originals);XCTAssertEqual(step.index.copyPaths,reference.copyPaths);XCTAssertEqual(step.index.copyManifests,reference.copyManifests)
        }
        XCTAssertEqual(cold.index.originals,reference.originals);XCTAssertEqual(reference.originals.count,195,"receipts cover keys 0..<39,000")
        XCTAssertEqual(backupIndexCache.parsedReceiptCount,parsed)
        try insert(20..<21)
        let (added,addedSeconds) = try time {try cleanupLookup(wanted)}
        XCTAssertEqual(added.reads,1)
        let warmMax = warm.max() ?? 0
        print(String(format:"CL355_TIMING receipts=20 entries_per_receipt=20000 wanted=200 full_scan_per_step=%.3fs index_cold_first_step=%.3fs per_receipt_build=%.3fs rss_growth_mib=%.1f index_warm_per_step_max=%.4fs index_warm_per_step_mean=%.4fs one_added_receipt_step=%.3fs",before,coldSeconds,coldSeconds / 20,Double(rssGrowth) / 1_048_576,warmMax,warm.reduce(0,+) / Double(warm.count),addedSeconds))
        XCTAssertLessThan(warmMax,1.0)
        XCTAssertLessThan(warmMax,before)
    }
}
