import XCTest
import AppKit
import Carbon.HIToolbox
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistApp

/// CL-65: quick capture works without a workspace window, keeps an unsent draft on this Mac and
/// replays the same commands after an outage.
@MainActor final class QuickCaptureTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-" + UUID().uuidString)
        preferences = isolatedDefaults("QuickCapture").preferences
    }
    override func tearDown() async throws {
        preferences = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func model(_ transport: @escaping QuickCaptureModel.Transport) -> QuickCaptureModel {
        QuickCaptureModel(journal: LocalDraftJournal(directory: root), preferences: preferences!, transport: transport)
    }

    func testOfflineDraftIsKeptAndSaysNotSentThenSendsWithTheSameCommands() async throws {
        var online = false
        var calls: [(String, [String: Any])] = []
        let transport: QuickCaptureModel.Transport = { method, params in
            calls.append((method, params))
            guard online else { throw ChecklistError("SERVICE_UNAVAILABLE", "offline") }
            switch method {
            case "project_list": return ["projects": [["id": "p1", "name": "Game"], ["id": "p2", "name": "Old", "archived": true]]]
            case "task_create": return ["id": "t1", "key": "GAME-7", "project_id": "p1"]
            case "attachment_add": return ["id": "a1"]
            default: return [:]
            }
        }
        let first = model(transport)
        await first.loadProjects()
        XCTAssertFalse(first.projectsAvailable)
        first.draft.title = "Boss door does not open"
        first.draft.projectID = "p1"
        first.draft.note = "Seen in the second level"
        let file = root.appendingPathComponent("shot.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        first.attach([file])
        await first.send()
        guard case .notSent(let reason) = first.state else { return XCTFail("An unavailable service leaves the draft unsent") }
        XCTAssertTrue(reason.contains("Not sent") && reason.contains("saved on this Mac"))
        let command = try XCTUnwrap(first.draft.createCommandID)

        // A new model (for example after a quit) restores the saved draft with the same command IDs.
        let restored = model(transport)
        XCTAssertEqual(restored.draft.title, "Boss door does not open")
        XCTAssertEqual(restored.draft.createCommandID, command)
        XCTAssertEqual(restored.draft.files.map(\.commandID), first.draft.files.map(\.commandID))
        online = true
        await restored.loadProjects()
        XCTAssertEqual(restored.projects.map(\.id), ["p1"], "Archived projects are not offered")
        await restored.send()
        XCTAssertEqual(restored.state, .captured(key: "GAME-7", taskID: "t1", projectID: "p1"))
        let create = try XCTUnwrap(calls.last { $0.0 == "task_create" }?.1)
        XCTAssertEqual(create["command_id"] as? String, command, "The retry replays the original create command")
        XCTAssertEqual(create["brief"] as? String, "Seen in the second level")
        let attach = try XCTUnwrap(calls.last { $0.0 == "attachment_add" }?.1)
        XCTAssertEqual(attach["task_id"] as? String, "t1"); XCTAssertEqual(attach["path"] as? String, file.path)
        XCTAssertTrue(restored.draft.isEmpty, "A sent ticket clears the draft")
        XCTAssertEqual(restored.draft.projectID, "p1", "The next capture keeps the project")
        XCTAssertTrue(model(transport).draft.isEmpty, "The cleared draft is saved")
    }

    /// Real router, with only the reply transport faulted after the create commits.
    @MainActor private final class CreateFixture {
        let root: URL
        let router: CommandRouter
        let owner = Caller(role: "owner", installation: "quick-capture-qualification", projectIDs: [])
        let projectID: String
        var loseReply = true
        var loseAttachmentReply = false
        var refusal: String?
        var creates: [[String: Any]] = []
        var attachments: [[String: Any]] = []
        init() throws {
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ChecklistQualification")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            root = cache.appendingPathComponent("quick-capture-" + UUID().uuidString)
            router = try CommandRouter(root: root)
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let reply = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
                "name": "Quick capture qualification", "key_prefix": "QC", "root_path": workspace.path], caller: owner)
            projectID = try XCTUnwrap((reply["data"] as? [String: Any])?["id"] as? String)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func transport(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            if method == "task_create" {
                creates.append(params)
                if let refusal { throw ChecklistError(refusal, "Refused before acceptance") }
            }
            if method == "attachment_add" { attachments.append(params) }
            let reply: [String: Any]
            do { reply = try router.handle(method: method, params: params, caller: owner) }
            catch let error as CoreError { reply = ["error": error.dictionary] }
            if reply["error"] == nil, method == "task_create", loseReply {
                loseReply = false
                throw CommandReply.unknown(commandID: params["command_id"] as? String, reason: "qualification_dropped_reply")
            }
            if reply["error"] == nil, method == "attachment_add", loseAttachmentReply {
                loseAttachmentReply = false
                throw CommandReply.unknown(commandID: params["command_id"] as? String, reason: "qualification_dropped_attachment_reply")
            }
            return try CommandReply.decode(JSONSerialization.data(withJSONObject: reply), method: method,
                                           commandID: params["command_id"] as? String)["data"] as! [String: Any]
        }
        func tickets() throws -> [[String: Any]] {
            let reply = try router.handle(method: "task_list", params: ["project_id": projectID], caller: owner)
            return try XCTUnwrap((reply["data"] as? [String: Any])?["tasks"] as? [[String: Any]])
        }
    }

    func testUnknownCreateKeepsOriginalIntentAndNewerEditsAsNextDraft() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        let quick = model(fixture.transport)
        quick.draft.projectID = fixture.projectID
        quick.draft.title = "Original title"
        quick.draft.note = "Original brief"
        let file = fixture.root.appendingPathComponent("capture.txt")
        try Data("Qualification attachment".utf8).write(to: file)
        quick.attach([file])
        let chosenFile = try XCTUnwrap(quick.draft.files.first)
        await quick.send()
        guard case .uncertain(let text) = quick.state else { return XCTFail("A committed lost reply must say it may already be saved") }
        XCTAssertTrue(text.contains("may already have saved"))
        XCTAssertFalse(text.contains("Not sent"))
        XCTAssertEqual(quick.sendTitle, "Check again")
        quick.remove(chosenFile)
        XCTAssertEqual(quick.draft.files, [chosenFile], "Files remain tied to the original ticket")
        quick.draft.title = "Newer title"
        quick.draft.note = "Newer brief"
        quick.draft.projectID = ""
        await quick.loadProjects()
        XCTAssertEqual(quick.state, .uncertain(text), "A project refresh cannot erase the uncertain create")
        XCTAssertTrue(quick.canSend, "Checking the original ticket does not require a valid next draft")
        await quick.send()
        XCTAssertEqual(fixture.creates.count, 2)
        if fixture.creates.count == 2 {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: fixture.creates[0], options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: fixture.creates[1], options: .sortedKeys))
        }
        let tickets = try fixture.tickets()
        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets.first?["title"] as? String, "Original title")
        let attached = try XCTUnwrap(fixture.attachments.first)
        XCTAssertEqual(attached["command_id"] as? String, chosenFile.commandID)
        XCTAssertEqual(attached["path"] as? String, chosenFile.path)
        XCTAssertEqual(attached["project_id"] as? String, fixture.projectID)
        XCTAssertEqual(attached["task_id"] as? String, tickets.first?["id"] as? String)
        guard case .captured = quick.state else { return XCTFail("Replay confirms the original ticket") }
        XCTAssertEqual(quick.draft.title, "Newer title")
        XCTAssertEqual(quick.draft.note, "Newer brief")
        XCTAssertEqual(quick.draft.projectID, "", "Even an unfinished newer edit stays intact")
        XCTAssertNil(quick.draft.createCommandID, "The next draft must get a new command ID")
    }

    func testRestartReplaysOriginalCreateDespiteSavedNewerTitle() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        var quick: QuickCaptureModel? = model(fixture.transport)
        quick!.draft.projectID = fixture.projectID
        quick!.draft.title = "Original before restart"
        await quick!.send()
        quick!.draft.title = "Newer after restart"
        quick = nil
        let restored = model(fixture.transport)
        XCTAssertEqual(restored.state, .uncertain(QuickCaptureModel.uncertainCreate))
        XCTAssertEqual(restored.sendTitle, "Check again")
        await restored.send()
        XCTAssertEqual(fixture.creates.count, 2)
        XCTAssertEqual(fixture.creates.last?["title"] as? String, "Original before restart")
        XCTAssertEqual(fixture.creates.first?["command_id"] as? String, fixture.creates.last?["command_id"] as? String)
        XCTAssertEqual(try fixture.tickets().count, 1)
        guard case .captured = restored.state else { return XCTFail("Restart replay confirms the original ticket") }
        XCTAssertEqual(restored.draft.title, "Newer after restart")
    }

    func testRefusalBeforeAcceptanceLeavesEditableNotSentDraft() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        fixture.refusal = "SERVICE_UNAVAILABLE"
        let quick = model(fixture.transport)
        quick.draft.projectID = fixture.projectID
        quick.draft.title = "Before refusal"
        await quick.send()
        guard case .notSent(let text) = quick.state else { return XCTFail("A connect refusal is Not sent") }
        XCTAssertTrue(text.contains("Not sent"))
        quick.draft.title = "Edited after refusal"
        fixture.refusal = nil; fixture.loseReply = false
        await quick.send()
        XCTAssertEqual(try fixture.tickets().count, 1)
        XCTAssertEqual(try fixture.tickets().first?["title"] as? String, "Edited after refusal")
        XCTAssertNotEqual(fixture.creates.first?["command_id"] as? String, fixture.creates.last?["command_id"] as? String)
    }

    func testValidationRefusalDoesNotFreezeTheDraft() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        fixture.loseReply = false
        let quick = model(fixture.transport)
        quick.draft.projectID = fixture.projectID
        quick.draft.title = String(repeating: "x", count: 2001)
        await quick.send()
        guard case .notSent = quick.state else { return XCTFail("A validation refusal is Not sent") }
        XCTAssertNil(quick.draft.pendingCreate)
        XCTAssertTrue(try fixture.tickets().isEmpty)
        quick.draft.title = "Valid title after refusal"
        await quick.send()
        XCTAssertEqual(try fixture.tickets().first?["title"] as? String, "Valid title after refusal")
        XCTAssertNotEqual(fixture.creates.first?["command_id"] as? String, fixture.creates.last?["command_id"] as? String)
    }

    func testUnknownOutcomeSurvivesOfflineRefreshAndPreSendRefusalOnCheck() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        var offline = false
        let quick = model { method, params in
            if offline { throw ChecklistError("SERVICE_UNAVAILABLE", "Connection refused") }
            return try await fixture.transport(method, params)
        }
        quick.draft.projectID = fixture.projectID
        quick.draft.title = "Saved before outage"
        await quick.send()
        let original = quick.draft.pendingCreate
        offline = true
        await quick.loadProjects()
        XCTAssertEqual(quick.state, .uncertain(QuickCaptureModel.uncertainCreate))
        await quick.send()
        XCTAssertEqual(quick.state, .uncertain(QuickCaptureModel.uncertainCreate))
        XCTAssertEqual(quick.draft.pendingCreate, original, "A later connect failure does not disprove the earlier commit")
        offline = false
        await quick.send()
        guard case .captured = quick.state else { return XCTFail("The original intent remains recoverable") }
        XCTAssertEqual(try fixture.tickets().count, 1)
    }

    func testSavedTicketWithLostAttachmentReplyKeepsFixedFileIntentAcrossRestart() async throws {
        let fixture = try CreateFixture(); defer { fixture.cleanup() }
        fixture.loseReply = false; fixture.loseAttachmentReply = true
        let quick = model(fixture.transport)
        quick.draft.projectID = fixture.projectID; quick.draft.title = "Ticket with file"
        let file = fixture.root.appendingPathComponent("attachment.txt")
        try Data("Qualification file".utf8).write(to: file)
        quick.attach([file])
        await quick.send()
        guard case .filesPending(let text) = quick.state else { return XCTFail("A known saved ticket cannot say Not sent") }
        XCTAssertTrue(text.contains("The ticket is saved")); XCTAssertFalse(text.contains("Not sent"))
        let taskID = try XCTUnwrap(quick.draft.createdTaskID)
        quick.draft.projectID = ""; quick.draft.note = "Newer note"
        let restored = model(fixture.transport)
        XCTAssertEqual(restored.state, .filesPending(QuickCaptureModel.savedTicketFiles))
        XCTAssertTrue(restored.canSend)
        await restored.send()
        XCTAssertEqual(fixture.creates.count, 1, "A known ticket never needs another create")
        XCTAssertEqual(fixture.attachments.count, 2)
        if fixture.attachments.count == 2 {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: fixture.attachments[0], options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: fixture.attachments[1], options: .sortedKeys))
        }
        let reply = try fixture.router.handle(method: "attachment_list", params: ["project_id": fixture.projectID, "task_id": taskID], caller: fixture.owner)
        XCTAssertEqual(((reply["data"] as? [String: Any])?["attachments"] as? [[String: Any]])?.count, 1)
        guard case .captured = restored.state else { return XCTFail("The file replay finishes capture") }
        XCTAssertEqual(restored.draft.note, "Newer note")
        XCTAssertEqual(restored.draft.projectID, "")
    }

    func testTimeoutAndCommandFailureKeepThePendingIntent() async throws {
        for error in [ChecklistError("COMMAND_FAILED", "Lost reply") as Error,
                      URLError(.timedOut), ChecklistError("TIMEOUT", "Timed out waiting for reply"),
                      ChecklistError("SERVICE_UNAVAILABLE", "Lost connection after sending", details: ["command_outcome": "unknown"]),
                      ChecklistError("INVALID_RESPONSE", "Missing ticket")] {
            // Each error gets its own journal, so these are independent first sends.
            let journal = LocalDraftJournal(directory: root.appendingPathComponent(UUID().uuidString))
            let quick = QuickCaptureModel(journal: journal, preferences: preferences!, transport: { _, _ in throw error })
            quick.draft.projectID = "p1"; quick.draft.title = "Uncertain send"
            await quick.send()
            XCTAssertEqual(quick.state, .uncertain(QuickCaptureModel.uncertainCreate))
            XCTAssertNotNil(quick.draft.pendingCreate)
            XCTAssertEqual(quick.sendTitle, "Check again")
        }
    }

    func testOlderJournalWithoutPendingIntentStillLoads() throws {
        // Encode the prior journal shape without relying on today's draft encoder.
        struct OlderDraft: Codable {
            var projectID = "p1", title = "Older draft", note = "Older note"
            var files: [QuickCaptureDraft.File] = []
            var createCommandID = "old-command"
        }
        try LocalDraftJournal(directory: root).save(OlderDraft(), kind: QuickCaptureModel.journalKind, key: "draft")
        let restored = model { _, _ in [:] }
        XCTAssertEqual(restored.draft.title, "Older draft")
        XCTAssertEqual(restored.draft.note, "Older note")
        XCTAssertEqual(restored.draft.createCommandID, "old-command")
        XCTAssertNil(restored.draft.pendingCreate)
        XCTAssertTrue(restored.canSend)
    }

    func testTitleOnlyCaptureNeedsAProjectAndATitle() async {
        let quick = model { method, _ in method == "project_list" ? ["projects": [["id": "p1", "name": "Only"]]] : ["id": "t9", "key": "ONLY-1"] }
        await quick.loadProjects()
        XCTAssertEqual(quick.draft.projectID, "p1", "With one project it is chosen")
        XCTAssertFalse(quick.canSend)
        quick.draft.title = "Remember to check audio"
        XCTAssertTrue(quick.canSend)
        await quick.send()
        XCTAssertEqual(quick.state, .captured(key: "ONLY-1", taskID: "t9", projectID: "p1"))
    }

    func testClipboardImageIsSavedAsAPrivatePNG() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("checklist-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4)); image.lockFocus(); NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4)); image.unlockFocus()
        pasteboard.clearContents(); pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        XCTAssertTrue(QuickCaptureModel.clipboardHasImage(pasteboard))
        let quick = model { _, _ in [:] }
        XCTAssertTrue(quick.attachClipboardImage(pasteboard))
        let file = try XCTUnwrap(quick.draft.files.first)
        XCTAssertTrue(file.ownedStaging); XCTAssertEqual(URL(fileURLWithPath: file.path).pathExtension, "png")
        quick.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Removing a staged clipboard image deletes its private copy")
    }

    func testShortcutNeedsAModifierAndShowsItsKeys() {
        XCTAssertEqual(QuickCaptureShortcut.standard.display, "⌃⌥⌘N")
        XCTAssertNil(QuickCaptureShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [.shift], characters: "k"), "Shift alone would take ordinary typing")
        let chosen = QuickCaptureShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift], characters: "k")
        XCTAssertEqual(chosen?.display, "⇧⌘K")
        let defaults = preferences!
        XCTAssertEqual(QuickCaptureShortcut.load(defaults), .standard, "The shortcut is on by default")
        QuickCaptureShortcut.save(chosen, defaults); XCTAssertEqual(QuickCaptureShortcut.load(defaults), chosen)
        QuickCaptureShortcut.save(nil, defaults); XCTAssertNil(QuickCaptureShortcut.load(defaults), "The owner can turn it off")
    }

    func testStatusItemFollowsTheSettingAndRefreshesClipboardAvailability() throws {
        _ = NSApplication.shared
        let defaults = preferences!
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("checklist-menu-test-" + UUID().uuidString))
        let controller = QuickCaptureController(model: model { _, _ in [:] }, pasteboard: pasteboard)
        defer {
            defaults.set(false, forKey: QuickCaptureSettings.menuBarKey)
            controller.updateMenuBarItem(defaults)
            pasteboard.releaseGlobally()
        }
        pasteboard.clearContents()
        controller.updateMenuBarItem(defaults)
        let item = try XCTUnwrap(controller.statusItem, "The menu bar item is shown by default")
        let menu = try XCTUnwrap(item.menu)
        XCTAssertTrue(menu.delegate === controller)
        XCTAssertFalse(menu.autoenablesItems, "AppKit must preserve the clipboard availability check")
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "New Ticket…", "New Ticket from Clipboard Image", "Open Checklist", "Quit Checklist"
        ])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, true, false, true, false])
        for action in menu.items where !action.isSeparatorItem {
            XCTAssertTrue(action.target === controller)
            XCTAssertNotNil(action.action)
        }
        XCTAssertEqual(item.button?.image?.isTemplate, true)
        XCTAssertEqual(item.button?.accessibilityLabel(), "Checklist")
        let clipboardItem = try XCTUnwrap(menu.item(at: 1))
        XCTAssertFalse(clipboardItem.isEnabled, "An empty pasteboard cannot start capture with an image")
        pasteboard.setData(Data([1]), forType: .png)
        // AppKit calls this delegate hook when the menu opens; update() only validates its items.
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertTrue(clipboardItem.isEnabled, "Opening the menu checks the current pasteboard")
        pasteboard.clearContents()
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertFalse(clipboardItem.isEnabled)

        controller.updateMenuBarItem(defaults)
        XCTAssertTrue(controller.statusItem === item, "Repeated updates keep one status item")
        defaults.set(false, forKey: QuickCaptureSettings.menuBarKey)
        controller.updateMenuBarItem(defaults)
        XCTAssertNil(controller.statusItem)
        defaults.set(true, forKey: QuickCaptureSettings.menuBarKey)
        controller.updateMenuBarItem(defaults)
        XCTAssertNotNil(controller.statusItem, "Settings can show the item again")
    }

    func testAppSceneDoesNotUseMenuBarExtra() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/ChecklistApp/App/ChecklistApp.swift"), encoding: .utf8)
        // Build 85's isInserted binding looped the SwiftUI app graph while making the main menu.
        XCTAssertFalse(source.contains("MenuBarExtra"), "Keep the menu bar item outside the SwiftUI scene graph")
    }

    private func key(_ code: Int, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: repeatKey, keyCode: UInt16(code)))
    }

    func testPanelHandlesCommandReturnAndEscapeBeforeTheTextEditor() throws {
        _ = NSApplication.shared
        let panel = QuickCapturePanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let editor = NSTextView()
        panel.contentView = editor
        panel.makeFirstResponder(editor)
        var submitted = 0, closed = 0
        panel.submitDraft = { submitted += 1 }
        panel.closeCapture = { closed += 1 }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(kVK_Return, flags: .command)))
        XCTAssertEqual(submitted, 1)
        // The nonactivating route can deliver a keyDown directly, bypassing key equivalents.
        panel.sendEvent(try key(kVK_Return, flags: .command))
        XCTAssertEqual(submitted, 2)
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(kVK_ANSI_KeypadEnter, flags: [.command, .numericPad])))
        XCTAssertEqual(submitted, 3)
        panel.sendEvent(try key(kVK_Escape))
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(kVK_Escape)))
        XCTAssertEqual(closed, 2)
        XCTAssertEqual(editor.string, "", "Panel commands must not insert text in the focused editor")
    }

    func testPanelLeavesOrdinaryTypingAndOtherModifiedKeysAloneAndConsumesRepeats() throws {
        _ = NSApplication.shared
        let panel = QuickCapturePanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var actions = 0
        panel.submitDraft = { actions += 1 }
        panel.closeCapture = { actions += 1 }
        let untouched: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_Return, []), (kVK_Return, .shift), (kVK_Return, [.command, .shift]),
            (kVK_Return, [.command, .option]), (kVK_Return, .control),
            (kVK_Escape, .command), (kVK_ANSI_N, .command)
        ]
        for (code, flags) in untouched {
            XCTAssertFalse(panel.handleCaptureKey(try key(code, flags: flags)))
        }
        XCTAssertFalse(panel.handleCaptureKey(try key(kVK_Return, flags: .command, type: .keyUp)))
        XCTAssertTrue(panel.handleCaptureKey(try key(kVK_Return, flags: [.command, .capsLock], repeatKey: true)))
        XCTAssertTrue(panel.handleCaptureKey(try key(kVK_Escape, repeatKey: true)))
        XCTAssertEqual(actions, 0)
    }

    func testSharedSubmitActionRequiresAValidDraftAndDoesNotSendAgainWhileSending() async {
        let started = expectation(description: "Create started")
        let finished = expectation(description: "Create returned")
        var resume: CheckedContinuation<Void, Never>?
        var creates = 0
        let quick = model { method, _ in
            XCTAssertEqual(method, "task_create")
            creates += 1
            await withCheckedContinuation { resume = $0; started.fulfill() }
            finished.fulfill()
            return ["id": "t1", "key": "P-1"]
        }
        let controller = QuickCaptureController(model: quick)
        controller.submitDraft()
        quick.draft.title = "   "
        quick.draft.projectID = "p1"
        controller.submitDraft()
        quick.draft.title = "A valid title"
        quick.draft.projectID = ""
        controller.submitDraft()
        XCTAssertEqual(creates, 0)
        quick.draft.projectID = "p1"
        controller.submitDraft()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(quick.state, .sending)
        controller.submitDraft()
        resume?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(creates, 1)
    }
}
