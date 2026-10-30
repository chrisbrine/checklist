import ChecklistTestSupport
import XCTest
@testable import ChecklistApp
@testable import ChecklistCore
import ChecklistIPC

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CL-373-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777 }
private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// CL-373 file route: temporary folders only. No test here uses the real data root or Keychain.
final class OwnerPrivateFileStoreTests: XCTestCase {
    private var root: URL!
    private var records: OwnerPrivateFileStore!
    private var file: URL { records.directory.appendingPathComponent(records.fileName("pending-command-v2")) }
    override func setUpWithError() throws {
        root = try temporaryFolder()
        records = OwnerPrivateFileStore(directory: root.appendingPathComponent("OwnerPrivate"), kind: OwnerPrivateFileStore.pendingCommandKind)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSaveRestartReadRemoveAndPermissions() throws {
        XCTAssertNil(try records.read("pending-command-v2"), "An absent folder is an absent record")
        try records.save("first", key: "pending-command-v2")
        try records.save("second", key: "pending-command-v2")
        let restarted = OwnerPrivateFileStore(directory: records.directory, kind: records.kind)
        XCTAssertEqual(try restarted.read("pending-command-v2"), "second")
        XCTAssertEqual(try mode(records.directory), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: records.directory.path), [file.lastPathComponent], "One file per key and no temporary copy")
        restarted.remove("pending-command-v2")
        XCTAssertNil(try records.read("pending-command-v2"))
        restarted.remove("pending-command-v2")
    }

