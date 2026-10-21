import Foundation
import Darwin
import ChecklistIPC

// The same early check as ChecklistCommand; this probe has no IPC or Keychain route.
do {
    if ProcessInfo.processInfo.environment[DelegateInstanceExpectation.environmentKey] != nil {
        try DelegateInstanceExpectation.verifyIfPresent(instance: ChecklistInstance.current)
    }
} catch {
    FileHandle.standardError.write(Data("Checklist: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// A service-free child for the real stdin boundary and termination checks.
if CommandLine.arguments.dropFirst().first == "signal" {
    FileHandle.standardError.write(Data("Checklist: connected after 3 attempts in 500 ms\n".utf8))
    raise(SIGKILL)
    exit(2)
}
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard Array(arguments.prefix(3)) == ["call", "synthetic", "-"] else {
        throw ChecklistError("INVALID_INPUT", "The synthetic probe requires call synthetic -.")
    }
    let input = try CallArgumentInput.read(arguments[2])
    _ = try JSONSerialization.jsonObject(with: input)
    let result: [String: Any] = ["bytes": input.count, "arguments": arguments,
        "directory": FileManager.default.currentDirectoryPath,
        "environment": ProcessInfo.processInfo.environment["CL171_VALUE"] ?? "missing"]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
} catch {
    FileHandle.standardError.write(Data("Checklist: \(error.localizedDescription)\n".utf8))
    exit(1)
}
