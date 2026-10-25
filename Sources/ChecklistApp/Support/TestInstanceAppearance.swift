import AppKit
import OSLog
import ChecklistIPC

/// A launch-only override for bundle-identified test instances; never a saved preference.
enum TestInstanceAppearance {
    static let argumentKey = "ChecklistTestAppearance"
    static let environmentKey = "CHECKLIST_TEST_APPEARANCE"

    static func resolve(instance: ChecklistInstance = .current,
                        readArgument: () -> Any? = { UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[argumentKey] },
                        readEnvironment: () -> String? = { ProcessInfo.processInfo.environment[environmentKey] },
                        log: (String) -> Void = logNotice) -> NSAppearance.Name? {
        // Do not even read the override inputs in a production app.
        guard instance.slot != nil else { return nil }
        guard let value = readArgument() ?? readEnvironment() else { return nil }
        switch value as? String {
        case "dark": return .darkAqua
        case "light": return .aqua
        default:
            log("Ignoring invalid Checklist test appearance; expected dark or light.")
            return nil
        }
    }

    private static func logNotice(_ message: String) {
        Logger(subsystem: "org.checklist.app", category: "TestInstanceAppearance").notice("\(message, privacy: .public)")
    }
}
