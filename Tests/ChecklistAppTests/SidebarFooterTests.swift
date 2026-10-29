import XCTest

final class SidebarFooterTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testFooterKeepsStatusAndActionsInOneRowIncludingWhileLoading() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/SidebarView.swift"), encoding: .utf8)
        let footer = try XCTUnwrap(source.components(separatedBy: "VStack(spacing: Spacing.control) {").last)
            .components(separatedBy: "/// An archived project")[0]
        XCTAssertFalse(footer.contains("AccessibleHStack"), "The footer must not become a vertical stack above 130% text")
        XCTAssertFalse(footer.contains("buildLabel"))
        XCTAssertTrue(footer.contains("Text(store.serviceConnectionFooter)"))
        XCTAssertTrue(footer.contains(".fixedSize(horizontal: false, vertical: true)"), "Status text wraps at the narrow sidebar width")
        XCTAssertTrue(footer.contains("if store.sidebarLoading || (store.page == .media && mediaLoading) { ProgressView().controlSize(.mini).frame(width: 28, height: 28) }"))
        XCTAssertTrue(footer.contains("else { Button { Task { await store.refresh() } }"))
        XCTAssertTrue(footer.contains(".help(\"Refresh service\").accessibilityLabel(\"Refresh service\")"))
        let refreshEnd = try XCTUnwrap(footer.range(of: ".accessibilityLabel(\"Refresh service\") }"))
        let settings = try XCTUnwrap(footer.range(of: "Button(action: openSettings)"))
        XCTAssertLessThan(refreshEnd.upperBound, settings.lowerBound, "Settings stays outside the loading/refresh conditional")
        XCTAssertTrue(footer.contains(".help(\"Checklist Settings\").accessibilityLabel(\"Checklist Settings\").accessibilityIdentifier(\"openChecklistSettings\")"))
        XCTAssertTrue(footer.contains("}.fixedSize()"), "The action pair keeps its hit areas as status text wraps")
    }

    func testSettingsCommandsAndIntentionalBuildIdentityRemainAvailable() throws {
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/AppSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("LabeledContent(\"Version\", value: ChecklistBuildVersion.current.version)"))
        XCTAssertTrue(settings.contains("LabeledContent(\"Installed build\", value: store.buildLabel)"))
        XCTAssertTrue(settings.contains("DiagnosticsExportSection()"))
        let commands = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/App/ChecklistApp.swift"), encoding: .utf8)
        XCTAssertTrue(commands.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"r\")"))
    }
}
