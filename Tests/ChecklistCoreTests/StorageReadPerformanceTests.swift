import XCTest
import GRDB
@testable import ChecklistCore

/// Disposable stores under the physical owner cache root, never the working installation.
final class ReadPerformanceFixture {
    let directory: URL
    let router: CommandRouter
    let owner = Caller(role: "owner", installation: "read-performance", projectIDs: [])
    init(_ ticket: String) throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        directory = caches.appendingPathComponent("ChecklistQualification/\(ticket)/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        router = try CommandRouter(root: directory.appendingPathComponent("store"))
    }
    deinit { try? router.closeStore(); try? FileManager.default.removeItem(at: directory) }
    func call(_ method: String, _ input: JSON = [:]) throws -> JSON {
        var p = input
        if !CommandRouter.readMethods.contains(method) { p["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: p, caller: owner)["data"] as! JSON
    }
    func save(_ values: [(String, JSON)]) throws {
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                for (type, value) in values { try router.save(db, value, type: type) }
                return .commit
            }
        }
    }
}

final class StorageReadPerformanceTests: XCTestCase {
    func testRouterLookupPlansSearchPrimaryAndScopeIndexes() throws {
        let f = try ReadPerformanceFixture("CL-152"), r = f.router
        try f.save([("message", ["id": "ticket", "project_id": "project", "revision": 1])])
        try r.dbQueue.read { db in
            var queries: [String] = []
            db.trace { if case .statement(let statement) = $0 { queries.append(statement.expandedSQL) } }
            _ = try r.record(db, "ticket", type: "message")
            _ = try r.scoped(db, "ticket", "project", type: "message")
            _ = try r.records(db, type: "message", project: "project")
            db.trace(nil)
            XCTAssertEqual(queries.count, 3)
            for (i, sql) in queries.enumerated() {
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: "\n")
                XCTAssertTrue(plan.contains("SEARCH records"), plan)
                XCTAssertFalse(plan.contains("SCAN records"), plan)
                XCTAssertTrue(plan.contains(i == 2 ? "records_scope (project_id=? AND type=?)" : "sqlite_autoindex_records_1 (id=?)"), plan)
            }
        }
    }

    func testMediaLookupPlansSearchScopeAndCommandIndexes() throws {
        let f = try ReadPerformanceFixture("CL-152"), r = f.router
        try f.save([("media_item", ["id":"item", "project_id":"project\0suffix", "round_id":"round\0suffix", "revision":1, "record_references":[]])])
        try r.dbQueue.read { db in
            var queries: [String] = []
            db.trace { if case .statement(let statement) = $0 { queries.append(statement.expandedSQL) } }
            let envelopes = try MediaRecordRegistry.envelopes(db, project:"project\0suffix")
            let items = try r.mediaItems(db, round:["project_id":"project\0suffix", "id":"round\0suffix"])
            _ = try r.managedImportReceipt(db, principal:"missing", command:"missing", digest:"")
            db.trace(nil)
            XCTAssertEqual(envelopes.map(\.id), ["item"])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(queries.count, 3)
            for (i, sql) in queries.enumerated() {
                let plan = try Row.fetchAll(db, sql:"EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator:"\n")
                XCTAssertTrue(plan.contains(i == 2 ? "SEARCH commands USING INDEX sqlite_autoindex_commands_1 (principal=? AND command_id=?)" : "SEARCH records USING INDEX records_scope"), plan)
                XCTAssertFalse(plan.contains("SCAN records") || plan.contains("SCAN commands"), plan)
            }
            XCTAssertTrue(try MediaRecordRegistry.envelopes(db, project:"project").isEmpty)
            XCTAssertTrue(try r.mediaItems(db, round:["project_id":"project\0suffix", "id":"round"]).isEmpty)
            XCTAssertTrue(try r.mediaItems(db, round:["project_id":"project", "id":"round\0suffix"]).isEmpty)
        }
    }

    func testCleanupCursorAndExportReceiptPlansUseIdentityIndexes() throws {
        let f = try ReadPerformanceFixture("CL-152"), r = f.router
        try ArchiveStorageGate.withExclusive(root:r.root) { permit in
            try r.dbQueue.writeWithoutTransaction { db in
                var queries: [String] = []
                db.trace { if case .statement(let statement) = $0 { queries.append(statement.expandedSQL) } }
                try r.processArchiveCleanupJobs(db,permit:permit,nowMS:0)
                _ = try r.exportReceiptCommitted(db,export:ExportPublication(destination:f.directory,principal:"owner\0suffix",command:"command\0suffix",digest:"digest"))
                db.trace(nil)
                let lookups = queries.filter { $0.contains("SELECT j.id FROM records j") || $0.contains("SELECT digest FROM commands") }
                XCTAssertEqual(lookups.count,2)
                for sql in lookups {
                    let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator:"\n")
                    // The outer job enumeration is intentional; its cursor identity must search.
                    XCTAssertTrue(plan.contains(sql.contains("SELECT j.id") ? "SEARCH c USING INDEX sqlite_autoindex_records_1 (id=?)" : "SEARCH commands USING INDEX sqlite_autoindex_commands_1 (principal=? AND command_id=?)"),plan)
                    XCTAssertFalse(plan.contains("AUTOMATIC") || plan.contains("SCAN c ") || plan.contains("SCAN commands"),plan)
                }
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(CAST(? AS TEXT),CAST(? AS TEXT),'digest','{}')",arguments:[Data("owner\0suffix".utf8),Data("command\0suffix".utf8)])
                for (principal,command,expected) in [("owner\0suffix","command\0suffix",true),("owner","command\0suffix",false),("owner\0suffix","command",false)] {
                    XCTAssertEqual(try r.exportReceiptCommitted(db,export:ExportPublication(destination:f.directory,principal:principal,command:command,digest:"digest")),expected)
                }
            }
        }
    }

    func testCoreSourcesDoNotOverrideStorageIdentityCollation() throws {
        let sources = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ChecklistCore")
        // Match only stored identity columns, not JSON fields, derived values or ORDER BY.
        let column = #"(?<![\w.$'])\b(?:[A-Za-z_]\w*\.)?(?:id|project_id|principal|command_id)\b"#
        let operand = #"(?:CAST\([^)]*\)|\([^)]*\)|[\w.?:]+|'[^']*')"#
        let patterns = [column + #"\s+COLLATE\s+BINARY\s*(?:=|IS|IN)"#,
                        column + #"\s*(?:=|IS|IN)\s*"# + operand + #"\s+COLLATE\s+BINARY"#,
                        operand + #"\s+COLLATE\s+BINARY\s*=\s*"# + column]
        for url in try FileManager.default.contentsOfDirectory(at:sources,includingPropertiesForKeys:nil) where url.pathExtension == "swift" {
            let source = try String(contentsOf:url,encoding:.utf8)
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern:pattern,options:.caseInsensitive)
                XCTAssertNil(regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)),url.lastPathComponent + " overrides indexed identity collation")
            }
        }
    }

    func testIndexedIdentityRemainsLengthAndByteExact() throws {
        let f = try ReadPerformanceFixture("CL-152"), r = f.router
        let ids = ["key", "key\0", "key\0suffix", "é", "e\u{301}", "key�"]
        try f.save(ids.map { ("message", ["id": $0, "project_id": "project\0suffix", "revision": 1]) })
        try r.dbQueue.write { db in
            // Malformed UTF-8 must not alias a valid replacement character or a shorter ID.
            let malformed = Data([0x6b, 0x65, 0x79, 0xff])
            try db.execute(sql: "INSERT INTO records VALUES(CAST(? AS TEXT),'project','task',1,'{}')", arguments: [malformed])
            for id in ids {
                let value = try r.scoped(db, id, "project\0suffix", type: "message")
                XCTAssertEqual(Data((value["id"] as! String).utf8), Data(id.utf8))
                XCTAssertThrowsError(try r.scoped(db, id, "project", type: "message"))
            }
            for bytes in [malformed, Data("key�".utf8), Data("key".utf8)] {
                let found = try Data.fetchOne(db, sql: "SELECT CAST(id AS BLOB) FROM records WHERE id=CAST(? AS TEXT)", arguments: [bytes])
                XCTAssertEqual(found, bytes)
            }
            XCTAssertEqual(try r.records(db, type: "message", project: "project\0suffix").count, ids.count)
        }
    }

    func testDeliveryPassLookupTimingAtFiveThousandRecords() throws {
        let f = try ReadPerformanceFixture("CL-152"), r = f.router
        let pid = "project", sid = "recipient"
        var rows: [(String, JSON)] = [("session", ["id": sid, "project_id": pid, "revision": 1, "state": "revoked", "authorization_generation": "fixture"])]
        for i in 0..<1118 { rows.append(("delivery", ["id": "delivery-\(i)", "project_id": pid, "revision": 1, "state": "queued", "recipient_session_id": sid, "recipient_authorization_generation": "fixture"])) }
        for i in rows.count..<5000 { rows.append(("message", ["id": "padding-\(i)", "project_id": pid, "revision": 1])) }
        // Put the recipient after the retained history. A recipient in the first row
        // makes a table scan stop immediately and cannot expose growth in lookup cost.
        try f.save(Array(rows.dropFirst()) + [rows[0]])
        try r.dbQueue.read { db in
            // Use the identical decoder and query construction on both sides. Alternate
            // order and take the median so another helper's build cannot decide the result.
            func sample(binary: Bool) throws -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<1118 {
                    let collation = binary ? " COLLATE BINARY" : ""
                    let query = "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT)" + collation + " AND type=CAST(? AS TEXT)" + collation
                    let row = try XCTUnwrap(Row.fetchOne(db, sql: query, arguments: [Data(sid.utf8), Data("session".utf8)]))
                    _ = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: "session")
                }
                return ProcessInfo.processInfo.systemUptime - start
            }
            var legacy: [Double] = [], indexed: [Double] = []
            for round in 0..<3 {
                if round % 2 == 0 { legacy.append(try sample(binary: true)); indexed.append(try sample(binary: false)) }
                else { indexed.append(try sample(binary: false)); legacy.append(try sample(binary: true)) }
            }
            let before = legacy.sorted()[1], after = indexed.sorted()[1]
            let bridgeStart = ProcessInfo.processInfo.systemUptime
            let result = try r.bridge(db, [:], Caller(role: "owner", installation: "native-bridge", projectIDs: []), "delivery_pending")
            let bridge = ProcessInfo.processInfo.systemUptime - bridgeStart
            XCTAssertEqual((result["deliveries"] as? [JSON])?.count, 0)
            print("CL-152 5000 records / 1118 delivery lookups: legacy=\(before)s indexed=\(after)s delivery_pending=\(bridge)s")
            XCTAssertLessThan(after, before * 0.95)
        }
    }
}

