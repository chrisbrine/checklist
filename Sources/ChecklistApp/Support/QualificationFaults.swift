import Foundation
import CoreFoundation
import Combine
import OSLog
import ChecklistIPC

/// App-client-only faults. Never consult a defaults search list (global,
/// argument, registration or another window's domain cannot arm a fault).
@MainActor
final class QualificationFaults: ObservableObject {
    nonisolated static let key = "checklistQualificationFaults"
    static let shared = QualificationFaults(instance: .current)
    enum Read: String { case records = "ui_records", history = "ui_history", freshContext = "recovery_ui" }
    private enum Kind: String { case cursorReset = "cursor_reset_twice", freshContext = "fresh_context_fail" }
    @Published private(set) var remaining = 0
    var isArmed: Bool { remaining > 0 }
    private let domain: String?
    private let read: (String) -> Any?
    private let write: (String, [String:Any]) -> Void
    private let log: (String) -> Void

    init(instance: ChecklistInstance, read: @escaping (String) -> Any? = QualificationFaults.readPreference,
         write: @escaping (String, [String:Any]) -> Void = QualificationFaults.writePreference,
         log: @escaping (String) -> Void = { Logger(subsystem:"org.checklist.app",category:"QualificationFaults").notice("\($0,privacy:.public)") }) {
        domain = instance.slot == nil ? nil : instance.bundleIdentifier
        self.read = read; self.write = write; self.log = log
        refresh()
    }

    nonisolated private static func readPreference(_ domain: String) -> Any? {
        CFPreferencesSynchronize(domain as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString,domain as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)
    }
    nonisolated private static func writePreference(_ domain: String, _ value: [String:Any]) {
        CFPreferencesSetValue(key as CFString,value as CFDictionary,domain as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)
    }
    private func configuration() -> (Kind,Int)? {
        // This guard precedes even the read closure: the live app never reads the key.
        guard let domain, let value = read(domain) as? [String:Any],
              let name = value["selected_records"] as? String, let kind = Kind(rawValue:name),
              let number = value["remaining"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f","d"].contains(String(cString:number.objCType)), number.intValue > 0,
              number == NSNumber(value:number.intValue) else { return nil }
        return (kind,number.intValue)
    }
    func refresh() { remaining = configuration()?.1 ?? 0 }

    func inject(_ boundary: Read) throws {
        guard let (kind,count) = configuration(), let domain else { remaining = 0; return }
        remaining = count
        if boundary == .freshContext && kind != .freshContext { return }
        remaining = count - 1
        write(domain,["selected_records":kind.rawValue,"remaining":remaining])
        let code = boundary == .freshContext ? "QUALIFICATION_FRESH_CONTEXT_FAILED" : "CURSOR_RESET"
        log("TEST FAULT slot-domain=\(domain) read=\(boundary.rawValue) code=\(code) remaining=\(remaining)")
        throw ChecklistError(code,boundary == .freshContext
            ? "TEST FAULT: selected-ticket fresh context read failed."
            : "TEST FAULT: selected-record context reset.")
    }
}
