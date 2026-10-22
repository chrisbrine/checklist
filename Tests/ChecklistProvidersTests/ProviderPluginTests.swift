import XCTest
@testable import ChecklistProviders

final class ProviderPluginTests: XCTestCase {
    struct Fixture: ChecklistProviderPlugin {
        let manifest: ProviderPluginManifest
        init(provider: String = "synthetic", plugin: String = "example.synthetic", interface: Int = 1,
             capabilities: Set<ProviderCapability> = [.workSession, .pickup, .correlatedReply]) {
            manifest = .init(interfaceVersion:interface,pluginID:plugin,version:"1.0.0",providerID:provider,displayName:"Synthetic fixture",capabilities:capabilities)
        }
    }
    func testBundledCapabilitiesPreserveHonestLimits() throws {
        let registry = ProviderPluginRegistry.bundled
        XCTAssertEqual(registry.workProviders,["codex","claude"])
        XCTAssertNotNil(registry.plugin("codex",requiring:.composer))
        XCTAssertNil(registry.plugin("codex",requiring:.nativePeer))
        XCTAssertNil(registry.plugin("codex",requiring:.registryClosure))
        XCTAssertNotNil(registry.plugin("claude",requiring:.nativePeer))
        XCTAssertNil(registry.plugin("claude",requiring:.composer))
        XCTAssertNil(registry.plugin("unknown",requiring:.pickup))
    }
    func testSyntheticPluginRegistersWithoutEnablingRoutes() throws {
        let registry = try ProviderPluginRegistry(ProviderPluginRegistry.bundled.registrations + [.init(plugin:Fixture())])
        XCTAssertEqual(registry.workProviders,["codex","claude"])
        XCTAssertEqual(registry.summaries.last?["provider_id"] as? String,"synthetic")
        XCTAssertEqual(registry.summaries.last?["availability"] as? String,"disabled")
        XCTAssertNil(registry.plugin("synthetic",requiring:.workSession))
        XCTAssertNil(registry.plugin("synthetic",requiring:.pickup))
    }
    func testEnabledMetadataStillNeedsHostQualification() throws {
        let registry = try ProviderPluginRegistry([.init(plugin:Fixture(),enabled:true)])
        XCTAssertEqual(registry.summaries.first?["availability"] as? String,"unqualified")
        XCTAssertNil(registry.plugin("synthetic",requiring:.workSession))
    }
    func testIncompatibleAndDuplicateRegistrationsRefuse() throws {
        XCTAssertThrowsError(try ProviderPluginRegistry([.init(plugin:Fixture(interface:2))]))
        XCTAssertThrowsError(try ProviderPluginRegistry([.init(plugin:Fixture()),.init(plugin:Fixture())]))
        XCTAssertThrowsError(try ProviderPluginRegistry([.init(plugin:Fixture()),.init(plugin:Fixture(provider:"another"))]))
        XCTAssertThrowsError(try ProviderPluginRegistry([.init(plugin:Fixture(),qualifiedCapabilities:[.nativePeer])]))
        XCTAssertThrowsError(try ProviderPluginRegistry([.init(plugin:Fixture(),qualifiedCapabilities:[.workSession])]))
    }
    func testManifestDecoderRejectsUnknownFieldsCapabilitiesAndDuplicates() throws {
        let original = try JSONEncoder().encode(CodexProviderPlugin().manifest)
        XCTAssertEqual(try ProviderPluginManifest.decode(original),CodexProviderPlugin().manifest)
        var raw = try JSONSerialization.jsonObject(with:original) as! [String:Any]
        raw["launch_command"] = "do not execute"
        XCTAssertThrowsError(try ProviderPluginManifest.decode(JSONSerialization.data(withJSONObject:raw)))
        raw.removeValue(forKey:"launch_command");raw["capabilities"] = ["automaticLaunch"]
        XCTAssertThrowsError(try ProviderPluginManifest.decode(JSONSerialization.data(withJSONObject:raw)))
        raw["capabilities"] = ["pickup","pickup"]
        XCTAssertThrowsError(try ProviderPluginManifest.decode(JSONSerialization.data(withJSONObject:raw)))
    }
    func testManifestVersionAndCapabilityDependenciesValidate() throws {
        XCTAssertThrowsError(try Fixture(capabilities:[.workSession]).manifest.validate())
        XCTAssertThrowsError(try Fixture(capabilities:[.registryClosure]).manifest.validate())
        let invalid = ProviderPluginManifest(pluginID:"example.fixture",version:"latest",providerID:"fixture",displayName:"Fixture",capabilities:[])
        XCTAssertThrowsError(try invalid.validate())
        let badModel = ProviderPluginManifest(pluginID:"example.fixture",version:"1.0.0",providerID:"fixture",displayName:"Fixture",capabilities:[],models:[.init(id:"m",name:"Model",selectable:true)])
        XCTAssertThrowsError(try badModel.validate())
    }
    func testUnknownModelsAndProvidersNeverSelectFallback() throws {
        for provider in ["codex","claude","unknown"] {
            XCTAssertThrowsError(try ProviderPluginRegistry.bundled.model("future-model",provider:provider)) { XCTAssertEqual($0 as? ProviderPluginError,.unqualifiedModel) }
        }
    }
    func testCodexChildIdentityCannotFallBackToParent() throws {
        let plugin = CodexProviderPlugin(), parent = UUID().uuidString
        XCTAssertNil(plugin.observe(environment:["CODEX_THREAD_ID":"bad","CODEX_SESSION_ID":parent],workspace:"/tmp",registry:nil))
        XCTAssertEqual(plugin.observe(environment:["CODEX_SESSION_ID":parent],workspace:"/tmp",registry:nil)?.sessionID,parent.lowercased())
        XCTAssertNil(plugin.observe(environment:["CLAUDE_SESSION_ID":parent],workspace:"/tmp",registry:nil))
    }
    func testClaudeRegistryPreservesWorkspaceAndEndpointIdentity() throws {
        let plugin = ClaudeProviderPlugin(), session = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let record: [String:Any] = ["pid":123,"sessionId":session,"cwd":root,"messagingSocketPath":"/tmp/cc-socks/123.sock","name":"\u{1}Session"]
        let environment = ["CLAUDE_SESSION_ID":session,"CLAUDE_CODE_MESSAGING_SOCKET":"uds:/tmp/cc-socks/123.sock"]
        XCTAssertEqual(plugin.observe(environment:environment,workspace:root,registry:record)?.title,"Session")
        XCTAssertNil(plugin.observe(environment:["CLAUDE_SESSION_ID":UUID().uuidString],workspace:root,registry:record))
        XCTAssertNil(plugin.observe(environment:environment,workspace:"/unrelated",registry:record))
        XCTAssertTrue(plugin.registryMatches(record,processID:123,sessionID:session,workspace:root,endpoint:"/tmp/cc-socks/123.sock"))
        XCTAssertFalse(plugin.registryMatches(record,processID:124,sessionID:session,workspace:root,endpoint:nil))
        XCTAssertFalse(plugin.registryMatches(record,processID:123,sessionID:session,workspace:root,endpoint:"/tmp/other.sock"))
        XCTAssertEqual(plugin.registryMismatchMessage,"Claude's current session registry does not match this native process and workspace.")
    }
    func testComposerEscapesPromptAndRejectsActionsAndUnknownProvider() throws {
        let plugin = CodexProviderPlugin(), root = FileManager.default.temporaryDirectory.path, prompt = "Fix & review #1? 日本語"
        let url = try XCTUnwrap(plugin.composeURL(instruction:prompt,workspace:root))
        XCTAssertEqual(plugin.validateComposeURL(url.absoluteString),url)
        XCTAssertEqual(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,prompt)
        for url in ["codex://threads/new?prompt=a&send=true","codex://threads/new?prompt=a&prompt=b","codex://threads/delete?prompt=a","https://threads/new?prompt=a","codex://user@threads/new?prompt=a"] { XCTAssertNil(plugin.validateComposeURL(url)) }
        XCTAssertNil(ClaudeProviderPlugin().composeURL(instruction:prompt,workspace:root))
        XCTAssertNil(plugin.composeURL(instruction:prompt,workspace:"/nonexistent/fixture-root"))
    }
    func testCompatibleVersionUpdateAndDisableDoNotMutateEarlierRegistry() throws {
        let original = ProviderPluginRegistry.bundled
        let disabled = try ProviderPluginRegistry(original.registrations.map { .init(plugin:$0.plugin) })
        XCTAssertTrue(disabled.workProviders.isEmpty)
        XCTAssertEqual(original.workProviders,["codex","claude"])
        XCTAssertEqual(disabled.registrations.map { $0.plugin.manifest.pluginID },original.registrations.map { $0.plugin.manifest.pluginID })
    }
    func testLegacyPolicyPresetsStayExplicit() {
        XCTAssertEqual(ProviderPolicyDefaults.providers(role:"coordinator",preset:"claude_coordinates",allowed:["codex","claude"]),["claude"])
        XCTAssertEqual(ProviderPolicyDefaults.providers(role:"implementer",preset:"codex_led",allowed:["codex","claude"]),["codex"])
        XCTAssertEqual(ProviderPolicyDefaults.providers(role:"reviewer",preset:"shared",allowed:["codex","claude"]),["codex","claude"])
    }
    func testModelIDsRequireExactBytesWithoutCanonicalUnicodeFallback() throws {
        struct Catalog: ChecklistProviderPlugin {
            let manifest = ProviderPluginManifest(pluginID:"example.catalog",version:"1.0.0",providerID:"catalog",displayName:"Synthetic catalog",capabilities:[.modelSelection],models:[.init(id:"caf\u{e9}",name:"Synthetic model",selectable:true)])
        }
        let registry = try ProviderPluginRegistry([.init(plugin:Catalog(),enabled:true,qualifiedCapabilities:[.modelSelection])])
        XCTAssertEqual(try registry.model("caf\u{e9}",provider:"catalog").id.utf8.map { $0 },Array("caf\u{e9}".utf8))
        XCTAssertThrowsError(try registry.model("cafe\u{301}",provider:"catalog"))
    }

}
