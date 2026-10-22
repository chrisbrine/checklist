import XCTest
import SwiftUI
import CryptoKit
import Darwin
import ChecklistCore
@testable import ChecklistApp

extension PreviewAvailabilityTests {
    @MainActor func testMissingAndServiceRefusedSheetsKeepReasonWithoutOpeningOrInspection() async throws {
        let watchdog = previewAXWatchdog(); defer { watchdog.cancel() }
        let cases = [("missing", "", "The original is missing or unavailable."),
                     ("unavailable", "", "The original is missing or unavailable."),
                     ("available", "ORIGINAL_CLEANED", "The original is unavailable; its metadata is retained."),
                     ("available", "MANAGED_ORIGINAL_UNAVAILABLE", "The managed original could not be read.")]
        for (availability, code, reason) in cases {
            for external in [false, true] {
                var calls: [String] = [], inspections = 0
                let store = previewEntryStore { method, _ in
                    calls.append(method)
                    return ["error": ["code": code, "message": reason]]
                }
                let source = unavailableEntryFile(availability: availability, name: "missing.png")
                let host = PreviewAXHost(FilePreviewSheet(attachment: source, inspected: { inspections += 1 }, openExternally: external)
                    .accessibilityLabel("Selected attachment preview").environmentObject(store))
                defer { host.close() }
                try await host.settle("unavailable preview with reason: \(reason)") {
                    let text = host.text()
                    return text.contains("Original unavailable") && text.contains(reason) && text.contains("Close")
                }
                for _ in 0..<3 {
                    let text = host.text()
                    XCTAssertTrue(text.contains("Original unavailable"), text)
                    XCTAssertTrue(text.contains(reason), text)
                    XCTAssertTrue(text.contains("Close"), text)
                    XCTAssertFalse(text.contains("Mark this original as inspected"), text)
                    XCTAssertFalse(text.contains("Open working copy"), text)
                    XCTAssertFalse(text.contains("Actual pixels"), text)
                    let open = try XCTUnwrap(host.nodes().first { previewAXString($0, "accessibilityLabel") == "Open in…" })
                    XCTAssertFalse(previewAXEnabled(open))
                }
                XCTAssertEqual(inspections, 0)
                XCTAssertEqual(calls, availability == "available" ? ["attachment_read"] : [])
                XCTAssertEqual(source.string("sha256"), String(repeating: "a", count: 64))
                XCTAssertEqual(source.string("target_manifest_id"), "exact-target")
                XCTAssertEqual(source.string("review_attempt_id"), "exact-review")
                let cpu = try await previewIdleCPU()
                print("UNAVAILABLE IDLE CPU: \(availability)/\(code), external=\(external): \(cpu)s / 0.3s wall")
                XCTAssertLessThan(cpu, 0.15, "An unavailable preview must settle at rest")
            }
        }
    }

    @MainActor func testMissingAttachmentRowPreviewAndOpenInSettle() async throws {
        let watchdog = previewAXWatchdog(); defer { watchdog.cancel() }
        for availability in ["missing", "unavailable"] {
            var calls: [String] = []
            let store = previewEntryStore { method, _ in calls.append(method); return [:] }
            let source = unavailableEntryFile(availability: availability)
            let host = PreviewAXHost(AttachmentRow(file: source).accessibilityIdentifier("detailOverlay").environmentObject(store))
            defer { host.close() }
            try await host.settle("attachment row preview actions") {
                ["Preview", "Open in…"].allSatisfy { action in host.nodes().contains { previewAXString($0, "accessibilityLabel") == action } }
            }
            for action in ["Preview", "Open in…"] {
                try host.press(action)
                let sheet = try await host.sheet()
                try await host.settle("missing original sheet", root: sheet) {
                    let text = host.text(sheet)
                    return text.contains("Original unavailable") && text.contains("missing or unavailable") && text.contains("Close")
                }
                for _ in 0..<3 {
                    let text = host.text(sheet)
                    XCTAssertTrue(text.contains("Original unavailable"), text)
                    XCTAssertTrue(text.contains("missing or unavailable"), text)
                    XCTAssertFalse(text.contains("Open working copy"), text)
                }
                try host.press("Close", root: sheet)
                try await host.settle("closed preview sheet") { host.window.attachedSheet == nil }
                XCTAssertNil(host.window.attachedSheet)
            }
            XCTAssertTrue(calls.isEmpty)
        }
    }

