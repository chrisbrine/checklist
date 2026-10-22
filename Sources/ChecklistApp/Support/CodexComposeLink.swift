import Foundation
import ChecklistProviders

/// Only the documented draft composer route is permitted; no sending or arbitrary actions.
enum CodexComposeLink {
    static func validated(_ value: String) -> URL? {
        ProviderPluginRegistry.bundled.plugin("codex", requiring: .composer)?.validateComposeURL(value)
    }
}
