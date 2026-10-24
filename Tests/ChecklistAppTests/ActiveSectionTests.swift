import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

@MainActor final class ActiveSectionTests: XCTestCase {
    private func task(_ id: String, category: String, readiness: String = "ready") -> Record {
        Record(values: ["id": id, "project_id": "p", "title": id, "status_id": "status-" + category,
                        "status_category": category, "readiness": readiness, "active_attention": true])
    }
    private func projection(_ tasks: [Record], triage: Record, filter: String) -> TicketListProjection {
        TicketListProjection.make(tasks: tasks, groups: [triage], messages: [], projectID: "p", archived: false,
                                  statusFilter: filter, tagFilter: "all", search: "", includeTriages: true, projectNames: [:])
    }
    func testActiveFilterUsesOwnCategoryDespiteAttentionMembershipAndStatusID() {
        for category in ["queued", "review", "blocked", "parked", "done", "completed", "canceled"] {
            let row = task(category, category: category)
            XCTAssertFalse(TicketVisibility.matchesStatus(row, filter: "active", activeTriageMember: true))
            XCTAssertFalse(TicketVisibility.matchesStatus(row, filter: "active", activeTriageMembers: [row.id]))
        }
        XCTAssertFalse(TicketVisibility.matchesStatus(task("draft", category: "queued", readiness: "draft"), filter: "active"))
        XCTAssertTrue(TicketVisibility.matchesStatus(task("working", category: "active"), filter: "active"))
        let alias = Record(values: ["id": "alias", "status_id": "active", "status_category": "queued"])
        XCTAssertFalse(TicketVisibility.matchesStatus(alias, filter: "active"), "The reserved Active filter cannot be overridden by an ID")
    }
    func testSnapshotActiveMembershipAndCountsWithAndWithoutOrchestration() throws {
        let tasks = [task("queued", category: "queued"), task("review", category: "review"), task("working", category: "active"),
                     task("draft", category: "queued", readiness: "draft"), task("blocked", category: "blocked"),
                     task("parked", category: "parked"), task("done", category: "done")]
        for orchestrated in [false, true] {
            var group: [String: Any] = ["id": "triage", "project_id": "p", "kind": "triage", "name": "Mixed pass",
                                        "active_attention": true, "task_ids": tasks.map(\.id)]
            if orchestrated { group["orchestration"] = ["state": "active", "actor_display": "Actual coordinator", "session_id": "session"] }
            let triage = Record(values: group), active = projection(tasks, triage: triage, filter: "active")
            XCTAssertEqual(active.visibleTicketCount, 1)
            XCTAssertEqual(active.scopedTicketCount, 6)
            XCTAssertTrue(active.ordinaryTickets.isEmpty)
            let section = try XCTUnwrap(active.triages.first)
            XCTAssertEqual(section.visibleMembers.map(\.id), ["working"])
            XCTAssertEqual(section.totalCount, 7)
            XCTAssertEqual(section.orchestrationLabel, orchestrated ? "Orchestrated by Actual coordinator" : nil)
            XCTAssertEqual(projection(tasks, triage: triage, filter: "review").triages.first?.visibleMembers.map(\.id), ["review"])
            XCTAssertEqual(Set(projection(tasks, triage: triage, filter: "queued").triages.first?.visibleMembers.map(\.id) ?? []), ["queued", "draft"])
        }
    }
    func testCoordinatorLabelUsesActualIdentityAndDoesNotCallAttentionInProgress() {
        func section(_ orchestration: [String: Any]) -> InlineTriageSection {
            InlineTriageSection(triage: Record(values: ["id": "triage", "active_attention": true, "orchestration": orchestration]),
                                allMembers: [], visibleMembers: [], matchesGroupSearch: false)
        }
        XCTAssertNil(section([:]).orchestrationLabel)
        XCTAssertNil(section(["state": "finished", "actor_display": "Prior coordinator"]).orchestrationLabel)
        XCTAssertEqual(section(["state": "active", "actor_display": "", "session_id": "actual-session"]).orchestrationLabel, "Orchestrated by actual-session")
        XCTAssertEqual(section(["state": "active"]).orchestrationLabel, "Being orchestrated")
    }
    func testOwnerPagePreparationCountsCoordinatorAndSidebarRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("active-app-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try CommandRouter(root: root), owner = Caller(role: "owner", installation: "active-app-test", projectIDs: [])
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            var input = params
            if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
            return try router.handle(method: method, params: appFixtureTaskInput(router,method:method,input:input), caller: owner)["data"] as! [String: Any]
        }
        let project = try call("project_create", ["name": "Active page", "key_prefix": "AP"]), pid = project["id"] as! String
        var ids: [String: String] = [:]
        for category in ["queued", "review", "active"] {
            ids[category] = try call("task_create", ["project_id": pid, "title": category])["id"] as? String
        }
        _ = try call("human_request_create", ["project_id": pid, "task_id": ids["queued"]!, "title": "Owner answer",
                                              "questions": [["id": "q", "prompt": "Which reference?", "type": "text"]]])
        for orchestrated in [false, true] {
            try router.dbQueue.writeWithoutTransaction { db in
                try router.withValidatedDomainTransaction(db) {
                    let statuses = try router.records(db, type: "status", project: pid)
                    for (category, id) in ids {
                        var task = try router.record(db, id, type: "task")
                        task["status_id"] = statuses.first { $0["category"] as? String == category }!["id"]
                        task["readiness"] = "ready"
                        if category == "queued" { task["planned_assignee"] = "human" }
                        try router.save(db, task, type: "task")
                    }
                    var group: [String: Any] = ["id": "triage", "project_id": pid, "kind": "triage", "phase": "implementation", "name": "Historical mixed pass",
                                                "purpose": "Projection fixture", "revision": 1, "task_ids": Array(ids.values), "archived": false]
                    if orchestrated { group["orchestration"] = ["state": "active", "actor_display": "Actual coordinator", "session_id": "coordinator-session"] }
                    try router.save(db, group, type: "group")
                    return .commit
                }
            }
            let query = TicketPageQuery(surface: "tickets", projectID: pid, text: "", statusFilter: "active", tagFilter: "all", groupBy: "status", orderBy: "manual")
            let response = try call("task_list", query.parameters()), page = try TicketPage(response: response)
            XCTAssertEqual(page.tasks.map(\.id), [ids["active"]!])
            XCTAssertEqual(page.matchedCount, 1); XCTAssertEqual(page.scopedCount, 3)
            var preparation = TicketPagePreparation()
            XCTAssertTrue(preparation.receive(page, for: preparation.begin(query: query)))
            let prepared = try XCTUnwrap(preparation.prepared(expansion: TicketWorkspaceExpansion()))
            XCTAssertEqual(prepared.list.visibleTicketCount, 1)
            let section = try XCTUnwrap(prepared.list.triages.first)
            XCTAssertEqual(section.visibleMembers.map(\.id), [ids["active"]!])
            XCTAssertEqual(section.orchestrationLabel, orchestrated ? "Orchestrated by Actual coordinator" : nil)
            let catalog = TicketCatalogObservation(); catalog.install(page)
            XCTAssertEqual(catalog.needsCount, 2, "The current sidebar badge counts one request plus one owner ticket")
            if orchestrated {
                var invalidResponse = response, invalidPage = response["tickets_page"] as! [String: Any]
                var triages = invalidPage["triages"] as! [[String: Any]]
                triages[0]["orchestration"] = ["state": true, "actor_display": "Bad", "session_id": "bad"]
                invalidPage["triages"] = triages; invalidResponse["tickets_page"] = invalidPage
                XCTAssertThrowsError(try TicketPage(response: invalidResponse))
            }
        }
    }
}
