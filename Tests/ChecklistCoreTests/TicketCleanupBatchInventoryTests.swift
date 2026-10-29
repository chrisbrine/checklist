import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testBatchInventoryIgnoresLargeDeletionAccountingButPreservesUnknownJobReferences() throws {
        try QualificationSuite.requireEnabled()
        let (p,task,attachment) = try fixture(),pid = p["id"] as! String,tid = task["id"] as! String
        let ignored = (0..<5).map {_ in uuid()},unknown = [uuid(),uuid()]
        let padding = String(repeating:"x",count:3_900_000)
        XCTAssertGreaterThan(padding.utf8.count * ignored.count,TicketCleanupInventory.byteLimit)
        try write {db in
            for id in ignored {
                try self.router.save(db,["id":id,"project_id":pid,"task_id":tid,"revision":1,"kind":"ticket_object_delete","state":"completed","body":padding,"objects":[["stored_path":attachment["path"]!]]],type:"storage_job")
            }
            // These foreign jobs have no direct ticket ownership. Their nested
            // attachment reference must survive large-row SQL reference matching.
            for index in unknown.indices {
                var job: JSON = ["id":unknown[index],"project_id":pid,"revision":1,"body":String(repeating:"x",count:32768),"nested":["attachment":attachment["id"]!]]
                if index == 0 {job["kind"] = "future_job_kind"}
                try self.router.save(db,job,type:"storage_job")
            }
        }
        try router.readers!.read {db in
            let receipt: JSON = ["id":ignored[0],"project_id":pid,"task_id":tid,"objects":[["owner_ids":[attachment["id"]!],"stored_path":attachment["path"]!]]]
            let batch = try self.router.ticketCleanupInventories(db,tasks:[task])
            XCTAssertTrue(batch.errors.isEmpty)
            let inventories = [try self.router.ticketCleanupInventory(db,task:task),try self.router.ticketCleanupInventory(db,receipt:receipt),try XCTUnwrap(batch.inventories[tid])]
            for inventory in inventories {
                XCTAssertTrue(inventory.rows.allSatisfy {!ignored.contains($0.id)})
                for id in unknown {XCTAssertNotNil(inventory.rows.first {$0.id == id})}
                XCTAssertLessThan(inventory.retainedBytes,TicketCleanupInventory.byteLimit)
            }
            var observed = Set<String>()
            try self.router.streamTicketCleanupRows(db,needles:[Data(tid.utf8),Data((attachment["id"] as! String).utf8)]) {row,_ in
                if ignored.contains(row.id) {observed.insert(row.id);XCTAssertFalse(bool(row.value,"_cleanup_large_match"))}
                if unknown.contains(row.id) {XCTAssertTrue(bool(row.value,"_cleanup_large_match"))}
            }
            XCTAssertEqual(observed,Set(ignored))
        }
    }

    func testBatchInventoryIgnoredDeletionAccountingStillValidatesUTF8AndEscapedUnicode() throws {
        let (p,task,_) = try fixture(),pid = p["id"] as! String,tid = task["id"] as! String,id = uuid()
        let prefix = "{\"id\":\"\(id)\",\"project_id\":\"\(pid)\",\"task_id\":\"\(tid)\",\"revision\":1,\"kind\":\"ticket_object_delete\",\"body\":\"" + String(repeating:"x",count:32768)
        var invalidUTF8 = Data(prefix.utf8);invalidUTF8.append(0xff);invalidUTF8.append(Data("\"}".utf8))
        let invalidEscape = Data((prefix + "\",\"value\":\"\\ud800\"}").utf8)
        for bytes in [invalidUTF8,invalidEscape] {
            try write {db in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',1,CAST(? AS TEXT))",arguments:[id,pid,bytes])}
            for path in 0..<3 {
                XCTAssertThrowsError(try router.readers!.read {db in
                    if path == 0 {_ = try self.router.ticketCleanupInventories(db,tasks:[task])}
                    else if path == 1 {_ = try self.router.ticketCleanupInventory(db,task:task)}
                    else {_ = try self.router.ticketCleanupInventory(db,receipt:["id":id,"project_id":pid,"task_id":tid,"objects":[]])}
                }) {XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")}
            }
            try write {db in try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
        }
    }

    func testBatchInventoryMatchesIndividualInventoriesWithReverseChildrenAndForeignReferences() throws {
        let (p,first,a) = try fixture(),(otherProject,second,_) = try fixture(),pid = p["id"] as! String
        let parent = uuid(),child = uuid(),foreign = uuid(),crossProjectChild = uuid(),capture = uuid(),hold = uuid()
        let padding = String(repeating:"batch-payload-",count:2048),path = "source-captures/" + pid + "/" + capture + "/source"
        try write {db in
            // A physical child-before-parent order must not require a fresh
            // complete corpus validation for every ownership depth.
            try self.router.save(db,["id":child,"project_id":pid,"revision":1,"message_id":parent,"body":padding],type:"message")
            try self.router.save(db,["id":parent,"project_id":pid,"task_id":first["id"]!,"revision":1,"body":padding],type:"message")
            try self.router.save(db,["id":capture,"project_id":pid,"task_id":first["id"]!,"revision":1,"snapshot_path":path,"files":[]],type:"source_capture")
            try self.router.save(db,["id":foreign,"project_id":otherProject["id"]!,"task_id":second["id"]!,"revision":1,"nested":[path + "/retained.txt":padding],"attachment":a["id"]!],type:"message")
            try self.router.save(db,["id":crossProjectChild,"project_id":otherProject["id"]!,"revision":1,"message_id":parent,"body":padding],type:"message")
            try self.router.save(db,["id":hold,"project_id":otherProject["id"]!,"revision":1,"kind":"reader","state":"active","nested":[a["sha256"] as! String:padding]],type:"storage_hold")
        }
        try router.readers!.read {db in
            let batch = try self.router.ticketCleanupInventories(db,tasks:[first,second])
            XCTAssertTrue(batch.errors.isEmpty)
            for task in [first,second] {
                let tid = task["id"] as! String,single = try self.router.ticketCleanupInventory(db,task:task)
                let actual = try XCTUnwrap(batch.inventories[tid])
                XCTAssertEqual(Set(actual.rows.map(\.id)),Set(single.rows.map(\.id)))
                XCTAssertEqual(actual.needles,single.needles);XCTAssertEqual(actual.holdDigests,single.holdDigests)
                XCTAssertEqual(actual.prefixes,single.prefixes);XCTAssertEqual(actual.tokens,single.tokens)
                XCTAssertEqual(actual.retainedBytes,single.retainedBytes)
                for row in single.rows {XCTAssertEqual(try jsonString(actual.rows.first {$0.id == row.id}!.value),try jsonString(row.value))}
            }
            let selected = try XCTUnwrap(batch.inventories[first["id"] as! String])
            XCTAssertNotNil(selected.rows.first {$0.id == crossProjectChild},"A cross-project parent mention is a foreign reference, never ownership")
            XCTAssertNotNil(selected.rows.first {$0.id == hold})
        }
    }

    func testBatchInventoryOversizedOwnedTicketDoesNotRefuseOtherTicket() throws {
        try QualificationSuite.requireEnabled()
        let (p,large,_) = try fixture(),small = try call("task_create",["project_id":p["id"]!,"title":"Small selected ticket"])
        let id = uuid(),padding = String(repeating:"x",count:TicketCleanupInventory.rowByteLimit + 1)
        try write {db in try self.router.save(db,["id":id,"project_id":p["id"]!,"task_id":large["id"]!,"revision":1,"body":padding],type:"message")}
        let batch = try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[large,small])}
        XCTAssertEqual(batch.errors[large["id"] as! String]?.code,"CLEANUP_INVENTORY_LIMIT")
        XCTAssertNil(batch.inventories[large["id"] as! String])
        XCTAssertNotNil(batch.inventories[small["id"] as! String]);XCTAssertNil(batch.errors[small["id"] as! String])
    }

    func testBatchInventoryOversizedForeignReferenceRefusesOnlyItsTarget() throws {
        try QualificationSuite.requireEnabled()
        let (p,first,a) = try fixture(),second = try call("task_create",["project_id":p["id"]!,"title":"Unaffected selected ticket"])
        let id = uuid(),padding = String(repeating:"x",count:TicketCleanupInventory.rowByteLimit + 1)
        try write {db in try self.router.save(db,["id":id,"project_id":p["id"]!,"revision":1,"body":padding,"nested":["target":a["id"]!]],type:"message")}
        let batch = try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[first,second])}
        XCTAssertEqual(batch.errors[first["id"] as! String]?.code,"CLEANUP_INVENTORY_LIMIT")
        XCTAssertNotNil(batch.inventories[second["id"] as! String]);XCTAssertNil(batch.errors[second["id"] as! String])
    }

    func testBatchInventoryValidatesMalformedUnrelatedPayloadBeforeReturningAnyTicket() throws {
        let (p,first,_) = try fixture(),second = try call("task_create",["project_id":p["id"]!,"title":"Other selected ticket"]),id = uuid()
        var bytes = Data("{\"id\":\"\(id)\",\"project_id\":\"\(p["id"]!)\",\"revision\":1,\"body\":\"".utf8)
        bytes.append(Data(repeating:120,count:32768));bytes.append(0xff);bytes.append(Data("\"}".utf8))
        try write {db in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,CAST(? AS TEXT))",arguments:[id,p["id"] as! String,bytes])}
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[first,second])}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")
        }
    }

    func testBatchInventoryAdmitsThirtyTwoIndependentTickets() throws {
        try QualificationSuite.requireEnabled()
        let (p,first,_) = try fixture()
        var selected = [first]
        for index in 1..<32 {selected.append(try call("task_create",["project_id":p["id"]!,"title":"Batch selected \(index)"]))}
        var scans = 0
        let batch = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains("FROM records ORDER BY rowid") {scans += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupInventories(db,tasks:selected)
        }
        XCTAssertEqual(batch.inventories.count,32);XCTAssertTrue(batch.errors.isEmpty)
        XCTAssertEqual(scans,2,"A full batch shares two corpus streams, independent of the selected ticket count")
        selected.append(first)
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:selected)}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"PURGE_LIMIT")
        }
    }

    func testBatchInventoryOwnershipDepthRefusalIsPerTicket() throws {
        let (p,first,_) = try fixture(),second = try call("task_create",["project_id":p["id"]!,"title":"Unaffected selected ticket"])
        let ids = (0..<66).map {_ in uuid()}
        try write {db in
            for index in ids.indices.reversed() {
                var row: JSON = ["id":ids[index],"project_id":p["id"]!,"revision":1]
                if index == 0 {row["task_id"] = first["id"]!} else {row["message_id"] = ids[index-1]}
                try self.router.save(db,row,type:"message")
            }
        }
        let batch = try router.readers!.read {try self.router.ticketCleanupInventories($0,tasks:[first,second])}
        XCTAssertEqual(batch.errors[first["id"] as! String]?.code,"PURGE_LIMIT")
        XCTAssertNotNil(batch.inventories[second["id"] as! String]);XCTAssertNil(batch.errors[second["id"] as! String])
    }

    func testBatchInventoryOwnershipCyclesTerminateAndOtherTicketChildrenStayForeign() throws {
        let (p,first,_) = try fixture(),second = try call("task_create",["project_id":p["id"]!,"title":"Foreign child owner"])
        let root = uuid(),child = uuid(),leaf = uuid(),foreign = uuid(),unownedFirst = uuid(),unownedSecond = uuid()
        try write {db in
            try self.router.save(db,["id":leaf,"project_id":p["id"]!,"revision":1,"message_id":child],type:"message")
            try self.router.save(db,["id":child,"project_id":p["id"]!,"revision":1,"message_id":root],type:"message")
            try self.router.save(db,["id":root,"project_id":p["id"]!,"revision":1,"task_id":first["id"]!,"message_id":leaf],type:"message")
            try self.router.save(db,["id":foreign,"project_id":p["id"]!,"revision":1,"task_id":second["id"]!,"message_id":child],type:"message")
            try self.router.save(db,["id":unownedFirst,"project_id":p["id"]!,"revision":1,"message_id":unownedSecond],type:"message")
            try self.router.save(db,["id":unownedSecond,"project_id":p["id"]!,"revision":1,"message_id":unownedFirst],type:"message")
        }
        try router.readers!.read {db in
            let batch = try self.router.ticketCleanupInventories(db,tasks:[first,second])
            XCTAssertTrue(batch.errors.isEmpty)
            let actual = try XCTUnwrap(batch.inventories[first["id"] as! String]),single = try self.router.ticketCleanupInventory(db,task:first)
            XCTAssertEqual(actual.needles,single.needles);XCTAssertEqual(actual.tokens,single.tokens)
            for id in [root,child,leaf] {XCTAssertTrue(actual.needles.contains(Data(id.utf8)))}
            XCTAssertFalse(actual.needles.contains(Data(foreign.utf8)));XCTAssertNotNil(actual.rows.first {$0.id == foreign})
            XCTAssertNil(actual.rows.first {$0.id == unownedFirst || $0.id == unownedSecond})
        }
    }
}
