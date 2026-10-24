import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

final class ImageInspectionTests: XCTestCase {
    let sha = String(repeating: "a", count: 64)
    func testInspectionRequiresEveryExactImageAndRejectsOtherTargets() throws {
        let a = ImageInspectionIdentity(artifactID: "front", sha256: sha, targetManifestID: "round2")
        let b = ImageInspectionIdentity(artifactID: "rear", sha256: sha, targetManifestID: "round2")
        XCTAssertThrowsError(try ImageInspectionIdentity.validated(nil, expected: [a, b], requireComplete: true))
        XCTAssertThrowsError(try ImageInspectionIdentity.validated([a.record], expected: [a, b], requireComplete: true))
        XCTAssertEqual(try ImageInspectionIdentity.validated([a.record, b.record], expected: [a, b], requireComplete: true), [a, b])
        XCTAssertEqual(try ImageInspectionIdentity.validated([a.record], expected: [a, b], requireComplete: false), [a])
        XCTAssertThrowsError(try ImageInspectionIdentity.validated([a.record, a.record], expected: [a, b], requireComplete: false))
        let old = ImageInspectionIdentity(artifactID: "front", sha256: sha, targetManifestID: "round1")
        XCTAssertThrowsError(try ImageInspectionIdentity.validated([old.record], expected: [a], requireComplete: true))
        let changed = ImageInspectionIdentity(artifactID: "front", sha256: String(repeating: "b", count: 64), targetManifestID: "round2")
        XCTAssertThrowsError(try ImageInspectionIdentity.validated([changed.record], expected: [a], requireComplete: false))
    }
    func testOpaqueIdentityAndViewNamesAreByteExact() {
        XCTAssertNotEqual(ImageInspectionIdentity(artifactID: "é", sha256: sha, targetManifestID: "round"), ImageInspectionIdentity(artifactID: "e\u{301}", sha256: sha, targetManifestID: "round"))
        XCTAssertEqual(ImageViewName.resolve(filename: "front-round2.png"), "front")
        XCTAssertEqual(ImageViewName.resolve(filename: "rear_r12.gif"), "rear")
        XCTAssertEqual(ImageViewName.resolve(filename: "inside-v2.png"), "inside")
        XCTAssertEqual(ImageViewName.resolve(filename: "front-v2.png", explicit: "corner"), "corner")
    }
    func testSpriteFramesUseWholePixelsAndRejectInvalidGrids() throws {
        let grid = try SpriteSheetLayout(columns: 4, rows: 2, frameCount: 7, framesPerSecond: 12)
        XCTAssertEqual(try grid.frameRect(index: 0, width: 64, height: 32), CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(try grid.frameRect(index: 5, width: 64, height: 32), CGRect(x: 16, y: 16, width: 16, height: 16))
        XCTAssertThrowsError(try grid.frameRect(index: 7, width: 64, height: 32))
        XCTAssertThrowsError(try grid.frameRect(index: 2, width: 63, height: 32))
        for (columns, rows) in [(0, 1), (1, 0), (32, 32), (Int.max, 2)] { XCTAssertThrowsError(try SpriteSheetLayout(columns: columns, rows: rows)) }
        XCTAssertThrowsError(try SpriteSheetLayout(columns: 2, rows: 2, frameCount: 5))
        XCTAssertThrowsError(try SpriteSheetLayout(columns: 2, rows: 2, framesPerSecond: .infinity))
        XCTAssertThrowsError(try SpriteSheetLayout.parse(["columns": true, "rows": 2]))
        XCTAssertThrowsError(try SpriteSheetLayout.parse(["columns": 2.5, "rows": 2]))
        XCTAssertThrowsError(try SpriteSheetLayout.parse(["columns": 2, "rows": 2, "frames_per_second": true]))
    }
    func testHumanApprovalRecordsAllMarksAndReadAloneCannotApprove() throws {
        let fixture = try ImageInspectionServiceFixture()
        defer { fixture.close() }
        let (project, ticket, submission, request, images) = try fixture.submission()
        var params = try fixture.answerParameters(project: project, ticket: ticket, request: request, images: images)
        // An authorized preview read has no verdict or status authority.
        let read = try fixture.call("attachment_read", ["project_id": project["id"]!, "attachment_id": images[0]["id"]!, "representation": "original"])
        if let hold = read["read_hold_id"] { _ = try fixture.call("attachment_read_release", ["project_id": project["id"]!, "read_hold_id": hold]) }
        XCTAssertThrowsError(try fixture.call("human_request_answer", params)) { XCTAssertEqual(($0 as? CoreError)?.code, "IMAGE_INSPECTION_REQUIRED") }
        let marks = images.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "target_manifest_id": submission["manifest_id"]!] }
        params["inspected_images"] = [marks[0]]
        XCTAssertThrowsError(try fixture.call("human_request_answer", params))
        params["inspected_images"] = marks
        let answered = try fixture.call("human_request_answer", params)
        XCTAssertEqual(answered["gate_outcome"] as? String, "pass")
        XCTAssertEqual(((answered["responses"] as! [JSON]).last!["inspected_images"] as! [JSON]).count, 2)
        let review = try fixture.router.dbQueue.read { try fixture.router.record($0, answered["gate_verdict_id"] as! String, type: "review") }
        XCTAssertEqual((review["inspected_images"] as! [JSON]).count, 2)
        XCTAssertTrue((review["inspected_images"] as! [JSON]).allSatisfy { $0["target_manifest_id"] as? String == submission["manifest_id"] as? String })
    }
    func testMissingOriginalCannotBeApprovedEvenWithEarlierMarks() throws {
        let fixture = try ImageInspectionServiceFixture()
        defer { fixture.close() }
        let (project, ticket, submission, request, images) = try fixture.submission()
        var params = try fixture.answerParameters(project: project, ticket: ticket, request: request, images: images)
        params["inspected_images"] = images.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "target_manifest_id": submission["manifest_id"]!] }
        try FileManager.default.removeItem(atPath: images[1]["path"] as! String)
        XCTAssertThrowsError(try fixture.call("human_request_answer", params))
        let current = try fixture.call("task_get", ["project_id": project["id"]!, "task_id": ticket["id"]!])
        XCTAssertNotEqual(current["status_category"] as? String, "done")
        let stored = try fixture.router.dbQueue.read { try fixture.router.record($0, request["id"] as! String, type: "request") }
        XCTAssertEqual(stored["state"] as? String, "pending"); XCTAssertNil(stored["gate_verdict_id"])
    }
    func testRequestContextContainsAllImagesAndAnExactPreviousRound() throws {
        let fixture = try ImageInspectionServiceFixture()
        defer { fixture.close() }
        let (project, ticket, submission, request, _) = try fixture.submission()
        let context = try fixture.router.dbQueue.read { db -> JSON in
            let task = try fixture.router.record(db, ticket["id"] as! String, type: "task")
            return try fixture.router.requestImageReviewContext(db, request: request, task: task, caller: fixture.owner)
        }
        XCTAssertEqual(context["manifest_id"] as? String, submission["manifest_id"] as? String)
        XCTAssertEqual((context["images"] as! [JSON]).count, 2)
        XCTAssertEqual((context["images"] as! [JSON]).map { $0["view_name"] as! String }, ["front", "rear"])
        XCTAssertNil(context["previous_manifest_id"])
        let catalog = fixture.router.toolCatalog(Caller(role: "worker", installation: "fixture", projectIDs: [project["id"] as! String]))
        let record = catalog.first { $0["name"] as? String == "review_record" }!
        XCTAssertNotNil(((record["inputSchema"] as! JSON)["properties"] as! JSON)["inspected_images"])
    }
    func testNonImageApprovalKeepsItsExistingAnswerPath() throws {
        let fixture = try ImageInspectionServiceFixture(); defer { fixture.close() }
        let (project, ticket, _, request, files) = try fixture.submission(fileExtension: "txt")
        let params = try fixture.answerParameters(project: project, ticket: ticket, request: request, images: files)
        let result = try fixture.call("human_request_answer", params)
        XCTAssertEqual(result["gate_outcome"] as? String, "pass")
        XCTAssertTrue(((result["responses"] as! [JSON]).last!["inspected_images"] as! [JSON]).isEmpty)
    }
    func testPreviousSubmissionAndOldMarksRemainSeparateAfterRework() throws {
        let fixture = try ImageInspectionServiceFixture(); defer { fixture.close() }
        let (project, ticket, first, request, files) = try fixture.submission()
        var reject = try fixture.answerParameters(project: project, ticket: ticket, request: request, images: files)
        reject["answers"] = [["question_id": "approve", "result": "changes_requested"]]
        _ = try fixture.call("human_request_answer", reject)
        let task = try fixture.call("task_get", ["project_id": project["id"]!, "task_id": ticket["id"]!])
        let attempt = try fixture.call("work_claim", ["project_id": project["id"]!, "task_id": task["id"]!, "expected_revision": task["revision"]!])
        let refs = files.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "view_name": ImageViewName.resolve(filename: $0["name"] as! String)] }
        let next = try fixture.call("work_submit", ["project_id": project["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "acceptance_revision": 1, "evidence_manifest": ["artifact_refs": refs]])
        let nextRequest = try fixture.call("human_request_create", ["project_id": project["id"]!, "task_id": task["id"]!, "supersedes_answer_id": request["id"]!, "supersede_reason": "A new submitted manifest requires fresh image inspection after requested changes.", "target_attachment_id": files[0]["id"]!, "questions": [["id": "approve", "type": "approval", "prompt": "Inspect the next exact target"]]])
        let context = try fixture.router.dbQueue.read { db in try fixture.router.requestImageReviewContext(db, request: nextRequest, task: task, caller: fixture.owner) }
        XCTAssertEqual(context["previous_manifest_id"] as? String, first["manifest_id"] as? String)
        XCTAssertEqual((context["previous_images"] as! [JSON]).count, 2)
        var approve = try fixture.answerParameters(project: project, ticket: ticket, request: nextRequest, images: files)
        approve["inspected_images"] = files.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "target_manifest_id": first["manifest_id"]!] }
        XCTAssertThrowsError(try fixture.call("human_request_answer", approve)) { XCTAssertEqual(($0 as? CoreError)?.code, "IMAGE_INSPECTION_REQUIRED") }
        approve["inspected_images"] = files.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "target_manifest_id": next["manifest_id"]!] }
        XCTAssertEqual(try fixture.call("human_request_answer", approve)["gate_outcome"] as? String, "pass")
    }
    func testAgentVerdictRequiresAndStoresItsOwnInspectionSelections() throws {
        let fixture = try ImageInspectionServiceFixture(); defer { fixture.close() }
        let (project, ticket, submission, _, files) = try fixture.submission(gates: ["review"])
        let sid = UUID().uuidString, pid = project["id"] as! String
        let workspace = project["root_path"] as! String
        _ = try fixture.call("session_register", ["project_id": pid, "session_id": sid, "installation": "synthetic-critic", "provider": "codex", "role": "worker", "workspace": workspace, "execution_domain": "synthetic-critic-host"])
        let critic = Caller(role: "worker", installation: "synthetic-critic", projectIDs: [pid], sessionID: sid, workspace: workspace, executionDomain: "synthetic-critic-host")
        let current = try fixture.call("task_get", ["project_id": pid, "task_id": ticket["id"]!])
        let rid = (submission["review_request_ids"] as! [String])[0]
        let attempt = try fixture.call("work_claim", ["project_id": pid, "task_id": ticket["id"]!, "expected_revision": current["revision"]!, "phase": "review", "review_request_id": rid, "target_manifest_id": submission["manifest_id"]!, "gate": "review"], critic)
        let reportURL = URL(fileURLWithPath: workspace).appendingPathComponent("synthetic-review.md")
        try Data("Synthetic component-test review report. This does not qualify any installed app or live review.".utf8).write(to: reportURL)
        let evidence = try fixture.call("attachment_add", ["project_id": pid, "task_id": ticket["id"]!, "path": reportURL.path], critic)
        let manifest = try fixture.router.dbQueue.read { try fixture.router.record($0, submission["manifest_id"] as! String, type: "manifest") }
        let claimedTask = try fixture.router.dbQueue.read { try fixture.router.record($0, ticket["id"] as! String, type: "task") }
        var input: JSON = ["project_id": pid, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "review_request_id": rid, "target_manifest_id": submission["manifest_id"]!, "gate": "review", "verdict": "pass", "checks": [], "review_assessment": try fixtureReviewAssessment(fixture.router, task: claimedTask, manifest: manifest, artifact: evidence)]
        XCTAssertThrowsError(try fixture.call("review_record", input, critic)) { XCTAssertEqual(($0 as? CoreError)?.code, "IMAGE_INSPECTION_REQUIRED") }
        input["inspected_images"] = files.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "target_manifest_id": submission["manifest_id"]!] }
        let draft = try fixture.call("review_draft_save", input, critic)
        XCTAssertEqual((((draft["draft_verdict"] as! JSON)["params"] as! JSON)["inspected_images"] as! [JSON]).count, 2)
        let verdict = try fixture.call("review_record", input, critic)
        XCTAssertEqual((verdict["inspected_images"] as! [JSON]).count, 2)
        XCTAssertEqual(verdict["actor"] as? String, critic.principal)
    }
}

