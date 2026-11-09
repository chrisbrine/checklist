import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private static let phaseTemplates = LockedTestState([String: TestStore.Template]())

    /// Share completed setup, never the mutable store used by a case. The
    /// template builder executes the existing fixture helpers once and publishes
    /// a closed database; each branch then receives private APFS-cloned bytes.
    func preparedCorePhase(_ name: String, prepare: @escaping () throws -> JSON) throws -> JSON {
        let template = Self.phaseTemplates.withLock { templates in
            if let template = templates[name] { return template }
            let template = TestStore.Template(name: "CoreTests.phase." + name) { [self] preparedRouter, workspace in
                let savedRouter = router, savedDirectory = directory
                router = preparedRouter; directory = workspace
                defer { router = savedRouter; directory = savedDirectory }
                let value = try prepare()
                try preparedRouter.dbQueue.write { db in
                    try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('test-core-phase-value',?)", arguments: [try jsonString(["fixture":value,"workspace":workspace.resolvingSymlinksInPath().path,"declared_workspace":workspace.path])])
                }
            }
            templates[name] = template
            return template
        }
        try router.closeStore(); router = nil
        try FileManager.default.removeItem(at: directory)
        let workspace = directory.appendingPathComponent("phase-workspace", isDirectory: true)
        router = try TestStore.router(root: directory.appendingPathComponent("phase-store"), template: template, workspace: workspace)
        let saved = try router.dbQueue.read { db in
            jsonObject(try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='test-core-phase-value'")))
        }
        let oldWorkspaces = [saved["workspace"] as! String, saved["declared_workspace"] as! String]
        // Mutable session authority must follow the cloned project's workspace,
        // including nested orchestrator roots. Literal historical text stays put.
        try fixtureDomainTransaction { db in
            for var session in try router.records(db, type: "session") {
                guard let path = session["workspace"] as? String,
                      let oldWorkspace = oldWorkspaces.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                session["workspace"] = workspace.resolvingSymlinksInPath().path + path.dropFirst(oldWorkspace.count)
                try router.save(db, session, type: "session")
            }
            for var attempt in try router.records(db, type: "attempt") where attempt["incarnation"] != nil {
                attempt["incarnation"] = router.incarnation
                try router.save(db, attempt, type: "attempt")
            }
        }
        var fixture = saved["fixture"] as! JSON
        if var project = fixture["project"] as? JSON, let path = project["root_path"] as? String,
           let prefix = oldWorkspaces.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            project["root_path"] = workspace.resolvingSymlinksInPath().path + path.dropFirst(prefix.count)
            fixture["project"] = project
        }
        return fixture
    }

    /// Canonical prerequisites for a batch/scope test. Domain writers retain
    /// all records, revisions and events; unrelated command journals and
    /// maintenance passes are not part of preparing this private phase.
    func coreFixtureTasksAndTriage(_ p: JSON,count: Int,titles: [String] = []) throws -> (JSON,[JSON]) {
        let taskInput = try fixtureTaskInput(router,method:"task_create",input:["project_id":p["id"]!,"title":"Fix input","brief":"Input responds correctly"])
        var group: JSON = [:],tasks: [JSON] = []
        try fixtureDomainTransaction { db in
            group = try router.groupWrite(db,["project_id":p["id"]!,"name":"Current handling","phase":"implementation","purpose":"Handle this selected batch together"],owner,"triage_create")
            for index in 0..<count {
                var input = taskInput
                if !titles.isEmpty {input["title"] = titles[index]}
                let initial = try router.taskCreate(db,input,owner)
                let task = try router.taskEdit(db,["project_id":p["id"]!,"task_id":initial["id"]!,"expected_revision":initial["revision"]!,"patch":["readiness":"ready"]],owner)
                tasks.append(task)
                group = try router.groupWrite(db,["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add","exit_milestone":"manual"],owner,"group_membership")
            }
        }
        return (group,tasks)
    }

    func preparedPolicyBatch() throws -> (project: JSON, tasks: [JSON], group: JSON, batch: JSON) {
        let fixture = try preparedCorePhase(orchestrateBatchTriages ? "policy-batch-orchestrated" : "policy-batch-plan") { [self] in
            let p = try project(), tasks = try [ready(p, task(p)), ready(p, task(p))], group = try triage(p)
            for task in tasks { try addTriage(p, group, task) }
            let batch = try prepareImplementationBatch(p, group, tasks)
            return ["project":p, "tasks":tasks, "group":group, "batch":batch]
        }
        return (fixture["project"] as! JSON, fixture["tasks"] as! [JSON], fixture["group"] as! JSON, fixture["batch"] as! JSON)
    }

    func preparedSubmittedArtifact(gates: [String] = ["review"], holdPassing: Bool = false) throws -> (project: JSON, task: JSON, artifact: JSON, submission: JSON) {
        let fixture = try preparedCorePhase("submitted-artifact-" + gates.joined(separator:"-") + (holdPassing ? "-held" : "")) { [self] in
            let value = try submittedArtifact(gates:gates,holdPassing:holdPassing)
            return ["project":value.project, "task":value.task, "artifact":value.artifact, "submission":value.submission]
        }
        let artifact = try router.dbQueue.read { db in
            router.ownerManagedPathProjection(try router.record(db,(fixture["artifact"] as! JSON)["id"] as! String,type:"attachment"),caller:owner)
        }
        return (fixture["project"] as! JSON, fixture["task"] as! JSON, artifact, fixture["submission"] as! JSON)
    }

    /// The verdict is the operation under test. The same independent, live
    /// review claim can seed every verdict branch without repeating submission,
    /// orchestration, preparation and claim commands in each private store.
    func preparedOwnerReviewClaim() throws -> (project: JSON, task: JSON, group: JSON, batch: JSON, claim: JSON, reviewer: Caller) {
        let fixture = try preparedCorePhase(orchestrateBatchTriages ? "owner-review-claim-orchestrated" : "owner-review-claim-plan") { [self] in
            let value = try submittedArtifact(), p = value.project, group = try triage(p,phase:"review")
            try addTriage(p,group,value.task)
            let reviewer = Caller(role:"owner",installation:"non-final-reviewer",projectIDs:[])
            let batch = try prepareReviewBatch(p,group,[value.task],reviewer)
            let claim = (try claimFixedBatch(p,batch,reviewer)["claims"] as! [JSON])[0]
            return ["project":p,"task":value.task,"group":group,"batch":batch,"claim":claim]
        }
        return (fixture["project"] as! JSON,fixture["task"] as! JSON,fixture["group"] as! JSON,fixture["batch"] as! JSON,fixture["claim"] as! JSON,Caller(role:"owner",installation:"non-final-reviewer",projectIDs:[]))
    }

    /// Keep scope preparation/claiming in the case, sharing only enrollment.
    /// No batch, frozen scope or reservation is copied from another workspace.
    func preparedCohortWorkers() throws -> (project: JSON, worker: Caller, other: Caller) {
        let fixture = try preparedCorePhase("cohort-workers") { [self] in
            let p = try cohortProject(), worker = try cohortWorker(p), other = try cohortWorker(p)
            return ["project":p,"worker":worker.sessionID!,"other":other.sessionID!]
        }
        func caller(_ id: String) throws -> Caller {
            let session = try router.dbQueue.read { try router.record($0,id,type:"session") }
            return Caller(role:"worker",installation:session["installation"] as! String,projectIDs:strings(session,"project_ids"),sessionID:id,workspace:session["workspace"] as? String,executionDomain:session["execution_domain"] as? String)
        }
        return (fixture["project"] as! JSON,try caller(fixture["worker"] as! String),try caller(fixture["other"] as! String))
    }
}
