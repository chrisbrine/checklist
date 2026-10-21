import XCTest
import Darwin
@testable import ChecklistCore

final class SourceGitTests: XCTestCase {
    func script(_ f: ReadPerformanceFixture, _ name: String, _ body: String, mode: Int = 0o700) throws -> URL {
        let url = f.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func testFixedListAndFirstTrustedChoiceIncludingHomebrewStyleSymlink() throws {
        XCTAssertEqual(SourceGit.trustedPaths, ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"])
        let f = try ReadPerformanceFixture("CL-155")
        let first = try script(f, "Cellar/git/bin/git", "echo 'git version fixture-first'")
        let second = try script(f, "fallback/git", "echo 'git version fixture-second'")
        let link = f.directory.appendingPathComponent("bin/git")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Cellar/git/bin/git")
        XCTAssertEqual(try SourceGit.resolve(candidates: [f.directory.appendingPathComponent("missing").path, link.path, second.path]), first.path)
        // A PATH decoy is never a candidate. No environment mutation is needed to prove selection.
        XCTAssertEqual(try SourceGit.resolve(candidates: [second.path, first.path]), second.path)
    }

    func testUnsafeFileDirectorySymlinkTargetAndForeignOwnerAreRefused() throws {
        let f = try ReadPerformanceFixture("CL-155")
        let unsafe = try script(f, "unsafe-file", "exit 0", mode: 0o722)
        func refuses(_ path: String, reason: String) {
            XCTAssertThrowsError(try SourceGit.trustedExecutable(path)) {
                XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_UNTRUSTED")
                XCTAssertTrue(($0 as? CoreError)?.message.contains(reason) == true)
            }
        }
        refuses(unsafe.path, reason: "writable by other users")
        let nested = try script(f, "unsafe-folder/git", "exit 0")
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: nested.deletingLastPathComponent().path)
        refuses(nested.path, reason: "writable by other users")
        let link = f.directory.appendingPathComponent("git-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: nested.path)
        refuses(link.path, reason: "writable by other users")
        let safe = try script(f, "safe/git", "exit 0")
        XCTAssertEqual(try SourceGit.resolve(candidates: [unsafe.path, nested.path, safe.path]), safe.path)
        XCTAssertThrowsError(try SourceGit.resolve(candidates: [unsafe.path])) {
            XCTAssertTrue(($0 as? CoreError)?.message.contains("writable by other users") == true)
        }
        // Model another owner's policy without chown or privilege changes.
        if getuid() != 0 {
            XCTAssertThrowsError(try SourceGit.trustedExecutable(safe.path, owner: getuid() + 1)) {
                XCTAssertTrue(($0 as? CoreError)?.message.contains("not owned by root or the owner") == true)
            }
        }
    }

    func testXcodeLicenseFailureNamesCauseAndOwnerStep() throws {
        let f = try ReadPerformanceFixture("CL-155")
        let shim = try script(f, "git", "echo \"You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'\" >&2; exit 69")
        let selected = try SourceGit.resolve(candidates: [shim.path])
        for args in [["--version"], ["rev-parse", "--show-toplevel"], ["ls-files", "-z"]] {
            XCTAssertThrowsError(try SourceGit.run(f.directory.path, args, executable: selected)) {
                let error = $0 as? CoreError
                XCTAssertEqual(error?.code, "SOURCE_GIT_LICENSE_REQUIRED")
                XCTAssertTrue(error?.message.contains("Xcode license") == true)
                XCTAssertTrue(error?.message.contains("sudo xcodebuild -license accept") == true)
            }
        }
    }

    func testInventoryAndCaptureRecordResolvedGitPathAndVersionWithoutChangingSourceHash() throws {
        let f = try ReadPerformanceFixture("CL-155")
        let source = f.directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source.appendingPathComponent("file.txt"))
        let executable = try SourceGit.resolve()
        _ = try SourceGit.run(source.path, ["init"], executable: executable)
        let inventory = try f.router.sourceInventory(source.path, useCache: false)
        XCTAssertEqual(inventory["git_path"] as? String, executable)
        XCTAssertTrue((inventory["git_version"] as? String)?.hasPrefix("git version ") == true)
        let identity: JSON = ["base_revision": inventory["base_revision"]!, "index_sha256": inventory["index_sha256"]!, "files": inventory["files"]!]
        XCTAssertEqual(inventory["sha256"] as? String, ChecklistCore.hash(Data(try jsonString(identity).utf8)))
        let project = try f.call("project_create", ["name": "Git capture", "key_prefix": "GIT", "root_path": source.path])
        let task = try f.call("task_create", ["project_id": project["id"]!, "title": "Capture"])
        var capture: JSON = [:]
        try f.router.dbQueue.writeWithoutTransaction { db in
            try f.router.withValidatedDomainTransaction(db) {
                capture = try f.router.captureSource(db, request: [:], task: task, attempt: ["id": "capture-attempt"])
                return .commit
            }
        }
        XCTAssertEqual(capture["git_path"] as? String, executable)
        XCTAssertEqual(capture["git_version"] as? String, inventory["git_version"] as? String)
    }
}
