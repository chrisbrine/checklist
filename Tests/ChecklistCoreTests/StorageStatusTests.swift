import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

final class StorageStatusTests: XCTestCase {
    func testPreviewIncludesSourceAndCaptureTimeAndLabelsLegacyTimeUnknown() throws {
        let f = try StorageFixture(),project = try f.project();_ = try f.task(project)
        let destination = f.base.appendingPathComponent("backup")
        _ = try f.call("backup_create",["path":destination.path])
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:manifestURL))
        let preview = try f.call("restore_preview",["path":destination.path])["data"] as! JSON
        XCTAssertEqual(preview["source_root"] as? String,f.root.path)
        XCTAssertEqual(preview["captured_at"] as? String,manifest.capturedAt)
        XCTAssertNotNil(ISO8601DateFormatter().date(from:try XCTUnwrap(manifest.capturedAt)))
        XCTAssertNotNil(ISO8601DateFormatter().date(from:try XCTUnwrap(preview["verified_at"] as? String)))
        XCTAssertEqual((preview["record_families"] as? [String:Int])?["task"],1)
        var legacy = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! JSON
        legacy.removeValue(forKey:"capturedAt")
        try JSONSerialization.data(withJSONObject:legacy,options:.sortedKeys).write(to:manifestURL)
        let old = try f.call("restore_preview",["path":destination.path])["data"] as! JSON
        XCTAssertTrue(old["captured_at"] is NSNull)
        XCTAssertEqual(old["source_root"] as? String,f.root.path)
    }
    func testStatusRecordsVerifiedBackupAndRestoreRehearsalWithoutInventingPhysicalSavings() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let original = f.workspace.appendingPathComponent("original");try Data([1,2,3,4]).write(to:original)
        _ = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":original.path])
        let initial = try f.call("storage_status")["data"] as! JSON
        XCTAssertTrue(initial["last_verified_backup"] is NSNull)
        XCTAssertTrue((initial["retained_usage"] as! JSON)["logical_bytes_at_verification"] is NSNull)
        let source = f.base.appendingPathComponent("backup")
        let backup = try f.call("backup_create",["path":source.path])["data"] as! JSON
        let status = try f.call("storage_status")["data"] as! JSON
        XCTAssertEqual((status["managed_bytes"] as? NSNumber)?.int64Value,4)
        let last = status["last_verified_backup"] as! JSON,usage = last["usage"] as! JSON
        XCTAssertEqual(last["path"] as? String,source.path)
        XCTAssertEqual(last["manifest_sha256"] as? String,backup["manifest_sha256"] as? String)
        XCTAssertNotNil(last["verified_at"] as? String)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:source.appendingPathComponent("manifest.json")))
        let expected = manifest.databaseSize + manifest.objects.reduce(0) {$0 + $1.size} + Int64(try Data(contentsOf:source.appendingPathComponent("manifest.json")).count) + Int64(try Data(contentsOf:source.appendingPathComponent("intent.json")).count)
        XCTAssertEqual((usage["logical_bytes"] as? NSNumber)?.int64Value,expected)
        XCTAssertGreaterThan((usage["allocated_file_bytes"] as! NSNumber).int64Value,0)
        XCTAssertTrue(usage["exclusive_physical_bytes"] is NSNull)
        XCTAssertTrue(usage["physical_reclaimable_bytes"] is NSNull)
        let preview = try f.call("restore_preview",["path":source.path])["data"] as! JSON
        let copy = try f.call("restore_create",["path":source.path,"manifest_sha256":preview["manifest_sha256"]!])["data"] as! JSON
        try f.reopen()
        let reopened = try f.call("storage_status")["data"] as! JSON
        let rehearsal = reopened["last_verified_rehearsal"] as! JSON
        XCTAssertEqual(rehearsal["path"] as? String,copy["path"] as? String)
        XCTAssertEqual(rehearsal["verification"] as? String,"copy_integrity_and_authority_fencing")
        XCTAssertEqual(rehearsal["native_startup_verified"] as? Bool,false)
        XCTAssertEqual((reopened["retained_usage"] as! JSON)["observed_copy_count"] as? Int,2)
        let previous = try jsonString(rehearsal)
        try Data([0]).write(to:source.appendingPathComponent("database.sqlite"))
        XCTAssertThrowsError(try f.call("restore_create",["path":source.path,"manifest_sha256":preview["manifest_sha256"]!]))
        XCTAssertEqual(try jsonString((try f.call("storage_status")["data"] as! JSON)["last_verified_rehearsal"] as! JSON),previous)
    }
    func testAllocationUsesObservedBlocksAndCountsHardLinkedInodeOnce() throws {
        let f = try StorageFixture(),files = try StorageObjectFiles(root:f.base)
        let first = f.base.appendingPathComponent("sparse"),second = f.base.appendingPathComponent("linked")
        XCTAssertTrue(FileManager.default.createFile(atPath:first.path,contents:nil))
        let fd = Darwin.open(first.path,O_WRONLY);XCTAssertGreaterThanOrEqual(fd,0)
        XCTAssertEqual(ftruncate(fd,4*1024*1024),0);Darwin.close(fd)
        try FileManager.default.linkItem(at:first,to:second)
        var info = stat();XCTAssertEqual(lstat(first.path,&info),0)
        let result = try StorageCopyUsage.measure(files,paths:["sparse","linked"],budget:.production())
        XCTAssertEqual((result["logical_bytes"] as! NSNumber).int64Value,Int64(info.st_size)*2)
        XCTAssertEqual((result["allocated_file_bytes"] as! NSNumber).int64Value,Int64(info.st_blocks)*512)
        XCTAssertTrue(result["physical_reclaimable_bytes"] is NSNull)
    }
    func testLegacyReceiptKeepsKnownVerificationTimeAndUnmeasuredUsageExplicit() throws {
        let f = try StorageFixture(),id = uuid(),time = "2026-10-23T16:24:00Z"
        try f.router!.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + id,try jsonString(["state":"complete","operation_id":id,"known_at":time,"manifest_sha256":String(repeating:"a",count:64),"objects":[]])])
        }
        let status = try f.call("storage_status")["data"] as! JSON
        XCTAssertEqual((status["last_verified_backup"] as! JSON)["verified_at"] as? String,time)
        let usage = status["retained_usage"] as! JSON
        XCTAssertEqual(usage["unmeasured_backup_count"] as? Int,1)
        XCTAssertTrue(usage["allocated_file_bytes_at_verification"] is NSNull)
        XCTAssertEqual(usage["availability"] as? String,"not_rechecked")
    }
    /// CL-343: the legacy fallback checks the newest receipt first, one row at a time,
    /// and gives the same reply as the old query that validated every receipt.
    func testLegacyFallbackPicksNewestCompleteReceiptWithoutValidatingEveryReceipt() throws {
        let f = try StorageFixture()
        func insert(_ r: Int,_ value: String) throws {
            try f.router!.dbQueue.write {db in try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + String(format:"00000000-0000-0000-0000-%012d",r),value])}
        }
        func receipt(_ r: Int,state: String) throws -> String {
            try jsonString(["state":state,"operation_id":"op-\(r)","known_at":String(format:"2026-10-23T16:%02d:00Z",r),"manifest_sha256":String(repeating:"\(r)",count:64),"objects":(0..<200).map {["path":"objects/x/\($0)","sha256":"s","size":$0]}])
        }
        try insert(1,receipt(1,state:"complete"));try insert(2,receipt(2,state:"complete"))
        try insert(3,receipt(3,state:"pending"));try insert(4,"{not json")
        let old = try f.router!.dbQueue.read {db in try String.fetchOne(db,sql:"SELECT json_object('kind','backup','operation_id',json_extract(value,'$.operation_id'),'verified_at',json_extract(value,'$.known_at'),'manifest_sha256',json_extract(value,'$.manifest_sha256'),'usage',NULL,'verification','legacy_complete_receipt') FROM metadata WHERE key GLOB 'backup-generation:*' AND json_valid(value) AND json_extract(value,'$.state')='complete' ORDER BY json_extract(value,'$.known_at') DESC,key DESC LIMIT 1")}
        let last = try XCTUnwrap((try f.call("storage_status")["data"] as! JSON)["last_verified_backup"] as? JSON)
        XCTAssertEqual(last as NSDictionary,jsonObject(try XCTUnwrap(old)) as NSDictionary)
        XCTAssertEqual(last["operation_id"] as? String,"op-2");XCTAssertEqual(last["verified_at"] as? String,"2026-10-23T16:02:00Z")
    }
}
