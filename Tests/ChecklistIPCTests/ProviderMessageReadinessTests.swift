import XCTest
@testable import ChecklistIPC

final class ProviderMessageReadinessTests: XCTestCase {
    private func input(_ values: [ProviderSettingSource.Scope: ProviderSettingSource.Reading] = [:],
                       missing: [String] = [], supported: Bool = true, sender: String? = "prompting", recipient: String? = "prompting") -> ClaudeReadinessInput {
        .init(sources: [ProviderSettingSource.Scope.managed, .session, .user, .project, .local].map {
            .init($0, "/fixture/\($0.rawValue).json", values[$0] ?? .unset)
        }, missingInputs: missing, rulesSupported: supported, senderClass: sender, recipientClass: recipient)
    }
    func testManagedThenSessionThenUserTrustedPrecedence() {
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.managed: .value(.accept), .session: .value(.refuse), .user: .value(.hold)])).state, .ready)
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.session: .value(.hold), .user: .value(.accept)])).state, .hold)
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.user: .value(.refuse)])).state, .refuse)
    }
    func testProjectAndLocalOnlyTightenTrustedValueAndNamePath() {
        let held = ClaudeMessageReadiness.resolve(input([.user: .value(.accept), .project: .value(.hold)]))
        XCTAssertEqual(held.state, .hold); XCTAssertEqual(held.decidingSource, "/fixture/project.json")
        let refused = ClaudeMessageReadiness.resolve(input([.managed: .value(.accept), .project: .value(.hold), .local: .value(.refuse)]))
        XCTAssertEqual(refused.state, .refuse); XCTAssertEqual(refused.decidingSource, "/fixture/local.json")
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.user: .value(.refuse), .project: .value(.accept), .local: .value(.hold)])).state, .refuse)
    }
    func testUnsetUsesPermissionClassParity() {
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input()).state, .ready)
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input(recipient: "bypass")).state, .hold)
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input(recipient: nil)).state, .unknown)
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input(sender: "", recipient: "")).state, .unknown)
    }
    func testInvalidManagedRefusesAndOtherValuesHold() {
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.managed: .invalid, .user: .value(.accept)])).state, .refuse)
        for scope in [ProviderSettingSource.Scope.session, .user, .project, .local] {
            XCTAssertEqual(ClaudeMessageReadiness.resolve(input([scope: .invalid])).state, .hold, scope.rawValue)
        }
    }
    func testUnknownLivePoliciesCannotBeOverriddenByPersonalAccept() {
        for reason in ["MDM", "server", "host", "flags", "primary directory", "worktree root"] {
            let result = ClaudeMessageReadiness.resolve(input([.user: .value(.accept)], missing: [reason]))
            XCTAssertEqual(result.state, .unknown); XCTAssertEqual(result.observedDecision, .accept)
            XCTAssertEqual(result.title, "Unknown: live policy not observable")
        }
    }
    func testKnownRestrictionRemainsVisibleWithUnknownHigherPolicy() {
        let result = ClaudeMessageReadiness.resolve(input([.user: .value(.accept), .local: .value(.hold)], missing: ["MDM"]))
        XCTAssertEqual(result.state, .unknown); XCTAssertEqual(result.observedDecision, .hold)
        XCTAssertEqual(result.decidingSource, "/fixture/local.json")
    }
    func testAbsentUnreadableUnsupportedOrUnobservedScopesNeverReady() {
        for scope in [ProviderSettingSource.Scope.managed, .session, .user, .project, .local] {
            for reading in [ProviderSettingSource.Reading.missing, .unreadable, .unsupported] {
                var values: [ProviderSettingSource.Scope: ProviderSettingSource.Reading] = [.user: .value(.accept)]
                values[scope] = reading
                XCTAssertEqual(ClaudeMessageReadiness.resolve(input(values)).state, .unknown)
            }
            var value = input([.user: .value(.accept)])
            value.sources.removeAll { $0.scope == scope }
            XCTAssertEqual(ClaudeMessageReadiness.resolve(value).state, .unknown)
        }
    }
    func testInvalidOverriddenSourceStillCannotEstablishReady() {
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.managed: .value(.accept), .user: .invalid])).state, .unknown)
    }
    func testUnqualifiedEngineCannotEstablishReady() {
        XCTAssertEqual(ClaudeMessageReadiness.resolve(input([.user: .value(.accept)], supported: false)).state, .unknown)
        XCTAssertTrue(ProviderReadinessObservation.versionLimitation.contains("shell CLI version is not"))
    }
    func testCodexIsPickupRegardlessOfQueueResumeNotifyAndHooks() {
        XCTAssertEqual(ProviderReadinessObservation.codexTitle, "Pickup only")
        for word in ["queue/resume", "notify", "hooks", "not recipient acknowledgment"] {
            XCTAssertTrue(ProviderReadinessObservation.codexExplanation.contains(word))
        }
    }

    private func fixture(_ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root)
    }
    func testReadsOnlyTopLevelKeyAndRejectsInvalidTypes() throws {
        try fixture { root in
            let file = root.appendingPathComponent("settings.json")
            for (text, reading) in [
                ("{}", ProviderSettingSource.Reading.unset),
                ("{\"permissions\":{\"crossSessionInbound\":\"accept\"}}", .unset),
                ("{\"crossSessionInbound\":\"accept\",\"secret\":\"not returned\"}", .value(.accept)),
                ("{\"crossSessionInbound\":\"hold\"}", .value(.hold)),
                ("{\"crossSessionInbound\":\"refuse\"}", .value(.refuse)),
                ("{\"crossSessionInbound\":null}", .invalid),
                ("{\"crossSessionInbound\":true}", .invalid),
                ("{\"crossSessionInbound\":\"Accept\"}", .invalid),
                ("{\"crossSessionInbound\":[]}", .invalid),
                ("[]", .invalid), ("{", .invalid)
            ] {
                let bytes = Data(text.utf8); try bytes.write(to: file)
                XCTAssertEqual(ProviderSettingsObservation.read(.user, path: file.path).reading, reading, text)
                XCTAssertEqual(try Data(contentsOf: file), bytes, "Inspection must never rewrite the source")
            }
        }
    }
    func testMissingUnreadableSymlinkDirectoryAndOversizeSources() throws {
        try fixture { root in
            XCTAssertEqual(ProviderSettingsObservation.read(.user, path: root.appendingPathComponent("absent").path).reading, .missing)
            XCTAssertEqual(ProviderSettingsObservation.read(.user, path: root.path).reading, .unsupported)
            let file = root.appendingPathComponent("settings.json")
            try Data(repeating: 32, count: ProviderSettingsObservation.maximumBytes + 1).write(to: file)
            XCTAssertEqual(ProviderSettingsObservation.read(.user, path: file.path).reading, .unsupported)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertEqual(ProviderSettingsObservation.read(.user, path: link.path).reading, .unreadable)
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertEqual(ProviderSettingsObservation.read(.user, path: file.path).reading, .unreadable)
        }
    }
    func testObservationHasNoWritesAndNamesContextUncertainty() throws {
        try fixture { root in
            let config = root.appendingPathComponent("config"), project = root.appendingPathComponent("worktree")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            let file = config.appendingPathComponent("settings.json"), local = project.appendingPathComponent(".claude/settings.local.json")
            let bytes = Data("{\"crossSessionInbound\":\"accept\"}".utf8)
            try bytes.write(to: file); try Data("{\"crossSessionInbound\":\"hold\"}".utf8).write(to: local)
            let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
            let date = Date(timeIntervalSince1970: 123)
            let observation = ProviderSettingsObservation.observe(projectRoot: project.path, home: root, environment: ["CLAUDE_CONFIG_DIR": config.path], managedPath: root.appendingPathComponent("managed.json").path, now: date)
            XCTAssertEqual(observation.userPath, file.path); XCTAssertEqual(observation.observedAt, date)
            XCTAssertEqual(observation.claude.state, .unknown); XCTAssertEqual(observation.claude.observedDecision, .hold)
            XCTAssertEqual(observation.claude.decidingSource, local.path)
            XCTAssertTrue(observation.claude.missingInputs.contains { $0.contains("worktree") })
            XCTAssertTrue(observation.claude.missingInputs.contains { $0.contains("primary directory") })
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        }
    }
    func testRelativeConfigAndUnknownProjectNeverResolveAgainstServiceCWD() throws {
        try fixture { root in
            let observation = ProviderSettingsObservation.observe(projectRoot: "relative", home: root, environment: ["CLAUDE_CONFIG_DIR": "relative"], managedPath: root.appendingPathComponent("absent").path)
            XCTAssertEqual(observation.sources.count, 2)
            XCTAssertEqual(observation.userPath, root.appendingPathComponent(".claude/settings.json").path)
            XCTAssertEqual(observation.claude.state, .unknown)
            XCTAssertTrue(observation.claude.missingInputs.contains { $0.contains("relative or invalid") })
        }
    }
}