    func testFileNamesAreSafeAndKindsAndKeysAreSeparate() throws {
        let hostile = "../../outside/pending"
        XCTAssertNotNil(records.fileName(hostile).range(of: "^pending_command-[0-9a-f]{64}\\.json$", options: .regularExpression))
        let claims = OwnerPrivateFileStore(directory: records.directory, kind: OwnerPrivateFileStore.claimKind)
        try records.save("record", key: hostile)
        try claims.save("credential", key: hostile)
        XCTAssertEqual(try records.read(hostile), "record")
        XCTAssertEqual(try claims.read(hostile), "credential")
        XCTAssertNil(try records.read("other"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    func testStaleStatesNeverBlockASaveAndAreNeverTrustedOnRead() throws {
        try records.save("safe", key: "pending-command-v2")
        // Garbage bytes.
        try Data([0xff, 0x00]).write(to: file)
        XCTAssertThrowsError(try records.read("pending-command-v2"))
        try records.save("after garbage", key: "pending-command-v2")
        XCTAssertEqual(try records.read("pending-command-v2"), "after garbage")
        // A readable file that another account could also read.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try records.read("pending-command-v2")) { XCTAssertEqual(($0 as? OwnerPrivateFileError)?.code, EPERM) }
        try records.save("after mode", key: "pending-command-v2")
        XCTAssertEqual(try mode(file), 0o600)
        // A symbolic link is replaced and its target is not followed.
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try records.read("pending-command-v2")) { XCTAssertEqual(($0 as? OwnerPrivateFileError)?.code, ELOOP) }
        try records.save("after link", key: "pending-command-v2")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(try records.read("pending-command-v2"), "after link")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType, .typeRegular)
        // A crash leaves a temporary copy, and the next save removes it.
        let leftover = records.directory.appendingPathComponent("." + file.lastPathComponent + ".crashed.tmp")
        try Data("old".utf8).write(to: leftover)
        try records.save("after crash", key: "pending-command-v2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        // A file of another key is refused: the record names its key.
        try FileManager.default.copyItem(at: file, to: records.directory.appendingPathComponent(records.fileName("other")))
        XCTAssertThrowsError(try records.read("other"))
        // A wider folder mode is repaired.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: records.directory.path)
        try records.save("after folder", key: "pending-command-v2")
        XCTAssertEqual(try mode(records.directory), 0o700)
    }

    func testLinkedFolderIsRefusedWithTheRealCauseAndNextStep() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: records.directory, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try records.save("value", key: "key")) { error in
            let failure = error as? OwnerPrivateFileError
            // O_DIRECTORY with O_NOFOLLOW reports a linked folder as ENOTDIR on macOS.
            XCTAssertEqual(failure?.code, ENOTDIR)
            XCTAssertEqual(failure?.details["errno"] as? Int, Int(ENOTDIR))
            XCTAssertTrue(failure?.errorDescription?.contains("Move the item named OwnerPrivate") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        XCTAssertThrowsError(try records.read("key"))
    }

    func testEveryFailureNamesItsCauseAndNextStepAndNeverAWorkClaim() {
        let steps: [(Int32, String)] = [(ENOSPC, "Free some disk space"), (EROFS, "writable"), (EACCES, "access"), (EIO, "Try again")]
        for (code, step) in steps {
            let text = OwnerPrivateFileError(operation: "create", code: code).errorDescription ?? ""
            XCTAssertTrue(text.contains(step), text)
            XCTAssertTrue(text.contains("errno \(code)"), text)
            XCTAssertTrue(text.contains(String(cString: strerror(code))), text)
            XCTAssertFalse(text.lowercased().contains("work claim"), text)
            XCTAssertFalse(text.contains("Keychain"), text)
        }
    }

    func testEachInstanceAndWindowUsesItsOwnFile() throws {
        let live = try ChecklistInstance(home: root, environment: [:])
        let slot1 = try ChecklistInstance(slotValue: 1, home: root, environment: [:])
        let slot2 = try ChecklistInstance(slotValue: 2, home: root, environment: [:])
        let folders = [live, slot1, slot2].map(OwnerPrivateFileStore.directory(for:))
        XCTAssertEqual(Set(folders).count, 3)
        XCTAssertEqual(folders[0], live.ownerDataRoot.appendingPathComponent("OwnerPrivate", isDirectory: true))
        XCTAssertEqual(folders[1], slot1.root.appendingPathComponent("OwnerPrivate", isDirectory: true))
        XCTAssertEqual(HumanClaims.store.directory, OwnerPrivateFileStore.directory(for: .current))
        let window = WorkspaceWindowIdentity.workspace(UUID()).pendingCommandKey
        XCTAssertNotEqual(records.fileName(WorkspaceWindowIdentity.primary.pendingCommandKey), records.fileName(window))
    }

    func testClaimCredentialUsesTheFileRouteAndAKeychainOnlyClaimIsSimplyAbsent() throws {
        let instance = try ChecklistInstance(slotValue: 1, home: root, environment: [:])
        let claims = HumanClaims.store(for: instance)
        XCTAssertEqual(claims.kind, OwnerPrivateFileStore.claimKind)
        XCTAssertNil(try claims.read("attempt-only-in-the-old-route"), "Absent, so the callers show their unavailable-credential route")
        try claims.save("token", key: "attempt")
        XCTAssertEqual(try claims.read("attempt"), "token")
        XCTAssertEqual(try mode(claims.directory.appendingPathComponent(claims.fileName("attempt"))), 0o600)
        claims.remove("attempt")
        XCTAssertNil(try claims.read("attempt"))
    }

    func testSourceKeepsKeychainCallsOutOfTheApp() throws {
        let sources = repository.appendingPathComponent("Sources/ChecklistApp")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            count += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in ["import Security", "import LocalAuthentication", "SecItem", "SecKeychain", "kSec[A-Z]", "errSec[A-Z]", "LAContext", "Keychain"] {
                XCTAssertNil(text.range(of: pattern, options: .regularExpression), "\(url.lastPathComponent) contains \(pattern)")
            }
        }
        XCTAssertGreaterThan(count, 50, "The scan found the app sources")
        let store = try String(contentsOf: sources.appendingPathComponent("Stores/ChecklistStore.swift"), encoding: .utf8)
        let persistence = try XCTUnwrap(store.range(of: "struct PendingCommandPersistence {")?.lowerBound)
        let end = try XCTUnwrap(store.range(of: "@MainActor\nfinal class ChecklistStore")?.lowerBound)
        XCTAssertFalse(store[persistence..<end].contains("HumanClaims"), "PendingCommandPersistence calls HumanClaims")
        XCTAssertTrue(store.contains("pendingCommandPersistence:PendingCommandPersistence = .ownerFile,"), "The default route is the file route")
        let work = try String(contentsOf: sources.appendingPathComponent("Views/HumanWorkActions.swift"), encoding: .utf8)
        XCTAssertTrue(work.contains("guard let token = HumanClaims.read(attempt.id) else { store.error = \"The local claim credential is unavailable."))
        let review = try String(contentsOf: sources.appendingPathComponent("Views/ReviewDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(review.contains("guard let token = HumanClaims.read(attempt.id) else {store.error = \"The exact prior claim credential is unavailable."))
    }

    func testDocsStateTheFileRouteAndIgnoredLeftovers() throws {
        for path in ["docs/database-storage.md", "docs/test-instances.md"] {
            let text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("OwnerPrivate"), path)
            XCTAssertTrue(text.contains("Leftover Keychain items are ignored"), path)
        }
    }
}

/// The store route with a real router for reads and a transport that records each write.
@MainActor final class OwnerPrivateCommandRouteTests: XCTestCase {
    private final class Sink: DesktopAlertSink {
        func authorization() async -> DesktopAlertAuthorization { .denied }
        func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
        func send(_ alert: DesktopAlert) async throws {}
        func remove(_ identifiers: [String]) {}
    }
    /// The old route under the defect: the delete leaves the stale item, and the add reports a duplicate.
    private final class StaleKeychainItemFake {
        static let duplicateItem = -25299
        var calls = 0
        func save() throws { calls += 1; throw NSError(domain: NSOSStatusErrorDomain, code: Self.duplicateItem) }
    }
    private var root: URL!
    private var defaults: IsolatedDefaults!
    private var router: CommandRouter!
    private var incarnation = ""
    private var calls: [(String, [String: Any])] = []
    private var loseReply = false
    private var onWrite: (() -> Void)?
    private let owner = Caller(role: "owner", installation: "cl-373-fixture", projectIDs: [])
    private let key = "pending-command-v2"
    private let identity = "org.checklist.coordination"
    private var instance: ChecklistInstance!
    private var records: OwnerPrivateFileStore!
    private var claims: OwnerPrivateFileStore!
    private var mutations: [(String, [String: Any])] { calls.filter { CommandReply.expectsMutation($0.0) } }

