import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import ChecklistCore

/// CL-363: fixture Git results keyed by every input Git reads from the tree.
/// A sandboxed launch costs 100-225 ms on a loaded host and one capture needs about
/// six. The first request for each exact tree state runs real, confined Git; a later
/// request for byte-identical state reuses its output with the workspace path rebound.
/// Refusals, a workspace overlapping a protected root, and any tree it cannot fully
/// key (a `.git` file, symlink, unreadable or large entry) always run real Git. Each
/// test starts without it; TestStore.router installs it unless `sourceGitMemo` is false.
final class SourceGitFixtureMemo: SourceGitProcessAdapter, @unchecked Sendable {
    static let shared = SourceGitFixtureMemo()
    private let lock = NSLock()
    private var results: [String: Data] = [:]
    private let real: any SourceGitProcessAdapter
    init(real: any SourceGitProcessAdapter = MacOSSourceGitProcessAdapter()) { self.real = real }
    private static let pathToken = Data("\u{1}checklist-fixture-workspace\u{1}".utf8)
    private static let contentLimit = 256 * 1024

    /// Applies to the current test only: the observer clears it before the next test.
    static func configure(enabled: Bool) {
        _ = testStartReset
        SourceGit.fixtureProcessAdapter.withLockUnchecked { $0 = enabled ? shared : nil }
    }
    private static let testStartReset: Void = { XCTestObservationCenter.shared.addTestObserver(TestStartReset()) }()
    private final class TestStartReset: NSObject, XCTestObservation {
        func testCaseWillStart(_ testCase: XCTestCase) { SourceGit.fixtureProcessAdapter.withLockUnchecked { $0 = nil } }
    }

    func run(_ request: SourceGitProcessRequest) throws -> Data {
        // Exact launcher shape from SourceGit.run: -p PROFILE GIT -c K=V -C PATH ARGS...
        let arguments = request.arguments
        guard arguments.count >= 7, arguments[0] == "-p", arguments[3] == "-c", arguments[5] == "-C" else { return try real.run(request) }
        let path = arguments[6], command = Array(arguments[7...])
        let state = command == ["--version"] ? "" : Self.overlapsProtectedRoot(path, profile: arguments[1]) ? nil : Self.treeState(path)
        guard let state else { return try real.run(request) }
        let accepted = request.acceptedExitCodes.sorted().map(String.init).joined(separator: ",")
        let environment = request.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\0")
        let key = ([request.gitExecutable, arguments[4], accepted, environment, state] + command).joined(separator: "\0")
        let physical = Darwin.realpath(path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) } ?? path
        if let stored = lock.withLock({ results[key] }) { return Self.replacing(Self.pathToken, with: Data(physical.utf8), in: stored) }
        let output = try real.run(request)
        var stored = Self.replacing(Data(physical.utf8), with: Self.pathToken, in: output)
        if physical != path { stored = Self.replacing(Data(path.utf8), with: Self.pathToken, in: stored) }
        lock.withLock { results[key] = stored }
        return output
    }

    private static func replacing(_ target: Data, with replacement: Data, in data: Data) -> Data {
        guard !target.isEmpty, data.range(of: target) != nil else { return data }
        var result = Data(), start = data.startIndex
        while let range = data.range(of: target, in: start..<data.endIndex) {
            result.append(data[start..<range.lowerBound]);result.append(replacement);start = range.upperBound
        }
        result.append(data[start..<data.endIndex])
        return result
    }

    /// Confinement kills Git for these paths; a remembered success would hide that.
    private static func overlapsProtectedRoot(_ path: String, profile: String) -> Bool {
        let physical = Darwin.realpath(path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) } ?? path
        return profile.components(separatedBy: "(subpath \"").dropFirst().contains { entry in
            guard let root = entry.components(separatedBy: "\")").first else { return true }
            return [path, physical].contains { $0 == root || $0.hasPrefix(root + "/") || root.hasPrefix($0 + "/") }
        }
    }

    /// Every path, mode, size and byte below the workspace, including all of `.git`.
    /// Returns nil when an entry could change Git's result without changing this digest.
    private static func treeState(_ root: String) -> String? {
        var gitInfo = stat()
        guard lstat(root + "/.git", &gitInfo) == 0, gitInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        var hash = SHA256()
        func visit(_ path: String, _ relative: String) -> Bool {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
            for name in names.sorted() {
                let child = path + "/" + name, entry = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { return false }
                hash.update(data: Data("\(entry)\0\(info.st_mode)\0\(info.st_size)\0".utf8))
                switch info.st_mode & S_IFMT {
                case S_IFDIR: if !visit(child, entry) { return false }
                case S_IFREG:
                    guard info.st_size <= contentLimit, let bytes = FileManager.default.contents(atPath: child) else { return false }
                    hash.update(data: bytes)
                default: return false
                }
            }
            return true
        }
        guard visit(root, "") else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