private final class ImageInspectionServiceFixture {
    let root: URL
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "synthetic-image-inspection", projectIDs: [])
    init() throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let parent = caches.resolvingSymlinksInPath().appendingPathComponent("ChecklistQualification/ImageInspection", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        root = parent.appendingPathComponent("Synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        router = try TestStore.router(root: root.appendingPathComponent("store"))
    }
    func close() { router = nil; try? FileManager.default.removeItem(at: root) }
    @discardableResult func call(_ method: String, _ values: JSON, _ caller: Caller? = nil) throws -> JSON {
        var params = values
        if !CommandRouter.readMethods.contains(method) { params["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: fixtureTaskInput(router,method:method,input:params), caller: caller ?? owner)["data"] as! JSON
    }
    func submission(fileExtension: String = "png", gates: [String] = ["human_approval"]) throws -> (JSON, JSON, JSON, JSON, [JSON]) {
        let workspace = root.appendingPathComponent("workspace"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var p = try call("project_create", ["name": "Synthetic image inspection", "key_prefix": "SYN", "root_path": workspace.path])
        p = try call("policy_apply", ["project_id": p["id"]!, "expected_revision": p["revision"]!, "policy": ["routing_preset": "shared", "required_gates": gates]])
        var t = try call("task_create", ["project_id": p["id"]!, "title": "Synthetic candidate views", "kind": "asset", "brief": "Inspect both exact originals"])
        t = try call("task_edit", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!, "patch": ["readiness": "ready"]])
        let attempt = try call("work_claim", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!])
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
        var images: [JSON] = []
        for view in ["front", "rear"] {
            let file = workspace.appendingPathComponent(view + "-round2." + fileExtension); try (fileExtension == "png" ? png : Data("Synthetic text candidate".utf8)).write(to: file)
            images.append(try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": file.path]))
        }
        let refs = images.map { ["artifact_id": $0["id"]!, "sha256": $0["sha256"]!, "view_name": ImageViewName.resolve(filename: $0["name"] as! String)] }
        let submitted = try call("work_submit", ["project_id": p["id"]!, "attempt_id": attempt["id"]!, "claim_token": attempt["claim_token"]!, "acceptance_revision": 1, "evidence_manifest": ["artifact_refs": refs]])
        let request: JSON = gates.contains("human_approval") ? try call("human_request_create", ["project_id": p["id"]!, "task_id": t["id"]!, "target_attachment_id": images[0]["id"]!, "questions": [["id": "approve", "type": "approval", "prompt": "Inspect both candidate views"]]]) : [:]
        return (p, t, submitted, request, images)
    }
    func answerParameters(project: JSON, ticket: JSON, request: JSON, images: [JSON]) throws -> JSON {
        let context = try call("task_context", ["project_id": project["id"]!, "task_id": ticket["id"]!])
        return ["project_id": project["id"]!, "request_id": request["id"]!, "expected_revision": request["revision"]!, "expected_task_revision": (context["task"] as! JSON)["revision"]!, "direction_cursor": context["direction_cursor"]!, "target_sha256": images[0]["sha256"]!, "form_identity": request["form_identity"]!, "answers": [["question_id": "approve", "result": "approved"]]]
    }
}

extension ImageInspectionTests {
    func testOwnerWorkspaceRecordLoadsExactImageReviewContext() throws {
        let fixture = try ImageInspectionServiceFixture(); defer { fixture.close() }
        let (project, _, submission, request, _) = try fixture.submission()
        let result = try fixture.call("workspace_page", ["project_id":project["id"]!, "surface":"record", "record_id":request["id"]!])
        let row = try XCTUnwrap((result["rows"] as? [JSON])?.first)
        let review = try XCTUnwrap(row["image_review"] as? JSON)
        XCTAssertEqual(review["manifest_id"] as? String, submission["manifest_id"] as? String)
        XCTAssertEqual((review["images"] as? [JSON])?.count, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }
}
