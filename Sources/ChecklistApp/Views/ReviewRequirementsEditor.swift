import SwiftUI

struct ReviewRequirementsEditor: View {
    @Binding var draft: ReviewRequirementsDraft
    var body: some View {
        DetailSection(title:"Review requirements") {
            Text("A new review uses the requirements as they are when it starts. Changes keep the requirements of active reviews and the recorded verdicts.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if let issue = draft.loadIssue {Text(issue).checklistFont(.micro).foregroundStyle(.orange)}
            Group {
                Toggle("Customize project default",isOn:Binding(get:{draft.customDefault},set:{draft.setCustomDefault($0)})).toggleStyle(.checkbox)
                if draft.customDefault {
                    ReviewRuleEditor(rule:$draft.defaultRule)
                    Button("Reset project default to generic requirements") {draft.setCustomDefault(false)}.checklistFont(.micro)
                } else {
                    Text("Generic: assess applicable acceptance and project requirements; reject unmet requirements or record blocked when evidence is unavailable. No additional evidence types.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                DisclosureGroup("Ticket-kind overrides") {
                    ForEach($draft.kindRules) { $kind in
                        VStack(alignment:.leading,spacing: Spacing.small) {
                            Text(kind.kind.capitalized).checklistFont(.bodyStrong)
                            Toggle("Use custom requirements",isOn:Binding(get:{kind.custom},set:{draft.setCustomKind(kind.kind,$0)})).toggleStyle(.checkbox)
                            if kind.custom {
                                ReviewRuleEditor(rule:$kind.rule)
                                Button("Reset to project default") {draft.setCustomKind(kind.kind,false)}.checklistFont(.micro)
                            } else {Text("Inherits the project default.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
                        }.padding(.vertical,Spacing.small)
                    }
                }
            }.checklistDisabled([(draft.loadIssue != nil, "The review requirements could not be loaded.")])
            ForEach(Array(draft.issues.enumerated()),id:\.offset) { _,issue in Text(issue).checklistFont(.micro).foregroundStyle(.orange) }
            Text("Changed requirements apply to future work rounds; active reviews keep their requirements.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Text("Evidence types describe selected file format or report provenance. They do not establish a successful check, native observation or approval.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
    }
}

private struct ReviewRuleEditor: View {
    @Binding var rule: ReviewRuleDraft
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.small) {
            Text("Checks").checklistFont(.captionEmphasis)
            ForEach($rule.checks) { $check in
                let checkID = check.id
                AccessibleHStack(alignment:.top) {
                    TextField("Review check",text:$check.text,axis:.vertical).textFieldStyle(.roundedBorder)
                    Button {rule.checks.removeAll {$0.id == checkID}} label:{Image(systemName:"minus.circle")}.buttonStyle(.checklistIcon).help("Remove review check").accessibilityLabel("Remove review check")
                }
            }
            Button("Add review check") {rule.checks.append(.init())}.checklistDisabled([(rule.checks.count >= 20, "A rule can have at most 20 checks.")])
            Text("Reject or block when").checklistFont(.captionEmphasis)
            TextEditor(text:$rule.rejectBar).checklistFont(.body).frame(height:70).padding(Spacing.tight).overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary)).accessibilityLabel("Reject or block guidance")
            Text("Required evidence types").checklistFont(.captionEmphasis)
            ForEach(ReviewEvidenceClass.allCases) { type in
                Toggle(type.label,isOn:Binding(get:{rule.evidenceClasses.contains(type)},set:{enabled in if enabled {rule.evidenceClasses.insert(type)} else {rule.evidenceClasses.remove(type)}})).toggleStyle(.checkbox)
            }
        }
    }
}
