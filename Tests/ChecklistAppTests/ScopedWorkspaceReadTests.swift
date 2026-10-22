import XCTest
@testable import ChecklistApp
@testable import ChecklistCore
import ChecklistIPC

@MainActor final class ScopedWorkspaceReadTests:XCTestCase {
    @MainActor private final class Fixture {
        let root:URL,preferences:UserDefaults,router:CommandRouter
        let owner=Caller(role:"owner",installation:"scoped-app-fixture",projectIDs:[])
        var calls:[(String,[String:Any])]=[]
        var pending:[String:String]=[:]
        var holdSurface:String?
        var held:CheckedContinuation<[String:Any],Error>?
        var heldReply:[String:Any]?
        var loseCreateReply=false
        var resetFirstWait=false
        var continuationFailure:String?
        var waitCursors:[String?]=[]
        var failRead: (method: String, detail: String?)?
        var a="",b="",task=""
        init(defaults: IsolatedDefaults)throws {
            let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
            try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
            root=cache.appendingPathComponent("scoped-app-"+UUID().uuidString)
            preferences=defaults.preferences
            router=try CommandRouter(root:root)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("a"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("b"),withIntermediateDirectories:true)
            func call(_ method:String,_ params:[String:Any])throws->[String:Any] {
                var params=params;params["command_id"]=UUID().uuidString
                return try router.handle(method:method,params:params,caller:owner)["data"] as! [String:Any]
            }
            a=try call("project_create",["name":"A","key_prefix":"A","root_path":root.appendingPathComponent("a").path])["id"] as! String
            b=try call("project_create",["name":"B","key_prefix":"B","root_path":root.appendingPathComponent("b").path])["id"] as! String
            task=try call("task_create",["project_id":a,"title":"Selected"])["id"] as! String
            preferences.set(Page.epics.rawValue,forKey:"lastPage");preferences.set(a,forKey:"lastProject")
        }
        func cleanup() {try? FileManager.default.removeItem(at:root)}
        func command(_ method:String,_ params:[String:Any])throws->[String:Any] {
            var params=params;if !CommandReply.readMethods.contains(method) && params["command_id"] == nil {params["command_id"]=UUID().uuidString}
            return try router.handle(method:method,params:params,caller:owner)
        }
        func transport(_ method:String,_ params:[String:Any]) async throws->[String:Any] {
            if method=="changes_wait" {
                waitCursors.append(params["cursor"] as? String)
                if resetFirstWait {resetFirstWait=false;throw ChecklistError("CURSOR_RESET","Synthetic expired subscription")}
                try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()
            }
            calls.append((method,params))
            if let failure=failRead,method==failure.method,failure.detail == nil || params["detail_level"] as? String==failure.detail {
                failRead=nil
                throw CommandReply.unknown(commandID:nil,reason:"reply_timeout")
            }
            if method=="task_context",params["history_cursor"] != nil,let code=continuationFailure {
                continuationFailure=nil
                throw ChecklistError(code,"Synthetic typed continuation failure")
            }
            let reply=try command(method,params)
            if method=="task_create" && loseCreateReply {loseCreateReply=false;throw CommandReply.unknown(commandID:params["command_id"] as? String,reason:"synthetic_committed_lost_reply")}
            if method=="workspace_page",params["surface"] as? String==holdSurface {
                holdSurface=nil;heldReply=reply
                return try await withCheckedThrowingContinuation {held=$0}
            }
            return reply
        }
        func release() {if let held {self.held=nil;held.resume(returning:heldReply!);heldReply=nil}}
        func store(restore:Bool=false)->ChecklistStore {
            ChecklistStore(draftJournal:LocalDraftJournal(directory:root.appendingPathComponent("drafts")),preferences:preferences,restorePendingCommand:restore,
                           desktopAlerts:DesktopAlertCoordinator(sink:ScopedReadAlertSink()),requestTransport:{[self] method,params in try await transport(method,params)},
                           navigationMemory:DetailItemNavigationMemory(),pendingCommandKey:"synthetic-window",
                           pendingCommandPersistence:PendingCommandPersistence(read:{[self] in pending[$0]},save:{[self] in pending[$1]=$0},remove:{[self] in pending.removeValue(forKey:$0)}))
        }
    }
    private func until(_ predicate:()->Bool,file:StaticString=#filePath,line:UInt=#line)async throws {
        for _ in 0..<600 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Finite asynchronous read did not finish",file:file,line:line)
        throw NSError(domain:"ScopedAppTimeout",code:1)
    }
    private func changes(_ pid:String,families:[String],task:String?=nil)->[String:Any] {
        ["event_cursor":"observed-interval","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":pid,"families":families,"task_ids":task.map{[$0]} ?? [],"all_tasks":task==nil]]]]
    }
    func testAnswerAndDeclineImmediatelyRemoveNeedsYouRowsAndCountsBeforeRefresh() async throws {
        for page in [Page.needsYou,.overview] {
            for result in ["passed","declined"] {
                let f = try Fixture(defaults:isolatedDefaults("ImmediateHumanAnswer")); defer { f.cleanup() }
                f.preferences.set(page.rawValue,forKey:"lastPage")
                let input: [String:Any] = ["project_id":f.a,"task_id":f.task,"title":"Answer this check","questions":[["id":"q","prompt":"Keyboard navigation is on","type":"check"]]]
                let request = Record(values:try f.command("human_request_create",input)["data"] as! [String:Any])
                let initial = result == "passed" ? 1 : 2
                if initial == 2 {
                    let other = try f.command("task_create",["project_id":f.a,"title":"Unrelated question target"])["data"] as! [String:Any]
                    _ = try f.command("human_request_create",["project_id":f.a,"task_id":other["id"]!,"title":"Keep this request","questions":[["id":"q","prompt":"Keep pending"]]])
                }
                let store = f.store(), live = Task { await store.startLiveUpdates() }
                defer { live.cancel(); f.release(); store.stopWindowReads() }
                try await until { store.connected && (page == .needsYou ? store.workspaceTotal == initial : store.overviewObservations["requests"]?.page?.total == initial) }
                store.open(.request(request.id))
                try await until { store.selectedOther?.id == request.id && !store.otherDetailLoading }
                XCTAssertEqual(store.needsCount,initial)
                var draft = AnswerDraft(revision:request.integer("revision"))
                draft.targetIdentity = RequestDraftIdentity.form(request); draft.formRevision = request.integer("form_revision")
                draft.values = ["q":result]
                XCTAssertTrue(RequestDraftIdentity.isComplete(draft,questions:request.records("questions"),fileRequests:[]))
                draft.values["q"] = "not_checked"
                XCTAssertFalse(RequestDraftIdentity.isComplete(draft,questions:request.records("questions"),fileRequests:[]))
                draft.values["q"] = result
                let submission = RequestAnswerSubmission(request:request,action:"answered")
                f.holdSurface = page == .needsYou ? "requests" : "overview"
                var completion: RequestAnswerCompletion?
                let params: [String:Any] = ["project_id":f.a,"request_id":request.id,"expected_revision":request.integer("revision"),"form_identity":draft.targetIdentity,"response":"answered","answers":[["question_id":"q","result":result]]]
                store.run("human_request_answer",params) { reply in
                    completion = submission.reconcile(Record(values:reply),currentRequest:store.requests.first { $0.id == request.id },currentDetail:store.detail,draft:draft)
                }
                try await until { f.held != nil }
                XCTAssertTrue(store.busy,"The refresh is still waiting")
                XCTAssertEqual(completion?.shouldDismiss,true,"The confirmed send reconciles before waiting for refresh")
                XCTAssertEqual(store.selectedOther?.string("state"),"answered")
                let rows = page == .needsYou ? store.workspaceRows : store.overviewObservations["requests"]?.page?.rows ?? []
                XCTAssertFalse(rows.contains { $0.id == request.id })
                XCTAssertEqual(rows.count,initial - 1)
                XCTAssertEqual(store.needsCount,initial - 1,"The sidebar count changes from the committed receipt")
                XCTAssertEqual(DockBadge.label(count:store.needsCount,enabled:true),initial == 1 ? nil : "1","The Dock consumes the same updated count")
                f.release(); try await until { !store.busy }
                XCTAssertEqual(store.needsCount,initial - 1,"The later refresh cannot subtract the same request twice")
            }
        }
    }
    func testReadDeadlinesEndLoadingAndLaterTicketAndRecordReadsRecover()async throws {
        let f=try Fixture(defaults:isolatedDefaults("ScopedAppReadFailure"));defer {f.cleanup()}
        f.preferences.set(Page.tasks.rawValue,forKey:"lastPage")
        let store=f.store(),live=Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads()}
        try await until {store.connected && !store.ticketPageLoading}
        f.failRead=("task_context","ui")
        store.open(.task(f.task))
        try await until {!store.selectedTicketLoading && store.selectedTicketError != nil}
        store.retrySelectedTicket()
        try await until {store.selectedTicketCurrent(f.task)}
        f.failRead=("task_context","ui_records")
        store.loadFullSelectedRecord(f.task)
        try await until {!store.selectedRecordsLoading && store.selectedRecordsError != nil}
        store.loadFullSelectedRecord(f.task)
        try await until {store.selectedRecordsCurrent}
        f.failRead=("task_list",nil)
        await store.refresh()
        XCTAssertFalse(store.ticketPageLoading)
        XCTAssertNotNil(store.ticketPageError)
        await store.refresh()
        XCTAssertFalse(store.ticketPageLoading)
        XCTAssertNil(store.ticketPageError)
    }
    func testForeignCatalogRefreshesVisibleSidebarButForeignTaskDoesNot()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()}
        f.preferences.set(Page.tasks.rawValue,forKey:"lastPage")
        let store=f.store(),live=Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads()}
        try await until {store.connected && !store.ticketPageLoading && f.calls.contains{$0.0=="task_list"}}
        XCTAssertEqual(f.calls.first?.0,"task_list","Prime the actual Tickets catalog, not a workspace fallback")
        XCTAssertEqual(store.projects.first{$0.id==f.b}?.string("name"),"B")
        store.select(.epics,project:f.a)
        try await until {!store.workspaceLoading && f.calls.last?.1["surface"] as? String=="epics"}
        XCTAssertEqual(store.projects.first{$0.id==f.b}?.string("name"),"B")
        let before=f.calls.count
        await store.applyChangeCoverage(changes(f.b,families:["tasks","work"],task:"foreign-task"))
        XCTAssertEqual(f.calls.count,before,"A foreign task does not refresh the selected project")
        let current=try f.command("project_settings_get",["project_id":f.b])["data"] as! [String:Any]
        _=try f.command("project_edit",["project_id":f.b,"expected_revision":current["revision"]!,"name":"B renamed"])
        await store.applyChangeCoverage(changes(f.b,families:["all"]))
        XCTAssertEqual(f.calls.count,before+1)
        XCTAssertEqual(f.calls.last?.0,"workspace_page")
        XCTAssertEqual(store.projects.first{$0.id==f.b}?.string("name"),"B renamed")
    }
    func testObsoleteWorkspaceReplyAndWindowCloseCannotInstallOrLoseDraft()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()};let store=f.store();let live=Task {await store.startLiveUpdates()}
        defer {live.cancel();f.release();store.stopWindowReads()}
        try await until {store.connected && !store.workspaceLoading}
        store.saveNote(f.task,text:"unsent exact draft")
        f.holdSurface="requests";store.select(.needsYou,project:f.a)
        try await until {f.held != nil}
        XCTAssertEqual(f.calls.last?.1["surface"] as? String,"requests")
        XCTAssertEqual(f.calls.last?.1["project_id"] as? String,f.a)
        store.select(.activity,project:f.a)
        try await until {!store.workspaceLoading && f.calls.last?.1["surface"] as? String=="activity"}
        let installed=store.workspaceRows.map(\.id)
        f.release();try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(store.workspaceRows.map(\.id),installed)
        XCTAssertEqual(store.noteDrafts[f.task],"unsent exact draft")
        f.holdSurface="activity";store.retryWorkspacePage();try await until {f.held != nil}
        store.stopWindowReads();f.release();try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertFalse(store.workspaceLoading)
        XCTAssertEqual(store.workspaceRows.map(\.id),installed)
        XCTAssertEqual(try LocalDraftJournal(directory:f.root.appendingPathComponent("drafts")).recover(StoredNoteDraft.self,kind:"note").values[f.task]?.text,"unsent exact draft")
    }
    func testCommittedCaptureReconcilesOriginalUUIDAcrossRestartAndRecoversExactTarget()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()};var first:ChecklistStore?=f.store();await first!.refresh()
        let storeID=first!.storeIncarnation
        first!.saveCapture(CaptureDraft(projectID:f.a,title:"Lost create",brief:"Preserved brief",kind:"work",epicID:"",storeIncarnation:storeID))
        let original=try first!.captureCreateParameters(projectID:f.a),uuid=original["command_id"] as! String
        f.loseCreateReply=true
        first!.run("task_create",original,success:"captured")
        try await until {!first!.busy && first!.hasPendingMutation}
        XCTAssertEqual(first!.pendingCommandID,uuid);XCTAssertNotNil(f.pending["synthetic-window"])
        first=nil
        let restored=f.store(restore:true);await restored.refresh()
        XCTAssertEqual(restored.pendingCommandID,uuid)
        restored.retryPendingMutation();try await until {!restored.busy && !restored.hasPendingMutation}
        XCTAssertNil(restored.captureDrafts[f.a]?.createdTaskID,"Reconciliation does not invent a lost view completion")
        let replay=try restored.captureCreateParameters(projectID:f.a)
        XCTAssertEqual(replay["command_id"] as? String,uuid)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:replay,options:.sortedKeys),try JSONSerialization.data(withJSONObject:original,options:.sortedKeys))
        var target:String?
        restored.run("task_create",replay,success:"reconciled") {target=restored.recordCapturedTask($0,projectID:f.a,commandID:uuid,store:storeID)}
        try await until {!restored.busy && target != nil}
        let tasks=try f.command("task_list",["project_id":f.a])["data"] as! [String:Any]
        XCTAssertEqual((tasks["tasks"] as! [[String:Any]]).filter{$0["title"] as? String=="Lost create"}.count,1)
        XCTAssertEqual(restored.captureDrafts[f.a]?.createdTaskID,target)
        XCTAssertNil(restored.recordCapturedTask(["id":"wrong","project_id":f.b],projectID:f.a,commandID:uuid,store:storeID))
        XCTAssertNil(restored.recordCapturedTask(["id":"wrong","project_id":f.a],projectID:f.a,commandID:UUID().uuidString,store:storeID))
        XCTAssertEqual(try LocalDraftJournal(directory:f.root.appendingPathComponent("drafts")).recover(CaptureDraft.self,kind:"capture").values[f.a]?.createdTaskID,target)
    }
    func testExpiredSubscriptionEstablishesFreshCoverageWithoutLosingDraftOrPendingUUID()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()};let store=f.store();await store.refresh()
        store.saveNote(f.task,text:"draft across cursor reset")
        let uuid=UUID().uuidString
        f.loseCreateReply=true
        store.run("task_create",["command_id":uuid,"project_id":f.a,"title":"Pending through reset"],success:"saved")
        try await until {!store.busy && store.hasPendingMutation}
        f.resetFirstWait=true
        let live=Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads()}
        try await until {f.waitCursors.count>=2 && store.connected}
        XCTAssertNotNil(f.waitCursors[0]);XCTAssertNotNil(f.waitCursors[1])
        XCTAssertNotEqual(f.waitCursors[0],f.waitCursors[1],"CURSOR_RESET must retire the rejected interval")
        XCTAssertEqual(f.calls.filter{$0.0=="workspace_page"}.count,3,"Initial view, subscription start and explicit reset reload only")
        XCTAssertEqual(store.pendingCommandID,uuid);XCTAssertTrue(store.hasPendingMutation)
        XCTAssertEqual(store.noteDrafts[f.task],"draft across cursor reset")
        XCTAssertNotNil(f.pending["synthetic-window"])
    }
    func testConversationContinuationRebasesOnlyCursorResetAndPreservesDraft()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()}
        for i in 0..<51 {_=try f.command("message_send",["project_id":f.a,"task_id":f.task,"body":"Synthetic history \(i)"])}
        f.preferences.set(Page.tasks.rawValue,forKey:"lastPage")
        let store=f.store(),live=Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads()}
        try await until {store.connected && !store.ticketPageLoading}
        store.open(.task(f.task));try await until {store.selectedTicketCurrent(f.task)}
        store.saveNote(f.task,text:"Exact unsent draft é")
        let cursor=try XCTUnwrap(store.selectedMessageNextCursor),before=f.calls.count
        f.continuationFailure="CURSOR_RESET";store.moveSelectedMessages(cursor)
        try await until {store.selectedTicketCurrent(f.task) && f.calls.dropFirst(before).filter{$0.0=="task_context" && $0.1["detail_level"] as? String=="ui"}.count==2}
        let reads=f.calls.dropFirst(before).filter{$0.0=="task_context" && $0.1["detail_level"] as? String=="ui"}
        XCTAssertEqual(reads.first?.1["history_cursor"] as? String,cursor)
        XCTAssertNil(reads.last?.1["history_cursor"])
        XCTAssertEqual(store.detailRecords("messages",task:try XCTUnwrap(store.selectedTask(f.task))).count,50)
        XCTAssertEqual(store.selectedMessageCount,51)
        XCTAssertEqual(store.noteDrafts[f.task],"Exact unsent draft é")
        XCTAssertFalse(f.calls.dropFirst(before).contains{CommandReply.expectsMutation($0.0)})
        let next=try XCTUnwrap(store.selectedMessageNextCursor),errorStart=f.calls.count
        f.continuationFailure="FORBIDDEN";store.moveSelectedMessages(next)
        try await until {!store.selectedTicketLoading && store.selectedTicketError != nil}
        XCTAssertEqual(f.calls.dropFirst(errorStart).filter{$0.0=="task_context" && $0.1["detail_level"] as? String=="ui"}.count,1,"Only CURSOR_RESET may rebase a continuation")
        XCTAssertEqual(store.noteDrafts[f.task],"Exact unsent draft é")
    }
    func testSavedCaptureEpicPersistsWhenTicketsHasNoGlobalGroupCorpus()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()}
        let epic=try f.command("epic_create",["project_id":f.a,"name":"Saved Epic"])["data"] as! [String:Any]
        f.preferences.set(Page.tasks.rawValue,forKey:"lastPage")
        let store=f.store(),live=Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads()}
        try await until {store.connected && !store.ticketPageLoading}
        XCTAssertTrue(store.groups.isEmpty,"Tickets has no authoritative complete Epic corpus")
        store.saveCapture(CaptureDraft(projectID:f.a,title:"Preserved Epic draft",brief:"",kind:"work",epicID:epic["id"] as! String,storeIncarnation:store.storeIncarnation))
        let reopened=f.store()
        XCTAssertEqual(reopened.captureDrafts[f.a]?.epicID,epic["id"] as? String)
        await reopened.refresh()
        let parameters=try reopened.captureCreateParameters(projectID:f.a)
        XCTAssertEqual(parameters["epic_id"] as? String,epic["id"] as? String)
        XCTAssertEqual(try LocalDraftJournal(directory:f.root.appendingPathComponent("drafts")).recover(CaptureDraft.self,kind:"capture").values[f.a]?.epicID,epic["id"] as? String)
    }
    func testMarkdownResourcesUseSelectedTicketScopeWithoutALegacyTaskSnapshot() async throws {
        let f = try Fixture(defaults:isolatedDefaults("ScopedMarkdownResources")); defer { f.cleanup() }
        let documentURL = f.root.appendingPathComponent("a/preview-sample.md")
        let imageURL = f.root.appendingPathComponent("a/front-round2.png")
        try Data("![Front](front-round2.png)".utf8).write(to:documentURL)
        try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!.write(to:imageURL)
        let document = Record(values:try f.command("attachment_add",["project_id":f.a,"task_id":f.task,"path":documentURL.path])["data"] as! [String:Any])
        let image = Record(values:try f.command("attachment_add",["project_id":f.a,"task_id":f.task,"path":imageURL.path])["data"] as! [String:Any])
        f.preferences.set(Page.tasks.rawValue,forKey:"lastPage")
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel();store.stopWindowReads() }
        try await until {store.connected && !store.ticketPageLoading}
        store.open(.task(f.task));try await until {store.selectedTicketCurrent(f.task)}
        XCTAssertNotNil(store.selectedTask(f.task))
        XCTAssertNil(store.task(f.task),"The bounded Tickets path intentionally has no legacy snapshot task")
        // Exact original AttachmentRow.resources expression: this falls back to
        // the Markdown file alone even when its image is in selected attachments.
        let oldSeed = store.task(document.string("task_id")).map {store.detailRecords("attachments",task:$0)} ?? [document]
        XCTAssertEqual(oldSeed.map(\.id),[document.id])
        let resources = try await MarkdownPreviewResources.load(source:document,seed:oldSeed) {method,params in try await store.request(method,params)}
        let rendered = RenderedMarkdownPreview(document:.parse("![Front](front-round2.png)"),resources:resources,source:document)
        XCTAssertEqual(MarkdownResource.resolve("front-round2.png",image:true,attachments:rendered.resourceMap),.attachment(image.id))
        XCTAssertEqual(f.calls.last?.0,"attachment_list")
    }
    func testServiceErrorEnvelopeIsCountedAsFailedNativeRequest()async throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()}
        let store=ChecklistStore(draftJournal:LocalDraftJournal(directory:f.root.appendingPathComponent("metrics-drafts")),preferences:f.preferences,restorePendingCommand:false,
                                 desktopAlerts:DesktopAlertCoordinator(sink:ScopedReadAlertSink()),requestTransport:{_,_ in
            ["error":["code":"SYNTHETIC_READ_REFUSED","message":"Synthetic refusal"]]
        },navigationMemory:DetailItemNavigationMemory(),pendingCommandPersistence:PendingCommandPersistence(read:{_ in nil},save:{_,_ in},remove:{_ in}))
        NativeRenderMetrics.begin(sample:901)
        defer {NativeRenderMetrics.cancel()}
        do {_=try await store.request("workspace_page");XCTFail("A service refusal cannot succeed")}
        catch {XCTAssertEqual((error as? ChecklistError)?.code,"SYNTHETIC_READ_REFUSED")}
        let counts=try XCTUnwrap(NativeRenderMetrics.finish()?.requests["workspacePage"])
        XCTAssertEqual(counts.started,1);XCTAssertEqual(counts.succeeded,0);XCTAssertEqual(counts.failed,1)
    }
    func testWorkspaceModelRejectsFractionalVersionsAndCountClaims()throws {
        let f=try Fixture(defaults: isolatedDefaults("ScopedAppTests"));defer {f.cleanup()}
        let query=WorkspacePageQuery(surface:"epics",project:f.a)
        let reply=try f.command("workspace_page",query.parameters())["data"] as! [String:Any]
        XCTAssertNoThrow(try WorkspacePage(reply,query:query))
        for (field,value) in [("workspace_version",1.5),("total",0.5)] {
            var malformed=reply;malformed[field]=value
            XCTAssertThrowsError(try WorkspacePage(malformed,query:query))
        }
    }
}

@MainActor private final class ScopedReadAlertSink:DesktopAlertSink {
    func authorization()async->DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction()async throws->Bool {false}
    func send(_ alert:DesktopAlert)async throws {throw NSError(domain:"UnexpectedScopedTestAlert",code:1)}
    func remove(_ identifiers:[String]) {}
}
