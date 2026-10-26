import ChecklistAXTestSupport
import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

/// CL-272 and CL-273: accessibility scroll actions on the app's scrolling
/// lists, with synthetic restore-preview templates and fake workspace pages.
/// No test reads the live store or opens a Checklist window.
final class LazyListAccessibilityTests: XCTestCase {
    // CL-273: a real-size preview must keep its decision controls visible.
    @MainActor func testRealSizeRestorePreviewKeepsConfirmationControlsVisibleAndPressable() async throws {
        let watchdog = AXProbe.watchdog(seconds: 240, "REAL-SIZE RESTORE PREVIEW")
        defer { watchdog.cancel() }
        for template in [RestorePreviewTemplate.make(unavailable: 931, managedFiles: 158_696),
                         RestorePreviewTemplate.make(unavailable: 160_000, managedFiles: 160_000)] {
            let total = (template["unavailable"] as? [[String:Any]] ?? []).count
            let holder = RestorePreviewHolder(template)
            var cancels = 0, confirms = 0
            let presented = try await RestorePreviewHost.present(holder, cancel: { cancels += 1 }, confirm: { confirms += 1 })
            defer { presented.close() }
            let sheet = presented.sheet
            let view = try XCTUnwrap(sheet.contentView)
            // The runner's step: scroll to the end of the preview, then look for the decision.
            try await AXProbe.scrollEveryScrollView(view, toEnd: true)
            for name in ["Cancel", "Prepare restored copy"] {
                let button = AXProbe.button(view, name)
                XCTAssertNotNil(button, "\(total) unavailable entries: \(name) is absent at the end of the preview")
                if let button { XCTAssertTrue(AXProbe.visible(button, in: sheet), "\(total) entries: \(name) is outside the visible sheet at the end") }
            }
            // The same controls stay visible at the start, without any scroll.
            try await AXProbe.scrollEveryScrollView(view, toEnd: false)
            let cancel = try XCTUnwrap(AXProbe.button(view, "Cancel"), "\(total) entries: Cancel is absent at the start")
            let prepare = try XCTUnwrap(AXProbe.button(view, "Prepare restored copy"), "\(total) entries: Prepare restored copy is absent at the start")
            XCTAssertTrue(AXProbe.visible(cancel, in: sheet), "\(total) entries: Cancel is outside the visible sheet at the start")
            XCTAssertTrue(AXProbe.visible(prepare, in: sheet), "\(total) entries: Prepare restored copy is outside the visible sheet at the start")
            let text = AXProbe.text(view)
            XCTAssertTrue(text.contains("Unavailable managed content: \(total.formatted())"), "The exact unavailable total stays shown")
            XCTAssertTrue(text.contains("The complete database and managed files passed verification."))
            XCTAssertTrue(text.contains("Active work requires explicit recovery."))
            AXProbe.press(cancel); AXProbe.press(prepare)
            XCTAssertEqual(cancels, 1); XCTAssertEqual(confirms, 1, "Only the owner's press reports the confirmation")
        }
    }

    // CL-272: scroll to the beginning and the end while the preview data changes.
    @MainActor func testRestorePreviewSurvivesAccessibilityScrollActionsWhileItsDataChanges() async throws {
        let watchdog = AXProbe.watchdog(seconds: 240, "RESTORE PREVIEW AX SCROLL")
        defer { watchdog.cancel() }
        let templates = [RestorePreviewTemplate.make(unavailable: 931, managedFiles: 158_696),
                         RestorePreviewTemplate.make(unavailable: 0, managedFiles: 19, zeroFamilies: 50),
                         RestorePreviewTemplate.make(unavailable: 160_000, managedFiles: 160_000),
                         RestorePreviewTemplate.make(unavailable: 12, managedFiles: 300, zeroFamilies: 5)]
        let holder = RestorePreviewHolder(templates[0])
        let presented = try await RestorePreviewHost.present(holder, cancel: {}, confirm: {})
        defer { presented.close() }
        let view = try XCTUnwrap(presented.sheet.contentView)
        let actions = try await AXProbe.exercise(view, rounds: 8, mutate: { holder.preview = templates[($0 + 1) % templates.count] })
        print("RESTORE PREVIEW AX SCROLL ACTIONS: \(actions)")
        XCTAssertNotNil(AXProbe.button(view, "Prepare restored copy"))
        XCTAssertNotNil(AXProbe.button(view, "Cancel"))
    }

