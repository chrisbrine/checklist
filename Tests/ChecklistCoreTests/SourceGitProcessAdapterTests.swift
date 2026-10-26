import XCTest
@testable import ChecklistCore

final class SourceGitProcessAdapterTests: XCTestCase {
    private final class RecordingAdapter: SourceGitProcessAdapter {
        var requests: [SourceGitProcessRequest] = []
        var output = Data("fixture inventory\0".utf8)
        var failure: CoreError?

        func run(_ request: SourceGitProcessRequest) throws -> Data {
            requests.append(request)
            if let failure { throw failure }
            return output
        }
    }

    func testValidatedInvocationRetainsConfinementArgumentsEnvironmentAndLimits() throws {
        let adapter = RecordingAdapter()
        let path = "/owned/source with spaces"
        let root = NSTemporaryDirectory() + "checklist-adapter-protected"
        let home = NSTemporaryDirectory() + "checklist-adapter-owner"
        let executable = try SourceGit.trustedExecutable("/usr/bin/git")
        let inherited = [
            "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "USER": "fixture",
            "LOGNAME": "fixture", "TMPDIR": home + "/tmp", "LANG": "C", "LC_ALL": "C",
            "PATH": "/untrusted/bin", "GIT_DIR": "/untrusted/repo", "GIT_CONFIG_COUNT": "1",
            "GIT_TRACE": "/untrusted/trace", "DYLD_INSERT_LIBRARIES": "/untrusted/library",
            "SSH_AUTH_SOCK": "/untrusted/socket"
        ]
        let output = try SourceGit.run(path, ["ls-files", "-z"], protectedRoots: [root],
            executable: executable, timeout: 13, acceptedExitCodes: [0, 1],
            additionalOwnerHome: home, inheritedEnvironment: inherited, processAdapter: adapter)

        XCTAssertEqual(output, adapter.output)
        let request = try XCTUnwrap(adapter.requests.first)
        XCTAssertEqual(adapter.requests.count, 1)
        let confinement = try SourceGit.Confinement(protectedRoots: [root], additionalOwnerHome: home)
        XCTAssertEqual(request.launcher, "/usr/bin/sandbox-exec")
        XCTAssertEqual(request.arguments, ["-p", confinement.profile, executable,
            "-c", "core.fsmonitor=false", "-C", path, "ls-files", "-z"])
        XCTAssertEqual(request.environment, [
            "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "USER": "fixture",
            "LOGNAME": "fixture", "TMPDIR": home + "/tmp", "LANG": "C", "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"
        ])
        XCTAssertEqual(request.timeout, 13)
        XCTAssertEqual(request.acceptedExitCodes, [0, 1])
        XCTAssertEqual(request.gitExecutable, executable)
    }

    func testInvalidConfinementIsRejectedBeforeAdapterInvocation() {
        let adapter = RecordingAdapter()
        for roots in [[], ["relative-root"], ["/"]] {
            XCTAssertThrowsError(try SourceGit.run("/owned/source", ["ls-files"],
                protectedRoots: roots, executable: "/usr/bin/git", processAdapter: adapter)) {
                XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_CONFINEMENT_UNAVAILABLE")
            }
        }
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testUntrustedExecutableIsRejectedBeforeAdapterInvocation() {
        let adapter = RecordingAdapter()
        XCTAssertThrowsError(try SourceGit.run("/owned/source", ["ls-files"],
            protectedRoots: [NSTemporaryDirectory() + "checklist-adapter-protected"],
            executable: "/nonexistent-checklist-test-git", processAdapter: adapter)) {
            XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_UNTRUSTED")
        }
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testAdapterFailurePassesThroughWithoutRetryOrFallback() {
        let adapter = RecordingAdapter()
        adapter.failure = CoreError("SOURCE_GIT_CONFINED", "fixture signal refusal", details: ["signal": 9])
        XCTAssertThrowsError(try SourceGit.run("/owned/source", ["ls-files"],
            protectedRoots: [NSTemporaryDirectory() + "checklist-adapter-protected"],
            executable: "/usr/bin/git", processAdapter: adapter)) {
            XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_CONFINED")
            XCTAssertEqual(($0 as? CoreError)?.message, "fixture signal refusal")
        }
        XCTAssertEqual(adapter.requests.count, 1)
    }

    func testUnsupportedAdapterRejectsWithoutExecutingRequestedProgram() throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("checklist-source-adapter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let request = SourceGitProcessRequest(launcher: "/usr/bin/touch", arguments: [marker.path],
            environment: [:], timeout: 1, acceptedExitCodes: [0], gitExecutable: "/usr/bin/git")
        XCTAssertThrowsError(try UnsupportedSourceGitProcessAdapter().run(request)) {
            let error = $0 as? CoreError
            XCTAssertEqual(error?.code, "SOURCE_GIT_CONFINEMENT_UNAVAILABLE")
            XCTAssertEqual(error?.message, SourceGit.Confinement.unavailable().message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
