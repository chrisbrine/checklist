import ChecklistTestSupport
import XCTest
import GRDB
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
        let principals = ["p1", "p2", "42", "P1"]
        let ids = ["a", "b", "123", "A", "c"]
        let results = ["{\"data\":{\"x\":1}}", "{\"data\":{\"policy\":{}}}", "{\"_connection_registration\":{}}", "{", CommandRouter.prunedResult, "{\"data\":{\"policy\":null}}", "[]", "\"text\""]
        let jobShapes = [
            "{\"parent_command_id\":\"a\",\"parent_principal\":\"p1\"}", "{\"parent_command_id\":123,\"parent_principal\":\"p2\"}",
            "{\"parent_command_id\":\"123\",\"parent_principal\":42}", "{\"parent_command_id\":\"b\"}", "{\"parent_principal\":\"p1\"}",
            "{\"parent_command_id\":null,\"parent_principal\":\"p2\"}", "{\"parent_command_id\":{\"x\":1},\"parent_principal\":\"p1\"}",
            "{\"parent_command_id\":\"A\",\"parent_principal\":\"p1\"}", "{}", "[]",
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
        let stopped = try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0, stepBudget: 0) }
        XCTAssertEqual(stopped.commandResults, 0)
        XCTAssertGreaterThan(stopped.budgetStops, 0)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE result=?", arguments: [CommandRouter.prunedResult]) }, 0, "a stopped step rolls back")
        XCTAssertFalse(try router.dbQueue.writeWithoutTransaction { $0.isInsideTransaction })
        let marks = try router.dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='command_retention_marks'") } ?? ""
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(marks.utf8)) as? [[Double]])?.count, 2, "the retention mark is kept when the prune step stops")
        let done = try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0, stepBudget: 60) }
        XCTAssertEqual(done.commandResults, CommandRouter.pruneBatch)
        XCTAssertEqual(done.budgetStops, 0)
    }

    /// Live-store shape of 21 Nov 2026: 23,637 storage jobs. Prints both forms' times; the
    /// correlated form is timed on 5 candidates only, because 500 took minutes.
    func testCommandResultPruneAtLiveStorageJobCount() throws {
        try oldCommandFixture(commands: 2_000, jobs: 23_637)
        let started = Date()
        let counts = try router.dbQueue.writeWithoutTransaction { try router.pruneRoutineRecords($0, stepBudget: 60) }
        let linear = Date().timeIntervalSince(started)
        XCTAssertEqual(counts.commandResults, CommandRouter.pruneBatch)
        let oldStarted = Date()
        let five = try router.dbQueue.read { try Int64.fetchAll($0, sql: Self.correlatedCommandResultsSQL + " LIMIT 5", arguments: [Int64.max, CommandRouter.prunedResult]) }
        let correlatedFive = Date().timeIntervalSince(oldStarted)
        XCTAssertEqual(five.count, 5)
        print("PRUNE-TIMING linear_pass_500=\(String(format: "%.3f", linear))s correlated_5=\(String(format: "%.3f", correlatedFive))s correlated_500_estimate=\(String(format: "%.1f", correlatedFive * 100))s")
    }
}
