import XCTest
@testable import ChecklistApp

final class IsolatedDefaultsTests: XCTestCase {
    func testSuitesStaySeparateAndTypedValuesNeverCreateAPlist() throws {
        let first = isolatedDefaults("Cleanup"), second = isolatedDefaults("Cleanup")
        let defaults = first.preferences
        defaults.register(defaults: ["registered": "fallback"])
        defaults.set(["draft": "Synthetic note"], forKey: "capture")
        defaults.set(true, forKey: "sidebarVisible")
        defaults.set(42, forKey: "count")
        defaults.set(1.5, forKey: "width")
        defaults.set(Data([1, 2]), forKey: "bytes")
        defaults.set(["one", "two"], forKey: "list")
        XCTAssertNil(second.preferences.object(forKey: "capture"))
        XCTAssertTrue(defaults.bool(forKey: "sidebarVisible"))
        XCTAssertEqual(defaults.integer(forKey: "count"), 42)
        XCTAssertEqual(defaults.double(forKey: "width"), 1.5)
        XCTAssertEqual(defaults.data(forKey: "bytes"), Data([1, 2]))
        XCTAssertEqual(defaults.stringArray(forKey: "list"), ["one", "two"])
        XCTAssertEqual(defaults.dictionary(forKey: "capture")?["draft"] as? String, "Synthetic note")
        XCTAssertEqual(defaults.string(forKey: "registered"), "fallback")
        defaults.set("override", forKey: "registered")
        defaults.removeObject(forKey: "registered")
        XCTAssertEqual(defaults.string(forKey: "registered"), "fallback")
        XCTAssertTrue(defaults.synchronize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.plistURL.path))
        try first.clean()
        XCTAssertTrue(defaults.dictionaryRepresentation().isEmpty)
        try first.clean()
    }

    func testWindowSuitesReopenTheSameMemoryAndCleanupClearsRetainedOwners() throws {
        let suite = isolatedDefaults("WindowCleanup"), id = UUID()
        let child = suite.childPreferences(id)
        child.set("Other window", forKey: "lastProject")
        XCTAssertTrue(child === suite.childPreferences(id))
        XCTAssertEqual(suite.childPreferences(id).string(forKey: "lastProject"), "Other window")
        XCTAssertNil(suite.childPreferences(UUID()).object(forKey: "lastProject"))
        XCTAssertNil(suite.preferences.object(forKey: "lastProject"))
        try suite.clean()
        XCTAssertNil(child.object(forKey: "lastProject"))
        // A late owner can write/synchronize even after teardown, without a file.
        child.set("Late write", forKey: "lastProject")
        XCTAssertTrue(child.synchronize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path))
    }

    @MainActor func testPreferencesRemainAbsentAfterChildProcessExit() throws {
        let marker = "CHECKLIST_DEFAULTS_EXIT_PROBE"
        if let manifest = ProcessInfo.processInfo.environment[marker] {
            let suite = IsolatedDefaults("ProcessExit"), id = UUID()
            let storage = WorkspaceWindowStorage(journalBaseDirectory: URL(fileURLWithPath: manifest).deletingLastPathComponent(),
                                                 primaryPreferences: suite.preferences, preferencesSuitePrefix: suite.suiteName,
                                                 workspacePreferences: suite.childPreferences)
            // Exercise the production secondary-window path and a retained owner.
            // Exit without teardown: memory must need no cleanup at all.
            let window = WorkspaceWindowState(identity: .workspace(id), storage: storage) { journal, preferences, memory in
                ChecklistStore(draftJournal: journal, preferences: preferences, restorePendingCommand: false,
                               desktopAlerts: DesktopAlertCoordinator(sink: DefaultsExitAlertSink()),
                               requestTransport: { _, _ in throw NSError(domain: "UnexpectedDefaultsExitRequest", code: 1) },
                               navigationMemory: memory)
            }
            for defaults in [suite.preferences, window.preferences] {
                defaults.set("Retained until exit", forKey: "value")
                XCTAssertTrue(defaults.synchronize())
            }
            try [suite.plistURL.path, suite.plistURL.deletingLastPathComponent()
                .appendingPathComponent(storage.suiteName(for: id) + ".plist").path]
                .joined(separator: "\n").write(toFile: manifest, atomically: true, encoding: .utf8)
            exit(0)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CL158-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("suites")
        let child = Process()
        let runner = URL(fileURLWithPath: CommandLine.arguments[0])
        let selector = "ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit"
        child.executableURL = runner
        child.arguments = runner.lastPathComponent == "xctest"
            ? ["-XCTest", selector, Bundle(for: Self.self).bundlePath]
            : [selector]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.environment = ProcessInfo.processInfo.environment.merging([marker: manifest.path]) { _, new in new }
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let paths = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 2)
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 2)
            for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Post-exit leak: " + path) }
        }
    }

    func testAppTestsCreateSuitesOnlyThroughTheSharedHelper() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let pattern = #"UserDefaults\s*(?:\.init)?\s*\(\s*suiteName\s*:"#
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" && file.lastPathComponent != "IsolatedDefaults.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(source.range(of: pattern, options: .regularExpression), "Use isolatedDefaults for process-local preferences: " + file.lastPathComponent)
        }
    }
}

@MainActor private final class DefaultsExitAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
