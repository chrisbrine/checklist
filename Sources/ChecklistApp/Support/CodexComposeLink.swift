import Foundation

/// Only the documented draft composer route is permitted; no sending or arbitrary actions.
enum CodexComposeLink {
    static func validated(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "codex", parts.host == "threads", parts.path == "/new", parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).isSubset(of: ["prompt", "path"]), items.filter({ $0.name == "prompt" }).count == 1, let prompt = items.first(where: { $0.name == "prompt" })?.value, !prompt.isEmpty, items.filter({ $0.name == "path" }).count <= 1 else { return nil }
        if let item = items.first(where: { $0.name == "path" }) {
            guard let path = item.value, path.hasPrefix("/") else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        }
        return parts.url
    }
}
