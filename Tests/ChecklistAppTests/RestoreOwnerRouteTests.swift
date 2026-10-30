import ChecklistAXTestSupport
import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

/// CL-370: the owner's restore route in the real Settings panel, through the
/// real store and long-command wait, against a mock service. Synthetic data only.
@MainActor final class RestoreOwnerRouteTests: XCTestCase {
    @MainActor private final class Service {
        let previewOperation = UUID().uuidString, previewCommand = UUID().uuidString
        let createOperation = UUID().uuidString
        var createCommand = ""
        var previewDone = false, createDone = false
        var previewError: [String:Any]?
        var calls: [String] = []
        func reply(_ method: String,_ params: [String:Any]) -> [String:Any] {
            calls.append(method)
            switch method {
            case "restore_preview":
                return ["command_id":previewCommand,"command_outcome":"accepted","data":ack(previewOperation,previewCommand,method)]
            case "restore_create":
                createCommand = params["command_id"] as? String ?? ""
                return ["command_id":createCommand,"command_outcome":"accepted","data":ack(createOperation,createCommand,method)]
            case "operation_get":
                if params["operation_id"] as? String == previewOperation {
                    var status = ack(previewOperation,previewCommand,"restore_preview");status["state"] = "running"
                    if previewDone {
                        if let previewError {status["state"] = "failed";status["error"] = previewError}
                        else {status["state"] = "succeeded";status["result"] = ["data":Self.preview]}
                    }
                    return ["data":status]
                }
                var status = ack(createOperation,createCommand,"restore_create");status["state"] = "running"
                if createDone {status["state"] = "succeeded";status["result"] = ["command_id":createCommand,"data":["path":"/synthetic/restored-copy"]]}
                return ["data":status]
            default: return ["data":["synthetic":true]]
            }
        }
        private func ack(_ operation: String,_ command: String,_ method: String) -> [String:Any] {
            ["operation_id":operation,"command_id":command,"method":method,"state":"queued","status_method":"operation_get","created_at":"2026-10-30T00:00:00Z"]
        }
        static let preview: [String:Any] = ["path":"/synthetic/backup","manifest_sha256":"synthetic-digest","project_count":1,"managed_files":0,"projects":[["id":"p","name":"Synthetic"]]]
    }
    @MainActor private struct Route {
        let service: Service, store: ChecklistStore, window: NSWindow, panel: NSWindow, presentation: SettingsModalPresentation
        func close() {
            store.stopWindowReads()
            if let sheet = panel.attachedSheet {panel.endSheet(sheet)}
            presentation.dismiss();window.contentView = nil;window.close()
        }
    }
    private struct Workspace: View {
        @ObservedObject var presentation: SettingsModalPresentation
        let store: ChecklistStore
        var body: some View {
            Color.clear.frame(width:1100,height:1200).background(SettingsModalAnchor(presentation:presentation,content:{
                AnyView(StorageSettingsView(chooseBackup:{$0(URL(fileURLWithPath:"/synthetic/backup"))}).environmentObject(store))
            }))
        }
    }
    private func route(_ label: String,_ service: Service = Service()) async throws -> Route {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-route-" + UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:isolatedDefaults(label).preferences,restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:RestoreRouteAlertSink()),requestTransport:{method,params in fixtureReply(service.reply(method,params))},
            pendingCommandPersistence:.init(read:{_ in nil},save:{_,_ in},remove:{_ in}))
        store.queuedCommandPause = 1_000_000
        store.connected = true;store.data = ["service":["store_incarnation":"synthetic-store"]]
        let restoreAX = AXProbe.enableEnhancedUserInterface()
        addTeardownBlock {await MainActor.run {restoreAX()}}
        let presentation = SettingsModalPresentation()
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:1200),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist restore route (offscreen)";window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:Workspace(presentation:presentation,store:store))
        window.orderFront(nil)
        try await until {presentation.isPresented || {presentation.present();return presentation.isPresented}()}
        let panel = try XCTUnwrap(window.attachedSheet)
        dumpRoot = panel.contentView
        try await until {AXProbe.button(panel.contentView!,"Preview backup restore…") != nil}
        return Route(service:service,store:store,window:window,panel:panel,presentation:presentation)
    }
    private var dumpRoot: NSView?
    /// A bounded wait whose failure names the caller's line and what accessibility shows.
    private func until(file: StaticString = #filePath,line: UInt = #line,_ predicate: () -> Bool) async throws {
        for _ in 0..<6000 {if predicate() {return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Did not settle. Accessibility text: \(dumpRoot.map {String(AXProbe.text($0).prefix(1500))} ?? "none")",file:file,line:line)
        throw CancellationError()
    }
    private func press(_ label: String,_ root: NSView) throws {AXProbe.press(try XCTUnwrap(AXProbe.button(root,label),"\(label) is absent"))}

    func testSuccessfulPreviewShowsRestoreActionInTheSettingsPanel() async throws {
        let route = try await route("RestorePlain");defer {route.close()}
        try press("Preview backup restore…",route.panel.contentView!)
        try await until {route.service.calls.contains("operation_get")}
        route.service.previewDone = true
        try await until {route.panel.attachedSheet != nil}
        XCTAssertNotNil(AXProbe.button(route.panel.attachedSheet!.contentView!,"Prepare restored copy"))
    }

    /// Discarded screen content leaves the store's identity blank for a while. That
    /// says nothing about which store is connected, so the preview must still end visibly.
    func testPreviewSurvivesBlankStoreIdentityWhileItRuns() async throws {
        let route = try await route("RestoreBlank");defer {route.close()}
        try press("Preview backup restore…",route.panel.contentView!)
        try await until {route.service.calls.contains("operation_get")}
        route.store.data = [:]
        try await Task.sleep(nanoseconds:100_000_000)
        route.store.data = ["service":["store_incarnation":"synthetic-store"]]
        try await Task.sleep(nanoseconds:100_000_000)
        route.service.previewDone = true
        try await until {route.panel.attachedSheet != nil}
        XCTAssertNotNil(AXProbe.button(route.panel.attachedSheet!.contentView!,"Prepare restored copy"))
    }

    /// The operation ID and state stay readable through accessibility while it runs,
    /// and the whole route ends with the restored path.
    func testOperationIDAndStateAreVisibleFromAcceptanceThroughTheRestoredCopy() async throws {
        let route = try await route("RestoreObserved");defer {route.close()}
        let content = route.panel.contentView!, service = route.service
        try press("Preview backup restore…",content)
        try await until {AXProbe.text(content).contains(service.previewOperation)}
        try await until {AXProbe.text(content).contains("Preview backup restore: Running.")}
        XCTAssertTrue(AXProbe.text(content).contains("Accepted in "))
        service.previewDone = true
        try await until {route.panel.attachedSheet != nil}
        try await until {AXProbe.text(content).contains("Preview backup restore: Succeeded.")}
        let sheet = try XCTUnwrap(route.panel.attachedSheet)
        try await until {AXProbe.button(sheet.contentView!,"Prepare restored copy") != nil}
        try press("Prepare restored copy",sheet.contentView!)
        try await until {AXProbe.text(content).contains(service.createOperation)}
        try await until {AXProbe.text(content).contains("Prepare restored copy: Running.")}
        XCTAssertNil(AXProbe.button(content,"Review verified backup…"),"A spent preview offers no second restore")
        XCTAssertEqual(service.calls.filter {$0 == "restore_create"}.count,1)
        service.createDone = true
        try await until {AXProbe.text(content).contains("Prepare restored copy: Succeeded.")}
        try await until {AXProbe.text(content).contains("Restored copy prepared at /synthetic/restored-copy.")}
    }

    func testClosingTheSheetKeepsTheRestoreActionInSettings() async throws {
        let route = try await route("RestoreReview");defer {route.close()}
        let content = route.panel.contentView!
        try press("Preview backup restore…",content)
        route.service.previewDone = true
        try await until {route.panel.attachedSheet != nil}
        let sheet = try XCTUnwrap(route.panel.attachedSheet)
        try await until {AXProbe.button(sheet.contentView!,"Cancel") != nil}
        try press("Cancel",sheet.contentView!)
        try await until {route.panel.attachedSheet == nil}
        try await until {AXProbe.button(content,"Review verified backup…") != nil}
        try press("Review verified backup…",content)
        try await until {route.panel.attachedSheet != nil}
    }

    func testFailedPreviewNamesTheReasonAndOffersNoAction() async throws {
        let service = Service();service.previewError = ["code":"RESTORE_INVALID_BACKUP","message":"Synthetic backup failed verification."]
        let route = try await route("RestoreFailed",service);defer {route.close()}
        let content = route.panel.contentView!
        try press("Preview backup restore…",content)
        service.previewDone = true
        try await until {AXProbe.text(content).contains("Synthetic backup failed verification.")}
        try await until {AXProbe.text(content).contains("Failed (RESTORE_INVALID_BACKUP)")}
        XCTAssertNil(route.panel.attachedSheet);XCTAssertNil(AXProbe.button(content,"Review verified backup…"))
    }

    func testADifferentStoreDuringPreviewNamesWhyItEnded() async throws {
        let route = try await route("RestoreOtherStore");defer {route.close()}
        let content = route.panel.contentView!
        try press("Preview backup restore…",content)
        try await until {route.service.calls.contains("operation_get")}
        route.store.data = ["service":["store_incarnation":"other-store"]]
        try await until {AXProbe.text(content).contains(StorageSettingsObservation.storeChangedText)}
        route.service.previewDone = true
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertNil(route.panel.attachedSheet)
    }

    func testLogKeepsFirstAcceptanceTimeFinalStateAndABoundedList() {
        let log = LongOperationLog()
        func receipt(_ id: String,_ state: String,_ code: String? = nil) -> LongOperationReceipt {LongOperationReceipt(operationID:id,commandID:"c",method:"backup_create",state:state,errorCode:code)}
        log.observe(receipt("a","queued"),acceptedAfter:0.25)
        log.observe(receipt("a","running"),acceptedAfter:9)
        XCTAssertEqual(log.operations[0].state,"running");XCTAssertEqual(log.operations[0].acceptedAfter,0.25)
        log.observe(receipt("a","succeeded"),acceptedAfter:9);log.observe(receipt("a","running"),acceptedAfter:9);log.stoppedWatching("a")
        XCTAssertEqual(log.operations[0].state,"succeeded")
        log.observe(receipt("b","running"),acceptedAfter:0.5);log.stoppedWatching("b")
        XCTAssertEqual(log.operations[0].id,"b");XCTAssertTrue(log.operations[0].stateText.hasPrefix("State not known"))
        for index in 0..<20 {log.observe(receipt("n\(index)","queued"),acceptedAfter:0)}
        XCTAssertEqual(log.operations.count,LongOperationLog.limit);XCTAssertEqual(log.operations[0].id,"n19")
    }

    func testStoreLogRecordsAcceptanceTimeAndMarksAnUnreadableOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-route-" + UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let service = Service();var failReads = false
        let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:isolatedDefaults("RestoreUnreadable").preferences,restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:RestoreRouteAlertSink()),requestTransport:{method,params in
                if method == "operation_get",failReads {throw NSError(domain:"synthetic",code:1)}
                return fixtureReply(service.reply(method,params))},
            pendingCommandPersistence:.init(read:{_ in nil},save:{_,_ in},remove:{_ in}))
        defer {store.stopWindowReads()}
        store.queuedCommandPause = 1_000_000
        var clock: TimeInterval = 100;store.liveNow = {clock}
        let read = Task {try await store.request("restore_preview",["path":"/synthetic/backup"])}
        try await until {service.calls.contains("restore_preview")}
        clock = 100.5
        failReads = true
        do {_ = try await read.value;XCTFail("An unreadable operation cannot complete")} catch {}
        let row = try XCTUnwrap(store.longOperations.operations.first)
        XCTAssertEqual(row.operationID,service.previewOperation);XCTAssertEqual(row.method,"restore_preview")
        XCTAssertEqual(row.state,ObservedLongOperation.unknownState)
    }

    func testReplyArrivingWhileIdentityIsBlankStillShowsTheAction() async throws {
        let route = try await route("RestoreBlankReply");defer {route.close()}
        try press("Preview backup restore…",route.panel.contentView!)
        try await until {route.service.calls.contains("operation_get")}
        route.store.data = [:]
        route.service.previewDone = true
        try await until {route.panel.attachedSheet != nil}
    }
}

@MainActor private final class RestoreRouteAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Read cancellation must not alert") }
    func remove(_ identifiers: [String]) {}
}
