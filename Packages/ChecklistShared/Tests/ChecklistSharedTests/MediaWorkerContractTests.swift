import Foundation
import XCTest
import ChecklistContracts

final class MediaWorkerContractTests: XCTestCase {
    private var write: [String: Any] { ["project_id": "project", "command_id": UUID().uuidString] }
    private let fixtureDigest = String(repeating: "a", count: 64)

    func testClosedWorkerCatalogAndReadClassification() throws {
        XCTAssertEqual(MediaWorkerContract.methods.count, 12)
        XCTAssertEqual(CommandMethods.mediaWorkerReads, MediaWorkerContract.readMethods)
        XCTAssertTrue(CommandMethods.mediaWorkerReads.isSubset(of: CommandMethods.coreReads))
        for method in MediaWorkerContract.methods {
            let schema = try XCTUnwrap(MediaWorkerContract.inputSchema(method))
            XCTAssertTrue(JSONSerialization.isValidJSONObject(schema), method)
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertEqual(required.contains("command_id"), !MediaWorkerContract.readMethods.contains(method))
        }
        for method in ["media_round_publish", "media_decide", "media_adopt_suggestion", "media_type_adopt", "media_item_create"] {
            XCTAssertNil(MediaWorkerContract.inputSchema(method), method)
            XCTAssertThrowsError(try MediaWorkerContract.validate(method, parameters: write), method)
        }
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_type_list", parameters: ["project_id": "project"]))
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_type_list", parameters: ["project_id": "project", "include_draft": true]))
    }

    func testThreeFileMetadataAndFiniteMapping() throws {
        var p = write
        p["round_id"] = "round"
        p["sources"] = (0..<3).map { i in ["path": "/workspace/take\(i).wav", "columns": [
            "character": "hero", "animation_label": "walk", "direction": "NE", "take": i,
        ]] }
        p["mapping"] = ["input": "selected_files", "assignments": [
            ["field_id": "character", "source": ["kind": "column", "column_id": "character"]],
            ["field_id": "animation_label", "source": ["kind": "stem_token", "delimiter": "__", "index": 1]],
        ]]
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_intake_preview", parameters: p))
        p["text"] = "another source"
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_preview", parameters: p))
        p.removeValue(forKey: "text")
        p["sources"] = [["path": "/workspace/a.wav", "columns": ["field": ["hidden": "object"]]]]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_preview", parameters: p))
        p["sources"] = [["path": "/workspace/a.wav", "origin": "human_ui"]]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_preview", parameters: p))
    }

    func testCaptureRequiresOriginalDistinctBoundedRowsAndRevision() throws {
        var p = write
        p.merge(["intake_id": "intake", "expected_revision": 2, "plan_id": "plan", "row_ids": ["a", "b", "c"]]) { _, new in new }
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_intake_capture", parameters: p))
        for invalid: Any in [[], ["a", "a"], Array(repeating: "a", count: 201), [" "]] {
            p["row_ids"] = invalid
            XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_capture", parameters: p))
        }
        p["row_ids"] = ["a"]
        for invalid: Any in [true, 0, 1.5, "1"] {
            p["expected_revision"] = invalid
            XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_capture", parameters: p))
        }
    }

    func testRevisionAndConfirmationEnvelopesRemainClosed() throws {
        var p = write
        p.merge(["intake_id": "intake", "expected_revision": 1, "plan_id": "plan", "plan_digest": fixtureDigest]) { _, new in new }
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_intake_confirm", parameters: p))
        p["plan_digest"] = "not-a-digest"
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_confirm", parameters: p))
        p.removeValue(forKey: "plan_id"); p.removeValue(forKey: "plan_digest")
        p["resolutions"] = [["row_id": "row", "disposition": "include", "slot_id": "take", "group_id": "hero"]]
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_intake_revise", parameters: p))
        p["resolutions"] = [["row_id": "row", "disposition": "include", "metadata": ["secret": "override"]]]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_intake_revise", parameters: p))
    }

