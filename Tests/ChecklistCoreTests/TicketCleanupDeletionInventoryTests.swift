import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testDeletionBatchMatchesIndependentReceiptsForTheSameTicketInOneStream() throws {
        let (p,task,attachment) = try fixture(),pid = p["id"] as! String,tid = task["id"] as! String
        let owner = uuid(),fingerprint = uuid(),foreign = uuid(),hold = uuid(),capture = "source-captures/" + uuid() + "/source"
        let digest = String(repeating:"a",count:64),padding = String(repeating:"receipt-payload-",count:2048)
        let receipts: [JSON] = [
            ["id":uuid(),"task_id":tid,"owned_record_fingerprints":[fingerprint:"fingerprint"],"objects":[["owner_ids":[attachment["id"]!],"stored_path":attachment["path"]!]]],
            ["id":uuid(),"task_id":tid,"objects":[["owner_ids":[owner],"sha256":digest,"capture_path":capture]]]
        ]
        try write {db in
            try self.router.save(db,["id":foreign,"project_id":pid,"revision":1,"references":[fingerprint],"body":padding],type:"message")
            try self.router.save(db,["id":owner,"project_id":pid,"revision":1,"nested":[capture + "/file.txt":padding]],type:"message")
            try self.router.save(db,["id":hold,"project_id":pid,"revision":1,"kind":"reader","state":"active","digest":digest],type:"storage_hold")
        }
        var scans = 0
        try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("FROM records ORDER BY rowid") {scans += 1}}
            let batch = try self.router.ticketCleanupDeletionInventories(db,receipts:receipts)
            db.trace(nil)
            XCTAssertEqual(scans,1,"All deletion receipts share one complete validated stream")
            XCTAssertEqual(batch.inventories.count,2);XCTAssertTrue(batch.errors.isEmpty)
            for receipt in receipts {
                let actual = try XCTUnwrap(batch.inventories[receipt["id"] as! String]),single = try self.router.ticketCleanupInventory(db,receipt:receipt)
                XCTAssertEqual(actual.needles,single.needles);XCTAssertEqual(actual.holdDigests,single.holdDigests)
                XCTAssertEqual(actual.prefixes,single.prefixes);XCTAssertEqual(actual.tokens,single.tokens)
                XCTAssertEqual(actual.retainedBytes,single.retainedBytes)
                XCTAssertEqual(Set(actual.rows.map(\.id)),Set(single.rows.map(\.id)))
            }
            XCTAssertNotNil(batch.inventories[receipts[0]["id"] as! String]?.rows.first {$0.id == foreign})
            XCTAssertNil(batch.inventories[receipts[1]["id"] as! String]?.rows.first {$0.id == foreign})
            XCTAssertNotNil(batch.inventories[receipts[1]["id"] as! String]?.rows.first {$0.id == hold})
        }
    }

    func testDeletionBatchDeepAndOversizedReferencesRefuseOnlyTheirExactReceipt() throws {
        let (p,task,_) = try fixture(),tid = task["id"] as! String,target = uuid(),unaffected = uuid(),id = uuid()
        let first: JSON = ["id":uuid(),"task_id":tid,"objects":[["owner_ids":[target]]]]
        let second: JSON = ["id":uuid(),"task_id":tid,"objects":[["owner_ids":[unaffected]]]]
        for oversized in [false,true] {
            var nested: Any = target
            if !oversized {for _ in 0..<65 {nested = [nested]}}
            let payload: JSON = ["id":id,"project_id":p["id"]!,"revision":1,"body":String(repeating:"x",count:oversized ? TicketCleanupInventory.rowByteLimit+1 : 17_000),"nested":nested]
            try write {db in try self.router.save(db,payload,type:"message")}
            let batch = try router.readers!.read {try self.router.ticketCleanupDeletionInventories($0,receipts:[first,second])}
            XCTAssertEqual(batch.errors[first["id"] as! String]?.code,oversized ? "CLEANUP_INVENTORY_LIMIT" : "REFERENCE_GRAPH_LIMIT")
            XCTAssertNil(batch.inventories[first["id"] as! String])
            XCTAssertNil(batch.errors[second["id"] as! String]);XCTAssertNotNil(batch.inventories[second["id"] as! String])
        }
    }

    func testDeletionBatchValidatesUnrelatedPayloadAndCapsReceiptCount() throws {
        let (p,task,_) = try fixture(),receipt: JSON = ["id":uuid(),"task_id":task["id"]!,"objects":[]]
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupDeletionInventories($0,receipts:Array(repeating:receipt,count:33))}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"PURGE_LIMIT")
        }
        let id = uuid()
        var bytes = Data("{\"id\":\"\(id)\",\"project_id\":\"\(p["id"]!)\",\"revision\":1,\"body\":\"".utf8)
        bytes.append(Data(repeating:120,count:32768));bytes.append(0xff);bytes.append(Data("\"}".utf8))
        try write {db in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,CAST(? AS TEXT))",arguments:[id,p["id"] as! String,bytes])}
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupDeletionInventories($0,receipts:[receipt])}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")
        }
    }
}
