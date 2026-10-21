import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testIndividualClaimReportsActualTriageDepartureAndReplaysReceipt() throws {
        let p = try project(), t = try ready(p, task(p)), g = try triage(p)
        try addTriage(p, g, t)
        let input: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!]
        let command = UUID().uuidString
        let result = try call("work_claim", input, nil, command)
        let effect = result["triage_effect"] as! JSON
        XCTAssertEqual(int(effect, "removed_count"), 1)
        XCTAssertEqual((effect["removed_memberships"] as! [JSON]).first?["triage_id"] as? String, g["id"] as? String)
        try assertEmptyTriage(p, g)
        let replay = try call("work_claim", input, nil, command)
        XCTAssertEqual(try jsonString(effect), try jsonString(replay["triage_effect"] as! JSON))
    }
}
