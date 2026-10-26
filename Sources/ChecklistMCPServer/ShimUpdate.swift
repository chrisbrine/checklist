import Foundation
import Darwin
import Security
import ChecklistIPC

public enum ShimLaunchState: Sendable {
    case current, replaced, unavailable
}

public struct ShimChildResult: Sendable {
    public enum Termination: Sendable { case exited, signalled, notAwaited }
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public let termination: Termination

    public init(status: Int32, stdout: Data, stderr: String = "", termination: Termination = .exited) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.termination = termination
    }
}

/// This error proves that Process.run did not start a child.
struct ShimChildLaunchError: Error {
    let underlying: Error
}

struct ShimInstanceRefusal: LocalizedError {
    var errorDescription: String? { ClientUpdateRequired.error.localizedDescription }
}

public struct ShimUpdateEnvironment: Sendable {
    public let launchPath: String
    public var check: @Sendable (_ force: Bool) -> ShimLaunchState
    public var run: @Sendable (_ arguments: [String], _ input: Data?) throws -> ShimChildResult

    public init(launchPath: String, check: @escaping @Sendable (Bool) -> ShimLaunchState,
                run: @escaping @Sendable ([String], Data?) throws -> ShimChildResult) {
        self.launchPath = launchPath; self.check = check; self.run = run
    }

    /// Capture the instance and resolved bundle before native discovery can wait.
    public static func capture() -> Self {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let path = _NSGetExecutablePath(&buffer, &size) == 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : CommandLine.arguments[0]
        let launchPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var code: SecCode?
        let own = SecCodeCopySelf([], &code) == errSecSuccess ? code.flatMap(ClientBuildIdentity.running) : nil
        return launched(path: launchPath, ownHash: own?.cdhash, instance: ChecklistInstance.current,
                        directory: FileManager.default.currentDirectoryPath, environment: ProcessInfo.processInfo.environment)
    }

    static func launched(path: String, ownHash: Data?, instance: ChecklistInstance, directory: String,
                         environment: [String: String],
                         identity: @escaping @Sendable (URL) -> ClientBuildIdentity? = { ClientBuildIdentity.executable($0) },
                         runner: @escaping @Sendable (String, [String], String, [String: String], Data?, ShimChildPin) throws -> ShimChildResult = {
                             try ShimChildProcess.run(path: $0, arguments: $1, directory: $2, environment: $3, input: $4, pin: $5)
                         }) -> Self {
        let boundary = try? ShimInstanceBoundary(launchPath: path, instance: instance)
        let monitor = ShimExecutableMonitor(path: path, ownHash: ownHash, boundary: boundary, identity: identity)
        let expectation = boundary.map { DelegateInstanceExpectation(instance: instance, bundleRoot: $0.bundleRoot) }
        return .init(launchPath: path, check: { monitor.check(force: $0) }, run: { arguments, input in
            // Check the bundle again even when the executable's signature stamp is unchanged.
            guard let boundary, let expectation, let resolved = boundary.resolve(path),
                  let signed = identity(resolved), boundary.accepts(signed) else {
                throw ShimInstanceRefusal()
            }
            var childEnvironment = environment
            childEnvironment[DelegateInstanceExpectation.environmentKey] = try expectation.encoded()
            return try runner(resolved.path, arguments, directory, childEnvironment, input,
                              ShimChildPin(cdhash: signed.cdhash, bundleRoot: boundary.bundleRoot))
        })
    }
}

/// A replacement must keep both the resolved bundle root and its instance identity.
struct ShimInstanceBoundary: Sendable {
    let slot: Int?
    let bundleIdentifier: String
    let machServiceName: String
    let bundleRoot: URL

    init(launchPath: String, instance: ChecklistInstance) throws {
        let resolved = URL(fileURLWithPath: launchPath).resolvingSymlinksInPath()
        guard let root = Self.bundle(containing: resolved) else { throw ClientUpdateRequired.error }
        slot = instance.slot; bundleIdentifier = instance.bundleIdentifier; machServiceName = instance.machServiceName
        bundleRoot = root
        guard resolve(launchPath) != nil else { throw ClientUpdateRequired.error }
    }

    private static func bundle(containing executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        let root = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", root.pathExtension == "app" else { return nil }
        return root
    }

    func resolve(_ launchPath: String) -> URL? {
        let resolved = URL(fileURLWithPath: launchPath).resolvingSymlinksInPath()
        guard Self.bundle(containing: resolved) == bundleRoot,
              let data = try? Data(contentsOf: bundleRoot.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let instance = try? ChecklistInstance.read(executable: resolved),
              instance.slot == slot, instance.bundleIdentifier == bundleIdentifier,
              instance.machServiceName == machServiceName else { return nil }
        return resolved
    }

    func accepts(_ identity: ClientBuildIdentity) -> Bool {
        identity.identifier == "org.checklist.checklist" || identity.identifier == bundleIdentifier + ".checklist"
    }
}

/// Each request uses stat. Read the signature again only when the file changes or a peer refuses it.
final class ShimExecutableMonitor: @unchecked Sendable {
    struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
    }
    private let lock = NSLock()
    private let path: String
    private let ownHash: Data?
    private let boundary: ShimInstanceBoundary?
    private let identity: (URL) -> ClientBuildIdentity?
    private var stamp: Stamp?
    private var state = ShimLaunchState.unavailable

    init(path: String, ownHash: Data?, boundary: ShimInstanceBoundary?,
         identity: @escaping (URL) -> ClientBuildIdentity? = ClientBuildIdentity.executable) {
        self.path = path; self.ownHash = ownHash; self.boundary = boundary; self.identity = identity
    }

    func check(force: Bool) -> ShimLaunchState {
        lock.lock(); defer { lock.unlock() }
        var file = stat()
        guard stat(path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
            stamp = nil; state = .unavailable; return state
        }
        let next = Stamp(device: file.st_dev, inode: file.st_ino, size: file.st_size,
                         seconds: file.st_mtimespec.tv_sec, nanoseconds: file.st_mtimespec.tv_nsec)
        if !force, stamp == next { return state }
        stamp = next
        guard let ownHash, let boundary, let resolved = boundary.resolve(path),
              let signed = identity(resolved), boundary.accepts(signed) else {
            state = .unavailable; return state
        }
        state = signed.cdhash == ownHash ? .current : .replaced
        return state
    }
}