    @MainActor func testUnavailableImageReviewAndBundleRolesPreserveInspectionAndAttribution() async throws {
        let watchdog = previewAXWatchdog(); defer { watchdog.cancel() }
        for availability in ["original_cleaned", "missing", "unavailable", "available"] {
            var calls: [String] = []
            let store = previewEntryStore { method, _ in
                calls.append(method)
                return ["error": ["code": "MANAGED_ORIGINAL_UNAVAILABLE", "message": "The managed original could not be read."]]
            }
            let image = unavailableEntryFile(availability: availability, name: "candidate.png")
            let candidate = ImageReviewCandidate(file: image, manifestID: "exact-target")
            var selection = Set<ImageInspectionIdentity>()
            do {
                let host = PreviewAXHost(ImageReviewSheet(current: [candidate], previous: [candidate], selection: Binding(get: { selection }, set: { selection = $0 })).environmentObject(store))
                defer { host.close() }
                let reason = availability == "available" ? "The managed original could not be read." : "Original unavailable or cleaned"
                try await host.settle("both image review originals unavailable: \(availability)") {
                    let text = host.text()
                    let unavailablePanes = host.nodes().filter {
                        previewAXString($0, "accessibilityLabel").contains(reason) || previewAXString($0, "accessibilityValue").contains(reason)
                    }
                    return unavailablePanes.count >= 2 && !text.contains("Loading exact original")
                }
                for _ in 0..<3 {
                    let text = host.text()
                    XCTAssertTrue(text.contains(availability == "available" ? "The managed original could not be read." : "Original unavailable or cleaned"), text)
                    XCTAssertFalse(text.contains("Quick Look"), text)
                    XCTAssertFalse(text.contains("Actual pixels"), text)
                    XCTAssertFalse(host.nodes().contains { previewAXString($0, "accessibilityRole") == "AXCheckBox" && previewAXString($0, "accessibilityLabel") == "Inspected" })
                }
                XCTAssertTrue(selection.isEmpty)
                XCTAssertEqual(calls, availability == "available" ? ["attachment_read", "attachment_read"] : [])
            }
            calls = []
            let files = ["scenario", "build", "state", "screen", "log"].map { id -> Record in
                var values = unavailableEntryFile(availability: availability, name: id + ".dat").values
                values["id"] = id
                return Record(values: values)
            }
            func ref(_ id: String) -> [String: Any] { ["artifact_id": id, "sha256": String(repeating: "a", count: 64)] }
            let bundle: [String: Any] = ["id": "exact-bundle", "sha256": "bundle-digest", "scenario": ref("scenario"),
                "build": ref("build").merging(["build_id": "exact-build", "version": "1", "platform": "macOS"]) { _, new in new },
                "state_files": [ref("state")], "screenshots": [ref("screen")], "log": ref("log")]
            let manifest = Record(values: ["id": "exact-target", "project_id": "p", "task_id": "t", "evidence": ["playtest_bundle": bundle]])
            let review = ReviewProjection(task: Record(values: ["id": "t", "project_id": "p", "current_manifest_id": "exact-target"]), project: nil,
                data: ["manifests": [manifest.values], "attachments": files.map(\.values), "reviews": [["id": "prior-verdict", "project_id": "p", "task_id": "t", "manifest_id": "exact-target", "actor_display": "Original reviewer", "verdict": "reject", "checks": [["evidence_refs": [ref("screen")]]]]]])
            let projection = PlaytestBundleProjection(manifest: manifest, review: review)
            do {
                let host = PreviewAXHost(PlaytestBundleView(manifest: manifest, projection: review).environmentObject(store))
                defer { host.close() }
                try await host.settle("playtest bundle disclosure") {
                    host.nodes().contains { previewAXString($0, "accessibilityLabel").contains("Playtest bundle") }
                }
                let disclosure = try XCTUnwrap(host.nodes().first { previewAXString($0, "accessibilityLabel").contains("Playtest bundle") })
                try host.press(disclosure)
                try await host.settle("expanded playtest bundle: \(availability)") {
                    availability == "available"
                        ? host.nodes().contains { previewAXString($0, "accessibilityLabel") == "Preview" }
                        : host.text().contains("Original unavailable or changed")
                }
                if availability == "available" {
                    try host.press("Preview")
                    let sheet = try await host.sheet()
                    try await host.settle("refused playtest original", root: sheet) {
                        let text = host.text(sheet)
                        return text.contains("The managed original could not be read.") && text.contains("Close")
                    }
                    let text = host.text(sheet)
                    XCTAssertTrue(text.contains("The managed original could not be read."), text)
                    XCTAssertFalse(text.contains("Open working copy"), text)
                    try host.press("Close", root: sheet)
                    XCTAssertEqual(calls, ["attachment_read"])
                } else {
                    let text = host.text()
                    XCTAssertTrue(text.contains("Original unavailable or changed"), text)
                    XCTAssertFalse(host.nodes().contains { ["Preview", "Open in…"].contains(previewAXString($0, "accessibilityLabel")) })
                    XCTAssertTrue(calls.isEmpty)
                }
            }
            XCTAssertEqual(projection.files.count, 5)
            XCTAssertEqual(projection.files.first { $0.role == "Screenshot 1" }?.ref.string("sha256"), String(repeating: "a", count: 64))
            XCTAssertTrue(projection.files.first { $0.role == "Screenshot 1" }?.cited == true)
            XCTAssertEqual(projection.verdicts.first?.string("actor_display"), "Original reviewer")
            XCTAssertEqual(candidate.identity.targetManifestID, "exact-target")
        }
    }

