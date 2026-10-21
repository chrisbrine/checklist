import XCTest
@testable import ChecklistBridges

final class NativeReplyLoopTests: XCTestCase {
    func testRepeatedFailuresBackOffCapAndRecoverWithoutIdleOrSuccessDelay() {
        var index = 0, errors = 0, frames: [Int] = [], sleeps: [TimeInterval] = []
        let sequence = ["timeout"] + Array(repeating: "failure", count: 9) + ["frame", "timeout", "failure"]
        NativeReplyLoop.run(shouldContinue: { index < sequence.count }, receive: { () throws -> Int in
            let value = sequence[index]; index += 1
            if value == "timeout" { throw NativeBridgeError.timedOut }
            if value == "failure" { throw NativeBridgeError.invalid("synthetic invalid receipt; no provider I/O") }
            return index
        }, onFrame: { frames.append($0) }, onError: { _ in errors += 1 }, sleep: { sleeps.append($0) })
        XCTAssertEqual(errors, 10); XCTAssertEqual(frames.count, 1); XCTAssertEqual(sleeps.count, 10)
        XCTAssertEqual(sleeps, [0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 2, 2, 2, 0.05])
        XCTAssertGreaterThan(sleeps.reduce(0, +), 9)
        XCTAssertTrue(sleeps.allSatisfy { $0 > 0 && $0 <= 2 })
    }
}
