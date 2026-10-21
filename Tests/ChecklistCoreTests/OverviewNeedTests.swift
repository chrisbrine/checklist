import XCTest
import GRDB
@testable import ChecklistCore

/// CL-53 and CL-66: Overview groups by what needs the owner, from existing ticket, attempt and session records.
extension CoreTests {
    func testOverviewNeedSurfacesGroupTicketsByWhatNeedsTheOwner() throws {
        let p = try project("Overview needs", "OV"), pid = p["id"] as! String
        var ids: [String: String] = [:]
        for name in ["review", "pickup", "waitsForPrerequisite", "active", "quiet", "lost", "blocked", "doneToday", "doneEarlier", "waiting", "owner"] {
            ids[name] = try task(p, name)["id"] as? String
        }
        let iso = ISO8601DateFormatter(), now = Date()
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            let statuses = try router.records(db, type: "status", project: pid)
            func status(_ category: String) -> String { statuses.first { $0["category"] as? String == category }!["id"] as! String }
            func update(_ name: String, _ change: (inout JSON) -> Void) throws {
                var value = try router.record(db, ids[name]!, type: "task"); change(&value); try router.save(db, router.revised(value), type: "task")
            }
            func attempt(_ name: String, session: String, checkpoint: Date, resource: String? = nil) throws {
                var value: JSON = ["id": "attempt-" + name, "project_id": pid, "task_id": ids[name]!, "state": "active", "phase": "implementation",
                                   "session_id": session, "started_at": iso.string(from: checkpoint), "last_checkpoint": iso.string(from: checkpoint), "revision": 1]
                if let resource { value["waiting_for_resource"] = resource }
                try router.save(db, value, type: "attempt")
                try update(name) { $0["active_attempt_id"] = "attempt-" + name; $0["status_id"] = status("active"); $0["readiness"] = "ready" }
            }
            for (session, state) in [("session-live", "connected"), ("session-ended", "ended")] {
                try router.save(db, ["id": session, "project_id": pid, "role": "worker", "state": state, "provider": "codex", "label": "Codex " + state, "revision": 1], type: "session")
            }
            try update("review") { $0["status_id"] = status("review"); $0["readiness"] = "ready"; $0["current_manifest_id"] = "manifest-review" }
            try router.save(db, ["id": "rr-review", "project_id": pid, "task_id": ids["review"]!, "manifest_id": "manifest-review", "gate": "review", "state": "queued", "revision": 1], type: "review_request")
            try update("pickup") { $0["status_id"] = status("queued"); $0["readiness"] = "ready" }
            try update("waitsForPrerequisite") { $0["status_id"] = status("queued"); $0["readiness"] = "ready" }
            try router.save(db, ["id": "edge-1", "project_id": pid, "source_task_id": ids["waitsForPrerequisite"]!, "target_task_id": ids["review"]!,
                                 "relation": "depends_on", "required": true, "state": "active", "revision": 1], type: "relation")
            try update("owner") { $0["status_id"] = status("queued"); $0["readiness"] = "ready"; $0["planned_assignee"] = "human" }
            try attempt("active", session: "session-live", checkpoint: now.addingTimeInterval(-60))
            try attempt("quiet", session: "session-live", checkpoint: now.addingTimeInterval(-2 * 3600))
            try attempt("waiting", session: "session-live", checkpoint: now.addingTimeInterval(-2 * 3600), resource: "shared build")
            try attempt("lost", session: "session-ended", checkpoint: now.addingTimeInterval(-60))
            try update("blocked") { $0["status_id"] = status("blocked") }
            try update("doneToday") { $0["status_id"] = status("done"); $0["completed_at"] = iso.string(from: now) }
            try update("doneEarlier") { $0["status_id"] = status("done"); $0["completed_at"] = iso.string(from: now.addingTimeInterval(-3 * 86400)) }
            return .commit
        }}
        func page(_ surface: String) throws -> (Int, Set<String>, [JSON]) {
            let reply = try call("workspace_page", ["project_id": pid, "surface": surface, "limit": 5])
            let rows = reply["rows"] as! [JSON]
            return (reply["total"] as! Int, Set(rows.compactMap { $0["id"] as? String }), rows)
        }
        XCTAssertEqual(try page("needs_review").1, [ids["review"]!])
        XCTAssertEqual(try page("needs_pickup").1, [ids["pickup"]!], "An open prerequisite and an owner-assigned ticket are not ready for pickup")
        XCTAssertEqual(try page("needs_active").1, [ids["active"]!, ids["waiting"]!], "A resource wait is never quiet")
        XCTAssertEqual(try page("needs_quiet").1, [ids["quiet"]!])
        XCTAssertEqual(try page("needs_recovery").1, [ids["lost"]!, ids["blocked"]!], "An ended session needs recovery; it is not working")
        let done = try page("needs_done_today")
        XCTAssertEqual(done.0, 1); XCTAssertEqual(done.1, [ids["doneToday"]!])
        let lost = try page("needs_recovery").2.first { $0["id"] as? String == ids["lost"]! }!
        let work = lost["active_work"] as! JSON
        XCTAssertEqual(work["session_state"] as? String, "ended"); XCTAssertEqual(work["session_label"] as? String, "Codex ended")
        let quiet = try page("needs_quiet").2.first!["active_work"] as! JSON
        XCTAssertNotNil(quiet["last_checkpoint"] as? String)
        XCTAssertEqual(try page("needs_active").2.first { $0["id"] as? String == ids["waiting"]! }.flatMap { ($0["active_work"] as? JSON)?["waiting_for_resource"] as? String }, "shared build")
        // One "overview" command returns every group's first page, equal to the single-surface reads.
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        let combined = try call("workspace_page", ["project_id": pid, "surface": "overview", "since": since])
        let groups = combined["groups"] as! JSON
        XCTAssertEqual(Set(groups.keys), Set(CommandRouter.overviewGroupLimits.map(\.surface)))
        for surface in ["needs_review", "needs_pickup", "needs_active", "needs_quiet", "needs_recovery", "needs_done_today"] {
            let group = groups[surface] as! JSON
            XCTAssertEqual(group["surface"] as? String, surface)
            XCTAssertEqual(group["total"] as? Int, try page(surface).0, surface)
            XCTAssertEqual(Set((group["rows"] as! [JSON]).compactMap { $0["id"] as? String }), try page(surface).1, surface)
        }
        XCTAssertEqual(((groups["completed_since"] as! JSON)["rows"] as! [JSON]).count, 1, "The digest group uses the given start")
    }

    /// CL-67: latest verdicts name ticket, reviewer and time; the digest lists tickets completed after the last visit.
    func testRecentReviewsAndCompletedSinceDigest() throws {
        let p = try project("Digest", "DG"), pid = p["id"] as! String
        let first = try task(p, "First")["id"] as! String, second = try task(p, "Second")["id"] as! String, older = try task(p, "Older")["id"] as! String
        let iso = ISO8601DateFormatter(), now = Date(), lastVisit = now.addingTimeInterval(-3600)
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            let done = try router.records(db, type: "status", project: pid).first { $0["category"] as? String == "done" }!["id"] as! String
            for (id, when) in [(first, now.addingTimeInterval(-60)), (second, now.addingTimeInterval(-600)), (older, now.addingTimeInterval(-7200))] {
                var value = try router.record(db, id, type: "task"); value["status_id"] = done; value["completed_at"] = iso.string(from: when)
                try router.save(db, router.revised(value), type: "task")
            }
            for (index, verdict) in ["reject", "pass"].enumerated() {
                try router.save(db, ["id": "review-\(index)", "project_id": pid, "task_id": first, "gate": "review", "verdict": verdict, "actor": "codex-session",
                                     "actor_display": "Codex thread 01", "created_at": iso.string(from: now.addingTimeInterval(Double(index) * 60 - 600)), "revision": 1], type: "review")
            }
            return .commit
        }}
        let reviews = try call("workspace_page", ["project_id": pid, "surface": "recent_reviews", "limit": 5])["rows"] as! [JSON]
        XCTAssertEqual(reviews.map { $0["verdict"] as? String }, ["pass", "reject"], "Newest verdict first")
        XCTAssertEqual(reviews.first?["reviewer"] as? String, "Codex thread 01")
        XCTAssertEqual(reviews.first?["task_title"] as? String, "First")
        XCTAssertNil(reviews.first?["review_assessment"], "Only the summary fields leave the ticket")
        let digest = try call("workspace_page", ["project_id": pid, "surface": "completed_since", "since": iso.string(from: lastVisit), "limit": 10])
        XCTAssertEqual((digest["rows"] as! [JSON]).compactMap { $0["id"] as? String }, [first, second], "Completed after the last visit, newest first")
        XCTAssertThrowsError(try call("workspace_page", ["project_id": pid, "surface": "completed_since"]), "The digest needs its start time")
    }

    /// CL-53 rework (finding 70f2b998): a blocking owner request keeps a ticket out of ready for pickup and
    /// ready for review; review also needs a queued review request for the current submission. CL-67 (fc06963d):
    /// the latest results are the newest three per project.
    func testReadyGroupsLeaveOutBlockedWorkAndResultsArePerProject() throws {
        let p = try project("Ready rules", "RR"), other = try project("Quiet project", "QP"), pid = p["id"] as! String, oid = other["id"] as! String
        var ids: [String: String] = [:]
        for name in ["pickupFree", "pickupBlocked", "reviewQueued", "reviewNoRequest", "reviewBlocked"] { ids[name] = try task(p, name)["id"] as? String }
        let otherTask = try task(other, "Other")["id"] as! String
        let iso = ISO8601DateFormatter(), now = Date()
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            let statuses = try router.records(db, type: "status", project: pid)
            func status(_ category: String) -> String { statuses.first { $0["category"] as? String == category }!["id"] as! String }
            func update(_ name: String, _ change: (inout JSON) -> Void) throws {
                var value = try router.record(db, ids[name]!, type: "task"); change(&value); try router.save(db, router.revised(value), type: "task")
            }
            for name in ["pickupFree", "pickupBlocked"] { try update(name) { $0["status_id"] = status("queued"); $0["readiness"] = "ready" } }
            for name in ["reviewQueued", "reviewNoRequest", "reviewBlocked"] {
                try update(name) { $0["status_id"] = status("review"); $0["readiness"] = "ready"; $0["current_manifest_id"] = "manifest-" + name }
            }
            for name in ["reviewQueued", "reviewBlocked"] {
                try router.save(db, ["id": "rr-" + name, "project_id": pid, "task_id": ids[name]!, "manifest_id": "manifest-" + name, "gate": "review", "state": "queued", "revision": 1], type: "review_request")
            }
            for name in ["pickupBlocked", "reviewBlocked"] {
                try router.save(db, ["id": "ask-" + name, "project_id": pid, "task_id": ids[name]!, "title": "Owner question", "state": "pending", "blocking": true, "revision": 1], type: "request")
            }
            for index in 0..<5 {
                try router.save(db, ["id": "busy-\(index)", "project_id": pid, "task_id": ids["pickupFree"]!, "gate": "review", "verdict": "pass", "actor_display": "Reviewer",
                                     "created_at": iso.string(from: now.addingTimeInterval(Double(-index))), "revision": 1], type: "review")
            }
            try router.save(db, ["id": "quiet-1", "project_id": oid, "task_id": otherTask, "gate": "review", "verdict": "reject", "actor_display": "Reviewer",
                                 "created_at": iso.string(from: now.addingTimeInterval(-86400)), "revision": 1], type: "review")
            return .commit
        }}
        func listed(_ surface: String, project: String? = nil) throws -> Set<String> {
            var p: JSON = ["surface": surface, "limit": 20]; if let project { p["project_id"] = project }
            return Set((try call("workspace_page", p)["rows"] as! [JSON]).compactMap { $0["id"] as? String })
        }
        XCTAssertEqual(try listed("needs_pickup", project: pid), [ids["pickupFree"]!], "A blocking owner request keeps a ticket out of pickup")
        XCTAssertEqual(try listed("needs_review", project: pid), [ids["reviewQueued"]!], "Review needs a queued request and no blocking owner request")
        let results = try listed("recent_reviews")
        XCTAssertTrue(results.contains("quiet-1"), "The quiet project's result is not hidden by the busy one")
        XCTAssertEqual(results.intersection(["busy-0", "busy-1", "busy-2", "busy-3", "busy-4"]), ["busy-0", "busy-1", "busy-2"], "The newest three per project")
    }

    /// Recheck finding 1234fd5f: with more projects than one page holds, the latest results continue on the next page.
    func testLatestResultsContinueBeyondOnePage() throws {
        var projects: [String] = []
        for index in 0..<21 { projects.append(try project("Results \(index)", "R\(index)")["id"] as! String) }
        let iso = ISO8601DateFormatter(), now = Date()
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            for (index, pid) in projects.enumerated() {
                for review in 0..<5 {
                    try router.save(db, ["id": "result-\(index)-\(review)", "project_id": pid, "gate": "review", "verdict": "pass", "actor_display": "Reviewer",
                                         "created_at": iso.string(from: now.addingTimeInterval(Double(-(index * 10 + review)))), "revision": 1], type: "review")
                }
            }
            return .commit
        }}
        let first = try call("workspace_page", ["surface": "recent_reviews", "limit": 60])
        let firstRows = first["rows"] as! [JSON]
        XCTAssertEqual(first["total"] as? Int, 63, "Three per project")
        XCTAssertEqual(firstRows.count, 60)
        let cursor = try XCTUnwrap(first["next_cursor"] as? String, "The first page offers more projects")
        let second = try call("workspace_page", ["surface": "recent_reviews", "limit": 60, "cursor": cursor])["rows"] as! [JSON]
        let seen = Set((firstRows + second).compactMap { $0["project_id"] as? String })
        XCTAssertEqual(seen, Set(projects), "Every project's latest results are reachable")
    }
}
