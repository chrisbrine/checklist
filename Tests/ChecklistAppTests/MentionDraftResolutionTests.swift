@testable import ChecklistApp
import Foundation
import XCTest

// Prepared source only; not compiled or executed. In a bounded source unit this
// file is compiled alongside MentionDraftResolution.swift, without App/Store.
final class MentionDraftResolutionTests: XCTestCase {
    private typealias M = MentionDraftResolution
    private func context(store: String = "store", project: String = "project", task: String = "task", reply: String? = nil) -> M.Context {
        .init(storeIncarnation: .init(store), projectID: .init(project), taskID: .init(task), replyID: reply.map { .init($0) })
    }
    private func ticket(_ id: String = "ticket", replacement: String = "@CL-12") -> M.Candidate {
        .init(target: .ticket(id: .init(id)), replacement: .init(replacement))
    }
    private func session(_ id: String = "session", generation: String = "g1") -> M.Candidate {
        .init(target: .session(id: .init(id), authorizationGeneration: .init(generation)), replacement: .init("@worker"))
    }
    private func choices(_ state: M) -> [M.Candidate] {
        guard case .choices(_, let candidates) = state.phase else { return [] }
        return candidates
    }

    func testAmbiguityRequiresExplicitExactTargetAndAppliesOnlyItsEdit() throws {
        var state = M(context: context(), body: "Ask @CL")
        let request = try XCTUnwrap(state.begin(range: 4..<7))
        let a = ticket("a"), b = ticket("b")
        XCTAssertTrue(state.receive([a, b], for: request))
        XCTAssertEqual(choices(state), [a, b])
        XCTAssertNil(state.propose(ticket("absent").target))
        let proposal = try XCTUnwrap(state.propose(b.target))
        let edit = try XCTUnwrap(state.apply(proposal, currentContext: context(), currentBody: "Ask @CL"))
        XCTAssertEqual(edit.after.body.string, "Ask @CL-12")
        XCTAssertEqual(edit.target, b.target)
        XCTAssertEqual(edit.replacementRange, 4..<10)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.apply(proposal, currentContext: context(), currentBody: edit.after.body.string))
    }

    func testBodyEditRefusesLateResolutionAndOldProposal() throws {
        var state = M(context: context(), body: "@CL")
        let old = try XCTUnwrap(state.begin(range: 0..<3))
        state.update(context: context(), body: "@worker")
        XCTAssertFalse(state.receive([ticket()], for: old))
        let current = try XCTUnwrap(state.begin(range: 0..<7))
        XCTAssertTrue(state.receive([session()], for: current))
        let proposal = try XCTUnwrap(state.propose(session().target))
        XCTAssertNil(state.apply(proposal, currentContext: context(), currentBody: "edited @worker"))
        XCTAssertEqual(state.snapshot.body.string, "edited @worker")
    }

    func testBodyABAAndContextABAHaveNewRevision() throws {
        var state = M(context: context(), body: "@CL")
        let original = try XCTUnwrap(state.begin(range: 0..<3))
        state.update(context: context(), body: "other")
        state.update(context: context(), body: "@CL")
        XCTAssertNotEqual(state.snapshot.revision, original.snapshot.revision)
        XCTAssertFalse(state.receive([ticket()], for: original))
        let next = try XCTUnwrap(state.begin(range: 0..<3))
        state.update(context: context(task: "different"), body: "@CL")
        state.update(context: context(), body: "@CL")
        XCTAssertFalse(state.receive([ticket()], for: next))
    }

    func testStoreProjectTaskAndReplyChangesEachInvalidatePendingResult() throws {
        for changed in [context(store: "new"), context(project: "new"), context(task: "new"), context(reply: "reply")] {
            var state = M(context: context(), body: "@CL")
            let request = try XCTUnwrap(state.begin(range: 0..<3))
            state.update(context: changed, body: "@CL")
            XCTAssertFalse(state.receive([ticket()], for: request))
            XCTAssertEqual(state.phase, .idle)
        }
    }

    func testExactUTF8IdentityAndBodyDoNotUseCanonicalEquivalence() throws {
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        var state = M(context: context(task: composed), body: "@" + composed)
        let request = try XCTUnwrap(state.begin(range: 0..<state.snapshot.body.bytes.count))
        state.update(context: context(task: decomposed), body: "@" + composed)
        XCTAssertFalse(state.receive([ticket()], for: request))
        let next = try XCTUnwrap(state.begin(range: 0..<state.snapshot.body.bytes.count))
        state.update(context: context(task: decomposed), body: "@" + decomposed)
        XCTAssertFalse(state.receive([ticket()], for: next))
        XCTAssertNotEqual(ticket(composed).target, ticket(decomposed).target)
    }

    func testSupersededRequestAndLateFailureCannotReplaceCurrentChoices() throws {
        var state = M(context: context(), body: "@CL @worker")
        let old = try XCTUnwrap(state.begin(range: 0..<3))
        let current = try XCTUnwrap(state.begin(range: 4..<11))
        XCTAssertFalse(state.receive([ticket()], for: old))
        XCTAssertTrue(state.receive([session()], for: current))
        XCTAssertFalse(state.fail(old))
        XCTAssertFalse(state.receive([ticket()], for: current))
        XCTAssertEqual(choices(state), [session()])
    }

    func testCancelAndInvalidNewQueryFencePreviouslyReadyEdit() throws {
        var state = M(context: context(), body: "@CL")
        let request = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([ticket()], for: request))
        let proposal = try XCTUnwrap(state.propose(ticket().target))
        state.cancel()
        XCTAssertNil(state.apply(proposal, currentContext: context(), currentBody: "@CL"))
        let next = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([ticket()], for: next))
        XCTAssertNil(state.begin(range: 0..<0))
        XCTAssertNil(state.propose(ticket().target))
    }

    func testMissingAndUnavailableResultsDoNotChooseAnyTarget() throws {
        var state = M(context: context(), body: "@CL")
        let request = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([], for: request))
        XCTAssertEqual(state.phase, .failed(request, .noMatches))
        let next = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.fail(next))
        XCTAssertEqual(state.phase, .failed(next, .unavailable))
        XCTAssertNil(state.propose(ticket().target))
    }

    func testMatchingDuplicateCandidatesDeduplicateButConflictingSnapshotsRefuse() throws {
        var state = M(context: context(), body: "@CL")
        let request = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([ticket(), ticket()], for: request))
        XCTAssertEqual(choices(state), [ticket()])
        let changedLabel = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([ticket(), ticket(replacement: "@different")], for: changedLabel))
        XCTAssertEqual(state.phase, .failed(changedLabel, .inconsistentCandidates))
        let changedGeneration = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([session(), session(generation: "g2")], for: changedGeneration))
        XCTAssertEqual(state.phase, .failed(changedGeneration, .inconsistentCandidates))
    }

    func testEmptyReplacementCannotEraseDraftOrProduceSelection() throws {
        var state = M(context: context(), body: "@CL")
        let request = try XCTUnwrap(state.begin(range: 0..<3))
        XCTAssertTrue(state.receive([ticket(replacement: "")], for: request))
        XCTAssertEqual(state.phase, .failed(request, .inconsistentCandidates))
        XCTAssertEqual(state.snapshot.body.string, "@CL")
    }

    func testUTF8ByteRangesRefuseSplitCharactersAndPreserveSurroundingBytes() throws {
        var state = M(context: context(), body: "🙂 @CL e\u{0301}")
        XCTAssertNil(state.begin(range: 1..<4))
        XCTAssertNil(state.begin(range: 0..<1))
        XCTAssertNil(state.begin(range: -1..<1))
        XCTAssertNil(state.begin(range: 0..<100))
        let request = try XCTUnwrap(state.begin(range: 5..<8))
        XCTAssertTrue(state.receive([ticket()], for: request))
        let proposal = try XCTUnwrap(state.propose(ticket().target))
        let edit = try XCTUnwrap(state.apply(proposal, currentContext: context(), currentBody: "🙂 @CL e\u{0301}"))
        XCTAssertEqual(edit.after.body.bytes, Array("🙂 @CL-12 e\u{0301}".utf8))
    }

    func testUnchangedBindingRefreshDoesNotInvalidateExplicitChoice() throws {
        var state = M(context: context(), body: "@CL")
        let request = try XCTUnwrap(state.begin(range: 0..<3))
        state.update(context: context(), body: "@CL")
        XCTAssertEqual(state.snapshot, request.snapshot)
        XCTAssertTrue(state.receive([ticket()], for: request))
        let proposal = try XCTUnwrap(state.propose(ticket().target))
        XCTAssertNotNil(state.apply(proposal, currentContext: context(), currentBody: "@CL"))
    }
}
