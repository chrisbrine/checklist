import XCTest
import Darwin
@testable import ChecklistCore

/// Real subprocess probes use only owned temporary repositories and protected roots.
/// fixtureGit is deliberately unconfined for fixture creation and positive controls;
/// all assertions about product behavior call SourceGit or CommandRouter.
final class SourceGitConfinementTests: XCTestCase {
    private final class Fixture {
        let base: URL, repo: URL, store: URL, home: URL, git: String
        var environment: [String: String] { ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "PATH": "/usr/bin:/bin", "LC_ALL": "C"] }
        init() throws {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            base = source.appendingPathComponent(".probe/git-confinement-" + UUID().uuidString)
            repo = base.appendingPathComponent("repo"); store = base.appendingPathComponent("protected-store"); home = base.appendingPathComponent("home")
            git = try SourceGit.resolve()
            for path in [repo, store, home] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            _ = try fixtureGit(["init", "--quiet"])
            try write(repo.appendingPathComponent("source.txt"), "source")
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func write(_ path: URL, _ value: String) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: path)
        }
        @discardableResult func fixtureGit(_ args: [String], at path: URL? = nil, environment override: [String: String]? = nil) throws -> Data {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", (path ?? repo).path] + args
            process.environment = override ?? environment
            process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
            try process.run()
            let bytes = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw CoreError("FIXTURE_GIT_FAILED", String(decoding: errors, as: UTF8.self))
            }
            return bytes
        }
        func run(_ args: [String], environment override: [String: String]? = nil) throws -> Data {
            try SourceGit.run(repo.path, args, protectedRoots: [store.path], executable: git, additionalOwnerHome: home.path, inheritedEnvironment: override ?? environment)
        }
        func config(_ key: String, _ value: String) throws { try fixtureGit(["config", key, value]) }
        func helper(_ name: String) throws -> (URL, URL) {
            let helper = base.appendingPathComponent(name), marker = base.appendingPathComponent(name + "-executed")
            try write(helper, "#!/bin/sh\nprintf executed > '\(marker.path)'\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            return (helper, marker)
        }
    }
    private func confined(_ body: () throws -> Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_CONFINED", file: file, line: line)
        }
    }

    func testMissingOrInvalidConfinementNeverLaunchesGit() throws {
        let f = try Fixture(), (helper, marker) = try f.helper("must-not-launch")
        for roots in [[], ["relative"], ["/"], ["/tmp/../"], ["/tmp/invalid\nroot"], ["/tmp/invalid\0root"]] {
            XCTAssertThrowsError(try SourceGit.run(f.repo.path, ["--version"], protectedRoots: roots, executable: helper.path)) {
                XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_GIT_CONFINEMENT_UNAVAILABLE", "\($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(SourceGit.Confinement.launcher, "/usr/bin/sandbox-exec")
    }

    func testSignalCannotBeAcceptedAsAnUnbornHeadExit() throws {
        let f = try Fixture(), trusted = try ReadPerformanceFixture("CL-180-signal")
        let script = trusted.directory.appendingPathComponent("signaled-git")
        try f.write(script, "#!/bin/sh\nkill -TERM $$\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        confined { try SourceGit.run(f.repo.path, ["rev-parse", "--verify", "--quiet", "HEAD"], protectedRoots: [f.store.path], executable: script.path, acceptedExitCodes: [0, 1, SIGTERM]) }
    }

    func testOwnerNamespacesAndEscapedCanonicalRootAreProtected() throws {
        let f = try Fixture()
        let roots = [f.store, f.home.appendingPathComponent("Library/Application Support/Checklist"), f.home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-1/data"), f.home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-2/data"), f.home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-3/data"), f.home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-4/data"), f.home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-99/data"), f.base.appendingPathComponent("quoted-\"-\\-store")]
        for root in roots {
            let sentinel = root.appendingPathComponent("config")
            try f.write(sentinel, "[probe]\nsecret = PROTECTED_SENTINEL\n")
            let args = ["config", "--file", sentinel.path, "--get", "probe.secret"]
            XCTAssertEqual(try f.fixtureGit(args), Data("PROTECTED_SENTINEL\n".utf8))
            confined { try SourceGit.run(f.repo.path, args, protectedRoots: [f.store.path, roots.last!.path], executable: f.git, additionalOwnerHome: f.home.path, inheritedEnvironment: f.environment) }
        }
        let alias = f.base.appendingPathComponent("store-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.store)
        confined { try f.run(["config", "--file", alias.appendingPathComponent("config").path, "--get", "probe.secret"]) }
    }

    func testAbsentNamespaceAndProtectedRootAliasUsePhysicalPaths() throws {
        let f = try Fixture(), alias = f.base.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.home)
        let namespace = alias.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-99/data")
        let confinement = try SourceGit.Confinement(protectedRoots: [f.store.path], additionalOwnerHome: alias.path)
        let sentinel = namespace.appendingPathComponent("config")
        try f.write(sentinel, "[probe]\nsecret = PROTECTED_SENTINEL\n")
        let args = ["config", "--file", sentinel.path, "--get", "probe.secret"]
        XCTAssertEqual(try f.fixtureGit(args), Data("PROTECTED_SENTINEL\n".utf8))
        // Use the already generated profile: its missing namespaces had to be
        // resolved through their existing ancestor before the sentinel existed.
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: SourceGit.Confinement.launcher)
        process.arguments = ["-p", confinement.profile, f.git, "-C", f.repo.path] + args
        process.environment = SourceGit.environment(f.environment)
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL); XCTAssertTrue(bytes.isEmpty)
        confined { try SourceGit.run(f.repo.path, args, protectedRoots: [alias.path], executable: f.git, inheritedEnvironment: f.environment) }
    }

    func testDirectNestedAndActiveConditionalIncludesTerminateInventoryAndCapture() throws {
        for mode in ["direct", "nested", "conditional"] {
            let f = try Fixture(), sentinel = f.store.appendingPathComponent("sentinel-config")
            let router = try CommandRouter(root: f.store)
            defer { try? router.closeStore() }
            try f.write(sentinel, "[probe]\nsecret = PROTECTED_SENTINEL\n")
            if mode == "nested" {
                let intermediate = f.base.appendingPathComponent("included-config")
                try f.write(intermediate, "[include]\npath = \(sentinel.path)\n")
                try f.config("include.path", intermediate.path)
            } else if mode == "conditional" {
                try f.config("includeIf.gitdir:\(f.repo.path)/.git.path", sentinel.path)
            } else { try f.config("include.path", sentinel.path) }
            XCTAssertEqual(try f.fixtureGit(["config", "--get", "probe.secret"]), Data("PROTECTED_SENTINEL\n".utf8))
            confined { try f.run(["rev-parse", "--show-toplevel"]) }
            confined { _ = try router.sourceInventory(f.repo.path, useCache: false); return Data() }
            confined { _ = try router.copySourceCapture(projectID: "synthetic", sourceRoot: f.repo.path, request: [:]); return Data() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.appendingPathComponent("source-captures").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.appendingPathComponent("staging/source-captures").path))
        }
    }

    func testEffectiveOptionalExcludesAndAttributesCannotBeSilentlyIgnored() throws {
        for attribute in [false, true] {
            let f = try Fixture(), sentinel = f.store.appendingPathComponent("rules")
            try f.write(sentinel, attribute ? "* secret=PROTECTED_SENTINEL\n" : "source.txt\n")
            try f.config(attribute ? "core.attributesFile" : "core.excludesFile", sentinel.path)
            let args = attribute ? ["check-attr", "secret", "--", "source.txt"] : ["check-ignore", "source.txt"]
            let control = String(decoding: try f.fixtureGit(args), as: UTF8.self)
            XCTAssertTrue(control.contains(attribute ? "PROTECTED_SENTINEL" : "source.txt"))
            confined { try f.run(args) }
            if !attribute { confined { try f.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) } }
        }
    }

    func testMetadataAndRuleSymlinkAliasesCannotReadStoreBytes() throws {
        for name in ["config", "info/exclude", "info/attributes"] {
            let f = try Fixture(), sentinel = f.store.appendingPathComponent("aliased-file")
            let config = name == "config", attributes = name.hasSuffix("attributes")
            try f.write(sentinel, config ? "[probe]\nsecret = PROTECTED_SENTINEL\n" : attributes ? "* secret=PROTECTED_SENTINEL\n" : "source.txt\n")
            let alias = f.repo.appendingPathComponent(".git/" + name)
            try? FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sentinel)
            let args = config ? ["config", "--get", "probe.secret"] : attributes ? ["check-attr", "secret", "--", "source.txt"] : ["check-ignore", "source.txt"]
            XCTAssertFalse(try f.fixtureGit(args).isEmpty)
            confined { try f.run(args) }
        }
    }

    func testAlternatesAndObjectDirectoryAliasesCannotReturnProtectedBlob() throws {
        for alias in [false, true] {
            let f = try Fixture(), sentinel = f.store.appendingPathComponent("blob"), objects = f.store.appendingPathComponent("git-objects")
            try f.write(sentinel, "PROTECTED_BLOB_SENTINEL")
            let oid = String(decoding: try f.fixtureGit(["hash-object", "-w", sentinel.path]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let local = f.repo.appendingPathComponent(".git/objects")
            try FileManager.default.moveItem(at: local, to: objects)
            if alias { try FileManager.default.createSymbolicLink(at: local, withDestinationURL: objects) }
            else { try f.write(local.appendingPathComponent("info/alternates"), objects.path + "\n") }
            let args = ["cat-file", "-p", oid]
            XCTAssertEqual(try f.fixtureGit(args), Data("PROTECTED_BLOB_SENTINEL".utf8))
            confined { try f.run(args) }
        }
    }

    func testFsmonitorIsDisabledAndOtherHelpersAreKilledBeforeExecution() throws {
        let f = try Fixture(), (monitor, marker) = try f.helper("fsmonitor")
        try f.config("core.fsmonitor", monitor.path)
        _ = try f.fixtureGit(["status", "--porcelain"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        _ = try f.run(["status", "--porcelain"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let (alias, aliasMarker) = try f.helper("alias-helper")
        try f.config("alias.probe", "!" + alias.path)
        _ = try f.fixtureGit(["probe"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasMarker.path))
        try FileManager.default.removeItem(at: aliasMarker)
        confined { try f.run(["probe"]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasMarker.path))
        _ = try f.fixtureGit(["-c", "core.fsmonitor=false", "add", "source.txt"])
        try f.write(f.repo.appendingPathComponent("source.txt"), "changed")
        let (diff, diffMarker) = try f.helper("external-diff")
        try f.config("diff.external", diff.path)
        _ = try f.fixtureGit(["-c", "core.fsmonitor=false", "diff", "--ext-diff"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffMarker.path))
        try FileManager.default.removeItem(at: diffMarker)
        confined { try f.run(["diff", "--ext-diff"]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: diffMarker.path))
    }

    func testInheritedGitRepositoryConfigObjectAndTraceOverridesAreRemoved() throws {
        let f = try Fixture(), sentinel = f.store.appendingPathComponent("config"), trace = f.base.appendingPathComponent("trace-marker")
        try f.write(sentinel, "[probe]\nsecret = PROTECTED_SENTINEL\n")
        var environment = f.environment
        let overrides = ["GIT_DIR": f.store.path, "GIT_WORK_TREE": f.store.path, "GIT_INDEX_FILE": sentinel.path, "GIT_CONFIG_GLOBAL": sentinel.path, "GIT_CONFIG_SYSTEM": sentinel.path, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "include.path", "GIT_CONFIG_VALUE_0": sentinel.path, "GIT_CONFIG_PARAMETERS": "'include.path=\(sentinel.path)'", "GIT_OBJECT_DIRECTORY": f.store.path, "GIT_ALTERNATE_OBJECT_DIRECTORIES": f.store.path, "GIT_EXEC_PATH": f.store.path, "GIT_TRACE": trace.path, "GIT_TRACE2_EVENT": trace.path, "GIT_CONFIG_NOSYSTEM": "1"]
        environment.merge(overrides) { _, new in new }
        XCTAssertTrue(SourceGit.environment(environment).keys.filter { $0.hasPrefix("GIT_") && !["GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT", "GIT_NO_LAZY_FETCH"].contains($0) }.isEmpty)
        XCTAssertEqual(try f.run(["rev-parse", "--show-toplevel"], environment: environment), try f.run(["rev-parse", "--show-toplevel"]))
        XCTAssertEqual(try f.run(["ls-files", "-z", "--others", "--exclude-standard"], environment: environment), Data("source.txt\0".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path))
    }

    func testOwnerGlobalAndConditionalIgnoreMembershipIsPreserved() throws {
        let f = try Fixture(), global = f.home.appendingPathComponent("global-ignore"), conditional = f.home.appendingPathComponent("conditional-config"), conditionalIgnore = f.home.appendingPathComponent("conditional-ignore")
        try f.write(global, "global-only.txt\n")
        try f.write(conditionalIgnore, "global-only.txt\nconditional-only.txt\n")
        try f.write(conditional, "[core]\nexcludesFile = \(conditionalIgnore.path)\n")
        try f.write(f.home.appendingPathComponent(".gitconfig"), "[core]\nexcludesFile = \(global.path)\n[includeIf \"gitdir:\(f.repo.path)/.git\"]\npath = \(conditional.path)\n")
        for name in ["global-only.txt", "conditional-only.txt", "local-only.txt", "visible.txt"] { try f.write(f.repo.appendingPathComponent(name), name) }
        try f.write(f.repo.appendingPathComponent(".gitignore"), "local-only.txt\n")
        let args = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let expected = try f.fixtureGit(args)
        XCTAssertEqual(try f.run(args), expected)
        XCTAssertEqual(Set(String(decoding: expected, as: UTF8.self).split(separator: "\0").map(String.init)), [".gitignore", "source.txt", "visible.txt"])
    }

    func testNormalUnbornInitializedAndExternalWorktreeFingerprintsMatchGit() throws {
        let f = try Fixture(), router = try CommandRouter(root: f.store)
        defer { try? router.closeStore() }
        try f.write(f.repo.appendingPathComponent(".gitignore"), "ignored.txt\n")
        try f.write(f.repo.appendingPathComponent("ignored.txt"), "explicit ignored source")
        try f.write(f.repo.appendingPathComponent("deleted.txt"), "tracked deletion")
        _ = try f.fixtureGit(["add", "source.txt", "deleted.txt"])
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent("deleted.txt"))
        let unborn = try router.sourceInventory(f.repo.path, additional: ["ignored.txt"], useCache: false)
        XCTAssertEqual(unborn["base_revision"] as? String, "unborn")
        XCTAssertEqual(unborn["index_sha256"] as? String, ChecklistCore.hash(try f.fixtureGit(["ls-files", "--stage", "-z"])))
        let entries = try XCTUnwrap(unborn["files"] as? [JSON])
        XCTAssertEqual(Set(entries.compactMap { $0["path"] as? String }), [".gitignore", "source.txt", "deleted.txt", "ignored.txt"])
        XCTAssertEqual(entries.first { $0["path"] as? String == "deleted.txt" }?["kind"] as? String, "deleted")
        let identity: JSON = ["base_revision": unborn["base_revision"]!, "index_sha256": unborn["index_sha256"]!, "files": entries]
        XCTAssertEqual(unborn["sha256"] as? String, ChecklistCore.hash(Data(try jsonString(identity).utf8)))
        _ = try f.fixtureGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture"])
        let initialized = try router.sourceInventory(f.repo.path, additional: ["ignored.txt"], useCache: false)
        XCTAssertEqual(initialized["base_revision"] as? String, String(decoding: try f.fixtureGit(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(initialized["git_path"] as? String, f.git)
        XCTAssertEqual(initialized["git_version"] as? String, String(decoding: try f.run(["--version"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let worktree = f.base.appendingPathComponent("external-worktree")
        _ = try f.fixtureGit(["worktree", "add", "--quiet", "--detach", worktree.path])
        let inventory = try router.sourceInventory(worktree.path, useCache: false)
        XCTAssertEqual(inventory["base_revision"] as? String, initialized["base_revision"] as? String)
        let capture = try router.copySourceCapture(projectID: "synthetic", sourceRoot: worktree.path, request: [:])
        XCTAssertEqual(capture.inventory["sha256"] as? String, inventory["sha256"] as? String)
        try router.validateCapturedFiles(["snapshot_path": capture.pending.directory + "/source", "files": inventory["files"]!])
    }
}
