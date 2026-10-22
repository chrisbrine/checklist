import Foundation

/// Versioned, portable metadata. These are capabilities, never project grants or
/// proof that a particular peer/session/model is authorized or currently reachable.
public enum ProviderCapability: String, Codable, CaseIterable, Sendable {
    case workSession = "work_session", pickup, correlatedReply = "correlated_reply", nativePeer = "native_peer"
    case registryClosure = "registry_closure", composer, assistantRelay = "assistant_relay", answerNotice = "answer_notice", modelSelection = "model_selection"
}

public struct ProviderModel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let selectable: Bool
    public init(id: String, name: String, selectable: Bool = false) { self.id = id; self.name = name; self.selectable = selectable }
}

public struct ProviderPluginManifest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", interfaceVersion = "interface_version", pluginID = "plugin_id", version
        case providerID = "provider_id", displayName = "display_name", capabilities, models
    }
    public let schemaVersion: Int
    public let interfaceVersion: Int
    public let pluginID: String
    public let version: String
    public let providerID: String
    public let displayName: String
    public let capabilities: Set<ProviderCapability>
    public let models: [ProviderModel]
    public init(schemaVersion: Int = 1, interfaceVersion: Int = 1, pluginID: String, version: String,
                providerID: String, displayName: String, capabilities: Set<ProviderCapability>, models: [ProviderModel] = []) {
        self.schemaVersion = schemaVersion; self.interfaceVersion = interfaceVersion; self.pluginID = pluginID
        self.version = version; self.providerID = providerID; self.displayName = displayName
        self.capabilities = capabilities; self.models = models
    }
    public static func decode(_ data: Data) throws -> ProviderPluginManifest {
        guard data.count <= 65_536, let raw = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              Set(raw.keys) == Set(["schema_version","interface_version","plugin_id","version","provider_id","display_name","capabilities","models"]),
              let capabilities = raw["capabilities"] as? [String], Set(capabilities).count == capabilities.count,
              let models = raw["models"] as? [[String:Any]], models.allSatisfy({ Set($0.keys) == Set(["id","name","selectable"]) }) else { throw ProviderPluginError.invalidManifest }
        let manifest = try JSONDecoder().decode(ProviderPluginManifest.self,from:data)
        try manifest.validate(); return manifest
    }
    public func validate() throws {
        func bounded(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 160 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        func identifier(_ text: String) -> Bool { bounded(text) && text.range(of: "^[a-z][a-z0-9.-]*$", options: .regularExpression) != nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard schemaVersion == 1, interfaceVersion == 1, identifier(pluginID), identifier(providerID), bounded(displayName), bounded(version),
              parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && UInt($0) != nil }),
              models.count <= 128, Set(models.map { Data($0.id.utf8) }).count == models.count,
              models.allSatisfy({ bounded($0.id) && bounded($0.name) && (!$0.selectable || capabilities.contains(.modelSelection)) }),
              !capabilities.contains(.workSession) || capabilities.isSuperset(of: [.pickup, .correlatedReply]),
              !capabilities.contains(.nativePeer) || capabilities.contains(.correlatedReply),
              !capabilities.contains(.registryClosure) || capabilities.contains(.workSession) else {
            throw ProviderPluginError.invalidManifest
        }
    }
}

public enum ProviderPluginError: Error, Equatable { case invalidManifest, duplicateProvider, unavailable, unqualifiedModel }

public struct ProviderNativeHost: Sendable {
    public let executable: String
    public let signingIdentifier: String
    public let signingTeam: String
    public let applicationBundleID: String
    public let registryDirectory: String?
    public let identityVerification: String
    public init(executable: String, signingIdentifier: String, signingTeam: String, applicationBundleID: String,
                registryDirectory: String?, identityVerification: String) {
        self.executable = executable; self.signingIdentifier = signingIdentifier; self.signingTeam = signingTeam
        self.applicationBundleID = applicationBundleID; self.registryDirectory = registryDirectory; self.identityVerification = identityVerification
    }
    public func registryPath(processID: Int32, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        registryDirectory.map { home.appendingPathComponent($0).appendingPathComponent("\(processID).json").path }
    }
}

public struct ProviderObservedSession: Equatable, Sendable {
    public let sessionID: String
    public let workspace: String
    public let endpoint: String?
    public let title: String?
    public init(sessionID: String, workspace: String, endpoint: String? = nil, title: String? = nil) {
        self.sessionID = sessionID; self.workspace = workspace; self.endpoint = endpoint; self.title = title
    }
}

/// Reviewed implementations are linked into the bundle, not loaded from paths,
/// manifests, task text or a download. OS-specific I/O remains in Bridges/Service.
public protocol ChecklistProviderPlugin: Sendable {
    var manifest: ProviderPluginManifest { get }
    var nativeHost: ProviderNativeHost? { get }
    var registryMismatchMessage: String { get }
    func registryMatches(_ record: [String: Any], processID: Int32, sessionID: String, workspace: String, endpoint: String?) -> Bool
    func hostStatusReason(_ status: String) -> String?
    func observe(environment: [String: String], workspace: String, registry: [String: Any]?) -> ProviderObservedSession?
    func composeURL(instruction: String, workspace: String) -> URL?
    func validateComposeURL(_ value: String) -> URL?
}

