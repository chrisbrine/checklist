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
    func assertCleanupMembershipEquals(_ a: StorageBackupRetentionIndex,_ b: StorageBackupRetentionIndex,objects: [JSON],file: StaticString = #filePath,line: UInt = #line) {
        for object in objects {
            guard let path = object["relative_path"] as? String,let sha = object["sha256"] as? String,let size = (object["size"] as? NSNumber)?.int64Value else {continue}
            let key = StorageBackupRetentionIndex.key(path:path,sha:sha,size:size)
            XCTAssertEqual(a.containsOriginal(key),b.containsOriginal(key),"historical presence for " + path,file:file,line:line)
            XCTAssertEqual(a.hasIndependentCopy(key),b.hasIndependentCopy(key),"independent copy for " + path,file:file,line:line)
        }
    }
    func assertCleanupIndexEqualsFullScan(_ objects: [JSON],file: StaticString = #filePath,line: UInt = #line) {
        let new = Result {try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndex($0,objects:objects)}}
        let old = Result {try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndexFullScan($0,objects:objects)}}
        switch (new,old) {
        case (.success(let a),.success(let b)):
            assertCleanupMembershipEquals(a,b,objects:objects,file:file,line:line)
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
        try insertCleanupReceipt("p355-e",objects:[cleanupEntry("objects/p355/k1",1),cleanupEntry("objects/p355/k5",5)],copy:"/tmp/p355-copy-e",summaryManifest:String(repeating:"d",count:64))
        let wanted: [JSON] = [cleanupWanted("objects/p355/k1",1),cleanupWanted("objects/p355/k2",2),cleanupWanted("objects/p355/k3",3),cleanupWanted("objects/p355/k4",4),cleanupWanted("source-captures/p355/s1",5),
                              cleanupWanted("objects/p355/k5",5),["relative_path":real,"sha256":attachment["sha256"]!,"size":attachment["size"]!]]
        assertCleanupIndexEqualsFullScan(wanted);assertCleanupIndexEqualsFullScan([])
        let index = try cleanupLookup(wanted).index,k1 = StorageBackupRetentionIndex.key(path:"objects/p355/k1",sha:String(format:"%064x",1),size:1)
        XCTAssertTrue(index.containsOriginal(k1));XCTAssertTrue(index.hasIndependentCopy(k1))
        XCTAssertTrue(index.originals.isEmpty);XCTAssertTrue(index.copyPaths.isEmpty,"duplicate entries must not materialize candidate URLs")
        XCTAssertEqual(index.copyManifests["/tmp/p355-copy-a"],String(repeating:"c",count:64));XCTAssertNil(index.copyManifests["/tmp/p355-copy-e"])
        XCTAssertFalse(index.containsOriginal(StorageBackupRetentionIndex.key(path:"objects/p355/k4",sha:String(format:"%064x",4),size:4)))
        let k5 = StorageBackupRetentionIndex.key(path:"objects/p355/k5",sha:String(format:"%064x",5),size:5)
        XCTAssertTrue(index.containsOriginal(k5));XCTAssertFalse(index.hasIndependentCopy(k5),"a mismatched manifest is not independent")
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
        XCTAssertFalse(try cleanupLookup(wanted).index.hasIndependentCopy(StorageBackupRetentionIndex.key(path:"objects/p355/k2",sha:String(format:"%064x",2),size:2)))
    }

    func testBackupRetentionKeyFastPathMatchesJSONEncoding() {
        let paths = ["objects/p355/k1","objects/a b/c-d_e.f","source-captures/x/y","/abs/root/objects/z","objects/q\"uote","objects/back\\slash","objects/caf\u{e9}","objects/tab\tx","objects/del\u{7f}"]
        for path in paths {
            for (sha,size) in [(String(repeating:"a",count:64),Int64(0)),("sha/with/slash",Int64(-1)),("\u{1}",Int64.max)] {
                XCTAssertEqual(StorageBackupRetentionIndex.key(path:path,sha:sha,size:size),StorageBackupRetentionIndex.referenceKey(path:path,sha:sha,size:size),path)
            }
        }
    }

    /// CL-321: repeated completed backups must not multiply the memory retained
    /// for the same cleanup candidates. The installed failure had 23 receipts.
    func testCleanupBackupIndexBoundsRepeatedCopiesAcrossTwentyThreeReceipts() throws {
        try QualificationSuite.requireEnabled()
        _ = try fixture(backed:false)
        let count = 40_133
        let entries = (0..<count).map {cleanupEntry("objects/p321h-repeated/\($0)",$0)}
        try insertCleanupReceipt("p321h-repeated-00",objects:entries,copy:"/tmp/p321h-repeated-00")
        // Reuse one serialized fixture instead of constructing 23 dictionary
        // trees in the test. Each generation still has its own completed copy.
        try write {db in
            for receipt in 1..<23 {
                let suffix = String(format:"%02d",receipt)
                try db.execute(sql:"INSERT INTO metadata(key,value) SELECT ?,json_set(value,'$.summary.path',?) FROM metadata WHERE key=?",arguments:["backup-generation:p321h-repeated-" + suffix,"/tmp/p321h-repeated-" + suffix,"backup-generation:p321h-repeated-00"])
            }
        }
        let wanted = (0..<count).map {cleanupWanted("objects/p321h-repeated/\($0)",$0)}
        let index = try cleanupLookup(wanted).index
        XCTAssertLessThanOrEqual(index.cleanupRetainedBytes,TicketCleanupBatchInventory.byteLimit)
        XCTAssertTrue(index.originals.isEmpty);XCTAssertTrue(index.copyPaths.isEmpty)
        for n in [0,count / 2,count - 1] {
            let key = StorageBackupRetentionIndex.key(path:"objects/p321h-repeated/\(n)",sha:String(format:"%064x",n),size:Int64(n))
            XCTAssertTrue(index.containsOriginal(key));XCTAssertTrue(index.hasIndependentCopy(key))
        }
    }

    /// CL-321: a candidate list larger than the observation budget is streamed
    /// in bounded chunks; its total size must not reject every candidate.
    func testCleanupBackupIndexStreamsWantedSetBeyondMemoryBound() throws {
        _ = try fixture(backed:false)
        // Keep the fixture small in entry count while exceeding 64 MiB of the
        // former wanted-key/path/content accounting. Components remain short.
        let prefix = "objects/" + Array(repeating:String(repeating:"p",count:96),count:8).joined(separator:"/") + "/"
        try insertCleanupReceipt("p321h-long-paths",objects:[cleanupEntry(prefix + "0",1),cleanupEntry(prefix + "24999",1)],copy:"/tmp/p321h-long-paths")
        let wanted = (0..<25_000).map {cleanupWanted(prefix + String($0),1)}
        let index = try cleanupLookup(wanted).index
        XCTAssertLessThanOrEqual(index.cleanupRetainedBytes,TicketCleanupBatchInventory.byteLimit)
        XCTAssertTrue(index.originals.isEmpty);XCTAssertTrue(index.copyPaths.isEmpty)
        for n in [0,24_999] {
            let key = StorageBackupRetentionIndex.key(path:prefix + String(n),sha:String(format:"%064x",1),size:1)
            XCTAssertTrue(index.containsOriginal(key));XCTAssertTrue(index.hasIndependentCopy(key),"the last chunk must be observed too")
        }
    }

    func testCleanupBackupIndexFallsBackAcrossCorruptManifestAndMissingPayload() throws {
        let (_,_,attachment) = try fixture(backed:false)
        let relative = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let wanted: JSON = ["relative_path":relative,"kind":"file","sha256":attachment["sha256"]!,"size":attachment["size"]!]
        let entry: JSON = ["path":relative,"sha256":attachment["sha256"]!,"size":attachment["size"]!]
        let manifest = Data("completed-backup-template".utf8),manifestSHA = ChecklistCore.hash(manifest)
        let corrupt = router.root.appendingPathComponent("backups/00-p321h-corrupt"),missing = router.root.appendingPathComponent("backups/01-p321h-missing")
        for copy in [corrupt,missing] {try FileManager.default.createDirectory(at:copy,withIntermediateDirectories:true)}
        try StorageObjectFiles(root:corrupt).writeNew("manifest.json",bytes:Data("corrupt-manifest".utf8))
        try StorageObjectFiles(root:missing).writeNew("manifest.json",bytes:manifest)
        try insertCleanupReceipt("p321h-corrupt",objects:Array(repeating:entry,count:1024),copy:corrupt.path,manifest:manifestSHA)
        try insertCleanupReceipt("p321h-missing",objects:[entry],copy:missing.path,manifest:manifestSHA)
        try ticketCleanupBackupTemplate(router,objects:[wanted])
        let key = StorageBackupRetentionIndex.key(path:relative,sha:attachment["sha256"] as! String,size:(attachment["size"] as! NSNumber).int64Value)
        var index = try cleanupLookup([wanted]).index
        XCTAssertTrue(index.hasIndependentCopy(key));XCTAssertTrue(index.copyPaths.isEmpty)
        XCTAssertLessThan(index.cleanupRetainedBytes,1_048_576,"descriptor duplicates must not multiply observation memory")
        index.verifyCopy(for:wanted)
        let verified = try XCTUnwrap(index.verifiedCopies[key])
        XCTAssertEqual(index.verifiedCopies.count,1);XCTAssertTrue(verified.isCurrent())
        XCTAssertTrue(verified.files.root.lastPathComponent.hasPrefix("template-"))
        XCTAssertTrue(index.unavailableManifests.contains(corrupt.path))
        XCTAssertNotNil(index.verifiedManifests[missing.path],"a verified manifest does not imply that its missing payload is usable")
        XCTAssertEqual(verified.regular?.sha256,attachment["sha256"] as? String)
        XCTAssertEqual(verified.regular?.size,(attachment["size"] as! NSNumber).int64Value)
        try Data("changed backup payload".utf8).write(to:verified.files.root.appendingPathComponent(verified.path))
        XCTAssertFalse(verified.isCurrent(),"final deletion must reject a backup payload changed after verification")
    }

    func testCleanupBackupIndexKeepsImmutableSnapshotWhileCacheChanges() throws {
        _ = try fixture(backed:false)
        let first = cleanupWanted("objects/p321h-snapshot/first",1),second = cleanupWanted("objects/p321h-snapshot/second",2)
        let firstKey = StorageBackupRetentionIndex.key(path:"objects/p321h-snapshot/first",sha:String(format:"%064x",1),size:1)
        let secondKey = StorageBackupRetentionIndex.key(path:"objects/p321h-snapshot/second",sha:String(format:"%064x",2),size:2)
        try insertCleanupReceipt("p321h-snapshot-a",objects:[cleanupEntry("objects/p321h-snapshot/first",1)],copy:"/tmp/p321h-snapshot-a")
        let before = try cleanupLookup([first,second]).index
        try write {db in try db.execute(sql:"DELETE FROM metadata WHERE key='backup-generation:p321h-snapshot-a'")}
        try insertCleanupReceipt("p321h-snapshot-b",objects:[cleanupEntry("objects/p321h-snapshot/second",2)],copy:"/tmp/p321h-snapshot-b")
        let after = try cleanupLookup([first,second]).index
        XCTAssertTrue(before.containsOriginal(firstKey));XCTAssertTrue(before.hasIndependentCopy(firstKey))
        XCTAssertFalse(before.containsOriginal(secondKey));XCTAssertFalse(before.hasIndependentCopy(secondKey))
        XCTAssertFalse(after.containsOriginal(firstKey));XCTAssertFalse(after.hasIndependentCopy(firstKey))
        XCTAssertTrue(after.containsOriginal(secondKey));XCTAssertTrue(after.hasIndependentCopy(secondKey))
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
            assertCleanupMembershipEquals(step.index,reference,objects:wanted)
        }
        assertCleanupMembershipEquals(cold.index,reference,objects:wanted);XCTAssertEqual(reference.originals.count,195,"receipts cover keys 0..<39,000")
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
