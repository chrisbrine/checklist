import AppKit
import UserNotifications

/// CL-53: the Dock icon shows how many items wait in Needs You. It clears at zero and the owner can
/// turn it off in Settings (General > Workspace).
enum DockBadge {
    static let key = "showDockBadge"
    static func label(count: Int, enabled: Bool) -> String? {
        guard enabled, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }
    @MainActor static func apply(count: Int, defaults: UserDefaults = .standard) {
        let enabled = defaults.object(forKey: key) as? Bool ?? true
        guard let app = NSApp else { return }
        let value = label(count: count, enabled: enabled)
        if app.dockTile.badgeLabel != value { app.dockTile.badgeLabel = value }
    }
    /// macOS draws an app's Dock badge only when the app may badge its icon (a notification permission
    /// that the owner controls). The app sets the label either way.
    static func macOSAllowsBadge() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled
    }
    /// The owner's direction for CL-53 (request a6c0bf5d, 20 October 2026): the badge is on by default and macOS
    /// asks for its permission by itself the first time. macOS shows that prompt once per app, so it covers badges
    /// and alerts; desktop alerts still stay off in Checklist until the owner turns them on.
    @MainActor static func requestPermissionIfNeeded(defaults: UserDefaults = .standard) async {
        guard defaults.object(forKey: key) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.badge, .alert])
    }
    /// macOS Notifications settings, where the owner can allow the badge after declining the prompt.
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
