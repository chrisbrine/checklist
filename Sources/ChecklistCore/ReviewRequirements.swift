import ChecklistDomain
import Foundation
import CryptoKit

enum ReviewRequirementError: Error { case invalid(String) }

/// Opaque identities compare their original UTF-8 bytes, never Unicode aliases.
struct ReviewRequirementID: Hashable {
    let text: String
    private let bytes: Data
    init(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256 else {
            throw ReviewRequirementError.invalid("Use a nonempty bounded identity.")
        }
        self.text = text; self.bytes = Data(text.utf8)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

// Compatibility name; the shared definition owns these wire values.
typealias ReviewRequirementKind = TicketKind
enum ReviewRequirementEvidenceType: String, CaseIterable, Hashable {
    case reviewerReport = "reviewer_report", sourceCapture = "source_capture", image, textRecord = "text_record"
}

struct ReviewRequirementPolicyIdentity {
    let projectID: ReviewRequirementID
    let revision: Int
    let digest: String
    init(projectID: String, revision: Int, digest: String) throws {
        guard revision > 0, reviewRequirementDigestIsValid(digest) else {
            throw ReviewRequirementError.invalid("Use the canonical policy revision and SHA-256.")
        }
        self.projectID = try ReviewRequirementID(projectID); self.revision = revision; self.digest = digest
    }
}

private func reviewRequirementDigestIsValid(_ digest: String) -> Bool {
    digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

struct ReviewRequirement {
    struct Check { let id: ReviewRequirementID; let text: String }
    let checks: [Check]
    let rejectBar: String
    let requiredEvidenceTypes: Set<ReviewRequirementEvidenceType>

    static let generic = ReviewRequirement(
        checks: [Check(id: try! ReviewRequirementID("acceptance"), text: "Assess every applicable acceptance and project requirement on the exact target.")],
        rejectBar: "Reject a supported unmet requirement or actionable defect. Report blocked when necessary evidence or access is unavailable.",
        requiredEvidenceTypes: [])

    static func parse(_ raw: Any) throws -> Self {
        guard let value = raw as? [String: Any], Set(value.keys) == ["checks", "reject_bar", "required_evidence_types"],
              let rawChecks = value["checks"] as? [[String: Any]], rawChecks.count <= 20,
              let rejectBar = value["reject_bar"] as? String, validText(rejectBar, limit: 4000),
              let rawTypes = value["required_evidence_types"] as? [String], rawTypes.count <= 4 else {
            throw ReviewRequirementError.invalid("A complete bounded review requirement is required.")
        }
        var checks: [Check] = [], ids = Set<ReviewRequirementID>(), types = Set<ReviewRequirementEvidenceType>()
        for entry in rawChecks {
            guard Set(entry.keys) == ["id", "text"], let id = entry["id"] as? String,
                  let text = entry["text"] as? String, validText(text, limit: 2000) else {
                throw ReviewRequirementError.invalid("Each check needs only an identity and bounded text.")
            }
            let identity = try ReviewRequirementID(id)
            guard ids.insert(identity).inserted else { throw ReviewRequirementError.invalid("Duplicate check identity.") }
            checks.append(Check(id: identity, text: text))
        }
        for rawType in rawTypes {
            guard let type = ReviewRequirementEvidenceType(rawValue: rawType), types.insert(type).inserted else {
                throw ReviewRequirementError.invalid("Unknown or duplicate evidence type.")
            }
        }
        return Self(checks: checks, rejectBar: rejectBar, requiredEvidenceTypes: types)
    }
    private static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= limit
    }
}

struct ReviewRequirementConfiguration {
    private let projectDefault: ReviewRequirement?
    private let overrides: [ReviewRequirementKind: ReviewRequirement]

    /// Private value shape only; this is not a parser for the complete project policy.
    static func parse(_ raw: Any?) throws -> Self {
        guard let raw else { return Self(projectDefault: nil, overrides: [:]) }
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["default", "kind_overrides"]) else {
            throw ReviewRequirementError.invalid("Unknown review-requirement configuration field.")
        }
        let base = try value["default"].map { try ReviewRequirement.parse($0) }
        var overrides: [ReviewRequirementKind: ReviewRequirement] = [:]
        if let rawOverrides = value["kind_overrides"] {
            guard let entries = rawOverrides as? [[String: Any]], entries.count <= ReviewRequirementKind.allCases.count else {
                throw ReviewRequirementError.invalid("Use at most one complete override per ticket kind.")
            }
            for entry in entries {
                guard Set(entry.keys) == ["kind", "requirement"], let name = entry["kind"] as? String,
                      let kind = ReviewRequirementKind(rawValue: name), overrides[kind] == nil,
                      let requirement = entry["requirement"] else {
                    throw ReviewRequirementError.invalid("Unknown, duplicate or incomplete kind override.")
                }
                overrides[kind] = try ReviewRequirement.parse(requirement)
            }
        }
        return Self(projectDefault: base, overrides: overrides)
    }

    /// Reset removes the complete override; it does not merge fields or mutate history.
    func resetting(_ kind: ReviewRequirementKind) -> Self {
        var retained = overrides; retained.removeValue(forKey: kind)
        return Self(projectDefault: projectDefault, overrides: retained)
    }
    func resolve(policy: ReviewRequirementPolicyIdentity, kind: ReviewRequirementKind) -> ResolvedReviewRequirement {
        let requirement = overrides[kind] ?? projectDefault ?? .generic
        return ResolvedReviewRequirement(policy: policy, kind: kind, requirement: requirement)
    }
}

struct ResolvedReviewRequirement {
    let policy: ReviewRequirementPolicyIdentity
    let kind: ReviewRequirementKind
    let requirement: ReviewRequirement
    /// Deterministic length-prefixed UTF-8 fields preserve identity bytes and check order.
    /// This fingerprints a pure resolution; it neither computes policy authority nor pins a claim.
    var digest: String {
        var bytes = Data()
        func append(_ value: String) {
            let field = Data(value.utf8)
            bytes.append(Data("\(field.count):".utf8)); bytes.append(field)
        }
        append("checklist-review-requirement-v1"); append(policy.projectID.text)
        append(String(policy.revision)); append(policy.digest); append(kind.rawValue)
        append(String(requirement.checks.count))
        for check in requirement.checks { append(check.id.text); append(check.text) }
        append(requirement.rejectBar)
        let types = ReviewRequirementEvidenceType.allCases.filter { requirement.requiredEvidenceTypes.contains($0) }
        append(String(types.count)); types.forEach { append($0.rawValue) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReviewRequirementEvidenceScope: Hashable {
    let projectID: ReviewRequirementID
    let taskID: ReviewRequirementID
    let manifestID: ReviewRequirementID
    let reviewAttemptID: ReviewRequirementID
}

struct ReviewRequirementEvidenceReference: Hashable {
    enum Namespace: String { case artifact, sourceCapture }
    let namespace: Namespace
    let id: ReviewRequirementID
}

/// An input descriptor is not an attestation. A future trusted adapter must first
/// validate its selected reference, bytes, ownership, availability and exact scope.
/// No path/filename/content claim becomes validated evidence in this pure unit.
struct ReviewRequirementEvidenceDescriptor {
    let scope: ReviewRequirementEvidenceScope
    let reference: ReviewRequirementEvidenceReference
    let digest: String
    let types: Set<ReviewRequirementEvidenceType>
    init(scope: ReviewRequirementEvidenceScope, reference: ReviewRequirementEvidenceReference,
         digest: String, types: Set<ReviewRequirementEvidenceType>) throws {
        guard reviewRequirementDigestIsValid(digest), !types.isEmpty,
              (reference.namespace == .sourceCapture ? types == [.sourceCapture] : !types.contains(.sourceCapture)) else {
            throw ReviewRequirementError.invalid("Invalid descriptor shape, not an evidence trust decision.")
        }
        self.scope = scope; self.reference = reference; self.digest = digest; self.types = types
    }
}

struct ReviewRequirementEvidenceGaps {
    let missing: [ReviewRequirementEvidenceType]
    let ambiguousReferences: Set<ReviewRequirementEvidenceReference>
    let ignoredScopeCount: Int

    /// Mathematical projection over caller-validated *selected* descriptors only.
    /// Empty gaps never mean a review passed, evidence was validated or native behavior occurred.
    static func project(_ requirement: ReviewRequirement, scope: ReviewRequirementEvidenceScope,
                        selected: [ReviewRequirementEvidenceDescriptor]) -> Self {
        var unique: [ReviewRequirementEvidenceReference: ReviewRequirementEvidenceDescriptor] = [:]
        var ambiguous = Set<ReviewRequirementEvidenceReference>(), ignored = 0
        for descriptor in selected {
            guard descriptor.scope == scope else { ignored += 1; continue }
            let reference = descriptor.reference
            guard !ambiguous.contains(reference) else { continue }
            if let prior = unique[reference], prior.digest != descriptor.digest || prior.types != descriptor.types {
                unique.removeValue(forKey: reference); ambiguous.insert(reference)
            } else { unique[reference] = descriptor }
        }
        let available = unique.values.reduce(into: Set<ReviewRequirementEvidenceType>()) { $0.formUnion($1.types) }
        return Self(missing: ReviewRequirementEvidenceType.allCases.filter {
            requirement.requiredEvidenceTypes.contains($0) && !available.contains($0)
        }, ambiguousReferences: ambiguous, ignoredScopeCount: ignored)
    }
}
