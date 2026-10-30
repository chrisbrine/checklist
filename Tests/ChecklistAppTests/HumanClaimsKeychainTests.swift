import XCTest
import Security
import LocalAuthentication
import ChecklistLegacyKeychain
import ChecklistKeychainTestFixture
import os
@testable import ChecklistIPC
@testable import ChecklistApp

/// CL-373: the app no longer uses this route. The old calls stay here only so that this
/// skipped class keeps its record of the Keychain rules of KeychainWithoutUI (CL-374).
private enum HumanClaims {
    static var service: String { ChecklistInstance.current.humanClaimService }
    static func query(_ attempt: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: attempt]
    }
    static func save(_ token: String, query: [String: Any]) throws {
        KeychainWithoutUI.perform(query) { SecItemDelete($0) }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = KeychainWithoutUI.perform(entry) { SecItemAdd($0, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func read(query: [String: Any]) -> String? { try? readRecovery(query: query) }
    static func readRecovery(query: [String: Any]) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = KeychainWithoutUI.perform(query) { SecItemCopyMatching($0, &item) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    static func remove(query: [String: Any]) { KeychainWithoutUI.perform(query) { SecItemDelete($0) } }
}

final class HumanClaimsKeychainTests: XCTestCase {
    func testEveryOperationReceivesNoUIQueryAndRestoresInteractionSetting() throws {
        // The wrapper is used for every read/add/update/delete in both stores.
        var original: DarwinBoolean = false
        XCTAssertEqual(ChecklistKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { ChecklistKeychainSetUserInteractionAllowed(original.boolValue) }
        for allowed in [false, true] {
            XCTAssertEqual(ChecklistKeychainSetUserInteractionAllowed(allowed), errSecSuccess)
            let result = KeychainWithoutUI.perform([:]) { query in
                let query = query as NSDictionary
                XCTAssertTrue((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
                XCTAssertNil(query[kSecUseAuthenticationUI])
                var current: DarwinBoolean = true
                XCTAssertEqual(ChecklistKeychainGetUserInteractionAllowed(&current), errSecSuccess)
                XCTAssertFalse(current.boolValue)
                return errSecAuthFailed
            }
            XCTAssertEqual(result, errSecAuthFailed)
            var restored: DarwinBoolean = false
            XCTAssertEqual(ChecklistKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
            XCTAssertEqual(restored.boolValue, allowed, "Restore even on an unsuccessful operation")
        }
    }

    func testConcurrentOperationsSerializeInteractionFlag() {
        let active = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let status = KeychainWithoutUI.perform([:]) { _ in
                active.withLock { count in
                    count += 1
                    XCTAssertEqual(count, 1)
                }
                var allowed: DarwinBoolean = true
                XCTAssertEqual(ChecklistKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
                XCTAssertFalse(allowed.boolValue)
                active.withLock { $0 -= 1 }
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
                ChecklistFixtureKeychainCreate(root.appendingPathComponent("fixture.keychain-db").path,
                                  UInt32(password.utf8.count), bytes, false, nil, &created)
            }
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        let keychain = try XCTUnwrap(created, "Temporary keychain creation failed: \(createStatus)")
        defer { XCTAssertEqual(KeychainWithoutUI.perform([:]) { _ in ChecklistFixtureKeychainDelete(keychain) }, errSecSuccess) }

        var access: SecAccess?
        XCTAssertEqual(ChecklistAccessCreate("CL-195 foreign fixture" as CFString, [] as CFArray, &access), errSecSuccess)
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

        // Write exactly the attributes used by the pre-CL-85 HumanClaims save
        // path, without the new wrapper, and read through the production reader.
        // The explicit keychain/search list keep the fixture out of login items.
        var legacy = HumanClaims.query("legacy-claim-" + UUID().uuidString)
        legacy[kSecUseKeychain as String] = keychain
        legacy[kSecValueData as String] = Data("legacy-credential".utf8)
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        legacy.removeValue(forKey: kSecUseKeychain as String)
        legacy.removeValue(forKey: kSecValueData as String)
        legacy.removeValue(forKey: kSecAttrAccessible as String)
        legacy[kSecMatchSearchList as String] = [keychain]
        XCTAssertEqual(try HumanClaims.readRecovery(query: legacy), "legacy-credential")

        // Pairing used the same generic-password attributes plus an executable
        // ACL. Trust this fixture's executable, without consulting login items.
        var pairing = [kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: ChecklistInstance.current.keychainService,
                       kSecAttrAccount as String: "legacy-pairing-" + UUID().uuidString,
                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                       kSecValueData as String: Data("legacy-pairing".utf8),
                       kSecUseKeychain as String: keychain] as [String: Any]
        var application: SecTrustedApplication?
        XCTAssertEqual(ChecklistTrustedApplicationCreateFromPath(nil, &application), errSecSuccess)
        var pairingAccess: SecAccess?
        XCTAssertEqual(ChecklistAccessCreate("Checklist paired local executables" as CFString,
                                       [try XCTUnwrap(application)] as CFArray, &pairingAccess), errSecSuccess)
        pairing[kSecAttrAccess as String] = try XCTUnwrap(pairingAccess)
        XCTAssertEqual(SecItemAdd(pairing as CFDictionary, nil), errSecSuccess)
        for key in [kSecUseKeychain, kSecValueData, kSecAttrAccessible, kSecAttrAccess] {
            pairing.removeValue(forKey: key as String)
        }
        pairing[kSecMatchSearchList as String] = [keychain]
        XCTAssertEqual(try ChecklistKeychain.read(query: pairing), "legacy-pairing")

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