    // CL-272 cause: SwiftUI's lazy accessibility node traps on an edge scroll
    // over rows it has not created yet, with static data and unique IDs.
    @MainActor func testEdgeScrollActionsOnUnrealizedLazyRowsScrollWithoutTrapping() async throws {
        let watchdog = AXProbe.watchdog(seconds: 120, "LAZY EDGE SCROLL")
        defer { watchdog.cancel() }
        XCTAssertTrue(LazyListAccessibilityGuard.install(), "The SwiftUI lazy accessibility node exists on this macOS release")
        let rows = (0..<200).map { "Synthetic row \($0)" }
        let host = NSHostingView(rootView: ScrollView { LazyVStack { ForEach(rows, id: \.self) { Text($0).frame(height: 30) } } }.frame(width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist lazy edge-scroll regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        let enhanced = AXProbe.enableEnhancedUserInterface()
        defer { enhanced() }
        try await AXProbe.until { host.layoutSubtreeIfNeeded(); return AXProbe.scrollTargets(host).contains { AXProbe.scrollActions($0).contains("AXScrollToBottom") } }
        let node = try XCTUnwrap(AXProbe.scrollTargets(host).first { AXProbe.scrollActions($0).contains("AXScrollToBottom") })
        let scroll = try XCTUnwrap(AXProbe.scrollViews(host).first)
        let start = scroll.contentView.bounds.origin.y
        AXProbe.perform(node, "AXScrollToBottom"); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(abs(scroll.contentView.bounds.origin.y - start), 1000, "AXScrollToBottom reaches the far rows")
        AXProbe.perform(node, "AXScrollToTop"); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 1, "AXScrollToTop returns to the first row")
        let actions = try await AXProbe.exercise(host, rounds: 4, mutate: { _ in })
        XCTAssertGreaterThan(actions, 0)
    }

    // CL-272 item 3: each mounted lazy list of changing workspace rows.
    @MainActor func testWorkspaceLazyListsSurviveAccessibilityScrollActionsWhileRowsChange() async throws {
        let watchdog = AXProbe.watchdog(seconds: 240, "WORKSPACE LIST AX SCROLL")
        defer { watchdog.cancel() }
        XCTAssertTrue(LazyListAccessibilityGuard.install())
        for page in [Page.needsYou, .activity, .epics] {
            let f = WorkspaceFixture(isolatedDefaults("LazyListAX-\(page.rawValue)").preferences, page: page)
            defer { f.clean() }
            f.rows = (0..<60).map { f.row("row-\($0)") }
            let store = f.store(), live = Task { await store.startLiveUpdates() }
            defer { live.cancel(); store.stopWindowReads() }
            let content: AnyView
            switch page {
            case .activity: content = AnyView(ActivityView())
            case .epics: content = AnyView(EpicWorkspaceView())
            default: content = AnyView(NeedsYouView())
            }
            let host = NSHostingView(rootView: content.environmentObject(store).frame(width: 700, height: 500))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Synthetic Checklist lazy-list accessibility regression (offscreen)"
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.orderFront(nil)
            let enhanced = AXProbe.enableEnhancedUserInterface()
            defer { enhanced() }
            try await AXProbe.until { host.layoutSubtreeIfNeeded(); return store.workspaceRows.count >= 50 && !AXProbe.scrollTargets(host).isEmpty }
            var generation = 0
            let actions = try await AXProbe.exercise(host, rounds: 6, mutate: { round in
                generation += 1
                // Remove, reorder, retitle and add rows (the new row first, inside the
                // 50-row page); then let the refresh publish them.
                var rows = (0..<(round % 2 == 0 ? 20 : 60)).map { f.row("row-\($0)", title: "Row \($0) generation \(generation)") }
                rows.reverse(); rows.insert(f.row("new-\(generation)"), at: 0)
                f.rows = rows
                Task { await store.refresh(quiet: true) }
            })
            print("WORKSPACE \(page.rawValue) AX SCROLL ACTIONS: \(actions)")
            XCTAssertGreaterThan(actions, 0, "\(page.rawValue): the lazy list offers scroll actions")
            try await AXProbe.until { !store.workspaceLoading }
            XCTAssertTrue(store.workspaceRows.contains { $0.id == "new-\(generation)" })
        }
    }
}

/// Synthetic restore_preview replies shaped like the service's reply.
enum RestorePreviewTemplate {
    // The 27 record families with no records in the observed 158,696-file backup.
    static let observedEmptyFamilies = ["cleanup_job", "cleanup_preview", "conversation", "direction_disposition", "handoff", "import_receipt", "import_record",
        "media_bulk_chunk", "media_bulk_operation", "media_candidate", "media_context_attention", "media_context_reconciliation", "media_intake", "media_intake_chunk",
        "media_intake_plan", "media_intake_row", "media_item", "media_item_target", "media_owner_decision", "media_review_context", "media_review_type",
        "media_review_type_revision", "media_rework_link", "media_round", "media_round_manifest", "media_suggestion", "recipient_target"]
    static func make(unavailable: Int, managedFiles: Int, zeroFamilies: Int = 27) -> [String:Any] {
        var families: [String:Int] = [:]
        for (index, name) in observedEmptyFamilies.enumerated() { families[name] = index < zeroFamilies ? 0 : index + 1 }
        for index in 0..<(64 - observedEmptyFamilies.count) { families["synthetic_family_\(index)"] = index < max(0, zeroFamilies - observedEmptyFamilies.count) ? 0 : 100 + index * 37 }
        let entries: [[String:Any]] = (0..<unavailable).map { index in
            index % 77 == 0 ? ["authority": "storage_job:00000000-0000-0000-0000-\(String(format: "%012d", index)):source-build-cache/\(String(repeating: "4", count: 64))", "reason": "rebuildable_source_build_cache"]
                : ["authority": "source_capture:00000000-0000-0000-0000-000000000273:00000000-0000-0000-0000-000000000273:synthetic/path/file-\(index).json", "reason": "evidence_cleaned"]
        }
        return ["manifest_sha256": String(repeating: "a", count: 64), "path": "/synthetic/backup-\(managedFiles)", "schema": 3, "store_id": "00000000-0000-0000-0000-000000000272",
                "source_root": "/synthetic/source", "captured_at": "2026-10-24T16:55:40Z", "verified_at": "2026-10-25T00:17:56Z", "record_families": families,
                "projects": (0..<5).map { ["id": "project-\($0)", "name": "Synthetic project \($0)", "archived": false] }, "project_count": 5,
                "managed_files": managedFiles, "managed_bytes": 4_688_395_874, "unavailable": entries, "external_references": ["/synthetic/a", "/synthetic/b"],
                "destination_parent": "/synthetic/restore", "existing_store_preserved": true, "authority": "new_incarnation_recovery_required"]
    }
}

@MainActor final class RestorePreviewHolder: ObservableObject {
    @Published var preview: [String:Any]
    init(_ preview: [String:Any]) { self.preview = preview }
}

/// Presents the product sheet the way StorageSettingsView does: its content
/// is rebuilt from a published preview while the sheet stays open.
@MainActor struct RestorePreviewHost: View {
    @ObservedObject var holder: RestorePreviewHolder
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        Text("Synthetic storage settings").frame(width: 700, height: 700).sheet(isPresented: .constant(true)) {
            RestorePreviewSheet(preview: holder.preview, cancel: cancel, confirm: confirm)
        }
    }
    @MainActor struct Presented {
        let window: NSWindow
        let sheet: NSWindow
        let restore: () -> Void
        func close() {
            restore()
            window.endSheet(sheet); window.contentView = nil; window.close()
        }
    }
    static func present(_ holder: RestorePreviewHolder, cancel: @escaping () -> Void, confirm: @escaping () -> Void) async throws -> Presented {
        let restore = AXProbe.enableEnhancedUserInterface()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist restore-preview regression (offscreen)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RestorePreviewHost(holder: holder, cancel: cancel, confirm: confirm))
        window.orderFront(nil)
        try await AXProbe.until { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(nanoseconds: 200_000_000)
        sheet.contentView?.layoutSubtreeIfNeeded()
        return Presented(window: window, sheet: sheet, restore: restore)
    }
}

