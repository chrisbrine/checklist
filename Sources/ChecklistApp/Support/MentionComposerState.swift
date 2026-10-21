import Foundation
import CoreFoundation
import CryptoKit

// State for this ordinary-note caller only. The service remains the routing and
// authority boundary; choices and text never confer a recipient grant.
struct MentionComposerState {
    typealias Draft = MentionDraftResolution
    struct Span: Hashable { let start: Int; let end: Int }
    struct Candidate: Identifiable {
        let target: Draft.Target
        let title: String
        let detail: String
        var id: Draft.Target { target }
    }
    struct Token: Identifiable {
        let span: Span
        let query: String
        let state: String
        let candidates: [Candidate]
        var selected: Draft.Target?
        var id: Span { span }
    }
    struct Panel: Identifiable {
        let id: UUID
        let snapshot: Draft.Snapshot
        var tokens: [Token]
    }
    struct Submission {
        let id: UUID
        let snapshot: Draft.Snapshot
        let expectedAttempt: Draft.ExactText
        let selections: [[String: Any]]
        var parameters: [String: Any] {
            ["project_id": snapshot.context.projectID.string, "task_id": snapshot.context.taskID.string,
             "body": snapshot.body.string, "selections": selections]
        }
    }
    enum Outcome { case needsSelection, send(mentionTarget: String?) }
    enum Failure: Error, LocalizedError {
        case invalidResponse
        var errorDescription: String? { "Mention targets changed or could not be read. Your note is preserved; refresh the targets before sending." }
    }

    private(set) var draft: Draft?
    private(set) var panel: Panel?
    private var selections: [Span: Draft.Target] = [:]
    private var pending: Submission?
    private var ready: Submission?

    mutating func observe(context: Draft.Context, body: String) {
        let previous = draft?.snapshot
        if draft == nil { draft = .init(context: context, body: body) }
        else { draft?.update(context: context, body: body) }
        if previous != draft?.snapshot { retire() }
    }
    mutating func cancel() { retire(); draft = nil }
    mutating func clearSelections() { retire() }
    private mutating func retire() { panel = nil; selections = [:]; pending = nil; ready = nil }

    mutating func begin(expectedAttempt: String) -> Submission? {
        guard let snapshot = draft?.snapshot else { return nil }
        let values = selections.sorted { $0.key.start < $1.key.start }.map {
            ["start": $0.key.start, "end": $0.key.end, "target": Self.reference($0.value)] as [String: Any]
        }
        let submission = Submission(id: UUID(), snapshot: snapshot, expectedAttempt: .init(expectedAttempt), selections: values)
        pending = submission; ready = nil
        return submission
    }

    mutating func receive(_ result: [String: Any], for submission: Submission,
                          context: Draft.Context, body: String) throws -> Outcome? {
        observe(context: context, body: body)
        guard pending?.id == submission.id, draft?.snapshot == submission.snapshot else { return nil }
        pending = nil; ready = nil
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        guard (result["body_sha256"] as? String)?.utf8.elementsEqual(digest.utf8) == true,
              result["parser"] as? String == "ordinary-mentions-1" else { throw Failure.invalidResponse }
        switch result["state"] as? String {
        case "needs_selection":
            let tokens = try Self.tokens(result["tokens"], snapshot: submission.snapshot)
            guard tokens.contains(where: { $0.state != "resolved" }) else { throw Failure.invalidResponse }
            selections = selections.filter { span, target in tokens.contains { $0.span == span && $0.candidates.contains { $0.target == target } } }
            panel = .init(id: UUID(), snapshot: submission.snapshot, tokens: tokens)
            return .needsSelection
        case "prepared":
            guard let target = result["mention_target"] as? String, !target.isEmpty else { throw Failure.invalidResponse }
            ready = submission
            return .send(mentionTarget: target)
        case "untagged":
            guard result["mention_target"] == nil, let tokens = result["tokens"] as? [Any], tokens.isEmpty else { throw Failure.invalidResponse }
            ready = submission
            return .send(mentionTarget: nil)
        default: throw Failure.invalidResponse
        }
    }

