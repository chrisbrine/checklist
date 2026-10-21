import XCTest
import GRDB
@testable import ChecklistCore

/// CL-81: agent input cannot read outside its workspace, skip an authority check or
/// receive storage-engine text.
extension CoreTests {
    func boundaryFixture() throws -> (project: JSON, agent: Caller, workspace: URL, outside: URL) {
        let base = directory.appendingPathComponent("boundary-" + UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), outside = base.appendingPathComponent("outside")
        for folder in [workspace, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("private bytes outside the workspace".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let p = try call("project_create", ["name": "Boundary", "key_prefix": "BD", "root_path": workspace.path]), sid = UUID().uuidString
        _ = try call("session_register", ["project_id": p["id"]!, "session_id": sid, "provider": "codex", "role": "worker", "label": "Agent"])
        return (p, Caller(role: "worker", installation: "boundary-agent", projectIDs: [p["id"] as! String], sessionID: sid, workspace: workspace.path), workspace, outside)
    }

    func testSafeReadRefusesFinalSymlinkAndSwappedParentFolder() throws {
        let (_, _, workspace, outside) = try boundaryFixture()
        let roots = [canonical(workspace.path)]
        let file = workspace.appendingPathComponent("notes.txt")
        try Data("inside".utf8).write(to: file)
        XCTAssertEqual(try SafeFileRead.read(file.path, maximum: 1024, allowedRoots: roots).bytes, Data("inside".utf8))

        // Final component swapped for a symlink after the path check.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("secret.txt"))
        assertCode("FILE_ACCESS_REQUIRED") { _ = try SafeFileRead.read(file.path, maximum: 1024, allowedRoots: roots) }

        // A parent folder swapped for a symlink: O_NOFOLLOW alone would follow it;
        // the descriptor path check refuses the read.
        let folder = workspace.appendingPathComponent("art")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        assertCode("FILE_ACCESS_REQUIRED") { _ = try SafeFileRead.read(folder.appendingPathComponent("secret.txt").path, maximum: 1024, allowedRoots: roots) }
        assertCode("FILE_ACCESS_REQUIRED") { _ = try SafeFileRead.read(file.path, maximum: 1024, allowedRoots: []) }
    }

    func testAgentReadOfSwappedReferenceAttachmentReturnsNoOutsideBytes() throws {
        let (p, agent, workspace, outside) = try boundaryFixture()
        let t = try task(p)
        let folder = workspace.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("run.txt")
        try Data("run log".utf8).write(to: file)
        let attached = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": file.path, "mode": "reference"], agent)
        let read = try call("attachment_read", ["project_id": p["id"]!, "attachment_id": attached["id"]!, "representation": "original"], agent)
        XCTAssertEqual(read["content_base64"] as? String, Data("run log".utf8).base64EncodedString())

        // The final component becomes a symlink to a file outside the workspace.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("secret.txt"))
        for representation in ["original", "preview"] {
            assertCode("FILE_ACCESS_REQUIRED") { _ = try self.call("attachment_read", ["project_id": p["id"]!, "attachment_id": attached["id"]!, "representation": representation], agent) }
        }

        // The parent folder becomes a symlink to an outside folder with the same file name.
        try FileManager.default.removeItem(at: folder)
        try Data("other outside bytes".utf8).write(to: outside.appendingPathComponent("run.txt"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        for representation in ["original", "preview"] {
            assertCode("FILE_ACCESS_REQUIRED") { _ = try self.call("attachment_read", ["project_id": p["id"]!, "attachment_id": attached["id"]!, "representation": representation], agent) }
        }
    }

    func testPreviewReadWithoutSeparatePreviewChecksOriginalIdentity() throws {
        let (p, agent, workspace, _) = try boundaryFixture()
        let t = try task(p), file = workspace.appendingPathComponent("plan.txt")
        try Data("first".utf8).write(to: file)
        let attached = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": file.path, "mode": "reference"], agent)
        try Data("replaced in place".utf8).write(to: file)
        assertCode("SOURCE_CHANGED") { _ = try self.call("attachment_read", ["project_id": p["id"]!, "attachment_id": attached["id"]!, "representation": "preview"], agent) }
    }

    func testReferenceImportOfSymlinkLeavingWorkspaceIsRefused() throws {
        let (p, agent, workspace, outside) = try boundaryFixture()
        let t = try task(p), link = workspace.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("secret.txt"))
        for mode in ["reference", "managed"] {
            assertCode("FILE_ACCESS_REQUIRED") { _ = try self.call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": link.path, "mode": mode], agent) }
        }
        XCTAssertEqual((try call("attachment_list", ["project_id": p["id"]!, "task_id": t["id"]!])["attachments"] as? [JSON])?.count, 0)
    }

    func testMissingSessionRecordFailsClosedWithAndWithoutExecutionDomain() throws {
        let (p, agent, _, _) = try boundaryFixture()
        XCTAssertNotNil(try call("task_list", ["project_id": p["id"]!], agent)["tasks"])
        for domain in [nil, "codex:1:2:3"] as [String?] {
            let unregistered = Caller(role: "worker", installation: agent.installation, projectIDs: agent.projectIDs, sessionID: UUID().uuidString, workspace: agent.workspace, executionDomain: domain)
            assertCode("FORBIDDEN") { _ = try self.call("task_list", ["project_id": p["id"]!], unregistered) }
            assertCode("FORBIDDEN") { _ = try self.call("task_create", ["project_id": p["id"]!, "title": "Draft"], unregistered) }
        }
    }

    func testPublicErrorsCarryNoSQL() throws {
        let queue = try DatabaseQueue()
        var storageError: Error?
        do { try queue.write { try $0.execute(sql: "INSERT INTO missing_table(secret_column) VALUES ('private-value')") } } catch { storageError = error }
        let failure = try XCTUnwrap(storageError)
        XCTAssertTrue(failure.localizedDescription.lowercased().contains("insert into"), "fixture must carry SQL")
        let payload = PublicErrorText.payload(failure)
        let text = String(describing: payload)
        XCTAssertEqual(payload["code"] as? String, "STORAGE_ERROR")
        for fragment in ["INSERT", "missing_table", "secret_column", "private-value", "SQLite error"] { XCTAssertFalse(text.contains(fragment), fragment) }
        XCTAssertFalse(PublicErrorText.describe(failure).contains("missing_table"))

        let wrapped = CoreError("CONNECTION_RECOVERY_REQUIRED", "Pairing needs repair.", details: ["original_failure": failure.localizedDescription, "nested": ["text": "SELECT token FROM cursors"]])
        let scrubbed = String(describing: PublicErrorText.payload(wrapped))
        XCTAssertFalse(scrubbed.contains("missing_table")); XCTAssertFalse(scrubbed.contains("FROM cursors"))
        XCTAssertTrue(scrubbed.contains("CONNECTION_RECOVERY_REQUIRED"))
        XCTAssertEqual(PublicErrorText.payload(CoreError("NOT_FOUND", "Select a task in this project."))["message"] as? String, "Select a task in this project.")
    }
}
