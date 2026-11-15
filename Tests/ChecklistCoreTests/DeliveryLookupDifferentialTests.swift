import XCTest
import GRDB
@testable import ChecklistCore

final class DeliveryLookupDifferentialTests: XCTestCase {
    private var indexesSQL: String {SchemaMigrations.deliveryLookupIndexSQL}
    private var messageSQL: String {
        "SELECT rowid," + CommandRouter.canonicalRecordColumns
        + " FROM records WHERE type='delivery' AND project_id=?"
        + " AND json_extract(data,'$.message_id')=? COLLATE BINARY ORDER BY rowid"
    }
    private var nativeSQL: String {
        "SELECT rowid," + CommandRouter.canonicalRecordColumns
        + " FROM records WHERE type='delivery' AND project_id=?"
        + " AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY"
        + " AND json_extract(data,'$.recipient_authorization_generation')=? COLLATE BINARY ORDER BY rowid"
    }
    private struct Query {
        let sql: String
        let values: [String]
        let index: String
        var arguments: StatementArguments { StatementArguments(values) }
    }

    /// Snapshot both raw bytes/order and the existing canonical decoder outcome.
    /// Invalid retained rows must fail identically rather than disappear in SQL.
    private func snapshot(_ db: Database, _ query: Query) throws -> [Data] {
        let rows = try Row.fetchAll(db,sql:query.sql,arguments:query.arguments)
        var result: [Data] = []
        for row in rows {
            result.append(Data(String(row["rowid"] as Int64).utf8))
            result.append(row["_envelope_id_bytes"] as Data)
            result.append(row["_envelope_data_bytes"] as Data)
        }
        do {
            let values = try rows.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object}
            result.append(Data(("decoded:" + (try jsonString(values))).utf8))
        } catch let error as CoreError {
            result.append(Data(("error:" + (try jsonString(error.dictionary))).utf8))
        }
        return result
    }

    func testDeliveryIndexesPreserveGeneratedQueriesAndCanonicalFailures() throws {
        let queue = try DatabaseQueue()
        defer {try? queue.close()}
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:SchemaMigrations.currentSQL)
            let projects = ["project","project\0tail","é","e\u{301}","other"]
            let identities: [Any?] = [nil,NSNull(),42,"42","","selected","selected\0tail","é","e\u{301}"]
            let states = ["queued","acknowledged","addressed","fenced","quarantined","delivered"]
            var seed: UInt64 = 462
            func next(_ limit: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 32) % UInt64(limit))
            }
            for i in 0..<768 {
                let pid = projects[next(projects.count)],id = "delivery-\(i)"
                var value: JSON = ["id":id,"project_id":pid,"revision":1,"state":states[next(states.count)]]
                for key in ["message_id","recipient_session_id","recipient_authorization_generation"] {
                    if let identity = identities[next(identities.count)] {value[key] = identity}
                }
                if i % 13 == 0 {value["owner_disconnect_ref"] = NSNull()}
                if i % 17 == 0 {value["restore_incarnation"] = "retained"}
                // Canonical failures in selected records remain failures after indexing.
                if i % 19 == 0 {value["id"] = 42}
                let raw = try jsonString(value)
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),'delivery',1,CAST(? AS TEXT))",arguments:[Data(id.utf8),Data(pid.utf8),Data(raw.utf8)])
            }
            // The partial indexes must never evaluate JSON in other record families.
            try db.execute(sql:"INSERT INTO records VALUES ('other-family','project','message',1,'not JSON')")
            let selected = identities.compactMap {$0 as? String} + ["absent"]
            var queries: [Query] = []
            for pid in projects {
                for mid in selected {queries.append(Query(sql:messageSQL,values:[pid,mid],index:"records_delivery_message"))}
                for sid in selected {
                    for generation in selected {queries.append(Query(sql:nativeSQL,values:[pid,sid,generation],index:"records_delivery_recipient_generation"))}
                }
            }
            let before = try queries.map {try snapshot(db,$0)}
            let stored = try Data.fetchAll(db,sql:"SELECT CAST(data AS BLOB) FROM records ORDER BY rowid")
            try db.execute(sql:indexesSQL)
            for (query,expected) in zip(queries,before) {
                XCTAssertEqual(try snapshot(db,query),expected,"\(query.values)")
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + query.sql,arguments:query.arguments)
                    .map {$0["detail"] as String}.joined(separator:"\n")
                XCTAssertTrue(plan.contains(query.index),plan)
                XCTAssertTrue(plan.contains(query.index == "records_delivery_message"
                    ? "(project_id=? AND <expr>=?)" : "(project_id=? AND <expr>=? AND <expr>=?)"),plan)
                XCTAssertFalse(plan.contains("USE TEMP B-TREE"),plan)
            }
            XCTAssertEqual(try Data.fetchAll(db,sql:"SELECT CAST(data AS BLOB) FROM records ORDER BY rowid"),stored)
        }
    }

    func testPrefixRecipientLookupKeepsScopePlanAndGeneratedRowOrder() throws {
        let queue = try DatabaseQueue()
        defer {try? queue.close()}
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:SchemaMigrations.currentSQL)
            let projects = ["project","control"],sessions = ["session-z","session-a","session\0tail","é","e\u{301}"]
            let generations: [Any?] = [nil,NSNull(),"generation-z","generation-a",42,"generation-middle"]
            for i in 0..<192 {
                let pid = projects[i % projects.count],sid = sessions[(i / projects.count) % sessions.count]
                var value: JSON = ["id":"receipt-\(999-i)","project_id":pid,"revision":1,
                    "recipient_session_id":sid,"state":"queued"]
                if i % 7 != 0 {value["message_id"] = "message-\(30-i % 31)"}
                if let generation = generations[(i / 3) % generations.count] {value["recipient_authorization_generation"] = generation}
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),'delivery',1,CAST(? AS TEXT))",arguments:[Data((value["id"] as! String).utf8),Data(pid.utf8),Data((try jsonString(value)).utf8)])
            }
            // This is the owner-disconnect prefix lookup, including its lack of
            // ORDER BY. Indexing full generations must not change its row order.
            let sql = "SELECT rowid," + CommandRouter.canonicalRecordColumns
                + " FROM records WHERE type='delivery' AND project_id=?"
                + " AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY"
            let queries = projects.flatMap {pid in sessions.map {sid in Query(sql:sql,values:[pid,sid],index:"records_scope")}}
            let before = try queries.map {try snapshot(db,$0)}
            func assertScopePlans() throws {
                for query in queries {
                    let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + query.sql,arguments:query.arguments)
                        .map {$0["detail"] as String}.joined(separator:"\n")
                    XCTAssertTrue(plan.contains("records_scope (project_id=? AND type=?)"),plan)
                    XCTAssertFalse(plan.contains("records_delivery_"),plan)
                }
            }
            try assertScopePlans()
            try db.execute(sql:indexesSQL)
            try assertScopePlans()
            for (query,expected) in zip(queries,before) {
                XCTAssertEqual(try snapshot(db,query),expected,"\(query.values)")
            }
        }
    }

    func testDeliveryIndexesPreserveFirstReceiptAndNativeFilterOrder() throws {
        let queue = try DatabaseQueue()
        defer {try? queue.close()}
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:SchemaMigrations.currentSQL)
            for (i,state) in ["queued","delivered","acknowledged","queued","fenced","quarantined"].enumerated() {
                var value: JSON = ["id":"receipt-\(9-i)","project_id":"project","revision":1,"message_id":"message",
                    "recipient_session_id":"session","recipient_authorization_generation":"generation","state":state]
                if i == 3 {value["owner_disconnect_ref"] = NSNull()}
                try db.execute(sql:"INSERT INTO records VALUES (?,'project','delivery',1,?)",arguments:[value["id"] as! String,try jsonString(value)])
            }
            func selected() throws -> ([String],String?,[String]) {
                let message = try Row.fetchAll(db,sql:messageSQL,arguments:["project","message"])
                    .map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object}
                let native = try Row.fetchAll(db,sql:nativeSQL,arguments:["project","session","generation"])
                    .map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object}
                    .filter {!["acknowledged","addressed","fenced","quarantined"].contains($0["state"] as? String ?? "") && $0["owner_disconnect_ref"] == nil && $0["restore_incarnation"] == nil}
                return (message.map {$0["id"] as! String},CommandRouter.earlierReceiptOfNote(message,session:"session")?["id"] as? String,native.map {$0["id"] as! String})
            }
            let before = try selected()
            XCTAssertEqual(before.0,["receipt-9","receipt-8","receipt-7","receipt-6","receipt-5","receipt-4"])
            XCTAssertEqual(before.1,"receipt-8")
            XCTAssertEqual(before.2,["receipt-9","receipt-8"])
            try db.execute(sql:indexesSQL)
            let after = try selected()
            XCTAssertEqual(after.0,before.0);XCTAssertEqual(after.1,before.1);XCTAssertEqual(after.2,before.2)
        }
    }
}
