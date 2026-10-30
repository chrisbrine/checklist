import Foundation
import os
#if os(macOS)
import Darwin
#endif

/// Native-only source inventory effects. SourceGit validates the executable,
/// protected roots and sanitized environment before handing off this invocation.
struct SourceGitProcessRequest {
    let launcher: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let acceptedExitCodes: Set<Int32>
    let gitExecutable: String
}

protocol SourceGitProcessAdapter {
    func run(_ request: SourceGitProcessRequest) throws -> Data
}

extension SourceGit {
    /// Internal test seam (CL-363), reachable only through `@testable import`. Nil
    /// in the product. Confinement, trust and argv are still built before it runs.
    static let fixtureProcessAdapter = OSAllocatedUnfairLock<(any SourceGitProcessAdapter)?>(uncheckedState: nil)
}

/// A platform without the protected-root launcher must fail closed. It must not
/// run Git directly or introduce a different CLI/helper/model fallback.
struct UnsupportedSourceGitProcessAdapter: SourceGitProcessAdapter {
    func run(_ request: SourceGitProcessRequest) throws -> Data {
        throw SourceGit.Confinement.unavailable()
    }
}

struct MacOSSourceGitProcessAdapter: SourceGitProcessAdapter {
    func run(_ request: SourceGitProcessRequest) throws -> Data {
#if os(macOS)
        let executable = request.gitExecutable
        let timeout = request.timeout
        let acceptedExitCodes = request.acceptedExitCodes
        let process = Process(), out = Pipe(), err = Pipe(), exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: request.launcher)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        let readers = DispatchGroup()
        let results = OSAllocatedUnfairLock(initialState: (output: Data(), errors: Data()))
        do { try process.run() }
        catch { throw SourceGit.Confinement.unavailable() }
        for (handle, isOutput) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                results.withLock { if isOutput { $0.output = data } else { $0.errors = data } }
                readers.leave()
            }
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
            _ = readers.wait(timeout: .now() + 2)
            throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git did not finish the source inventory within \(Int(timeout)) seconds.", details: ["reason": "git_timeout"])
        }
        // The child has exited; its pipes reach end of file unless a grandchild still holds them.
        guard readers.wait(timeout: .now() + 5) == .success else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git output did not close after git exited.", details: ["reason": "git_pipe_open"]) }
        let (output, errors) = results.withLock { $0 }
        guard process.terminationReason == .exit else {
            throw CoreError("SOURCE_GIT_CONFINED", "Source Git was terminated by protected-root or helper confinement (or an external signal); no source inventory was accepted.", details: ["signal": process.terminationStatus])
        }
        let reason = String(data: errors.prefix(4096), encoding: .utf8) ?? "git failed"
        if reason.contains("sandbox-exec:") { throw SourceGit.Confinement.unavailable() }
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            let diagnostic = reason.lowercased()
            if diagnostic.contains("xcode") && diagnostic.contains("license") {
                throw CoreError("SOURCE_GIT_LICENSE_REQUIRED", "Git could not run because the Xcode license has not been accepted. The owner must run sudo xcodebuild -license accept in Terminal, then retry.", details: ["git_path": executable, "reason": "xcode_license_not_accepted"])
            }
            throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git could not inventory the complete enrolled source tree.", details: ["reason": reason, "git_path": executable])
        }
        return output
#else
        return try UnsupportedSourceGitProcessAdapter().run(request)
#endif
    }
}
