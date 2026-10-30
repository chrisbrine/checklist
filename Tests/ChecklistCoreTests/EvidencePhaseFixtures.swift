import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private static let phaseTemplates = LockedTestState([String: TestStore.Template]())
    private static let phaseKey = "test-evidence-phase"

    /// Prepare prerequisite commands once, retaining their real records and
    /// history. Every use receives an APFS-cloned store, managed files and Git
    /// workspace; the operation and assertions under test run on that copy.
    func preparedPhase(_ name: String, prepare: @escaping (EvidenceAuthorityTests) throws -> JSON) throws -> JSON {
        let template = Self.phaseTemplates.withLock { templates in
            if let cached = templates[name] { return cached }
            let made = TestStore.Template(name: "EvidenceAuthorityTests-phase-" + name) { router, workspace in
                let fixture = EvidenceAuthorityTests()
                fixture.router = router; fixture.workspace = workspace
                fixture.directory = workspace.deletingLastPathComponent()
                let payload = try prepare(fixture)
                try router.dbQueue.write { db in
                    var manifests: JSON = [:], captures: JSON = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT id,type,data FROM records WHERE type IN ('manifest','source_capture')") {
                        let id: String = row["id"], type: String = row["type"], literal: String = row["data"]
                        if type == "manifest" { manifests[id] = literal }
                        else {
                            let capture = jsonObject(literal)
                            captures[id] = ["sha256":capture["sha256"]!,"files":capture["files"]!]
                        }
                    }
                    try db.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?)", arguments: [Self.phaseKey, try jsonString(["workspace": workspace.path, "physical_workspace": router.reservationKey(workspace.path), "payload": payload, "manifests": manifests, "captures": captures])])
                }
            }
            templates[name] = made
            return made
        }
        try router.closeStore()
        let phase = directory.appendingPathComponent("phase-" + UUID().uuidString, isDirectory: true)
        workspace = phase.appendingPathComponent("workspace", isDirectory: true)
        router = try TestStore.router(root: phase.appendingPathComponent("store"), template: template, workspace: workspace)
        clearPreparedProject()
        return try router.dbQueue.write { db in
            let saved = jsonObject(try XCTUnwrap(String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [Self.phaseKey])))
            let original = try XCTUnwrap(saved["workspace"] as? String)
            let physicalOriginal = try XCTUnwrap(saved["physical_workspace"] as? String)
            let current = workspace.resolvingSymlinksInPath().path
            let currentKey = router.reservationKey(current)
            // Relocate named canonical authority fields only. Frozen manifests,
            // evidence, history, receipts and returned snapshots stay literal.
            func relocatePath(_ text: String) -> String {
                // /tmp metadata and physical /private/tmp reservations describe
                // the same source fixture. Capture both while it still exists.
                for prefix in [original, physicalOriginal] {
                    if text == prefix || text.hasPrefix(prefix + "/") { return current + text.dropFirst(prefix.count) }
                    let oldKey = prefix.lowercased()
                    if text == oldKey || text.hasPrefix(oldKey + "/") { return current + text.dropFirst(oldKey.count) }
                }
                return text
            }
            for row in try Row.fetchAll(db, sql: "SELECT id,type,data FROM records WHERE type IN ('session','attempt','delegation','source_capture')") {
                var value = jsonObject(row["data"])
                let type: String = row["type"]
                if type == "session", let path = value["workspace"] as? String { value["workspace"] = relocatePath(path) }
                if type == "attempt" || type == "delegation", let scopes = value["file_scopes"] as? [JSON] {
                    value["file_scopes"] = scopes.map { scope in
                        var scope = scope
                        for key in ["path","canonical_key","declared_path"] {
                            if let path = scope[key] as? String {
                                let relocated = relocatePath(path)
                                scope[key] = key == "declared_path" ? relocated : router.reservationKey(relocated)
                            }
                        }
                        return scope
                    }
                }
                if type == "attempt", value["incarnation"] != nil { value["incarnation"] = router.incarnation }
                if type == "attempt" {
                    for scope in value["file_scopes"] as? [JSON] ?? [] {
                        let path = try XCTUnwrap(scope["path"] as? String), key = router.reservationKey(path)
                        XCTAssertTrue(key == currentKey || key.hasPrefix(currentKey + "/"), "Every copied attempt scope must address its private cloned project root")
                        XCTAssertEqual(scope["canonical_key"] as? String, key)
                        if let declared = scope["declared_path"] as? String {
                            let declaredKey = router.reservationKey(declared)
                            XCTAssertTrue(declaredKey == currentKey || declaredKey.hasPrefix(currentKey + "/"))
                        }
                    }
                }
                if type == "source_capture", let path = value["source_root"] as? String { value["source_root"] = relocatePath(path) }
                try router.save(db, value, type: type)
                if type == "source_capture", let path = value["snapshot_path"] as? String {
                    let source = try router.managedURL(path, family: "source-captures")
                    try Data((try jsonString(value)).utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("manifest.json"), options: .atomic)
                    let expected = (saved["captures"] as! JSON)[value["id"] as! String] as! JSON
                    XCTAssertEqual(value["sha256"] as? String, expected["sha256"] as? String)
                    XCTAssertEqual(try jsonString(["files":value["files"]!]), try jsonString(["files":expected["files"]!]))
                    try router.validateCapturedFiles(value)
                }
            }
            for (id, expected) in saved["manifests"] as! JSON {
                let literal = try XCTUnwrap(String.fetchOne(db, sql: "SELECT data FROM records WHERE id=? AND type='manifest'", arguments: [id]))
                XCTAssertEqual(literal, expected as? String, "A prepared phase must preserve the exact frozen manifest bytes")
                let manifest = jsonObject(literal), evidence = try XCTUnwrap(manifest["evidence"] as? JSON)
                XCTAssertEqual(manifest["digest"] as? String, ChecklistCore.hash(Data((try jsonString(evidence)).utf8)))
            }
            var payload = saved["payload"] as! JSON
            if var project = payload["project"] as? JSON, let path = project["root_path"] as? String {
                project["root_path"] = relocatePath(path); payload["project"] = project
            }
            return payload
        }
    }

    /// Reconstruct the same enrolled synthetic caller with its copied workspace.
    func phaseCaller(_ sessionID: Any) throws -> Caller {
        let session = try router.dbQueue.read { try router.record($0, sessionID as! String, type: "session") }
        return Caller(role: session["role"] as! String, installation: session["installation"] as! String,
                      projectIDs: strings(session, "project_ids"), sessionID: session["id"] as? String,
                      workspace: session["workspace"] as? String, executionDomain: session["execution_domain"] as? String)
    }

    func nativeSourceReviewPhase() throws -> (JSON, JSON, JSON, JSON, Caller, Caller) {
        let f = try preparedPhase("native-source-review") { fixture in
            try fixture.sourceFixture()
            let p = try fixture.project(), task = try fixture.ready(p)
            let author = try fixture.native(p, "phase-author", domain: "codex:evidence-phase")
            let reviewer = try fixture.native(p, "phase-reviewer", domain: "claude:evidence-phase", provider: "claude")
            let attempt = try fixture.claim(p, task, caller: author)
            var input = fixture.auth(p, attempt); input["acceptance_revision"] = 1
            input["evidence_manifest"] = ["kind": "source", "source_capture": [:]]
            let submitted = try fixture.call("work_submit", input, author)
            let review = try fixture.reviewClaim(p, submitted, reviewer)
            return ["project": p, "task": task, "submitted": submitted, "review": review,
                    "author": author.sessionID!, "reviewer": reviewer.sessionID!]
        }
        return (f["project"] as! JSON, f["task"] as! JSON, f["submitted"] as! JSON, f["review"] as! JSON,
                try phaseCaller(f["author"]!), try phaseCaller(f["reviewer"]!))
    }
}
