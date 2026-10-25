import XCTest
import AppKit
import ChecklistIPC
@testable import ChecklistApp

final class TestInstanceAppearanceTests: XCTestCase {
    func testTestInstanceDarkArgumentWinsOverEnvironment() throws {
        let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 1, environment: [:]),
            readArgument: { "dark" }, readEnvironment: { XCTFail("Argument takes precedence"); return "light" },
            log: { _ in XCTFail("Valid override must not warn") })
        XCTAssertEqual(name, .darkAqua)
    }

    func testTestInstanceLightArgumentWinsOverEnvironment() throws {
        let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 2, environment: [:]),
            readArgument: { "light" }, readEnvironment: { XCTFail("Argument takes precedence"); return "dark" },
            log: { _ in XCTFail("Valid override must not warn") })
        XCTAssertEqual(name, .aqua)
    }

    func testEnvironmentSuppliesEitherAppearanceWhenArgumentIsAbsent() throws {
        for (value, expected) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            var reads = 0
            let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 3, environment: [:]),
                readArgument: { nil }, readEnvironment: { reads += 1; return value },
                log: { _ in XCTFail("Valid override must not warn") })
            XCTAssertEqual(name, expected)
            XCTAssertEqual(reads, 1)
        }
    }

    func testInvalidArgumentIsIgnoredWithOneLogAndDoesNotFallBack() throws {
        let invalidValues: [Any] = ["auto", "Dark", "", true, 1]
        for value in invalidValues {
            var logs: [String] = []
            let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 4, environment: [:]),
                readArgument: { value }, readEnvironment: { XCTFail("Argument takes precedence"); return "dark" },
                log: { logs.append($0) })
            XCTAssertNil(name)
            XCTAssertEqual(logs, ["Ignoring invalid Checklist test appearance; expected dark or light."])
        }
    }

    func testInvalidEnvironmentIsIgnoredWithOneLog() throws {
        var logs: [String] = []
        let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 1, environment: [:]),
            readArgument: { nil }, readEnvironment: { "system" }, log: { logs.append($0) })
        XCTAssertNil(name)
        XCTAssertEqual(logs.count, 1)
    }

    func testProductionBundleIgnoresBothInputsWithoutReadingOrLogging() throws {
        for value in ["dark", "light", "invalid"] {
            var reads = 0, logs = 0
            let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(environment: [:]),
                readArgument: { reads += 1; return value }, readEnvironment: { reads += 1; return value },
                log: { _ in logs += 1 })
            XCTAssertNil(name)
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(logs, 0)
        }
    }

    func testAbsentInputsKeepSystemAppearanceWithoutLogging() throws {
        let name = TestInstanceAppearance.resolve(instance: try ChecklistInstance(slotValue: 1, environment: [:]),
            readArgument: { nil }, readEnvironment: { nil }, log: { _ in XCTFail("No override is not an error") })
        XCTAssertNil(name)
    }
}
