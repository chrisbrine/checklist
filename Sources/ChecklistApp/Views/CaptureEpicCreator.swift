import SwiftUI

/// Empty-project capture creates only the Epic for the concrete ticket being entered.
struct CaptureEpicCreator: View {
    let projectID: String
    let request: @MainActor (String,[String:Any]) async throws -> [String:Any]
    let created: (Record) -> Void
    @State private var name = ""
    @State private var pending: [String:Any]?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.small) {
            Text("This project has no Epic yet. Create one for this ticket.").checklistFont(.micro)
            TextField("Epic name",text:$name).textFieldStyle(.roundedBorder).checklistDisabled([(pending != nil,"Finish checking this Epic first.")])
            Button(pending == nil ? "Create Epic" : "Check Epic again") {Task {await create()}}
                .checklistDisabled([(busy,DisabledReasons.saving),(pending == nil && name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter an Epic name first.")])
            if let failure {Text(failure).checklistFont(.micro).foregroundStyle(.orange)}
        }.id(projectID)
    }
    func create() async {
        guard !busy else {return}
        busy=true;failure=nil
        if pending == nil {pending=["command_id":UUID().uuidString,"project_id":projectID,"name":name]}
        do {
            let result=try await request("epic_create",pending!)
            guard !Task.isCancelled,let id=result["id"] as? String,!id.isEmpty,result["project_id"] as? String == projectID else {busy=false;failure="The Epic may be saved. Check again using the same request.";return}
            pending=nil;busy=false;created(Record(values:result))
        } catch {busy=false;failure="Could not confirm this Epic. Check again using the same request."}
    }
}
