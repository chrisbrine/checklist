import GRDB
import XCTest
@testable import ChecklistCore

final class WorkClaimRecordPreparationTests: XCTestCase {
    private struct ClaimFixture {
        let store: ReadPerformanceFixture
        let projectID: String
        let taskID: String
        let params: JSON

        init() throws {
            let store = try ReadPerformanceFixture("CL-512-claim-selection")
            let project = try store.call("project_create", ["name": "Claim selection", "key_prefix": "SEL",
                "root_path": store.directory.path])
            let projectID = try XCTUnwrap(project["id"] as? String)
            let task = try store.call("task_create", ["project_id": projectID, "title": "Selected ticket"])
            let taskID = try XCTUnwrap(task["id"] as? String)
            self.store = store
            self.projectID = projectID
            self.taskID = taskID
            params = ["project_id": projectID, "task_id": taskID,
                "expected_revision": try XCTUnwrap(task["revision"] as? Int), "command_id": uuid()]
        }

        var router: CommandRouter { store.router }
        var task: JSON { ["id": taskID, "project_id": projectID] }

        func note(_ id: String, state: String = "kept", linkedTaskID: String? = nil) -> JSON {
            ["id": id, "project_id": projectID, "task_id": linkedTaskID ?? taskID,
                "body": id, "state": state, "revision": 1]
        }
    }

