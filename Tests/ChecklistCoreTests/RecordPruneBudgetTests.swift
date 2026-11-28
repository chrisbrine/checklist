import ChecklistTestSupport
import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

/// 21 Nov 2026 outage: the 30-day command-result prune read every storage job again for each
/// candidate command (500 x 23,637 JSON reads) on the writer, inside a command's storage gate.
/// The service stopped answering for minutes. These cases keep the linear query equal to the
/// earlier correlated one and prove that a prune step stops at its time limit.
extension CoreTests {
    /// The earlier correlated form, kept here only as the reference for the differential case.
    static let correlatedCommandResultsSQL = """
        SELECT c.rowid FROM commands c WHERE c.rowid <= ? AND c.result <> ?
          AND CASE WHEN json_valid(c.result) THEN json_type(c.result,'$.data.policy') IS NULL AND json_type(c.result,'$._connection_registration') IS NULL ELSE 0 END
          AND NOT EXISTS (SELECT 1 FROM records r WHERE r.type='storage_job' AND CASE WHEN json_valid(r.data) THEN json_extract(r.data,'$.parent_command_id')=c.command_id AND json_extract(r.data,'$.parent_principal')=c.principal ELSE 1 END)
          ORDER BY c.rowid
        """

    private struct PruneLCG { var state: UInt64; mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

    private func replacePruneFixture(_ db: Database, commands: [(String, String, String)], jobs: [String]) throws {
        try db.execute(sql: "DELETE FROM commands")
        try db.execute(sql: "DELETE FROM records WHERE type='storage_job'")
        for (principal, command, result) in commands {
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,'d',?)", arguments: [principal, command, result])
        }
        for (index, data) in jobs.enumerated() {
            try db.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES (?,'project','storage_job',1,?)", arguments: ["prune-job-\(index)", data])
        }
    }

    private func prunable(_ sql: String) throws -> [Int64] {
        try router.dbQueue.read { try Int64.fetchAll($0, sql: sql, arguments: [Int64.max, CommandRouter.prunedResult]) }
    }

    func testCommandResultPruneMatchesTheCorrelatedForm() throws {
        let principals = ["p1", "p2", "42", "P1", "[1,2]"]
        let ids = ["a", "b", "123", "A", "c", "{\"x\":1}", "[3,4]"]
        let results = ["{\"data\":{\"x\":1}}", "{\"data\":{\"policy\":{}}}", "{\"_connection_registration\":{}}", "{", CommandRouter.prunedResult, "{\"data\":{\"policy\":null}}", "[]", "\"text\""]
        let jobShapes = [
            "{\"parent_command_id\":\"a\",\"parent_principal\":\"p1\"}", "{\"parent_command_id\":123,\"parent_principal\":\"p2\"}",
            "{\"parent_command_id\":\"123\",\"parent_principal\":42}", "{\"parent_command_id\":\"b\"}", "{\"parent_principal\":\"p1\"}",
            "{\"parent_command_id\":null,\"parent_principal\":\"p2\"}", "{\"parent_command_id\":{\"x\":1},\"parent_principal\":\"p1\"}",
            "{\"parent_command_id\":\"A\",\"parent_principal\":\"p1\"}",
            "{\"parent_command_id\":[3,4],\"parent_principal\":[1,2]}", "{}", "[]",
        ]
        var random = PruneLCG(state: 0x5EED_2111)
        var compared = 0, withInvalidJob = 0
        for scenario in 0..<60 {
            var commands: [(String, String, String)] = []
            for principal in principals { for id in ids where random.next(3) != 0 { commands.append((principal, id, results[random.next(results.count)])) } }
            var jobs = (0..<random.next(8)).map { _ in jobShapes[random.next(jobShapes.count)] }
            if scenario % 12 == 5 { jobs.append("{"); withInvalidJob += 1 }
            try router.dbQueue.write { try replacePruneFixture($0, commands: commands, jobs: jobs) }
            XCTAssertEqual(try prunable(CommandRouter.prunableCommandResultsSQL), try prunable(Self.correlatedCommandResultsSQL), "scenario \(scenario)")
            compared += commands.count
        }
        XCTAssertGreaterThan(compared, 500)
        XCTAssertEqual(withInvalidJob, 5)
    }