    mutating func select(panelID: UUID, span: Span, target: Draft.Target) -> Bool {
        guard var current = panel, current.id == panelID, current.snapshot == draft?.snapshot,
              let index = current.tokens.firstIndex(where: { $0.span == span }),
              current.tokens[index].candidates.contains(where: { $0.target == target }) else { return false }
        selections[span] = target; current.tokens[index].selected = target; panel = current
        return true // a choice never starts preparation or Send
    }
    mutating func consumeSend(_ submission: Submission, context: Draft.Context, body: String, expectedAttempt: String) -> Bool {
        observe(context: context, body: body)
        guard ready?.id == submission.id, draft?.snapshot == submission.snapshot,
              submission.expectedAttempt == .init(expectedAttempt) else { return false }
        ready = nil; panel = nil
        return true
    }

    private static func tokens(_ input: Any?, snapshot: Draft.Snapshot) throws -> [Token] {
        guard let values = input as? [[String: Any]], !values.isEmpty, values.count <= 50 else { throw Failure.invalidResponse }
        let bytes = snapshot.body.bytes
        var result: [Token] = [], previousEnd = 0
        for value in values {
            guard let start = offset(value["start"]), let end = offset(value["end"]),
                  start >= previousEnd, start < end, end <= bytes.count,
                  String(bytes: bytes[..<start], encoding: .utf8) != nil,
                  String(bytes: bytes[start..<end], encoding: .utf8) != nil,
                  String(bytes: bytes[end...], encoding: .utf8) != nil,
                  let query = value["query"] as? String, !query.isEmpty,
                  let state = value["state"] as? String, ["resolved", "ambiguous", "not_found"].contains(state),
                  let choices = value["candidates"] as? [[String: Any]] else { throw Failure.invalidResponse }
            var candidates: [Candidate] = [], seen: Set<Draft.Target> = []
            for choice in choices {
                guard let project = choice["project_id"] as? String, Draft.ExactText(project) == snapshot.context.projectID,
                      let reference = choice["target"] as? [String: Any] else { throw Failure.invalidResponse }
                let target = try Self.target(reference)
                guard seen.insert(target).inserted else { throw Failure.invalidResponse }
                let title: String, detail: String
                switch target {
                case .ticket(let id):
                    title = (choice["key"] as? String ?? "Ticket") + " · " + (choice["title"] as? String ?? "")
                    detail = "Ticket · " + id.string
                case .session(let id, _):
                    title = choice["label"] as? String ?? "Worker"
                    detail = (choice["provider"] as? String ?? "Worker") + " · " + id.string
                }
                candidates.append(.init(target: target, title: title, detail: detail))
            }
            let selected: Draft.Target?
            if state == "resolved" {
                guard let reference = value["target"] as? [String: Any] else { throw Failure.invalidResponse }
                let target = try Self.target(reference)
                guard candidates.contains(where: { $0.target == target }) else { throw Failure.invalidResponse }
                selected = target
            } else {
                guard value["target"] == nil, (state == "ambiguous" ? candidates.count > 1 : candidates.isEmpty) else { throw Failure.invalidResponse }
                selected = nil
            }
            result.append(.init(span: .init(start: start, end: end), query: query, state: state, candidates: candidates, selected: selected))
            previousEnd = end
        }
        return result
    }
    private static func offset(_ input: Any?) -> Int? {
        guard let value = input as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= 65536 else { return nil }
        return value.intValue
    }
    private static func target(_ reference: [String: Any]) throws -> Draft.Target {
        if reference["kind"] as? String == "ticket", Set(reference.keys) == ["kind", "task_id"],
           let id = reference["task_id"] as? String, !id.isEmpty { return .ticket(id: .init(id)) }
        if reference["kind"] as? String == "session", Set(reference.keys) == ["kind", "session_id", "authorization_generation"],
           let id = reference["session_id"] as? String, !id.isEmpty,
           let generation = reference["authorization_generation"] as? String, !generation.isEmpty {
            return .session(id: .init(id), authorizationGeneration: .init(generation))
        }
        throw Failure.invalidResponse
    }
    static func reference(_ target: Draft.Target) -> [String: Any] {
        switch target {
        case .ticket(let id): return ["kind": "ticket", "task_id": id.string]
        case .session(let id, let generation): return ["kind": "session", "session_id": id.string, "authorization_generation": generation.string]
        }
    }
}