    func testPreparedRowsAndCountsMatchGenericQueriesAndInvalidateOnSave() throws {
        let f = try ClaimFixture(), router = f.router
        let state = "json_extract(data,'$.state')='kept'"
        try f.store.save([
            ("message", f.note("first")), ("message", f.note("filtered", state: "other")),
            ("message", f.note("foreign", linkedTaskID: f.taskID + "-foreign")), ("message", f.note("newest")),
        ])
        let attachments: [(String, JSON)] = (0..<24).map { index in
            ("attachment", ["id": "attachment-\(index)", "project_id": f.projectID,
                            "task_id": index.isMultiple(of: 3) ? f.taskID + "-foreign" : f.taskID,
                            "availability": index.isMultiple(of: 2) ? "original_cleaned" : "available", "revision": 1])
        }
        try f.store.save(attachments)

        try router.withWorkClaimRecordPreparation(params: f.params, caller: f.store.owner) { prepared in
            let prepared = try XCTUnwrap(prepared)
            try router.dbQueue.write { db in
                let rows = try router.scopedTaskRows(db, type: "message", task: f.task, predicate: state,
                    limit: 1, descending: true)
                let count = try router.scopedTaskCount(db, type: "message", task: f.task, predicate: state)
                let task = try router.scoped(db, f.taskID, f.projectID, type: "task")
                let originalCount = try router.selectedTaskProjectionWithoutHealth(db, task: task)["cleaned_original_count"] as? Int
                XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["newest"])
                XCTAssertEqual(count, 2)
                XCTAssertEqual(originalCount, 8)

                try router.withPreparedWorkClaimRecordSelection(db, prepared: prepared) {
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "message", task: f.task)?.count, 3)
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "finding", task: f.task), [])
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "attempt", task: f.task), [])
                    XCTAssertNil(try router.selectedTaskRecordIDs(db, type: "message",
                        task: ["id": f.taskID + "-foreign", "project_id": f.projectID]))
                    XCTAssertNil(try router.selectedTaskRecordIDs(db, type: "message",
                        task: ["id": f.taskID, "project_id": f.projectID + "\0foreign"]))
                    XCTAssertEqual(try jsonString(router.scopedTaskRows(db, type: "message", task: f.task,
                        predicate: state, limit: 1, descending: true)), try jsonString(rows))
                    XCTAssertEqual(try router.scopedTaskCount(db, type: "message", task: f.task, predicate: state), count)
                    XCTAssertEqual(try router.selectedTaskProjectionWithoutHealth(db, task: task)["cleaned_original_count"] as? Int, originalCount)

                    try router.save(db, f.note("during-claim"), type: "message")
                    XCTAssertNil(try router.selectedTaskRecordIDs(db, type: "message", task: f.task))
                    XCTAssertEqual(try router.scopedTaskCount(db, type: "message", task: f.task, predicate: state), 3)
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "finding", task: f.task), [])

                    let attempt: JSON = ["id": "new-attempt", "project_id": f.projectID, "task_id": f.taskID,
                                         "state": "active", "revision": 1]
                    // Test the INSERT's real SQLite row ID, including the
                    // production guard that excludes the fixture statement seam.
                    let fixtureExecute = router.fixtureStoreStatement
                    router.fixtureStoreStatement = nil
                    defer { router.fixtureStoreStatement = fixtureExecute }
                    try router.save(db, attempt, type: "attempt")
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "attempt", task: f.task)?.count, 1)
                    XCTAssertEqual(try router.scopedTaskRows(db, type: "attempt", task: f.task).first?["id"] as? String, "new-attempt")
                }
                XCTAssertNil(try router.selectedTaskRecordIDs(db, type: "finding", task: f.task))
            }
        }
    }

    func testPreparedHandlerTreeMatchesExactLiveRecipients() throws {
        let f = try ClaimFixture(), router = f.router
        let tree: [(id: String, parent: String?, task: String, state: String)] = [
            ("root", nil, f.taskID, "active"),
            ("child", "root", f.taskID, "active"),
            ("grandchild", "child", f.taskID, "active"),
            ("inactive", "root", f.taskID, "released"),
            ("below-inactive", "inactive", f.taskID, "active"),
            ("unrelated-root", nil, f.taskID, "active"),
            ("other-ticket", "root", f.taskID + "-other", "active"),
        ]
        try f.store.save(tree.flatMap { node -> [(String, JSON)] in
            let sessionID = "session-" + node.id
            let session: JSON = ["id": sessionID, "project_id": f.projectID, "project_ids": [f.projectID],
                "role": "worker", "provider": "codex", "state": "connected", "authorization_generation": "current",
                "label": node.id, "revision": 1]
            var attempt: JSON = ["id": "attempt-" + node.id, "project_id": f.projectID, "task_id": node.task,
                "session_id": sessionID, "session_authorization_generation": "current", "state": node.state, "revision": 1]
            if let parent = node.parent { attempt["parent_attempt_id"] = "attempt-" + parent }
            return [("session", session), ("attempt", attempt)]
        })
        var task = f.task
        task["active_attempt_id"] = "attempt-root"

        try router.withWorkClaimRecordPreparation(params: f.params, caller: f.store.owner) { prepared in
            let prepared = try XCTUnwrap(prepared)
            try router.dbQueue.write { db in
                let original = try router.relevantHandlerRecipients(db, task: task)
                XCTAssertEqual(original.compactMap { $0["attempt_id"] as? String },
                    ["attempt-child", "attempt-grandchild", "attempt-root"])
                XCTAssertEqual(original.compactMap { $0["recipient_role"] as? String },
                    ["registered_child", "registered_child", "handler"])
                try router.withPreparedWorkClaimRecordSelection(db, prepared: prepared) {
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "attempt", task: task)?.count, 6)
                    let selected = try router.relevantHandlerRecipients(db, task: task)
                    XCTAssertEqual(try jsonString(selected), try jsonString(original))
                }
            }
        }
    }

    func testInterveningCommitsNeverInstallStaleRowsAndRetryAtMostTwice() throws {
        let f = try ClaimFixture(), router = f.router

        for changes in 1...2 {
            var preparations = 0
            var bodyCalls = 0
            let ids = try router.withWorkClaimRecordPreparation(params: f.params, caller: f.store.owner) { prepared in
                if prepared != nil {
                    preparations += 1
                    if preparations <= changes {
                        try f.store.save([("message", f.note("race-\(changes)-\(preparations)"))])
                    }
                }
                return try router.dbQueue.write { db in
                    try router.withPreparedWorkClaimRecordSelection(db, prepared: prepared) {
                        bodyCalls += 1
                        XCTAssertEqual(prepared != nil, changes == 1)
                        return try router.scopedTaskRows(db, type: "message", task: f.task).compactMap { $0["id"] as? String }
                    }
                }
            }
            XCTAssertEqual(preparations, 2)
            XCTAssertEqual(bodyCalls, 1)
            XCTAssertEqual(ids, changes == 1 ? ["race-1-1"] : ["race-1-1", "race-2-1", "race-2-2"])
        }
    }

    func testUnrelatedRecordsPreserveThePreparedSelection() throws {
        let f = try ClaimFixture(), router = f.router
        var preparations = 0
        try f.store.save([("message", f.note("kept"))])
        let ids = try router.withWorkClaimRecordPreparation(params:f.params,caller:f.store.owner) { prepared in
            preparations += 1
            XCTAssertNotNil(prepared)
            try f.store.save([("message",f.note("other-ticket-\(preparations)",linkedTaskID:f.taskID + "-other"))])
            return try router.dbQueue.write { db in
                try router.withPreparedWorkClaimRecordSelection(db,prepared:prepared) {
                    try router.scopedTaskRows(db,type:"message",task:f.task).compactMap { $0["id"] as? String }
                }
            }
        }
        XCTAssertEqual(preparations,1)
        XCTAssertEqual(ids,["kept"])
    }

    func testRecordMovedIntoTheTicketInvalidatesTheSelection() throws {
        let f = try ClaimFixture(), router = f.router
        try f.store.save([("message",f.note("moving",linkedTaskID:f.taskID + "-other"))])
        var preparations = 0
        let ids = try router.withWorkClaimRecordPreparation(params:f.params,caller:f.store.owner) { prepared in
            preparations += 1
            XCTAssertNotNil(prepared)
            if preparations == 1 {
                var moved = f.note("moving")
                moved["revision"] = 2
                try f.store.save([("message",moved)])
            }
            return try router.dbQueue.write { db in
                try router.withPreparedWorkClaimRecordSelection(db,prepared:prepared) {
                    try router.scopedTaskRows(db,type:"message",task:f.task).compactMap { $0["id"] as? String }
                }
            }
        }
        XCTAssertEqual(preparations,2)
        XCTAssertEqual(ids,["moving"])
    }

    func testLostObservationWindowRequiresAnotherSnapshot() throws {
        let f = try ClaimFixture(), router = f.router
        var preparations = 0, completed = 0
        try router.withWorkClaimRecordPreparation(params:f.params,caller:f.store.owner) { prepared in
            preparations += 1
            XCTAssertNotNil(prepared)
            if preparations == 1 {
                let unrelated = (0..<1025).map { index in
                    ("message",f.note("unrelated-\(index)",linkedTaskID:f.taskID + "-other"))
                }
                try f.store.save(unrelated)
            }
            try router.dbQueue.write { db in
                try router.withPreparedWorkClaimRecordSelection(db,prepared:prepared) { completed += 1 }
            }
        }
        XCTAssertEqual(preparations,2)
        XCTAssertEqual(completed,1)
    }

    func testUnobservedConnectionCommitRequiresAnotherReadSnapshot() throws {
        let f = try ClaimFixture(), router = f.router
        var configuration = Configuration()
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let external = try DatabaseQueue(path:StorageBootstrap.writableURI(router.root.appendingPathComponent("checklist.sqlite")),
                                         configuration:configuration)
        defer { try? external.close() }
        var preparations = 0, completed = 0
        try router.withWorkClaimRecordPreparation(params:f.params,caller:f.store.owner) { prepared in
            preparations += 1
            XCTAssertNotNil(prepared)
            if preparations == 1 {
                try external.write { db in
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('claim-fence-fixture','changed')")
                }
            }
            try router.dbQueue.write { db in
                try router.withPreparedWorkClaimRecordSelection(db,prepared:prepared) {
                    completed += 1
                }
            }
        }
        XCTAssertEqual(preparations,2)
        XCTAssertEqual(completed,1)
    }

    func testPreparationSkipsReceiptsAndUsesCallerProjectGrant() throws {
        let f = try ClaimFixture(), router = f.router
        let foreign = Caller(role: "worker", installation: "foreign", projectIDs: [], workspace: f.store.directory.path)
        try router.withWorkClaimRecordPreparation(params: f.params, caller: foreign) { prepared in
            XCTAssertNil(prepared)
        }

        try router.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,'fixture','{}')",
                arguments: [f.store.owner.principal, try XCTUnwrap(f.params["command_id"] as? String)])
        }
        try router.withWorkClaimRecordPreparation(params: f.params, caller: f.store.owner) { prepared in
            XCTAssertNil(prepared)
        }
        var freshReview = f.params
        freshReview["phase"] = "review"
        freshReview["command_id"] = uuid()
        try router.withWorkClaimRecordPreparation(params: freshReview, caller: f.store.owner) { prepared in
            let prepared = try XCTUnwrap(prepared)
            try router.dbQueue.write { db in
                try router.withPreparedWorkClaimRecordSelection(db, prepared: prepared) {
                    XCTAssertEqual(try router.selectedTaskRecordIDs(db, type: "finding", task: f.task), [])
                    XCTAssertNil(try router.selectedTaskRecordIDs(db, type: "review_request", task: f.task))
                }
            }
        }
    }
}
