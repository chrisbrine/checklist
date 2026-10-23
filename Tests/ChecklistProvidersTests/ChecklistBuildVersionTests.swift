import XCTest
@testable import ChecklistProviders

final class ChecklistBuildVersionTests: XCTestCase {
    func testAllExecutableNamesReadTheSameBundleIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": "0.0.1.1", "build_id": "0123456789abcdef", "build_number": 118]).write(to: resources.appendingPathComponent("build-info.json"))
        for executable in ["ChecklistApp", "ChecklistService", "checklist"] {
            let identity = ChecklistBuildVersion.read(executable: root.appendingPathComponent("Contents/MacOS/" + executable))
            XCTAssertEqual(identity.version, "0.0.1.1")
            XCTAssertEqual(identity.buildID, "0123456789abcdef")
            XCTAssertEqual(identity.buildNumber, 118)
        }
    }
    func testMissingOrMalformedMetadataDoesNotInventARelease() {
        XCTAssertEqual(ChecklistBuildVersion.read(executable: nil).version, "development")
        let identity = ChecklistBuildVersion(metadata: ["version": "private/path", "build_id": "private/path"])
        XCTAssertEqual(identity.version, "development")
        XCTAssertEqual(identity.buildID, "development")
    }
}
