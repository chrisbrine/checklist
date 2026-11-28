import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ChecklistCore
import ChecklistIPC
@testable import ChecklistService

final class SlotStartupInspectionTests: XCTestCase {
    private func verify(instance: ChecklistInstance, environment: [String: String]) throws -> SlotStartupInspection? {
        let inspection = try SlotStartupInspection.load(instance: instance, environment: environment)
        try inspection?.verifyBeforeOpeningStore()
        return inspection
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture() throws -> ChecklistInstance {
        let parent = ProcessInfo.processInfo.environment["CHECKLIST_SLOT_TEST_FIXTURE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let home = parent.appendingPathComponent("CL-515-" + UUID().uuidString)
        let instance = try ChecklistInstance(slotValue: 1, home: home, environment: [:])
        try FileManager.default.createDirectory(at: instance.root, withIntermediateDirectories: true)
        return instance
    }

    private func stamp(_ url: URL) throws -> [String] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        func nanos(_ time: timespec) -> String { String(time.tv_sec * 1_000_000_000 + time.tv_nsec) }
        return [String(info.st_dev), String(info.st_ino), String(info.st_mode), String(info.st_size),
                nanos(info.st_mtimespec), nanos(info.st_ctimespec)]
    }

    private func withExistingStore(_ instance: ChecklistInstance, body: (StorageServiceLease) throws -> Void) throws {
        // These fixtures exercise SQLite startup. Use a pinned descriptor for
        // their local root so a helper launch timeout cannot mask the assertion.
        var access = StorageFolderAccess()
        access.directOpen = true
        let files = try StorageObjectFiles(root: instance.root, folderAccess: access, pinRootForGates: true)
        let lease = try StorageServiceLease(root: instance.root)
        try withExtendedLifetime(files) {
            let opened = try StorageBootstrap.open(root: instance.root, serviceLease: lease)
            try opened.queue.close()
            try body(lease)
        }
    }

    private func receipt(_ instance: ChecklistInstance, named: [[String: Any]] = [],
                         canonical: [[String: Any]] = [], directories: [[String: Any]] = [],
                         wrongContent: Bool = false) throws -> [String: String] {
        let rootEntries = try FileManager.default.contentsOfDirectory(atPath: instance.root.path)
            .filter { !["checklist.bootstrap.lock", "service.lock", ".archive-storage.lock"].contains($0) }
        let observations = try JSONSerialization.data(withJSONObject: [
            "named": named, "canonical": canonical, "directories": directories, "root_entries": rootEntries
        ])
        let files: [[String: Any]] = try SlotStartupInspection.storeNames.map { name in
            let url = instance.root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ["name": name, "stamp": NSNull(), "sha256": NSNull()]
            }
            let bytes = try Data(contentsOf: url)
            return ["name": name, "stamp": try stamp(url), "sha256": digest(wrongContent ? Data() : bytes)]
        }
        let raw = try JSONSerialization.data(withJSONObject: ["format": 1, "slot": 1, "files": files,
            "observations": observations.base64EncodedString(), "observations_sha256": digest(observations)])
        let url = instance.root.deletingLastPathComponent().appendingPathComponent(SlotStartupInspection.receiptName)
        try raw.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return [SlotStartupInspection.environmentKey: digest(raw)]
    }

