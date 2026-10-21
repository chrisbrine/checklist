import XCTest
import Darwin
import ChecklistIPC
@testable import ChecklistMCPServer

final class DelegateChildBindingTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let executable: URL
        let instance: ChecklistInstance
        init(slot: Int?, variant: Bool = false) throws {
            directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".cl171-binding-" + UUID().uuidString)
            let bundle = directory.appendingPathComponent("Synthetic.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/checklist")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            instance = try ChecklistInstance(slotValue: slot.map { NSNumber(value: $0) }, bundleURL: bundle, home: directory, environment: [:])
            try setSlot(slot)
            let probe = Bundle(for: DelegateChildBindingTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ChecklistCLIInputProbe")
            try FileManager.default.copyItem(at: probe, to: executable)
            let signing = Process()
            signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            var arguments = ["--force", "--sign", "-", "--timestamp=none", "--identifier", "org.checklist.checklist"]
            if variant {
                let entitlement = directory.appendingPathComponent("synthetic-entitlements.plist")
                try PropertyListSerialization.data(fromPropertyList: ["org.checklist.synthetic-fixture": true], format: .xml, options: 0).write(to: entitlement)
                arguments += ["--entitlements", entitlement.path]
            }
            signing.arguments = arguments + [executable.path]
            signing.standardOutput = FileHandle.nullDevice; signing.standardError = FileHandle.nullDevice
            try signing.run(); signing.waitUntilExit()
            guard signing.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func setSlot(_ slot: Int?) throws {
            var plist: [String: Any] = ["CFBundleIdentifier": "org.checklist.app" + (slot.map { ".test\($0)" } ?? "")]
            if let slot { plist["ChecklistInstanceSlot"] = slot }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"), options: .atomic)
        }
    }

    func testValidationToExecSwapKillsDifferentSignedChildBeforeOutput() throws {
        let original = try Fixture(slot: 2), replacement = try Fixture(slot: nil, variant: true)
        let originalHash = try XCTUnwrap(ClientBuildIdentity.executable(original.executable)?.cdhash)
        XCTAssertNotEqual(originalHash, ClientBuildIdentity.executable(replacement.executable)?.cdhash)
        let update = ShimUpdateEnvironment.launched(path: original.executable.path, ownHash: originalHash,
            instance: original.instance, directory: original.directory.path, environment: [:], identity: { path in
                let validated = ClientBuildIdentity.executable(path)
                try! FileManager.default.moveItem(at: path, to: path.appendingPathExtension("validated"))
                try! FileManager.default.createSymbolicLink(at: path, withDestinationURL: replacement.executable)
                return validated
            })
        XCTAssertThrowsError(try update.run(["signal"], nil)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("DELEGATE_INSTANCE_MISMATCH:"), error.localizedDescription)
            let mismatch = error as? ShimChildInstanceMismatch
            XCTAssertEqual(mismatch?.observedHash, ClientBuildIdentity.executable(replacement.executable)?.cdhash)
            XCTAssertEqual(mismatch?.stdout, Data())
            XCTAssertEqual(mismatch?.stderr, "")
            if let pid = mismatch?.processID {
                var status: Int32 = 0
                XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
                XCTAssertEqual(errno, ECHILD, "The rejected child must already be reaped.")
            }
        }
    }

    func testSameHashInAnotherBundleIsKilledBeforeOutput() throws {
        let original = try Fixture(slot: 2), replacement = try Fixture(slot: 2)
        let hash = try XCTUnwrap(ClientBuildIdentity.executable(original.executable)?.cdhash)
        XCTAssertEqual(hash, ClientBuildIdentity.executable(replacement.executable)?.cdhash)
        let update = ShimUpdateEnvironment.launched(path: original.executable.path, ownHash: hash,
            instance: original.instance, directory: original.directory.path, environment: [:], identity: { path in
                let validated = ClientBuildIdentity.executable(path)
                try! FileManager.default.moveItem(at: path, to: path.appendingPathExtension("validated"))
                try! FileManager.default.createSymbolicLink(at: path, withDestinationURL: replacement.executable)
                return validated
            })
        XCTAssertThrowsError(try update.run(["signal"], nil)) { error in
            let mismatch = error as? ShimChildInstanceMismatch
            XCTAssertEqual(mismatch?.observedHash, hash)
            XCTAssertEqual(mismatch?.stdout, Data())
            XCTAssertEqual(mismatch?.stderr, "")
        }
    }

    func testMetadataSwapAfterValidationIsRefusedByChildBeforeItsBody() throws {
        let fixture = try Fixture(slot: 2)
        let hash = try XCTUnwrap(ClientBuildIdentity.executable(fixture.executable)?.cdhash)
        let update = ShimUpdateEnvironment.launched(path: fixture.executable.path, ownHash: hash,
            instance: fixture.instance, directory: fixture.directory.path, environment: [:], identity: { path in
                let validated = ClientBuildIdentity.executable(path)
                try! fixture.setSlot(nil)
                return validated
            })
        let result = try update.run(["signal"], nil)
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.hasPrefix("Checklist: DELEGATE_INSTANCE_MISMATCH:"), result.stderr)
        XCTAssertFalse(result.stderr.contains("connected after"), "The probe body must not run.")
    }

    func testSameBundleDelegatesThroughSuspendedStartWithOriginalContext() throws {
        let fixture = try Fixture(slot: 2)
        let hash = try XCTUnwrap(ClientBuildIdentity.executable(fixture.executable)?.cdhash)
        let update = ShimUpdateEnvironment.launched(path: fixture.executable.path, ownHash: hash,
            instance: fixture.instance, directory: fixture.directory.path, environment: ["CL171_VALUE": "same environment"])
        let arguments = ["call", "synthetic", "-", "--workspace", fixture.directory.path, "--session", "synthetic-session", "--installation", "synthetic-slot"]
        let result = try update.run(arguments, Data("{}".utf8))
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.status, 0, result.stderr)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(value["bytes"] as? Int, 2)
        XCTAssertEqual(value["arguments"] as? [String], arguments)
        XCTAssertEqual(value["environment"] as? String, "same environment")
        XCTAssertEqual(URL(fileURLWithPath: value["directory"] as! String).resolvingSymlinksInPath().path, fixture.directory.resolvingSymlinksInPath().path)
    }
}
