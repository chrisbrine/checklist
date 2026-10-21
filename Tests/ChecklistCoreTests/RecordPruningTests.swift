import XCTest
import GRDB
@testable import ChecklistCore

/// CL-72: routine reads do not grow the store, old records are pruned under a documented
/// retention period, and read methods do not wait for the write lock.
extension CoreTests {
    func cursorRowCount() throws -> Int { try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cursors") ?? -1 } }

    func testNoMethodCreatesCursorRowsAndSealedCursorsStillWork() throws {
        let p = try project(), before = try cursorRowCount()
        for _ in 0..<5 {
            _ = try router.handle(method: "tool_catalog", params: [:], caller: owner)
            _ = try router.handle(method: "task_list", params: ["project_id": p["id"]!], caller: owner)
        }
        let created = try router.handle(method: "task_create", params: ["project_id": p["id"]!, "title": "Cursor check", "command_id": UUID().uuidString], caller: owner)
        XCTAssertEqual(try cursorRowCount(), before, "cursors are sealed, not stored")
        let token = try XCTUnwrap(created["event_cursor"] as? String)
        XCTAssertTrue(token.hasPrefix(SealedCursor.prefix))
        let unchanged = try call("changes_wait", ["cursor": token])
        XCTAssertEqual(unchanged["changed"] as? Bool, false)
        _ = try task(p, "Another")
        XCTAssertEqual(try call("changes_wait", ["cursor": token])["changed"] as? Bool, true)
    }

    func testSealedCursorRefusesOtherCallerTamperingAgeAndSurvivesRestart() throws {
        let p = try project()
        let token = try XCTUnwrap(try router.handle(method: "task_list", params: ["project_id": p["id"]!], caller: owner)["event_cursor"] as? String)
        let scope = try router.dbQueue.read { try router.authorizationScope($0, owner) }
        XCTAssertNoThrow(try router.dbQueue.read { db in _ = try router.cursorSequence(db, ["cursor": token], caller: owner, scope: scope) })
        let other = Caller(role: "owner", installation: "other-owner", projectIDs: [])
        assertCode("CURSOR_RESET") { _ = try self.router.dbQueue.read { db in try self.router.cursorSequence(db, ["cursor": token], caller: other, scope: scope) } }
        assertCode("CURSOR_RESET") { _ = try self.router.dbQueue.read { db in try self.router.cursorSequence(db, ["cursor": token], caller: self.owner, scope: scope + ":other") } }
        var altered = Array(token); altered[altered.count - 3] = altered[altered.count - 3] == "A" ? "B" : "A"
        assertCode("CURSOR_RESET") { _ = try self.router.dbQueue.read { db in try self.router.cursorSequence(db, ["cursor": String(altered)], caller: self.owner, scope: scope) } }
        let binding = SealedCursor.binding(principal: owner.principal, scope: scope, incarnation: router.incarnation)
        let old = try SealedCursor.seal(sequence: 3, created: Date().timeIntervalSince1970 - SealedCursor.maximumAge - 1, binding: binding, key: router.cursorKey)
        assertCode("CURSOR_RESET") { _ = try self.router.dbQueue.read { db in try self.router.cursorSequence(db, ["cursor": old], caller: self.owner, scope: scope) } }
        // The key lives in the store, so a service restart keeps open views valid.
        router = nil; router = try CommandRouter(root: directory)
        XCTAssertNoThrow(try router.dbQueue.read { db in _ = try router.cursorSequence(db, ["cursor": token], caller: owner, scope: scope) })
    }

    func testExpiredCursorRowsArePrunedAndThenReset() throws {
        let scope = try router.dbQueue.read { try router.authorizationScope($0, owner) }
        let now = Date().timeIntervalSince1970
        try router.dbQueue.write { db in
            for (token, age) in [("legacy-fresh-cursor-token", 60.0), ("legacy-expired-cursor-token", SealedCursor.maximumAge + 120)] {
                try db.execute(sql: "INSERT INTO cursors(token,principal,scope,sequence,incarnation,created_at) VALUES (?,?,?,?,?,?)", arguments: [token, owner.principal, scope, 0, router.incarnation, now - age])
            }
        }
        XCTAssertNoThrow(try router.dbQueue.read { db in _ = try router.cursorSequence(db, ["cursor": "legacy-fresh-cursor-token"], caller: owner, scope: scope) })
        let counts = try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0) }
        XCTAssertEqual(counts.cursors, 1)
        XCTAssertEqual(try router.dbQueue.read { try String.fetchAll($0, sql: "SELECT token FROM cursors") }, ["legacy-fresh-cursor-token"])
        assertCode("CURSOR_RESET") { _ = try self.router.dbQueue.read { db in try self.router.cursorSequence(db, ["cursor": "legacy-expired-cursor-token"], caller: self.owner, scope: scope) } }
    }

    func testOldCommandResultsAreTombstonedAndTheirReplayIsRefused() throws {
        let p = try project(), oldCommand = UUID().uuidString
        let old = try router.handle(method: "task_create", params: ["project_id": p["id"]!, "title": "Old command", "command_id": oldCommand], caller: owner)
        // Mark every current row as written 31 days ago.
        try router.dbQueue.write { db in
            let top = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM commands") ?? 0
            try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks',?)", arguments: [try jsonString([[Date().timeIntervalSince1970 - 31 * 86_400, Double(top)]])])
        }
        let recentCommand = UUID().uuidString
        _ = try router.handle(method: "task_create", params: ["project_id": p["id"]!, "title": "Recent command", "command_id": recentCommand], caller: owner)
        let counts = try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0) }
        XCTAssertGreaterThan(counts.commandResults, 0)
        assertCode("COMMAND_RESULT_EXPIRED") { _ = try self.router.handle(method: "task_create", params: ["project_id": p["id"]!, "title": "Old command", "command_id": oldCommand], caller: self.owner) }
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records WHERE type='task' AND json_extract(data,'$.title')='Old command'") }, 1, "an expired retry never runs twice")
        let replay = try router.handle(method: "task_create", params: ["project_id": p["id"]!, "title": "Recent command", "command_id": recentCommand], caller: owner)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        // The project_create result carries the policy that older attempts read back.
        let kept = try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE json_type(result,'$.data.policy') IS NOT NULL") ?? 0 }
        XCTAssertGreaterThan(kept, 0)
        XCTAssertNotNil(old["data"])
    }

    func testCleanupPreviewIsReusedAndStalePreviewsArePruned() throws {
        let p = try project(), t = try task(p), input: JSON = ["project_id": p["id"]!, "task_id": t["id"]!]
        func previews() throws -> Int { try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records WHERE type='cleanup_preview'") ?? -1 } }
        let first = try call("attachment_cleanup_preview", input), second = try call("attachment_cleanup_preview", input)
        XCTAssertEqual(first["cleanup_preview_id"] as? String, second["cleanup_preview_id"] as? String)
        XCTAssertEqual(try previews(), 1)
        _ = try call("task_edit", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!, "patch": ["title": "Renamed"]])
        _ = try call("attachment_cleanup_preview", input)
        XCTAssertEqual(try previews(), 2)
        XCTAssertEqual(try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0) }.cleanupPreviews, 1, "the preview of an older ticket revision is unusable")
        XCTAssertEqual(try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0, now: Date().addingTimeInterval(2 * 86_400)) }.cleanupPreviews, 1)
        XCTAssertEqual(try previews(), 0)
    }

    func testReadMethodsDoNotWaitForTheWriteLock() throws {
        let p = try project(), t = try task(p)
        XCTAssertNotNil(router.readers)
        let file = directory.appendingPathComponent("read-path-original.txt"); try Data("original bytes".utf8).write(to: file)
        let attachment = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": file.path])
        let cursor = try XCTUnwrap(try router.handle(method: "task_list", params: ["project_id": p["id"]!], caller: owner)["event_cursor"] as? String)
        let holding = expectation(description: "writer held"), release = DispatchSemaphore(value: 0), done = expectation(description: "writer released")
        DispatchQueue.global().async {
            try? ArchiveStorageGate.withExclusive(root: self.directory) { _ in
                try self.router.dbQueue.writeWithoutTransaction { _ in holding.fulfill(); _ = release.wait(timeout: .now() + 10) }
            }
            done.fulfill()
        }
        wait(for: [holding], timeout: 5)
        let start = Date()
        for method in ["task_list", "triage_list", "epic_list", "project_list"] {
            _ = try router.handle(method: method, params: method == "project_list" ? [:] : ["project_id": p["id"]!], caller: owner)
        }
        // Finding 2a41447f: attachment metadata and previews and changes_wait also read without the writer.
        for representation in ["metadata", "preview"] {
            _ = try router.handle(method: "attachment_read", params: ["project_id": p["id"]!, "attachment_id": attachment["id"]!, "representation": representation], caller: owner)
        }
        _ = try router.handle(method: "changes_wait", params: ["cursor": cursor], caller: owner)
        let elapsed = Date().timeIntervalSince(start)
        // An owner's original read issues a reader hold, so it falls back to the writer and waits.
        let fallback = expectation(description: "original read finished"), heldStart = Date()
        var fallbackSeconds = 0.0, holdID: String?
        DispatchQueue.global().async {
            let output = try? self.router.handle(method: "attachment_read", params: ["project_id": p["id"]!, "attachment_id": attachment["id"]!, "representation": "original"], caller: self.owner)
            fallbackSeconds = Date().timeIntervalSince(heldStart); holdID = (output?["data"] as? JSON)?["read_hold_id"] as? String
            fallback.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        release.signal(); wait(for: [done, fallback], timeout: 5)
        XCTAssertLessThan(elapsed, 1.0, "reads completed while the object gate and the writer were held")
        XCTAssertGreaterThanOrEqual(fallbackSeconds, 0.3, "the writing read waited for the writer")
        XCTAssertNotNil(holdID, "the fallback read still issued its reader hold")
    }

    func testSnapshotLoadsTagsGroupsAndRelationsOncePerCall() throws {
        let p = try project(), pid = p["id"] as! String
        let tag = try call("tag_create", ["project_id": pid, "name": "art"])
        var tasks: [JSON] = []
        for index in 0..<6 { tasks.append(try ready(p, try task(p, "Snapshot \(index)"))) }
        for (index, t) in tasks.enumerated() {
            let tagged = try call("task_edit", ["project_id": pid, "task_id": t["id"]!, "expected_revision": t["revision"]!, "patch": ["tag_ids": [tag["id"]!]]])
            if index > 0 { _ = try call("task_link", ["project_id": pid, "task_id": t["id"]!, "expected_revision": tagged["revision"]!, "target_task_id": tasks[index - 1]["id"]!, "relation": "depends_on", "action": "add"]) }
        }
        let triage = try call("triage_create", ["project_id": pid, "name": "Snapshot triage", "phase": "implementation"])
        _ = try call("group_membership", ["project_id": pid, "group_id": triage["id"]!, "task_id": tasks[0]["id"]!, "action": "add", "expected_revision": triage["revision"]!])
        var statements: [String] = []
        try router.dbQueue.read { db in
            db.trace(options: .statement) { event in if case .statement(let statement) = event { statements.append(statement.expandedSQL) } }
            _ = try router.snapshot(db, c: owner)
            db.trace(options: [], nil)
        }
        func loads(_ type: String) -> Int {
            let literal = "x'" + Data(type.utf8).map { String(format: "%02x", $0) }.joined() + "'"
            return statements.filter { ($0.contains("type = CAST(\(literal) AS TEXT)") || $0.contains("type = CAST('\(type)' AS TEXT)")) && !$0.contains("id = CAST") }.count
        }
        XCTAssertEqual(loads("tag"), 1, statements.filter { $0.contains("746167") }.joined(separator: "\n"))
        XCTAssertEqual(loads("group"), 1)
        XCTAssertEqual(loads("relation"), 1)
    }
}
