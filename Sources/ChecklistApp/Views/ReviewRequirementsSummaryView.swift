import SwiftUI

struct ReviewRequirementsSummaryView: View {
    let title: String
    let snapshot: [String:Any]
    let projectID: String
    let taskKind: String
    var preflight: [String:Any] = [:]
    var previewOnly = false
    var summary: ReviewRequirementsSummary? {.init(snapshot:snapshot,projectID:projectID,taskKind:taskKind,preflight:preflight)}
    var body: some View {
        if let summary {
            DisclosureGroup(title) {
                VStack(alignment:.leading,spacing: Spacing.compact) {
                    if previewOnly {Text("Preview only. A review uses the requirements as they are when it starts.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
                    ForEach(Array(summary.checks.enumerated()),id:\.offset) {index,check in Text("\(index+1). \(check)").checklistFont(.micro).textSelection(.enabled)}
                    Text("Reject or block: \(summary.rejectBar)").checklistFont(.micro).textSelection(.enabled)
                    Text("Required evidence: \(summary.evidenceClasses.isEmpty ? "no additional types" : summary.evidenceClasses.map(\.label).joined(separator:", "))").checklistFont(.micro)
                    switch summary.selection {
                    case .unevaluated:
                        Text("Selected evidence validation is not available in this view. Refresh service review context before recording a verdict.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    case .recorded(let missing,let references,let ambiguous):
                        Text("Service-recorded selection: \(references) references · \(ambiguous) ambiguous").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        Text(missing.isEmpty ? "No missing evidence types in that recorded selection." : "Missing in that selection: "+missing.map(\.label).joined(separator:", ")).checklistFont(.micro)
                    }
                    Text("These types do not establish execution success, native observation or approval.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    TechnicalDetails([("Policy revision", "\(summary.policyRevision)"), ("Requirement SHA-256", summary.requirementDigest)])
                }.padding(.top,Spacing.compact)
            }.checklistFont(.micro)
        } else {
            Text(previewOnly ? "\(title): requirement preview unavailable. Refresh service review context before claiming." : "\(title): snapshot not recorded or unavailable for this record. Current settings cannot reconstruct historical requirements.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
    }
}
