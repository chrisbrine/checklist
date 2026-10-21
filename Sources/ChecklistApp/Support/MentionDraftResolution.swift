import Foundation

// Private composer state only. Target values come from the scoped service
// resolver; they grant no authority and must be revalidated by preparation/Send.
struct MentionDraftResolution {
    // String's canonical-equivalence equality is unsuitable for opaque IDs or
    // deciding whether an asynchronous result still describes these exact bytes.
    struct ExactText: Equatable, Hashable, Sendable {
        let bytes: [UInt8]
        init(_ text: String) { bytes = Array(text.utf8) }
        var string: String { String(decoding: bytes, as: UTF8.self) }
    }

    struct Context: Equatable, Sendable {
        let storeIncarnation: ExactText
        let projectID: ExactText
        let taskID: ExactText
        let replyID: ExactText?
    }

    struct Snapshot: Equatable, Sendable {
        let context: Context
        let body: ExactText
        let revision: UUID
    }

    enum Target: Equatable, Hashable, Sendable {
        case ticket(id: ExactText)
        case session(id: ExactText, authorizationGeneration: ExactText)
    }

    struct Candidate: Equatable, Sendable {
        let target: Target
        // Explicit text edit supplied by the caller's mention UI. This unit
        // defines no token grammar and never turns a display label into a target.
        let replacement: ExactText
    }

    struct Request: Equatable, Sendable {
        let id: UUID
        let snapshot: Snapshot
        let range: Range<Int> // UTF-8 byte offsets in snapshot.body
    }

    enum Failure: Equatable, Sendable { case noMatches, inconsistentCandidates, unavailable }
    enum Phase: Equatable, Sendable {
        case idle
        case pending(Request)
        case choices(Request, [Candidate])
        case failed(Request, Failure)
    }

    struct ProposedEdit: Equatable, Sendable {
        let request: Request
        let target: Target
    }

    struct AppliedEdit: Equatable, Sendable {
        let before: Snapshot
        let after: Snapshot
        let replacementRange: Range<Int>
        let target: Target
    }

    private(set) var snapshot: Snapshot
    private(set) var phase: Phase = .idle

    init(context: Context, body: String) {
        snapshot = .init(context: context, body: .init(body), revision: UUID())
    }

    // Call on every existing note-binding/context update, before consuming a
    // result or edit. Even an A -> B -> A edit gets a distinct revision.
    mutating func update(context: Context, body: String) {
        let exactBody = ExactText(body)
        guard snapshot.context != context || snapshot.body != exactBody else { return }
        snapshot = .init(context: context, body: exactBody, revision: UUID())
        phase = .idle
    }

    // An invalid new query also invalidates an older menu/result.
    @discardableResult
    mutating func begin(range: Range<Int>) -> Request? {
        phase = .idle
        guard valid(range, in: snapshot.body.bytes) else { return nil }
        let request = Request(id: UUID(), snapshot: snapshot, range: range)
        phase = .pending(request)
        return request
    }

    mutating func cancel() { phase = .idle }

    // Caller first updates from the actual current binding. Only the one pending
    // request can complete; old failures cannot erase newer choices either.
    @discardableResult
    mutating func receive(_ candidates: [Candidate], for request: Request) -> Bool {
        guard case .pending(let pending) = phase, pending == request,
              snapshot == request.snapshot else { return false }
        var unique: [Candidate] = []
        for candidate in candidates {
            guard !candidate.replacement.bytes.isEmpty else {
                phase = .failed(request, .inconsistentCandidates); return true
            }
            if let previous = unique.first(where: { sameIdentity($0.target, candidate.target) }) {
                guard previous == candidate else {
                    phase = .failed(request, .inconsistentCandidates); return true
                }
            } else { unique.append(candidate) }
        }
        phase = unique.isEmpty ? .failed(request, .noMatches) : .choices(request, unique)
        return true
    }

    @discardableResult
    mutating func fail(_ request: Request) -> Bool {
        guard case .pending(let pending) = phase, pending == request,
              snapshot == request.snapshot else { return false }
        phase = .failed(request, .unavailable)
        return true
    }

    // There is no implicit first-match selection, including a single result.
    func propose(_ target: Target) -> ProposedEdit? {
        guard case .choices(let request, let candidates) = phase,
              candidates.contains(where: { $0.target == target }) else { return nil }
        return .init(request: request, target: target)
    }

    // Returns a body edit for the existing note binding, not permission to Send.
    // The caller must preserve the existing draft/recipient and command guards.
    mutating func apply(_ edit: ProposedEdit, currentContext: Context, currentBody: String) -> AppliedEdit? {
        update(context: currentContext, body: currentBody)
        guard case .choices(let request, let candidates) = phase,
              request == edit.request, snapshot == request.snapshot,
              let candidate = candidates.first(where: { $0.target == edit.target }) else { return nil }
        let before = snapshot, range = request.range, bytes = before.body.bytes
        let replaced = Array(bytes[..<range.lowerBound]) + candidate.replacement.bytes + Array(bytes[range.upperBound...])
        guard let body = String(bytes: replaced, encoding: .utf8) else { return nil }
        snapshot = .init(context: before.context, body: .init(body), revision: UUID())
        phase = .idle
        return .init(before: before, after: snapshot,
                     replacementRange: range.lowerBound..<(range.lowerBound + candidate.replacement.bytes.count),
                     target: candidate.target)
    }

    private func valid(_ range: Range<Int>, in bytes: [UInt8]) -> Bool {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
              range.upperBound <= bytes.count else { return false }
        return String(bytes: bytes[..<range.lowerBound], encoding: .utf8) != nil
            && String(bytes: bytes[range.lowerBound..<range.upperBound], encoding: .utf8) != nil
            && String(bytes: bytes[range.upperBound...], encoding: .utf8) != nil
    }

    private func sameIdentity(_ lhs: Target, _ rhs: Target) -> Bool {
        switch (lhs, rhs) {
        case (.ticket(let a), .ticket(let b)): return a == b
        case (.session(let a, _), .session(let b, _)): return a == b
        default: return false
        }
    }
}
