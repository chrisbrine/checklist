import XCTest
import Darwin
@testable import ChecklistCore

final class SourceCaptureStoreBoundaryTests: XCTestCase {
    private final class Fixture {
        let base: URL, store: URL, router: CommandRouter
        init(storePath: String = "project/Checklist") throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            base = repository.appendingPathComponent(".probe/rework2/source-boundary-" + UUID().uuidString)
            store = base.appendingPathComponent(storePath)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            router = try CommandRouter(root: store)
        }
        deinit { try? router.closeStore(); try? FileManager.default.removeItem(at: base) }
        func write(_ relative: String, bytes: Data = Data("source-boundary sentinel".utf8)) throws -> URL {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }
    }
    private func refused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_CAPTURE_INCOMPLETE", file: file, line: line)
            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String, "checklist_store_overlap", file: file, line: line)
        }
    }
    func testAncestorIsRefusedBeforeInventoryGitOrCaptureStaging() throws {
        let f = try Fixture(), project = f.store.deletingLastPathComponent()
        let sentinel = try f.write("project/Checklist/objects/sentinel")
        let before = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        // A failing Git marker proves refusal precedes Git discovery/execution too.
        try Data("not a repository".utf8).write(to: project.appendingPathComponent(".git"))
        refused { _ = try f.router.sourceInventory(project.path, useCache: false) }
        refused { _ = try f.router.copySourceCapture(projectID: "synthetic", sourceRoot: project.path, request: [:]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.appendingPathComponent("staging/source-captures").path))
        let after = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        for key in [FileAttributeKey.systemFileNumber, .modificationDate, .size] {
            XCTAssertEqual(String(describing: before[key]), String(describing: after[key]))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("source-boundary sentinel".utf8))
    }
    func testStoreAndDescendantAreRefusedBeforeCachedInventory() throws {
        let f = try Fixture()
        _ = try f.write("project/Checklist/objects/sentinel")
        for path in [f.store.path, f.store.appendingPathComponent("objects").path] {
            var preparation = CommandPreparation()
            preparation.inventories[f.router.inventoryKey(path, [])] = ["sha256":"cached", "files":[]]
            f.router.commandPreparation = preparation
            refused { _ = try f.router.sourceInventory(path) }
        }
        f.router.commandPreparation = CommandPreparation()
    }
    func testSymlinkAndUnicodeAliasesCannotBecomeSourceRoots() throws {
        let f = try Fixture(storePath: "Caf\u{00e9}")
        let alias = f.base.appendingPathComponent("store-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.store)
        refused { _ = try f.router.sourceInventory(alias.path, useCache: false) }
        let decomposed = f.base.appendingPathComponent("Cafe\u{0301}")
        var canonicalInfo = stat(), aliasInfo = stat()
        guard stat(f.store.path, &canonicalInfo) == 0, stat(decomposed.path, &aliasInfo) == 0,
              canonicalInfo.st_dev == aliasInfo.st_dev, canonicalInfo.st_ino == aliasInfo.st_ino else {
            throw XCTSkip("Requires normalization-insensitive filesystem aliases.")
        }
        refused { _ = try f.router.sourceInventory(decomposed.path, useCache: false) }
    }
    func testSelectedEntryAliasIntoStoreIsRefused() throws {
        let f = try Fixture(storePath: "store")
        _ = try f.write("store/objects/sentinel")
        let project = f.base.appendingPathComponent("workspace")
        _ = try f.write("workspace/source.txt")
        let alias = project.appendingPathComponent("store-alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../store/objects")
        refused { _ = try f.router.sourceInventory(project.path, additional: ["store-alias/sentinel"], useCache: false) }
        refused { _ = try f.router.copySourceCapture(projectID: "synthetic", sourceRoot: project.path, request: ["additional_paths":["store-alias/sentinel"]]) }
    }
    func testSiblingProjectIncludingStoreNamePrefixStillCapturesNormally() throws {
        let f = try Fixture(storePath: "store"), bytes = Data("normal project source".utf8)
        let source = try f.write("store-project/source.txt", bytes: bytes)
        let project = source.deletingLastPathComponent()
        let inventory = try f.router.sourceInventory(project.path, additional: ["source.txt"], useCache: false)
        XCTAssertEqual((inventory["files"] as? [JSON])?.count, 1)
        let capture = try f.router.copySourceCapture(projectID: "synthetic", sourceRoot: project.path, request: [:])
        let captured = f.store.appendingPathComponent(capture.pending.directory + "/source/source.txt")
        XCTAssertEqual(try Data(contentsOf: captured), bytes)
    }
    private func refuseGitMetadata(_ mode: String) throws {
        let f = try Fixture(storePath:"store"), project = f.base.appendingPathComponent("project")
        _ = try f.write("project/source.txt")
        let executable = try SourceGit.resolve(), metadata = f.store.appendingPathComponent("git-meta")
        if mode == "commondir" {
            _ = try SourceGit.run(project.path,["init","--quiet"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
            _ = try SourceGit.run(f.base.path,["init","--bare","--quiet",metadata.path], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
            try Data("../../store/git-meta\n".utf8).write(to:project.appendingPathComponent(".git/commondir"))
        } else {
            _ = try SourceGit.run(project.path,["init","--quiet","--separate-git-dir=" + metadata.path], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
            try FileManager.default.removeItem(at:project.appendingPathComponent(".git"))
            if mode == "symlink" {
                try FileManager.default.createSymbolicLink(atPath:project.appendingPathComponent(".git").path,withDestinationPath:"../store/git-meta")
            } else {
                try Data("gitdir: ../store/git-meta\n".utf8).write(to:project.appendingPathComponent(".git"))
            }
        }
        // A Git config read would report "bad config line", without our reason.
        let sentinel = metadata.appendingPathComponent("config"), bytes = Data("[INVALID STORE CONFIG\n".utf8)
        try bytes.write(to:sentinel)
        let before = try FileManager.default.attributesOfItem(atPath:sentinel.path)
        refused { _ = try f.router.sourceInventory(project.path,useCache:false) }
        refused { _ = try f.router.copySourceCapture(projectID:"synthetic",sourceRoot:project.path,request:[:]) }
        let after = try FileManager.default.attributesOfItem(atPath:sentinel.path)
        for key in [FileAttributeKey.systemFileNumber,.modificationDate,.size] {
            XCTAssertEqual(String(describing:before[key]),String(describing:after[key]))
        }
        XCTAssertEqual(try Data(contentsOf:sentinel),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.store.appendingPathComponent("source-captures").path))
    }
    func testGitDirectorySymlinkIntoStoreIsRefusedBeforeGitReadsConfig() throws {
        try refuseGitMetadata("symlink")
    }
    func testGitdirFileIntoStoreIsRefusedBeforeGitReadsConfig() throws {
        try refuseGitMetadata("gitdir")
    }
    func testCommonDirectoryIntoStoreIsRefusedBeforeGitReadsConfig() throws {
        try refuseGitMetadata("commondir")
    }
    func testExternalGitdirWorktreeStillInventoriesAndCaptures() throws {
        let f = try Fixture(storePath:"store"), main = f.base.appendingPathComponent("main"), project = f.base.appendingPathComponent("worktree")
        let source = try f.write("main/source.txt",bytes:Data("worktree source".utf8)), executable = try SourceGit.resolve()
        _ = try SourceGit.run(main.path,["init","--quiet"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
        _ = try SourceGit.run(main.path,["add","source.txt"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
        _ = try SourceGit.run(main.path,["-c","maintenance.auto=false","-c","gc.auto=0","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","--quiet","-m","fixture"], protectedRoots: [NSTemporaryDirectory() + "checklist-fixture-protected"],executable:executable)
        // Fixture creation invokes Git's own reset child. Production capture is
        // confined below; worktree creation is not a production inventory command.
        let setup = Process(); setup.executableURL = URL(fileURLWithPath: executable)
        setup.arguments = ["-C",main.path,"worktree","add","--quiet","--detach",project.path]
        setup.standardOutput = FileHandle.nullDevice; setup.standardError = FileHandle.nullDevice
        try setup.run(); setup.waitUntilExit(); XCTAssertEqual(setup.terminationStatus,0)
        XCTAssertTrue(try String(contentsOf:project.appendingPathComponent(".git"),encoding:.utf8).hasPrefix("gitdir: "))
        XCTAssertTrue(FileManager.default.fileExists(atPath:main.appendingPathComponent(".git/worktrees/worktree/commondir").path))
        let inventory = try f.router.sourceInventory(project.path,useCache:false)
        XCTAssertEqual((inventory["files"] as? [JSON])?.count,1)
        let capture = try f.router.copySourceCapture(projectID:"synthetic",sourceRoot:project.path,request:[:])
        XCTAssertEqual(try Data(contentsOf:f.store.appendingPathComponent(capture.pending.directory + "/source/source.txt")),try Data(contentsOf:source))
    }
}
