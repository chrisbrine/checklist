import XCTest
import Security
import ChecklistIPC
@testable import ChecklistApp

final class HumanClaimsKeychainTests: XCTestCase {
    func testEveryOperationReceivesNoUIQueryAndRestoresInteractionSetting() throws {
        // The wrapper is used for every read/add/update/delete in both stores.
        var original: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(original.boolValue) }
        for allowed in [false, true] {
            XCTAssertEqual(SecKeychainSetUserInteractionAllowed(allowed), errSecSuccess)
            let result = KeychainWithoutUI.perform([kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow]) { query in
                let query = query as NSDictionary
                XCTAssertEqual(query[kSecUseAuthenticationUI] as? String, kSecUseAuthenticationUIFail as String)
                var current: DarwinBoolean = true
                XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&current), errSecSuccess)
                XCTAssertFalse(current.boolValue)
                return errSecAuthFailed
            }
            XCTAssertEqual(result, errSecAuthFailed)
            var restored: DarwinBoolean = false
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
            XCTAssertEqual(restored.boolValue, allowed, "Restore even on an unsuccessful operation")
        }
    }

    func testConcurrentOperationsSerializeInteractionFlag() {
        let state = NSLock()
        var active = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let status = KeychainWithoutUI.perform([:]) { _ in
                state.lock()
                active += 1
                XCTAssertEqual(active, 1)
                state.unlock()
                var allowed: DarwinBoolean = true
                XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
                XCTAssertFalse(allowed.boolValue)
                state.lock()
                active -= 1
                state.unlock()
                return errSecSuccess
            }
            XCTAssertEqual(status, errSecSuccess)
        }
    }

    func testRecoveryAccountsUseV2AndClaimAccountsStayUnchanged() {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        XCTAssertEqual(WorkspaceWindowIdentity.primary.pendingCommandKey, "pending-command-v2")
        XCTAssertEqual(WorkspaceWindowIdentity.workspace(id).pendingCommandKey,
                       "pending-command-v2-window-abcdef01-2345-6789-abcd-ef0123456789")
        XCTAssertEqual(HumanClaims.query(id.uuidString)[kSecAttrAccount as String] as? String, id.uuidString)
    }

    @MainActor func testUnreadableRecoveryIsAbsentWithoutBannerOrRequestAndDefaultUsesV2() throws {
        let defaults = isolatedDefaults("UnreadablePendingClaim")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var accounts: [String] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: defaults.preferences,
                                   desktopAlerts: DesktopAlertCoordinator(sink: KeychainTestNoAlerts()),
                                   requestTransport: { _, _ in XCTFail("Absent recovery must not send a command"); return [:] },
                                   pendingCommandPersistence: .init(read: { accounts.append($0); return nil },
                                                                    save: { _, _ in XCTFail("Must not save on launch") },
                                                                    remove: { _ in XCTFail("Must not remove on launch") }))
        defer { store.stopWindowReads(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(accounts, ["pending-command-v2"])
        XCTAssertFalse(store.hasPendingMutation)
        XCTAssertNil(store.pendingCommandID)
        XCTAssertNil(store.error)
    }

    func testForeignACLReadReturnsNilWithinTwoSecondsInTemporaryKeychain() throws {
        // #filePath lives in the scratch checkout. Never change the search list or
        // use the default/login keychain for any fixture operation.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".CL-195-keychain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var created: SecKeychain?
        let password = "temporary-fixture-password"
        let createStatus = KeychainWithoutUI.perform([:]) { _ in
            password.withCString { bytes in
                SecKeychainCreate(root.appendingPathComponent("fixture.keychain-db").path,
                                  UInt32(password.utf8.count), bytes, false, nil, &created)
            }
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        let keychain = try XCTUnwrap(created, "Temporary keychain creation failed: \(createStatus)")
        defer { XCTAssertEqual(KeychainWithoutUI.perform([:]) { _ in SecKeychainDelete(keychain) }, errSecSuccess) }

        var access: SecAccess?
        XCTAssertEqual(SecAccessCreate("CL-195 foreign fixture" as CFString, [] as CFArray, &access), errSecSuccess)
        let foreignAccess = try XCTUnwrap(access)
        var foreign: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: HumanClaims.service,
                                      kSecAttrAccount as String: "pending-command",
                                      kSecValueData as String: Data("must-not-be-readable".utf8),
                                      kSecAttrAccess as String: foreignAccess,
                                      kSecUseKeychain as String: keychain]
        XCTAssertEqual(KeychainWithoutUI.perform(foreign) { SecItemAdd($0, nil) }, errSecSuccess)
        foreign.removeValue(forKey: kSecValueData as String)
        foreign.removeValue(forKey: kSecAttrAccess as String)
        foreign.removeValue(forKey: kSecUseKeychain as String)
        foreign[kSecMatchSearchList as String] = [keychain]
        // Confirm this is an existing item, rather than a false pass from a bad query.
        var metadata = foreign
        metadata[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(KeychainWithoutUI.perform(metadata) { SecItemCopyMatching($0, &attributes) }, errSecSuccess)
        XCTAssertNotNil(attributes)

        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(HumanClaims.read(query: foreign), "The test runner must not be trusted by the empty ACL")
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 2)
        print("CL-195 foreign ACL read returned nil in \(elapsed) seconds (temporary file-based keychain)")

        // The stale account can coexist with the replacement recovery account.
        var own = HumanClaims.query(WorkspaceWindowIdentity.primary.pendingCommandKey)
        own[kSecUseKeychain as String] = keychain
        own[kSecMatchSearchList as String] = [keychain]
        try HumanClaims.save("replacement", query: own)
        XCTAssertEqual(HumanClaims.read(query: own), "replacement")
        HumanClaims.remove(query: own)
        XCTAssertNil(HumanClaims.read(query: own))
        XCTAssertNil(HumanClaims.read(query: foreign))
    }
}

@MainActor private final class KeychainTestNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { XCTFail("No launch alert"); return false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("No launch alert") }
    func remove(_ identifiers: [String]) {}
}
