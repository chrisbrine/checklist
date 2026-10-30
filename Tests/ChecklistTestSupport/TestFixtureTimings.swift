import Foundation
import XCTest

/// Opt-in attribution for test-only setup. Nothing is installed in the product.
/// XCTest method elapsed includes setup/teardown; these nested components explain
/// where that time went rather than being added to the method elapsed again.
enum TestFixtureTimings {
    private static let enabled = ProcessInfo.processInfo.environment["CHECKLIST_TEST_PROFILE"] == "1"
    private static let observer = Observer()
    private static let registration: Void = { XCTestObservationCenter.shared.addTestObserver(observer) }()

    static func measure<T>(_ component: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        _ = registration
        let start = ProcessInfo.processInfo.systemUptime
        defer { observer.add(component, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try body()
    }

    private final class Observer: NSObject, XCTestObservation, @unchecked Sendable {
        private let lock = NSLock()
        private var components: [String: (count: Int, seconds: Double)] = [:]
        private let output: FileHandle? = {
            guard let directory = ProcessInfo.processInfo.environment["CHECKLIST_TEST_PROFILE_DIRECTORY"] else { return nil }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("fixture-\(ProcessInfo.processInfo.processIdentifier).jsonl")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
            return try? FileHandle(forWritingTo: file)
        }()
        deinit { try? output?.close() }
        func add(_ component: String, seconds: Double) {
            lock.lock(); defer { lock.unlock() }
            let prior = components[component] ?? (0, 0)
            components[component] = (prior.count + 1, prior.seconds + seconds)
        }
        func testCaseWillStart(_ testCase: XCTestCase) {
            lock.lock(); defer { lock.unlock() }
            components = [:]
        }
        func testCaseDidFinish(_ testCase: XCTestCase) {
            lock.lock()
            let values: [String: Any] = ["test": testCase.name, "components": components.mapValues { ["count": $0.count, "seconds": $0.seconds] as [String: Any] }]
            components = [:]
            lock.unlock()
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
                if let output {
                    try? output.write(contentsOf: Data((line + "\n").utf8))
                } else {
                    // A single write avoids mixing partial JSON with XCTest.
                    try? FileHandle.standardError.write(contentsOf: Data(("CHECKLIST_FIXTURE_TIMING " + line + "\n").utf8))
                }
            }
        }
    }
}
