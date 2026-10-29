import ChecklistTestSupport
import XCTest
import LocalAuthentication
import Security
@testable import ChecklistApp
@testable import ChecklistCore
import ChecklistIPC

@MainActor final class PendingCommandRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL, defaults: IsolatedDefaults, router: CommandRouter
        let owner = Caller(role: "owner", installation: "recovery-fixture", projectIDs: [])
        let identity = "org.checklist.coordination"
        let account = "synthetic-recovery"
        var saved: String?
        var unreadable = false
        var failRead = false
        var retryIncarnation: String?
        var pageIncarnation: String?
        var holdIdentity = false
        var heldIdentity: CheckedContinuation<[String: Any], Never>?
        var identityReply: [String: Any]?
        var loseReply = false
        var upgradingBeforeMutation = false
        var calls: [(String, [String: Any])] = []
        var removals = 0
        let incarnation: String
        init(defaults: IsolatedDefaults) throws {
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/recovery-" + UUID().uuidString)
            self.defaults = defaults
            router = try TestStore.router(root: root)
            let info = try router.handle(method: "service_info", params: [:], caller: owner)["data"] as! [String: Any]
            incarnation = info["store_incarnation"] as! String
            defaults.preferences.set(Page.epics.rawValue, forKey: "lastPage")
        }
        func record(incarnation: String? = nil, identity: String? = nil) -> PendingCommandRecovery {
            PendingCommandRecovery(method: "project_create", params: ["command_id": UUID().uuidString, "name": "Recovered project"],
                                   storeIncarnation: incarnation ?? self.incarnation, serviceIdentity: identity ?? self.identity)
        }
        func store(restore: Bool = true, account: String? = nil) -> ChecklistStore {
            ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: defaults.preferences,
                           restorePendingCommand: restore, desktopAlerts: DesktopAlertCoordinator(sink: RecoveryNoAlerts()),
                           requestTransport: { [self] method, params in
                calls.append((method, params))
                if failRead, CommandReply.readMethods.contains(method) { throw ChecklistError("SERVICE_UNAVAILABLE", "Synthetic failed identity read") }
                if upgradingBeforeMutation, !CommandReply.readMethods.contains(method) {
                    throw StorageUpgradeStatus(stage:"final_migration",estimatedRemainingSeconds:90)!.error(commandID:params["command_id"] as? String)
                }
                var reply = try router.handle(method: method, params: appFixtureTaskInput(router,method:method,input:params), caller: owner)
                if method == "service_info", let retryIncarnation {
                    var data = reply["data"] as! [String: Any]; data["store_incarnation"] = retryIncarnation; reply["data"] = data
                }
                if method == "workspace_page", let pageIncarnation {
                    var data = reply["data"] as! [String: Any]
                    var service = data["service"] as! [String: Any]; service["store_incarnation"] = pageIncarnation
                    data["service"] = service; reply["data"] = data
                }
                if method == "service_info", holdIdentity {
                    identityReply = reply
                    return await withCheckedContinuation { heldIdentity = $0 }
                }
                if loseReply, method == "project_create" { throw CommandReply.unknown(commandID: params["command_id"] as? String, reason: "synthetic_lost_reply") }
                return reply
            }, navigationMemory: DetailItemNavigationMemory(), pendingCommandKey: account ?? self.account,
                           pendingCommandPersistence: .init(read: { [self] _ in
                if unreadable { throw NSError(domain: "SyntheticUnreadableRecovery", code: 1) }
                return saved
            }, save: { [self] value, _ in saved = value }, remove: { [self] _ in saved = nil; removals += 1 }),
                           pendingCommandServiceIdentity: identity)
        }
        var mutations: [(String, [String: Any])] { calls.filter { CommandReply.expectsMutation($0.0) } }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func settled(_ store: ChecklistStore) async throws {
        for _ in 0..<600 {
            if !store.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Bounded recovery check did not finish")
    }

    func testNewSaveBindsToServiceAndStoreAndOwnRecoveryKeepsOriginalCommand() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }
        let first = f.store(restore: false); defer { first.stopWindowReads() }
        await first.refresh(); XCTAssertTrue(first.connected)
        f.loseReply = true
        first.run("project_create", ["name": "Saved once"])
        try await settled(first)
        XCTAssertTrue(first.hasPendingMutation)
        let original = try XCTUnwrap(first.pendingCommandID), saved = try XCTUnwrap(f.saved)
        let record = try XCTUnwrap(PendingCommandRecovery(saved: saved))
        XCTAssertEqual(record.storeIncarnation, f.incarnation); XCTAssertEqual(record.serviceIdentity, f.identity)
        XCTAssertEqual(record.params["command_id"] as? String, original)
        let restored = f.store(); defer { restored.stopWindowReads() }
        XCTAssertFalse(restored.hasPendingMutation); XCTAssertNil(restored.pendingCommandID)
        await restored.refresh()
        XCTAssertTrue(restored.hasPendingMutation); XCTAssertEqual(restored.pendingCommandID, original)
        XCTAssertEqual(f.mutations.count, 1, "Launching and connecting never sends the recovered command")
        f.loseReply = false
        restored.retryPendingMutation(); try await settled(restored)
        XCTAssertFalse(restored.hasPendingMutation); XCTAssertNil(f.saved)
        XCTAssertEqual(f.removals, 1); XCTAssertEqual(f.mutations.count, 2)
        XCTAssertEqual(f.mutations[1].1["command_id"] as? String, original)
        let projects = try f.router.handle(method: "project_list", params: [:], caller: f.owner)["data"] as! [String: Any]
        XCTAssertEqual((projects["projects"] as? [[String: Any]])?.count, 1, "The original receipt prevents a duplicate project")
    }

    func testUpgradeBeforeRetryDoesNotEraseEarlierUnresolvedCommand() async throws {
        let f = try Fixture(defaults:isolatedDefaults("PendingUpgradeRetry"));defer {f.cleanup()}
        let store = f.store(restore:false);defer {store.stopWindowReads()}
        await store.refresh();f.loseReply = true
        store.run("project_create",["name":"Saved before upgrade"]);try await settled(store)
        let original = try XCTUnwrap(store.pendingCommandID),saved = try XCTUnwrap(f.saved)
        XCTAssertTrue(store.hasPendingMutation)
        f.loseReply = false;f.upgradingBeforeMutation = true
        store.retryPendingMutation();try await settled(store)
        XCTAssertTrue(store.hasPendingMutation,"This retry was not sent, but the earlier attempt is still unresolved")
        XCTAssertEqual(store.pendingCommandID,original);XCTAssertEqual(f.saved,saved);XCTAssertEqual(f.removals,0)
        f.upgradingBeforeMutation = false;await store.refresh()
        store.retryPendingMutation();try await settled(store)
        XCTAssertFalse(store.hasPendingMutation);XCTAssertNil(f.saved);XCTAssertEqual(f.removals,1)
        let projects = try f.router.handle(method:"project_list",params:[:],caller:f.owner)["data"] as! [String:Any]
        XCTAssertEqual((projects["projects"] as? [[String:Any]])?.count,1,"Reconcile the original receipt without duplicating the project")
    }

    func testOlderIncarnationOtherServiceAndTestSlotAreIgnoredOnceAndNeverSent() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }
        for record in [f.record(incarnation: "pre-restore-incarnation"), f.record(identity: "other-installation"),
                       f.record(identity: "org.checklist.test1.coordination")] {
            f.saved = try record.encoded()
            let store = f.store(); defer { store.stopWindowReads() }
            XCTAssertFalse(store.hasPendingMutation); XCTAssertNil(store.pendingCommandID)
            await store.refresh()
            XCTAssertFalse(store.hasPendingMutation); XCTAssertNil(store.pendingCommandID)
            XCTAssertEqual(store.notice, "Checklist ignored a saved change from a different store or installation. It will not be sent to this store.")
            XCTAssertTrue(store.noticeIsWarning); XCTAssertNil(store.error)
            let retained = f.saved
            store.notice = nil; await store.refresh(); store.retryPendingMutation()
            XCTAssertNil(store.notice); XCTAssertEqual(f.saved, retained)
            let relaunched = f.store(); defer { relaunched.stopWindowReads() }; await relaunched.refresh()
            XCTAssertNil(relaunched.notice); XCTAssertFalse(relaunched.hasPendingMutation)
        }
        XCTAssertTrue(f.mutations.isEmpty); XCTAssertEqual(f.removals, 0)
    }

    func testUnreadableItemReportsOnceAcrossLaunchesAndAbsenceStartsANewInterval() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }; f.unreadable = true
        let store = f.store(); defer { store.stopWindowReads() }
        XCTAssertFalse(store.hasPendingMutation); XCTAssertNil(store.pendingCommandID)
        XCTAssertEqual(store.notice, "Checklist ignored a saved change it could not read safely. It will not be sent.")
        XCTAssertTrue(store.noticeIsWarning); XCTAssertNil(store.error)
        store.notice = nil; await store.refresh(); store.retryPendingMutation(); XCTAssertNil(store.notice)
        let again = f.store(); defer { again.stopWindowReads() }; await again.refresh(); XCTAssertNil(again.notice)
        f.unreadable = false; f.saved = try f.record().encoded()
        let readable = f.store(); defer { readable.stopWindowReads() }; await readable.refresh()
        XCTAssertTrue(readable.hasPendingMutation)
        f.unreadable = true
        let afterReadable = f.store(); defer { afterReadable.stopWindowReads() }; XCTAssertNotNil(afterReadable.notice)
        f.unreadable = false; f.saved = nil
        let absent = f.store(); defer { absent.stopWindowReads() }; XCTAssertNil(absent.notice)
        f.unreadable = true
        let newInterval = f.store(); defer { newInterval.stopWindowReads() }; XCTAssertNotNil(newInterval.notice)
        XCTAssertTrue(f.mutations.isEmpty); XCTAssertEqual(f.removals, 0)
    }

    func testMalformedAndLegacyUnboundItemsAreRetainedAndReportedOnce() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }
        for saved in ["not JSON", "{\"method\":\"project_create\",\"params\":{\"command_id\":\"" + UUID().uuidString + "\",\"name\":\"Unbound\"}}"] {
            f.saved = saved
            let store = f.store(); defer { store.stopWindowReads() }; await store.refresh()
            XCTAssertTrue(store.noticeIsWarning); XCTAssertTrue(store.notice?.contains("could not read safely") == true)
            XCTAssertFalse(store.hasPendingMutation); XCTAssertEqual(f.saved, saved)
            let again = f.store(); defer { again.stopWindowReads() }; await again.refresh(); XCTAssertNil(again.notice)
        }
        XCTAssertTrue(f.mutations.isEmpty); XCTAssertEqual(f.removals, 0)
    }

    func testUnverifiedRecoveryCannotBeOverwrittenAndSurvivesFailedConnection() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }; f.saved = try f.record().encoded()
        let store = f.store(); defer { store.stopWindowReads() }; let saved = f.saved
        f.failRead = true; await store.refresh()
        XCTAssertFalse(store.hasPendingMutation)
        store.connected = true // Even an incidental health flag cannot authorize unverified recovery.
        store.run("project_create", ["name": "Must not replace recovery"])
        XCTAssertEqual(f.saved, saved); XCTAssertTrue(f.mutations.isEmpty)
        f.failRead = false; await store.refresh()
        XCTAssertTrue(store.hasPendingMutation)
    }

    func testRetryRefusesAnIncarnationChangedSinceOfferAndKeepsItem() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }; f.saved = try f.record().encoded()
        let store = f.store(); defer { store.stopWindowReads() }; await store.refresh()
        XCTAssertTrue(store.hasPendingMutation)
        f.retryIncarnation = "restored-between-read-and-click"
        store.retryPendingMutation(); try await settled(store)
        XCTAssertEqual(f.calls.last?.0, "service_info"); XCTAssertTrue(f.mutations.isEmpty)
        XCTAssertFalse(store.hasPendingMutation); XCTAssertNotNil(f.saved); XCTAssertTrue(store.noticeIsWarning)
        store.notice = nil; store.retryPendingMutation(); XCTAssertNil(store.notice)
    }

    func testConcurrentStoreChangeFencesASuspendedRetry() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }; f.saved = try f.record().encoded()
        let store = f.store(); defer { store.stopWindowReads() }; await store.refresh()
        f.holdIdentity = true; store.retryPendingMutation()
        for _ in 0..<600 where f.heldIdentity == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let held = try XCTUnwrap(f.heldIdentity)
        f.pageIncarnation = "concurrently-restored-store"; await store.refresh()
        XCTAssertFalse(store.hasPendingMutation); XCTAssertTrue(store.noticeIsWarning)
        held.resume(returning: fixtureReply(try XCTUnwrap(f.identityReply))); f.heldIdentity = nil
        try await settled(store)
        XCTAssertFalse(store.hasPendingMutation); XCTAssertTrue(f.mutations.isEmpty)
        XCTAssertNotNil(f.saved); XCTAssertTrue(store.noticeIsWarning)
    }

    func testFailedRetryIdentityReadPreservesOriginalWithoutSending() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }; f.saved = try f.record().encoded()
        let store = f.store(); defer { store.stopWindowReads() }; await store.refresh()
        let commandID = store.pendingCommandID, saved = f.saved
        f.failRead = true; store.retryPendingMutation(); try await settled(store)
        XCTAssertTrue(store.hasPendingMutation); XCTAssertEqual(store.pendingCommandID, commandID)
        XCTAssertEqual(f.saved, saved); XCTAssertTrue(f.mutations.isEmpty); XCTAssertNotNil(store.error)
        f.failRead = false; store.retryPendingMutation(); try await settled(store)
        XCTAssertFalse(store.hasPendingMutation); XCTAssertEqual(f.mutations.count, 1)
    }

    func testUnknownStoreBlocksNewSaveAndNoticesAreWindowScoped() async throws {
        let f = try Fixture(defaults: isolatedDefaults("PendingCommandRecovery")); defer { f.cleanup() }
        let store = f.store(restore: false); defer { store.stopWindowReads() }; store.connected = true
        store.run("project_create", ["name": "Unknown store"])
        XCTAssertNil(f.saved); XCTAssertTrue(f.mutations.isEmpty); XCTAssertTrue(store.noticeIsWarning)
        f.unreadable = true
        let first = f.store(), second = f.store(account: "different-window")
        defer { first.stopWindowReads(); second.stopWindowReads() }
        XCTAssertNotNil(first.notice); XCTAssertNotNil(second.notice)
    }

    func testKeychainRecoveryDistinguishesAbsenceFailureAndMalformedBytesWithoutUI() throws {
        XCTAssertNil(try HumanClaims.readRecovery(query: [:], copyMatching: { query, _ in
            XCTAssertTrue(((query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
            return errSecItemNotFound
        }))
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            XCTAssertThrowsError(try HumanClaims.readRecovery(query: [:], copyMatching: { _, _ in status }))
        }
        XCTAssertThrowsError(try HumanClaims.readRecovery(query: [:], copyMatching: { _, item in
            item.pointee = Data([0xff]) as CFData; return errSecSuccess
        }))
        XCTAssertThrowsError(try HumanClaims.readRecovery(query: [:], copyMatching: { _, _ in errSecSuccess }))
        XCTAssertEqual(try HumanClaims.readRecovery(query: [:], copyMatching: { _, item in
            item.pointee = Data("saved change".utf8) as CFData; return errSecSuccess
        }), "saved change")
    }

    func testRecoveryIdentityComparisonsAreByteExact() {
        let record = PendingCommandRecovery(method: "task_edit", params: [:], storeIncarnation: "é", serviceIdentity: "é")
        XCTAssertTrue(record.matches(storeIncarnation: "é", serviceIdentity: "é"))
        XCTAssertFalse(record.matches(storeIncarnation: "e\u{301}", serviceIdentity: "é"))
        XCTAssertFalse(record.matches(storeIncarnation: "é", serviceIdentity: "e\u{301}"))
    }
}

@MainActor private final class RecoveryNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { XCTFail("Recovery must not request alert permission"); return false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Recovery uses one in-app notice") }
    func remove(_ identifiers: [String]) {}
}
