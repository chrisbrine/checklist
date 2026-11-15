import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class NativeClosureRedeliveryDifferentialTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!

    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification/r12-N/test-fixtures")
            .appendingPathComponent("native-redelivery-differential-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        router = try CommandRouter(root: root.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws {
        router.fixtureStoreStatement = nil
        try router.closeStore(); router = nil
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: trash.appendingPathComponent(root.lastPathComponent))
    }

    /// Independent pre-change driver, including the second save after queueing.
    private func legacyRedeliver(_ db: Database, session: JSON, closure: JSON) throws {
        let pid = try StoredRecord(closure, family: "native_closure").string("project_id")
        let sid = try StoredRecord(session, family: "session").string("id")
        let closedSID = try StoredRecord(closure, family: "native_closure").string("session_id")
        let generation = try StoredRecord(closure, family: "native_closure").string("old_authorization_generation")
        let notices = try Row.fetchAll(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns
            + " FROM records WHERE type='delivery' AND project_id=?"
            + " AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY"
            + " AND json_extract(data,'$.recipient_authorization_generation')=? COLLATE BINARY ORDER BY rowid",
            arguments: [pid, closedSID, generation])
            .map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "delivery").object }
            .filter { !["acknowledged", "addressed", "fenced", "quarantined"].contains($0["state"] as? String ?? "") && $0["owner_disconnect_ref"] == nil && $0["restore_incarnation"] == nil }
        for old in notices {
            let mid = try StoredRecord(old, family: "delivery").string("message_id")
            let message = try router.scoped(db, mid, pid, type: "message")
            guard !bool(message, "addressed") else { continue }
            if bool(message, "requires_action"),
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM records WHERE type='message' AND project_id=? AND id=? AND " + CommandRouter.unretractedDirectionSQL() + ")", arguments: [pid, mid]) != true { continue }
            if message["kind"] as? String == "work_health" && message["origin"] as? String == "system" { continue }
            let receipts = try legacyQueue(db, message: message, recipients: [["session_id": sid,
                "recipient_role": "resumed_conversation", "label": "Notice from this conversation's earlier process; its original delivery remains fenced."]])
            if var receipt = receipts.first(where: { $0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == router.sessionGeneration(session) }) {
                receipt["resumed_from_delivery_id"] = old["id"]
                receipt["resumed_native_closure_ref"] = closure["id"]
                try router.save(db, receipt, type: "delivery")
            }
        }
    }

    /// Kept separate from the optimized function so its default path cannot
    /// accidentally bless a regression in receipt selection or relay state.
    private func legacyQueue(_ db: Database, message: JSON, recipients: [JSON]) throws -> [JSON] {
        let pid = try StoredRecord(message, family: "message").string("project_id")
        let mid = try StoredRecord(message, family: "message").string("id")
        var deliveries = try Row.fetchAll(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns
            + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? COLLATE BINARY ORDER BY rowid",
            arguments: [pid, mid]).map { try GRDBRecordEnvelopeAdapter.decode($0).object }
        for recipient in recipients {
            let sid = try StoredRecord(recipient, family: "recipient").string("session_id")
            let session = try router.scoped(db, sid, pid, type: "session"), generation = router.sessionGeneration(session)
            if deliveries.contains(where: { $0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == generation }) { continue }
            var delivery: JSON = ["id": uuid(), "project_id": pid, "message_id": mid, "recipient_session_id": sid,
                "recipient_authorization_generation": generation, "recipient_role": recipient["recipient_role"] ?? "recipient",
                "recipient_display": recipient["display_name"] ?? session["label"] ?? "Worker", "state": "queued",
                "push_state": "unavailable", "push_reason": "Native push is unqualified; available on recipient MCP pickup.", "revision": 1, "created_at": now()]
            if let aid = recipient["attempt_id"] { delivery["recipient_attempt_id"] = aid }
            let priorReceipts = try deliveries.map { prior -> JSON in
                var prior = prior
                if prior["recipient_session_id"] as? String == sid, let closure = try router.deliveryNativeClosure(db, prior) {
                    prior["native_closure_ref"] = closure["id"]; prior["fenced_at"] = closure["observed_at"]
                }
                return prior
            }
            if let earlier = CommandRouter.earlierReceiptOfNote(priorReceipts, session: sid) {
                delivery["push_state"] = "relay_skipped"; delivery["relay_skipped_for_delivery_id"] = earlier["id"]
                delivery["push_reason"] = "The relay already wrote this note to this conversation, or the conversation received it. It stays available through Checklist pickup."
            }
            router.copyRoleLabel(recipient, into: &delivery)
            try router.save(db, delivery, type: "delivery"); deliveries.append(delivery)
        }
        return deliveries
    }

    private struct Snapshot: Equatable {
        let records: [Data]
        let error: Data?
        let writes: Int
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.records == rhs.records && lhs.error == rhs.error }
    }
    private func snapshot(_ db: Database, originals: Set<String>, start: Date, end: Date) throws -> [Data] {
        var fresh = 0
        return try Row.fetchAll(db, sql: "SELECT rowid," + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid").map { row in
            let storedID: String = row["id"]
            if originals.contains(storedID) {
                // Also retain malformed fixture bytes without asking the same
                // decoder whose failure is the differential outcome below.
                let project: Data? = row["_envelope_project_id_bytes"]
                return try JSONSerialization.data(withJSONObject: ["rowid": row["rowid"] as Int64,
                    "id": (row["_envelope_id_bytes"] as Data).base64EncodedString(),
                    "project": project?.base64EncodedString() as Any? ?? NSNull(),
                    "type": (row["_envelope_type_bytes"] as Data).base64EncodedString(),
                    "revision": row["revision"] as Int64,
                    "data": (row["_envelope_data_bytes"] as Data).base64EncodedString()], options: [.sortedKeys])
            }
            let envelope = try GRDBRecordEnvelopeAdapter.decode(row)
            var value = envelope.object, id = envelope.id
            XCTAssertEqual(envelope.type, "delivery")
            XCTAssertNotNil(UUID(uuidString: id))
            let created = try XCTUnwrap(value["created_at"] as? String)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let clock = try XCTUnwrap(formatter.date(from: created) ?? ISO8601DateFormatter().date(from: created))
            XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, start.timeIntervalSince1970 - 1)
            XCTAssertLessThanOrEqual(clock.timeIntervalSince1970, end.timeIntervalSince1970 + 1)
            id = "fresh-receipt-\(fresh)"; fresh += 1
            value["id"] = id; value["created_at"] = "fresh-clock"
            return try JSONSerialization.data(withJSONObject: ["rowid": row["rowid"] as Int64, "id": id,
                "project_id": envelope.projectID ?? "", "type": envelope.type, "revision": envelope.revision, "value": value], options: [.sortedKeys])
        }
    }

    private func run(_ db: Database, session: JSON, closure: JSON, originals: Set<String>, legacy: Bool,
                     directMessage: JSON? = nil, recipients: [JSON] = []) throws -> Snapshot {
        var writes = 0, records: [Data] = [], failure: Data?
        router.fixtureStoreStatement = { db, sql, arguments in
            if sql.hasPrefix("INSERT INTO records(") { writes += 1 }
            try db.cachedStatement(sql: sql).execute(arguments: arguments)
        }
        defer { router.fixtureStoreStatement = nil }
        let start = Date()
        do {
            try db.inSavepoint {
                if let directMessage {
                    if legacy { _ = try legacyQueue(db, message: directMessage, recipients: recipients) }
                    else { _ = try router.queueDirectionDeliveries(db, message: directMessage, recipients: recipients) }
                } else if legacy { try legacyRedeliver(db, session: session, closure: closure) }
                else { try router.redeliverNativeClosureNotices(db, session: session, closure: closure) }
                records = try snapshot(db, originals: originals, start: start, end: Date())
                return .rollback
            }
        } catch let error as CoreError {
            failure = try JSONSerialization.data(withJSONObject: error.dictionary, options: [.sortedKeys])
            records = try snapshot(db, originals: originals, start: start, end: Date())
        }
        return Snapshot(records: records, error: failure, writes: writes)
    }

    private func seed(_ db: Database, variant: Int, count: Int = 6, simple: Bool = false) throws -> (JSON, JSON, Set<String>) {
        let session: JSON = ["id": "session-main", "project_id": "project-main", "authorization_generation": "current",
            "label": "Synthetic recipient", "provider": "claude", "role": "worker", "state": "connected", "revision": 1]
        let closure: JSON = ["id": "closure-main", "project_id": "project-main", "session_id": "session-main",
            "old_authorization_generation": "old", "observed_at": "2026-11-14T12:00:30Z", "state": "released", "revision": 1]
        try router.save(db, session, type: "session"); try router.save(db, closure, type: "native_closure")
        let states = ["queued", "delivered", "acknowledged", "addressed", "fenced", "quarantined"]
        let pushes = ["unavailable", "transport_written", "provider_accepted", "uncertain", "held", "refused"]
        for index in 0..<count {
            let code = simple ? 0 : variant &* 17 &+ index &* 11
            let mid = "message-\(index)"
            var message: JSON = ["id": mid, "project_id": "project-main", "revision": 1, "body": "Synthetic note",
                "kind": "note", "origin": "human_ui", "requires_action": false, "created_at": "2026-11-14T12:00:00Z"]
            if !simple {
                if code % 13 == 0 { message["kind"] = "work_health"; message["origin"] = "system" }
                if code % 17 == 0 { message["addressed"] = true }
                if code % 19 == 0 { message["kind"] = "work_health"; message["origin"] = "worker" }
            }
            try router.save(db, message, type: "message")
            var old: JSON = ["id": "old-\(index)-0", "project_id": "project-main", "message_id": mid,
                "recipient_session_id": "session-main", "recipient_authorization_generation": "old",
                "recipient_role": "original_handler", "revision": 3, "state": states[code % states.count],
                "push_state": pushes[(code / 3) % pushes.count], "created_at": "2026-11-14T12:00:00Z"]
            if !simple {
                if code % 7 == 0 { old["updated_at"] = "2026-11-14T11:59:59Z" }
                if code % 11 == 0 { old["updated_at"] = "2026-11-14T12:00:01Z" }
                if code % 23 == 0 { old["host_status"] = "held" }
                if code % 29 == 0 { old["transport_receipt"] = ["route": "codex_app_queue"] }
                if code % 31 == 0 { old["owner_disconnect_ref"] = NSNull() }
                if code % 37 == 0 { old["restore_incarnation"] = "historical-incarnation" }
            }
            let existing = simple ? 0 : (variant + index) % 3
            for ordinal in 0..<existing {
                var current = old
                current["id"] = "current-\(index)-\(ordinal)"; current["recipient_authorization_generation"] = "current"
                current["recipient_role"] = "existing-role-\(ordinal)"; current["label"] = "Existing label"
                current["resumed_from_delivery_id"] = "earlier-lineage"; current["resumed_native_closure_ref"] = "earlier-closure"
                try router.save(db, current, type: "delivery")
            }
            try router.save(db, old, type: "delivery")
            if !simple && code % 5 == 0 {
                old["id"] = "old-\(index)-1"; old["state"] = "queued"
                old.removeValue(forKey: "owner_disconnect_ref"); old.removeValue(forKey: "restore_incarnation")
                try router.save(db, old, type: "delivery")
            }
            if !simple {
                var other = old
                other["id"] = "other-\(index)"; other["recipient_session_id"] = "other-session"
                other["recipient_authorization_generation"] = "current"
                try router.save(db, other, type: "delivery")
            }
        }
        return (session, closure, Set(try String.fetchAll(db, sql: "SELECT id FROM records")))
    }

    private func memoryDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql: SchemaMigrations.currentSQL)
        }
        return queue
    }

    func testGeneratedRedeliveryMatchesIndependentLegacyDriver() throws {
        let queue = try memoryDatabase(); defer { try? queue.close() }
        try queue.write { db in
            for variant in 0..<128 {
                try db.inSavepoint {
                    let (session, closure, originals) = try seed(db, variant: variant)
                    let old = try run(db, session: session, closure: closure, originals: originals, legacy: true)
                    let new = try run(db, session: session, closure: closure, originals: originals, legacy: false)
                    XCTAssertEqual(new, old, "generated variant \(variant)")
                    return .rollback
                }
            }
        }
    }

    func testFreshReceiptsAreSavedOnceWithIdenticalLineageAndOrder() throws {
        let queue = try memoryDatabase(); defer { try? queue.close() }
        try queue.write { db in
            let (session, closure, originals) = try seed(db, variant: 1, count: 150, simple: true)
            let old = try run(db, session: session, closure: closure, originals: originals, legacy: true)
            let new = try run(db, session: session, closure: closure, originals: originals, legacy: false)
            XCTAssertEqual(new, old)
            XCTAssertEqual(old.writes, 300)
            XCTAssertEqual(new.writes, 150)
        }
    }

    func testDefaultQueuePathAndCanonicalFailuresMatchLegacy() throws {
        let queue = try memoryDatabase(); defer { try? queue.close() }
        try queue.write { db in
            for variant in 0..<24 {
                try db.inSavepoint {
                    let (session, closure, originals) = try seed(db, variant: variant)
                    let message = try router.record(db, "message-0", type: "message")
                    let recipients: [JSON] = [["session_id": "session-main", "recipient_role": "handler",
                        "display_name": "Explicit display", "attempt_id": "attempt-fixture", "label": "Routing label", "triage_id": "triage-fixture"]]
                    XCTAssertEqual(try run(db, session: session, closure: closure, originals: originals, legacy: false, directMessage: message, recipients: recipients),
                        try run(db, session: session, closure: closure, originals: originals, legacy: true, directMessage: message, recipients: recipients))
                    return .rollback
                }
            }
            for malformedMessage in [false, true] {
                try db.inSavepoint {
                    let (session, closure, _) = try seed(db, variant: 1, count: 1, simple: true)
                    if malformedMessage {
                        try db.execute(sql: "UPDATE records SET data=? WHERE id='message-0'", arguments: ["{\"id\":42,\"project_id\":\"project-main\",\"revision\":1}"])
                    } else {
                        try db.execute(sql: "UPDATE records SET data=? WHERE id='old-0-0'", arguments: ["{\"id\":42,\"project_id\":\"project-main\",\"revision\":3,\"recipient_session_id\":\"session-main\",\"recipient_authorization_generation\":\"old\"}"])
                    }
                    let originals = Set(try String.fetchAll(db, sql: "SELECT id FROM records"))
                    let old = try run(db, session: session, closure: closure, originals: originals, legacy: true)
                    let new = try run(db, session: session, closure: closure, originals: originals, legacy: false)
                    XCTAssertNotNil(old.error); XCTAssertEqual(new, old)
                    return .rollback
                }
            }
        }
    }
}