    func testDatabaseOrRetainedWALChangeAtServiceAccessRefuses() throws {
        for name in SlotStartupInspection.storeNames.prefix(2) {
            let instance = try fixture()
            let db = instance.root.appendingPathComponent("checklist.sqlite")
            let wal = instance.root.appendingPathComponent("checklist.sqlite-wal")
            try Data("db".utf8).write(to: db)
            try Data("wal".utf8).write(to: wal)
            let env = try receipt(instance)
            let initial = try XCTUnwrap(SlotStartupInspection.load(instance: instance, environment: env))
            let changed = instance.root.appendingPathComponent(name)
            let bytes = try Data(contentsOf: changed)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: changed.path)
            XCTAssertEqual(try Data(contentsOf: changed), bytes)
            XCTAssertThrowsError(try verify(instance: instance, environment: env))
            XCTAssertThrowsError(try initial.verifyBeforeOpeningStore())
        }
    }

    func testHashesAndLaunchConfigurationDigestAreRequired() throws {
        let instance = try fixture()
        try Data("db".utf8).write(to: instance.root.appendingPathComponent("checklist.sqlite"))
        XCTAssertThrowsError(try verify(instance: instance, environment: [:]))
        let env = try receipt(instance, wrongContent: true)
        XCTAssertThrowsError(try verify(instance: instance, environment: env))
        _ = try receipt(instance)
        XCTAssertThrowsError(try verify(instance: instance, environment: env))
    }

    func testRouterRefusesDatabaseChangeAtEitherSQLiteOpen() throws {
        for boundary in [StoreOpeningCheck.Boundary.readOnlyOpened, .writerOpened] {
            let instance = try fixture()
            try withExistingStore(instance) { lease in
                let env = try receipt(instance)
                let inspection = try XCTUnwrap(SlotStartupInspection.load(instance: instance, environment: env))
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: instance.root.path)
                let database = instance.root.appendingPathComponent("checklist.sqlite")
                let check = StoreOpeningCheck { opening in
                    if opening == boundary {
                        try FileManager.default.setAttributes(
                            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: database.path)
                    }
                    switch opening {
                    case .beforeOpen: try inspection.verifyBeforeOpeningStore(preparedRoot: true)
                    case .readOnlyOpened, .writerOpened:
                        try inspection.verifyOpenedStore(writer: opening == .writerOpened)
                    }
                }
                XCTAssertThrowsError(try CommandRouter(root: instance.root, serviceLease: lease,
                                                        cliCommand: instance.cliCommand, openingCheck: check)) { error in
                    let refusal = error as? StoreOpeningCheck.Refusal
                    XCTAssertEqual(refusal?.cause.localizedDescription, "The inspected slot database, WAL or SQLite companion changed.")
                    XCTAssertEqual(try? self.stamp(database)[4], "100000000000")
                }
            }
        }
    }

    func testRouterRefusesPathChangesAtFirstSQLiteOpen() throws {
        for replaceExternal in [false, true] {
            let instance = try fixture()
            try withExistingStore(instance) { lease in
                let parent = instance.root.deletingLastPathComponent()
                let external = parent.appendingPathComponent("external")
                let objects = instance.root.appendingPathComponent("objects")
                try Data("external".utf8).write(to: external)
                let env = try receipt(instance, named: [["path": external.path, "expected": Array(try stamp(external).prefix(3))]],
                                      directories: [["path": objects.path, "expected": try stamp(objects)]])
                let inspection = try XCTUnwrap(SlotStartupInspection.load(instance: instance, environment: env))
                let check = StoreOpeningCheck { opening in
                    switch opening {
                    case .beforeOpen: try inspection.verifyBeforeOpeningStore(preparedRoot: true)
                    case .readOnlyOpened:
                        if replaceExternal {
                            try FileManager.default.moveItem(at: external, to: parent.appendingPathComponent("previous"))
                            try Data("replacement".utf8).write(to: external)
                        } else {
                            try Data().write(to: objects.appendingPathComponent("new"))
                        }
                        try inspection.verifyOpenedStore(writer: false)
                    case .writerOpened: XCTFail("The first open must refuse the changed path.")
                    }
                }
                XCTAssertThrowsError(try CommandRouter(root: instance.root, serviceLease: lease,
                                                        cliCommand: instance.cliCommand, openingCheck: check)) { error in
                    let refusal = error as? StoreOpeningCheck.Refusal
                    let message = replaceExternal ? "A slot inspection path changed." : "An inspected slot directory changed."
                    XCTAssertEqual(refusal?.cause.localizedDescription, message)
                }
            }
        }
    }

    func testNamedReplacementAliasAndLocalDirectoryChangesRefuse() throws {
        for change in ["name", "alias", "directory"] {
            let instance = try fixture()
            try Data("db".utf8).write(to: instance.root.appendingPathComponent("checklist.sqlite"))
            let parent = instance.root.deletingLastPathComponent()
            let target = parent.appendingPathComponent("external")
            let link = parent.appendingPathComponent("alias")
            let local = instance.root.appendingPathComponent("objects")
            try Data("external".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let env = try receipt(instance,
                named: [["path": target.path, "expected": Array(try stamp(target).prefix(3))]],
                canonical: [["path": link.path, "expected": try ChecklistInstance.slotInspectionCanonicalPath(link.path)]],
                directories: [["path": local.path, "expected": try stamp(local)]])
            XCTAssertNotNil(try verify(instance: instance, environment: env))
            switch change {
            case "name":
                try FileManager.default.moveItem(at: target, to: parent.appendingPathComponent("previous"))
                try Data("external".utf8).write(to: target)
            case "alias":
                try FileManager.default.moveItem(at: link, to: parent.appendingPathComponent("previous"))
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
            default:
                try Data().write(to: local.appendingPathComponent("new"))
            }
            XCTAssertThrowsError(try verify(instance: instance, environment: env))
        }
    }

    func testPythonProducedReceiptAtTheServiceOpenBoundary() throws {
        guard let file = ProcessInfo.processInfo.environment["CHECKLIST_SLOT_TEST_WIRE_FIXTURE"] else {
            throw XCTSkip("Run the retained Python receipt fixture to exercise the cross-language wire format.")
        }
        struct WireFixture: Decodable { let home: String; let digest: String }
        let fixture = try JSONDecoder().decode(WireFixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let instance = try ChecklistInstance(slotValue: 1, home: URL(fileURLWithPath: fixture.home), environment: [:])
        let environment = [SlotStartupInspection.environmentKey: fixture.digest]
        let inspection = try XCTUnwrap(SlotStartupInspection.load(instance: instance, environment: environment))
        // Mirror the known service-lease write between the initial and final checks.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: instance.root.path)
        try Data().write(to: instance.root.appendingPathComponent("service.lock"))
        try inspection.verifyBeforeOpeningStore(preparedRoot: true)
        let lateLink = instance.root.appendingPathComponent("late-link")
        let parent = instance.root.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: lateLink, withDestinationURL: parent.appendingPathComponent("outside"))
        XCTAssertThrowsError(try inspection.verifyBeforeOpeningStore(preparedRoot: true))
        try FileManager.default.moveItem(at: lateLink, to: parent.appendingPathComponent("retained-link"))
        let wal = instance.root.appendingPathComponent("checklist.sqlite-wal")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 120)], ofItemAtPath: wal.path)
        XCTAssertThrowsError(try inspection.verifyBeforeOpeningStore(preparedRoot: true))
    }

    func testLiveAndFreshEmptySlotIgnoreMissingReceipt() throws {
        let slot = try fixture()
        XCTAssertNotNil(try verify(instance: slot, environment: [:]))
        let live = try ChecklistInstance(environment: [:])
        XCTAssertNil(try verify(instance: live, environment: [SlotStartupInspection.environmentKey: "invalid"]))
    }
}
