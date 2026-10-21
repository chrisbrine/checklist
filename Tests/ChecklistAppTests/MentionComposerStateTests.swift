@testable import ChecklistApp
// First/unrun caller controls for the ONE coherent app/test target.
// Compile alongside actual MentionComposerState and unchanged draft helper.
// These prove caller state only, not installed SwiftUI focus or Store execution.
import XCTest
import CryptoKit

final class MentionComposerStateTests: XCTestCase {
    typealias S = MentionComposerState
    typealias D = MentionDraftResolution
    let body = "@Worker"
    func context(task: String = "task") -> D.Context {
        .init(storeIncarnation: .init("store"), projectID: .init("project"), taskID: .init(task), replyID: nil)
    }
    func target(_ id: String, generation: String = "g1") -> D.Target {
        .session(id: .init(id), authorizationGeneration: .init(generation))
    }
    func candidate(_ id: String, generation: String = "g1", project: String = "project") -> [String: Any] {
        ["project_id": project, "target": S.reference(target(id, generation: generation)), "label": "Worker", "provider": "codex"]
    }
    func result(_ state: String, body: String = "@Worker", candidates: [[String: Any]] = []) -> [String: Any] {
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        var value: [String: Any] = ["state": state, "body_sha256": digest, "parser": "ordinary-mentions-1", "tokens": []]
        if state == "prepared" { value["mention_target"] = "opaque-test-token" }
        if state == "needs_selection" {
            value["tokens"] = [["start": 0, "end": body.utf8.count, "query": "Worker", "state": candidates.isEmpty ? "not_found" : "ambiguous", "candidates": candidates]]
        }
        return value
    }
    func begin(_ state: inout S, body: String = "@Worker") throws -> S.Submission {
        state.observe(context: context(), body: body)
        return try XCTUnwrap(state.begin(expectedAttempt: "attempt"))
    }

    func testFreshSameBodyReorderRetiresPanelAndPreservesExactTargetIdentity() throws {
        var state = S(), first = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("a"), candidate("b")]), for: first, context: context(), body: body)
        let old = try XCTUnwrap(state.panel), span = try XCTUnwrap(old.tokens.first?.span)
        XCTAssertTrue(state.select(panelID: old.id, span: span, target: target("b")))
        first = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("c"), candidate("a"), candidate("b")]), for: first, context: context(), body: body)
        let fresh = try XCTUnwrap(state.panel)
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertEqual(fresh.tokens[0].candidates.map(\.id), [target("c"), target("a"), target("b")])
        XCTAssertFalse(state.select(panelID: old.id, span: span, target: target("c")))
        XCTAssertTrue(state.select(panelID: fresh.id, span: span, target: target("b")))
    }

    func testChoiceCannotSendAndNewUserPreparationAuthorizesOnlyOneSend() throws {
        var state = S();let first = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("a"), candidate("b")]), for: first, context: context(), body: body)
        let panel = try XCTUnwrap(state.panel), span = panel.tokens[0].span
        XCTAssertTrue(state.select(panelID: panel.id, span: span, target: target("b")))
        XCTAssertFalse(state.consumeSend(first, context: context(), body: body, expectedAttempt: "attempt"))
        let second = try begin(&state)
        let selection = try XCTUnwrap(second.selections.first)
        XCTAssertEqual(selection["start"] as? Int, 0)
        XCTAssertEqual((selection["target"] as? [String: Any])?["session_id"] as? String, "b")
        guard case .send(let token)? = try state.receive(result("prepared"), for: second, context: context(), body: body) else { return XCTFail("Expected prepared outcome") }
        XCTAssertEqual(token, "opaque-test-token")
        XCTAssertFalse(state.consumeSend(second, context: context(), body: body, expectedAttempt: "new handler"))
        XCTAssertTrue(state.consumeSend(second, context: context(), body: body, expectedAttempt: "attempt"))
        XCTAssertFalse(state.consumeSend(second, context: context(), body: body, expectedAttempt: "attempt"))
    }

    func testEditABAContextAndCloseReopenRejectPriorCallbackAndReadySend() throws {
        var state = S();let first = try begin(&state)
        state.observe(context: context(), body: "changed")
        state.observe(context: context(), body: body)
        XCTAssertNil(try state.receive(result("prepared"), for: first, context: context(), body: body))
        let second = try begin(&state)
        _ = try state.receive(result("prepared"), for: second, context: context(), body: body)
        state.observe(context: context(task: "other"), body: body)
        XCTAssertFalse(state.consumeSend(second, context: context(), body: body, expectedAttempt: "attempt"))
        let third = try begin(&state)
        state.cancel();state.observe(context: context(), body: body)
        XCTAssertNil(try state.receive(result("prepared"), for: third, context: context(), body: body))
    }

    func testUnknownTagHasNoFallbackAndEditDiscardsAllSpanSelections() throws {
        var state = S();let first = try begin(&state)
        _ = try state.receive(result("needs_selection"), for: first, context: context(), body: body)
        XCTAssertEqual(state.panel?.tokens.first?.state, "not_found")
        XCTAssertFalse(state.consumeSend(first, context: context(), body: body, expectedAttempt: "attempt"))
        let second = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("a"), candidate("b")]), for: second, context: context(), body: body)
        let panel = try XCTUnwrap(state.panel)
        XCTAssertTrue(state.select(panelID: panel.id, span: panel.tokens[0].span, target: target("a")))
        let edited = try begin(&state, body: "@Other")
        XCTAssertTrue(edited.selections.isEmpty)
        XCTAssertNil(state.panel)
    }

    func testMalformedHashForeignCandidateAndDuplicateIdentityNeverAuthorizeSend() throws {
        var state = S();let first = try begin(&state)
        var bad = result("prepared");bad["body_sha256"] = "wrong"
        XCTAssertThrowsError(try state.receive(bad, for: first, context: context(), body: body))
        XCTAssertFalse(state.consumeSend(first, context: context(), body: body, expectedAttempt: "attempt"))
        let second = try begin(&state)
        XCTAssertThrowsError(try state.receive(result("needs_selection", candidates: [candidate("a", project: "foreign"), candidate("b")]), for: second, context: context(), body: body))
        let third = try begin(&state)
        XCTAssertThrowsError(try state.receive(result("needs_selection", candidates: [candidate("a"), candidate("a")]), for: third, context: context(), body: body))
        XCTAssertNil(state.panel)
    }

    func testGenerationChangeRetiresRowsAndClearInvalidatesPendingSend() throws {
        var state = S();let first = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("a"), candidate("b")]), for: first, context: context(), body: body)
        let old = try XCTUnwrap(state.panel)
        let second = try begin(&state)
        _ = try state.receive(result("needs_selection", candidates: [candidate("a", generation: "g2"), candidate("b")]), for: second, context: context(), body: body)
        let fresh = try XCTUnwrap(state.panel)
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertFalse(state.select(panelID: fresh.id, span: fresh.tokens[0].span, target: target("a")))
        XCTAssertTrue(state.select(panelID: fresh.id, span: fresh.tokens[0].span, target: target("a", generation: "g2")))
        let third = try begin(&state)
        _ = try state.receive(result("prepared"), for: third, context: context(), body: body)
        state.clearSelections()
        XCTAssertFalse(state.consumeSend(third, context: context(), body: body, expectedAttempt: "attempt"))
    }
}
