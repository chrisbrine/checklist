@testable import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

/// CL-363: the fixture memo may only skip a launch whose inputs are byte-identical.
final class SourceGitFixtureMemoTests: XCTestCase {
    private final class Counting: SourceGitProcessAdapter, @unchecked Sendable {
        var launches = 0,failure: Error?
        let real = MacOSSourceGitProcessAdapter()
        func run(_ request: SourceGitProcessRequest) throws -> Data {
            launches += 1
            if let failure {throw failure}
            return try real.run(request)
        }
    }
    private var directory: URL!
    override func setUpWithError() throws {
        let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true).resolvingSymlinksInPath()
        directory = caches.appendingPathComponent("ChecklistQualification/CL-363/" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:directory)}
    private func repository(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name,isDirectory:true)
        try FileManager.default.createDirectory(at:url.appendingPathComponent(".git/refs"),withIntermediateDirectories:true)
        try Data("ref: refs/heads/main\n".utf8).write(to:url.appendingPathComponent(".git/HEAD"))
        try FileManager.default.createDirectory(at:url.appendingPathComponent(".git/objects"),withIntermediateDirectories:true)
        try Data("base".utf8).write(to:url.appendingPathComponent("tracked.txt"))
        return url
    }
    private func run(_ memo: SourceGitFixtureMemo,_ url: URL,_ args: [String],roots: [String]? = nil) throws -> Data {
        try SourceGit.run(url.path,args,protectedRoots:roots ?? [directory.appendingPathComponent("store").path],processAdapter:memo)
    }
    func testSameTreeReusesAndRebindsThePathWhileAChangedTreeRunsRealGit() throws {
        let counting = Counting(),memo = SourceGitFixtureMemo(real:counting),first = try repository("first"),second = try repository("second")
        let args = ["rev-parse","--show-toplevel"]
        let original = try run(memo,first,args)
        XCTAssertEqual(String(decoding:original,as:UTF8.self).trimmingCharacters(in:.newlines),first.path)
        XCTAssertEqual(counting.launches,1)
        let reused = try run(memo,second,args)
        XCTAssertEqual(counting.launches,1)
        XCTAssertEqual(String(decoding:reused,as:UTF8.self).trimmingCharacters(in:.newlines),second.path)
        // Real Git gives exactly the rebound answer.
        XCTAssertEqual(reused,try SourceGit.run(second.path,args,protectedRoots:[directory.appendingPathComponent("store").path],processAdapter:counting.real))
        for change in [{try Data("edit".utf8).write(to:second.appendingPathComponent("tracked.txt"))},
                       {try Data("new".utf8).write(to:second.appendingPathComponent("untracked.txt"))},
                       {try Data("[core]\n".utf8).write(to:second.appendingPathComponent(".git/config"))},
                       {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:second.appendingPathComponent("tracked.txt").path)}] as [() throws -> Void] {
            let before = counting.launches
            try change();_ = try run(memo,second,args)
            XCTAssertEqual(counting.launches,before+1,"Every tree change needs real Git")
        }
    }
    func testRefusalIsNeverRemembered() throws {
        let counting = Counting(),memo = SourceGitFixtureMemo(real:counting),url = try repository("refused"),args = ["rev-parse","--show-toplevel"]
        counting.failure = CoreError("SOURCE_GIT_CONFINED","Synthetic refusal")
        XCTAssertThrowsError(try run(memo,url,args));XCTAssertThrowsError(try run(memo,url,args))
        XCTAssertEqual(counting.launches,2)
        counting.failure = nil
        _ = try run(memo,url,args);XCTAssertEqual(counting.launches,3)
    }
    func testAnyInputOutsideTheDigestRunsRealGitEveryTime() throws {
        let counting = Counting(),memo = SourceGitFixtureMemo(real:counting),args = ["rev-parse","--show-toplevel"]
        // A protected root over the workspace, its parent or inside it.
        let protected = try repository("protected")
        for root in [protected.path,directory.path,protected.appendingPathComponent("store").path] {
            counting.launches = 0;counting.failure = CoreError("SOURCE_GIT_CONFINED","Synthetic refusal")
            XCTAssertThrowsError(try run(memo,protected,args,roots:[root]));XCTAssertEqual(counting.launches,1)
        }
        counting.failure = nil
        // A symlink can read outside the digest; a .git file points elsewhere.
        let linked = try repository("linked")
        try FileManager.default.createSymbolicLink(atPath:linked.appendingPathComponent("link").path,withDestinationPath:"/etc/hosts")
        counting.launches = 0
        _ = try run(memo,linked,args);_ = try run(memo,linked,args);XCTAssertEqual(counting.launches,2)
        let worktree = try repository("worktree"),metadata = worktree.appendingPathComponent(".git")
        try FileManager.default.removeItem(at:metadata)
        try FileManager.default.moveItem(at:try repository("metadata").appendingPathComponent(".git"),to:directory.appendingPathComponent("external"))
        try Data(("gitdir: " + directory.appendingPathComponent("external").path + "\n").utf8).write(to:metadata)
        counting.launches = 0
        _ = try? run(memo,worktree,args);_ = try? run(memo,worktree,args);XCTAssertEqual(counting.launches,2)
    }
    func testEachTestStartsWithoutTheMemoAndRouterOptOutKeepsItOff() throws {
        XCTAssertNil(SourceGit.fixtureProcessAdapter.withLockUnchecked {$0},"The previous test's router must not leak the memo")
        let store = directory.appendingPathComponent("opt-out")
        let router = try TestStore.router(root:store,sourceGitMemo:false);defer {try? router.closeStore()}
        XCTAssertNil(SourceGit.fixtureProcessAdapter.withLockUnchecked {$0})
        let enabled = try TestStore.router(root:directory.appendingPathComponent("enabled"),sourceGitMemo:true);defer {try? enabled.closeStore()}
        XCTAssertNotNil(SourceGit.fixtureProcessAdapter.withLockUnchecked {$0})
    }
}