    override func setUp() async throws {
        root = try temporaryFolder()
        defaults = isolatedDefaults("OwnerPrivateRoute")
        defaults.preferences.set(Page.epics.rawValue, forKey: "lastPage")
        router = try TestStore.router(root: root.appendingPathComponent("store"))
        incarnation = try router.handle(method: "service_info", params: [:], caller: owner)["data"].flatMap { ($0 as? [String: Any])?["store_incarnation"] as? String } ?? ""
        instance = try ChecklistInstance(home: root, environment: [:])
        records = OwnerPrivateFileStore(directory: OwnerPrivateFileStore.directory(for: instance), kind: OwnerPrivateFileStore.pendingCommandKind)
        claims = HumanClaims.store(for: instance)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store(persistence: PendingCommandPersistence? = nil, identity: String? = nil, restore: Bool = true) -> ChecklistStore {
        ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: defaults.preferences,
                       restorePendingCommand: restore, desktopAlerts: DesktopAlertCoordinator(sink: Sink()),
                       requestTransport: { [self] method, params in
            calls.append((method, params))
            if CommandReply.expectsMutation(method) {
                onWrite?()
                if loseReply { throw CommandReply.unknown(commandID: params["command_id"] as? String, reason: "synthetic_lost_reply") }
                if method == "work_release" { return ["ok": true, "data": ["id": "released"]] }
            }
            return try router.handle(method: method, params: appFixtureTaskInput(router, method: method, input: params), caller: owner)
        }, navigationMemory: DetailItemNavigationMemory(), pendingCommandKey: key,
                       pendingCommandPersistence: persistence ?? .ownerFile(for: instance), pendingCommandServiceIdentity: identity ?? self.identity)
    }
    private func settled(_ store: ChecklistStore) async throws {
        for _ in 0..<600 { if !store.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("The command did not finish")
    }
    private var recordFile: URL { records.directory.appendingPathComponent(records.fileName(key)) }

    func testDefaultStoreUsesTheFileRouteWithoutDiskAccess() {
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")), preferences: defaults.preferences,
                                   restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: Sink()),
                                   requestTransport: { _, _ in XCTFail("No request"); return [:] })
        defer { store.stopWindowReads() }
        XCTAssertEqual(store.pendingCommandFileDirectory, OwnerPrivateFileStore.directory(for: .current))
    }

