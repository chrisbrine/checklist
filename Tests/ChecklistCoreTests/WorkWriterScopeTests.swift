import GRDB
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testSubmissionScopesRetainedContributorsAndSupersessionWithLegacyOrder() throws {
        let workspace = directory.appendingPathComponent("submission-scope")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Submission scope", "root_path": workspace.path])
        let foreign = try self.project("Foreign submission scope")
        let acceptanceItem = "Record the synthetic decision."
        let draft = try call("task_create", [
            "project_id": project["id"]!, "title": "Synthetic decision", "kind": "question",
            "brief": "Record an immutable synthetic decision and verify retained submission history.",
            "acceptance": [acceptanceItem],
        ])
        let task = try ready(project, draft)
        let nearby = try self.task(project, "Nearby history")
        let foreignTask = try self.task(foreign, "Foreign history")
        let scopes = [(project, task), (project, nearby), (foreign, foreignTask)]
        let projectID = try XCTUnwrap(project["id"] as? String)
        let taskID = try XCTUnwrap(task["id"] as? String)
        let sessionID = UUID().uuidString
        _ = try call("session_register", [
            "project_id": projectID, "session_id": sessionID, "role": "worker",
            "provider": "codex", "installation": "submission-scope-worker",
        ])
        let author = Caller(role: "worker", installation: "submission-scope-worker",
                            projectIDs: [projectID], sessionID: sessionID, workspace: workspace.path)
        let claim = try call("work_claim", [
            "project_id": projectID, "task_id": taskID, "expected_revision": task["revision"]!,
        ], author)
        let attemptID = try XCTUnwrap(claim["id"] as? String)
        let oldStates = ["queued", "blocked", "active", "pass", "superseded", "evidence_requested"]
        try router.dbQueue.write { db in
            let template = try router.record(db, attemptID, type: "attempt")
            for index in 0..<90 {
                let (owner, ticket) = scopes[index % scopes.count]
                var attempt = template
                let id = UUID().uuidString
                attempt["id"] = id
                attempt["project_id"] = owner["id"]
                attempt["task_id"] = ticket["id"]
                attempt["phase"] = index % 4 == 0 ? "review" : "implementation"
                attempt["state"] = index % 2 == 0 ? "submitted" : "released"
                attempt["session_id"] = "generated-session-\(index)"
                attempt.removeValue(forKey: "token_hash")
                try router.save(db, attempt, type: "attempt")
                try router.save(db, [
                    "id": UUID().uuidString, "project_id": owner["id"]!, "task_id": ticket["id"]!,
                    "manifest_id": UUID().uuidString, "gate": "review", "revision": 1,
                    "state": oldStates[(index / scopes.count) % oldStates.count],
                ], type: "review_request")
            }
        }
        let baseline = try router.dbQueue.read { db -> ([JSON], [String: String]) in
            let attempts = try router.records(db, type: "attempt", project: projectID).filter {
                $0["task_id"] as? String == taskID && $0["phase"] as? String == "implementation"
            }
            let contributors = try attempts.map { row -> JSON in
                var result: JSON = [
                    "attempt_id": try XCTUnwrap(row["id"]),
                    "principal": try XCTUnwrap(row["principal"]),
                    "session_id": try XCTUnwrap(row["session_id"]),
                    "session_authorization_generation": row["session_authorization_generation"] ?? "",
                ]
                for key in ["execution_domain", "installation", "parent_attempt_id"] {
                    result[key] = row[key]
                }
                return result
            }
            let requests = try router.records(db, type: "review_request")
            let states = try Dictionary(uniqueKeysWithValues: requests.map { row in
                let id = try XCTUnwrap(row["id"] as? String)
                let state = try XCTUnwrap(row["state"] as? String)
                let superseded = row["project_id"] as? String == projectID && row["task_id"] as? String == taskID
                    && ["queued", "blocked"].contains(state)
                return (id, superseded ? "superseded" : state)
            })
            return (contributors, states)
        }
        XCTAssertGreaterThan(baseline.0.count, 10)
        let input: JSON = [
            "project_id": projectID, "attempt_id": attemptID, "claim_token": claim["claim_token"]!,
            "acceptance_revision": task["acceptance_revision"]!,
            "evidence_manifest": ["kind": "decision", "decision": ["text": "Synthetic decision"]],
            "acceptance_evidence": [["item": 0, "limitation": "Synthetic component observation"]],
        ]
        let commandID = UUID().uuidString
        let submission = try call("work_submit", input, author, commandID)
        let replay = try call("work_submit", input, author, commandID)
        XCTAssertEqual(try jsonString(replay), try jsonString(submission))
        try router.dbQueue.read { db in
            let manifestID = try XCTUnwrap(submission["manifest_id"] as? String)
            let manifest = try router.record(db, manifestID, type: "manifest")
            XCTAssertEqual(try jsonString(manifest["contributors"]!), try jsonString(baseline.0))
            let evidence = try XCTUnwrap(manifest["evidence"] as? JSON)
            let coverage = try XCTUnwrap(evidence["acceptance_evidence"] as? [JSON])
            XCTAssertEqual(coverage.map { $0["item_text"] as? String }, [acceptanceItem])
            XCTAssertEqual((coverage.first?["coverage"] as? JSON)?["covered"] as? Bool, true)
            let requests = try router.records(db, type: "review_request")
            let observed = try Dictionary(uniqueKeysWithValues: requests.compactMap { row -> (String, String)? in
                let id = try XCTUnwrap(row["id"] as? String)
                guard baseline.1[id] != nil else { return nil }
                return (id, try XCTUnwrap(row["state"] as? String))
            })
            XCTAssertEqual(observed, baseline.1)
        }
    }

    func testExactActiveBatchSelectionMatchesUnscopedLegacyFilter() throws {
        let project = try self.project("Batch scope")
        let foreign = try self.project("Foreign batch scope")
        let projectID = try XCTUnwrap(project["id"] as? String)
        let foreignID = try XCTUnwrap(foreign["id"] as? String)
        let batchID = UUID().uuidString
        let differentBatchID = UUID().uuidString
        let visibleMember = try XCTUnwrap(try task(project, "Frozen member")["id"] as? String)
        let extraActiveMember = try XCTUnwrap(try task(project, "Unlisted active member")["id"] as? String)
        let foreignMember = try XCTUnwrap(try task(foreign, "Foreign active history")["id"] as? String)
        let digest = "fixture-digest"
        try router.dbQueue.write { db in
            for index in 0..<90 {
                let scope = index % 5 == 0 ? foreignID : projectID
                let taskID = scope == foreignID ? foreignMember : (index % 2 == 0 ? visibleMember : extraActiveMember)
                var row: JSON = [
                    "id": UUID().uuidString, "project_id": scope, "task_id": taskID, "revision": 1,
                    "state": index % 4 == 0 ? "released" : "active",
                    "phase": index % 3 == 0 ? "implementation" : "review",
                    "batch_id": index % 7 == 0 ? differentBatchID : batchID,
                ]
                if index % 6 != 0 { row["batch_digest"] = index % 11 == 0 ? "obsolete-digest" : digest }
                try router.save(db, row, type: "attempt")
            }
        }
        try router.dbQueue.read { db in
            let allInScope = try router.records(db, type: "attempt", project: projectID)
            for digest in [digest, "obsolete-digest", nil] as [String?] {
                for phase in ["implementation", "review"] {
                    var batch: JSON = ["id": batchID, "project_id": projectID, "members": [["task_id": visibleMember]]]
                    if let digest { batch["digest"] = digest }
                    let old = Set(allInScope.filter {
                        $0["state"] as? String == "active" && $0["batch_id"] as? String == batchID
                            && $0["batch_digest"] as? String == digest && $0["phase"] as? String == phase
                    }.compactMap { $0["task_id"] as? String })
                    XCTAssertEqual(try router.activeBatchTaskIDs(db, batch: batch, phase: phase), old)
                    if digest == "fixture-digest", phase == "review" {
                        XCTAssertTrue(old.contains(extraActiveMember), "An unexpected legacy claim must stay in the validation set.")
                    }
                }
            }
        }
    }

    func testGlobalSourceExecutionScopeMatchesLegacyEnumeration() throws {
        let first = try project("Source execution scope")
        let second = try project("Other source execution scope")
        let scopes = [try XCTUnwrap(first["id"] as? String), try XCTUnwrap(second["id"] as? String), UUID().uuidString]
        let states = ["queued", "running", "interrupted", "completed", "stopped"]
        var insertedIDs: [String] = []
        try router.dbQueue.write { db in
            for index in 0..<60 {
                let projectID = scopes[index % scopes.count]
                let id = UUID().uuidString
                insertedIDs.append(id)
                try router.save(db, ["id": UUID().uuidString, "project_id": projectID, "revision": 1], type: "source_capture")
                try router.save(db, [
                    "id": id, "project_id": projectID, "revision": 1, "state": states[index % states.count],
                    "process_stop_unverified": index % 7 == 0, "attempt_id": "attempt-\(index % 2)", "task_id": "task-\(index % 3)",
                ], type: "source_execution")
            }
        }
        try router.dbQueue.read { db in
            let legacy = try legacyGlobalSourceExecutions(db)
            XCTAssertEqual(legacy.compactMap { $0["id"] as? String }, insertedIDs)
            var statements: [String] = []
            db.trace { if case .statement(let statement) = $0 { statements.append(statement.sql) } }
            let indexed = try router.records(db, type: "source_execution")
            db.trace(options: [])
            XCTAssertEqual(try jsonString(indexed), try jsonString(legacy))
            let sql = try XCTUnwrap(statements.first)
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: [Data("source_execution".utf8)])
                .map { $0["detail"] as String }
            XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX records_scope") }, plan.joined(separator: "\n"))
            XCTAssertTrue(plan.contains { $0.contains("USING INTEGER PRIMARY KEY (rowid=?)") }, plan.joined(separator: "\n"))
            XCTAssertFalse(plan.contains("SCAN records"), plan.joined(separator: "\n"))
            for attemptID in [nil, "attempt-0", "attempt-1"] as [String?] {
                for taskID in [nil, "task-0", "task-1", "task-2"] as [String?] {
                    let expected = legacy.filter {
                        (["queued", "running", "interrupted"].contains($0["state"] as? String ?? "") || bool($0, "process_stop_unverified"))
                            && (attemptID == nil || $0["attempt_id"] as? String == attemptID)
                            && (taskID == nil || $0["task_id"] as? String == taskID)
                    }
                    XCTAssertEqual(try jsonString(router.unresolvedSourceExecutions(db, attemptID: attemptID, taskID: taskID)),
                                   try jsonString(expected))
                }
            }
        }
    }

    func testGlobalSourceExecutionScopeRejectsMalformedUnrelatedEnvelopes() throws {
        let foreign = try project("Unrelated source execution")
        let projectID = try XCTUnwrap(foreign["id"] as? String)
        try router.dbQueue.write { db in
            // The verdict's attempt filter must not hide corruption in a foreign or NULL scope.
            for (scope, reason) in [(projectID as String?, "revisionMismatch"), (nil, "ownershipShape")] {
                try db.inSavepoint {
                    let id = UUID().uuidString
                    var run: JSON = ["id": id, "revision": 1, "attempt_id": "unrelated", "task_id": "unrelated", "state": "completed"]
                    if let scope { run["project_id"] = scope }
                    let revision = scope == nil ? 1 : 2
                    let arguments: StatementArguments = [id, scope, revision, try jsonString(run)]
                    try db.execute(sql: "INSERT INTO records (id,project_id,type,revision,data) VALUES (?,?,'source_execution',?,?)",
                                   arguments: arguments)
                    let fetches: [() throws -> [JSON]] = [
                        { try self.legacyGlobalSourceExecutions(db) },
                        { try self.router.unresolvedSourceExecutions(db, attemptID: "target", taskID: "target") },
                    ]
                    for fetch in fetches {
                        XCTAssertThrowsError(try fetch()) {
                            XCTAssertEqual(($0 as? CoreError)?.code, "CANONICAL_RECORD_INVALID")
                            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String, reason)
                        }
                    }
                    return .rollback
                }
            }
        }
    }

    private func legacyGlobalSourceExecutions(_ db: Database) throws -> [JSON] {
        let sql = "SELECT " + CommandRouter.canonicalRecordColumns
            + " FROM records WHERE type = CAST(? AS TEXT) ORDER BY rowid"
        return try Row.fetchAll(db, sql: sql, arguments: [Data("source_execution".utf8)])
            .map { try GRDBRecordEnvelopeAdapter.decode($0).object }
    }
}
