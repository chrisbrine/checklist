import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testTaskEditRejectsUnknownEnumValuesAtomically() throws {
        let p = try project(), t = try task(p)
        for field in ["kind", "readiness", "priority"] {
            for value: Any in ["unsupported", "", 42, NSNull()] {
                assertCode("INVALID_INPUT") {
                    _ = try self.call("task_edit", ["project_id":p["id"]!, "task_id":t["id"]!, "expected_revision":t["revision"]!, "patch":[field:value, "title":"Must not persist"]])
                }
                let unchanged = try call("task_get", ["project_id":p["id"]!, "task_id":t["id"]!])
                XCTAssertEqual(unchanged["revision"] as? Int, t["revision"] as? Int)
                XCTAssertEqual(unchanged["title"] as? String, t["title"] as? String)
            }
        }
    }

    func testClaimedTaskCannotSwitchKindToQuestion() throws {
        let p = try project(), t = try ready(p, task(p))
        let attempt = try call("work_claim", ["project_id":p["id"]!, "task_id":t["id"]!, "expected_revision":t["revision"]!])
        let active = try call("task_get", ["project_id":p["id"]!, "task_id":t["id"]!])
        assertCode("CLAIM_CONFLICT") {
            _ = try self.call("task_edit", ["project_id":p["id"]!, "task_id":t["id"]!, "expected_revision":active["revision"]!, "patch":["kind":"question"]])
        }
        let current = try call("task_get", ["project_id":p["id"]!, "task_id":t["id"]!])
        XCTAssertEqual(current["kind"] as? String, "work")
        XCTAssertEqual(current["active_attempt_id"] as? String, attempt["id"] as? String)
        // Same-kind edits remain ordinary metadata; legitimate priority/readiness values still work.
        let edited = try call("task_edit", ["project_id":p["id"]!, "task_id":t["id"]!, "expected_revision":current["revision"]!, "patch":["kind":"work", "priority":"high", "readiness":"ready"]])
        XCTAssertEqual(edited["priority"] as? String, "high")
        XCTAssertEqual(edited["active_attempt_id"] as? String, attempt["id"] as? String)
    }

    func testUnclaimedTaskCanChangeToEverySupportedKind() throws {
        let p = try project(); var t = try task(p)
        for kind in ["bug", "asset", "playtest", "question", "work"] {
            t = try call("task_edit", ["project_id":p["id"]!, "task_id":t["id"]!, "expected_revision":t["revision"]!, "patch":["kind":kind]])
            XCTAssertEqual(t["kind"] as? String, kind)
        }
    }
}
