import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testPortableProjectExportOmitsRuntimeAuthorityFromRecordsProfilesAndEvents() throws {
        let p = try project("Portable history"), t = try ready(p, task(p))
        let profile = try call("profile_create", ["display_name": "Historical assistant"])
        let sid = "portable-history-session"
        _ = try call("session_register", ["project_id": p["id"]!, "session_id": sid,
            "role": "assistant", "provider": "codex", "profile_id": profile["id"]!,
            "assistant_grants": [p["id"] as! String: fullAssistantPermissions]])
        let attempt = try call("work_claim", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!])
        let text = "Keep the literal words token_hash, native_endpoint and api_key in this owner's note."
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": text])
        let authority: JSON = ["token_hash": "PRIVATE-TOKEN-HASH", "claim_token": "PRIVATE-CLAIM-TOKEN",
            "credential": "PRIVATE-CREDENTIAL", "native_endpoint": "/private/PRIVATE-NATIVE-ENDPOINT.sock",
            "native_binding": ["installation": "PRIVATE-NATIVE-BINDING"], "execution_domain": "PRIVATE-EXECUTION-DOMAIN",
            "session_authorization_generation": "PRIVATE-SESSION-GENERATION", "grant_generation": "PRIVATE-GRANT-GENERATION",
            "recipient_authorization_generation": "PRIVATE-RECIPIENT-GENERATION",
            "reply_sender_authorization_generation": "PRIVATE-REPLY-GENERATION",
            "assistant_grants": [p["id"] as! String: ["read": true]], "route_generation": "PRIVATE-ROUTE-GENERATION"]
        try router.dbQueue.write { db in
            for (id, type) in [(sid, "session"), (profile["id"] as! String, "profile"), (attempt["id"] as! String, "attempt"), (note["id"] as! String, "message")] {
                var value = try router.record(db, id, type: type)
                for (key, field) in authority { value[key] = field }
                value["historical_details"] = ["nested": [authority], "source_session_id": sid,
                    "actor_display": "Historical author", "state": "active", "revision": 7,
                    "settings_generation": "preserved-settings-generation", "observed_context_token": "preserved-media-token"]
                try router.save(db, value, type: type)
            }
            try router.event(db, caller: owner, project: p["id"] as? String, entity: t["id"] as? String,
                kind: "portable_authority_fixture", data: ["session": authority, "history": [["runtime": authority]],
                    "source_session_id": sid, "actor_display": "Historical author", "detail": text])
        }
        let destination = directory.appendingPathComponent("portable-authority-export")
        _ = try call("export_project", ["project_id": p["id"]!, "path": destination.path])
        let bytes = try Data(contentsOf: destination.appendingPathComponent("project.json"))
        let encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE-"))
        let exported = try JSONSerialization.jsonObject(with: bytes) as! JSON
        let message = (exported["message"] as! [JSON]).first { $0["id"] as? String == note["id"] as? String }!
        XCTAssertEqual(message["body"] as? String, text)
        let session = (exported["session"] as! [JSON]).first { $0["id"] as? String == sid }!
        XCTAssertEqual(session["profile_id"] as? String, profile["id"] as? String)
        XCTAssertEqual(session["project_ids"] as? [String], [p["id"] as! String])
        XCTAssertNil(session["authorization_generation"])
        XCTAssertNil(session["assistant_grants"])
        XCTAssertNil(session["execution_domain"])
        let details = session["historical_details"] as! JSON
        XCTAssertEqual(details["source_session_id"] as? String, sid)
        XCTAssertEqual(details["actor_display"] as? String, "Historical author")
        XCTAssertEqual(details["state"] as? String, "active")
        XCTAssertEqual(details["revision"] as? Int, 7)
        XCTAssertEqual(details["settings_generation"] as? String, "preserved-settings-generation")
        XCTAssertEqual(details["observed_context_token"] as? String, "preserved-media-token")
        let exportedProfile = (exported["profiles"] as! [JSON]).first { $0["id"] as? String == profile["id"] as? String }!
        XCTAssertEqual(exportedProfile["display_name"] as? String, "Historical assistant")
        let event = (exported["events"] as! [JSON]).first { $0["kind"] as? String == "portable_authority_fixture" }!
        XCTAssertEqual(event["actor"] as? String, owner.principal)
        XCTAssertEqual((event["data"] as! JSON)["detail"] as? String, text)
        XCTAssertEqual((event["data"] as! JSON)["source_session_id"] as? String, sid)
        // Export does not edit canonical history or the authority that full recovery must fence.
        let retained = try router.dbQueue.read { try router.record($0, sid, type: "session") }
        XCTAssertEqual(retained["native_endpoint"] as? String, authority["native_endpoint"] as? String)
        XCTAssertEqual(retained["token_hash"] as? String, authority["token_hash"] as? String)
    }
}
