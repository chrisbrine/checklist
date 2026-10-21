import Foundation

enum ReviewEvidenceClass: String, CaseIterable, Identifiable, Hashable {
    case reviewerReport = "reviewer_report", sourceCapture = "source_capture", image, textRecord = "text_record"
    var id: String { rawValue }
    var label: String {
        switch self {case .reviewerReport:return "Reviewer report";case .sourceCapture:return "Captured source";case .image:return "Image";case .textRecord:return "Text record"}
    }
}

struct ReviewCheckDraft: Identifiable {
    let id = UUID() // View identity survives text edits; it is never serialized as the requirement ID.
    var requirementID: String
    var text: String
    init(requirementID: String = UUID().uuidString.lowercased(),text: String = "") {
        self.requirementID = requirementID;self.text = text
    }
}

enum ReviewRequirementsDraftError: Error {case unsupported}

struct ReviewRuleDraft {
    var checks: [ReviewCheckDraft]
    var rejectBar: String
    var evidenceClasses: Set<ReviewEvidenceClass>
    static var generic: Self {
        .init(checks:[.init(requirementID:"acceptance",text:"Assess every applicable acceptance and project requirement on the exact target.")],
              rejectBar:"Reject a supported unmet requirement or actionable defect. Report blocked when necessary evidence or access is unavailable.",evidenceClasses:[])
    }
    init(checks: [ReviewCheckDraft],rejectBar: String,evidenceClasses: Set<ReviewEvidenceClass>) {
        self.checks = checks;self.rejectBar = rejectBar;self.evidenceClasses = evidenceClasses
    }
    init(raw: Any) throws {
        guard let raw = raw as? [String:Any],Set(raw.keys) == ["checks","reject_bar","required_evidence_types"],
              let checks = raw["checks"] as? [[String:Any]],let rejectBar = raw["reject_bar"] as? String,
              let types = raw["required_evidence_types"] as? [String],types.count <= 4,
              Set(types).count == types.count else {throw ReviewRequirementsDraftError.unsupported}
        self.checks = try checks.map { check in
            guard Set(check.keys) == ["id","text"],let id = check["id"] as? String,let text = check["text"] as? String else {throw ReviewRequirementsDraftError.unsupported}
            return .init(requirementID:id,text:text)
        }
        self.rejectBar = rejectBar
        self.evidenceClasses = Set(try types.map {value in guard let type = ReviewEvidenceClass(rawValue:value) else {throw ReviewRequirementsDraftError.unsupported};return type})
        guard issues.isEmpty else {throw ReviewRequirementsDraftError.unsupported}
    }
    var wireValue: [String:Any] {
        ["checks":checks.map {["id":$0.requirementID,"text":$0.text]},"reject_bar":rejectBar,
         "required_evidence_types":ReviewEvidenceClass.allCases.filter(evidenceClasses.contains).map(\.rawValue)]
    }
    /// Local input feedback only. The service remains the authoritative validator.
    var issues: [String] {
        var issues: [String] = [],ids = Set<Data>()
        if checks.count > 20 {issues.append("Use at most 20 review checks.")}
        for check in checks {
            if check.requirementID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || check.requirementID.utf8.count > 256 || !ids.insert(Data(check.requirementID.utf8)).inserted {issues.append("Review check identities must be nonblank, bounded and unique.")}
            if check.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || check.text.utf8.count > 2000 {issues.append("Each review check needs text of at most 2000 UTF-8 bytes.")}
        }
        if rejectBar.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || rejectBar.utf8.count > 4000 {issues.append("Reject or block guidance needs text of at most 4000 UTF-8 bytes.")}
        return issues
    }
}

struct ReviewKindRequirementDraft: Identifiable {
    let kind: String
    var id: String {kind}
    var custom = false
    var rule = ReviewRuleDraft.generic
}

/// View-local editor value. It neither applies policy nor pins a review.
struct ReviewRequirementsDraft {
    static let kindNames = ["work","bug","asset","playtest","question"]
    var customDefault = false
    var defaultRule = ReviewRuleDraft.generic
    var kindRules = ReviewRequirementsDraft.kindNames.map {ReviewKindRequirementDraft(kind:$0)}
    private(set) var loadIssue: String?
    private var originalRaw: Any?
    private var originalProjection = ""

    init(raw: Any? = nil) {
        originalRaw = raw
        do {
            if let raw {
                guard let value = raw as? [String:Any],Set(value.keys).isSubset(of:["default","kind_overrides"]) else {throw ReviewRequirementsDraftError.unsupported}
                if let base = value["default"] {defaultRule = try .init(raw:base);customDefault = true}
                if let rawOverrides = value["kind_overrides"] {
                    guard let overrides = rawOverrides as? [[String:Any]],overrides.count <= Self.kindNames.count else {throw ReviewRequirementsDraftError.unsupported}
                    var seen = Set<String>()
                    for row in overrides {
                        guard Set(row.keys) == ["kind","requirement"],let kind = row["kind"] as? String,
                              let index = kindRules.firstIndex(where: {$0.kind == kind}),seen.insert(kind).inserted,let rule = row["requirement"] else {throw ReviewRequirementsDraftError.unsupported}
                        kindRules[index].custom = true;kindRules[index].rule = try .init(raw:rule)
                    }
                }
            }
        } catch {loadIssue = "Stored review requirements cannot be edited by this client. Project details can still be saved."}
        originalProjection = Self.signature(configurationValue)
    }
    var effectiveDefault: ReviewRuleDraft {customDefault ? defaultRule : .generic}
    mutating func setCustomDefault(_ enabled: Bool) {
        if enabled && !customDefault {defaultRule = .generic};customDefault = enabled
    }
    mutating func setCustomKind(_ kind: String,_ enabled: Bool) {
        guard let index = kindRules.firstIndex(where: {$0.kind == kind}) else {return}
        if enabled && !kindRules[index].custom {kindRules[index].rule = effectiveDefault};kindRules[index].custom = enabled
    }
    var issues: [String] {
        guard loadIssue == nil else {return []}
        return (customDefault ? defaultRule.issues : []) + kindRules.filter(\.custom).flatMap {row in row.rule.issues.map {row.kind.capitalized+": "+$0}}
    }
    var canPreview: Bool {loadIssue == nil && issues.isEmpty}
    private var configurationValue: [String:Any] {
        var value: [String:Any] = ["kind_overrides":kindRules.filter(\.custom).map {["kind":$0.kind,"requirement":$0.rule.wireValue]}]
        if customDefault {value["default"] = defaultRule.wireValue};return value
    }
    func applying(to policy: [String:Any]) -> [String:Any] {
        var value = policy
        // Keep missing/{}/explicit generic and original representation on untouched load.
        // Unknown unrelated policy values are retained; unsupported requirement data is never reset.
        if loadIssue != nil || Self.signature(configurationValue) == originalProjection {value["review_requirements"] = originalRaw}
        else {value["review_requirements"] = configurationValue}
        return value
    }
    static func workflowSignature(policy: [String:Any],applyMode: String) -> String {
        signature(["policy":policy,"mode":applyMode])
    }
    private static func signature(_ value: [String:Any]) -> String {
        (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)).map {String(decoding:$0,as:UTF8.self)} ?? ""
    }
}
