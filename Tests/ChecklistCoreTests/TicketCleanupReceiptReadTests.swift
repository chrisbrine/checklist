import ChecklistTestSupport
import XCTest
import GRDB
import CryptoKit
@testable import ChecklistCore

final class TicketCleanupReceiptReadTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var pid = ""
    private let owner = Caller(role:"owner",installation:"cleanup-read-test",projectIDs:[])
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-read-"+uuid())
        router = try TestStore.router(root:root)
        let created = try router.handle(method:"project_create",params:["name":"Synthetic receipt read","key_prefix":"RR","root_path":root.path,"command_id":uuid()],caller:owner)["data"] as! JSON
        pid = created["id"] as! String
    }
    override func tearDownWithError() throws {try router.closeStore();router = nil;try FileManager.default.removeItem(at:root)}
    private func save(_ value: JSON) throws {try router.dbQueue.write {try router.save($0,value,type:"storage_job")}}
    private func read(_ params: JSON = [:],caller: Caller? = nil) throws -> JSON {
        var p = params;if p["project_id"] == nil {p["project_id"] = pid}
        return try router.handle(method:"ticket_cleanup_receipts",params:p,caller:caller ?? owner)["data"] as! JSON
    }
    private func receipt(_ id: String = uuid(),items: [JSON]? = nil) throws -> String {
        let objects: [JSON] = [["state":"removed","size":42,"relative_path":"objects/a","sha256":String(repeating:"a",count:64)],
            ["state":"retained","size":17,"relative_path":"objects/b","reasons":["reader","shared"]],
            ["state":"already_missing","size":9],["state":"pending","size":11]]
        let linked = uuid()
        try save(["id":linked,"project_id":pid,"kind":"ticket_object_delete","state":"pending","revision":1,"objects":objects,"summary":CommandRouter.ticketObjectDeletionSummary(objects)])
        try save(["id":id,"project_id":pid,"kind":"ticket_object_delete","cause":"ticket_cleanup_pass","revision":1,"created_at":now(),"selected_bytes":79,
            "items":items ?? [["task_id":"a","action":"keep","reason":"open_ticket"],["task_id":"b","action":"keep","reason":"reader"],["task_id":"c","action":"done_evidence","reason":"done","byte_deletion_receipt_id":linked]],
            "source_build_cache":[["relative_path":"cache/a","size_unknown":true],["relative_path":"cache/b","size_unknown":true]]])
        return id
    }
    func testSummaryCountsCurrentByteFactsAndDurableBytesUnchanged() throws {
        let id = try receipt()
        let before = try router.dbQueue.read {try Row.fetchAll($0,sql:"SELECT rowid,data FROM records WHERE type='storage_job' ORDER BY rowid")}
        let page = try read(),value = try XCTUnwrap((page["receipts"] as? [JSON])?.first)
        XCTAssertNil(value["items"]);XCTAssertNil(value["source_build_cache"])
        XCTAssertEqual(value["item_count"] as? Int,3)
        XCTAssertEqual(value["action_counts"] as? [String:Int],["keep":2,"done_evidence":1])
        XCTAssertEqual(value["reason_counts"] as? [String:Int],["open_ticket":1,"reader":1,"done":1])
        let expanded = try router.dbQueue.read {try router.ticketCleanupPassProjection($0,receipt:router.record($0,id,type:"storage_job"))}
        XCTAssertEqual(try jsonString(value["summary"]!),try jsonString(expanded["summary"]!))
        XCTAssertEqual(value["bytes_state"] as? String,"pending")
        let after = try router.dbQueue.read {try Row.fetchAll($0,sql:"SELECT rowid,data FROM records WHERE type='storage_job' ORDER BY rowid")}
        XCTAssertEqual(before,after)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:page).count,256*1024)
    }
    func testAllItemsAndExactObjectsAndCacheEntriesPageWithoutGaps() throws {
        let id = try receipt()
        for (section,count) in [("items",3),("objects",4),("source_build_cache",2)] {
            var p: JSON = ["receipt_id":id,"section":section,"limit":1],values: [JSON] = []
            repeat {
                let page = try read(p);values += page[section] as! [JSON]
                p["cursor"] = page["next_cursor"] as? String
            } while p["cursor"] != nil
            XCTAssertEqual(values.count,count)
            if section == "objects" {
                XCTAssertEqual(values.compactMap {$0["object_index"] as? Int},[0,1,2,3])
                XCTAssertEqual((values.first?["object"] as? JSON)?["relative_path"] as? String,"objects/a")
            }
            if section == "items" {XCTAssertNil((values.last?["byte_deletion"] as? JSON)?["objects"])}
        }
    }
    func testLatestSummaryPagesRetainFirstReceiptAndAreBoundedWithLargeItems() throws {
        try QualificationSuite.requireEnabled()
        let large = (0..<250).map {["task_id":"t\($0)","action":"keep","reason":"open_ticket","summary":["detail":String(repeating:"x",count:2000)]] as JSON}
        for i in 0..<52 {_ = try receipt("pass-\(i)",items:large)}
        try router.dbQueue.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-first:"+pid,"pass-0"])}
        var p: JSON = ["limit":50],ids: [String] = []
        repeat {
            let start = ProcessInfo.processInfo.systemUptime,page = try read(p)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1)
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject:page).count,256*1024)
            XCTAssertEqual(page["first_pass_receipt_id"] as? String,"pass-0")
            ids += (page["receipts"] as! [JSON]).map {$0["id"] as! String}
            p["cursor"] = page["next_cursor"] as? String
        } while p["cursor"] != nil
        XCTAssertEqual(ids,(0..<52).reversed().map {"pass-\($0)"})
    }
    func testCursorsBindProjectReceiptSectionLimitPrincipalGrantAndExpire() throws {
        let id = try receipt(),otherID = try receipt()
        let page = try read(["receipt_id":id,"limit":1]),token = page["next_cursor"] as! String
        func reset(_ p: JSON,_ caller: Caller? = nil) {
            XCTAssertThrowsError(try read(p,caller:caller)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        }
        reset(["receipt_id":otherID,"limit":1,"cursor":token])
        reset(["receipt_id":id,"section":"objects","limit":1,"cursor":token])
        reset(["receipt_id":id,"limit":2,"cursor":token])
        reset(["receipt_id":id,"limit":1,"cursor":token],Caller(role:"owner",installation:"other",projectIDs:[]))
        reset(["receipt_id":id,"limit":1,"cursor":token],Caller(role:"owner",installation:owner.installation,projectIDs:[pid]))
        XCTAssertThrowsError(try read(["project_id":"foreign","receipt_id":id,"cursor":token]))
        // Re-seal the real cursor payload with an expired timestamp; all other
        // binding bytes stay exact, so this exercises route-level age refusal.
        var raw = String(token.dropFirst(SealedCursor.prefix.count)).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        while raw.count % 4 != 0 {raw += "="}
        var payload = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:Data(base64Encoded:raw)!),using:router.cursorKey)
        var old = (Date().timeIntervalSince1970-86401).bitPattern.bigEndian
        withUnsafeBytes(of:&old) {payload.replaceSubrange(9..<17,with:$0)}
        let expired = SealedCursor.prefix + (try ChaChaPoly.seal(payload,using:router.cursorKey).combined).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        reset(["receipt_id":id,"limit":1,"cursor":expired])
        try router.dbQueue.write {db in
            var value = try router.record(db,id,type:"storage_job");value["revision"] = 2;try router.save(db,value,type:"storage_job")
        }
        reset(["receipt_id":id,"limit":1,"cursor":token])
    }
    func testWorkerGrantGenerationAndLinkedOutcomeChangesFenceCursors() throws {
        let id = try receipt(),sid = uuid()
        try router.dbQueue.write {db in
            try router.save(db,["id":sid,"project_id":pid,"project_ids":[pid],"role":"worker","state":"connected","revision":1,"authorization_generation":"g1"],type:"session")
        }
        let worker = Caller(role:"worker",installation:"receipt-worker",projectIDs:[pid],sessionID:sid,workspace:root.path)
        let first = try read(["receipt_id":id,"limit":1],caller:worker),token = first["next_cursor"] as! String
        let params: JSON = ["receipt_id":id,"limit":1,"cursor":token]
        XCTAssertEqual((try read(params,caller:worker)["items"] as! [JSON]).first?["task_id"] as? String,"b")
        var revoked = worker;revoked.projectIDs = []
        XCTAssertThrowsError(try read(params,caller:revoked)) {XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")}
        try router.dbQueue.write {db in
            var session = try router.record(db,sid,type:"session");session["authorization_generation"] = "g2";session["revision"] = 2;try router.save(db,session,type:"session")
        }
        XCTAssertThrowsError(try read(params,caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        let current = try read(["receipt_id":id,"section":"objects","limit":1],caller:worker)
        let linked = ((current["objects"] as! [JSON]).first!)["byte_deletion_receipt_id"] as! String
        try router.dbQueue.write {db in
            var job = try router.record(db,linked,type:"storage_job"),objects = job["objects"] as! [JSON]
            objects[3]["state"] = "removed";job["objects"] = objects;job["revision"] = 2
            job["summary"] = CommandRouter.ticketObjectDeletionSummary(objects);try router.save(db,job,type:"storage_job")
        }
        XCTAssertThrowsError(try read(["receipt_id":id,"section":"objects","limit":1,"cursor":current["next_cursor"]!],caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
        let summary = try read(["receipt_id":id],caller:worker)
        XCTAssertEqual(((summary["summary"] as? JSON)?["removed_bytes"] as? NSNumber)?.int64Value,53)
        XCTAssertEqual(summary["bytes_state"] as? String,"completed")
        let listing = try read(["limit":1]);_ = try receipt()
        // The earlier list had one pass, so request two first to get a cursor.
        XCTAssertFalse(listing["has_more"] as! Bool)
        let page = try read(["limit":1]);_ = try receipt()
        XCTAssertThrowsError(try read(["limit":1,"cursor":page["next_cursor"]!])) {XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")}
    }

}
