import XCTest
import GRDB
@testable import ChecklistCore
@testable import ChecklistBridges

extension HumanAnswerNoticeTests {
    func pendingNotes(_ output: JSON) -> JSON? {
        let data = output["data"] as? JSON ?? output
        return (data["_checklist"] as? JSON)?["pending_notes"] as? JSON
    }

    func sendNote(_ f: (project:JSON,task:JSON,requester:Caller,handler:Caller,other:Caller), body: String = "PRIVATE_NOTE_BODY") throws -> JSON {
        try call("message_send",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"body":body,"recipient":["kind":"session","session_id":f.requester.sessionID!]])
    }

    func testPendingNoteMetadataIsLiveScopedBoundedAndDoesNotAcknowledge() throws {
        let f = try fixture(),note = try sendNote(f)
        let output = try envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.requester)
        let metadata = try XCTUnwrap(pendingNotes(output)), item = try XCTUnwrap((metadata["items"] as? [JSON])?.first)
        XCTAssertEqual(item["message_id"] as? String,note["id"] as? String)
        XCTAssertEqual(item["project_id"] as? String,f.project["id"] as? String)
        XCTAssertEqual(item["task_key"] as? String,f.task["key"] as? String)
        XCTAssertFalse(try jsonString(metadata).contains("PRIVATE_NOTE_BODY"))
        XCTAssertNotNil(PendingNoteNoticePresentation.text(in:output))
        XCTAssertNotNil(PendingNoteNoticePresentation.text(in:output["data"] as! JSON))
        let before = try delivery(item["delivery_id"] as! String)
        XCTAssertEqual(before["state"] as? String,"queued");XCTAssertEqual(before["push_state"] as? String,"unavailable")
        XCTAssertNil(pendingNotes(try envelope("service_info",[:],f.other)))
        for _ in 0..<9 { _ = try sendNote(f) }
        let bounded = try XCTUnwrap(pendingNotes(envelope("service_info",[:],f.requester)))
        XCTAssertEqual((bounded["items"] as? [JSON])?.count,8);XCTAssertEqual(bounded["has_more"] as? Bool,true)
        _ = try call("message_ack",["project_id":f.project["id"]!,"delivery_id":item["delivery_id"]!,"stage":"acknowledged"],f.requester)
        let after = try XCTUnwrap(pendingNotes(envelope("service_info",[:],f.requester)))
        XCTAssertFalse((after["items"] as! [JSON]).contains { $0["message_id"] as? String == note["id"] as? String })
    }

    func testPendingNotesCoexistWithAnswersAndClaudeGetsNeither() throws {
        let f = try fixture()
        for index in 0..<10 { let request = try request(f," note coexist \(index)");_ = try answer(f,request) }
        let note = try sendNote(f)
        let result = try envelope("service_info",[:],f.requester)
        XCTAssertNotNil(notice(result))
        XCTAssertEqual(((try XCTUnwrap(pendingNotes(result)))["items"] as! [JSON])[0]["message_id"] as? String,note["id"] as? String)
        // Change only the provider in an owned fixture; no production store is used.
        try router.dbQueue.write { db in
            var session = try router.record(db,f.requester.sessionID!,type:"session")
            session["provider"] = "claude";try router.save(db,session,type:"session")
        }
        let claude = try envelope("service_info",[:],f.requester)
        XCTAssertNil(pendingNotes(claude));XCTAssertNil(notice(claude))
    }

    private func pickup(_ caller: Caller) throws -> JSON { try call("codex_hook_pickup",[:],caller)["pending_notes"] as! JSON }
    private func storeCounts() throws -> [Int] {
        try router.dbQueue.read { db in
            try ["commands","events","records"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } + [try Int.fetchOne(db,sql:"SELECT SUM(revision) FROM records") ?? -1]
        }
    }

    func testHookPickupIsAReadAndOnlyConfirmStampsWithANoBodyReceipt() throws {
        let f = try fixture()
        var before = try storeCounts()
        XCTAssertEqual(try pickup(f.requester)["status"] as? String,"empty")
        XCTAssertEqual(try storeCounts(),before,"Nothing pending writes nothing.")
        let note = try sendNote(f)
        before = try storeCounts()
        let first = try pickup(f.requester),second = try pickup(f.requester)
        XCTAssertEqual(try storeCounts(),before,"Pickup adds no commands row and stamps nothing.")
        let items = first["items"] as! [JSON],id = items[0]["delivery_id"] as! String
        XCTAssertEqual(items.count,1);XCTAssertEqual(items[0]["body"] as? String,"PRIVATE_NOTE_BODY")
        XCTAssertEqual((second["items"] as! [JSON])[0]["delivery_id"] as? String,id)
        XCTAssertNil(try delivery(id)["hook_state"])
        let command = uuid()
        let confirmed = try envelope("codex_hook_confirm",["delivery_ids":[id]],f.requester,command:command)
        XCTAssertEqual((confirmed["data"] as! JSON)["confirmed"] as? [String],[id])
        let receipt = try delivery(id),stamp = receipt["hook_written_at"] as? String
        XCTAssertEqual(receipt["hook_state"] as? String,"context_written");XCTAssertEqual(receipt["hook_route"] as? String,"codex_post_tool_use")
        XCTAssertNotNil(stamp);XCTAssertEqual(receipt["state"] as? String,"queued");XCTAssertEqual(receipt["push_state"] as? String,"unavailable")
        let row = try router.dbQueue.read { try String.fetchOne($0,sql:"SELECT result FROM commands WHERE command_id=?",arguments:[command]) }
        XCTAssertFalse(try XCTUnwrap(row).contains("PRIVATE_NOTE_BODY"),"The receipt stores no note body.")
        let replay = try envelope("codex_hook_confirm",["delivery_ids":[id]],f.requester,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true,"A retry with the derived command ID replays.")
        XCTAssertEqual(try delivery(id)["hook_written_at"] as? String,stamp)
        router = nil;router = try CommandRouter(root:root.appendingPathComponent("store"))
        XCTAssertTrue((try pickup(f.requester)["items"] as! [JSON]).isEmpty)
        XCTAssertNotNil(pendingNotes(try envelope("service_info",[:],f.requester)),"A confirmed hook output never consumes inbox/reply pickup.")
        let listed = try call("message_delivery_list",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"message_id":note["id"]!])["deliveries"] as! [JSON]
        XCTAssertEqual(listed[0]["hook_route"] as? String,"codex_post_tool_use")
        XCTAssertEqual(listed[0]["hook_state"] as? String,"context_written")
        XCTAssertEqual(listed[0]["hook_written_at"] as? String,stamp)
        XCTAssertEqual(listed[0]["state"] as? String,"queued")
    }

    func testLostOutputOrFailedConfirmShowsTheNoteAgainAcrossRestart() throws {
        let f = try fixture(),note = try sendNote(f)
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON])[0]["message_id"] as? String,note["id"] as? String)
        router = nil;router = try CommandRouter(root:root.appendingPathComponent("store"))
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON])[0]["message_id"] as? String,note["id"] as? String,"No confirmation: at least once, never lost.")
    }

    func testBackupCaptureRefusesConfirmWithoutQueueAndTheNoteRepeats() throws {
        let f = try fixture(),note = try sendNote(f),id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        try router.backupWrites.beginCapture()
        let before = try storeCounts()
        let refused = try envelope("codex_hook_confirm",["delivery_ids":[id]],f.requester)
        let data = refused["data"] as? JSON
        XCTAssertNotNil(refused["command_id"],"The bundled client needs the command identity to read a definite refusal.")
        XCTAssertEqual(data?["state"] as? String,"locked");XCTAssertEqual(data?["queued"] as? Bool,false);XCTAssertEqual(data?["retry_required"] as? Bool,true)
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).count,1,"Pickup stays a read during the capture.")
        XCTAssertEqual(try storeCounts(),before)
        router.backupWrites.endCapture(router:router);router.backupWrites.endBackup(router:router)
        XCTAssertNil(try delivery(id)["hook_state"],"A refused confirmation runs nothing later.")
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).count,1)
    }

    func testHookConfirmIsLimitedToTheRecipientAndHiddenFromTheCatalog() throws {
        let f = try fixture(),note = try sendNote(f),id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        XCTAssertThrowsError(try call("codex_hook_confirm",["delivery_ids":[id]],f.other))
        XCTAssertNil(try delivery(id)["hook_state"])
        XCTAssertThrowsError(try call("codex_hook_confirm",["delivery_ids":[]],f.requester))
        XCTAssertThrowsError(try call("codex_hook_confirm",["delivery_ids":[id,id]],f.requester))
        let names = router.toolCatalog(f.requester).compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("codex_hook_pickup"));XCTAssertFalse(names.contains("codex_hook_confirm"))
        XCTAssertFalse(try jsonString(try call("tool_catalog",[:],f.requester)).contains("codex_hook"))
        let concurrent = try call("codex_hook_confirm",["delivery_ids":[id]],f.requester)
        XCTAssertEqual(concurrent["confirmed"] as? [String],[id])
        XCTAssertEqual(try call("codex_hook_confirm",["delivery_ids":[id]],f.requester)["skipped"] as? [String],[id],"A later hook process does not stamp again.")
    }

    func testHookBoundedBodyAndAcknowledgedGenerationFences() throws {
        let f = try fixture()
        for _ in 0..<10 { _ = try sendNote(f,body:String(repeating:"é",count:5000)) }
        let picked = try pickup(f.requester)
        let items = picked["items"] as! [JSON]
        XCTAssertEqual(items.count,8);XCTAssertEqual(picked["has_more"] as? Bool,true)
        XCTAssertTrue(items.allSatisfy { ($0["body"] as! String).utf8.count <= 4096 && $0["body_truncated"] as? Bool == true })
        _ = try call("codex_hook_confirm",["delivery_ids":items.map { $0["delivery_id"]! }],f.requester)
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).count,2)
        let fresh = try sendNote(f),id = (fresh["deliveries"] as! [JSON])[0]["id"]!
        _ = try call("message_ack",["project_id":f.project["id"]!,"delivery_id":id,"stage":"acknowledged"],f.requester)
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).count,2,"An acknowledged note is not shown.")
        _ = try call("session_register",["project_id":f.project["id"]!,"session_id":f.requester.sessionID!,"provider":"codex","role":"worker","installation":"requester","workspace":f.requester.workspace!])
        XCTAssertNil(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertTrue((try pickup(f.requester)["items"] as! [JSON]).isEmpty)
    }

    private func age(_ deliveryID: String, hours: Double) throws {
        try router.dbQueue.write { db in
            var delivery = try router.record(db,deliveryID,type:"delivery")
            delivery["created_at"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-hours*3600))
            try router.save(db,delivery,type:"delivery")
        }
    }

    func testHookRepeatsANoteForAtMost24HoursWithNoWriteAndTheInboxKeepsIt() throws {
        let f = try fixture()
        XCTAssertEqual(CommandRouter.codexHookNoteWindow,24*3600)
        _ = try sendNote(f,body:"old note")
        let id = try XCTUnwrap((try pickup(f.requester)["items"] as! [JSON]).first?["delivery_id"] as? String)
        try age(id,hours:23.5)
        let before = try storeCounts()
        for _ in 0..<3 { XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).first?["delivery_id"] as? String,id,"It repeats inside the window.") }
        try age(id,hours:24.5)
        let aged = try storeCounts()
        XCTAssertEqual(aged,before,"Three repeated pickups add no row and no revision. The fixture edit keeps the revision.")
        XCTAssertEqual(try pickup(f.requester)["status"] as? String,"empty")
        XCTAssertEqual(try storeCounts(),aged,"The rule is a read. It writes nothing.")
        XCTAssertNil(try delivery(id)["hook_state"])
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertEqual((metadata["items"] as! [JSON]).first?["delivery_id"] as? String,id,"The reply notice still names it.")
        let inbox = try call("session_inbox",["project_id":f.project["id"]!],f.requester)
        XCTAssertTrue(try jsonString(inbox).contains("old note"),"The inbox still holds it.")
        let new = try sendNote(f,body:"new note")
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).map { $0["message_id"] as? String },[new["id"] as? String])
    }

    func testAMalformedDeliveryRowOfAnyRecipientStopsNoWorker() throws {
        let f = try fixture()
        _ = try sendNote(f,body:"good note")
        try router.dbQueue.write { db in
            for (id,data) in [("malformed-delivery","{not json"),("array-delivery","[1]")] {
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,'delivery',1,?)",arguments:[id,f.project["id"] as! String,data])
            }
        }
        let items = try pickup(f.requester)["items"] as! [JSON]
        XCTAssertEqual(items.map { $0["body"] as? String },["good note"])
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertEqual(metadata["status"] as? String,"pending_pickup")
        XCTAssertEqual((metadata["items"] as! [JSON]).count,1)
        XCTAssertEqual(try pickup(f.other)["status"] as? String,"empty","Another worker in the project is not stopped.")
    }

    func testAMalformedMessageRowInTheSameProjectStopsNoWorker() throws {
        let f = try fixture()
        _ = try sendNote(f,body:"good note")
        try router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('malformed-message',?,'message',1,'{not json')",arguments:[f.project["id"] as! String])
        }
        XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).map { $0["body"] as? String },["good note"])
    }

    func testNewestNotesComeFirstAndOlderNotesCannotHideANewOne() throws {
        let f = try fixture()
        for index in 0..<9 { _ = try sendNote(f,body:"older \(index)") }
        let new = try sendNote(f,body:"new note")
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertEqual((metadata["items"] as! [JSON])[0]["message_id"] as? String,new["id"] as? String)
        XCTAssertEqual(metadata["has_more"] as? Bool,true)
        let picked = try pickup(f.requester)
        XCTAssertEqual((picked["items"] as! [JSON])[0]["body"] as? String,"new note");XCTAssertEqual(picked["has_more"] as? Bool,true)
    }

    func testSystemNotesStayOutOfHookAndPendingNotesAndInInbox() throws {
        let f = try fixture(),plain = try sendNote(f,body:"plain note")
        var healthDelivery = ""
        for index in 0..<9 {
            let health = try sendNote(f,body:"health \(index)");healthDelivery = (health["deliveries"] as! [JSON])[0]["id"] as! String
            try router.dbQueue.write { try $0.execute(sql:"UPDATE records SET data=json_set(data,'$.origin','system') WHERE id=?",arguments:[health["id"] as! String]) }
        }
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)),"Nine newer system notes take no slot.")
        XCTAssertEqual((metadata["items"] as! [JSON]).map { $0["message_id"] as? String },[plain["id"] as? String]);XCTAssertEqual(metadata["has_more"] as? Bool,false)
        let picked = try pickup(f.requester)
        XCTAssertEqual((picked["items"] as! [JSON]).map { $0["message_id"] as? String },[plain["id"] as? String])
        XCTAssertTrue(try jsonString(try call("session_inbox",["project_id":f.project["id"]!],f.requester)).contains(healthDelivery))
    }

    func testNoteStepFailureKeepsAGoodHumanAnswerNotice() throws {
        let f = try fixture(),r = try request(f);_ = try answer(f,r)
        let note = try sendNote(f),id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        try router.dbQueue.write { db in try db.execute(sql:"UPDATE records SET data=json_set(data,'$.id','wrong-envelope-id') WHERE id=?",arguments:[id]) }
        let output = try envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.requester)
        XCTAssertEqual(notice(output)?["status"] as? String,"pending_pickup")
        XCTAssertEqual((notice(output)?["items"] as? [JSON])?.count,1)
        XCTAssertEqual(pendingNotes(output)?["status"] as? String,"unavailable")
    }

    func testSessionReadErrorReportsUnavailableAndNotAnEmptyInbox() throws {
        let f = try fixture();_ = try sendNote(f)
        try router.dbQueue.write { db in try db.execute(sql:"UPDATE records SET data=json_set(data,'$.id','wrong-envelope-id') WHERE id=?",arguments:[f.requester.sessionID!]) }
        let result = try router.dbQueue.read { db in try router.addingHumanAnswerNotices(db,output:["data":["ok":true]],params:[:],caller:f.requester) }
        XCTAssertEqual((result["data"] as! JSON)["ok"] as? Bool,true)
        XCTAssertEqual(pendingNotes(result)?["status"] as? String,"unavailable")
    }

    func testWriteReplySeesItsCommittedNoteThroughTheReaderPool() throws {
        let f = try fixture()
        XCTAssertNotNil(router.readers)
        let reply = try envelope("message_send",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"body":"own note","recipient":["kind":"session","session_id":f.requester.sessionID!]],f.requester)
        let message = (reply["data"] as! JSON)["id"] as? String
        XCTAssertEqual((pendingNotes(reply)?["items"] as? [JSON])?.first?["message_id"] as? String,message)
    }

    /// Core read path only: no process start, no XPC and no native discovery. The row count matches
    /// the largest project in the newest backup (4,072 delivery rows).
    func testHookPickupTimeOnALargeDeliveryTable() throws {
        try QualificationSuite.requireEnabled()
        let f = try fixture();for _ in 0..<8 { _ = try sendNote(f) }
        try router.dbQueue.write { db in
            let template = try XCTUnwrap(String.fetchOne(db,sql:"SELECT id FROM records WHERE type='delivery' ORDER BY rowid LIMIT 1"))
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<4064)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT 'bulk-'||i,project_id,type,revision,json_set(data,'$.id','bulk-'||i,'$.state','acknowledged') FROM records,n WHERE records.id=?
                """,arguments:[template])
        }
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual((try pickup(f.requester)["items"] as! [JSON]).count,8)
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("CL410_PICKUP_SECONDS rows=4072 samples=\(samples)")
        XCTAssertLessThan(try XCTUnwrap(samples.max()),1.5)
    }

    func testPendingNoteObservationFailurePreservesCommandResult() throws {
        let f = try fixture(),note = try sendNote(f),id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        try router.dbQueue.write { db in try db.execute(sql:"UPDATE records SET data=json_set(data,'$.id','wrong-envelope-id') WHERE id=?",arguments:[id]) }
        let output = try envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.requester)
        XCTAssertEqual((output["data"] as! JSON)["id"] as? String,f.task["id"] as? String)
        XCTAssertEqual(pendingNotes(output)?["status"] as? String,"unavailable")
    }

    private func breakMessage(_ note: JSON) throws {
        try router.dbQueue.write { try $0.execute(sql:"UPDATE records SET data='{not json' WHERE id=? AND type='message'",arguments:[note["id"] as! String]) }
    }
    private func detachDeliveries(keeping kept: [String]) throws {
        try router.dbQueue.write { db in
            for id in try String.fetchAll(db,sql:"SELECT id FROM records WHERE type='delivery'") where !kept.contains(id) {
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.message_id','no-such-message') WHERE id=?",arguments:[id])
            }
        }
    }

    func testAMalformedMessageOfOneDeliveryIsSkippedCountedAndBlocksNoNote() throws {
        let f = try fixture()
        let old = try sendNote(f,body:"older note"),bad = try sendNote(f,body:"lost note"),new = try sendNote(f,body:"newer note")
        try breakMessage(bad)
        let picked = try pickup(f.requester)
        XCTAssertEqual((picked["items"] as! [JSON]).map { $0["message_id"] as? String },[new["id"] as? String,old["id"] as? String])
        XCTAssertEqual(picked["skipped_malformed"] as? Int,1);XCTAssertEqual(picked["status"] as? String,"pending_pickup")
        let output = try envelope("service_info",[:],f.requester),metadata = try XCTUnwrap(pendingNotes(output))
        XCTAssertEqual((metadata["items"] as! [JSON]).count,2);XCTAssertEqual(metadata["skipped_malformed"] as? Int,1)
        XCTAssertTrue(try XCTUnwrap(PendingNoteNoticePresentation.text(in:output)).contains("could not read 1"))
        // The route that the hook line names works, and states the same count.
        let inbox = try call("session_inbox",["project_id":f.project["id"]!],f.requester)
        XCTAssertEqual(inbox["skipped_malformed"] as? Int,1)
        XCTAssertEqual(Set((inbox["messages"] as! [JSON]).map { $0["body"] as? String }),["older note","newer note"])
        XCTAssertEqual(try pickup(f.other)["skipped_malformed"] as? Int,0,"Another worker has no such row.")
    }

    func testOnlyAMalformedMessageStillTellsTheWorker() throws {
        let f = try fixture()
        try breakMessage(try sendNote(f,body:"lost note"))
        let picked = try pickup(f.requester)
        XCTAssertEqual((picked["items"] as! [JSON]).count,0);XCTAssertEqual(picked["status"] as? String,"pending_pickup");XCTAssertEqual(picked["skipped_malformed"] as? Int,1)
        let output = try envelope("service_info",[:],f.requester),metadata = try XCTUnwrap(pendingNotes(output))
        XCTAssertEqual(metadata["status"] as? String,"pending_pickup");XCTAssertEqual(metadata["skipped_malformed"] as? Int,1)
        XCTAssertTrue(try XCTUnwrap(PendingNoteNoticePresentation.text(in:output)).contains("session_inbox"))
    }

    func testNineRowsThatTheFiltersDropDoNotHideAnOlderNote() throws {
        let f = try fixture(),old = try sendNote(f,body:"older good note")
        for index in 0..<9 { _ = try sendNote(f,body:"dropped \(index)") }
        try detachDeliveries(keeping:[(old["deliveries"] as! [JSON])[0]["id"] as! String])
        let picked = try pickup(f.requester)
        XCTAssertEqual((picked["items"] as! [JSON]).map { $0["body"] as? String },["older good note"]);XCTAssertEqual(picked["has_more"] as? Bool,false)
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertEqual((metadata["items"] as! [JSON]).map { $0["message_id"] as? String },[old["id"] as? String]);XCTAssertEqual(metadata["has_more"] as? Bool,false)
    }

    func testRowsPastTheScanBoundReportHasMore() throws {
        let f = try fixture(),old = try sendNote(f,body:"older good note")
        // Fixture rows exercise the full scan bound. Only one send is needed
        // to obtain the real message/delivery envelopes; pickup is the subject.
        let seed = try sendNote(f,body:"dropped 0")
        try router.dbQueue.write { db in
            let message = try router.record(db,seed["id"] as! String,type:"message")
            let delivery = try router.record(db,(seed["deliveries"] as! [JSON])[0]["id"] as! String,type:"delivery")
            for index in 1..<(CommandRouter.pendingNoteScanRows + 1) {
                var nextMessage = message;nextMessage["id"] = uuid();nextMessage["body"] = "dropped \(index)"
                try router.save(db,nextMessage,type:"message")
                var nextDelivery = delivery;nextDelivery["id"] = uuid();nextDelivery["message_id"] = nextMessage["id"]!
                try router.save(db,nextDelivery,type:"delivery")
                try router.event(db,caller:owner,project:f.project["id"] as? String,entity:f.task["id"] as? String,kind:"message_saved",data:["message_id":nextMessage["id"]!,"origin":nextMessage["origin"]!])
            }
        }
        try detachDeliveries(keeping:[(old["deliveries"] as! [JSON])[0]["id"] as! String])
        let picked = try pickup(f.requester)
        XCTAssertTrue((picked["items"] as! [JSON]).isEmpty);XCTAssertEqual(picked["has_more"] as? Bool,true);XCTAssertEqual(picked["status"] as? String,"pending_pickup")
        let metadata = try XCTUnwrap(pendingNotes(try envelope("service_info",[:],f.requester)))
        XCTAssertEqual(metadata["has_more"] as? Bool,true)
        XCTAssertTrue(try jsonString(try call("session_inbox",["project_id":f.project["id"]!],f.requester)).contains("older good note"),"The inbox keeps the note past the bound.")
    }

    func testAMalformedDeliveryOfAnyRecipientHidesNoHumanAnswer() throws {
        let f = try fixture(),r = try request(f);_ = try answer(f,r)
        try router.dbQueue.write { db in
            for (id,data) in [("malformed-delivery","{not json"),("array-delivery","[1]")] {
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,'delivery',1,?)",arguments:[id,f.project["id"] as! String,data])
            }
        }
        let output = try envelope("service_info",[:],f.requester)
        XCTAssertEqual(notice(output)?["status"] as? String,"pending_pickup");XCTAssertEqual((notice(output)?["items"] as? [JSON])?.count,1)
        XCTAssertNil(notice(try envelope("service_info",[:],f.other)),"Another worker has no answer and no unavailable notice.")
    }

    func testAMalformedMessageOfThisWorkersDeliveryKeepsTheAnswerNoticeUnavailable() throws {
        let f = try fixture()
        try breakMessage(try sendNote(f))
        XCTAssertEqual(notice(try envelope("service_info",[:],f.requester))?["status"] as? String,"unavailable","It can be an answer, so the notice claims no empty inbox.")
        XCTAssertNil(notice(try envelope("service_info",[:],f.other)),"Only the named recipient sees that.")
    }

    func testOneMalformedDeliveryCostsOnlyItsRowInTheInbox() throws {
        let f = try fixture()
        let old = try sendNote(f,body:"older note"),bad = try sendNote(f,body:"lost note"),new = try sendNote(f,body:"newer note")
        _ = (old,new)
        try router.dbQueue.write { try $0.execute(sql:"UPDATE records SET data='{not json' WHERE type='delivery' AND json_extract(data,'$.message_id')=?",arguments:[bad["id"] as! String]) }
        let inbox = try call("session_inbox",["project_id":f.project["id"]!],f.requester)
        XCTAssertEqual(inbox["skipped_malformed"] as? Int,1)
        XCTAssertEqual(Set((inbox["messages"] as! [JSON]).map { $0["body"] as? String }),["older note","newer note"])
        XCTAssertEqual((inbox["deliveries"] as! [JSON]).count,2)
    }
    func testAnotherRecipientsWellFormedDeliveryIsNotCounted() throws {
        let f = try fixture()
        _ = try sendNote(f,body:"for the requester")
        XCTAssertEqual(try call("session_inbox",["project_id":f.project["id"]!],f.other)["skipped_malformed"] as? Int,0)
        XCTAssertEqual(try call("session_inbox",["project_id":f.project["id"]!],f.requester)["skipped_malformed"] as? Int,0)
    }
}
