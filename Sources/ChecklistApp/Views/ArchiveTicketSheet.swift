import SwiftUI

/// Unlike an AppKit-backed confirmationDialog, a sheet can update its retention
/// section after presentation without freezing the initial loading text.
struct ArchiveTicketSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: [String: Any]?
    let failure: String?
    let blockedReason: String?
    let refresh: () -> Void
    let perform: (Bool, [String: Any]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(Confirmations.archiveTitle).checklistFont(.sheetTitle)
            Text(Confirmations.archiveEffect).checklistFont(.callout)
            if let preview {
                Text(ArchiveConfirmationState.description(preview)).checklistFont(.callout)
                Button("Refresh file retention", action: refresh).buttonStyle(.link)
            } else if let failure {
                Text(failure).checklistFont(.callout).foregroundStyle(.orange)
                Button("Retry file retention", action: refresh)
            } else {
                ProgressView("Checking this ticket’s file retention…").controlSize(.small)
                Text("Archive actions become available when retention is known.").checklistFont(.micro).foregroundStyle(.secondary)
            }
            if let preview, (preview["clean_bytes"] as? NSNumber)?.int64Value ?? 0 > 0 {
                Button("Archive and clean eligible large copies", role: .destructive) { perform(true, preview) }
                    .buttonStyle(.checklistBordered).checklistDisabled([(blockedReason != nil, blockedReason ?? "")])
            }
            AccessibleHStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(Confirmations.archiveKeepFiles, role: .destructive) {
                    if let preview { perform(false, preview) }
                }.checklistDisabled([(preview == nil, "File retention is still loading."), (blockedReason != nil, blockedReason ?? "")])
            }.buttonStyle(.checklistBordered)
        }.padding(Spacing.page).checklistSheet(width: 560)
    }
}
