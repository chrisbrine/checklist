import XCTest
import GRDB
import ChecklistProviders
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
        let project = try call("project_create",["name":"Synthetic diagnostics","key_prefix":"DIAG"])
        let projectID = project["id"] as! String
        let statuses = try call("taxonomy_get",["project_id":projectID])["statuses"] as! [JSON]
        let statusID = try XCTUnwrap(statuses.first?["id"] as? String)
        let before = try call("diagnostics_summary")["record_counts"] as! [String:Int]
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                try router.save(db, fixtureDomainValue(router,db:db,value:["id": "private-task-id", "project_id": projectID, "status_id":statusID, "title": secrets[0], "brief": secrets[1], "root_path": secrets[2], "claim_token": secrets[3], "session_id": secrets[4], "native_endpoint": secrets[5], "revision": 1],type:"task"), type: "task")
                try router.save(db, ["id": "private-message-id", "project_id":projectID, "body": secrets[0], "revision": 1], type: "message")
                // Unknown historical families are diagnostic input, never valid new domain writes.
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,NULL,?,1,?)",arguments:["unknown-private-id",secrets[2],try jsonString(["id":"unknown-private-id","revision":1])])
                return .commit
            }
        }
        let summary = try call("diagnostics_summary")
        let counts = summary["record_counts"] as! [String: Int]
        // Project bootstrap creates private infrastructure records; test only fixture deltas.
        XCTAssertEqual(counts["task"], before["task"]! + 1); XCTAssertEqual(counts["message"], before["message"]! + 1); XCTAssertEqual(counts["other"], before["other"]! + 1)
        XCTAssertNil(counts[secrets[2]])
        XCTAssertEqual((summary["service"] as! JSON)["state"] as? String, "responsive")
        let bytes = try jsonString(summary)
        for secret in secrets + ["private-task-id", projectID, statusID, "private-message-id", directory.path] { XCTAssertFalse(bytes.contains(secret)) }
        XCTAssertEqual(Set(summary.keys), ["schema_version", "observed_at", "service", "record_counts"])
    }

    func testServiceInfoAndDiagnosticsReportTheSameBundleIdentity() throws {
        let service = try call("service_info")
        let diagnostics = try call("diagnostics_summary")["service"] as! JSON
        XCTAssertEqual(service["version"] as? String, ChecklistBuildVersion.current.version)
        XCTAssertEqual(service["build_id"] as? String, ChecklistBuildVersion.current.buildID)
        XCTAssertEqual(service["build_number"] as? Int, ChecklistBuildVersion.current.buildNumber)
        for key in ["version", "build_id", "build_number"] {
            XCTAssertEqual(String(describing: service[key]!), String(describing: diagnostics[key]!))
        }
    }

    func testDiagnosticsIsReadOnlyAndRequiresScopedWorkerOrOwner() throws {
        let before = try router.dbQueue.read { db in try router.records(db, type: "task").count }
        _ = try call("diagnostics_summary")
        let after = try router.dbQueue.read { db in try router.records(db, type: "task").count }
        XCTAssertEqual(before, after)
        for role in ["worker", "assistant"] {
            let caller = Caller(role: role, installation: "untrusted-diagnostics", projectIDs: [], sessionID: "private-session")
            XCTAssertEqual(router.toolCatalog(caller).contains { $0["name"] as? String == "diagnostics_summary" },role == "worker")
            XCTAssertThrowsError(try call("diagnostics_summary", ["project_id":"outside-grant"], caller: caller)) { XCTAssertEqual(($0 as? CoreError)?.code, "FORBIDDEN") }
        }
    }
}