    @MainActor func testActiveCopyCancelButtonShowsAccessibleCanceledOutcome() async throws {
        let watchdog = previewAXWatchdog(); defer { watchdog.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPreviewCancelUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic-large.mp4"), data = Data(repeating: 7, count: 128 * 1024 * 1024)
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var values = unavailableEntryFile(availability: "available", name: url.lastPathComponent).values
        values["size"] = data.count; values["sha256"] = hash
        let source = Record(values: values)
        var calls: [String] = [], inspections = 0
        let store = previewEntryStore { method, params in
            calls.append(method)
            if method == "attachment_read_release" { XCTAssertEqual(params["read_hold_id"] as? String, "ui-hold"); return [:] }
            XCTAssertEqual(method, "attachment_read")
            var reply = source.values; reply["url"] = url.path; reply["read_hold_id"] = "ui-hold"
            return reply
        }
        let host = PreviewAXHost(FilePreviewSheet(attachment: source, inspected: { inspections += 1 }).environmentObject(store))
        defer { host.close() }
        var activeBytes: Int64 = 0
        try await host.settle("observed partial preview copy") {
            guard let progress = host.nodes().first(where: { previewAXString($0, "accessibilityIdentifier") == "filePreviewCopyProgress" }) else { return false }
            let words = previewAXString(progress, "accessibilityValue").split(separator: " ")
            guard words.count >= 3, let count = Int64(words[0]), let total = Int64(words[2]), count > 0, count < total else { return false }
            activeBytes = count
            return true
        }
        try host.press("Cancel preview")
        XCTAssertGreaterThan(activeBytes, 0, "This case requires an observed partial copy")
        try await host.settle("canceled preview and released read hold") {
            host.text().contains("Preview canceled") && calls.contains("attachment_read_release")
        }
        let outcome = host.text()
        XCTAssertTrue(outcome.contains("Preview canceled"), outcome)
        XCTAssertFalse(outcome.contains("Mark this original as inspected"), outcome)
        XCTAssertFalse(outcome.contains("Press Play"), outcome)
        let expression = try NSRegularExpression(pattern: #"Preparation stopped after copying ([0-9]+) of ([0-9]+) bytes"#)
        let match = try XCTUnwrap(expression.firstMatch(in: outcome, range: NSRange(outcome.startIndex..<outcome.endIndex, in: outcome)))
        let copied = try XCTUnwrap(Int64((outcome as NSString).substring(with: match.range(at: 1))))
        let total = try XCTUnwrap(Int64((outcome as NSString).substring(with: match.range(at: 2))))
        XCTAssertGreaterThanOrEqual(copied, activeBytes); XCTAssertLessThan(copied, total)
        XCTAssertEqual(total, Int64(data.count)); XCTAssertEqual(inspections, 0)
        XCTAssertEqual(calls, ["attachment_read", "attachment_read_release"])
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(), hash)
        let cpu = try await previewIdleCPU()
        print("NATIVE AX CANCELED: active=\(activeBytes), stopped=\(copied)/\(total), idle CPU=\(cpu)s / 0.3s wall")
        XCTAssertLessThan(cpu, 0.15)
    }
}

private func previewAXWatchdog() -> DispatchWorkItem {
    let item = DispatchWorkItem { fputs("PREVIEW ENTRY AX EXCEEDED 20 SECONDS\n", stderr); _exit(124) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: item)
    return item
}

private func unavailableEntryFile(availability: String, name: String = "unavailable.txt") -> Record {
    Record(values: ["id": "original", "name": name, "project_id": "p", "task_id": "t", "sha256": String(repeating: "a", count: 64), "size": 4,
                    "mode": "managed", "availability": availability, "target_manifest_id": "exact-target", "review_attempt_id": "exact-review", "author": "Original author", "origin": "worker", "keep_original": true])
}

@MainActor private extension PreviewAvailabilityTests {
func previewEntryStore(_ transport: @escaping (String, [String: Any]) async throws -> [String: Any]) -> ChecklistStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPreviewEntryDrafts-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root),
                               preferences: isolatedDefaults("PreviewEntry").preferences, restorePendingCommand: false,
                               desktopAlerts: DesktopAlertCoordinator(sink: PreviewEntryNoAlerts()), requestTransport: transport)
    store.connected = true
    return store
}
}

