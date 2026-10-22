import SwiftUI

struct PlaytestBundleFile: Identifiable {
    let role: String
    let ref: Record
    let file: Record?
    let cited: Bool
    var id: String { role + ":" + ref.string("artifact_id") }
    var available: Bool { file?.string("mode") == "managed" && file?.string("availability") == "available" && file?.string("sha256") == ref.string("sha256") }
}

struct PlaytestBundleProjection {
    let manifest: Record
    let review: ReviewProjection
    var bundle: Record { Record(values:manifest.object("evidence")["playtest_bundle"] as? [String:Any] ?? [:]) }
    var verdicts: [Record] { review.reviews.filter { $0.string("manifest_id") == manifest.id } }
    var citedIDs: Set<String> {
        func ids(_ value: Any) -> Set<String> {
            if let object = value as? [String:Any] {
                var result = Set<String>();if let id = object["artifact_id"] as? String { result.insert(id) }
                for value in object.values { result.formUnion(ids(value)) };return result
            }
            if let array = value as? [Any] { return array.reduce(into:Set<String>()) { $0.formUnion(ids($1)) } }
            return []
        }
        return verdicts.reduce(into:Set<String>()) { result,verdict in
            result.formUnion(ids(verdict.object("review_assessment")));result.formUnion(ids(verdict.values["checks"] ?? []))
        }
    }
    var files: [PlaytestBundleFile] {
        var rows: [(String,Record)] = [("Scenario",Record(values:bundle.object("scenario"))),("Build",Record(values:bundle.object("build")))]
        rows += bundle.records("state_files").enumerated().map { ("State \($0.offset + 1)",$0.element) }
        rows += bundle.records("screenshots").enumerated().map { ("Screenshot \($0.offset + 1)",$0.element) }
        rows.append(("Log",Record(values:bundle.object("log"))))
        let cited = citedIDs
        return rows.filter { !$0.1.string("artifact_id").isEmpty }.map { role,ref in
            PlaytestBundleFile(role:role,ref:ref,file:review.attachments.first { $0.id == ref.string("artifact_id") },cited:cited.contains(ref.string("artifact_id")))
        }
    }
    func acceptanceText(_ item: Record,verdict: Record) -> String {
        let contract = Record(values:Record(values:verdict.object("review_assessment")).object("contract"))
        return contract.records("acceptance").first { $0.id == item.string("requirement_id") }?.string("text") ?? item.string("requirement_id")
    }
}

struct PlaytestBundleView: View {
    @EnvironmentObject var store: ChecklistStore
    let manifest: Record?
    let projection: ReviewProjection
    @State private var cleanup: Record?
    @State private var error = ""
    @State private var reading = false
    var body: some View {
        if let manifest,manifest.object("evidence")["playtest_bundle"] != nil {
            let value = PlaytestBundleProjection(manifest:manifest,review:projection)
            let build = Record(values:value.bundle.object("build"))
            DisclosureGroup("Playtest bundle · \(build.string("build_id"))") {
                VStack(alignment:.leading,spacing:Spacing.small) {
                    Text("Build \(build.string("build_id")) · \(build.string("version")) · \(build.string("platform"))").checklistFont(.microEmphasis)
                    Text(manifest.id == projection.task.string("current_manifest_id") ? "Bound to this exact submission and build. A different build requires a new bundle." : "Earlier bundle. Its results do not verify a replacement build.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    ForEach(value.files) { row in
                        VStack(alignment:.leading,spacing:Spacing.tight) {
                            Text(row.role).checklistFont(.microEmphasis)
                            if row.available, let file = row.file {
                                AttachmentRow(file:file,targetManifestID:manifest.id)
                            } else {
                                Text(row.file?.string("name",fallback:"File") ?? "Missing file").checklistFont(.microEmphasis).lineLimit(2)
                            }
                            Text("\(row.available ? "Available managed original" : "Original unavailable or changed")\(row.cited ? " · Cited in a verdict" : " · Not cited in a recorded verdict")\(row.file?.bool("keep_original") == true ? " · Keep original" : "")").checklistFont(.micro).foregroundStyle(row.available ? Color.checklistSecondaryText : .orange)
                            TechnicalDetails([("Attachment",row.ref.string("artifact_id")),("SHA-256",row.ref.string("sha256"))])
                        }.padding(Spacing.small).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:Radius.small))
                    }
                    ForEach(value.verdicts) { verdict in
                        let items = Record(values:verdict.object("review_assessment")).records("acceptance")
                        if !items.isEmpty {
                            Text("\(ReviewProjection.verdictLabel(verdict.string("verdict"))) · \(verdict.string("actor_display",fallback:"Reviewer"))").checklistFont(.microEmphasis)
                            ForEach(Array(items.enumerated()),id:\.offset) { _,item in
                                VStack(alignment:.leading,spacing:Spacing.tight) {
                                    Text("\(item.string("result").capitalized): \(value.acceptanceText(item,verdict:verdict))").checklistFont(.microEmphasis).foregroundStyle(item.string("result") == "fail" ? Color.orange : .primary)
                                    Text(verbatim:item.string("rationale")).checklistFont(.micro).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Text("Reviewers can request Keep original for cited bundle files with their verdict. Other files follow the project’s archive policy and existing holds. Preview the normal cleanup before archiving.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    Button("Preview archive cleanup") { preview() }.checklistDisabled([(reading,"The cleanup preview is loading."),(!store.connected,DisabledReasons.offline),(!store.selectedTicketCurrent(projection.task.id),"Refresh the ticket before previewing cleanup.")])
                    if let cleanup {
                        Text("Eligible originals: \(cleanup.strings("attachment_ids").count) · selected \(ByteCountFormatter.string(fromByteCount:(cleanup.values["clean_bytes"] as? NSNumber)?.int64Value ?? 0,countStyle:.file)) · kept \(ByteCountFormatter.string(fromByteCount:(cleanup.values["retained_bytes"] as? NSNumber)?.int64Value ?? 0,countStyle:.file)). No files have been removed by this preview.").checklistFont(.micro)
                    }
                    if !error.isEmpty { Text(verbatim:error).checklistFont(.micro).foregroundStyle(.orange) }
                    TechnicalDetails([("Bundle",value.bundle.id),("Bundle SHA-256",value.bundle.string("sha256")),("Build SHA-256",build.string("sha256")),("Submission",manifest.id)])
                }.padding(.top,Spacing.small)
            }.checklistFont(.micro)
                .onChange(of:manifest.id) { _,_ in cleanup = nil;error = "" }
        }
    }
    private func preview() {
        reading = true;cleanup = nil;error = ""
        let tid = projection.task.id,pid = projection.task.string("project_id")
        Task { @MainActor in
            defer { reading = false }
            do {
                let result = try await store.request("attachment_cleanup_preview",["project_id":pid,"task_id":tid])
                guard projection.task.id == tid,store.selectedTicketCurrent(tid),!Task.isCancelled else { return }
                cleanup = Record(values:result)
            } catch { self.error = PlainError.text(error) }
        }
    }
}
