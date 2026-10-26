import SwiftUI

struct NoteCorrectionActions: View {
    @EnvironmentObject var store: ChecklistStore
    let message: Record
    let task: Record
    @State private var correcting = false
    @State private var retracting = false
    @State private var text = ""
    @State private var confirmRetraction = false
    var ownNote: Bool {
        message.string("origin") == "human_ui" && message.string("author_session_id") == "human" && message.string("human_response_id").isEmpty && message.string("human_request_id").isEmpty
    }
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.small) {
            let state = message.string("note_revision_state")
            if ["corrected","retracted"].contains(state) {Text(state == "corrected" ? "Corrected · original retained" : "Retracted · original retained").checklistFont(.microEmphasis).foregroundStyle(Color.checklistSecondaryText)}
            ForEach(message.records("note_revisions")) {revision in
                VStack(alignment:.leading,spacing:Spacing.tight) {
                    Text(revision.string("kind") == "retraction" ? "Retraction" : "Correction").checklistFont(.microEmphasis)
                    Text(revision.string("body")).checklistFont(.callout).textSelection(.enabled)
                    if revision.bool("direction_already_addressed") || revision.bool("direction_already_acknowledged") {Text("Recorded after the earlier direction was acknowledged or addressed. Earlier work is still recorded.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
                }
            }
            if message.bool("note_revisions_truncated") {Text("More corrections are kept in ticket history.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
            if ownNote {
                HStack {
                    Button("Correct…") {text = message.string("body");retracting = false;correcting = true}
                    Button("Retract…") {text = "";retracting = true;correcting = true}
                }.buttonStyle(.link).checklistFont(.micro)
                    .checklistDisabled([(!store.connected,DisabledReasons.offline),(store.busy,DisabledReasons.saving),(!store.selectedTicketCurrent(task.id),DisabledReasons.ticketLoading)])
            }
        }.sheet(isPresented:$correcting) {
            VStack(alignment:.leading,spacing:Spacing.group) {
                Text(retracting ? "Retract note" : "Correct note").checklistFont(.sheetTitle)
                Text("The original note, its author and delivery receipts stay in history. The current handler receives a linked note. Earlier work is still recorded.").checklistFont(.callout)
                TextEditor(text:$text).frame(minHeight:110).overlay(RoundedRectangle(cornerRadius:Radius.medium).stroke(.quaternary))
                Text(retracting ? "Give a short reason for retracting this note." : "Write the corrected note. A direction stays pending until addressed or retracted.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                HStack {Button("Cancel") {correcting = false};Spacer();Button(retracting ? "Retract…" : "Save correction") {if retracting {confirmRetraction = true} else {save()}}.buttonStyle(.checklistProminent).checklistDisabled([(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Write the corrected note or a retraction reason first."),(store.busy,DisabledReasons.saving),(!store.connected,DisabledReasons.offline)])}
            }.padding(Spacing.page).checklistSheet(width:510)
                .confirmationDialog("Retract this note?",isPresented:$confirmRetraction,titleVisibility:.visible) {Button("Retract note",role:.destructive) {save()};Button("Cancel",role:.cancel) {}} message: {Text("Future action on this direction is withdrawn. Acknowledgment and earlier work remain in history.")}
        }
    }
    func save() {
        store.run("message_send",["project_id":task.string("project_id"),"task_id":task.id,"correction_of":message.id,"kind":retracting ? "retraction" : "correction","body":text],success:retracting ? "Retraction saved; original retained" : "Correction saved; original retained", completion: {_ in correcting = false})
    }
}
