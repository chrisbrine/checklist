import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class TicketCleanupTokenObservationTests: XCTestCase {
    func testObservationPreservesByteExactKeysAndConservativeCanonicalPrefixes() throws {
        let composed = "caf\u{00e9}",decomposed = "cafe\u{0301}",digest = String(repeating:"a",count:64)
        let value: JSON = ["nested":[decomposed:[digest,"source-captures/" + decomposed + "/source/file.txt"]]]
        let observation = try TicketCleanupInventory.TokenObservation(value)
        XCTAssertTrue(observation.tokens.contains(Data(decomposed.utf8)))
        XCTAssertFalse(observation.tokens.contains(Data(composed.utf8)))
        var inventory = TicketCleanupInventory();inventory.needles = [Data(composed.utf8)]
        XCTAssertFalse(inventory.mentions(observation),"Canonically equivalent IDs are distinct byte identities")
        inventory.holdDigests = [Data(digest.utf8)]
        XCTAssertFalse(inventory.mentions(observation))
        XCTAssertTrue(inventory.mentions(observation,includeDigests:true),"Digest-only authority is limited to typed holds")
        inventory.prefixes = ["source-captures/" + composed + "/source"]
        XCTAssertTrue(inventory.mentions(observation),"Canonical prefix equivalence remains conservative")
        inventory.prefixes = ["source-captures/" + composed + "/sour"]
        XCTAssertFalse(inventory.mentions(observation),"A prefix must end at the slash separator")
    }

    func testEarlyMatchDoesNotSkipTraversalLimitsOrPartiallyAdmitRow() throws {
        var nested: Any = "target"
        for _ in 0..<66 {nested = [nested]}
        let value: JSON = ["match":"target","nested":nested]
        var inventory = TicketCleanupInventory();inventory.needles = [Data("target".utf8)]
        XCTAssertThrowsError(try inventory.mentions(value)) {XCTAssertEqual(($0 as? CoreError)?.code,"REFERENCE_GRAPH_LIMIT")}
        let row = PurgeRow(id:"too-deep",type:"message",project:"project",value:value)
        XCTAssertThrowsError(try inventory.add(row,bytes:100) {value}) {XCTAssertEqual(($0 as? CoreError)?.code,"REFERENCE_GRAPH_LIMIT")}
        XCTAssertTrue(inventory.rows.isEmpty);XCTAssertTrue(inventory.tokens.isEmpty);XCTAssertEqual(inventory.retainedBytes,0)
    }

    func testSharedObservationAdmissionRetainsByteRowAndCountLimits() throws {
        let value: JSON = ["body":"target"],observation = try TicketCleanupInventory.TokenObservation(value)
        func row(_ id: String) -> PurgeRow {PurgeRow(id:id,type:"message",project:"project",value:value)}
        var inventory = TicketCleanupInventory()
        XCTAssertThrowsError(try inventory.add(row("oversized"),bytes:TicketCleanupInventory.rowByteLimit+1,observation:observation)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
        for index in 0..<4 {try inventory.add(row("large-\(index)"),bytes:TicketCleanupInventory.rowByteLimit,observation:observation)}
        XCTAssertEqual(inventory.retainedBytes,TicketCleanupInventory.byteLimit)
        try inventory.add(row("large-0"),bytes:TicketCleanupInventory.rowByteLimit,observation:observation)
        XCTAssertEqual(inventory.rows.count,4,"Repeated admission neither charges nor traverses the row again")
        XCTAssertThrowsError(try inventory.add(row("over-budget"),bytes:1,observation:observation)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
        var many = TicketCleanupInventory()
        for index in 0..<4096 {try many.add(row("small-\(index)"),bytes:1,observation:observation)}
        XCTAssertThrowsError(try many.add(row("over-count"),bytes:1,observation:observation)) {XCTAssertEqual(($0 as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")}
        XCTAssertEqual(many.rows.count,4096)
    }
}

extension TicketLifecycleCleanupTests {
    func testBatchTokenObservationDeepForeignRowRefusesOnlyItsExactTarget() throws {
        let (p,first,attachment) = try fixture(),pid = p["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Unaffected deep-row observer"]),id = uuid()
        func deep(_ reference: String) -> Any {
            var value: Any = reference
            for _ in 0..<65 {value = [value]}
            return value
        }
        func payload(_ reference: String) -> JSON {
            ["id":id,"project_id":pid,"revision":1,"body":String(repeating:"x",count:17_000),"nested":deep(reference)]
        }
        try write {db in try self.router.save(db,payload("unrelated reference"),type:"message")}
        let unaffected = try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[first,second])}
        XCTAssertTrue(unaffected.errors.isEmpty)
        XCTAssertEqual(unaffected.inventories.count,2,"An unrelated full payload cannot globally exhaust the traversal bound")
        for task in [first,second] {
            XCTAssertNoThrow(try router.readers!.read {try self.router.ticketCleanupInventory($0,task:task)})
        }
        try write {db in try self.router.save(db,payload(attachment["id"] as! String),type:"message")}
        let referenced = try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[first,second])}
        XCTAssertEqual(referenced.errors[first["id"] as! String]?.code,"REFERENCE_GRAPH_LIMIT")
        XCTAssertNil(referenced.inventories[first["id"] as! String])
        XCTAssertNil(referenced.errors[second["id"] as! String])
        XCTAssertNotNil(referenced.inventories[second["id"] as! String],"Only the exact referenced ticket is refused")
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupInventory($0,task:first)}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"REFERENCE_GRAPH_LIMIT")
        }
        XCTAssertNoThrow(try router.readers!.read {try self.router.ticketCleanupInventory($0,task:second)})
    }

    func testFullPayloadStreamReadsBoundedBlobOnceAndPreservesMalformedRefusals() throws {
        let (p,task,_) = try fixture(),pid = p["id"] as! String,tid = task["id"] as! String,id = uuid()
        let padding = String(repeating:"payload-",count:25_600)
        let value: JSON = ["id":id,"project_id":pid,"task_id":tid,"revision":1,"body":padding,"nested":["reference":tid,"unicode":"cafe\u{0301}"]]
        try write {db in try self.router.save(db,value,type:"message")}
        var blobReads = 0,sliceReads = 0,actual: PurgeRow?
        let hex = Data(id.utf8).map {String(format:"%02x",$0)}.joined()
        try router.readers!.read {db in
            db.trace {event in
                guard case .statement(let statement) = event,statement.expandedSQL.lowercased().contains(hex) else {return}
                if statement.sql.hasPrefix("SELECT CAST(data AS BLOB) FROM records WHERE id=") {blobReads += 1}
                if statement.sql.hasPrefix("SELECT substr(CAST(data AS BLOB)") {sliceReads += 1}
            }
            defer {db.trace(nil)}
            try self.router.streamTicketCleanupRows(db,needles:[Data(tid.utf8)],fullPayloads:true) {row,size in
                guard row.id == id else {return}
                XCTAssertGreaterThan(size,200_000);XCTAssertLessThan(size,TicketCleanupInventory.rowByteLimit)
                actual = row
            }
        }
        XCTAssertEqual(blobReads,1,"A bounded large payload is read once for Foundation validation and full-row use")
        XCTAssertEqual(sliceReads,0,"Bounded payloads must not repeatedly copy the complete SQLite value for each slice")
        let row = try XCTUnwrap(actual)
        XCTAssertEqual(row.value["body"] as? String,padding)
        XCTAssertEqual(try TicketCleanupInventory.TokenObservation(row.value).tokens,try TicketCleanupInventory.TokenObservation(value).tokens)

        let prefix = "{\"id\":\"\(id)\",\"project_id\":\"\(pid)\",\"task_id\":\"\(tid)\",\"revision\":1,"
        let body = "\"body\":\"" + padding
        let duplicateHeader = Data((prefix + "\"id\":\"\(id)\"," + body + "\"}").utf8)
        var invalidUTF8 = Data((prefix + body).utf8);invalidUTF8.append(0xff);invalidUTF8.append(Data("\"}".utf8))
        let invalidEscape = Data((prefix + body + "\",\"invalid\":\"\\ud800\"}").utf8)
        for bytes in [duplicateHeader,invalidUTF8,invalidEscape] {
            try write {db in try db.execute(sql:"UPDATE records SET data=CAST(? AS TEXT) WHERE id=?",arguments:[bytes,id])}
            for fullPayloads in [false,true] {
                XCTAssertThrowsError(try router.readers!.read {db in
                    try self.router.streamTicketCleanupRows(db,needles:[Data(tid.utf8)],fullPayloads:fullPayloads) {_,_ in}
                }) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID","fullPayloads=\(fullPayloads)")}
            }
        }
    }

    func testBatchTokenObservationLoadsEachLargePayloadOnceAcrossSelectedTickets() throws {
        let (p,first,_) = try fixture(),pid = p["id"] as! String
        var selected = [first]
        for index in 0..<3 {selected.append(try call("task_create",["project_id":pid,"title":"Shared token observer \(index)"]))}
        let ids = selected.map {$0["id"] as! String},owned = uuid(),foreign = uuid(),digest = String(repeating:"a",count:64),hold = uuid()
        let padding = String(repeating:"payload-",count:4096)
        try write {db in
            try self.router.save(db,["id":owned,"project_id":pid,"task_id":ids[0],"revision":1,"body":padding,"references":ids,"digest":digest],type:"message")
            try self.router.save(db,["id":foreign,"project_id":pid,"revision":1,"body":padding,"references":ids],type:"message")
            try self.router.save(db,["id":hold,"project_id":pid,"revision":1,"kind":"reader","state":"active","digest":digest],type:"storage_hold")
        }
        var loads: [String:Int] = [:]
        let tracked = [owned,foreign],hex = Dictionary(uniqueKeysWithValues:tracked.map {($0,Data($0.utf8).map {String(format:"%02x",$0)}.joined())})
        let batch = try router.readers!.read {db in
            db.trace {event in
                guard case .statement(let statement) = event,statement.sql.hasPrefix("SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE id = CAST(") else {return}
                let expanded = statement.expandedSQL.lowercased()
                for id in tracked where expanded.contains(hex[id]!) {loads[id,default:0] += 1}
            }
            defer {db.trace(nil)}
            return try self.router.ticketCleanupInventories(db,tasks:selected)
        }
        XCTAssertTrue(batch.errors.isEmpty);XCTAssertEqual(batch.inventories.count,4)
        XCTAssertEqual(loads[owned],1,"Only the ownership pass loads this row separately; reference matching uses the full stream")
        XCTAssertEqual(loads[foreign,default:0],0,"The full stream supplies foreign payloads without a separate canonical reload")
        for tid in ids {
            let inventory = try XCTUnwrap(batch.inventories[tid])
            for id in tracked {
                let observed = try XCTUnwrap(inventory.rows.first {$0.id == id})
                XCTAssertEqual(observed.value["body"] as? String,padding,"Admission must retain the full row, not its projection")
                XCTAssertTrue(inventory.tokens[Data(id.utf8)]?.contains(Data(padding.utf8)) == true)
            }
        }
        let ownerInventory = try XCTUnwrap(batch.inventories[ids[0]])
        XCTAssertTrue(ownerInventory.holdDigests.contains(Data(digest.utf8)))
        XCTAssertNotNil(ownerInventory.rows.first {$0.id == hold},"Owned tokens still discover digest-only reader holds")
    }
}
