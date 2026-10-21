import XCTest
@testable import ChecklistCore

final class DiagnosticsTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "diagnostics-owner", projectIDs: [])
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        router = try CommandRouter(root: directory)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: directory) }
    func call(_ method: String,_ params: JSON = [:], caller: Caller? = nil) throws -> JSON {
        var params = params
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = uuid() }
        return try router.handle(method: method, params: params, caller: caller ?? owner)["data"] as! JSON
    }

    func testOwnerSummaryCountsRecordsWithoutPrivateDataOrDynamicLabels() throws {
        let secrets = ["private-note-body", "private-file-content", "/Users/PrivateOwner/Work/Secret", "private-claim-token", "private-session-secret", "private-routing-socket"]
        try router.dbQueue.write { db in
            try router.save(db, ["id": "private-task-id", "project_id": "private-project-id", "title": secrets[0], "brief": secrets[1], "root_path": secrets[2], "claim_token": secrets[3], "session_id": secrets[4], "native_endpoint": secrets[5], "revision": 1], type: "task")
            try router.save(db, ["id": "private-message-id", "body": secrets[0], "revision": 1], type: "message")
            try router.save(db, ["id": "unknown-private-id", "revision": 1], type: secrets[2])
        }
        let summary = try call("diagnostics_summary")
        let counts = summary["record_counts"] as! [String: Int]
        XCTAssertEqual(counts["task"], 1); XCTAssertEqual(counts["message"], 1); XCTAssertEqual(counts["other"], 1)
        XCTAssertNil(counts[secrets[2]])
        XCTAssertEqual((summary["service"] as! JSON)["state"] as? String, "responsive")
        let bytes = try jsonString(summary)
        for secret in secrets + ["private-task-id", "private-project-id", "private-message-id", directory.path] { XCTAssertFalse(bytes.contains(secret)) }
        XCTAssertEqual(Set(summary.keys), ["schema_version", "observed_at", "service", "record_counts"])
    }

    func testDiagnosticsIsReadOnlyAndUnavailableToWorkerOrAssistant() throws {
        let before = try router.dbQueue.read { db in try router.records(db, type: "task").count }
        _ = try call("diagnostics_summary")
        let after = try router.dbQueue.read { db in try router.records(db, type: "task").count }
        XCTAssertEqual(before, after)
        for role in ["worker", "assistant"] {
            let caller = Caller(role: role, installation: "untrusted-diagnostics", projectIDs: [], sessionID: "private-session")
            XCTAssertFalse(router.toolCatalog(caller).contains { $0["name"] as? String == "diagnostics_summary" })
            XCTAssertThrowsError(try call("diagnostics_summary", caller: caller)) { XCTAssertEqual(($0 as? CoreError)?.code, "FORBIDDEN") }
        }
    }
}
