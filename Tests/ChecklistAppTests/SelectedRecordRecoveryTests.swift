import ChecklistTestSupport
import XCTest
@testable import ChecklistApp
@testable import ChecklistCore
import ChecklistIPC

@MainActor final class SelectedRecordRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL, preferences: UserDefaults, router: CommandRouter
        let owner = Caller(role:"owner",installation:"selected-record-recovery",projectIDs:[])
        var project = "", task = "", other = ""
        var calls: [(String,[String:Any])] = []
        var resets: [String:Int] = [:]
        var failures: [String:Error] = [:]
        var transform: ((String,inout [String:Any])->Void)?
        var hold: String?
        var held: CheckedContinuation<[String:Any],Error>?
        var heldReply: [String:Any]?
        var heldError: Error?
        init(_ defaults: IsolatedDefaults, archived: Bool = false, manifests: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Checklist-CL174-"+UUID().uuidString)
            preferences = defaults.preferences;router = try TestStore.router(root:root)
            project = try command("project_create",["name":"Recovery","key_prefix":"R","root_path":root.path])["id"] as! String
            task = try command("task_create",["project_id":project,"title":"Selected"])["id"] as! String
            other = try command("task_create",["project_id":project,"title":"Other"])["id"] as! String
            // Synthetic fixture history/visibility; all recovery invalidation below
            // uses an actual unrelated task_edit through the router.
            try router.dbQueue.writeWithoutTransaction { db in
                try router.withValidatedDomainTransaction(db) {
                    if archived {var row = try router.record(db,task,type:"task");row["archived"] = true;try router.save(db,row,type:"task")}
                    for i in 0..<manifests {try router.save(db,["id":"target-\(i)","project_id":project,"task_id":task,"revision":1,"evidence":[:]],type:"manifest")}
                    return .commit
                }
            }
            preferences.set(Page.tasks.rawValue,forKey:"lastPage");preferences.set(project,forKey:"lastProject")
        }
        func command(_ method: String,_ values: [String:Any]) throws -> [String:Any] {
            var p = values;if !CommandRouter.readMethods.contains(method) {p["command_id"] = UUID().uuidString}
            return try router.handle(method:method,params:appFixtureTaskInput(router,method:method,input:p),caller:owner)["data"] as! [String:Any]
        }
        func mutateOther() throws {
            let row = try command("task_get",["project_id":project,"task_id":other])
            _ = try command("task_edit",["project_id":project,"task_id":other,"expected_revision":row["revision"]!,"patch":["title":"Changed unrelated ticket","brief":"Synthetic outcome"]])
        }
        func transport(_ method: String,_ p: [String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()}
            calls.append((method,p))
            let level = p["detail_level"] as? String ?? ""
            if let failure = failures.removeValue(forKey:level) {throw failure}
            if resets[level,default:0] > 0 {resets[level]! -= 1;throw ChecklistError("CURSOR_RESET","Synthetic repeated reset")}
            var response: [String:Any]
            do {response = try command(method,p)}
            catch let error as CoreError {
                let failure = ChecklistError(error.code,error.message)
                if hold == level {hold = nil;heldError = failure;return try await withCheckedThrowingContinuation {held = $0}}
                throw failure
            }
            transform?(level,&response)
            let reply = ["data":response]
            if hold == level {hold = nil;heldReply = reply;return try await withCheckedThrowingContinuation {held = $0}}
            return reply
        }
        func release(_ error: Error? = nil) {
            guard let held else {return};self.held = nil
            if let error = error ?? heldError {held.resume(throwing:error)} else {held.resume(returning:heldReply!)}
            heldReply = nil;heldError = nil
        }
        func store(qualificationFaults: QualificationFaults? = nil) -> ChecklistStore {
            ChecklistStore(draftJournal:LocalDraftJournal(directory:root.appendingPathComponent("drafts")),preferences:preferences,restorePendingCommand:false,
                           desktopAlerts:DesktopAlertCoordinator(sink:RecoveryAlertSink()),requestTransport:{[self] in try await transport($0,$1)},navigationMemory:DetailItemNavigationMemory(),
                           pendingCommandPersistence:PendingCommandPersistence(read:{_ in nil},save:{_,_ in},remove:{_ in}),qualificationFaults:qualificationFaults)
        }
        func reads(_ level: String) -> [[String:Any]] {calls.filter {$0.0 == "task_context" && $0.1["detail_level"] as? String == level}.map(\.1)}
        func draftBytes() throws -> [String:Data] {
            let path = root.appendingPathComponent("drafts")
            return try Dictionary(uniqueKeysWithValues:FileManager.default.contentsOfDirectory(at:path,includingPropertiesForKeys:nil).map {($0.lastPathComponent,try Data(contentsOf:$0))})
        }
        func cleanup() {release();try? FileManager.default.removeItem(at:root)}
    }
    private func until(_ predicate: ()->Bool,file: StaticString = #filePath,line: UInt = #line) async throws {
        for _ in 0..<1000 {if predicate() {return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Bounded recovery did not settle",file:file,line:line);throw NSError(domain:"RecoveryTimeout",code:1)
    }
    private func select(_ store: ChecklistStore,_ f: Fixture) async throws {
        try await until {store.connected && !store.ticketPageLoading}
        store.open(.task(f.task));try await until {store.selectedTicketCurrent(f.task)}
        f.calls = []
    }
    func testRealUnrelatedMutationRecoversEachRouteInBothVisibilityStatesAndPreservesDraftBytes() async throws {
        for archived in [false,true] {for history in [false,true] {
            let f = try Fixture(isolatedDefaults("CL174-real"),archived:archived,manifests:51);defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f)
            let task = try XCTUnwrap(store.selectedTask(f.task))
            XCTAssertEqual(task.bool("archived"),archived)
            store.saveNote(f.task,text:"Unsent é\nexact bytes ");store.refreshNoteDestination(f.task)
            store.saveTaskEdit(f.task,draft:TaskEditDraft(title:"Edited é",brief:" draft\n",baseRevision:task.integer("revision"),editing:true,hasChanges:true,scope:store.draftScope(project:f.project,entity:f.task)))
            var answer = AnswerDraft(revision:7);answer.values = ["answer":"unsent\n é"];answer.targetIdentity = "target-binding"
            store.saveAnswer("question#part",draft:answer)
            let bytes = try f.draftBytes(),binding = store.noteDraftNeedsReconciliation(f.task)
            var cursor: String?
            if history {
                store.readRecordHistory(task,family:"manifest");try await until {!store.recordHistoryLoading}
                cursor = try XCTUnwrap(store.recordHistoryNext)
                store.readRecordHistory(task,family:"manifest",cursor:cursor);try await until {!store.recordHistoryLoading}
                XCTAssertEqual(store.recordHistoryRows.count,1)
            }
            f.calls = [];try f.mutateOther()
            if history {store.readRecordHistory(task,family:"manifest",cursor:cursor)} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            let level = history ? "ui_history" : "ui_records",reads = f.reads(level)
            XCTAssertEqual(reads.count,2);XCTAssertEqual(f.reads("ui").count,1)
            XCTAssertNotEqual(reads.first?["selected_context_cursor"] as? String,reads.last?["selected_context_cursor"] as? String)
            XCTAssertNil(reads.last?["cursor"])
            XCTAssertFalse(f.calls.contains {CommandReply.expectsMutation($0.0)})
            XCTAssertFalse(f.calls.contains {$0.0 == "changes_wait"},"Recovery does not replace the subscription interval")
            XCTAssertEqual(try f.draftBytes(),bytes);XCTAssertEqual(store.noteDraftNeedsReconciliation(f.task),binding)
            if history {
                XCTAssertNil(store.recordHistoryError);XCTAssertEqual(store.recordHistoryRows.count,50)
                XCTAssertEqual(store.recordHistoryRows.first?.id,"target-50");XCTAssertNil(store.recordHistoryPrevious)
                XCTAssertTrue(store.recordHistoryNotice?.contains("restarted at the latest records") == true)
                XCTAssertTrue(reads.allSatisfy {$0["records_family"] as? String == "manifest"})
            } else {XCTAssertNil(store.selectedRecordsError);XCTAssertTrue(store.selectedRecordsCurrent)}
        }}
    }
    func testConcurrentRecordAndHistoryRecoverySharesOneFreshContext() async throws {
        let f = try Fixture(isolatedDefaults("CL174-concurrent"));defer {f.cleanup()}
        let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
        try await select(store,f);try f.mutateOther();f.hold = "ui"
        store.loadFullSelectedRecord(f.task);try await until {f.held != nil}
        store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")
        try await until {f.reads("ui_history").count == 1}
        f.release();try await until {!store.selectedRecordsLoading && !store.recordHistoryLoading}
        XCTAssertEqual(f.reads("ui").count,1);XCTAssertEqual(f.reads("ui_records").count,2);XCTAssertEqual(f.reads("ui_history").count,2)
        XCTAssertTrue(store.selectedRecordsCurrent);XCTAssertNil(store.recordHistoryError)
    }
    func testDelayedOldHistoryResetPreservesAlreadyRecoveredCurrentAuthority() async throws {
        let f = try Fixture(isolatedDefaults("CL174-delayed-reset"));defer {f.cleanup()}
        let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
        try await select(store,f);try f.mutateOther();f.hold = "ui_history"
        store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")
        try await until {f.held != nil}
        store.loadFullSelectedRecord(f.task);try await until {store.selectedRecordsCurrent}
        f.release();try await until {!store.recordHistoryLoading}
        XCTAssertTrue(store.selectedRecordsCurrent);XCTAssertNil(store.recordHistoryError)
        XCTAssertEqual(f.reads("ui").count,1);XCTAssertEqual(f.reads("ui_records").count,2);XCTAssertEqual(f.reads("ui_history").count,2)
    }
    func testSecondResetAndFailedFreshContextAreBoundedForBothRoutes() async throws {
        for history in [false,true] {for freshFailure in [false,true] {
            let f = try Fixture(isolatedDefaults("CL174-bounded"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f)
            store.loadFullSelectedRecord(f.task);try await until {store.selectedRecordsCurrent};f.calls = []
            let level = history ? "ui_history" : "ui_records"
            if freshFailure {f.resets[level] = 1;f.failures["ui"] = ChecklistError("FORBIDDEN","Fresh context permission refused")}
            else {f.resets[level] = 2}
            if history {store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            let error = history ? store.recordHistoryError : store.selectedRecordsError
            XCTAssertTrue(error?.contains(freshFailure ? "Fresh context permission refused" : "context changed again") == true)
            XCTAssertEqual(f.reads("ui").count,1);XCTAssertEqual(f.reads(level).count,freshFailure ? 1 : 2)
            XCTAssertFalse(store.selectedRecordsCurrent)
        }}
    }
    func testSlotPreferenceFaultsReachTerminalRecoveryOnBothRoutesThenDisarm() async throws {
        for history in [false,true] {for kind in ["cursor_reset_twice","fresh_context_fail"] {
            let f = try Fixture(isolatedDefaults("CL205-client-boundary"));defer {f.cleanup()}
            var preference: [String:Any] = [:], logs: [String] = []
            let faults = QualificationFaults(instance:try ChecklistInstance(slotValue:1),read:{ domain in
                XCTAssertEqual(domain,"org.checklist.app.test1");return preference
            },write:{ _,value in preference = value },log:{logs.append($0)})
            let store = f.store(qualificationFaults:faults),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads()}
            try await select(store,f)
            store.saveNote(f.task,text:"CL205 unsent draft");let bytes = try f.draftBytes()
            preference = ["selected_records":kind,"remaining":2];faults.refresh()
            XCTAssertTrue(faults.isArmed)
            let task = try XCTUnwrap(store.selectedTask(f.task))
            if history {store.readRecordHistory(task,family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            let error = history ? store.recordHistoryError : store.selectedRecordsError
            XCTAssertTrue(error?.contains(kind == "fresh_context_fail" ? "TEST FAULT: selected-ticket fresh context read failed" : "context changed again") == true)
            XCTAssertTrue(error?.contains("Your draft is kept") == true)
            XCTAssertFalse(store.selectedRecordsCurrent);XCTAssertTrue(store.connected)
            XCTAssertEqual(try f.draftBytes(),bytes)
            XCTAssertEqual(logs.count,2);XCTAssertTrue(logs[0].contains("remaining=1"));XCTAssertTrue(logs[1].contains("remaining=0"))
            XCTAssertEqual(preference["remaining"] as? Int,0);XCTAssertFalse(faults.isArmed)
            XCTAssertEqual(f.reads("ui_records").count,0);XCTAssertEqual(f.reads("ui_history").count,0)
            XCTAssertEqual(f.reads("ui").count,kind == "fresh_context_fail" ? 0 : 1)
            f.calls = []
            if history {store.readRecordHistory(task,family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            XCTAssertNil(history ? store.recordHistoryError : store.selectedRecordsError)
            XCTAssertEqual(f.reads(history ? "ui_history" : "ui_records").count,1)
            XCTAssertEqual(logs.count,2)
        }}
    }
    func testOtherFailuresNeverRebaseAndRemainSpecific() async throws {
        for history in [false,true] {for code in ["FORBIDDEN","OUTCOME_UNKNOWN"] {
            let f = try Fixture(isolatedDefaults("CL174-refusal"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f);let level = history ? "ui_history" : "ui_records"
            f.failures[level] = ChecklistError(code,"Permission denied specifically")
            if history {store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            XCTAssertEqual(f.reads(level).count,1);XCTAssertEqual(f.reads("ui").count,0)
            let error = history ? store.recordHistoryError : store.selectedRecordsError
            XCTAssertTrue(error?.contains(code == "FORBIDDEN" ? "Permission denied specifically" : "in time") == true)
        }}
    }
    func testMalformedIdentityAndIncompleteRecordsFailClosedAfterRetry() async throws {
        for rebase in [false,true] {for field in ["task_id","project_id","task_revision","service","collections","complete"] {
            let f = try Fixture(isolatedDefaults("CL174-invalid"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f);if rebase {try f.mutateOther()}
            f.transform = {level,response in if level == "ui_records" {
                switch field {case "complete":response[field] = false
                case "task_revision":response[field] = 0
                case "service":response[field] = ["store_incarnation":"foreign"]
                case "collections":response[field] = [:]
                default:response[field] = "foreign"}
            }}
            store.loadFullSelectedRecord(f.task);try await until {!store.selectedRecordsLoading}
            XCTAssertNotNil(store.selectedRecordsError);XCTAssertFalse(store.selectedRecordsCurrent)
            XCTAssertFalse(store.fullSelectedRecordLoaded(f.task));XCTAssertEqual(f.reads("ui").count,rebase ? 1 : 0);XCTAssertEqual(f.reads("ui_records").count,rebase ? 2 : 1)
        }}
    }
    func testMalformedFreshContextAndHistoryIdentityNeverInstall() async throws {
        for malformedHead in [false,true] {
            let f = try Fixture(isolatedDefaults("CL174-history-identity"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f);if malformedHead {try f.mutateOther()}
            f.transform = {level,response in
                if malformedHead && level == "ui" {var task = response["task"] as! [String:Any];task["id"] = "foreign";response["task"] = task}
                if !malformedHead && level == "ui_history" {response["record_id"] = "foreign"}
            }
            store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")
            try await until {!store.recordHistoryLoading}
            XCTAssertNotNil(store.recordHistoryError);XCTAssertTrue(store.recordHistoryRows.isEmpty)
            XCTAssertEqual(f.reads("ui").count,malformedHead ? 1 : 0);XCTAssertEqual(f.reads("ui_history").count,1)
            XCTAssertEqual(store.selectedTask(f.task)?.id,f.task)
        }
    }
    func testObsoleteRecoveryCannotInstallAfterSelectionProjectStoreOrWindowChange() async throws {
        try await assertObsoleteRecoveryCannotInstall(after: "selection")
    }
    func testObsoleteRecoveryCannotInstallAfterProjectChange() async throws {
        try await assertObsoleteRecoveryCannotInstall(after: "project")
    }
    func testObsoleteRecoveryCannotInstallAfterStoreChange() async throws {
        try await assertObsoleteRecoveryCannotInstall(after: "store")
    }
    func testObsoleteRecoveryCannotInstallAfterWindowChange() async throws {
        try await assertObsoleteRecoveryCannotInstall(after: "window")
    }
    private func assertObsoleteRecoveryCannotInstall(after change: String) async throws {
        for history in [false,true] {for lateFailure in [false,true] {do {
            let f = try Fixture(isolatedDefaults("CL174-obsolete"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f);try f.mutateOther();f.hold = "ui"
            if history {store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {f.held != nil}
            switch change {
            case "selection":store.open(.task(f.other));try await until {store.selectedTicketCurrent(f.other)}
            case "project":store.projectID = "other-project";store.projectID = f.project
            case "store":
                f.transform = {_,response in
                    if var page = response["tickets_page"] as? [String:Any] {
                        var service = page["service"] as! [String:Any];service["store_incarnation"] = "replacement-store";page["service"] = service;response["tickets_page"] = page
                    } else if var service = response["service"] as? [String:Any] {service["store_incarnation"] = "replacement-store";response["service"] = service}
                }
                store.retryTicketPage();try await until {store.storeIncarnation == "replacement-store"}
            default:store.stopWindowReads()
            }
            let count = f.reads(history ? "ui_history" : "ui_records").count
            f.release(lateFailure ? ChecklistError("FORBIDDEN","Obsolete held refusal") : nil);try await Task.sleep(nanoseconds:30_000_000)
            XCTAssertEqual(f.reads(history ? "ui_history" : "ui_records").count,count)
            XCTAssertNil(store.recordHistoryError);XCTAssertNil(store.selectedRecordsError)
            XCTAssertFalse(store.fullSelectedRecordLoaded(f.task))
            if change == "selection" {XCTAssertTrue(store.selectedTicketCurrent(f.other))}
        }}}
    }
    func testFamilyReplacementAndCanceledOlderReadCannotClearNewLoader() async throws {
        for history in [false,true] {
            let f = try Fixture(isolatedDefaults("CL174-newer"));defer {f.cleanup()}
            let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
            try await select(store,f);try f.mutateOther();f.hold = "ui"
            let task = try XCTUnwrap(store.selectedTask(f.task))
            if history {store.readRecordHistory(task,family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {f.held != nil}
            if history {store.readRecordHistory(task,family:"attachment")} else {store.loadFullSelectedRecord(f.task)}
            try await until {f.reads(history ? "ui_history" : "ui_records").count == 2}
            f.hold = history ? "ui_history" : "ui_records"
            f.release();try await until {f.held != nil}
            // The superseded consumer has resumed from the shared head read;
            // its cancellation cannot retire the held replacement's loader.
            try await Task.sleep(nanoseconds:20_000_000)
            XCTAssertTrue(history ? store.recordHistoryLoading : store.selectedRecordsLoading)
            f.release();try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            XCTAssertEqual(f.reads("ui").count,1);XCTAssertNil(store.recordHistoryError);XCTAssertNil(store.selectedRecordsError)
            if history {XCTAssertEqual(f.reads("ui_history").last?["records_family"] as? String,"attachment");XCTAssertTrue(store.recordHistoryRows.isEmpty)}
            else {XCTAssertTrue(store.selectedRecordsCurrent)}
        }
    }
    func testCancellationIsNeutralAndSuccessfulReadsUseOneRequest() async throws {
        let f = try Fixture(isolatedDefaults("CL174-ordinary"));defer {f.cleanup()}
        let store = f.store(),live = Task {await store.startLiveUpdates()};defer {live.cancel();store.stopWindowReads()}
        try await select(store,f)
        store.loadFullSelectedRecord(f.task);try await until {!store.selectedRecordsLoading}
        store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest");try await until {!store.recordHistoryLoading}
        XCTAssertEqual(f.reads("ui_records").count,1);XCTAssertEqual(f.reads("ui_history").count,1);XCTAssertEqual(f.reads("ui").count,0)
        for history in [false,true] {
            try f.mutateOther();f.failures["ui"] = CancellationError()
            if history {store.readRecordHistory(try XCTUnwrap(store.selectedTask(f.task)),family:"manifest")} else {store.loadFullSelectedRecord(f.task)}
            try await until {history ? !store.recordHistoryLoading : !store.selectedRecordsLoading}
            XCTAssertNil(store.recordHistoryError);XCTAssertNil(store.selectedRecordsError);XCTAssertTrue(store.connected);XCTAssertNil(store.lastServiceFailure)
        }
    }
}

@MainActor private final class RecoveryAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert: DesktopAlert) async throws {XCTFail("Unexpected recovery alert")}
    func remove(_ identifiers: [String]) {}
}
