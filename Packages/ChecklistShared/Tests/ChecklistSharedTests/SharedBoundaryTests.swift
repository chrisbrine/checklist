import Foundation
import XCTest

final class SharedBoundaryTests: XCTestCase {
    func testProductionSharedTargetsImportOnlyPortableDependencies() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        let allowed = Set(["Foundation", "ChecklistDomain", "ChecklistContracts"])
        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for line in contents.split(separator: "\n") {
                let words = line.split(whereSeparator: \.isWhitespace)
                guard let importIndex = words.firstIndex(of: "import"),
                      words.indices.contains(importIndex + 1) else { continue }
                let module = String(words[importIndex + 1].split(separator: ".")[0])
                XCTAssertTrue(allowed.contains(module), "Nonportable dependency \(module) in \(file.lastPathComponent)")
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
    }
}
