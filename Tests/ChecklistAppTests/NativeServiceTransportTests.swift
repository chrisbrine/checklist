import XCTest
@testable import ChecklistApp

final class NativeServiceTransportTests: XCTestCase {
    @MainActor func testUnsupportedRequestIsCatchablyRejectedBeforeClientCreation() async {
        do {
            _ = try await NativeServiceTransport.call("task_get", ["unsupported": NSObject()])
            XCTFail("Unsupported request values must be rejected before opening a client")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, 3840)
            XCTAssertEqual(failure.localizedDescription, "The request contains unsupported JSON values.")
        }
    }
}
