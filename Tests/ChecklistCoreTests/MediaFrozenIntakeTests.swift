import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class MediaFrozenIntakeTests: XCTestCase {
    final class Fixture {
        // Reuse the established owned-store harness: Foundation rewrites every tmp
        // spelling to /tmp, which the real no-follow walker correctly refuses.
        let storage: StorageFixture?
        let base: URL,workspace: URL,root: URL
        var router: CommandRouter!
        let owner: Caller
        var worker: Caller
        let project: String
        init(template: TestStore.Template? = nil) throws {
            let owned = try StorageFixture(open:template == nil,fast:true)
            storage = owned
            base = owned.base;workspace = owned.workspace;root = owned.root;owner = owned.owner
            if let template {
                // StorageFixture owns the lease and teardown, while TestStore
                // supplies private APFS-cloned phase bytes and relocates the root.
                try FileManager.default.removeItem(at:workspace)
                let lease = try StorageServiceLease(root:root)
                owned.lease = lease
                let prepared = try TestStore.router(root:root,serviceLease:lease,template:template,workspace:workspace)
                owned.router = prepared;router = prepared
                project = try prepared.dbQueue.read {try XCTUnwrap(prepared.records($0,type:"project").first?["id"] as? String)}
                try prepared.dbQueue.write {db in
                    var session = try prepared.record(db,"media-fixture-worker",type:"session")
                    session["workspace"] = owned.workspace.path
                    try prepared.save(db,session,type:"session")
                }
            } else {
                router = owned.router!
                project = try owned.project()["id"] as! String
                _ = try router.handle(method:"session_register",params:["command_id":uuid(),"project_id":project,"provider":"codex","label":"Actual fixture worker","session_id":"media-fixture-worker","workspace":workspace.path],caller:owner)
            }
            worker = Caller(role:"worker",installation:"media-owned-worker",projectIDs:[project],sessionID:"media-fixture-worker",workspace:workspace.path)
        }
        /// Template construction borrows the router which TestStore closes and
        /// checkpoints before publishing. This adapter never owns or reopens it.
        fileprivate init(router: CommandRouter,workspace: URL) throws {
            storage = nil;self.router = router;self.workspace = workspace
            root = router.root;base = root.deletingLastPathComponent()
            owner = Caller(role:"owner",installation:"storage-fixture",projectIDs:[])
            let value = try router.handle(method:"project_create",params:["command_id":uuid(),"name":"Storage fixture","key_prefix":"SF","root_path":workspace.path],caller:owner)["data"] as! JSON
            project = value["id"] as! String
            _ = try router.handle(method:"epic_create",params:["command_id":uuid(),"project_id":project,"name":"Storage fixture tickets"],caller:owner)
            let session = try router.handle(method:"session_register",params:["command_id":uuid(),"project_id":project,"provider":"codex","label":"Actual fixture worker","session_id":"media-fixture-worker","workspace":workspace.path],caller:owner)["data"] as! JSON
            worker = Caller(role:"worker",installation:"media-owned-worker",projectIDs:[project],sessionID:session["id"] as? String ?? "media-fixture-worker",workspace:workspace.path)
        }
        func reopen() throws {
            let storage = try XCTUnwrap(storage,"Only an owned fixture may reopen its router")
            try storage.close();router = nil
            try storage.reopen();router = storage.router!
        }
        func call(_ method: String,_ p: JSON = [:],as caller: Caller? = nil,command: String? = nil) throws -> JSON {
            var p = p;p["project_id"] = p["project_id"] ?? project
            if !["media_round_get","media_type_get"].contains(method) {p["command_id"] = command ?? uuid()}
            return try router.executeMediaCommand(method:method,params:p,caller:caller ?? owner)
        }
        func rows(_ type: String) throws -> [JSON] {try router.dbQueue.read {try router.records($0,type:type,project:project)}}
        func record(_ id: String,_ type: String) throws -> JSON {try router.dbQueue.read {try router.record($0,id,type:type)}}
        func allState() throws -> String {
            try router.dbQueue.read { db in
                let rows = try Row.fetchAll(db,sql:"SELECT id,type,revision,data FROM records ORDER BY id").map { r -> JSON in ["id":r["id"] as String,"type":r["type"] as String,"revision":r["revision"] as Int,"data":r["data"] as String] }
                let events = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events")!,commands = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands")!,cursors = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM cursors")!
                return try jsonString(["rows":rows,"events":events,"commands":commands,"cursors":cursors])
            }
        }
        func type(_ schema: JSON? = nil,adopt: Bool = true,as caller: Caller? = nil) throws -> JSON {
            var p: JSON = ["title":"Story"];p["schema"] = schema
            let t = try call("media_type_create",p,as:caller)
            return adopt ? try adoptType(t) : t
        }
        func adoptType(_ type: JSON) throws -> JSON {
            let t = try call("media_type_get",["type_id":type["id"]!])
            return try call("media_type_adopt",["type_id":t["id"]!,"type_revision_id":t["draft_revision_id"]!,"expected_revision":t["revision"]!,"observed_type_token":t["observed_type_token"]!])
        }
        func round(_ type: JSON,as caller: Caller? = nil) throws -> JSON { try call("media_round_create",["type_id":type["id"]!,"title":"First pass"],as:caller) }
        func get(_ round: JSON,as caller: Caller? = nil) throws -> JSON {try call("media_round_get",["round_id":round["id"]!],as:caller)}
        func item(_ round: JSON,title: String = "Item",metadata: JSON = [:],texts: [String] = ["Exact text\r\n"],as caller: Caller? = nil) throws -> JSON {
            try call("media_item_create",["round_id":round["id"]!,"title":title,"metadata":metadata,"candidates":texts.map {["slots":[["slot_id":"text","text":$0]]]}],as:caller)
        }
        func observation(_ round: JSON) -> JSON { ["round_id":round["id"]!,"expected_revision":round["revision"]!,"observed_context_token":round["observed_context_token"]!] }
        func selection(_ round: JSON,publish: Bool = false) -> [JSON] {
            (round["items"] as! [JSON]).compactMap { item in
                guard let t = item[publish ? "draft_target" : "published_target"] as? JSON else {return nil}
                let basis = publish ? (item["publication_preview"] as! JSON)["review_basis_signature"]! : t["review_basis_signature"]!
                return ["item_id":item["id"]!,"expected_revision":item["revision"]!,"target_id":t["id"]!,"review_basis_signature":basis]
            }
        }
        func publish(_ round: JSON) throws -> JSON {
            let r = try get(round);var p = observation(r);p["items"] = selection(r,publish:true);return try call("media_round_publish",p)
        }
        func decisionParams(_ round: JSON,ids: [String]? = nil,disposition: String = "accepted") -> JSON {
            var p = observation(round);let m = round["manifest"] as! JSON
            p["manifest_id"] = m["id"];p["manifest_digest"] = m["digest"]
            p["items"] = selection(round).filter {ids == nil || ids!.contains($0["item_id"] as! String)}
            p["disposition"] = disposition
            if disposition == "accepted",let row = (round["items"] as! [JSON]).first(where:{ ids == nil || ids!.contains($0["id"] as! String) }) { p["winner_id"] = strings(row["published_target"] as! JSON,"candidate_ids").first }
            return p
        }
        func acceptEach(_ round: JSON) throws {
            for row in try get(round)["items"] as! [JSON] {
                let r = try get(round);_ = try call("media_decide",decisionParams(r,ids:[row["id"] as! String]))
            }
        }
        func reconcile(_ round: JSON,action: String = "migrate") throws -> JSON {
            let r = try get(round);var p = observation(r);p["attention_ids"] = r["attention_ids"];p["action"] = action;p["reason"] = "Explicit owner scope: this round"
            return try call("media_context_reconcile",p)
        }
    }
    let checks = MediaRoundTests()
    func imageSchema(twoSlots: Bool = false) -> JSON {
        var slots: [JSON] = [["id":"image","kind":"image","required":true]]
        if twoSlots { slots.append(["id":"reference","kind":"image"]) }
        return ["schema_version":1,"id":"server","name":"Images","slots":slots,"layout":["kind":"image_compare","primary_slot_id":"image"],"max_candidates":8]
    }
    let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func source(_ f: Fixture,_ name: String,_ index: Int = 0) throws -> JSON {
        let path = f.workspace.appendingPathComponent(name)
        var data = png;data.append(Data("fixture-\(index)".utf8));try data.write(to:path)
        return ["path":path.path]
    }
    func preview(_ f: Fixture,_ round: JSON,_ sources: [JSON]) throws -> JSON {try f.call("media_intake_preview",["round_id":round["id"]!,"sources":sources],as:f.worker)}
    func get(_ f: Fixture,_ intake: JSON) throws -> JSON {try f.call("media_intake_get",["intake_id":intake["id"]!],as:f.worker)}
    func confirm(_ f: Fixture,_ intake: JSON) throws -> JSON {
        let plan = intake["plan"] as! JSON
        return try f.call("media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":plan["id"]!,"plan_digest":plan["digest"]!],as:f.worker)
    }
    func captureParams(_ intake: JSON,_ ids: [String]? = nil) -> JSON {
        ["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":intake["plan_id"]!,"row_ids":ids ?? strings(intake,"remaining_row_ids")]
    }
    func capture(_ f: Fixture,_ intake: JSON,_ ids: [String]? = nil,command: String? = nil) throws -> JSON {try f.call("media_intake_capture",captureParams(intake,ids),as:f.worker,command:command)}
    func resolve(_ f: Fixture,_ intake: JSON,_ resolutions: [JSON],mapping: JSON? = nil) throws -> JSON {
        var p: JSON = ["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"resolutions":resolutions];p["mapping"] = mapping
        return try f.call("media_intake_revise",p,as:f.worker)
    }
    func testCandidateSetRetainedInDifferentOrderKeepsAcceptedBasis() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        var intake = try preview(f,round,(0..<8).map {try source(f,"take-\($0).png",$0)})
        intake = try resolve(f,intake,(intake["rows"] as! [JSON]).map {["row_id":$0["id"]!,"disposition":"include","group_id":"one-item"]})
        intake = try confirm(f,intake)
        _ = try capture(f,intake,Array(strings(intake,"remaining_row_ids").reversed()))
        _ = try f.publish(round);try f.acceptEach(round)
        let before = try f.get(round),item = (before["items"] as! [JSON])[0],target = item["draft_target"] as! JSON
        let ids = strings(target,"candidate_ids")
        XCTAssertEqual(ids,ids.sorted(),"Intake capture/chunk order must not order the material candidate set")
        let updated = try f.call("media_item_update",["item_id":item["id"]!,"expected_revision":item["revision"]!,"candidates":ids.reversed().map {["candidate_id":$0]}],as:f.worker)
        let retained = updated["draft_target"] as! JSON
        XCTAssertEqual(strings(retained,"candidate_ids"),ids)
        for key in ["content_signature","content_basis_base64","review_basis_signature","review_basis_base64"] {
            XCTAssertEqual(retained[key] as? String,target[key] as? String,key)
        }
        let published = try f.publish(round),result = (published["items"] as! [JSON])[0]
        XCTAssertEqual(result["disposition"] as? String,"accepted")
        XCTAssertEqual(result["decision_applicable"] as? Bool,true)
        XCTAssertEqual((result["decision"] as! JSON)["id"] as? String,(item["decision"] as! JSON)["id"] as? String)
    }
    func testRequiredIntakeIdentifiersRefuseMalformedInputBeforePreparation() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema())),file = try source(f,"validation.png",1)
        let intake = try confirm(f,preview(f,round,[file])),plan = intake["plan"] as! JSON,rowID = strings(intake,"row_ids")[0]
        let cases: [(String,JSON,[String])] = [
            ("media_intake_preview",["round_id":round["id"]!,"sources":[file]],["round_id"]),
            ("media_intake_get",["intake_id":intake["id"]!],["intake_id"]),
            ("media_intake_revise",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!],["intake_id"]),
            ("media_intake_confirm",["intake_id":intake["id"]!,"expected_revision":intake["revision"]!,"plan_id":plan["id"]!,"plan_digest":plan["digest"]!],["intake_id","plan_id"]),
            ("media_intake_capture",captureParams(intake),["intake_id","plan_id","row_ids"]),
            ("media_round_publish",["round_id":round["id"]!,"items":[]],["round_id"])
        ]
        let before = try f.allState()
        func metadata() throws -> String {try f.router.dbQueue.read {db in
            try jsonString(Row.fetchAll(db,sql:"SELECT key,value FROM metadata ORDER BY key").map {["key":$0["key"] as String,"value":$0["value"] as String]})
        }}
        let beforeMetadata = try metadata()
        for (method,params,keys) in cases {
            for key in keys {
                for value: Any? in [nil,NSNull(),42,"",String(repeating:"x",count:65_537)] {
                    var p = params;p[key] = value
                    XCTAssertThrowsError(try f.call(method,p,as:method == "media_round_publish" ? f.owner : f.worker),"\(method) \(key)") {error in
                        XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT","\(method) \(key)")
                    }
                    XCTAssertEqual(try f.allState(),before,"\(method) \(key)")
                    XCTAssertEqual(try metadata(),beforeMetadata,"No capture intent may be reserved for malformed identifiers")
                }
            }
        }
        for row: JSON in [[:],["row_id":NSNull()],["row_id":42],["row_id":""],["row_id":String(repeating:"x",count:65_537)]] {
            var resolution = row;resolution["disposition"] = "skip"
            checks.checkError("INVALID_INPUT") {try resolve(f,intake,[resolution])}
        }
        for ids in [[""],[String(repeating:"x",count:65_537)],[],[rowID,rowID],["missing-row"]] {
            checks.checkError("INVALID_INPUT") {try capture(f,intake,ids)}
        }
        for method in ["media_intake_get","media_intake_revise","media_intake_confirm","media_intake_capture"] {
            var p = captureParams(intake);p["intake_id"] = "missing-intake"
            if method != "media_intake_capture" {p.removeValue(forKey:"row_ids");p.removeValue(forKey:"plan_id")}
            if method == "media_intake_get" {p.removeValue(forKey:"expected_revision")}
            XCTAssertThrowsError(try f.call(method,p,as:f.worker)) {error in XCTAssertEqual((error as? CoreError)?.code,"NOT_FOUND")}
        }
        XCTAssertEqual(try f.allState(),before);XCTAssertEqual(try metadata(),beforeMetadata)
        XCTAssertTrue(try f.rows("attachment").isEmpty);XCTAssertTrue(try f.rows("media_item").isEmpty)
    }
    func testUnsupportedSparseSourcesConsumeAggregatePreviewBudgetWithoutWrites() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        let sources: [JSON] = try (0..<5).map {index in
            let path = f.workspace.appendingPathComponent("unsupported-\(index).bin")
            XCTAssertTrue(FileManager.default.createFile(atPath:path.path,contents:Data()))
            let file = try FileHandle(forWritingTo:path)
            try file.truncate(atOffset:256 * 1024 * 1024);try file.close()
            return ["path":path.path]
        }
        let within = try preview(f,round,Array(sources.prefix(4)))
        XCTAssertEqual((within["rows"] as! [JSON]).map {$0["status"] as! String},Array(repeating:"unsupported",count:4))
        let before = try f.allState()
        checks.checkError("CAPACITY_EXCEEDED") {try preview(f,round,sources)}
        XCTAssertEqual(try f.allState(),before,"The over-budget preview must create no intake, row, event or command receipt")
        XCTAssertEqual(try f.rows("media_intake").count,1);XCTAssertEqual(try f.rows("media_intake_row").count,4)
        XCTAssertTrue(try f.rows("media_item").isEmpty)
    }
    func test300SourcePreviewExactConfirmationStop200Resume96AndPlanRevision() throws {
        try QualificationSuite.requireEnabled()
        let f = try Fixture(),type = try f.type(imageSchema()),round = try f.round(type)
        var sources = try (0..<292).map {try source(f,"clip-\($0).png",$0)}
        for i in 0..<4 {let url = f.workspace.appendingPathComponent("duplicate-\(i).png");try Data(contentsOf:URL(fileURLWithPath:sources[i]["path"] as! String)).write(to:url);sources.append(["path":url.path])}
        for i in 0..<2 {sources.append(["path":f.workspace.appendingPathComponent("missing-\(i).png").path])}
        for i in 0..<2 {let url = f.workspace.appendingPathComponent("unsupported-\(i).bin");try Data([1,2,3]).write(to:url);sources.append(["path":url.path])}
        var intake = try preview(f,round,sources),rows = intake["rows"] as! [JSON]
        XCTAssertEqual(rows.count,300)
        for (status,count) in [("valid",292),("duplicate",4),("missing",2),("unsupported",2)] {XCTAssertEqual(rows.filter {$0["status"] as? String == status}.count,count)}
        XCTAssertTrue(try f.rows("media_item").isEmpty)
        let before = try f.allState();checks.checkError("MEDIA_MAPPING_REQUIRED") {try confirm(f,intake)};XCTAssertEqual(try f.allState(),before)
        intake = try resolve(f,intake,rows.filter {$0["status"] as? String != "valid"}.map {["row_id":$0["id"]!,"disposition":["missing","unsupported"].contains($0["status"] as! String) ? "skip" : "include"]})
        XCTAssertEqual(strings(intake,"remaining_row_ids").count,296);XCTAssertEqual(strings(intake,"skipped_row_ids").count,4)
        rows = intake["rows"] as! [JSON]
        XCTAssertTrue(rows.filter {$0["disposition"] as? String == "include"}.allSatisfy {$0["slot_id"] as? String == "image" && $0["group_id"] as? String == $0["id"] as? String})
        intake = try confirm(f,intake)
        let originalID = intake["id"] as! String,originalRows = strings(intake,"row_ids"),firstIDs = Array(strings(intake,"remaining_row_ids").prefix(200))
        let command = uuid(),params = captureParams(intake,firstIDs)
        intake = try capture(f,intake,firstIDs,command:command)
        XCTAssertEqual(strings(intake,"committed_row_ids").count,200);XCTAssertEqual(strings(intake,"remaining_row_ids").count,96)
        XCTAssertEqual(try f.rows("media_item").count,200);XCTAssertEqual(try f.rows("attachment").count,200)
        let committed = (intake["rows"] as! [JSON]).filter {$0["capture_state"] as? String == "committed"}
        let replay = try f.call("media_intake_capture",params,as:f.worker,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true);XCTAssertEqual(try f.rows("attachment").count,200)
        let pendingID = strings(intake,"remaining_row_ids")[0],oldPlan = intake["plan_id"] as! String
        intake = try resolve(f,intake,[["row_id":pendingID,"disposition":"include","title":"Explicit revised title"]])
        XCTAssertNotEqual(intake["plan_id"] as? String,oldPlan)
        for old in committed {XCTAssertEqual(try jsonString((intake["rows"] as! [JSON]).first {$0["id"] as? String == old["id"] as? String}!),try jsonString(old))}
        XCTAssertEqual(strings(intake,"remaining_row_ids").count,96)
        intake = try confirm(f,intake)
        try f.reopen()
        intake = try capture(f,intake)
        XCTAssertEqual(intake["id"] as? String,originalID);XCTAssertEqual(strings(intake,"row_ids"),originalRows)
        XCTAssertEqual(strings(intake,"committed_row_ids").count,296);XCTAssertTrue(strings(intake,"remaining_row_ids").isEmpty)
        XCTAssertEqual(try f.rows("media_item").count,296);XCTAssertEqual(try f.rows("attachment").count,296)
        XCTAssertEqual(try f.rows("media_intake_chunk").count,2)
        for source in sources.prefix(296) {XCTAssertTrue(FileManager.default.fileExists(atPath:source["path"] as! String))}
        let published = try f.publish(round)
        XCTAssertEqual((published["manifest"] as! JSON)["items"] as? [JSON] != nil,true)
        XCTAssertEqual(((published["manifest"] as! JSON)["items"] as! [JSON]).count,296)
        XCTAssertEqual(try f.rows("storage_hold").filter {$0["kind"] as? String == "media_reference" && $0["state"] as? String == "active"}.count,296)
        try f.router.dbQueue.read {try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes($0,project:f.project))}
    }
    func testChangedAndUnavailableSourcesStayFailedWithBoundedErrors() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        let sources = try [source(f,"a.png",1),source(f,"b.png",2),source(f,"c.png",3)]
        var intake = try confirm(f,preview(f,round,sources))
        try Data([8,9,10]).write(to:URL(fileURLWithPath:sources[0]["path"] as! String))
        try FileManager.default.removeItem(atPath:sources[1]["path"] as! String)
        intake = try capture(f,intake)
        XCTAssertEqual(strings(intake,"committed_row_ids").count,1);XCTAssertEqual(strings(intake,"remaining_row_ids").count,2)
        let failed = (intake["rows"] as! [JSON]).filter {$0["capture_state"] as? String == "failed"}
        XCTAssertEqual(failed.count,2)
        for row in failed {let error = row["capture_error"] as! JSON;XCTAssertLessThan(try jsonString(error).utf8.count,300);XCTAssertNil(row["item_id"])}
        XCTAssertEqual(try f.rows("attachment").count,1)
        let before = try f.allState();checks.checkError("MEDIA_CAPTURE_REQUIRED") {try f.publish(round)};XCTAssertEqual(try f.allState(),before)
        let original = png + Data("fixture-1".utf8);try original.write(to:URL(fileURLWithPath:sources[0]["path"] as! String))
        intake = try capture(f,intake)
        XCTAssertEqual(strings(intake,"committed_row_ids").count,2);XCTAssertEqual(strings(intake,"remaining_row_ids").count,1)
        XCTAssertEqual(try f.rows("attachment").count,2)
    }
    func testExplicitSlotsDuplicateGroupingAndPastedExactLinesAndTSV() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema(twoSlots:true)))
        let one = try source(f,"same-1.png",1),two = try source(f,"same-2.png",1)
        var intake = try preview(f,round,[one,two]),rows = intake["rows"] as! [JSON]
        XCTAssertTrue(rows.allSatisfy {$0["disposition"] as? String == "unresolved"})
        intake = try resolve(f,intake,rows.map {["row_id":$0["id"]!,"slot_id":"image","group_id":"explicit-takes","disposition":"include"]})
        let groups = intake["groups"] as! [JSON];XCTAssertEqual(groups.count,1)
        XCTAssertEqual(groups[0]["title"] as? String,rows[0]["title"] as? String)
        intake = try capture(f,confirm(f,intake),Array(strings(intake,"remaining_row_ids").reversed().prefix(1)))
        XCTAssertEqual(try f.rows("media_item").count,1)
        intake = try resolve(f,intake,[["row_id":strings(intake,"remaining_row_ids")[0],"disposition":"include","title":"New source label in revised plan"]])
        XCTAssertEqual((intake["groups"] as! [JSON])[0]["title"] as? String,groups[0]["title"] as? String)
        intake = try capture(f,confirm(f,intake));XCTAssertEqual(try f.rows("media_item").count,1)
        let item = try f.rows("media_item")[0],target = try f.record(item["draft_target_id"] as! String,"media_item_target")
        XCTAssertEqual(strings(target,"candidate_ids").count,2)
        XCTAssertEqual(item["title"] as? String,groups[0]["title"] as? String);XCTAssertEqual(int(item,"order"),int(groups[0],"order"))
        let published = try f.publish(round);XCTAssertEqual(((published["manifest"] as! JSON)["items"] as! [JSON]).count,1)
        let textRound = try f.round(f.type(checks.schema()))
        var pasted = try f.call("media_intake_preview",["round_id":textRound["id"]!,"text":" e\u{301}\r\n\n=literal\n"],as:f.worker)
        pasted = try capture(f,confirm(f,pasted));XCTAssertEqual(strings(pasted,"committed_row_ids").count,2)
        let candidateTexts = try f.rows("media_candidate").flatMap {$0["slots"] as! [JSON]}.compactMap {$0["text"] as? String}
        XCTAssertTrue(candidateTexts.contains(" e\u{301}\r"));XCTAssertTrue(candidateTexts.contains("=literal"))
        let tsvRound = try f.round(f.type(checks.schema()))
        let tsv = try f.call("media_intake_preview",["round_id":tsvRound["id"]!,"tsv":"title\ttext\tgroup\nStory\ttake one\tg\nStory\ttake two\tg\n"],as:f.worker)
        _ = try capture(f,confirm(f,tsv));XCTAssertEqual(((try f.get(tsvRound))["items"] as! [JSON]).count,1)
    }
    private static func publicationPhase(published: Bool) -> TestStore.Template {
        TestStore.Template(name:"media-frozen-publication-" + (published ? "published" : "captured")) {router,workspace in
            let checks = MediaFrozenIntakeTests(),f = try Fixture(router:router,workspace:workspace)
            let round = try f.round(f.type(checks.imageSchema()))
            let intake = try checks.capture(f,checks.confirm(f,checks.preview(f,round,[checks.source(f,"original.png",1)])))
            if published { _ = try f.publish(round) }
            try router.dbQueue.write {db in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('test-media-publication-intake',?)",arguments:[try jsonString(intake)])
            }
        }
    }
    private static let capturedPublicationPhase = publicationPhase(published:false)
    private static let publishedPublicationPhase = publicationPhase(published:true)

    func testPublicationRollsBackAtEveryHandoverManifestAndReceiptStep() throws {
        let points = [
            ("INSERT","records","NEW.type='storage_job' AND json_extract(NEW.data,'$.owner_kind')='media_target'"),
            ("INSERT","records","NEW.type='storage_hold'"),
            ("UPDATE","records","NEW.type='storage_hold' AND json_extract(NEW.data,'$.state')='released'"),
            ("INSERT","records","NEW.type='media_item_target'"),
            ("INSERT","records","NEW.type='media_round_manifest'"),
            ("UPDATE","records","NEW.type='media_round'"),
            ("INSERT","events","1"),("INSERT","commands","1")
        ]
        for (operation,table,condition) in points {
            // The released-hold trigger needs prepublication; every other point
            // starts from an earlier publication, as before. Only setup is cloned.
            let unpublished = operation == "UPDATE" && condition.contains("storage_hold")
            let f = try Fixture(template:unpublished ? Self.capturedPublicationPhase : Self.publishedPublicationPhase)
            let round = try XCTUnwrap(f.rows("media_round").first)
            let intake = try f.router.dbQueue.read {db in
                try jsonObject(XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='test-media-publication-intake'")))
            }
            XCTAssertEqual(strings(intake,"committed_row_ids").count,1)
            let observed = try f.get(round),before = try f.allState()
            try f.router.dbQueue.write {try $0.execute(sql:"CREATE TRIGGER media_fail BEFORE \(operation) ON \(table) WHEN \(condition) BEGIN SELECT RAISE(ABORT,'publication interruption'); END")}
            var params = f.observation(observed);params["items"] = f.selection(observed,publish:true)
            XCTAssertThrowsError(try f.call("media_round_publish",params),"\(operation) \(table) \(condition)")
            XCTAssertEqual(try f.allState(),before,"\(operation) \(table) \(condition)")
            try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_fail")}
            let command = uuid(),published = try f.call("media_round_publish",params,command:command)
            let replay = try f.call("media_round_publish",params,command:command)
            XCTAssertEqual((published["manifest"] as! JSON)["digest"] as? String,(replay["manifest"] as! JSON)["digest"] as? String)
            XCTAssertEqual(replay["replayed"] as? Bool,true)
        }
    }
    func testCaptureInterruptedReceiptRecoversFinalizedBytesWithOriginalRowUUID() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        let file = try source(f,"lost-source.png",1)
        let intake = try confirm(f,preview(f,round,[file])),params = captureParams(intake),command = uuid()
        let row = (intake["rows"] as! [JSON])[0],originalImport = row["import_command_id"] as! String
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TRIGGER media_fail BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'receipt interruption'); END")}
        XCTAssertThrowsError(try f.call("media_intake_capture",params,as:f.worker,command:command))
        XCTAssertTrue(try f.rows("media_item").isEmpty);XCTAssertTrue(try f.rows("attachment").isEmpty)
        XCTAssertEqual((try get(f,intake)["rows"] as! [JSON])[0]["capture_state"] as? String,"uncommitted")
        let ownerJobs = try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"}
        XCTAssertEqual(ownerJobs.count,1);XCTAssertEqual(ownerJobs[0]["parent_command_id"] as? String,originalImport);XCTAssertEqual(ownerJobs[0]["state"] as? String,"finalized")
        try FileManager.default.removeItem(atPath:file["path"] as! String)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_fail")}
        try f.reopen()
        var changed = params;changed["row_ids"] = [String]()
        checks.checkError("IDEMPOTENCY_CONFLICT") {try f.call("media_intake_capture",changed,as:f.worker,command:command)}
        let resumed = try f.call("media_intake_capture",params,as:f.worker,command:command)
        XCTAssertEqual(strings(resumed,"committed_row_ids"),[row["id"] as! String])
        XCTAssertEqual((resumed["rows"] as! [JSON])[0]["import_command_id"] as? String,originalImport)
        XCTAssertEqual(try f.rows("attachment").count,1)
        let jobs = try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"};XCTAssertEqual(jobs[0]["state"] as? String,"committed")
        _ = try f.call("media_intake_capture",params,as:f.worker,command:command);XCTAssertEqual(try f.rows("attachment").count,1)
    }
    func testPublicationRequiresCompleteIncludedSetCurrentContextAndUnchangedManagedOriginal() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        _ = try capture(f,confirm(f,preview(f,round,[source(f,"one.png",1),source(f,"two.png",2)])))
        var observed = try f.get(round),params = f.observation(observed)
        params["items"] = Array(f.selection(observed,publish:true).prefix(1))
        let before = try f.allState();checks.checkError("MEDIA_CAPTURE_REQUIRED") {try f.call("media_round_publish",params)};XCTAssertEqual(try f.allState(),before)
        params["items"] = f.selection(observed,publish:true)
        _ = try f.call("media_context_approve",["kind":"direction","body":"No flashing","round_id":round["id"]!])
        let attention = try f.allState();checks.checkError("MEDIA_CONTEXT_CHANGED") {try f.call("media_round_publish",params)};XCTAssertEqual(try f.allState(),attention)
        _ = try f.reconcile(round);observed = try f.get(round);params = f.observation(observed);params["items"] = f.selection(observed,publish:true);params["command_id"] = uuid();params["project_id"] = f.project
        let resources = try f.router.prepareMediaResources(method:"media_round_publish",params:params,caller:f.owner)
        let prepared = try XCTUnwrap(f.router.prepareMediaCommand(method:"media_round_publish",params:params,caller:f.owner,resources:resources))
        defer {try? prepared.observer.close()}
        XCTAssertEqual(resources.originals.count,2)
        let original = try f.router.managedURL(resources.originals[0].attachment["path"] as! String,family:"objects").path
        try Data([1,2,3]).write(to:URL(fileURLWithPath:original))
        let prior = try f.allState()
        try ArchiveStorageGate.withExclusive(root:f.root) {_ in try f.router.dbQueue.write {db in
            checks.checkError("MANAGED_ORIGINAL_UNAVAILABLE") {try prepared.commit(db,router:f.router,caller:f.owner)}
        }}
        XCTAssertEqual(try f.allState(),prior);XCTAssertTrue(try f.rows("media_round_manifest").isEmpty)
        checks.checkError("SOURCE_CHANGED") {try f.publish(round)}
    }
    func testBoundedInputsAuthorizationAndPublicDispatchStayClosed() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        checks.checkError("INVALID_INPUT") {try preview(f,round,[])}
        checks.checkError("INVALID_INPUT") {try f.call("media_intake_preview",["round_id":round["id"]!,"text":"one","sources":[["path":"/missing"]]])}
        let intake = try preview(f,round,[source(f,"real.png",1)])
        var p = captureParams(intake)
        checks.checkError("MEDIA_PLAN_REQUIRED") {try f.call("media_intake_capture",p,as:f.worker)}
        let confirmed = try confirm(f,intake);p = captureParams(confirmed,Array(repeating:strings(confirmed,"remaining_row_ids")[0],count:201))
        checks.checkError("INVALID_INPUT") {try f.call("media_intake_capture",p,as:f.worker)}
        let before = try f.allState()
        XCTAssertThrowsError(try f.router.handle(method:"media_intake_preview",params:["project_id":f.project,"round_id":round["id"]!,"sources":[]],caller:f.worker))
        XCTAssertEqual(try f.allState(),before)
        let assistant = Caller(role:"assistant",installation:"not-a-worker",projectIDs:[f.project])
        checks.checkError("FORBIDDEN") {try f.call("media_intake_get",["intake_id":intake["id"]!],as:assistant)}
    }
    func testPartialIntakeExportAndBackupKeepExactPlansRowsReceiptsAndOwnedBytes() throws {
        let f = try Fixture(),round = try f.round(f.type(imageSchema()))
        var intake = try confirm(f,preview(f,round,[source(f,"one.png",1),source(f,"two.png",2)]))
        intake = try capture(f,intake,Array(strings(intake,"remaining_row_ids").prefix(1)))
        let export = f.base.appendingPathComponent("export"),backup = f.base.appendingPathComponent("backup")
        _ = try f.router.handle(method:"export_project",params:["command_id":uuid(),"project_id":f.project,"path":export.path],caller:f.owner)
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        for family in ["media_intake","media_intake_plan","media_intake_row","media_intake_chunk"] {
            let saved = try f.rows(family),captured = json[family] as! [JSON]
            XCTAssertEqual(Set(try saved.map {Data(try jsonString($0).utf8)}),Set(try captured.map {Data(try jsonString($0).utf8)}))
        }
        XCTAssertEqual((json["attachment"] as! [JSON]).count,1)
        XCTAssertEqual((json["media_capture"] as! JSON)["staging_bytes_included"] as? Bool,false)
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copied = try DatabaseQueue(path:backup.appendingPathComponent("database.sqlite").path,configuration:config)
        defer {try? copied.close()}
        let envelopes = try copied.read {try MediaRecordRegistry.envelopes($0)};try MediaRecordRegistry.validate(envelopes)
        let rows = envelopes.filter {$0.type == "media_intake_row"}.map(\.object)
        XCTAssertEqual(rows.filter {$0["capture_state"] as? String == "committed"}.count,1)
        XCTAssertEqual(rows.filter {$0["capture_state"] as? String == "uncommitted"}.count,1)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:backup.appendingPathComponent("manifest.json")))
        let attachment = try f.rows("attachment")[0]
        XCTAssertTrue(manifest.objects.contains {$0.descriptor.authorities.contains("attachment:" + (attachment["id"] as! String) + ":original")})
    }
    func testClosedByteCapabilitiesRejectRemotePlaylistsAndMalformedMappings() throws {
        let f = try Fixture(),schema: JSON = ["schema_version":1,"id":"server","name":"Audio","slots":[["id":"audio","kind":"audio","required":true]],"layout":["kind":"audio_compare","primary_slot_id":"audio"]]
        let round = try f.round(f.type(schema))
        var wav = Data("RIFF".utf8)
        func word(_ value: UInt16) {wav.append(UInt8(value & 255));wav.append(UInt8(value >> 8))}
        func dword(_ value: UInt32) {word(UInt16(value & 65535));word(UInt16(value >> 16))}
        dword(38);wav.append(Data("WAVEfmt ".utf8));dword(16);word(1);word(1);dword(8000);dword(16000);word(2);word(16);wav.append(Data("data".utf8));dword(2);word(0)
        XCTAssertTrue(MediaIntakeWAV.validate(wav));XCTAssertFalse(MediaIntakeWAV.validate(wav.dropLast()))
        let path = f.workspace.appendingPathComponent("exact.wav");try wav.write(to:path)
        let intake = try preview(f,round,[["path":path.path]])
        XCTAssertEqual((intake["rows"] as! [JSON])[0]["media_kind"] as? String,"audio")
        _ = try capture(f,confirm(f,intake));_ = try f.publish(round)
        let playlist = f.workspace.appendingPathComponent("remote.m3u");try Data("https://example.invalid/source.mp4".utf8).write(to:playlist)
        let unsupported = try preview(f,round,[["path":playlist.path]])
        XCTAssertEqual((unsupported["rows"] as! [JSON])[0]["status"] as? String,"unsupported")
        checks.checkError("INVALID_INPUT") {try preview(f,round,[["path":path.path,"columns":["title":42]]])}
        checks.checkError("INVALID_INPUT") {try f.call("media_intake_preview",["round_id":round["id"]!,"text":"one","mapping":"invalid"])}
        checks.checkError("INVALID_INPUT") {try f.call("media_intake_preview",["round_id":round["id"]!,"tsv":"text\ttext\none\ttwo\n"])}
    }

    func testFiniteFieldMappingRevisionKeepsCommittedRowsAndByteExactGroups() throws {
        let f = try Fixture(),field = checks.field("character",required:true)
        var schema = imageSchema();schema["fields"] = [field,checks.field("source",kind:"number",material:false)]
        let round = try f.round(f.type(schema))
        let sources = try [source(f,"hero__walk.png",1),source(f,"hero__run.png",2),source(f,"hero__idle.png",3)]
        func mapping(_ index: Int) -> JSON {["input":"selected_files","assignments":[["field_id":"character","source":["kind":"stem_token","delimiter":"__","index":index]],["field_id":"source","source":["kind":"source_index"]]]]}
        var intake = try f.call("media_intake_preview",["round_id":round["id"]!,"sources":sources,"mapping":mapping(0)],as:f.worker)
        XCTAssertTrue((intake["rows"] as! [JSON]).allSatisfy {($0["metadata"] as! JSON)["character"] as? String == "hero"})
        for row in intake["rows"] as! [JSON] {XCTAssertEqual(int(row["metadata"] as! JSON,"source"),int(row,"source_index"))}
        intake = try capture(f,confirm(f,intake),Array(strings(intake,"remaining_row_ids").prefix(1)))
        let original = (intake["rows"] as! [JSON]).first {$0["capture_state"] as? String == "committed"}!
        intake = try resolve(f,intake,[],mapping:mapping(1))
        XCTAssertEqual(try jsonString((intake["rows"] as! [JSON]).first {$0["id"] as? String == original["id"] as? String}!),try jsonString(original))
        let remaining = strings(intake,"remaining_row_ids")
        // Canonically equivalent Unicode spellings are distinct explicit group IDs.
        intake = try resolve(f,intake,[["row_id":remaining[0],"disposition":"include","group_id":"é"],["row_id":remaining[1],"disposition":"include","group_id":"e\u{301}"]])
        XCTAssertEqual((intake["groups"] as! [JSON]).count,3)
        intake = try capture(f,confirm(f,intake))
        XCTAssertEqual(strings(intake,"committed_row_ids").count,3);XCTAssertEqual(try f.rows("media_item").count,3)
        XCTAssertEqual(try f.rows("attachment").count,3)
        XCTAssertEqual(try jsonString((intake["rows"] as! [JSON]).first {$0["id"] as? String == original["id"] as? String}!),try jsonString(original))
    }

}
