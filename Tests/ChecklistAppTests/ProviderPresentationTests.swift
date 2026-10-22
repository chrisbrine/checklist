import XCTest
import ChecklistProviders
@testable import ChecklistApp

final class ProviderPresentationTests: XCTestCase {
    func testUnknownProviderHasNoFallbackHostOrComposer() {
        let provider = HandoffProvider(id: "missing")
        XCTAssertFalse(provider.isAvailable)
        XCTAssertEqual(provider.name, "Unavailable provider (missing)")
        XCTAssertNotNil(provider.unavailabilityReason)
        XCTAssertNil(provider.bundleID)
        XCTAssertNil(provider.validatedComposeURL("codex://threads/new?prompt=Review"))
    }

    func testRegisteredProviderSuppliesItsOwnNameHostAndComposer() throws {
        let plugin = SyntheticProviderPlugin(id: "alternate", name: "Alternate Workbench")
        let registry = try adding(plugin)
        let provider = HandoffProvider(id: "alternate", registry: registry)
        XCTAssertEqual(HandoffProvider.workProviders(in: registry).map(\.id), ["codex", "claude", "alternate"])
        XCTAssertTrue(provider.isAvailable)
        XCTAssertEqual(provider.name, "Alternate Workbench")
        XCTAssertEqual(provider.bundleID, "org.example.alternate")
        XCTAssertNotNil(provider.validatedComposeURL("alternate://draft"))
        XCTAssertNil(provider.validatedComposeURL("codex://threads/new?prompt=Review"))
        XCTAssertNil(HandoffProvider(id: "codex", registry: registry).validatedComposeURL("alternate://draft"))
    }

    func testDisabledAndUnqualifiedComposerCapabilitiesStayUnavailable() throws {
        let plugin = SyntheticProviderPlugin(id: "future", name: "Future Workbench")
        let disabled = try adding(plugin, enabled: false)
        XCTAssertFalse(HandoffProvider.workProviders(in: disabled).contains { $0.id == "future" })
        let provider = HandoffProvider(id: "future", registry: disabled)
        XCTAssertFalse(provider.isAvailable)
        XCTAssertNil(provider.bundleID)
        XCTAssertNil(provider.validatedComposeURL("future://draft"))
        let workOnly = try adding(plugin, qualified: [.workSession, .pickup, .correlatedReply])
        XCTAssertTrue(HandoffProvider(id: "future", registry: workOnly).isAvailable)
        XCTAssertNil(HandoffProvider(id: "future", registry: workOnly).validatedComposeURL("future://draft"))
        XCTAssertNil(HandoffProvider(id: "claude").validatedComposeURL("codex://threads/new?prompt=Review"))
    }

    func testCodexCompatibilityEntryPointKeepsComposerRouteValidation() {
        XCTAssertNotNil(CodexComposeLink.validated("codex://threads/new?prompt=Review"))
        for raw in ["codex://threads/new?prompt=", "codex://threads/new?prompt=A&prompt=B", "codex://threads/delete?prompt=Review", "claude://threads/new?prompt=Review", "codex://threads/new?prompt=Review&send=true"] {
            XCTAssertNil(CodexComposeLink.validated(raw), raw)
        }
    }

    func testReviewChoicesIntersectQualifiedProvidersProjectAndKindPolicy() throws {
        let registry = try adding(SyntheticProviderPlugin(id: "alternate", name: "Alternate Workbench"))
        let policy: [String: Any] = ["allowed_providers": ["codex", "alternate", "missing"],
            "roles": ["reviewer": ["providers": ["claude", "alternate", "missing"]]],
            "task_kind_overrides": [["kind": "asset", "roles": ["reviewer": ["providers": ["codex", "missing"]]]]]]
        XCTAssertEqual(HandoffProvider.eligibleIDs(role: "reviewer", policy: policy, registry: registry), ["alternate"])
        XCTAssertEqual(HandoffProvider.eligibleIDs(role: "reviewer", policy: policy, taskKind: "asset", registry: registry), ["codex"])
    }

    func testPolicyPickerPreservesExactSubsetAndOpaqueModelPreferences() throws {
        let registry = try adding(SyntheticProviderPlugin(id: "alternate", name: "Alternate Workbench"))
        let original: [String: Any] = ["providers": ["codex", "alternate"], "preferred_provider": "alternate",
            "preferred_models": ["only-a-stored-preference"]]
        let selection = PolicyProviderChoices.choice(original, fallback: "both", registry: registry)
        XCTAssertNotEqual(selection, "both")
        let role = PolicyProviderChoices.role(selection, existing: original, registry: registry)
        XCTAssertEqual(role["providers"] as? [String], ["codex", "alternate"])
        XCTAssertEqual(role["preferred_provider"] as? String, "alternate")
        XCTAssertEqual(role["preferred_models"] as? [String], ["only-a-stored-preference"])
        XCTAssertEqual(PolicyProviderChoices.label(selection, registry: registry), "Codex or Alternate Workbench")
        XCTAssertEqual(PolicyProviderChoices.providers("both", registry: registry), ["codex", "claude", "alternate"])
    }

    func testCompatibilityPresetDefaultsRemainProviderPolicyDefaults() {
        XCTAssertEqual(ProviderPolicyDefaults.presets, ["shared", "claude_coordinates", "codex_led"])
        XCTAssertEqual(PolicyProviderChoices.providers(PolicyProviderChoices.defaultChoice(role: "coordinator", preset: "claude_coordinates")), ["claude"])
        XCTAssertEqual(PolicyProviderChoices.providers(PolicyProviderChoices.defaultChoice(role: "implementer", preset: "codex_led")), ["codex"])
        XCTAssertEqual(PolicyProviderChoices.providers(PolicyProviderChoices.defaultChoice(role: "reviewer", preset: "shared", allowed: ["claude"])), ["claude"])
    }

    private func adding(_ plugin: SyntheticProviderPlugin, enabled: Bool = true, qualified: Set<ProviderCapability>? = nil) throws -> ProviderPluginRegistry {
        try ProviderPluginRegistry(ProviderPluginRegistry.bundled.registrations + [
            .init(plugin: plugin, enabled: enabled, qualifiedCapabilities: qualified ?? plugin.manifest.capabilities)
        ])
    }
}

private struct SyntheticProviderPlugin: ChecklistProviderPlugin {
    let id: String
    let name: String
    var manifest: ProviderPluginManifest {
        .init(pluginID: "org.example.\(id)", version: "1.0.0", providerID: id, displayName: name,
              capabilities: [.workSession, .pickup, .correlatedReply, .composer])
    }
    var nativeHost: ProviderNativeHost? {
        .init(executable: id, signingIdentifier: id, signingTeam: "TEST", applicationBundleID: "org.example.\(id)", registryDirectory: nil, identityVerification: "synthetic-fixture")
    }
    func validateComposeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == id else { return nil }
        return url
    }
}
