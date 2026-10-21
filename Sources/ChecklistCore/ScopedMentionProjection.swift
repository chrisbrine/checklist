// PRIVATE CANDIDATE. No service, parsing, identity, grant, liveness or delivery authority.
// Callers supply an already authorized snapshot and revalidate it before any send.
enum ScopedMentionProjection {
    // Swift String equality is canonically equivalent. Opaque IDs/generations must
    // instead keep their original UTF-8 bytes; this value never creates an identity.
    struct ExactText: Hashable, Sendable {
        let bytes: [UInt8]
        init(_ text: String) { bytes = Array(text.utf8) }
    }

    struct Context: Equatable, Sendable {
        let projectID: ExactText
        let taskID: ExactText
        let messageID: ExactText
    }
    struct Recipient: Hashable, Sendable {
        let projectID: ExactText
        let sessionID: ExactText
        let authorizationGeneration: ExactText
    }
    enum Target: Hashable, Sendable {
        case ticket(ExactText)
        case session(ExactText, authorizationGeneration: ExactText)
    }
    // Lookup text is prepared upstream. This unit adds no parser, case-folding
    // policy, label catalog or fallback from a stable reference to a display name.
    enum Lookup: Hashable, Sendable {
        case ticketKey(ExactText)
        case workerName(ExactText)
        case reference(Target)
    }
    struct Candidate: Sendable {
        let projectID: ExactText
        let aliases: [Lookup]
        let target: Target
        let recipients: [Recipient]
    }
    struct Selection: Equatable, Sendable {
        let target: Target
        let recipients: [Recipient]
    }
    enum Form: Sendable { case topLevel, reply }
    struct Projection: Equatable, Sendable {
        let context: Context
        let taggedTargets: [Target]
        let recipients: [Recipient]
    }
    enum Failure: Error, Equatable, Sendable {
        case missingMention(Lookup)
        case ambiguousMention(Lookup, [Target])
        case inconsistentCandidate(Target)
        case outOfScopeRecipient
        case conflictingGeneration(ExactText)
    }

    static func resolve(projectID: ExactText, lookup: Lookup,
                        candidates: [Candidate]) -> Result<Selection, Failure> {
        var matches: [Selection] = []
        for candidate in candidates where candidate.projectID == projectID {
            let matchesLookup: Bool
            if case .reference(let target) = lookup {
                matchesLookup = candidate.target == target
            } else {
                matchesLookup = candidate.aliases.contains(lookup)
            }
            guard matchesLookup else { continue }
            let recipients: [Recipient]
            switch uniqueRecipients(candidate.recipients, projectID: projectID) {
            case .success(let routes): recipients = routes
            case .failure: return .failure(.inconsistentCandidate(candidate.target))
            }
            if case .session(let sessionID, let generation) = candidate.target {
                guard recipients.count == 1, recipients[0].sessionID == sessionID,
                      recipients[0].authorizationGeneration == generation else {
                    return .failure(.inconsistentCandidate(candidate.target))
                }
            }
            let selection = Selection(target: candidate.target, recipients: recipients)
            if let existing = matches.first(where: { $0.target == selection.target }) {
                guard Set(existing.recipients) == Set(selection.recipients) else {
                    return .failure(.inconsistentCandidate(candidate.target))
                }
            } else { matches.append(selection) }
        }
        guard let selected = matches.first else { return .failure(.missingMention(lookup)) }
        guard matches.count == 1 else {
            return .failure(.ambiguousMention(lookup, matches.map(\.target)))
        }
        return .success(selected)
    }

    // Ordinary comments/replies ONLY. Protected owner directions and human-answer
    // fanout must continue using their separate existing contract.
    // No history, prior-author or coordinator subscription is an input here.
    static func project(context: Context, form: Form, currentHandlers: [Recipient],
                        tags: [Lookup], candidates: [Candidate]) -> Result<Projection, Failure> {
        var selected: [Selection] = []
        for lookup in tags {
            switch resolve(projectID: context.projectID, lookup: lookup, candidates: candidates) {
            case .failure(let error): return .failure(error) // no partial projection
            case .success(let selection):
                if let existing = selected.first(where: { $0.target == selection.target }) {
                    guard Set(existing.recipients) == Set(selection.recipients) else {
                        return .failure(.inconsistentCandidate(selection.target))
                    }
                } else { selected.append(selection) }
            }
        }
        let base: [Recipient]
        switch form {
        case .reply where !tags.isEmpty: base = []
        default: base = currentHandlers
        }
        return uniqueRecipients(base + selected.flatMap(\.recipients), projectID: context.projectID).map {
            Projection(context: context, taggedTargets: selected.map(\.target), recipients: $0)
        }
    }

    // Preserve first input order, deduplicate only exact descriptors, and refuse
    // mixed generations of one exact session instead of choosing one snapshot.
    private static func uniqueRecipients(_ input: [Recipient], projectID: ExactText) -> Result<[Recipient], Failure> {
        var output: [Recipient] = []
        var seen: Set<Recipient> = []
        var generations: [ExactText: ExactText] = [:]
        for recipient in input {
            guard recipient.projectID == projectID else { return .failure(.outOfScopeRecipient) }
            if let generation = generations[recipient.sessionID],
               generation != recipient.authorizationGeneration {
                return .failure(.conflictingGeneration(recipient.sessionID))
            }
            generations[recipient.sessionID] = recipient.authorizationGeneration
            if seen.insert(recipient).inserted { output.append(recipient) }
        }
        return .success(output)
    }
}
