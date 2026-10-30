import Darwin
import XCTest
@testable import ChecklistService

final class ServiceDescriptorLimitTests: XCTestCase {
    // Darwin's RLIM_INFINITY macro is not imported by Swift.
    private let unlimited: rlim_t = (rlim_t(1) << 63) - 1

    func testLaunchdSoftLimitRaisesToKernelCeilingAndPreservesInfiniteHardLimit() throws {
        var written: ServiceDescriptorLimit.Limits?
        let adjustment = try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:self.unlimited)},
            readKernelMaximum:{10_240},
            writeLimits:{written = $0})
        XCTAssertEqual(adjustment,ServiceDescriptorLimit.Adjustment(previous:256,current:10_240))
        XCTAssertEqual(written,ServiceDescriptorLimit.Limits(soft:10_240,hard:unlimited))
    }

    func testFiniteHardLimitCapsRaise() throws {
        var written: ServiceDescriptorLimit.Limits?
        let adjustment = try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:1_024)},
            readKernelMaximum:{10_240},
            writeLimits:{written = $0})
        XCTAssertEqual(adjustment,ServiceDescriptorLimit.Adjustment(previous:256,current:1_024))
        XCTAssertEqual(written,ServiceDescriptorLimit.Limits(soft:1_024,hard:1_024))
    }

    func testAlreadyHigherInheritedLimitIsNotLowered() throws {
        let adjustment = try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:20_480,hard:self.unlimited)},
            readKernelMaximum:{10_240},
            writeLimits:{_ in XCTFail("An inherited higher limit must be preserved")})
        XCTAssertNil(adjustment)
    }

    func testHardLimitAtCurrentSoftLimitDoesNotWrite() throws {
        let adjustment = try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:256)},
            readKernelMaximum:{10_240},
            writeLimits:{_ in XCTFail("There is no permitted soft-limit increase")})
        XCTAssertNil(adjustment)
    }

    func testLimitReadFailureDoesNotReadKernelOrWrite() {
        XCTAssertThrowsError(try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{throw ServiceDescriptorLimit.SystemFailure(operation:"getrlimit",code:EIO)},
            readKernelMaximum:{XCTFail("Cannot choose a target without inherited limits");return 10_240},
            writeLimits:{_ in XCTFail("A read failure must leave limits unchanged")})) { error in
                XCTAssertEqual((error as? ServiceDescriptorLimit.SystemFailure)?.code,EIO)
            }
    }

    func testKernelReadFailureDoesNotWrite() {
        XCTAssertThrowsError(try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:self.unlimited)},
            readKernelMaximum:{throw ServiceDescriptorLimit.SystemFailure(operation:"sysctl",code:ENOENT)},
            writeLimits:{_ in XCTFail("An unknown kernel ceiling must leave limits unchanged")})) { error in
                XCTAssertEqual((error as? ServiceDescriptorLimit.SystemFailure)?.code,ENOENT)
            }
    }

    func testInvalidKernelMaximumDoesNotWrite() {
        XCTAssertThrowsError(try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:self.unlimited)},
            readKernelMaximum:{0},
            writeLimits:{_ in XCTFail("An invalid kernel ceiling must leave limits unchanged")})) { error in
                XCTAssertEqual((error as? ServiceDescriptorLimit.SystemFailure)?.code,EINVAL)
            }
    }

    func testRaiseFailurePreservesErrnoAndIsNotReportedAsSuccess() {
        var writes = 0
        XCTAssertThrowsError(try ServiceDescriptorLimit.raiseForStartup(
            readLimits:{.init(soft:256,hard:self.unlimited)},
            readKernelMaximum:{10_240},
            writeLimits:{_ in writes += 1;throw ServiceDescriptorLimit.SystemFailure(operation:"setrlimit",code:EPERM)})) { error in
                XCTAssertEqual((error as? ServiceDescriptorLimit.SystemFailure)?.code,EPERM)
            }
        XCTAssertEqual(writes,1)
    }
}
