import XCTest
import Darwin
import Security
import ChecklistIPC
@testable import ChecklistMCPServer

final class SuspendedChildAdmissionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/synthetic/Checklist.app")

    func testAdmissionUsesExactPinnedRequirementAndDynamicValidityResult() {
        let hash = Data([0x00, 0x19, 0xa2, 0xff])
        let pin = ShimChildPin(cdhash: hash, bundleRoot: root)
        let inside = root.appendingPathComponent("Contents/MacOS/checklist")
        for valid in [false, true] {
            var requests: [(pid_t, String)] = []
            var pathReads = 0
            let admitted = ShimChildProcess.admits(123, pin: pin, validator: { pid, requirement in
                requests.append((pid, requirement))
                return valid
            }, executablePath: { _ in pathReads += 1; return inside })
            XCTAssertEqual(admitted, valid)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.0, 123)
            XCTAssertEqual(requests.first?.1, "cdhash H\"0019a2ff\"")
            XCTAssertEqual(pathReads, valid ? 1 : 0, "Failed dynamic validity must end admission.")
        }
    }

    func testEmptyPinFailsClosedWithoutCallingValidator() {
        var called = false
        let admitted = ShimChildProcess.admits(123, pin: .init(cdhash: Data(), bundleRoot: root), validator: { _, _ in
            called = true; return true
        }, executablePath: { _ in self.root.appendingPathComponent("Contents/MacOS/checklist") })
        XCTAssertFalse(admitted)
        XCTAssertFalse(called)
    }

    func testValidCodeStillNeedsKernelPathInsideCapturedBundle() {
        for path: URL? in [nil, URL(fileURLWithPath: "/synthetic/Other.app/Contents/MacOS/checklist"),
                           URL(fileURLWithPath: "/synthetic/Checklist.app-other/Contents/MacOS/checklist")] {
            XCTAssertFalse(ShimChildProcess.admits(123, pin: .init(cdhash: Data([1]), bundleRoot: root),
                validator: { _, _ in true }, executablePath: { _ in path }))
        }
    }

    func testRealDynamicValidityAcceptsOwnLoadedHashAndRefusesDifferentHash() throws {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        let own = try XCTUnwrap(ClientBuildIdentity.running(XCTUnwrap(code)))
        let ownPin = ShimChildPin(cdhash: own.cdhash, bundleRoot: root)
        let inside = root.appendingPathComponent("Contents/MacOS/checklist")
        XCTAssertTrue(ShimChildProcess.admits(getpid(), pin: ownPin, executablePath: { _ in inside }))
        let other = Data(own.cdhash.map { $0 ^ 0xff })
        XCTAssertFalse(ShimChildProcess.admits(getpid(), pin: .init(cdhash: other, bundleRoot: root), executablePath: { _ in inside }))
    }
}