    /// The defect condition: the old route refuses the write on a stale item, and the file
    /// route sends the same write with that stale item still present and untouched.
    func testWriteGoesOutWhereTheOldRouteAddReturnsADuplicate() async throws {
        let stale = StaleKeychainItemFake()
        let oldRoute = store(persistence: PendingCommandPersistence(read: { _ in nil }, save: { _, _ in try stale.save() }, remove: { _ in }))
        defer { oldRoute.stopWindowReads() }
        await oldRoute.refresh()
        var refusal: Error?
        oldRoute.run("project_create", ["name": "Blocked before"], failure: { refusal = $0 })
        XCTAssertEqual(stale.calls, 1)
        XCTAssertTrue(mutations.isEmpty, "The old route stops before the send")
        XCTAssertEqual((refusal as? ChecklistError)?.details["code"] as? Int, StaleKeychainItemFake.duplicateItem, "The status stays in the error details")
        XCTAssertFalse(oldRoute.error?.lowercased().contains("work claim") == true, oldRoute.error ?? "")

        let callsBefore = stale.calls
        let fileRoute = store()
        defer { fileRoute.stopWindowReads() }
        await fileRoute.refresh()
        fileRoute.error = nil
        var sawRecordAtSend = false
        onWrite = { [self] in sawRecordAtSend = (try? records.read(key)) != nil && (try? mode(recordFile)) == 0o600 }
        fileRoute.run("project_create", ["name": "Sent now"])
        try await settled(fileRoute)
        XCTAssertEqual(mutations.count, 1, "The write goes out")
        XCTAssertEqual(mutations[0].1["name"] as? String, "Sent now")
        XCTAssertTrue(sawRecordAtSend, "The record exists, mode 0600, before the send")
        XCTAssertNil(fileRoute.error)
        XCTAssertEqual(stale.calls, callsBefore, "The file route makes no call on the old route")
        XCTAssertNil(try records.read(key), "The reply removes the record")
    }

    func testRestartOfferExactMatchSameCommandAndRemovalAfterReply() async throws {
        let first = store(); defer { first.stopWindowReads() }
        await first.refresh()
        loseReply = true
        first.run("project_create", ["name": "Saved once"])
        try await settled(first)
        let original = try XCTUnwrap(first.pendingCommandID)
        let record = try XCTUnwrap(PendingCommandRecovery(saved: XCTUnwrap(records.read(key)), claimToken: { _ in nil }))
        XCTAssertEqual(record.storeIncarnation, incarnation); XCTAssertEqual(record.serviceIdentity, identity)

        let restarted = store(); defer { restarted.stopWindowReads() }
        XCTAssertFalse(restarted.hasPendingMutation, "No offer before the store is identified")
        await restarted.refresh()
        XCTAssertTrue(restarted.hasPendingMutation); XCTAssertEqual(restarted.pendingCommandID, original)
        XCTAssertEqual(mutations.count, 1, "Connecting sends nothing")
        loseReply = false
        restarted.retryPendingMutation(); try await settled(restarted)
        XCTAssertEqual(mutations.count, 2); XCTAssertEqual(mutations[1].1["command_id"] as? String, original)
        XCTAssertFalse(restarted.hasPendingMutation)
        XCTAssertNil(try records.read(key))
    }

    func testForeignStoreAndServiceAreNeverSent() async throws {
        for foreign in [PendingCommandRecovery(method: "project_create", params: ["command_id": UUID().uuidString], storeIncarnation: "other-store", serviceIdentity: identity),
                        PendingCommandRecovery(method: "project_create", params: ["command_id": UUID().uuidString], storeIncarnation: incarnation, serviceIdentity: "org.checklist.test1.coordination")] {
            try records.save(foreign.encoded(), key: key)
            let restarted = store(); defer { restarted.stopWindowReads() }
            await restarted.refresh()
            XCTAssertFalse(restarted.hasPendingMutation)
            XCTAssertEqual(restarted.notice?.contains("different store"), true, restarted.notice ?? "")
            XCTAssertTrue(mutations.isEmpty)
            XCTAssertNotNil(try records.read(key), "An ignored item stays until a later save")
        }
        let next = store(); defer { next.stopWindowReads() }
        await next.refresh()
        next.run("project_create", ["name": "Newer"])
        try await settled(next)
        XCTAssertEqual(mutations.count, 1, "A later write replaces the ignored item")
        XCTAssertNil(try records.read(key))
    }

