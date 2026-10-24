import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testExportCopiesChecksummedSourceCapturesAndExecutionLogsWithPortableReferences() throws {
        // A project source tree is external to its Checklist store.
        try router.closeStore(); router = try TestStore.router(root: directory.appendingPathComponent("store"))
        let workspace = directory.appendingPathComponent("export-source")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sourceBytes = Data("Complete captured source".utf8)
        try sourceBytes.write(to: workspace.appendingPathComponent("result.txt"))
        try FileManager.default.createSymbolicLink(atPath: workspace.appendingPathComponent("result-link").path, withDestinationPath: "result.txt")
        let p = try call("project_create", ["name": "Source export", "key_prefix": "SRC", "root_path": workspace.path]), t = try ready(p, task(p))
        let attempt = try call("work_claim", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!])
        let capture = try router.dbQueue.write { db in try router.captureSource(db, request: [:], task: t, attempt: attempt) }
        let output = router.root.appendingPathComponent("source-executions/test-run/output.log")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputBytes = Data("Synthetic exporter fixture log".utf8); try outputBytes.write(to: output)
        let manifestID = UUID().uuidString.lowercased(), executionID = UUID().uuidString.lowercased()
        let evidence: JSON = ["kind": "source", "source_capture": capture]
        let originalDigest = ChecklistCore.hash(Data((try jsonString(evidence)).utf8))
        try router.dbQueue.write { db in
            try router.save(db, ["id": manifestID, "project_id": p["id"]!, "task_id": t["id"]!, "evidence": evidence, "digest": originalDigest, "revision": 1], type: "manifest")
            try router.save(db, ["id": executionID, "project_id": p["id"]!, "task_id": t["id"]!, "source_capture_id": capture["id"]!, "working_directory": capture["snapshot_path"]!, "output_path": output.path, "output_sha256": ChecklistCore.hash(outputBytes), "revision": 1], type: "source_execution")
        }
        let destination = directory.appendingPathComponent("source-export-bundle")
        _ = try call("export_project", ["project_id": p["id"]!, "path": destination.path])
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("project.json"))) as! JSON
        let portableCapture = (exported["source_capture"] as! [JSON])[0], portableExecution = (exported["source_execution"] as! [JSON])[0]
        XCTAssertNil(portableCapture["source_root"])
        let portableRoot = destination.appendingPathComponent(portableCapture["snapshot_path"] as! String)
        XCTAssertEqual(try Data(contentsOf: portableRoot.appendingPathComponent("result.txt")), sourceBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: portableRoot.appendingPathComponent("result-link").path), "result.txt")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(portableExecution["output_path"] as! String)), outputBytes)
        XCTAssertEqual(portableExecution["working_directory"] as? String, portableCapture["snapshot_path"] as? String)
        let portableManifest = (exported["manifest"] as! [JSON])[0], portableEvidence = portableManifest["evidence"] as! JSON
        XCTAssertEqual((portableEvidence["source_capture"] as! JSON)["snapshot_path"] as? String, portableCapture["snapshot_path"] as? String)
        XCTAssertNil((portableEvidence["source_capture"] as! JSON)["source_root"])
        XCTAssertEqual(portableManifest["digest"] as? String, originalDigest)
        XCTAssertEqual(portableManifest["export_evidence_sha256"] as? String, ChecklistCore.hash(Data((try jsonString(portableEvidence)).utf8)))
        try Data("Changed captured bytes".utf8).write(to: router.managedURL(capture["snapshot_path"] as! String,family:"source-captures").appendingPathComponent("result.txt"), options: .atomic)
        assertCode("EVIDENCE_STALE") { _ = try self.call("export_project", ["project_id": p["id"]!, "path": self.directory.appendingPathComponent("corrupted-source-export").path]) }
    }
}
