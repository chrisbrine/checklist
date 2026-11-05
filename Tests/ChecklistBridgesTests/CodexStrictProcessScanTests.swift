import XCTest
@testable import ChecklistBridges

final class CodexStrictProcessScanTests: XCTestCase {
    private let thread = "00000000-0000-4000-8000-000000000434"
    private let app = "/Applications/Synthetic.app/Contents/MacOS/codex"
    private struct Entry: Sendable {
        var bsd: CodexProcessAccount? = .init(effective: 501, real: 501, command: "agent")
        var kernel: CodexProcessAccount? = .init(effective: 501, real: 501, command: "agent")
        var path: String? = "/usr/libexec/agent"
        var argv: [String]? = ["agent"]
        var descriptors = CodexProcessDescriptors(complete: true)
        var gone = false
    }
    private struct Table: CodexProcessTableReading {
        var entries: [Int32: Entry]
        var listed = true
        func processIDs() -> [Int32]? { listed ? entries.keys.sorted() : nil }
        func bsdAccount(_ pid: Int32) -> CodexProcessAccount? { entries[pid]?.bsd }
        func kernelAccount(_ pid: Int32) -> CodexProcessAccount? { entries[pid]?.kernel }
        func executable(_ pid: Int32) -> String? { entries[pid]?.path }
        func arguments(_ pid: Int32) -> [String]? { entries[pid]?.argv }
        func descriptors(_ pid: Int32) -> CodexProcessDescriptors { entries[pid]!.descriptors }
        func definitelyGone(_ pid: Int32) -> Bool { entries[pid]?.gone == true }
    }
    private func scan(_ entries: [Int32: Entry]) throws -> CodexHostScan {
        try XCTUnwrap(MacOSCodexProcessObserver(sessionsRoot: "/unused", accountID: 501, table: Table(entries: entries))
            .scan(threadID: thread, requireComplete: true))
    }
    private var rollout: String { "/any/root/rollout-test-\(thread).jsonl" }
    private func host() -> Entry {
        var e = Entry(); e.path = app; e.argv = [app, "app-server"]
        e.descriptors.paths = [rollout]; return e
    }
    private func preflight(_ scan: CodexHostScan) -> CodexQueueReason? {
        let result = CodexQueueRoute.preflight(registrationProven: true, enabled: true,
            observation: .init(host: .nativeApp, reason: .sourceVscode, source: "vscode"), scan: { scan },
            hostVerified: { _ in true }, threadItems: { .empty })
        if case .refused(let observation) = result { return observation.reason }
        return nil
    }
    func testOtherAccountEPERMUsesKernelAccountAndSkips() throws {
        var e = Entry(); e.bsd = nil; e.kernel = .init(effective: 0, real: 0, command: "codex")
        e.path = nil; e.argv = nil; e.descriptors.complete = false
        let result = try scan([10: e])
        XCTAssertFalse(result.unreadable); XCTAssertEqual(result.incompleteNonCodex, 0); XCTAssertTrue(result.holders.isEmpty)
    }
    func testUnreadableAccountRefusesUnlessPositivelyGone() throws {
        var e = Entry(); e.bsd = nil; e.kernel = nil
        XCTAssertTrue(try scan([10: e]).unreadable)
        e.gone = true; XCTAssertFalse(try scan([10: e]).unreadable)
    }
    func testSameAccountNoPathCodexCommandRequiresCompleteDescriptors() throws {
        var e = Entry(); e.path = nil; e.kernel = .init(effective: 501, real: 501, command: "codex")
        e.argv = ["renamed", "exec"]; e.descriptors.complete = false
        XCTAssertTrue(try scan([10: e]).unreadable)
        e.descriptors.complete = true; XCTAssertFalse(try scan([10: e]).unreadable)
    }
    func testNoPathNonCodexWithReadableArgumentsCanBeExcluded() throws {
        var e = Entry(); e.path = nil
        XCTAssertFalse(try scan([10: e]).unreadable)
        e.descriptors.complete = false
        let result = try scan([10: e])
        XCTAssertFalse(result.unreadable); XCTAssertEqual(result.incompleteNonCodex, 1)
    }
    func testNoPathUnreadableArgumentsOrKernelIdentityRefuses() throws {
        var e = Entry(); e.path = nil; e.argv = nil
        XCTAssertTrue(try scan([10: e]).unreadable)
        e.argv = ["agent"]; e.kernel = nil
        XCTAssertTrue(try scan([10: e]).unreadable)
    }
    func testIncompleteNonCodexVnodeIsCountedAndKnownPathsAreRetained() throws {
        var e = Entry(); e.descriptors = .init(paths: ["/some/readable/path"], complete: false)
        let result = try scan([10: e, 11: host()])
        XCTAssertFalse(result.unreadable); XCTAssertEqual(result.incompleteNonCodex, 1)
        XCTAssertEqual(result.holders.map(\.pid), [11]); XCTAssertNil(preflight(result))
        e.descriptors.paths.append(rollout)
        let competing = try scan([10: e, 11: host()])
        XCTAssertEqual(competing.holders.map(\.pid), [10, 11])
        XCTAssertEqual(preflight(competing), .holderUnclassified)
    }
    func testCodexUnreadableArgumentsOrDescriptorsAlwaysRefuses() throws {
        var e = Entry(); e.path = "/x/codex"; e.argv = nil
        XCTAssertTrue(try scan([10: e]).unreadable)
        e.argv = ["codex", "exec"]; e.descriptors.complete = false
        XCTAssertTrue(try scan([10: e]).unreadable)
    }
    func testSecondReadableHolderRefusesEvenWhenNotCodex() throws {
        var e = Entry(); e.descriptors.paths = [rollout]
        let result = try scan([10: e, 11: host()])
        XCTAssertFalse(result.unreadable); XCTAssertEqual(result.holders.count, 2)
        XCTAssertEqual(preflight(result), .holderUnclassified)
    }
    func testExecNamingThreadAndNonCodexLastClaimRefuse() throws {
        var e = Entry(); e.path = "/x/codex"; e.argv = ["codex", "exec", "resume", thread]
        XCTAssertEqual(preflight(try scan([10: e, 11: host()])), .holderExec)
        e.path = "/usr/bin/helper"; e.argv = ["helper", "--last"]
        XCTAssertTrue(try scan([10: e]).execClaim)
        XCTAssertEqual(preflight(try scan([10: e, 11: host()])), .holderExec)
    }
    func testNoPathArgvCodexAndThreadClaimStayCandidates() throws {
        var e = Entry(); e.path = nil; e.argv = ["/x/codex", "exec"]; e.descriptors.complete = false
        XCTAssertTrue(try scan([10: e]).unreadable)
        e.argv = ["helper", thread]; XCTAssertTrue(try scan([10: e]).unreadable)
        e.descriptors.complete = true; XCTAssertTrue(try scan([10: e]).execClaim)
    }
    func testIncompleteEnumerationAndStrictArgumentParsingRefuse() throws {
        let observer = MacOSCodexProcessObserver(sessionsRoot: "/unused", accountID: 501, table: Table(entries: [:], listed: false))
        XCTAssertNil(observer.scan(threadID: thread, requireComplete: true))
        XCTAssertNil(observer.scan(threadID: "invalid", requireComplete: true))
        var bytes: [UInt8] = [1, 0, 0, 0] + Array("/x/agent".utf8) + [0, 0] + Array("agent".utf8)
        XCTAssertNil(MacOSCodexProcessObserver.parseArguments(bytes, requireComplete: true))
        XCTAssertEqual(MacOSCodexProcessObserver.parseArguments(bytes), ["agent"], "Transport parser behavior is retained")
        bytes.append(0); XCTAssertEqual(MacOSCodexProcessObserver.parseArguments(bytes, requireComplete: true), ["agent"])
        bytes[bytes.count - 2] = 0xff; XCTAssertNil(MacOSCodexProcessObserver.parseArguments(bytes, requireComplete: true))
    }
}

final class CodexLiveProcessScanTests: XCTestCase {
    func testOptInStrictKernelScanIsComplete() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_LIVE_PROCESS_SCAN"] == "1" else {
            throw XCTSkip("Set CHECKLIST_LIVE_PROCESS_SCAN=1 for the authorized read-only kernel scan")
        }
        let scan = try XCTUnwrap(MacOSCodexProcessObserver().scan(threadID: UUID().uuidString, requireComplete: true))
        print("CL-434 live strict kernel scan: hosts=\(scan.hosts.count) holders=\(scan.holders.count) unreadable=\(scan.unreadable) execClaim=\(scan.execClaim) incompleteNonCodex=\(scan.incompleteNonCodex)")
        XCTAssertFalse(scan.unreadable)
    }
}
