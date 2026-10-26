import XCTest
import SwiftUI
@testable import ChecklistApp

/// CL-57: one confirmation pattern for destructive and authority-releasing actions.
@MainActor final class ConfirmationTests: XCTestCase {
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

    func testSafeDefaultConfirmationHasSeparateEscapeAndReturnPaths() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp/Support/Confirmations.swift")
        let text=try String(contentsOf:source,encoding:.utf8)
        XCTAssertFalse(text.contains("role: .cancel) { item.respond(confirmed: false) }.keyboardShortcut(.defaultAction)"), "Overriding the native cancel shortcut with Return loses Escape")
        XCTAssertTrue(text.contains(".onExitCommand { PendingConfirmation.resolve(pending, confirmed: false) }"), "Escape must use the same dismissal as the safe default")
    }

    func testSafeDefaultCancellationDismissesAndExplicitConfirmationRunsOnce() {
        let state = ConfirmationState()
        let make: [(String, (@escaping () -> Void) -> PendingConfirmation)] = [
            ("Retire type", {Confirmations.retireMediaType("Animation",perform:$0)}),
            ("Cancel round", {Confirmations.cancelMediaRound("Round C",perform:$0)}),
            ("Archive round", {Confirmations.archiveMediaRound("Round C",perform:$0)})
        ]
        for (name,make) in make {
            state.pending = make {state.performed += 1}
            let binding=Binding(get:{state.pending},set:{state.pending=$0})
            XCTAssertTrue(state.pending!.cancelIsDefault,name)
            // Escape, Return and the Keep button all resolve this same safe path.
            PendingConfirmation.resolve(binding,confirmed:false)
            XCTAssertNil(state.pending,name)
            XCTAssertEqual(state.performed,0,name)
        }
        state.pending = Confirmations.archiveMediaRound("Round C") {state.performed += 1}
        let binding=Binding(get:{state.pending},set:{state.pending=$0})
        PendingConfirmation.resolve(binding,confirmed:true)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.performed,1)
        PendingConfirmation.resolve(binding,confirmed:true)
        XCTAssertEqual(state.performed,1,"A dismissed confirmation cannot run again")
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

@MainActor private final class ConfirmationState {
    var pending: PendingConfirmation?
    var performed = 0
}