private func previewAXAttribute(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
}
private func previewAXString(_ object: NSObject, _ name: String) -> String { previewAXAttribute(object, name) as? String ?? "" }
private func previewAXEnabled(_ object: NSObject) -> Bool {
    let selector = NSSelectorFromString("isAccessibilityEnabled")
    guard object.responds(to: selector) else { XCTFail("Missing native enabled state"); return false }
    return unsafeBitCast(object.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)(object, selector)
}
@MainActor private func previewIdleCPU() async throws -> Double {
    let start = clock()
    try await Task.sleep(nanoseconds: 300_000_000)
    return Double(clock() - start) / Double(CLOCKS_PER_SEC)
}

@MainActor private final class PreviewAXHost {
    let window: NSWindow
    let view: NSView
    private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let wasEnhanced: Any
    init<V: View>(_ root: V) {
        wasEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        view = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist preview-entry regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    }
    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.close() }
        window.contentView = nil; window.close()
        NSApplication.shared.accessibilitySetValue(wasEnhanced, forAttribute: enhanced)
    }
    func settle(_ state: String, root: NSObject? = nil, file: StaticString = #filePath, line: UInt = #line,
                until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            view.layoutSubtreeIfNeeded()
            (root as? NSView)?.layoutSubtreeIfNeeded()
            if predicate() { return }
            if ContinuousClock.now >= deadline {
                _ = try XCTUnwrap(nil as Bool?, "Timed out after 5 seconds waiting for \(state). Observed AX: \(text(root))", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func nodes(_ root: NSObject? = nil) -> [NSObject] {
        var result: [NSObject] = []
        func visit(_ node: NSObject, depth: Int = 0) {
            guard depth < 30, result.count < 1000 else { XCTFail("Unbounded native AX hierarchy"); return }
            result.append(node)
            for child in previewAXAttribute(node, "accessibilityChildren") as? [NSObject] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root ?? view)
        return result
    }
    func text(_ root: NSObject? = nil) -> String {
        nodes(root).flatMap { object in ["accessibilityLabel", "accessibilityValue"].compactMap { previewAXAttribute(object, $0) as? String } }.joined(separator: " | ")
    }
    func press(_ label: String, root: NSObject? = nil) throws {
        try press(XCTUnwrap(nodes(root).first { previewAXString($0, "accessibilityLabel") == label }, "Missing \(label): \(text(root))"))
    }
    func press(_ object: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("AX element cannot be pressed"); return }
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: (@convention(c) (NSObject, Selector) -> Bool).self)(object, selector))
    }
    func sheet() async throws -> NSView {
        try await settle("attached preview sheet") { window.attachedSheet?.contentView != nil }
        return try XCTUnwrap(window.attachedSheet?.contentView)
    }
}

@MainActor private final class PreviewEntryNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) { }
}
