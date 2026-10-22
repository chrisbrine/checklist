import SwiftUI

struct MentionComposerPanel: View {
    let panel: MentionComposerState.Panel
    let select: (UUID, MentionComposerState.Span, MentionDraftResolution.Target) -> Void
    let clear: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                Text("Choose tagged targets, then Send note").checklistFont(.microEmphasis)
                Spacer()
                Button("Clear selections", action: clear).buttonStyle(.link).checklistFont(.micro)
            }
            ForEach(panel.tokens) { token in
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("@" + token.query).checklistFont(.microStrong)
                    if token.state == "not_found" {
                        Text("No eligible target in this project. Edit this tag, or escape @ if it is literal text.")
                            .checklistFont(.micro).foregroundStyle(.orange)
                    } else {
                        ForEach(token.candidates) { candidate in
                            Button { select(panel.id, token.span, candidate.target) } label: {
                                AccessibleHStack(alignment: .top, spacing: Spacing.small) {
                                    Image(systemName: token.selected == candidate.target ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                                        Text(candidate.title).checklistFont(.micro)
                                        Text(candidate.detail).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.compact)
                            }.buttonStyle(.checklistBordered).accessibilityAddTraits(token.selected == candidate.target ? .isSelected : [])
                        }
                    }
                }
            }
        }.checklistCard(padding: Spacing.small)
            .id(panel.id) // retire old row/focus state on every fresh result
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tagged target choices")
    }
}
