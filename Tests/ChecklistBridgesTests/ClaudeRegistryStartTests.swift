import XCTest
import ChecklistIPC
@testable import ChecklistBridges

final class ClaudeRegistryStartTests: XCTestCase {
    private let session = "a85c9a24-fce8-49ba-a738-67594bb90a67"
    private let earlier = "442869b6-60df-4b59-b572-c2ac85566e2a"
    private let pid: Int32 = 24680

    private final class Clock {
        var elapsed: TimeInterval = 0
        var waits: [TimeInterval] = []
        func sleep(_ interval: TimeInterval) { elapsed += interval; waits.append(interval) }
    }

    private func registryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeRegistry(_ directory: URL, session: String, workspace: String = "/tmp") throws {
        let file = directory.appendingPathComponent("\(pid).json")
        try JSONSerialization.data(withJSONObject: ["pid": pid, "sessionId": session, "cwd": workspace]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func writeDuringWait(_ directory: URL) {
        do { try writeRegistry(directory, session: session) }
        catch { XCTFail(error.localizedDescription) }
    }

    private func discover(_ directory: URL, provider: String = "claude", environment: [String: String]? = nil) -> NativeSessionDiscovery {
        NativeSessionContext.discovery(host: (provider, pid), environment: environment ?? ["CLAUDE_SESSION_ID": session],
            currentDirectory: "/tmp/project", registryDirectory: directory)
    }

    private var mismatch: ChecklistError { ChecklistError(ClaudeRegistryStart.errorCode, ClaudeRegistryStart.registryMessage) }

    private func pending(_ state: inout ClaudeRegistryStart, clock: Clock) throws {
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { .claudeRegistryNotReady(.absent) }, bootstrap: { _, _ in XCTFail("No verified context"); return nil })
        XCTAssertNil(result)
    }

    func testExactServiceRegistryMismatchRepeatsDiscoveryAndBootstrap() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), attempts = 0, bootstraps = 0
        var environment = ["CLAUDE_SESSION_ID": session]
        let result = try state.start(command: "connect", assistantRelay: false, now: { clock.elapsed }, sleep: {
            clock.sleep($0)
            environment = ["CLAUDE_CODE_SESSION_ID": self.session]
            self.writeDuringWait(directory)
        }, discover: { attempts += 1; return self.discover(directory, environment: environment) }, bootstrap: { (context, _) -> String? in
            bootstraps += 1
            if bootstraps == 1 {
                try self.writeRegistry(directory, session: self.earlier)
                throw self.mismatch
            }
            return context?.nativeSessionID
        })
        XCTAssertEqual(result, session)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(bootstraps, 2)
    }

    func testLazyTransientFailureMakesOneAttemptAndRetainsLatestError() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart()
        try pending(&state, clock: clock)
        let latest = ChecklistError(ClaudeRegistryStart.errorCode, ClaudeRegistryStart.registryMessage, details: ["command_id": "latest"])
        var attempts = 0
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { self.discover(directory) }, bootstrap: { _ -> String? in attempts += 1; throw latest }))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(clock.elapsed, 10)
        XCTAssertEqual(state.error?.localizedDescription, latest.localizedDescription)
        XCTAssertTrue(state.mayRetry)
    }

    func testLazyPermanentFailureEndsAttemptsAndKeepsError() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart()
        try pending(&state, clock: clock)
        let revoked = ChecklistError("CONNECTION_REVOKED", "The owner disconnected this thread in Checklist. It cannot reconnect automatically.")
        var attempts = 0
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { self.discover(directory) }, bootstrap: { _ -> String? in attempts += 1; throw revoked }))
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { XCTFail("Permanent failure must stop discovery"); return .noHost }, bootstrap: { _ -> String? in nil }))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state.error?.localizedDescription, revoked.localizedDescription)
        XCTAssertEqual(state.connection?["state"] as? String, "connection_failed")
    }

    func testLossOfNativeContextDoesNotFallBackToStoredConnection() throws {
        var state = ClaudeRegistryStart()
        let clock = Clock()
        try pending(&state, clock: clock)
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { .noHost }, bootstrap: { _ -> String? in
            XCTFail("Lost context must stay unconnected"); return "stored"
        }))
        XCTAssertEqual(state.error?.localizedDescription, mismatch.localizedDescription)
        XCTAssertFalse(state.mayRetry)
    }

    func testInitialMissingHostKeepsExistingNoContextBehavior() throws {
        var state = ClaudeRegistryStart(), attempts = 0
        let clock = Clock()
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { .noHost }, bootstrap: { context, _ in attempts += 1; XCTAssertNil(context); return nil })
        XCTAssertNil(result)
        XCTAssertNil(state.notice)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testPermanentStartupErrorsPropagateWithoutWait() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        let errors = [
            ChecklistError("CONNECTION_REVOKED", "revoked"), ChecklistError("WORKSPACE_MISMATCH", "workspace"),
            ChecklistError("NATIVE_HOST_REQUIRED", "host"), ChecklistError("NATIVE_CLIENT_REQUIRED", "client"),
            ChecklistError("NATIVE_ROUTE_MISMATCH", "route"), ChecklistError("OUTCOME_UNKNOWN", "unknown"),
            ChecklistError("NATIVE_SESSION_MISMATCH", "This reported thread was connected by a different native host process. Its claims and messages cannot be borrowed."),
            ChecklistError("NATIVE_SESSION_MISMATCH", "This thread's earlier process has no verified closure yet. Its claims and messages cannot be borrowed."),
            ChecklistError("NATIVE_SESSION_MISMATCH", "This connection belongs to another native host process."),
            ChecklistError("NATIVE_SESSION_MISMATCH", "A resumed conversation needs a new verified process and a new connection generation."),
            ChecklistError("NATIVE_SESSION_MISMATCH", ClaudeRegistryStart.registryMessage + " "),
            ChecklistError("OTHER", ClaudeRegistryStart.registryMessage)
        ]
        for error in errors {
            var state = ClaudeRegistryStart(), attempts = 0
            let clock = Clock()
            XCTAssertThrowsError(try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                discover: { self.discover(directory) }, bootstrap: { (_, _) -> String? in attempts += 1; throw error })) {
                XCTAssertEqual($0.localizedDescription, error.localizedDescription)
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(clock.waits.isEmpty)
        }
    }

    func testCodexAndAssistantRelayDoNotRetryRegistryError() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        for (provider, relay) in [("codex", false), ("claude", true)] {
            var state = ClaudeRegistryStart(), attempts = 0
            let clock = Clock()
            XCTAssertThrowsError(try state.start(command: "mcp", assistantRelay: relay, now: { clock.elapsed }, sleep: clock.sleep,
                discover: { self.discover(directory, provider: provider, environment: ["CLAUDE_SESSION_ID": self.session, "CODEX_THREAD_ID": self.session]) },
                bootstrap: { (_, _) -> String? in attempts += 1; throw self.mismatch }))
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(clock.waits.isEmpty)
        }
    }

    func testProjectSetupErrorKeepsUnregisteredWorkspacePolicy() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        for command in ["mcp", "tools"] {
            var state = ClaudeRegistryStart(), attempts = 0
            let clock = Clock()
            let result: String? = try state.start(command: command, assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                discover: { self.discover(directory) }, bootstrap: { _, _ in
                    attempts += 1
                    if UnregisteredWorkspaceStart.applies(errorCode: "PROJECT_SETUP_REQUIRED", command: command, assistantRelay: false) { return nil }
                    throw ChecklistError("PROJECT_SETUP_REQUIRED", "unregistered")
                })
            XCTAssertNil(result)
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(clock.waits.isEmpty)
            XCTAssertNil(state.notice)
        }
        for command in ["connect", "call"] {
            var state = ClaudeRegistryStart(), attempts = 0
            let clock = Clock()
            XCTAssertThrowsError(try state.start(command: command, assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                discover: { self.discover(directory) }, bootstrap: { (_, _) -> String? in attempts += 1; throw ChecklistError("PROJECT_SETUP_REQUIRED", "unregistered") }))
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(clock.waits.isEmpty)
        }
    }

    func testDiscoveryReasonsDoNotBroadenRetryClass() throws {
        let directory = try registryDirectory()
        XCTAssertEqual(NativeSessionContext.discovery(host: nil, environment: [:], currentDirectory: "/tmp", registryDirectory: directory), .noHost)
        XCTAssertEqual(discover(directory, environment: [:]), .unavailable)
        XCTAssertEqual(discover(directory, environment: ["CLAUDE_SESSION_ID": "invalid"]), .unavailable)
        try writeRegistry(directory, session: session, workspace: "/var")
        XCTAssertEqual(discover(directory), .claudeRegistryNotReady(.outsideWorkspace))
        try writeRegistry(directory, session: session)
        let file = directory.appendingPathComponent("\(pid).json")
        var record = ["pid": pid, "sessionId": session, "cwd": "/tmp", "messagingSocketPath": "/tmp/one.sock"] as [String: Any]
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        XCTAssertEqual(discover(directory, environment: ["CLAUDE_SESSION_ID": session, "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/two.sock"]), .unavailable)
        record["sessionId"] = nil
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        XCTAssertEqual(discover(directory), .unavailable)
    }

    func testDiscoveryReportsEachClientRegistryReason() throws {
        let directory = try registryDirectory()
        XCTAssertEqual(discover(directory), .claudeRegistryNotReady(.absent))
        XCTAssertEqual(discover(directory).registryReason?.rawValue, "registry absent")
        try writeRegistry(directory, session: earlier)
        XCTAssertEqual(discover(directory), .claudeRegistryNotReady(.otherSession))
        XCTAssertEqual(discover(directory).registryReason?.rawValue, "registry names another session")
        try writeRegistry(directory, session: session, workspace: "/var")
        XCTAssertEqual(discover(directory), .claudeRegistryNotReady(.outsideWorkspace))
        XCTAssertEqual(discover(directory).registryReason?.rawValue, "registry cwd outside the workspace")
        try writeRegistry(directory, session: session)
        XCTAssertNil(discover(directory).registryReason)
        XCTAssertNotNil(discover(directory).context)
    }

    func testServiceMismatchHasDistinctDiagnosticReason() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), bootstraps = 0
        let result = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { self.discover(directory) }, bootstrap: { (context, _) -> String? in
                bootstraps += 1
                if bootstraps == 1 { throw self.mismatch }
                return context?.nativeSessionID
            })
        XCTAssertEqual(result, session)
        XCTAssertEqual(state.firstReason, .serviceMismatch)
        XCTAssertEqual(state.lastReason, .serviceMismatch)
        XCTAssertEqual(state.takeRecoverySummary(), "connected after 2 attempts in 250 ms; Claude's session registry was not ready at first (service registry mismatch).")
    }

    func testStartupRecoverySummaryHasCountTimeAndOneLine() throws {
        let directory = try registryDirectory(), clock = Clock()
        var state = ClaudeRegistryStart(), waits = 0
        let result = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: {
            clock.sleep($0); waits += 1
            if waits == 2 { self.writeDuringWait(directory) }
        }, discover: { self.discover(directory) }, bootstrap: { context, _ in
            clock.elapsed += 0.112
            return context?.nativeSessionID
        })
        XCTAssertEqual(result, session)
        let summary = try XCTUnwrap(state.takeRecoverySummary())
        XCTAssertEqual(summary, "connected after 3 attempts in 612 ms; Claude's session registry was not ready at first (registry absent).")
        XCTAssertFalse(summary.contains("\n")); XCTAssertFalse(summary.contains("\r"))
        for secret in [session, earlier, String(pid), directory.path, "/tmp/project"] { XCTAssertFalse(summary.contains(secret)) }
        XCTAssertNil(state.takeRecoverySummary())
    }

    func testRecoverySummaryNamesFirstAndLastReasonsAfterAnyChange() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        let sequences: [[ClaudeRegistryReason]] = [[.absent, .otherSession], [.absent, .otherSession, .absent]]
        for reasons in sequences {
            let clock = Clock()
            var state = ClaudeRegistryStart(), index = 0
            let result = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                discover: {
                    defer { index += 1 }
                    if index < reasons.count { return .claudeRegistryNotReady(reasons[index]) }
                    return self.discover(directory)
                }, bootstrap: { context, _ in context?.nativeSessionID })
            XCTAssertEqual(result, session)
            let last = try XCTUnwrap(reasons.last)
            XCTAssertEqual(state.takeRecoverySummary(), "connected after \(reasons.count + 1) attempts in \(reasons.count * 250) ms; Claude's session registry was not ready at first (registry absent). Last reason: \(last.rawValue).")
            XCTAssertNil(state.takeRecoverySummary())
        }
    }

    func testLazyRecoverySummaryCountsStartupAndLazyAttemptsOnce() throws {
        let directory = try registryDirectory(), clock = Clock()
        var state = ClaudeRegistryStart()
        try pending(&state, clock: clock)
        XCTAssertNil(state.takeRecoverySummary())
        clock.elapsed += 2
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { .claudeRegistryNotReady(.otherSession) }, bootstrap: { _ -> String? in nil }))
        try writeRegistry(directory, session: session)
        clock.elapsed += 0.125
        XCTAssertTrue(state.retry(now: { clock.elapsed }, discover: { self.discover(directory) }, bootstrap: { $0?.nativeSessionID }))
        XCTAssertEqual(state.takeRecoverySummary(), "connected after 42 attempts in 12125 ms; Claude's session registry was not ready at first (registry absent). Last reason: registry names another session.")
        XCTAssertNil(state.takeRecoverySummary())
        XCTAssertFalse(state.retry(now: { clock.elapsed }, discover: { XCTFail("No attempt after success"); return .noHost }, bootstrap: { _ -> String? in nil }))
        XCTAssertNil(state.takeRecoverySummary())
        XCTAssertEqual(clock.waits.count, 40)
    }

    func testExhaustedStartupNoticeGivesLastReasonAndKeepsToolNotice() throws {
        let clock = Clock()
        var state = ClaudeRegistryStart(), attempts = 0
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: {
                attempts += 1
                return .claudeRegistryNotReady(attempts == 1 ? .absent : .outsideWorkspace)
            }, bootstrap: { _, _ in nil })
        XCTAssertNil(result)
        let notice = "This conversation is not connected yet. \(mismatch.localizedDescription)"
        XCTAssertEqual(state.notice, notice)
        XCTAssertEqual(state.startupNotice, notice + " Startup wait ended after 40 attempts in 10000 ms; last reason: registry cwd outside the workspace.")
        XCTAssertNil(state.takeRecoverySummary())
    }

    func testNoRecoverySummaryForInitialSuccessOrPermanentFailure() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart()
        let result = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { self.discover(directory) }, bootstrap: { context, _ in context?.nativeSessionID })
        XCTAssertEqual(result, session)
        XCTAssertNil(state.takeRecoverySummary())
        XCTAssertThrowsError(try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { self.discover(directory) }, bootstrap: { (_, _) -> String? in throw ChecklistError("CONNECTION_REVOKED", "revoked") }))
        XCTAssertNil(state.firstReason)
        XCTAssertNil(state.takeRecoverySummary())
    }

    func testSlowFinalRegistryFailureUsesRemainingTotalBudget() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        for command in ["mcp", "tools", "call", "connect"] {
            var state = ClaudeRegistryStart(), starts: [TimeInterval] = [], budgets: [TimeInterval?] = []
            let clock = Clock()
            do {
                let result: String? = try state.start(command: command, assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                    discover: { self.discover(directory) }, bootstrap: { _, budget in
                        starts.append(clock.elapsed); budgets.append(budget)
                        clock.elapsed += budget ?? 9
                        throw self.mismatch
                    })
                XCTAssertEqual(command, "mcp"); XCTAssertNil(result)
                XCTAssertEqual(state.connection?["connected"] as? Bool, false)
            } catch {
                XCTAssertNotEqual(command, "mcp")
                XCTAssertEqual(error.localizedDescription, mismatch.localizedDescription)
            }
            XCTAssertEqual(starts, [0, 9.25])
            XCTAssertTrue(starts.allSatisfy { $0 < 10 })
            XCTAssertNil(budgets[0]); XCTAssertEqual(budgets[1], 10.75)
            XCTAssertEqual(clock.elapsed, 20)
        }
    }

    func testSleepAtDeadlineDoesNotStartAnotherAttempt() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), starts: [TimeInterval] = []
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { self.discover(directory) }, bootstrap: { _, budget in
                starts.append(clock.elapsed); XCTAssertNil(budget)
                clock.elapsed += 9.75
                throw self.mismatch
            })
        XCTAssertNil(result)
        XCTAssertEqual(starts, [0])
        XCTAssertEqual(clock.elapsed, 10)
    }

    func testSlowFinalSuccessStaysWithinTotalBudget() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), starts: [TimeInterval] = []
        let result = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: { self.discover(directory) }, bootstrap: { context, budget in
                starts.append(clock.elapsed)
                clock.elapsed += budget ?? 9
                if budget == nil { throw self.mismatch }
                XCTAssertEqual(budget, 10.75)
                return context?.nativeSessionID
            })
        XCTAssertEqual(result, session)
        XCTAssertEqual(starts, [0, 9.25])
        XCTAssertEqual(clock.elapsed, 20)
        XCTAssertFalse(state.mayRetry)
    }

    func testRetryTimeoutPropagatesWithoutAnotherAttempt() throws {
        let directory = try registryDirectory()
        try writeRegistry(directory, session: session)
        for command in ["mcp", "tools", "call", "connect"] {
            let clock = Clock()
            var state = ClaudeRegistryStart(), attempts = 0
            XCTAssertThrowsError(try state.start(command: command, assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
                discover: { self.discover(directory) }, bootstrap: { (_, budget) -> String? in
                    attempts += 1
                    clock.elapsed += budget ?? 9
                    if budget == nil { throw self.mismatch }
                    throw CommandReply.unknown(commandID: nil, reason: "reply_timeout")
                })) { XCTAssertEqual(($0 as? ChecklistError)?.code, "OUTCOME_UNKNOWN") }
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(clock.elapsed, 20)
            XCTAssertFalse(state.mayRetry)
        }
    }

    func testRetryBudgetAlsoAccountsForDiscoveryTime() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), discoveries = 0
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: {
                discoveries += 1
                if discoveries == 2 { clock.elapsed += 0.5 }
                return self.discover(directory)
            }, bootstrap: { _, budget in
                if budget == nil { clock.elapsed += 9 }
                else { XCTAssertEqual(budget, 10.25); clock.elapsed += try XCTUnwrap(budget) }
                throw self.mismatch
            })
        XCTAssertNil(result)
        XCTAssertEqual(discoveries, 2)
        XCTAssertEqual(clock.elapsed, 20)
    }

    func testDiscoveryAtDeadlineDoesNotStartBootstrap() throws {
        let directory = try registryDirectory(), clock = Clock()
        try writeRegistry(directory, session: session)
        var state = ClaudeRegistryStart(), discoveries = 0, bootstraps = 0
        let result: String? = try state.start(command: "mcp", assistantRelay: false, now: { clock.elapsed }, sleep: clock.sleep,
            discover: {
                discoveries += 1
                if discoveries == 2 { clock.elapsed += 0.75 }
                return self.discover(directory)
            }, bootstrap: { _, budget in
                bootstraps += 1; XCTAssertNil(budget)
                clock.elapsed += 9
                throw self.mismatch
            })
        XCTAssertNil(result)
        XCTAssertEqual(bootstraps, 1)
        XCTAssertEqual(discoveries, 2)
        XCTAssertEqual(clock.elapsed, 10)
    }
}