    func testPagedReadsRejectWrongTypesAndProvenance() throws {
        for method in ["media_round_get", "media_decision_list"] {
            let p: [String: Any] = ["project_id": "project", "round_id": "round", "limit": 3, "cursor": "opaque"]
            XCTAssertNoThrow(try MediaWorkerContract.validate(method, parameters: p))
            for invalid: Any in [true, 0, 101, 1.5, "1"] {
                var bad = p; bad["limit"] = invalid
                XCTAssertThrowsError(try MediaWorkerContract.validate(method, parameters: bad))
            }
            var bad = p; bad["principal"] = "owner"
            XCTAssertThrowsError(try MediaWorkerContract.validate(method, parameters: bad))
            var window = p; window["cursor"] = String(repeating: "x", count: 70_000)
            if method == "media_round_get" {
                XCTAssertNoThrow(try MediaWorkerContract.validate(method, parameters: window))
            } else {
                XCTAssertThrowsError(try MediaWorkerContract.validate(method, parameters: window))
            }
        }
    }

    func testFoundationBooleanValidationPreservesJSONTypesIncludingSmallIntegers() throws {
        var p = write
        p.merge(["round_id": "round", "expected_revision": 4, "observed_context_token": "opaque", "manifest_id": "manifest",
            "manifest_digest": fixtureDigest, "disposition": "changes_requested", "items": [["item_id": "item",
                "expected_revision": 3, "target_id": "target", "review_basis_signature": fixtureDigest]]]) { _, new in new }
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[true,false,0,1,-1]".utf8)) as? [Any])
        for value: Any in [true, false, NSNumber(value: true), NSNumber(value: false), decoded[0], decoded[1]] {
            p["none_fit"] = value
            XCTAssertNoThrow(try MediaWorkerContract.validate("media_suggest", parameters: p))
            var revision = p;revision["expected_revision"] = value
            XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: revision))
        }
        for value: Any in [Int8(0), Int8(1), Int8(-1), UInt8(1), 0, 1, 1.0, NSNumber(value: Int8(1)), decoded[2], decoded[3], decoded[4]] {
            p["none_fit"] = value
            XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: p))
        }
    }

    func testSuggestionRequiresExactObservationAndTypedSelection() throws {
        var p = write
        let selection: [String: Any] = ["item_id": "item", "expected_revision": 3, "target_id": "target", "review_basis_signature": fixtureDigest]
        p.merge(["round_id": "round", "expected_revision": 4, "observed_context_token": "opaque", "manifest_id": "manifest",
            "manifest_digest": fixtureDigest, "disposition": "accepted", "winner_id": "candidate", "note": "Use this take.", "items": [selection]]) { _, new in new }
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_suggest", parameters: p))
        p["origin"] = "human_ui"
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: p))
        p.removeValue(forKey: "origin")
        var bad = selection; bad["none_fit"] = 1
        p["items"] = [bad]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: p))
        p["items"] = [selection, selection]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: p))
        p["items"] = [selection]; p.removeValue(forKey: "manifest_digest")
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_suggest", parameters: p))
        // CL-351: a Draft target has no manifest; the pair stays together.
        p.removeValue(forKey: "manifest_id")
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_suggest", parameters: p))
    }

    func testFollowUpNamesExactlyOneTicketOrReasonAndExactDecisions() throws {
        var p = write
        let selection: [String: Any] = ["item_id": "item", "expected_revision": 3, "decision_id": "decision"]
        p.merge(["round_id": "round", "expected_revision": 4, "observed_context_token": "opaque", "manifest_id": "manifest",
            "manifest_digest": fixtureDigest, "items": [selection], "task_id": "task"]) { _, new in new }
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p["reason"] = "Next production round"
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p.removeValue(forKey: "task_id")
        XCTAssertNoThrow(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p.removeValue(forKey: "reason")
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p["reason"] = "Next production round"; p["origin"] = "human_ui"
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p.removeValue(forKey: "origin"); p["items"] = [["item_id": "item", "expected_revision": 3]]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p["items"] = [selection, selection]
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
        p["items"] = [selection]; p.removeValue(forKey: "manifest_digest")
        XCTAssertThrowsError(try MediaWorkerContract.validate("media_follow_up_record", parameters: p))
    }
}