public extension ChecklistProviderPlugin {
    var nativeHost: ProviderNativeHost? { nil }
    var registryMismatchMessage: String { "The current provider session registry does not match this native process and workspace." }
    func registryMatches(_ record: [String: Any], processID: Int32, sessionID: String, workspace: String, endpoint: String?) -> Bool { false }
    func hostStatusReason(_ status: String) -> String? { nil }
    func observe(environment: [String: String], workspace: String, registry: [String: Any]?) -> ProviderObservedSession? { nil }
    func composeURL(instruction: String, workspace: String) -> URL? { nil }
    func validateComposeURL(_ value: String) -> URL? { nil }
}

public struct ProviderPluginRegistration: Sendable {
    public let plugin: any ChecklistProviderPlugin
    public let enabled: Bool
    /// Supplied by the reviewed host packaging/qualification record, not a manifest.
    public let qualifiedCapabilities: Set<ProviderCapability>
    public init(plugin: any ChecklistProviderPlugin, enabled: Bool = false, qualifiedCapabilities: Set<ProviderCapability> = []) {
        self.plugin = plugin; self.enabled = enabled; self.qualifiedCapabilities = qualifiedCapabilities
    }
}

public struct ProviderPluginRegistry: Sendable {
    public let registrations: [ProviderPluginRegistration]
    public init(_ registrations: [ProviderPluginRegistration]) throws {
        var providers = Set<String>(), plugins = Set<String>()
        for registration in registrations {
            let manifest = registration.plugin.manifest
            try manifest.validate()
            guard providers.insert(manifest.providerID).inserted, plugins.insert(manifest.pluginID).inserted else { throw ProviderPluginError.duplicateProvider }
            guard registration.qualifiedCapabilities.isSubset(of: manifest.capabilities),
                  !registration.qualifiedCapabilities.contains(.workSession) || registration.qualifiedCapabilities.isSuperset(of: [.pickup, .correlatedReply]),
                  !registration.qualifiedCapabilities.contains(.nativePeer) || registration.qualifiedCapabilities.contains(.correlatedReply),
                  !registration.qualifiedCapabilities.contains(.registryClosure) || registration.qualifiedCapabilities.contains(.workSession) else { throw ProviderPluginError.invalidManifest }
        }
        self.registrations = registrations
    }
    public func plugin(_ providerID: String, requiring capability: ProviderCapability) -> (any ChecklistProviderPlugin)? {
        registrations.first { $0.enabled && $0.plugin.manifest.providerID == providerID && $0.qualifiedCapabilities.contains(capability) }?.plugin
    }
    public var workProviders: [String] { registrations.compactMap { plugin($0.plugin.manifest.providerID, requiring: .workSession)?.manifest.providerID } }
    public func model(_ id: String, provider: String) throws -> ProviderModel {
        guard let plugin = plugin(provider, requiring: .modelSelection), let model = plugin.manifest.models.first(where: { $0.id.utf8.elementsEqual(id.utf8) && $0.selectable }) else { throw ProviderPluginError.unqualifiedModel }
        return model
    }
    public var summaries: [[String: Any]] {
        registrations.map { entry in
            let m = entry.plugin.manifest
            return ["schema_version":m.schemaVersion, "interface_version":m.interfaceVersion, "plugin_id":m.pluginID, "version":m.version,
                    "provider_id":m.providerID, "display_name":m.displayName, "enabled":entry.enabled, "availability":entry.enabled ? (entry.qualifiedCapabilities.isEmpty ? "unqualified" : "available") : "disabled",
                    "capabilities":m.capabilities.map(\.rawValue).sorted(), "qualified_capabilities":entry.qualifiedCapabilities.map(\.rawValue).sorted(),
                    "models":m.models.map { ["id":$0.id, "name":$0.name, "selectable":$0.selectable && entry.enabled && entry.qualifiedCapabilities.contains(.modelSelection)] as [String:Any] }]
        }
    }
    public static let bundled: ProviderPluginRegistry = {
        // Host-owned allowlists are deliberately independent of each manifest.
        // A newly declared capability is unavailable until separately qualified.
        return try! ProviderPluginRegistry([
            .init(plugin:CodexProviderPlugin(),enabled:true,
                  qualifiedCapabilities:[.workSession,.pickup,.correlatedReply,.composer,.assistantRelay,.answerNotice]),
            .init(plugin:ClaudeProviderPlugin(),enabled:true,
                  qualifiedCapabilities:[.workSession,.pickup,.correlatedReply,.nativePeer,.registryClosure])
        ])
    }()
}
