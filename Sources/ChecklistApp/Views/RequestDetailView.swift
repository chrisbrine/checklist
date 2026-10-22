import SwiftUI
import AppKit
import ChecklistCore

struct RequestDetailView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.checklistTextScale) private var textScale
    let request: Record
    @State private var draft = AnswerDraft()
    @State private var staleDraft = false
    @State private var fileProblems: [String: String] = [:]
    @State private var answerCompletion = RequestAnswerCompletionObserver()
    @StateObject private var fileInspector = RequestFileInspector()
    @State private var requestVisible = false
    @State private var draftEditGeneration: UInt64 = 0
    @State private var showingImageReview = false
    var imageContext: Record { Record(values: request.object("image_review")) }
    var imageCandidates: [ImageReviewCandidate] {
        if !imageContext.records("images").isEmpty {
            return imageContext.records("images").map { ImageReviewCandidate(file: $0, manifestID: imageContext.string("manifest_id")) }
        }
        return request.records("detail_attachments").filter { FilePreviewKind.detect(name: $0.string("name")) == .image && $0.id == exactTarget.id }.map {
            ImageReviewCandidate(file: $0, manifestID: request.string("target_manifest_id", fallback: "request:" + formIdentity), expectedSHA256: request.string("target_sha256"))
        }
    }
    var previousImages: [ImageReviewCandidate] { imageContext.records("previous_images").map { ImageReviewCandidate(file: $0, manifestID: imageContext.string("previous_manifest_id")) } }
    var inspectedSelection: Binding<Set<ImageInspectionIdentity>> {
        Binding(get: { ImageReviewProjection.selection(draft.inspectedImages) }, set: { values in
            draft.inspectedImages = values.sorted { $0.artifactID < $1.artifactID }.map(\.record); save()
        })
    }
    var imageApprovalReady: Bool {
        let approves = questions.contains { $0.string("type") == "approval" && draft.values[$0.id] == "approved" }
        return !approves || ImageReviewProjection.readyToApprove(imageCandidates, selection: inspectedSelection.wrappedValue, problem: imageContext.string("problem"))
    }
    var spec: Record { let spec = request.object("spec"); return spec.isEmpty ? request : Record(values: spec) }
    var formIdentity: String { RequestDraftIdentity.form(request) }
    var exactTarget: Record {
        if !spec.object("target").isEmpty { return Record(values: spec.object("target")) }
        if let attachment = request.records("detail_attachments").first(where: { $0.id == request.string("target_attachment_id") }) { return Record(values: ["id": attachment.id, "label": attachment.string("name"), "sha256": request.string("target_sha256"), "version_label": "Attached file", "platform_label": ""]) }
        return Record(values: [:])
    }
    var questions: [Record] { spec.records("questions") }
    var fileRequests: [Record] { spec.records("file_requests") }
    func questionPrompt(_ id: String) -> String { questions.first { $0.string("id") == id }.map { $0.string("prompt", fallback: $0.string("label", fallback: "Question")) } ?? "Question" }
    func filePrompt(_ id: String) -> String { fileRequests.first { $0.string("id") == id }.map { $0.string("prompt", fallback: $0.string("label", fallback: "File")) } ?? "File" }
    var answered: Bool { ["answered", "resolved", "canceled", "superseded"].contains(Canceled.normalized(request.string("state"))) }
    var complete: Bool { RequestDraftIdentity.isComplete(draft, questions: questions, fileRequests: fileRequests) && !staleDraft && fileProblems.isEmpty && fileInspector.ready(for: fileInspectionScope) && imageApprovalReady }
    var fileInspectionScope: RequestFileInspectionScope {
        RequestFileInspectionScope(request: request, draft: draft, fileRequests: fileRequests, storeIncarnation: store.storeIncarnation)
    }
    var priorDrafts: [(String, AnswerDraft)] { store.answerDrafts.filter { $0.key.hasPrefix(request.id + "#form-") }.sorted { $0.key < $1.key } }
    @State private var confirmation: PendingConfirmation?
    /// An older record may store the legacy spelling; the pill shows the glossary spelling.
    static func stateName(_ request: Record) -> String { GlossaryText.title(request.string("state", fallback: "open")) }
    static func footerText(_ request: Record) -> String { "This request is \(stateName(request).lowercased())." }
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        VStack(spacing: Spacing.none) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.page) {
                    Text(request.string("title")).checklistFont(.pageTitle)
                    AccessibleHStack { StatusPill(name: Self.stateName(request), category: answered ? "done" : "blocked"); Spacer() }
                    Text("Requested by \(requesterLabel)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
                    TechnicalDetails([("Request", request.id), ("Form revision", "\(request.integer("form_revision"))"), ("Candidate", exactTarget.id), ("Candidate SHA-256", exactTarget.string("sha256"))])
                    if !spec.string("explanation").isEmpty { Text(spec.string("explanation")).checklistFont(.callout).textSelection(.enabled) }
                    if !request.string("task_id").isEmpty, let task = store.task(request.string("task_id")) { Button { store.open(.task(task.id)) } label: { Label("\(task.string("key")) · \(task.string("title"))", systemImage: "arrow.turn.up.left") }.buttonStyle(.link) }
                    if staleDraft && !answered {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Label("This form changed. Its old draft is preserved; inspect the current target before answering.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Button("Keep notes and clear choices for current form") { adoptCurrentForm() }
                        }.checklistFont(.callout)
                    }
                    let target = exactTarget
                    if !target.id.isEmpty {
                        DetailSection(title: "Exact candidate") {
                            Text(target.string("label")).checklistFont(.bodyStrong)
                            Text("\(target.string("version_label")) · \(target.string("platform_label"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                            if let attachment = request.records("detail_attachments").first(where: { $0.id == target.id }) { AttachmentRow(file: attachment, targetManifestID: request.string("target_manifest_id")) }
                            if !imageCandidates.isEmpty {
                                Button("Inspect and compare images…") { showingImageReview = true }
                                Text("Inspected \(imageCandidates.filter { inspectedSelection.wrappedValue.contains($0.identity) }.count) of \(imageCandidates.count) originals").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                if !imageApprovalReady { Text("Inspect and explicitly mark every available original before approving. Missing or cleaned originals cannot be approved.").checklistFont(.micro).foregroundStyle(.orange) }
                            }
                            if !imageContext.string("problem").isEmpty { Text(imageContext.string("problem")).checklistFont(.micro).foregroundStyle(.orange) }
                        }
                    }
                    if !spec.object("command").isEmpty { commandView(Record(values: spec.object("command"))) }
                    ForEach(questions) { question in questionView(question) }
                    ForEach(fileRequests) { file in fileView(file) }
                    DetailSection(title: "Optional explanation") {
                        TextEditor(text: Binding(get: { draft.explanation }, set: { draft.explanation = $0; save() })).checklistFont(.body).frame(minHeight: 75).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")])
                    }
                    if !priorDrafts.isEmpty {
                        DisclosureGroup("Preserved drafts from earlier forms") {
                            ForEach(priorDrafts, id: \.0) { entry in
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text("Draft for an earlier version of this form").checklistFont(.microEmphasis)
                                    TechnicalDetails([("Form revision", "\(entry.1.formRevision)")])
                                    ForEach(entry.1.values.keys.sorted(), id: \.self) { id in Text("\(questionPrompt(id)): \(entry.1.values[id] ?? "")").checklistFont(.micro).textSelection(.enabled) }
                                    if !entry.1.explanation.isEmpty { Text(entry.1.explanation).checklistFont(.micro).textSelection(.enabled) }
                                    ForEach(entry.1.customValues.keys.sorted(), id: \.self) { id in Text("\(questionPrompt(id)) (own answer): \(entry.1.customValues[id] ?? "")").checklistFont(.micro).textSelection(.enabled) }
                                    ForEach(entry.1.paths.keys.sorted(), id: \.self) { id in Text("\(filePrompt(id)): \((entry.1.paths[id] ?? []).joined(separator: ", "))").checklistFont(.micro).textSelection(.enabled) }
                                }.padding(.vertical, Spacing.tight)
                            }
                        }.checklistFont(.micro)
                    }
                    if !request.records("responses").isEmpty {
                        DetailSection(title: "Saved responses") {
                            ForEach(request.records("responses")) { response in
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text("You · \(relativeTime(response.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    Text(response.bool("complete") ? "Answer saved" : "Response saved; dependency remains unresolved").checklistFont(.micro)
                                    if !response.records("inspected_images").isEmpty { Text("Inspected originals: \(response.records("inspected_images").count)").checklistFont(.micro) }
                                    if !response.string("explanation").isEmpty { Text(response.string("explanation")).checklistFont(.callout).textSelection(.enabled) }
                                    let continuation = RequestAnswerDeliveryProjection.make(request: request, response: response, messages: request.records("detail_messages"), sessions: request.records("detail_sessions"), snapshotCurrent: store.connected)
                                    ForEach(continuation.recipients) { recipient in
                                        Text("\(recipient.label) · \(recipient.receipt)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    }
                                    Text(continuation.summary).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    TechnicalDetails([("Response", response.id), ("Saved at", response.string("created_at")), ("Form revision", "\(response.integer("form_revision"))"),
                                                      ("Source", response.string("origin")), ("Authorization generation", response.string("source_authorization_generation")), ("Form identity", response.string("form_identity"))])
                                }
                            }
                        }
                    }
                    if TextScale.usesInlineComposer(at: textScale) { Divider(); responseActions }
                }.padding(Spacing.page)
            }
            if !TextScale.usesInlineComposer(at: textScale) { Divider(); responseActions }
        }.onAppear { requestVisible = true; loadDraft() }
            .sheet(isPresented: $showingImageReview) { ImageReviewSheet(current: imageCandidates, previous: previousImages, selection: inspectedSelection, editable: !answered && !staleDraft) }
            .onDisappear { requestVisible = false; fileInspector.cancel(); answerCompletion.invalidate() }
            .onChange(of: fileInspectionScope) { _, _ in inspectFiles() }
            .onChange(of: formIdentity) { _, _ in updateDraftReconciliation() }
            .onChange(of: store.storeIncarnation) { _, _ in updateDraftReconciliation() }
            .onChange(of: request.string("state")) { _, _ in if answered { staleDraft = false; fileInspector.cancel() } }
    }
    var responseActions: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            if answered { Text(Self.footerText(request)).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            else { DraftSaveStatusView(kind: "answer", draftID: request.id); Text("Sending records only the results you explicitly select.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if draft.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !answered { Text("Add an explanation to request clarification or say you cannot do this.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if let progress = fileInspector.progress {
                ProgressView(value: progress.fraction) { Text("Checking selected files…").checklistFont(.micro) }
            }
            AccessibleHStack {
                Menu("Other response") {
                    Button("Need clarification") { send("clarification") }.checklistDisabled([(!store.connected, DisabledReasons.offline), (draft.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write an explanation first."), (staleDraft, "This request changed. Review the current version first."), (fileInspector.isChecking, "The selected files are still being checked.")])
                    Button("Cannot do") { send("cannot_do") }.checklistDisabled([(!store.connected, DisabledReasons.offline), (draft.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write an explanation first."), (staleDraft, "This request changed. Review the current version first."), (fileInspector.isChecking, "The selected files are still being checked.")])
                    Button(request.bool("owner_snoozed") ? "Show in inbox" : "Snooze in my inbox") { store.run("human_request_snooze", ["project_id": request.string("project_id"), "request_id": request.id, "expected_revision": request.integer("revision"), "snoozed": !request.bool("owner_snoozed")], success: "Inbox visibility updated; request remains unresolved") }
                    Divider()
                    Button("Cancel request…", role: .destructive) { confirmation = Confirmations.cancelRequest { store.run("human_request_cancel", ["project_id": request.string("project_id"), "request_id": request.id, "expected_revision": request.integer("revision"), "reason": draft.explanation], success: "Request canceled") } }
                }.checklistDisabled([(answered, "This request is already answered."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                Spacer()
                Button("Send answer") { send("answered") }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command).checklistDisabled([(!complete, "Complete every required item. Choose No to decline; use Other response for Not checked."), (answered, "This request is already answered."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
        }.padding(Spacing.group).background(.bar)
    }
    @ViewBuilder func commandView(_ command: Record) -> some View {
        DetailSection(title: "Run this check") {
            Text(command.string("reason")).checklistFont(.callout)
            ScrollView(.horizontal) { Text(command.string("text")).checklistFont(.codeCaption).textSelection(.enabled).padding(Spacing.row) }.background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Radius.medium))
            Text("In: \(command.string("working_directory"))").checklistFont(.micro).textSelection(.enabled)
            Text("Expected: \(command.string("expected_result"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Button("Copy command") { clipboard(command.string("text")) }
        }
    }
    @ViewBuilder func questionView(_ question: Record) -> some View {
        DetailSection(title: question.string("label", fallback: question.string("prompt")) + ((question.values["required"] as? Bool ?? true) ? " *" : "")) {
            let type = question.string("type")
            if !question.object("command").isEmpty { commandView(Record(values: question.object("command"))) }
            if ["single_choice", "multiple_choice", "choice", "approval", "check"].contains(type) {
                let options: [Record] = type == "approval" ? [Record(values: ["id": "approved", "label": "Approve"]), Record(values: ["id": "changes_requested", "label": "Needs changes"]), Record(values: ["id": "declined", "label": "No · I decline"]), Record(values: ["id": "not_checked", "label": "Not checked"])] : type == "check" ? [Record(values: ["id": "passed", "label": "I ran it · Passed"]), Record(values: ["id": "failed", "label": "I ran it · Failed"]), Record(values: ["id": "declined", "label": "No · I decline"]), Record(values: ["id": "not_checked", "label": "Not checked"])] : question.records("options")
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(options) { option in
                        Button {
                            if type == "multiple_choice" || question.bool("multiple") {
                                var chosen = Set((draft.values[question.id] ?? "").split(separator: "\n").map(String.init))
                                if chosen.contains(option.id) { chosen.remove(option.id) } else { chosen.insert(option.id) }
                                draft.values[question.id] = chosen.sorted().joined(separator: "\n")
                            } else { draft.values[question.id] = option.id; draft.customValues[question.id] = "" }
                            save()
                        } label: {
                            AccessibleHStack { Image(systemName: selected(question.id, option.id, multiple: (type == "multiple_choice" || question.bool("multiple"))) ? "checkmark.circle.fill" : "circle"); Text(option.string("label")); Spacer() }.padding(Spacing.row).background(selected(question.id, option.id, multiple: (type == "multiple_choice" || question.bool("multiple"))) ? Color.checklistAccent.opacity(0.12) : Card.background, in: RoundedRectangle(cornerRadius: Radius.medium))
                        }.buttonStyle(.checklistRow).accessibilityAddTraits(selected(question.id, option.id, multiple: (type == "multiple_choice" || question.bool("multiple"))) ? .isSelected : []).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")])
                    }
                    if question.bool("allow_custom") { TextField("Or give a custom answer…", text: customValueBinding(question)).textFieldStyle(.roundedBorder).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]) }
                    if !(draft.values[question.id] ?? "").isEmpty || !(draft.customValues[question.id] ?? "").isEmpty { Button("Clear selection") { draft.values.removeValue(forKey: question.id); draft.customValues.removeValue(forKey: question.id); save() }.checklistFont(.micro).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]) }
                }
            } else if type == "long_text" { TextEditor(text: valueBinding(question.id)).checklistFont(.body).frame(minHeight: 80).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]) }
            else { TextField("Your answer…", text: valueBinding(question.id)).textFieldStyle(.roundedBorder).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]) }
        }
    }
    @ViewBuilder func fileView(_ file: Record) -> some View {
        DetailSection(title: file.string("label", fallback: file.string("prompt")) + ((file.values["required"] as? Bool ?? true) ? " *" : "")) {
            AccessibleHStack {
                Button("Choose in Finder…") { choose(file) }.checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")])
                Picker("Store as", selection: Binding(get: { draft.fileModes[file.id] ?? "reference" }, set: { draft.fileModes[file.id] = $0; save() })) {
                    Text("Reference").tag("reference")
                    if file.string("kind", fallback: file.string("selection")) != "directory" { Text("Managed copy").tag("managed") }
                }.frame(maxWidth: .infinity, alignment: .leading).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")])
            }
            ForEach(draft.paths[file.id] ?? [], id: \.self) { path in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    AccessibleHStack {
                        Image(systemName: "link"); Text(URL(fileURLWithPath: path).lastPathComponent).checklistFont(.micro).lineLimit(1)
                        Text(draft.fileModes[file.id] == "managed" ? "Managed copy on send" : "Reference").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }.buttonStyle(.checklistIcon).help("Reveal original").accessibilityLabel("Reveal original")
                        Button("Relink") { choose(file, replacing: path) }.checklistFont(.micro).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")])
                        Button { draft.paths[file.id]?.removeAll { $0 == path }; draft.pathHashes.removeValue(forKey: path); fileProblems.removeValue(forKey: path); save() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.checklistIcon).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]).help("Remove selection").accessibilityLabel("Remove selection")
                    }
                    if let problem = fileProblems[path] { Text(problem).checklistFont(.micro).foregroundStyle(.orange) }
                }
            }
            if file.bool("optional_explanation") { TextField("Explanation (optional)", text: Binding(get: { draft.explanations[file.id] ?? "" }, set: { draft.explanations[file.id] = $0; save() })).textFieldStyle(.roundedBorder).checklistDisabled([(answered, "This request is already answered."), (staleDraft, "This request changed. Review the current version first.")]) }
        }
    }
    var requesterLabel: String {
        let explicit = request.string("requester_label")
        if !explicit.isEmpty && UUID(uuidString: explicit) == nil { return explicit }
        let sessionID = request.string("requester_session_id")
        if sessionID == "human" { return "You" }
        if let session = request.records("detail_sessions").first(where: { $0.id == sessionID }) { let label = session.string("native_conversation_title", fallback: session.string("label")); if !label.isEmpty && UUID(uuidString: label) == nil { return label } }
        return sessionID.isEmpty ? "Agent" : "Agent · " + String(sessionID.prefix(8))
    }
    func customValueBinding(_ question: Record) -> Binding<String> { Binding(get: { draft.customValues[question.id] ?? "" }, set: { draft.customValues[question.id] = $0; if !question.bool("multiple") { draft.values.removeValue(forKey: question.id) }; save() }) }
    func selected(_ question: String, _ option: String, multiple: Bool) -> Bool { multiple ? (draft.values[question] ?? "").split(separator: "\n").contains(Substring(option)) : draft.values[question] == option }
    func valueBinding(_ key: String) -> Binding<String> { Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0; save() }) }
    func save() { draftEditGeneration &+= 1; store.saveAnswer(request.id, draft: draft) }
    func loadDraft() {
        draft = store.answerDrafts[request.id] ?? AnswerDraft(revision: request.integer("revision"))
        if answered { return }
        if draft.targetIdentity.isEmpty && draft.revision == request.integer("revision") { draft.targetIdentity = formIdentity; draft.formRevision = request.integer("form_revision"); save() }
        updateDraftReconciliation()
        for question in questions where question.bool("allow_custom") {
            let value = draft.values[question.id] ?? "", known = Set(question.records("options").map(\.id))
            if !value.isEmpty && !Set(value.split(separator: "\n").map(String.init)).isSubset(of: known) { draft.customValues[question.id] = value; draft.values.removeValue(forKey: question.id) }
        }
        inspectFiles(); save()
    }
    func adoptCurrentForm() {
        store.saveAnswer(RequestDraftIdentity.archivedKey(request.id, draft: draft), draft: draft)
        draft = RequestDraftIdentity.adoptingCurrentForm(draft, request: request)
        staleDraft = false
        inspectFiles(); store.saveAnswer(request.id, draft: draft, reconcile: true)
    }
    func updateDraftReconciliation() { staleDraft = !answered && (draft.targetIdentity != formIdentity || store.answerDraftNeedsReconciliation(request.id, project: request.string("project_id"))) }
    func inspectFiles(forSend: Bool = false, force: Bool = false, newSelectionPaths: Set<String> = []) {
        guard requestVisible, !answered, !staleDraft else { fileInspector.cancel(); return }
        let scope = fileInspectionScope, editGeneration = draftEditGeneration
        fileInspector.inspect(scope: scope, expectedHashes: draft.pathHashes, force: forSend || force) { completedScope, result in
            guard requestVisible, !answered, !staleDraft, completedScope == fileInspectionScope, inspectionIsCurrent(completedScope) else { return }
            fileProblems = result.problems
            for (path, digest) in result.hashes where draft.pathHashes[path] == nil { draft.pathHashes[path] = digest }
            for file in fileRequests where (draft.paths[file.id] ?? []).contains(where: { newSelectionPaths.contains($0) && result.directories.contains($0) }) {
                draft.fileModes[file.id] = "reference"
            }
            store.saveAnswer(request.id, draft: draft)
            if forSend {
                guard editGeneration == draftEditGeneration else {
                    store.error = "Your answer changed while files were checked. Review it and press Send again."
                    return
                }
                guard fileProblems.isEmpty else {
                    store.error = "A selected original changed or is unavailable. Relink or remove it; your draft remains saved."
                    return
                }
                submit("answered")
            }
        }
    }
    func choose(_ file: Record, replacing oldPath: String? = nil) {
        let kind = file.string("kind", fallback: file.string("selection", fallback: "either"))
        let urls = chooseFiles(directories: kind != "file", files: kind != "directory", multiple: oldPath == nil && file.bool("multiple"))
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        if let oldPath { draft.paths[file.id] = (draft.paths[file.id] ?? []).map { $0 == oldPath ? paths[0] : $0 }; draft.pathHashes.removeValue(forKey: oldPath) }
        else { draft.paths[file.id] = paths }
        for path in paths { draft.pathHashes.removeValue(forKey: path) }
        // An explicit choice may accept new bytes at the same path. Do not reuse
        // its earlier refusal or let canceled same-scope work restore that result.
        inspectFiles(force: true, newSelectionPaths: Set(paths)); save()
    }
    func inspectionIsCurrent(_ scope: RequestFileInspectionScope) -> Bool {
        guard store.detail == .request(request.id),
              let live = store.requests.first(where: { $0.id == request.id && $0.string("project_id") == request.string("project_id") }),
              !["answered", "resolved", "canceled", "superseded"].contains(Canceled.normalized(live.string("state"))) else { return false }
        let liveSpec = live.object("spec").isEmpty ? live : Record(values: live.object("spec"))
        return scope == RequestFileInspectionScope(request: live, draft: draft, fileRequests: liveSpec.records("file_requests"), storeIncarnation: store.storeIncarnation)
    }
    func send(_ response: String) {
        guard requestVisible, !answered, !staleDraft, !fileInspector.isChecking, store.connected, !store.busy else { return }
        if response == "answered" {
            guard complete else { return }
            inspectFiles(forSend: true)
        } else {
            save(); submit(response)
        }
    }
    func submit(_ response: String) {
        let answers: [[String: Any]] = questions.compactMap { question in
            let value = draft.values[question.id] ?? "", custom = draft.customValues[question.id] ?? ""
            guard !value.isEmpty || !custom.isEmpty else { return nil }
            let type = question.string("type")
            if ["choice", "single_choice", "multiple_choice"].contains(type) { return ["question_id": question.id, "option_ids": value.split(separator: "\n").map(String.init), "custom_text": custom] }
            var answer: [String: Any] = ["question_id": question.id]
            answer[["approval", "check"].contains(type) ? "result" : "text"] = value
            return answer
        }
        let files: [[String: Any]] = fileRequests.map { file in ["file_request_id": file.id, "paths": draft.paths[file.id] ?? [], "mode": draft.fileModes[file.id] ?? "reference", "path_sha256": draft.pathHashes.filter { (draft.paths[file.id] ?? []).contains($0.key) }, "explanation": draft.explanations[file.id] ?? ""] }
        var params: [String: Any] = ["project_id": request.string("project_id"), "request_id": request.id, "expected_revision": request.integer("revision"), "form_identity": formIdentity, "answers": response == "answered" ? answers : [], "files": response == "answered" ? files : [], "response": response, "explanation": draft.explanation]
        if !request.string("target_sha256").isEmpty { params["target_sha256"] = request.string("target_sha256") }
        params["inspected_images"] = response == "answered" ? draft.inspectedImages : []
        let success = response == "answered" ? "Answer saved; agent delivery is recorded separately" : "Response saved; request remains unresolved"
        let submission = RequestAnswerSubmission(request: request, action: response)
        answerCompletion.observe(submission)
        let recordedAnswer: ([String: Any]) -> Void = { recorded in
            guard let completion = answerCompletion.reconcile(submission, recorded: Record(values: recorded), currentRequest: store.requests.first(where: { $0.id == submission.requestID }), currentDetail: store.detail, draft: draft) else { return }
            draft = completion.draft; staleDraft = false
            store.saveAnswer(submission.requestID, draft: completion.draft)
            if completion.shouldDismiss { store.goBack() }
        }
        let completesGate = response == "answered" && !request.string("review_request_id").isEmpty && !answers.contains { $0["result"] as? String == "not_checked" }
        if completesGate {
            store.runTaskCommand("human_request_answer", params, taskID: request.string("task_id"), success: success, completion: recordedAnswer)
        } else {
            store.run("human_request_answer", params, success: success, completion: recordedAnswer)
        }
    }
}
