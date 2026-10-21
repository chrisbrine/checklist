import Foundation
import Darwin
import Security
import ChecklistIPC

struct ShimChildPin: Sendable {
    let cdhash: Data
    let bundleRoot: URL
}

/// The child was killed and reaped while still suspended.
struct ShimChildInstanceMismatch: LocalizedError {
    let processID: pid_t
    let observedHash: Data?
    let stdout: Data
    let stderr: String
    var errorDescription: String? { DelegateInstanceExpectation.mismatch.localizedDescription }
}

/// Every delegate supplies a pin. Direct service-free runner tests may omit it.
enum ShimChildProcess {
    private final class Bytes: @unchecked Sendable { var value = Data() }
    private final class InputState: @unchecked Sendable { var delivered = true }

    private static func failure(_ status: Int32) -> ShimChildLaunchError {
        ShimChildLaunchError(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(status)))
    }

    private static func checked(_ status: Int32) throws {
        guard status == 0 else { throw failure(status) }
    }

    private static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return status }
            if result == -1 && errno == EINTR { continue }
            return nil
        }
    }

    /// This checks the loaded image against the exact pinned hash, including the kernel/disk link.
    static func dynamicallyValidates(_ pid: pid_t, requirementText: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func admits(_ pid: pid_t, pin: ShimChildPin,
                       validator: (pid_t, String) -> Bool = { dynamicallyValidates($0, requirementText: $1) },
                       executablePath: (pid_t) -> URL? = executable) -> Bool {
        guard !pin.cdhash.isEmpty else { return false }
        let text = "cdhash H\"" + pin.cdhash.map { String(format: "%02x", $0) }.joined() + "\""
        guard validator(pid, text), let actual = executablePath(pid) else { return false }
        return actual.pathComponents.starts(with: pin.bundleRoot.pathComponents)
    }

    /// Unchecked static information is diagnostic only; it never admits a child.
    private static func diagnosticIdentity(_ pid: pid_t) -> ClientBuildIdentity? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        return ClientBuildIdentity.running(code)
    }

    private static func executable(_ pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    static func run(path: String, arguments: [String], directory: String, environment: [String: String],
                    input: Data? = nil, pin: ShimChildPin? = nil) throws -> ShimChildResult {
        let output = Pipe(), errors = Pipe(), incoming = input.map { _ in Pipe() }
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { throw failure(errno) }
        defer { close(null) }
        if let incoming { try checked(fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 ? 0 : errno) }
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)))
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        if #available(macOS 26.0, *) { try checked(posix_spawn_file_actions_addchdir(&actions, directory)) }
        else { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        try checked(posix_spawn_file_actions_adddup2(&actions, incoming?.fileHandleForReading.fileDescriptor ?? null, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        var descriptors = [null, output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor,
                           errors.fileHandleForReading.fileDescriptor, errors.fileHandleForWriting.fileDescriptor]
        if let incoming { descriptors += [incoming.fileHandleForReading.fileDescriptor, incoming.fileHandleForWriting.fileDescriptor] }
        for descriptor in Set(descriptors) where descriptor > STDERR_FILENO {
            try checked(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        let argv = ([path] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer { for pointer in argv + envp { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw failure(ENOMEM) }
        var terminatedArguments = argv + [nil], terminatedEnvironment = envp + [nil]
        var pid: pid_t = 0
        let spawned = terminatedArguments.withUnsafeMutableBufferPointer { arguments in
            terminatedEnvironment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        try checked(spawned)
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        try? incoming?.fileHandleForReading.close()

        // START_SUSPENDED stops the initial thread before it executes any instruction.
        if let pin {
            if !admits(pid, pin: pin) {
                let observed = diagnosticIdentity(pid)
                _ = kill(pid, SIGKILL); _ = reap(pid)
                try? incoming?.fileHandleForWriting.close()
                throw ShimChildInstanceMismatch(processID: pid, observedHash: observed?.cdhash,
                    stdout: output.fileHandleForReading.readDataToEndOfFile(),
                    stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
        }
        guard kill(pid, SIGCONT) == 0 else {
            let status = errno
            _ = kill(pid, SIGKILL); _ = reap(pid)
            try? incoming?.fileHandleForWriting.close()
            throw failure(status)
        }

        let group = DispatchGroup(), stdout = Bytes(), stderr = Bytes(), inputState = InputState()
        group.enter()
        DispatchQueue.global().async { stdout.value = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderr.value = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let incoming, let input {
            group.enter()
            DispatchQueue.global().async {
                defer { try? incoming.fileHandleForWriting.close(); group.leave() }
                do { try incoming.fileHandleForWriting.write(contentsOf: input) }
                catch { inputState.delivered = false }
            }
        }
        let status = reap(pid)
        group.wait()
        guard let status, inputState.delivered else {
            return .init(status: -1, stdout: stdout.value, stderr: String(decoding: stderr.value, as: UTF8.self), termination: .notAwaited)
        }
        // waitpid's low seven bits hold the signal; a normal exit has no signal bits.
        let signal = status & 0x7f
        return .init(status: signal == 0 ? (status >> 8) & 0xff : signal,
                     stdout: stdout.value, stderr: String(decoding: stderr.value, as: UTF8.self),
                     termination: signal == 0 ? .exited : .signalled)
    }
}
