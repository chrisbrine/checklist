import XCTest
@testable import ChecklistCore

final class AuthorizedFileReadAdapterTests: XCTestCase {
    private final class Reader: AuthorizedFileReading {
        var invocations: [(String, Int, [String])] = []
        func read(_ path: String, maximum: Int, allowedRoots: [String]) throws -> SafeFileRead.Opened {
            invocations.append((path, maximum, allowedRoots))
            return .init(bytes: Data("verified".utf8), resolvedPath: "/synthetic/verified")
        }
    }
    func testForwardsExactAuthenticatedScopeAndLimit() throws {
        let reader = Reader()
        let result = try SafeFileRead.read("/synthetic/input", maximum: 31, allowedRoots: ["/synthetic"], reader: reader)
        XCTAssertEqual(result.bytes, Data("verified".utf8))
        XCTAssertEqual(result.resolvedPath, "/synthetic/verified")
        XCTAssertEqual(reader.invocations.count, 1)
        XCTAssertEqual(reader.invocations.first?.0, "/synthetic/input")
        XCTAssertEqual(reader.invocations.first?.1, 31)
        XCTAssertEqual(reader.invocations.first?.2, ["/synthetic"])
    }
    func testUnsupportedFileReadHasNoFallback() throws {
        XCTAssertThrowsError(try SafeFileRead.read("/must/not/open", maximum: 31, allowedRoots: ["/"], reader: UnavailableAuthorizedFileReader())) { error in
            XCTAssertEqual((error as? CoreError)?.code, "PLATFORM_CAPABILITY_UNAVAILABLE")
            XCTAssertEqual((error as? CoreError)?.details["capability"] as? String, "authorized_file_read")
        }
    }
}
