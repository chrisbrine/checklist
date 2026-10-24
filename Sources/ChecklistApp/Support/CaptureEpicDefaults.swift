import Foundation

/// Last successfully used Epic, shared by normal and floating capture per project.
enum CaptureEpicDefaults {
    static func key(_ project: String) -> String { "captureLastEpic." + project }
    static func last(_ project: String,preferences: UserDefaults) -> String { preferences.string(forKey:key(project)) ?? "" }
    static func remember(_ epic: String,project: String,preferences: UserDefaults) {
        guard !epic.isEmpty else { return }
        preferences.set(epic,forKey:key(project))
    }
}
