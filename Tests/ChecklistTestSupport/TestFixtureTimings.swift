import Foundation
import XCTest
@testable import ChecklistCore

/// Opt-in attribution for test-only setup. Nothing is installed in the product.
/// XCTest method elapsed includes setup/teardown; these nested components explain
/// where that time went rather than being added to the method elapsed again.
public enum TestFixtureTimings {
    private static let enabled = ProcessInfo.processInfo.environment["CHECKLIST_TEST_PROFILE"] == "1"
    private static let observer = Observer()
    private static let registration: Void = { XCTestObservationCenter.shared.addTestObserver(observer) }()

    public static func measure<T>(_ component: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        _ = registration
        let start = ProcessInfo.processInfo.systemUptime
        defer { observer.add(component, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try body()
    }

    public static func start() { if enabled { _ = registration } }

    /// Startup attribution is serialized only in the explicit profiling mode.
    /// Nested template opens keep the prior observers and restore them on exit.
    private static let startupLock = NSRecursiveLock()
    static func startup<T>(_ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        startupLock.lock(); defer { startupLock.unlock() }
        let priorRouter = CommandRouter.qualificationStartupObserve
        let priorBootstrap = StorageBootstrap.qualificationObserve
        var previous = ProcessInfo.processInfo.systemUptime
        CommandRouter.qualificationStartupObserve = { phase in
            let current = ProcessInfo.processInfo.systemUptime
            observer.add("router." + phase, seconds: current - previous)
            previous = current
            priorRouter?(phase)
        }
        StorageBootstrap.qualificationObserve = { phase, seconds in
            observer.add("bootstrap." + phase, seconds: seconds)
            priorBootstrap?(phase, seconds)
        }
        defer {
            CommandRouter.qualificationStartupObserve = priorRouter
            StorageBootstrap.qualificationObserve = priorBootstrap
            observer.add("router.construction-tail", seconds: ProcessInfo.processInfo.systemUptime - previous)
        }
        return try body()
    }

    private final class Observer: NSObject, XCTestObservation, @unchecked Sendable {
        private let lock = NSLock()
        private var started: TimeInterval?
        private var startedCPU: (user: Double, system: Double)?
        private var components: [String: (count: Int, seconds: Double)] = [:]
        /// CL-363: CPU time of this process. Under host load the elapsed time of a case is mostly a
        /// wait for a CPU; the CPU time of a serial run is the cost of the case itself.
        private static func processCPU() -> (user: Double, system: Double) {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6, Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6)
        }
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
            started = ProcessInfo.processInfo.systemUptime
            startedCPU = Self.processCPU()
        }
        func testCaseDidFinish(_ testCase: XCTestCase) {
            lock.lock()
            var values: [String: Any] = ["test": testCase.name, "case_seconds": started.map { ProcessInfo.processInfo.systemUptime - $0 } as Any, "components": components.mapValues { ["count": $0.count, "seconds": $0.seconds] as [String: Any] }]
            if let startedCPU {
                let current = Self.processCPU()
                values["case_user_seconds"] = current.user - startedCPU.user
                values["case_system_seconds"] = current.system - startedCPU.system
            }
            components = [:]; started = nil; startedCPU = nil
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
