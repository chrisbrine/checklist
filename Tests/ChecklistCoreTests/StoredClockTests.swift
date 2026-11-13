import CryptoKit
import Foundation
import XCTest
@testable import ChecklistCore

/// CL-363: `now()` and `hash()` use cheaper paths. Stored bytes must stay the same as the
/// former `ISO8601DateFormatter().string(from:)` and `String(format: "%02x")` results.
final class StoredClockTests: XCTestCase {
    /// Whole seconds that cover day, month, leap-day, century and year-10000 boundaries,
    /// dates before 1970 and the date of this change.
    private let wholeSeconds: [TimeInterval] = [
        0, 1, 59, 60, 3_599, 86_399, 86_400, 951_782_399, 951_782_400, 951_868_800, 978_307_200,
        1_709_164_800, 1_709_251_199, 1_794_523_972, 1_798_761_599, 1_798_761_600, 4_107_542_399,
        4_107_542_400, 253_402_300_799, 253_402_300_800, -1, -2, -86_400, -86_401, -978_307_200
    ]
    /// Fractions on both sides of each limit of the cached range, of a millisecond and of a second.
    private let fractions: [TimeInterval] = [
        0, 0.000_000_1, 0.000_4, 0.000_5, 0.000_6, 0.001, 0.001_5, 0.001_9, 0.002, 0.002_1, 0.25,
        0.499_9, 0.5, 0.500_1, 0.75, 0.996_9, 0.997, 0.997_1, 0.998, 0.998_5, 0.999, 0.999_4,
        0.999_5, 0.999_6, 0.999_9, 0.999_99, 0.999_999_9
    ]

    func testClockTextEqualsANewDefaultFormatterAtEveryProbedBoundary() {
        let clock = StoredClock(), reference = ISO8601DateFormatter()
        for whole in wholeSeconds {
            for fraction in fractions {
                let date = Date(timeIntervalSince1970: whole + fraction)
                let expected = reference.string(from: date)
                XCTAssertEqual(clock.currentString(at: date), expected, "\(whole) + \(fraction)")
                XCTAssertEqual(clock.string(from: date), expected, "\(whole) + \(fraction)")
            }
        }
    }

    func testClockTextEqualsANewDefaultFormatterForManyDatesInAndOutOfOrder() {
        let clock = StoredClock(), reference = ISO8601DateFormatter()
        // A fixed linear congruential sequence: the same 1,500 dates in each run.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 11 }
        var checked = 0
        for _ in 0..<1_500 {
            // 1970 to 2100, with a fraction of 0 to 999,999 microseconds.
            let whole = TimeInterval(next() % 4_102_444_800), micro = TimeInterval(next() % 1_000_000) / 1_000_000
            let date = Date(timeIntervalSince1970: whole + micro)
            XCTAssertEqual(clock.currentString(at: date), reference.string(from: date)); checked += 1
            // The same second again at other fractions uses the kept text or the formatter.
            for fraction in [0.002, 0.3, 0.997, 0.9995, 0.0, 0.5] {
                let again = Date(timeIntervalSince1970: whole + fraction)
                XCTAssertEqual(clock.currentString(at: again), reference.string(from: again)); checked += 1
            }
        }
        XCTAssertEqual(checked, 10_500)
    }

    func testClockTextAdvancesAndReturnsAcrossNeighbourSeconds() {
        let clock = StoredClock(), reference = ISO8601DateFormatter(), start: TimeInterval = 1_794_523_972
        // Forward and backward steps of 100 ms across 40 seconds: each second changes the kept text.
        let forward = stride(from: 0.0, to: 40.0, by: 0.1).map { start + $0 }
        for seconds in forward + forward.reversed() {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(clock.currentString(at: date), reference.string(from: date), "\(seconds)")
            XCTAssertEqual(clock.string(from: date), reference.string(from: date), "\(seconds)")
        }
    }

    func testSharedClockIsExactUnderConcurrentCalls() {
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            let reference = ISO8601DateFormatter()
            for index in 0..<600 {
                // Workers share some seconds and differ in others, so the kept text changes between them.
                let date = Date(timeIntervalSince1970: 1_794_523_972 + TimeInterval((index + worker * 3) % 97) + TimeInterval(index % 1_000) / 1_000)
                if StoredClock.shared.currentString(at: date) != reference.string(from: date) { failures.add() }
                if StoredClock.shared.string(from: date) != reference.string(from: date) { failures.add() }
                if StoredClock.shared.date(from: reference.string(from: date)) != reference.date(from: reference.string(from: date)) { failures.add() }
            }
        }
        XCTAssertEqual(failures.value, 0)
    }

    func testNowIsTheCurrentDefaultFormatterText() throws {
        let before = Date(), text = now(), after = Date()
        XCTAssertEqual(text.utf8.count, 20)
        XCTAssertNotNil(text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression))
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: text))
        // The text has whole seconds; the formatter may round the last millisecond up.
        XCTAssertGreaterThanOrEqual(parsed.timeIntervalSince1970, before.timeIntervalSince1970.rounded(.down))
        XCTAssertLessThanOrEqual(parsed.timeIntervalSince1970, after.timeIntervalSince1970.rounded(.up))
    }

    func testClockDateEqualsANewDefaultFormatterForAcceptedAndRefusedText() {
        let clock = StoredClock()
        let texts = ["2026-11-12T22:52:52Z", "1970-01-01T00:00:00Z", "2000-02-29T23:59:59Z", "2026-11-12T15:52:52-07:00",
                     "2026-11-12T22:52:52+00:00", "2026-11-12T22:52:52.123Z", "2026-11-12 22:52:52Z", "2026-11-12", "", "not a date",
                     "2026-02-30T00:00:00Z", "2026-11-12T24:00:00Z", "9999-12-31T23:59:59Z", " 2026-11-12T22:52:52Z"]
        for text in texts {
            XCTAssertEqual(clock.date(from: text), ISO8601DateFormatter().date(from: text), text)
        }
    }

    func testLowercaseHexEqualsTheFormerFormatForEveryByte() {
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(lowercaseHex(all), all.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(lowercaseHex([UInt8]()), "")
        XCTAssertEqual(lowercaseHex(Data([0x00, 0x0f, 0xf0, 0xff])), "000ff0ff")
        XCTAssertEqual(lowercaseHex("Aé".utf8), "41c3a9")
    }

    func testHashEqualsTheFormerFormatAndPublishedVectors() {
        XCTAssertEqual(ChecklistCore.hash(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ChecklistCore.hash(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var bytes = Data()
        for length in 0..<300 {
            XCTAssertEqual(ChecklistCore.hash(bytes), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "length \(length)")
            bytes.append(UInt8(truncatingIfNeeded: length &* 31 &+ 7))
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
