import XCTest
@testable import ChecklistApp

/// CL-57: one confirmation pattern for destructive and authority-releasing actions.
final class ConfirmationTests: XCTestCase {
    func testEveryConfirmationNamesTheActionAndItsEffect() {
        let all = [Confirmations.archiveTicket {}, Confirmations.cancelRequest {}, Confirmations.retireTag("Bug") {}, Confirmations.removeDecision {},
                   Confirmations.removeLink {}, Confirmations.releaseWork("CL-1") {}, Confirmations.removeFromTriage("CL-1") {}, Confirmations.removeFromEpic("CL-1") {},
                   Confirmations.archiveTriage("Review pass") {}, Confirmations.cancelTicket("CL-1", status: "Canceled") {}]
        for item in all {
            XCTAssertTrue(item.title.hasSuffix("?"), item.title)
            XCTAssertGreaterThan(item.effect.count, 20, item.title)
            XCTAssertFalse(item.confirmLabel.isEmpty)
            XCTAssertNotEqual(item.confirmLabel, item.keepLabel, item.title)
        }
        var performed = false
        Confirmations.releaseWork("CL-1") { performed = true }.perform()
        XCTAssertTrue(performed)
    }

    /// Each destructive button opens its shared confirmation instead of acting at once.
    func testDestructiveButtonsAskFirst() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp/Views")
        let text = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let asks: [String] = [#"Button("Cancel request…", role: .destructive) { confirmation = Confirmations.cancelRequest"#,
                              #"Button("Retire…") { confirmation = Confirmations.retireTag"#,
                              #"Button("Remove decision…") { confirmation = Confirmations.removeDecision"#,
                              #"Button("Release…") { confirmation = Confirmations.releaseWork"#,
                              #"Button("Remove from Triage…") { confirmation = Confirmations.removeFromTriage"#,
                              #"Button("Remove from this Epic…") { confirmation = Confirmations.removeFromEpic"#,
                              #"Button { confirmation = Confirmations.removeLink"#,
                              #"confirmation = Confirmations.archiveTicket(perform: archive)"#,
                              #".sheet(isPresented: $archiveConfirmation.presented)"#,
                              #"Text(Confirmations.archiveTitle)"#,
                              #"confirmation = Confirmations.archiveTriage(ProductionGroups.label(triage), perform: change)"#,
                              #"reasonStatus = status"#]
        for ask in asks { XCTAssertTrue(text.contains(ask), ask) }
        XCTAssertNil(text.range(of: #"role: \.destructive\) \{ store\.(run|runTaskCommand)"#, options: .regularExpression), "A destructive button acts without its confirmation")
        XCTAssertFalse(text.contains(#""archived":!triage.bool("archived")"#), "Archive Triage asks first; only Restore acts at once")
        XCTAssertEqual(Confirmations.cancelTicket("CL-7", status: "Won't do") {}.title, "Set CL-7 to Won't do?")
        XCTAssertEqual(Confirmations.cancelTicket("CL-7", status: "Canceled") {}.keepLabel, "Keep current status")
    }
}
