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
        return saved["fixture"] as! JSON
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

    func preparedSubmittedArtifact() throws -> (project: JSON, task: JSON, artifact: JSON, submission: JSON) {
        let fixture = try preparedCorePhase("submitted-artifact") { [self] in
            let value = try submittedArtifact()
            return ["project":value.project, "task":value.task, "artifact":value.artifact, "submission":value.submission]
        }
        return (fixture["project"] as! JSON, fixture["task"] as! JSON, fixture["artifact"] as! JSON, fixture["submission"] as! JSON)
    }
}
