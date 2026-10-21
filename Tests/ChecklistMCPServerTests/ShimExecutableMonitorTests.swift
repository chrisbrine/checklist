import XCTest
import ChecklistIPC
@testable import ChecklistMCPServer

final class ShimExecutableMonitorTests: XCTestCase {
    private final class BundleFixture {
        let directory: URL
        let executable: URL
        let instance: ChecklistInstance
        init(slot: Int? = 2) throws {
            directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".cl171-bundle-" + UUID().uuidString)
            let bundle = directory.appendingPathComponent("Synthetic.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/checklist")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            instance = try ChecklistInstance(slotValue: slot.map { NSNumber(value: $0) }, bundleURL: bundle, home: directory, environment: [:])
            var plist: [String: Any] = ["CFBundleIdentifier": instance.bundleIdentifier]
            if let slot { plist["ChecklistInstanceSlot"] = slot }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data("first".utf8).write(to: executable)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var boundary: ShimInstanceBoundary { get throws { try .init(launchPath: executable.path, instance: instance) } }
        func point(to other: BundleFixture) throws {
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: other.executable)
        }
    }

    func testCacheUsesFileStampAndRefusalForcesSignatureRead() throws {
        let fixture = try BundleFixture(), path = fixture.executable
        let own = Data([1]), replacement = Data([2])
        var reads = 0
        var hash = own
        let monitor = ShimExecutableMonitor(path: path.path, ownHash: own, boundary: try fixture.boundary, identity: { _ in
            reads += 1
            return .init(identifier: "org.checklist.checklist", cdhash: hash)
        })
        XCTAssertEqual(monitor.check(force: false), .current)
        XCTAssertEqual(monitor.check(force: false), .current)
        XCTAssertEqual(reads, 1)
        hash = replacement
        XCTAssertEqual(monitor.check(force: true), .replaced)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(monitor.check(force: false), .replaced)
        XCTAssertEqual(reads, 2)
        try Data("other".utf8).write(to: path, options: .atomic)
        XCTAssertEqual(monitor.check(force: false), .replaced)
        XCTAssertEqual(reads, 3)
        try Data("longer file".utf8).write(to: path)
        XCTAssertEqual(monitor.check(force: false), .replaced)
        XCTAssertEqual(reads, 4)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: path.path)
        XCTAssertEqual(monitor.check(force: false), .replaced)
        XCTAssertEqual(reads, 5)
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(monitor.check(force: false), .unavailable)
    }

    func testUnsignedWrongIdentifierAndMissingSelfIdentityCannotDelegate() throws {
        let fixture = try BundleFixture(), path = fixture.executable, boundary = try fixture.boundary
        let own = Data([1])
        let identities: [ClientBuildIdentity?] = [nil, .init(identifier: "other.app", cdhash: Data([2]))]
        for identity in identities {
            let monitor = ShimExecutableMonitor(path: path.path, ownHash: own, boundary: boundary, identity: { _ in identity })
            XCTAssertEqual(monitor.check(force: false), .unavailable)
        }
        let missingSelf = ShimExecutableMonitor(path: path.path, ownHash: nil, boundary: boundary, identity: { _ in
            .init(identifier: "org.checklist.checklist", cdhash: own)
        })
        XCTAssertEqual(missingSelf.check(force: false), .unavailable)
        let realInvalid = ShimExecutableMonitor(path: path.path, ownHash: own, boundary: boundary)
        XCTAssertEqual(realInvalid.check(force: false), .unavailable)
    }

    private final class Runs: @unchecked Sendable { var count = 0 }
    private func environment(_ fixture: BundleFixture, runs: Runs) -> ShimUpdateEnvironment {
        .launched(path: fixture.executable.path, ownHash: Data([1]), instance: fixture.instance,
            directory: fixture.directory.path, environment: [:], identity: { _ in .init(identifier: "org.checklist.checklist", cdhash: Data([2])) },
            runner: { _, _, _, _, _, _ in runs.count += 1; return .init(status: 0, stdout: Data("{}".utf8)) })
    }

    func testSymlinkReplacementToAnotherBundleCannotStartChild() throws {
        let original = try BundleFixture(), other = try BundleFixture(), runs = Runs()
        let update = environment(original, runs: runs)
        try original.point(to: other)
        XCTAssertEqual(update.check(false), .unavailable)
        XCTAssertThrowsError(try update.run(["tools"], nil)) { XCTAssertTrue($0.localizedDescription.hasPrefix("CLIENT_OUTDATED:")) }
        XCTAssertEqual(runs.count, 0)
    }

    func testCrossSlotAndSlotToLiveTargetsCannotStartChild() throws {
        for targetSlot in [nil, 3] as [Int?] {
            let original = try BundleFixture(slot: 2), other = try BundleFixture(slot: targetSlot), runs = Runs()
            let update = environment(original, runs: runs)
            try original.point(to: other)
            XCTAssertEqual(update.check(false), .unavailable)
            XCTAssertThrowsError(try update.run(["tools"], nil)) { failure in
                XCTAssertTrue(failure.localizedDescription.contains("no command ran"))
                XCTAssertTrue(failure.localizedDescription.contains("reconnect"))
            }
            XCTAssertEqual(runs.count, 0)
        }
    }

    func testLiveToSlotTargetCannotStartChild() throws {
        let original = try BundleFixture(slot: nil), other = try BundleFixture(slot: 2), runs = Runs()
        let update = environment(original, runs: runs)
        try original.point(to: other)
        XCTAssertEqual(update.check(false), .unavailable)
        XCTAssertThrowsError(try update.run(["tools"], nil))
        XCTAssertEqual(runs.count, 0)
    }

    func testChangedInstancePlistIsCheckedEvenWhenExecutableStampIsCached() throws {
        let original = try BundleFixture(slot: 2), runs = Runs()
        let update = environment(original, runs: runs)
        XCTAssertEqual(update.check(false), .replaced)
        let plist: [String: Any] = ["ChecklistInstanceSlot": 3, "CFBundleIdentifier": "org.checklist.app.test3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: original.instance.bundleURL!.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try update.run(["tools"], nil))
        XCTAssertEqual(runs.count, 0)
    }


    func testChangedBundleIdentifierIsRefusedEvenWhenSlotDoesNotChange() throws {
        let original = try BundleFixture(slot: 2), runs = Runs()
        let update = environment(original, runs: runs)
        let plist: [String: Any] = ["ChecklistInstanceSlot": 2, "CFBundleIdentifier": "unrelated.app"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: original.instance.bundleURL!.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try update.run(["tools"], nil))
        XCTAssertEqual(runs.count, 0)
    }

    func testSameBundleReplacementStillStartsChild() throws {
        let original = try BundleFixture(), runs = Runs()
        let update = environment(original, runs: runs)
        try Data("replacement".utf8).write(to: original.executable, options: .atomic)
        XCTAssertEqual(update.check(false), .replaced)
        let result = try update.run(["tools"], nil)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(runs.count, 1)
    }

    func testChildRunnerPreservesDirectoryEnvironmentArgumentsAndDrainsBothPipes() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".cl171-child-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("synthetic-child")
        let source = """
        #!/bin/sh
        printf '%s\\n' "$PWD" "$CL171_VALUE" "$1"
        i=0
        while [ "$i" -lt 8192 ]; do
          printf 'stderr-data\\n' >&2
          i=$((i+1))
        done
        exit 7
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try ShimChildProcess.run(path: script.path, arguments: ["exact 'JSON' argument"],
            directory: directory.path, environment: ["CL171_VALUE": "same environment"])
        XCTAssertEqual(result.status, 7)
        let lines = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
        XCTAssertEqual(Array(lines.dropFirst()), ["same environment", "exact 'JSON' argument", ""])
        XCTAssertEqual(result.stderr, String(repeating: "stderr-data\n", count: 8192))
    }

    private func inputProbe() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap([products.appendingPathComponent("ChecklistCLIInputProbe")].first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    func testRealChildReadsStdinAtOneMiBBoundaryWithRoutingAndEnvironment() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let arguments = ["call", "synthetic", "-", "--workspace", directory.path, "--session", "synthetic-session", "--installation", "synthetic-slot"]
        let prefix = "{\"body\":\"", suffix = "\"}"
        for count in [CallArgumentInput.limit - 1, CallArgumentInput.limit, CallArgumentInput.limit + 1] {
            let input = Data((prefix + String(repeating: "a", count: count - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
            let result = try ShimChildProcess.run(path: inputProbe().path, arguments: arguments,
                directory: directory.path, environment: ["CL171_VALUE": "same environment"], input: input)
            XCTAssertEqual(result.termination, .exited)
            if count <= CallArgumentInput.limit {
                XCTAssertEqual(result.status, 0, result.stderr)
                let output = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
                XCTAssertEqual(output["bytes"] as? Int, count)
                XCTAssertEqual(output["arguments"] as? [String], arguments)
                XCTAssertEqual(output["environment"] as? String, "same environment")
                XCTAssertEqual(URL(fileURLWithPath: output["directory"] as! String).resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
            } else {
                XCTAssertEqual(result.status, 1)
                XCTAssertTrue(result.stderr.hasPrefix("Checklist: TOO_LARGE: Input exceeds 1 MiB"))
                XCTAssertTrue(result.stdout.isEmpty)
            }
        }
    }

    func testRealSignalAfterRecoveryDiagnosticIsReportedAsSignal() throws {
        let result = try ShimChildProcess.run(path: inputProbe().path, arguments: ["signal"],
            directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().path, environment: [:])
        XCTAssertEqual(result.termination, .signalled)
        XCTAssertEqual(result.status, 9)
        XCTAssertTrue(result.stderr.contains("connected after"))
    }

    func testSpawnErrorsIncludingArgumentListTooLongAreLaunchFailures() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        for pathAndArguments in [(try inputProbe().path, [String(repeating: "a", count: 1_048_576)]),
                                 (directory + "/missing-child", [])] {
            XCTAssertThrowsError(try ShimChildProcess.run(path: pathAndArguments.0, arguments: pathAndArguments.1, directory: directory, environment: [:])) {
                XCTAssertTrue($0 is ShimChildLaunchError)
            }
        }
    }
}
