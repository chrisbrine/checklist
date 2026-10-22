import Foundation
import ChecklistProviders

/// Presentation follows the same enabled, qualified registry as service routing.
/// A stored provider ID alone never supplies a host or composer capability.
struct HandoffProvider: Identifiable {
    let id: String
    private let registry: ProviderPluginRegistry

    init(id: String, registry: ProviderPluginRegistry = .bundled) {
        self.id = id
        self.registry = registry
    }

    private var plugin: (any ChecklistProviderPlugin)? { registry.plugin(id, requiring: .workSession) }
    var isAvailable: Bool { plugin != nil }
    var name: String { plugin?.manifest.displayName ?? "Unavailable provider (\(id))" }
    var bundleID: String? { plugin?.nativeHost?.applicationBundleID }
    var unavailabilityReason: String? {
        isAvailable ? nil : "\(name) is not enabled and qualified for Checklist work in this build."
    }

    func validatedComposeURL(_ value: String) -> URL? {
        guard isAvailable else { return nil }
        return registry.plugin(id, requiring: .composer)?.validateComposeURL(value)
    }

    static func workProviders(in registry: ProviderPluginRegistry = .bundled) -> [HandoffProvider] {
        registry.workProviders.map { HandoffProvider(id: $0, registry: registry) }
    }

    static func eligibleIDs(role: String, policy: [String: Any], taskKind: String = "", registry: ProviderPluginRegistry = .bundled) -> [String] {
        let allowed = policy["allowed_providers"] as? [String] ?? registry.workProviders
        var roles = policy["roles"] as? [String: Any] ?? [:]
        if let override = (policy["task_kind_overrides"] as? [[String: Any]] ?? []).first(where: { $0["kind"] as? String == taskKind }) {
            for (key, value) in override["roles"] as? [String: Any] ?? [:] { roles[key] = value }
        }
        let rule = roles[role] as? [String: Any] ?? [:]
        let requested = rule["providers"] as? [String] ?? ProviderPolicyDefaults.providers(role: role, preset: policy["routing_preset"] as? String ?? "shared", allowed: allowed)
        return registry.workProviders.filter { allowed.contains($0) && requested.contains($0) }
    }
}

/// "both" is a legacy local picker value. Persisted policies always carry exact
/// provider arrays, including a custom subset when more providers are registered.
enum PolicyProviderChoices {
    private static let subsetPrefix = "providers:"

    static func providers(_ selection: String, registry: ProviderPluginRegistry = .bundled) -> [String] {
        if selection == "both" { return registry.workProviders }
        if selection.hasPrefix(subsetPrefix) { return selection.dropFirst(subsetPrefix.count).split(separator: ",").map(String.init) }
        return selection.isEmpty ? [] : [selection]
    }

    static func selection(_ providers: [String], registry: ProviderPluginRegistry = .bundled) -> String {
        if providers == registry.workProviders { return "both" }
        if providers.count == 1 { return providers[0] }
        return subsetPrefix + providers.joined(separator: ",")
    }

    static func choice(_ rule: Any?, fallback: String, registry: ProviderPluginRegistry = .bundled) -> String {
        guard let rule = rule as? [String: Any], let providers = rule["providers"] as? [String] else { return fallback }
        return selection(providers, registry: registry)
    }

    static func defaultChoice(role: String, preset: String, allowed: [String]? = nil, registry: ProviderPluginRegistry = .bundled) -> String {
        selection(ProviderPolicyDefaults.providers(role: role, preset: preset, allowed: allowed ?? registry.workProviders), registry: registry)
    }

    static func role(_ selection: String, existing: Any? = nil, registry: ProviderPluginRegistry = .bundled) -> [String: Any] {
        let values = providers(selection, registry: registry), old = existing as? [String: Any] ?? [:]
        let preferred = (old["preferred_provider"] as? String).flatMap { values.contains($0) ? $0 : nil } ?? values.first
        return ["providers": values, "preferred_provider": preferred.map { $0 as Any } ?? NSNull(),
                "preferred_models": old["preferred_models"] as? [String] ?? []]
    }

    static func label(_ selection: String, registry: ProviderPluginRegistry = .bundled) -> String {
        let names = providers(selection, registry: registry).map { HandoffProvider(id: $0, registry: registry).name }
        return names.isEmpty ? "No providers" : names.joined(separator: " or ")
    }
}
