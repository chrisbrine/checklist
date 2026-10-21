import Foundation
import CoreFoundation

/// Read-only service snapshot presentation. No current-policy fallback, authority or class inference.
struct ReviewRequirementsSummary {
    let policyRevision: Int
    let requirementDigest: String
    let checks: [String]
    let rejectBar: String
    let evidenceClasses: [ReviewEvidenceClass]
    enum Selection: Equatable {
        case unevaluated
        case recorded(missing: [ReviewEvidenceClass],references: Int,ambiguous: Int)
    }
    let selection: Selection

    init?(snapshot: [String:Any],projectID: String,taskKind: String,preflight: [String:Any] = [:]) {
        guard Self.integer(snapshot["version"]) == 1,
              let project = snapshot["project_id"] as? String,project.utf8.elementsEqual(projectID.utf8),
              let kind = snapshot["task_kind"] as? String,kind == taskKind,ReviewRequirementsDraft.kindNames.contains(kind),
              let revision = Self.integer(snapshot["policy_revision"]),revision > 0,
              let digest = snapshot["sha256"] as? String,Self.digest(digest),
              let policyDigest = snapshot["policy_sha256"] as? String,Self.digest(policyDigest),
              let raw = snapshot["requirement"],let rule = try? ReviewRuleDraft(raw:raw) else {return nil}
        policyRevision = revision;requirementDigest = digest;checks = rule.checks.map(\.text);rejectBar = rule.rejectBar
        evidenceClasses = ReviewEvidenceClass.allCases.filter(rule.evidenceClasses.contains)
        if preflight["state"] as? String == "selected_validated",Self.integer(preflight["policy_revision"]) == revision,
           preflight["requirement_sha256"] as? String == digest,
           let rawMissing = preflight["missing_evidence_types"] as? [String],Set(rawMissing).count == rawMissing.count,
           let missing = Self.classes(rawMissing),Set(missing).isSubset(of:rule.evidenceClasses),
           let references = Self.integer(preflight["selected_reference_count"]),references >= 0,
           let ambiguous = Self.integer(preflight["ambiguous_reference_count"]),ambiguous >= 0 {
            selection = .recorded(missing:missing,references:references,ambiguous:ambiguous)
        } else {selection = .unevaluated}
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let value = raw as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID() else {return nil}
        return Int(value.stringValue)
    }
    private static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {(48...57).contains($0) || (97...102).contains($0)}
    }
    private static func classes(_ raw: [String]) -> [ReviewEvidenceClass]? {
        let result = raw.compactMap(ReviewEvidenceClass.init(rawValue:));return result.count == raw.count ? result : nil
    }
}
