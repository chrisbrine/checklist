import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-307: media preparation reads only the records a command touches plus their
/// dependency closure. Temporary owned stores built from templates; never the live store.
final class MediaPreparationScaleTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()

    private func measure(_ f: Fixture,_ method: String,_ p: JSON) throws -> (records: Int,bytes: Int,seconds: TimeInterval,writes: [String]) {
        var p = p;p["project_id"] = f.project;p["command_id"] = uuid()
        let start = Date()
        let prepared = try XCTUnwrap(try f.router.prepareMediaCommand(method:method,params:p,caller:f.owner))
        defer { try? prepared.observer.close() }
        return (prepared.readRecords,prepared.readBytes,Date().timeIntervalSince(start),prepared.writes.map { String(decoding:$0.id,as:UTF8.self) })
    }
    private func envelope(_ f: Fixture,_ id: String) throws -> DecodedEnvelope {
        try f.router.dbQueue.read { db in
            try GRDBRecordEnvelopeAdapter.decode(try XCTUnwrap(try Row.fetchOne(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)])))
        }
    }

    func testLargeProjectPreparationReadsTouchedRecordsAndHoldsAtomicityReplayAndFencing() throws {
        let f = try Fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at:f.base) }
        let type = try f.type(checks.schema()),round = try f.round(type)
        _ = try f.item(round,title:"Before growth")
        let typeProbe: JSON = ["title":"Probe"],itemProbe: JSON = ["round_id":round["id"]!,"title":"Probe item","candidates":[["slots":[["slot_id":"text","text":"Probe"]]]]]
        let smallType = try measure(f,"media_type_create",typeProbe),smallItem = try measure(f,"media_item_create",itemProbe)
        // Grow the same project: 200,500 small media records plus 520 records of 2 MiB
        // (about 1.09 GiB of canonical payload). The former whole-project copy refused
        // at 100,000 records or 128 MiB.
        let seedStart = Date()
        try f.router.dbQueue.write { db in
            try db.execute(sql:"""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<200500)
            INSERT INTO records(id,project_id,type,revision,data) SELECT 'bulk-'||i,CAST(? AS TEXT),'media_candidate',1,
              '{"id":"bulk-'||i||'","project_id":"'||?||'","record_references":[]}' FROM n
            """,arguments:[Data(f.project.utf8),f.project])
            try db.execute(sql:"""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<520)
            INSERT INTO records(id,project_id,type,revision,data) SELECT 'large-'||i,CAST(? AS TEXT),'media_candidate',1,
              '{"id":"large-'||i||'","project_id":"'||?||'","record_references":[],"text":"'||hex(zeroblob(1048576))||'"}' FROM n
            """,arguments:[Data(f.project.utf8),f.project])
        }
        try f.router.dbQueue.writeWithoutTransaction { db in _ = try Row.fetchAll(db,sql:"PRAGMA wal_checkpoint(TRUNCATE)") }
        let (records,payload) = try f.router.dbQueue.read { db in
            (try Int.fetchOne(db,sql:"SELECT count(*) FROM records WHERE project_id=CAST(? AS TEXT)",arguments:[Data(f.project.utf8)])!,
             try Int.fetchOne(db,sql:"SELECT sum(length(CAST(data AS BLOB))) FROM records WHERE project_id=CAST(? AS TEXT)",arguments:[Data(f.project.utf8)])!)
        }
        XCTAssertGreaterThan(records,200_000);XCTAssertGreaterThan(payload,1 << 30)
        let largeType = try measure(f,"media_type_create",typeProbe),largeItem = try measure(f,"media_item_create",itemProbe)
        print("CL307_MEASUREMENT project_records=\(records) project_payload_bytes=\(payload) seed_seconds=\(Date().timeIntervalSince(seedStart))"
            + " type_create small=\(smallType.records)r/\(smallType.bytes)B/\(smallType.seconds)s large=\(largeType.records)r/\(largeType.bytes)B/\(largeType.seconds)s"
            + " item_create small=\(smallItem.records)r/\(smallItem.bytes)B/\(smallItem.seconds)s large=\(largeItem.records)r/\(largeItem.bytes)B/\(largeItem.seconds)s")
        // Same command, same reads: preparation follows the touched records, not project size.
        XCTAssertEqual(largeType.records,smallType.records);XCTAssertEqual(largeType.bytes,smallType.bytes)
        XCTAssertEqual(largeItem.records,smallItem.records);XCTAssertEqual(largeItem.bytes,smallItem.bytes)
        XCTAssertLessThan(largeItem.records,100);XCTAssertLessThan(largeItem.bytes,1 << 20)
        XCTAssertLessThan(largeType.seconds,max(2,smallType.seconds * 50));XCTAssertLessThan(largeItem.seconds,max(2,smallItem.seconds * 50))
        // A dependency outside the touched set: the item references its unchanged round,
        // which preparation resolves from the snapshot and does not rewrite.
        XCTAssertFalse(largeItem.writes.contains(round["id"] as! String))
        let item = try f.item(round,title:"After growth")
        XCTAssertEqual(try f.record(item["id"] as! String,"media_item")["round_id"] as? String,round["id"] as? String)
        let written = try envelope(f,item["id"] as! String)
        let referenced = try (written.object["record_references"] as! [JSON]).map { try envelope(f,$0["id"] as! String) }
        XCTAssertNoThrow(try MediaRecordRegistry.validate([written],dependencies:referenced))
        let missing = referenced.filter { $0.id != round["id"] as? String }
        XCTAssertThrowsError(try MediaRecordRegistry.validate([written],dependencies:missing)) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
        // Idempotent replay in the large project.
        let command = uuid()
        let first = try f.call("media_type_create",["title":"Replay"],command:command)
        let replay = try f.call("media_type_create",["title":"Replay"],command:command)
        XCTAssertEqual(replay["id"] as? String,first["id"] as? String);XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual(try f.rows("media_review_type").filter { $0["title"] as? String == "Replay" }.count,1)
        // A concurrent change outside the touched set fences the prepared command.
        let prepared = try XCTUnwrap(try f.router.prepareMediaCommand(method:"media_type_create",params:["project_id":f.project,"command_id":uuid(),"title":"Fenced"],caller:f.owner))
        defer { try? prepared.observer.close() }
        try f.router.dbQueue.write { db in try db.execute(sql:"UPDATE records SET revision=2 WHERE id='bulk-7'") }
        let before = try f.rows("media_review_type").count
        XCTAssertThrowsError(try f.router.dbQueue.write { db in try prepared.commit(db) }) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED") }
        XCTAssertEqual(try f.rows("media_review_type").count,before)
        // The durable store is unchanged by preparation alone (TEMP overlay only).
        XCTAssertTrue(try f.rows("media_review_type").allSatisfy { $0["title"] as? String != "Probe" })
    }

    func testRoundAndIntakeAcceptMoreThanOneThousandItems() throws {
        let f = try Fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at:f.base) }
        let type = try f.type(checks.schema()),round = try f.round(type)
        let start = Date()
        for index in 0..<1001 { _ = try f.item(round,title:"Item \(index)",texts:["Text \(index)"]) }
        let created = Date().timeIntervalSince(start)
        let counts = try f.call("media_item_counts",["round_id":round["id"]!])
        XCTAssertEqual(counts["total"] as? Int,1001)
        var cursor: String?,seen = Set<String>()
        repeat {
            var p: JSON = ["round_id":round["id"]!];p["cursor"] = cursor
            let page = try f.call("media_item_page",p)
            for row in page["rows"] as! [JSON] { seen.insert(row["id"] as! String) }
            cursor = page["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(seen.count,1001)
        let publishStart = Date()
        _ = try f.publish(round)
        let published = try f.get(round)
        XCTAssertEqual((published["items"] as! [JSON]).filter { $0["published_target"] is JSON }.count,1001)
        // A pasted TSV intake with more than 1,000 entries previews without an intake ceiling.
        let round2 = try f.round(type)
        let tsv = "text\n" + (0..<1001).map { "Line \($0)" }.joined(separator:"\n") + "\n"
        let intake = try f.call("media_intake_preview",["round_id":round2["id"]!,"tsv":tsv],as:f.worker)
        XCTAssertEqual((intake["rows"] as? [JSON])?.count,1001)
        print("CL307_ROUND_MEASUREMENT items=1001 create_seconds=\(created) publish_seconds=\(Date().timeIntervalSince(publishStart))")
    }
}
