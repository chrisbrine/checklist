import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func currentRelationTask(_ p: JSON, _ t: JSON) throws -> JSON { try call("task_get", ["project_id": p["id"]!, "task_id": t["id"]!]) }
    @discardableResult func link(_ p: JSON, _ source: JSON, _ target: JSON, _ kind: String = "depends_on", required: Bool = true) throws -> JSON {
        let current = try currentRelationTask(p, source)
        return try call("task_link", ["project_id": p["id"]!, "task_id": source["id"]!, "expected_revision": current["revision"]!, "target_task_id": target["id"]!, "relation": kind, "required": required])
    }
    func completeRelationFixture(_ p: JSON, _ t: JSON) throws -> JSON {
        let current = try currentRelationTask(p, t)
        let readyTask = current["readiness"] as? String == "ready" ? current : try ready(p, current)
        let claim = try call("work_claim", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": readyTask["revision"]!])
        let submission = try submitTriageArtifact(p, readyTask, claim)
        let submitted = submission["task"] as! JSON
        return try call("task_complete", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": submitted["revision"]!])
    }

    func testRelationsAreScopedAndRejectAllCyclesAtomically() throws {
        let p = try project(), foreign = try project("Other"), a = try task(p), b = try task(p), c = try task(p), other = try task(foreign)
        assertCode("NOT_FOUND") { _ = try self.link(p, a, other) }
        for kind in ["depends_on", "parent_child", "duplicate_of"] {
            let first = try task(p, kind + " first"), second = try task(p, kind + " second"), third = try task(p, kind + " third")
            try link(p, first, second, kind); try link(p, second, third, kind)
            let before = try call("snapshot")
            assertCode("RELATION_CYCLE") { _ = try self.link(p, third, first, kind) }
            let after = try call("snapshot")
            for key in ["tasks", "relations", "task_aliases", "events"] { XCTAssertEqual(try jsonString(["rows": before[key]!]), try jsonString(["rows": after[key]!]), key) }
        }
        try link(p, a, b, "related_to")
        assertCode("RELATION_EXISTS") { _ = try self.link(p, b, a, "related_to") }
        try link(p, b, c, "follow_up_of")
        XCTAssertEqual((try call("relation_list", ["project_id": p["id"]!, "task_id": c["id"]!])["relations"] as! [JSON]).count, 1)
    }

    func testRequiredPrerequisitesGuardClaimAndCompletionAndTrackReopenCancel() throws {
        var p = try project(); p = try call("policy_apply", ["project_id": p["id"]!, "expected_revision": p["revision"]!, "policy": ["required_gates": []]])
        let prerequisite = try task(p), dependent = try ready(p, task(p))
        try link(p, dependent, prerequisite)
        var blocked = try currentRelationTask(p, dependent)
        XCTAssertFalse(bool(blocked, "pickup_eligible")); XCTAssertFalse(bool(blocked, "prerequisites_satisfied")); XCTAssertTrue((blocked["blocked_reason"] as! String).contains(prerequisite["key"] as! String))
        // Ready means a refined brief; an open prerequisite never blocks it (CL-133). Claim and completion still wait.
        let refined = try task(p, "Refined dependent"); try link(p, refined, prerequisite)
        let refinedDraft = try currentRelationTask(p, refined)
        XCTAssertEqual(refinedDraft["effective_readiness"] as? String, "draft")
        let refinedReady = try ready(p, refinedDraft)
        XCTAssertEqual(refinedReady["readiness"] as? String, "ready"); XCTAssertEqual(refinedReady["effective_readiness"] as? String, "blocked")
        XCTAssertFalse(bool(refinedReady, "pickup_eligible")); XCTAssertTrue(bool(refinedReady, "queue_eligible"))
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("work_claim", ["project_id": p["id"]!, "task_id": refined["id"]!, "expected_revision": refinedReady["revision"]!]) }
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("work_claim", ["project_id": p["id"]!, "task_id": dependent["id"]!, "expected_revision": blocked["revision"]!]) }
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete", ["project_id": p["id"]!, "task_id": dependent["id"]!, "expected_revision": blocked["revision"]!]) }
        // An ordinary metadata correction remains possible while eligibility is blocked.
        _ = try call("task_edit", ["project_id": p["id"]!, "task_id": dependent["id"]!, "expected_revision": blocked["revision"]!, "patch": ["title": "Clarified dependent"]])
        let done = try completeRelationFixture(p, prerequisite)
        XCTAssertTrue(bool(try currentRelationTask(p, dependent), "pickup_eligible"))
        let reopened = try call("task_transition", ["project_id": p["id"]!, "task_id": done["id"]!, "expected_revision": done["revision"]!, "action": "reopen", "reason": "Recheck prerequisite or duplicate scope"])
        XCTAssertFalse(bool(try currentRelationTask(p, dependent), "pickup_eligible"))
        _ = try call("task_transition", ["project_id": p["id"]!, "task_id": reopened["id"]!, "expected_revision": reopened["revision"]!, "action": "cancel", "reason": "Prerequisite scope no longer applies"])
        blocked = try currentRelationTask(p, dependent)
        XCTAssertFalse(bool(blocked, "prerequisites_satisfied")); XCTAssertTrue((blocked["blocked_reason"] as! String).contains("canceled"))
        let edge = (try call("relation_list", ["project_id": p["id"]!, "task_id": dependent["id"]!])["relations"] as! [JSON])[0]
        _ = try call("task_link", ["project_id": p["id"]!, "task_id": dependent["id"]!, "expected_revision": blocked["revision"]!, "action": "remove", "relation_id": edge["id"]!])
        XCTAssertTrue(bool(try currentRelationTask(p, dependent), "pickup_eligible"))
    }

    func testOptionalPrerequisiteDoesNotBlockAndFollowupNeverCompletesParent() throws {
        let p = try project(), original = try task(p), followup = try task(p)
        try link(p, followup, original, "follow_up_of")
        try link(p, followup, original, required: false)
        let result = try ready(p, currentRelationTask(p, followup))
        XCTAssertTrue(bool(result, "pickup_eligible"))
        XCTAssertEqual(try currentRelationTask(p, original)["status_category"] as? String, "queued")
        XCTAssertEqual(try currentRelationTask(p, original)["readiness"] as? String, "draft")
    }

    func testDuplicatePreservesContextAndFindingsRequiresExplicitReopen() throws {
        let value = try submittedArtifact(), p = value.project
        let reviewer = Caller(role: "owner", installation: "independent-relation-review", projectIDs: [])
        let rid = strings(value.submission, "review_request_ids")[0]
        let claim = try call("work_claim", ["project_id": p["id"]!, "task_id": value.task["id"]!, "expected_revision": value.task["revision"]!, "phase": "review", "review_request_id": rid, "target_manifest_id": value.submission["manifest_id"]!, "gate": "review"], reviewer)
        _ = try call("review_record", ["project_id": p["id"]!, "attempt_id": claim["id"]!, "claim_token": claim["claim_token"]!, "review_request_id": rid, "target_manifest_id": value.submission["manifest_id"]!, "gate": "review", "verdict": "reject", "findings": [["client_ref": "preserve-finding", "description": "Preserve this finding", "severity": "major"]]], reviewer)
        _ = try call("message_send", ["project_id": p["id"]!, "task_id": value.task["id"]!, "body": "Original context stays here"])
        let canonical = try task(p, value.task["title"] as! String)
        let before = try call("task_context", ["project_id": p["id"]!, "task_id": value.task["id"]!])
        let result = try link(p, value.task, canonical, "duplicate_of"), duplicate = result["task"] as! JSON
        XCTAssertEqual(duplicate["disposition"] as? String, "superseded"); XCTAssertEqual(duplicate["canonical_task_id"] as? String, canonical["id"] as? String)
        XCTAssertFalse(bool(duplicate, "pickup_eligible"))
        let after = try call("task_context", ["project_id": p["id"]!, "task_id": value.task["id"]!])
        for key in ["messages", "findings", "reviews"] { XCTAssertEqual(try jsonString(["rows": before[key]!]), try jsonString(["rows": after[key]!])) }
        let removed = try call("task_link", ["project_id": p["id"]!, "task_id": value.task["id"]!, "expected_revision": duplicate["revision"]!, "action": "remove", "relation_id": (result["relation"] as! JSON)["id"]!])["task"] as! JSON
        XCTAssertEqual(removed["disposition"] as? String, "superseded")
        assertCode("TASK_SUPERSEDED") { _ = try self.call("work_claim", ["project_id": p["id"]!, "task_id": removed["id"]!, "expected_revision": removed["revision"]!]) }
        let reopened = try call("task_transition", ["project_id": p["id"]!, "task_id": removed["id"]!, "expected_revision": removed["revision"]!, "action": "reopen", "reason": "Recheck prerequisite or duplicate scope"])
        XCTAssertEqual(reopened["disposition"] as? String, "open"); XCTAssertEqual(reopened["canonical_task_id"] as? String, reopened["id"] as? String)
        XCTAssertEqual((try call("task_context", ["project_id": p["id"]!, "task_id": reopened["id"]!])["findings"] as! [JSON]).count, 1)
        let originalAliases = (try call("relation_list", ["project_id": p["id"]!, "task_id": reopened["id"]!])["aliases"] as! [JSON])
        XCTAssertEqual(originalAliases.first?["state"] as? String, "retired")
    }

    func testDuplicateActiveWorkRejectedAndOrdinaryLinksRetainTriage() throws {
        let p = try project(), original = try ready(p, task(p)), canonical = try task(p), group = try triage(p)
        try addTriage(p, group, original)
        // CL-125 rule 6: the owner's claim keeps the ticket in this orchestrated Triage.
        try orchestrateTriage(p, group)
        try link(p, original, canonical, "related_to")
        XCTAssertEqual(strings(try currentTriage(p, group), "task_ids"), [original["id"] as! String])
        let current = try currentRelationTask(p, original)
        let claim = try call("work_claim", ["project_id": p["id"]!, "task_id": original["id"]!, "expected_revision": current["revision"]!])
        assertCode("CLAIM_CONFLICT") { _ = try self.link(p, original, canonical, "duplicate_of") }
        _ = try call("work_release", ["project_id": p["id"]!, "attempt_id": claim["id"]!, "claim_token": claim["claim_token"]!, "reason": "Fixture stopped"])
        XCTAssertEqual(strings(try currentTriage(p, group), "task_ids"), [original["id"] as! String])
        try link(p, original, canonical, "duplicate_of")
        try assertEmptyTriage(p, group)
    }

    func testRelationImportExportPreservesIDsAliasesAndUnresolvedReferences() throws {
        let p = try project(), source = try task(p), sameTitle = try task(p, source["title"] as! String)
        let edgeID = UUID().uuidString.lowercased(), aliasID = UUID().uuidString.lowercased()
        let currentProject = try call("project_settings_get", ["project_id": p["id"]!])
        let result = try call("relation_import", ["project_id": p["id"]!, "expected_revision": currentProject["revision"]!, "relations": [["id": edgeID, "source_task_id": source["id"]!, "target_task_id": "missing-legacy-id", "relation": "depends_on"]], "aliases": [["id": aliasID, "task_id": source["id"]!, "namespace": "legacy-source-1", "alias": "BUG-99"]]])
        XCTAssertEqual((result["unresolved"] as! [JSON]).count, 1)
        let stored = (result["relations"] as! [JSON])[0]
        XCTAssertNil(stored["target_task_id"]); XCTAssertEqual(stored["original_target_task_id"] as? String, "missing-legacy-id")
        let readySource = try ready(p, currentRelationTask(p, source))
        XCTAssertFalse(bool(readySource, "pickup_eligible"))
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("work_claim", ["project_id": p["id"]!, "task_id": source["id"]!, "expected_revision": readySource["revision"]!]) }
        XCTAssertTrue(bool(try currentRelationTask(p, sameTitle), "prerequisites_satisfied"))
        let destination = directory.appendingPathComponent("relations-export")
        _ = try call("export_project", ["project_id": p["id"]!, "path": destination.path])
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("project.json"))) as! JSON
        XCTAssertEqual((exported["relation"] as! [JSON])[0]["id"] as? String, edgeID)
        XCTAssertEqual((exported["task_alias"] as! [JSON])[0]["id"] as? String, aliasID)
        XCTAssertEqual((exported["relation"] as! [JSON])[0]["target_legacy_ref"] as? String, "missing-legacy-id")
        // Explicit owner mapping is required on another project; equal titles are irrelevant.
        let destinationProject = try project("Mapped destination"), mapped = try task(destinationProject)
        var edge = stored; edge["source_task_id"] = mapped["id"]
        var alias = (exported["task_alias"] as! [JSON])[0]; alias["task_id"] = mapped["id"]
        // IDs remain globally unique in one installation; a portable import preserves them into a fresh store.
        let fresh = try TestStore.router(root: directory.appendingPathComponent("fresh-store"))
        // TaskReferenceValidation.swift: the portable task needs its same-project status,
        // and the validated domain boundary owns the complete graph's outer commit.
        let statuses = try router.dbQueue.read { try router.records($0,type:"status",project:destinationProject["id"] as? String) }
        let epic = try router.dbQueue.read {try router.record($0,mapped["epic_id"] as! String,type:"group")}
        try fresh.dbQueue.writeWithoutTransaction { db in
            try fresh.withValidatedDomainTransaction(db) {
                try fresh.save(db, destinationProject, type: "project")
                for status in statuses { try fresh.save(db,status,type:"status") }
                try fresh.save(db,epic,type:"group")
                try fresh.save(db, mapped, type: "task")
                return .commit
            }
        }
        let imported = try fresh.handle(method: "relation_import", params: ["command_id": UUID().uuidString, "project_id": destinationProject["id"]!, "expected_revision": destinationProject["revision"]!, "relations": [edge], "aliases": [alias]], caller: owner)["data"] as! JSON
        XCTAssertEqual((imported["relations"] as! [JSON])[0]["id"] as? String, edgeID)
        XCTAssertEqual((imported["aliases"] as! [JSON])[0]["id"] as? String, aliasID)
    }

    func testRelationImportCycleAliasConflictAndCrossProjectRollback() throws {
        let p = try project(), a = try task(p), b = try task(p), foreign = try project("Foreign"), other = try task(foreign)
        let baseline = try call("snapshot"), currentProject = try call("project_settings_get", ["project_id": p["id"]!])
        let cycle: [JSON] = [["id": UUID().uuidString, "source_task_id": a["id"]!, "target_task_id": b["id"]!, "relation": "depends_on"], ["id": UUID().uuidString, "source_task_id": b["id"]!, "target_task_id": a["id"]!, "relation": "depends_on"]]
        assertCode("RELATION_CYCLE") { _ = try self.call("relation_import", ["project_id": p["id"]!, "expected_revision": currentProject["revision"]!, "relations": cycle]) }
        assertCode("NOT_FOUND") { _ = try self.call("relation_import", ["project_id": p["id"]!, "expected_revision": currentProject["revision"]!, "relations": [["id": UUID().uuidString, "source_task_id": a["id"]!, "target_task_id": other["id"]!, "relation": "depends_on"]]]) }
        let aliases: [JSON] = [["id": UUID().uuidString, "task_id": a["id"]!, "namespace": "source", "alias": "old-1"], ["id": UUID().uuidString, "task_id": b["id"]!, "namespace": "source", "alias": "old-1"]]
        assertCode("ALIAS_CONFLICT") { _ = try self.call("relation_import", ["project_id": p["id"]!, "expected_revision": currentProject["revision"]!, "aliases": aliases]) }
        let after = try call("snapshot")
        for key in ["tasks", "relations", "task_aliases", "events"] { XCTAssertEqual(try jsonString(["rows": baseline[key]!]), try jsonString(["rows": after[key]!]), key) }
    }
}
