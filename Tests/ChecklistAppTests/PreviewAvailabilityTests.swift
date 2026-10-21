import XCTest
import SwiftUI
import ChecklistCore
@testable import ChecklistApp

final class PreviewAvailabilityTests: XCTestCase {
    @MainActor func testCleanedAttachmentRowPreviewAndOpenInAccessibilitySettle() async throws {
        let watchdog = DispatchWorkItem { fputs("ATTACHMENT ROW AX EXCEEDED 10 SECONDS\n", stderr); _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticUnavailableRow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: isolatedDefaults("PreviewAvailabilityRow").preferences,
                                   restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: AvailabilityNoAlerts()),
                                   requestTransport: { _, _ in XCTFail("Known cleaned originals must not be read"); return [:] })
        store.connected = true
        let file = Record(values: ["id": "cleaned", "project_id": "synthetic-project", "task_id": "synthetic-ticket", "name": "cleaned.txt",
                                   "sha256": String(repeating: "a", count: 64), "size": 3_700_000, "mode": "managed", "availability": "original_cleaned"])
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(wasEnhanced, forAttribute: enhanced) }
        let host = NSHostingView(rootView: AttachmentRow(file: file).accessibilityIdentifier("detailOverlay").environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist attachment-row regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        func attribute(_ obj: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return obj.responds(to: selector) ? obj.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes(_ object: NSObject, depth: Int = 0) -> [NSObject] {
            guard depth < 30 else { XCTFail("Unbounded AX hierarchy"); return [] }
            return [object] + (attribute(object, "accessibilityChildren") as? [NSObject] ?? []).flatMap { nodes($0, depth: depth + 1) }
        }
        func press(_ object: NSObject) {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { XCTFail("AX button cannot be pressed"); return }
            let action = unsafeBitCast(object.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)
            XCTAssertTrue(action(object, selector))
        }
        for action in ["Preview", "Open in…"] {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(nodes(host).first { attribute($0, "accessibilityLabel") as? String == action })
            press(button)
            for _ in 0..<50 {
                if window.attachedSheet != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let sheet = try XCTUnwrap(window.attachedSheet)
            try await Task.sleep(nanoseconds: 100_000_000)
            let view = try XCTUnwrap(sheet.contentView)
            for _ in 0..<3 {
                let text = nodes(view).flatMap { object in ["accessibilityLabel", "accessibilityValue"].compactMap { attribute(object, $0) as? String } }.joined(separator: " | ")
                print("UNAVAILABLE AX \(action): \(text)")
                XCTAssertTrue(text.contains("Original unavailable"), text)
                XCTAssertTrue(text.contains("retained thumbnail"), text)
            }
            let close = try XCTUnwrap(nodes(view).first { attribute($0, "accessibilityLabel") as? String == "Close" })
            press(close)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    @MainActor func testCleanedOriginalSheetAccessibilityContainsReasonAndSettles() async throws {
        let watchdog = DispatchWorkItem { fputs("UNAVAILABLE PREVIEW AX EXCEEDED 10 SECONDS\n", stderr); _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticUnavailablePreview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: isolatedDefaults("PreviewAvailability").preferences,
                                   restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: AvailabilityNoAlerts()),
                                   requestTransport: { method, _ in calls.append(method); throw FilePreviewFailure("ORIGINAL_CLEANED: The original is unavailable; its metadata is retained.") })
        store.connected = true
        let file = Record(values: ["id": "cleaned", "project_id": "synthetic-project", "task_id": "synthetic-ticket", "name": "cleaned.txt",
                                   "sha256": String(repeating: "a", count: 64), "size": 3_700_000, "mode": "managed", "availability": "original_cleaned"])
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(wasEnhanced, forAttribute: enhanced) }
        let host = NSHostingView(rootView: FilePreviewSheet(attachment: file, inspected: { XCTFail("Unavailable originals cannot be inspected") }).accessibilityLabel("Selected attachment preview").environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist unavailable-preview regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func attribute(_ obj: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return obj.responds(to: selector) ? obj.perform(selector)?.takeUnretainedValue() : nil
        }
        func labels() -> [String] {
            var result: [String] = [], count = 0
            func visit(_ node: Any, depth: Int = 0) {
                count += 1
                guard count < 1000, depth < 30, let object = node as? NSObject else { return }
                for name in ["accessibilityLabel", "accessibilityValue"] {
                    if let value = attribute(object, name) as? String { result.append(value) }
                }
                for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            }
            for child in host.accessibilityChildren() ?? [] { visit(child) }
            XCTAssertLessThan(count, 1000)
            return result
        }
        for _ in 0..<3 {
            let text = labels().joined(separator: " | ")
            XCTAssertTrue(text.contains("Original unavailable"), text)
            XCTAssertTrue(text.contains("retained thumbnail"), text)
            XCTAssertTrue(text.contains("Close"), text)
            XCTAssertFalse(text.contains("Mark this original as inspected"), text)
            XCTAssertFalse(text.contains("Open working copy"), text)
        }
        XCTAssertTrue(calls.isEmpty, "Known unavailable metadata must not read bytes or record a verdict")
    }
}

@MainActor private final class AvailabilityNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) { }
}