/// In-process calls to the same AppKit accessibility methods an AX client
/// reaches: accessibilityChildren, accessibilityActionNames and
/// accessibilityPerformAction(_:) with the scroll actions.
@MainActor enum AXProbe {
    static func watchdog(seconds: Int, _ name: String) -> DispatchWorkItem {
        let item = DispatchWorkItem { fputs("\(name) EXCEEDED \(seconds) SECONDS\n", stderr); _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
        return item
    }
    static func enableEnhancedUserInterface() -> () -> Void {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let was = ChecklistTestAXAttributeValue(NSApplication.shared, enhanced) ?? false
        ChecklistTestAXSetValue(NSApplication.shared, true, enhanced)
        return { ChecklistTestAXSetValue(NSApplication.shared, was, enhanced) }
    }
    static func until(_ predicate: () -> Bool) async throws {
        // A liveness bound, not a budget: 60 s keeps a stuck fixture finite while a
        // concurrent build slows the hosted app (CL-275 review: 5 s did not settle).
        for _ in 0..<6000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Bounded accessibility fixture did not settle"); throw CancellationError()
    }
    static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    static func nodes(_ root: NSObject, limit: Int = 3000) -> [NSObject] {
        var result: [NSObject] = [], queue: [(NSObject, Int)] = [(root, 0)], index = 0
        while index < queue.count, result.count < limit {
            let (node, depth) = queue[index]; index += 1
            result.append(node)
            guard depth < 40 else { continue }
            for child in attribute(node, "accessibilityChildren") as? [NSObject] ?? [] { queue.append((child, depth + 1)) }
        }
        return result
    }
    static func actions(_ node: NSObject) -> [String] { attribute(node, "accessibilityActionNames") as? [String] ?? [] }
    static func scrollActions(_ node: NSObject) -> [String] { actions(node).filter { $0.hasPrefix("AXScroll") } }
    static func scrollTargets(_ root: NSObject) -> [NSObject] { nodes(root).filter { !scrollActions($0).isEmpty } }
    static func perform(_ node: NSObject, _ action: String) {
        let selector = NSSelectorFromString("accessibilityPerformAction:")
        guard node.responds(to: selector) else { return }
        typealias Perform = @convention(c) (NSObject, Selector, NSString) -> Void
        unsafeBitCast(node.method(for: selector), to: Perform.self)(node, selector, action as NSString)
    }
    static func press(_ node: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { XCTFail("AX button cannot be pressed"); return }
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
    }
    static func button(_ root: NSObject, _ label: String) -> NSObject? {
        nodes(root).first { attribute($0, "accessibilityLabel") as? String == label && (attribute($0, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue }
    }
    static func text(_ root: NSObject) -> String {
        nodes(root).flatMap { node in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { attribute(node, $0) as? String } }.joined(separator: " | ")
    }
    static func frame(_ node: NSObject) -> NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard node.responds(to: selector) else { return nil }
        typealias Frame = @convention(c) (NSObject, Selector) -> NSRect
        return unsafeBitCast(node.method(for: selector), to: Frame.self)(node, selector)
    }
    /// Visible means the element's whole frame lies inside the sheet and inside
    /// the clip view of every scroll view that contains its centre.
    static func visible(_ node: NSObject, in window: NSWindow) -> Bool {
        guard let frame = frame(node), !frame.isEmpty, window.frame.insetBy(dx: -1, dy: -1).contains(frame), let content = window.contentView else { return false }
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        for scroll in scrollViews(content) {
            let outer = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            let clip = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            if outer.contains(centre) && !clip.insetBy(dx: -1, dy: -1).contains(frame) { return false }
        }
        return true
    }
    static func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }
    /// Scrolls each vertical scroll view to its start or end until its
    /// document height stops changing (lazy content grows as it is reached).
    static func scrollEveryScrollView(_ root: NSView, toEnd: Bool) async throws {
        for _ in 0..<12 {
            var changed = false
            for scroll in scrollViews(root) {
                guard let document = scroll.documentView else { continue }
                let before = document.frame.height
                let y = toEnd ? (document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0)
                              : (document.isFlipped ? 0 : max(0, document.frame.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                for node in scrollTargets(scroll) where scrollActions(node).contains(toEnd ? "AXScrollToBottom" : "AXScrollToTop") {
                    perform(node, toEnd ? "AXScrollToBottom" : "AXScrollToTop")
                }
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
                if abs(document.frame.height - before) > 0.5 || abs(scroll.contentView.bounds.origin.y - y) > 0.5 { changed = true }
            }
            if !changed { return }
        }
    }
    /// Performs every offered scroll action on every scrolling node: once on
    /// the nodes read before a data change, before SwiftUI lays the change out,
    /// and again on the nodes read after it settles. Returns the action count.
    static func exercise(_ root: NSView, rounds: Int, mutate: (Int) -> Void) async throws -> Int {
        var performed = 0
        for round in 0..<rounds {
            let stale = scrollTargets(root).map { ($0, scrollActions($0)) }
            mutate(round)
            for (node, names) in stale { for name in names { perform(node, name); performed += 1 } }
            try await Task.sleep(nanoseconds: 20_000_000)
            root.layoutSubtreeIfNeeded()
            for node in scrollTargets(root) {
                for name in ["AXScrollToBottom", "AXScrollToTop"] + scrollActions(node) where scrollActions(node).contains(name) {
                    perform(node, name); performed += 1
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return performed
    }
}

/// Serves workspace_page for one surface from changing synthetic rows.
@MainActor private final class WorkspaceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-list-ax-" + UUID().uuidString)
    let preferences: UserDefaults
    let page: Page
    var rows: [[String:Any]] = []
    init(_ preferences: UserDefaults, page: Page) {
        self.preferences = preferences; self.page = page
        preferences.set(page.rawValue, forKey: "lastPage")
    }
    func row(_ id: String, title: String? = nil) -> [String:Any] {
        switch page {
        case .activity: return ["id": id, "project_id": "p", "record_type": "event", "type": "task_edit", "occurred_at": "2026-10-24T17:00:00Z", "data": ["reason": title ?? "Synthetic change \(id)"]]
        case .epics: return ["id": id, "project_id": "p", "record_type": "subproject", "name": title ?? "Synthetic Epic \(id)", "title": title ?? "Synthetic Epic \(id)", "ticket_count": 4, "done_count": 1, "revision": 1]
        default: return ["id": id, "project_id": "p", "record_type": "request", "title": title ?? "Request \(id)", "state": "pending", "revision": 1, "form_revision": 1,
                         "questions": [["id": "q", "prompt": "Your answer", "type": "text"]]]
        }
    }
    func transport(_ method: String, _ params: [String:Any]) async throws -> [String:Any] {
        if method == "changes_wait" { try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() }
        guard method == "workspace_page" else { throw NSError(domain: "UnexpectedLazyListRead", code: 1) }
        await Task.yield()
        let surface = params["surface"] as? String ?? ""
        let project = params["project_id"] as? String ?? "p"
        let all = surface == "record" ? [] : rows.map { row -> [String:Any] in var row = row; row["project_id"] = project; return row }
        let offset = Int(params["cursor"] as? String ?? "") ?? 0
        let limit = params["limit"] as? Int ?? 50
        let values = Array(all.dropFirst(offset).prefix(limit))
        let next = offset + values.count < all.count ? String(offset + values.count) : nil
        return ["workspace_version": 1, "surface": surface, "record_id": params["record_id"] ?? "", "rows": values, "total": all.count, "needs_you_count": page == .needsYou ? all.count : 0,
                "has_more": next != nil, "next_cursor": next as Any? ?? NSNull(), "previous_cursor": offset > 0 ? String(max(0, offset - limit)) : NSNull(),
                "projects": [["id": project, "name": "Synthetic project"]], "service": ["store_incarnation": "synthetic"], "content_cursor": "content"]
    }
    func store() -> ChecklistStore {
        ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                       desktopAlerts: DesktopAlertCoordinator(sink: LazyListNoAlerts()),
                       requestTransport: { [self] in try await transport($0, $1) }, navigationMemory: DetailItemNavigationMemory())
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class LazyListNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) { }
}