    func testClaimTokenIsNeverOnDiskInTheRecordAndReplaysExactly() async throws {
        let token = "plain-claim-token-5d1c"
        try claims.save(token, key: "attempt-1")
        let first = store(); defer { first.stopWindowReads() }
        await first.refresh()
        loseReply = true
        first.run("work_release", ["project_id": "p", "attempt_id": "attempt-1", "claim_token": token, "reason": "stop"])
        try await settled(first)
        XCTAssertEqual(mutations[0].1["claim_token"] as? String, token, "The send keeps the token")
        let bytes = try Data(contentsOf: recordFile)
        XCTAssertNil(bytes.range(of: Data(token.utf8)), "The record holds no plain token")
        let original = try XCTUnwrap(first.pendingCommandID)

        let restarted = store(); defer { restarted.stopWindowReads() }
        await restarted.refresh()
        XCTAssertEqual(restarted.pendingCommandID, original)
        loseReply = false
        restarted.retryPendingMutation(); try await settled(restarted)
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations[1].1["claim_token"] as? String, token, "Recovery resolves the exact token")
        XCTAssertNil(mutations[1].1["claim_token_ref"], "The reference is not sent")
        XCTAssertEqual(mutations[1].1["command_id"] as? String, original)
        XCTAssertNil(try records.read(key))
    }

    func testMissingChangedOrPlainClaimCredentialIsIgnoredAndNotSent() async throws {
        func saved() throws -> String {
            try PendingCommandRecovery(method: "work_release", params: ["command_id": UUID().uuidString, "attempt_id": "attempt-2", "claim_token": "original"],
                                       storeIncarnation: incarnation, serviceIdentity: identity).encoded()
        }
        // Missing, then a different credential for the same attempt.
        for current in [nil, "replacement"] as [String?] {
            claims.remove("attempt-2")
            if let current { try claims.save(current, key: "attempt-2") }
            try records.save(try saved(), key: key)
            let restarted = store(); defer { restarted.stopWindowReads() }
            await restarted.refresh()
            XCTAssertFalse(restarted.hasPendingMutation)
            XCTAssertEqual(restarted.notice?.contains("could not read safely"), true, restarted.notice ?? "")
        }
        // A record with a plain token is malformed, and a nested token is refused on save.
        let plain = #"{"method":"work_release","params":{"command_id":"\#(UUID().uuidString)","attempt_id":"a","claim_token":"x"},"service_identity":"s","store_incarnation":"i"}"#
        XCTAssertNil(PendingCommandRecovery(saved: plain, claimToken: { _ in "x" }))
        XCTAssertThrowsError(try PendingCommandRecovery(method: "m", params: ["items": [["claim_token": "x"]]], storeIncarnation: "i", serviceIdentity: "s").encoded())
        XCTAssertThrowsError(try PendingCommandRecovery(method: "m", params: ["claim_token": "x"], storeIncarnation: "i", serviceIdentity: "s").encoded())
        XCTAssertTrue(mutations.isEmpty)
    }

    func testFileFailureStopsTheSendAndKeepsErrnoAndNextStep() async throws {
        try FileManager.default.createDirectory(at: records.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: records.directory)
        try FileManager.default.createSymbolicLink(at: records.directory, withDestinationURL: root)
        let store = store(restore: false); defer { store.stopWindowReads() }
        await store.refresh()
        var refusal: Error?
        store.run("project_create", ["name": "Stopped"], failure: { refusal = $0 })
        XCTAssertTrue(mutations.isEmpty, "Save before send")
        let message = try XCTUnwrap(store.error)
        XCTAssertTrue(message.contains("Cannot preserve the command for safe recovery"), message)
        XCTAssertTrue(message.contains("errno \(ENOTDIR)"), message)
        XCTAssertTrue(message.contains("Move the item named OwnerPrivate"), message)
        XCTAssertFalse(message.lowercased().contains("work claim"), message)
        XCTAssertFalse(message.contains("Keychain"), message)
        let details = try XCTUnwrap(refusal as? ChecklistError).details
        XCTAssertEqual(details["errno"] as? Int, Int(ENOTDIR))
        XCTAssertEqual((refusal as? ChecklistError)?.code, "WRITE_NOT_STARTED")
    }
}