    func testPruneParentKeysUseStoredTextForJSONObjectsAndArrays() throws {
        try router.dbQueue.write { db in
            try replacePruneFixture(db, commands: [
                ("p1", "{\"x\":1}", "{\"data\":{}}"),
                ("[1,2]", "[3,4]", "{\"data\":{}}"),
                ("p1", "unprotected", "{\"data\":{}}")
            ], jobs: [
                "{\"parent_command_id\":{\"x\":1},\"parent_principal\":\"p1\"}",
                "{\"parent_command_id\":[3,4],\"parent_principal\":[1,2]}"
            ])
        }
        let reference = try prunable(Self.correlatedCommandResultsSQL)
        XCTAssertEqual(reference.count, 1)
        XCTAssertEqual(try prunable(CommandRouter.prunableCommandResultsSQL), reference)
    }

    func testCommandResultPruneReadsStorageJobsOncePerStatement() throws {
        func plan(_ sql: String) throws -> [String] {
            try router.dbQueue.read { db in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: [Int64.max, CommandRouter.prunedResult]).map { $0["detail"] as String } }
        }
        let current = try plan(CommandRouter.prunableCommandResultsSQL)
        XCTAssertFalse(current.contains { $0.contains("CORRELATED") }, current.joined(separator: "\n"))
        XCTAssertTrue(try plan(Self.correlatedCommandResultsSQL).contains { $0.contains("CORRELATED") }, "control: the earlier form reads storage jobs per candidate")
    }

    private func oldCommandFixture(commands: Int, jobs: Int) throws {
        try router.dbQueue.write { db in
            try replacePruneFixture(db,
                commands: (0..<commands).map { ("principal-\($0 % 7)", "command-\($0)", "{\"data\":{\"index\":\($0)}}") },
                jobs: (0..<jobs).map { "{\"parent_command_id\":\"job-parent-\($0)\",\"parent_principal\":\"principal-\($0 % 7)\",\"state\":\"succeeded\",\"phase\":\"done\",\"bytes\":\($0 * 17)}" })
            let top = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM commands") ?? 0
            try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES ('command_retention_marks',?)", arguments: [try jsonString([[Date().timeIntervalSince1970 - 31 * 86_400, Double(top)]])])
        }
    }

    func testPruneStepStopsAtTheTimeLimitAndKeepsNoChange() throws {
        try oldCommandFixture(commands: 3_000, jobs: 3_000)
        let stopped = try router.pruneRoutineRecords(stepBudget: 0)
        XCTAssertEqual(stopped.commandResults, 0)
        XCTAssertGreaterThan(stopped.budgetStops, 0)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE result=?", arguments: [CommandRouter.prunedResult]) }, 0, "a stopped step rolls back")
        XCTAssertFalse(try router.dbQueue.writeWithoutTransaction { $0.isInsideTransaction })
        let marks = try router.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'") } ?? ""
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(marks.utf8)) as? [[Double]])?.count, 2, "the retention mark is kept when the prune step stops")
        let done = try router.pruneRoutineRecords(stepBudget: 60)
        XCTAssertEqual(done.commandResults, CommandRouter.pruneBatch)
        XCTAssertEqual(done.budgetStops, 0)
    }

    func testRoutinePruneRetriesAPlanWithANewProtectedParent() throws {
        try oldCommandFixture(commands: 12, jobs: 3)
        let stopped = try router.pruneRoutineRecords(beforeCommandApply: {
            try self.router.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO records(id,project_id,type,revision,data) VALUES
                    ('late-job','project','storage_job',1,'{"parent_command_id":"command-0","parent_principal":"principal-0"}')
                    """)
            }
        })
        XCTAssertEqual(stopped.commandResults, 0)
        XCTAssertEqual(stopped.budgetStops, 1)
        XCTAssertEqual(try router.pruneRoutineRecords().commandResults, 11)
        XCTAssertNotEqual(try router.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT result FROM commands WHERE command_id='command-0'")
        }, CommandRouter.prunedResult)
    }

    func testRoutinePruneKeepsAnAgedPlanWhenARecentJobChanges() throws {
        try oldCommandFixture(commands: 12, jobs: 3)
        let turn = try router.pruneRoutineRecords(beforeCommandApply: {
            try self.router.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO commands(principal,command_id,digest,result) VALUES ('principal-0','recent','digest','{}');
                    INSERT INTO records(id,project_id,type,revision,data) VALUES
                    ('recent-job','project','storage_job',1,'{"parent_command_id":"recent","parent_principal":"principal-0"}');
                    UPDATE commands SET result='{"data":{}}' WHERE command_id='recent';
                    """)
            }
        })
        XCTAssertEqual(turn.commandResults, 12)
        XCTAssertEqual(turn.budgetStops, 0)
        XCTAssertEqual(try router.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT result FROM commands WHERE command_id='recent'")
        }, "{\"data\":{}}")
    }

    func testOrdinaryCommandLeavesPruneBacklogToMaintenance() throws {
        let p = try project()
        let input = try fixtureTaskInput(router, method: "task_create", input: [
            "project_id": p["id"]!, "title": "Ordinary write", "command_id": UUID().uuidString
        ])
        try oldCommandFixture(commands: 12, jobs: 3)
        _ = try router.handle(method: "task_create", params: input, caller: owner)
        XCTAssertEqual(try router.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE result=?", arguments: [CommandRouter.prunedResult])
        }, 0)
        XCTAssertEqual(try router.pruneRoutineRecords().commandResults, 12)
    }

    func testMaintenanceWriterDoesNotWaitAtSQLiteBeginImmediate() throws {
        let external = try DatabaseQueue(path: directory.appendingPathComponent("checklist.sqlite").path)
        try external.writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try router.withMaintenanceWriter(label: "fixture_begin_immediate") { db, deadline in
                    try deadline.transaction(db) {
                        XCTFail("a busy maintenance step must not begin a transaction")
                        return true
                    }
                }
                XCTAssertNil(result)
                let wall = ProcessInfo.processInfo.systemUptime - start
                XCTAssertLessThan(wall, 1)
                print("PRUNE-BEGIN wall_ms=\(wall * 1000)")
                return .rollback
            }
        }
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") }, 5_000)
    }

    /// Live-store shape of 21 Nov 2026. Compare both 500-row passes on the
    /// same shape, with the reference result selected before either writes.
    func testCommandResultPruneAtLiveStorageJobCount() throws {
        try oldCommandFixture(commands: 63_261, jobs: 23_637)
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func measured(_ name: String, from started: Date, cpu: Double) {
            var load = [Double](repeating: 0, count: 3)
            _ = getloadavg(&load, 3)
            print("PRUNE-TIMING \(name) utc=\(ISO8601DateFormatter().string(from: started)) load=\(load) wall_s=\(Date().timeIntervalSince(started)) cpu_s=\(cpuSeconds() - cpu)")
        }
        let oldStarted = Date(), oldCPU = cpuSeconds()
        let baseline = try router.dbQueue.read {
            try Int64.fetchAll($0, sql: Self.correlatedCommandResultsSQL + " LIMIT 500", arguments: [Int64.max, CommandRouter.prunedResult])
        }
        measured("correlated_control_500", from: oldStarted, cpu: oldCPU)
        XCTAssertEqual(baseline.count, 500)
        let started = Date(), cpu = cpuSeconds()
        let counts = try router.pruneRoutineRecords(stepBudget: 60)
        measured("current_pass_500", from: started, cpu: cpu)
        XCTAssertEqual(counts.commandResults, CommandRouter.pruneBatch)
        XCTAssertEqual(try router.dbQueue.read {
            try Int64.fetchAll($0, sql: "SELECT rowid FROM commands WHERE result=? ORDER BY rowid", arguments: [CommandRouter.prunedResult])
        }, baseline)
    }
}