final class ArchivePreviewPerformanceTests: XCTestCase {
    func testFourFourHundredFileCapturesKeepExactPreviewUnderOneSecond() throws {
        let f = try ReadPerformanceFixture("CL-150")
        let project = try f.call("project_create", ["name": "Archive fixture", "key_prefix": "AP"])
        let pid = project["id"] as! String
        let task = try f.call("task_create", ["project_id": pid, "title": "Four captured submissions"])
        let tid = task["id"] as! String
        var rows: [(String, JSON)] = []
        for capture in 0..<4 {
            let files: [JSON] = (0..<400).map { ["path": "Sources/fixture-\($0).swift", "kind": "file", "sha256": String(repeating: "a", count: 64), "size": 4096, "executable": false] }
            rows.append(("source_capture", ["id": "capture-\(capture)", "project_id": pid, "task_id": tid, "revision": 1, "files": files, "size": 400 * 4096]))
            rows.append(("manifest", ["id": "manifest-\(capture)", "project_id": pid, "task_id": tid, "revision": 1, "evidence": ["source_capture": ["id": "capture-\(capture)", "files": files]]]))
        }
        let mib = 1024 * 1024
        for (id, size, keep) in [("eligible", 30 * mib, false), ("small", 1024, false), ("held", 40 * mib, true)] {
            rows.append(("attachment", ["id": id, "project_id": pid, "task_id": tid, "revision": 1, "mode": "managed", "availability": "available", "size": size, "keep_original": keep, "sha256": String(repeating: "a", count: 64), "path": f.directory.appendingPathComponent("store/objects/\(id)").path]))
        }
        try f.save(rows)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try f.call("attachment_cleanup_preview", ["project_id": pid, "task_id": tid])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("CL-150 4 x 400 captured files: preview=\(elapsed)s clean=\(result["clean_bytes"]!) retained=\(result["retained_bytes"]!) held=\(result["held_bytes"]!)")
        XCTAssertEqual(int(result, "clean_bytes"), 30 * mib)
        XCTAssertEqual(int(result, "retained_bytes"), 40 * mib + 1024)
        XCTAssertEqual(int(result, "held_bytes"), 40 * mib)
        XCTAssertEqual(strings(result, "attachment_ids"), ["eligible"])
        let holds = try XCTUnwrap(result["holds"] as? [JSON])
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(strings(holds[0], "reasons"), ["keepOriginal"])
        XCTAssertLessThan(elapsed, 1)
        let again = try f.call("attachment_cleanup_preview", ["project_id": pid, "task_id": tid])
        XCTAssertEqual(try jsonString(result), try jsonString(again))
    }
}
