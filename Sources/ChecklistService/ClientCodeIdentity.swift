import Foundation
import Security
import ChecklistIPC

/// Code-signing requirement for every XPC client of this service: the exact bundled
/// ChecklistApp and checklist executables installed beside the service. XPC checks the
/// requirement against each message's audit token, so a reused process ID cannot pass.
enum ClientCodeIdentity {
    static func bundledRequirement() -> String? {
        let directory = ChecklistPaths.serviceExecutable.deletingLastPathComponent()
        return requirement(for: [directory.appendingPathComponent("ChecklistApp"), directory.appendingPathComponent("checklist")])
    }

    /// Nil when any executable is missing, unsigned or invalid: the service then accepts no client.
    static func requirement(for executables: [URL]) -> String? {
        var clauses: [String] = []
        for executable in executables {
            var code: SecStaticCode?
            var info: CFDictionary?
            guard SecStaticCodeCreateWithPath(executable.resolvingSymlinksInPath() as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return nil }
            clauses.append("cdhash H\"" + unique.map { String(format: "%02x", $0) }.joined() + "\"")
        }
        let text = clauses.joined(separator: " or ")
        var parsed: SecRequirement?
        guard !clauses.isEmpty, SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess else { return nil }
        return text
    }

    /// Applies the requirement before the connection resumes. Returns false to refuse the connection.
    static func restrict(_ connection: NSXPCConnection, requirement: String?) -> Bool {
        guard let requirement else {
            fputs("ChecklistService: refused a client because the bundled client signatures are unavailable.\n", stderr)
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        return true
    }
}
