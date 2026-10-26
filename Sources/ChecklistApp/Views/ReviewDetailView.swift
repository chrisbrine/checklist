import SwiftUI
import ChecklistDomain
import AppKit
import ChecklistProviders

struct ReviewDetailView: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var selectedManifestID = ""
    @State private var sheet: ReviewSheet?
    @State private var policyReason = ""
    var projection: ReviewProjection { ReviewTargetPresentation.projection(task: task, project: store.project(task.string("project_id")), data: store.selectedReviewData(task)) }
    var assignedToOwner: Bool { task.string("planned_assignee") == "human" || task.object("planned_assignee")["kind"] as? String == "human" }
    var canStartImplementation: Bool { !assignedToOwner && task.values["pickup_eligible"] as? Bool != false && task.values["prerequisites_satisfied"] as? Bool != false && task.string("disposition") != "superseded" && task.string("readiness") == "ready" && ["queued", "blocked"].contains(task.string("status_category")) && !task.bool("archived") && !task.bool("trashed") && projection.activeAttempt == nil && task.string("active_verification_request_id").isEmpty }
    var selected: Record? { projection.manifests.first { $0.id == selectedManifestID } ?? (selectedManifestID.isEmpty ? projection.current : nil) }
    /// CL-52: the next action shows in a bar under the ticket's status line; the details stay here.
    enum Part { case nextAction, details }
    var part: Part = .details
    var body: some View {
        Group {
            switch part {
            case .nextAction: NextActionBar { nextAction }
            case .details: details
            }
        }
        .onAppear { if selectedManifestID.isEmpty { selectedManifestID = task.string("current_manifest_id") } }
        .onChange(of: task.id) { _, _ in selectedManifestID = task.string("current_manifest_id"); sheet = nil }
        .onChange(of: task.string("current_manifest_id")) { _, value in if selectedManifestID.isEmpty { selectedManifestID = value } }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .prepare(let request): AgentReviewPreparationSheet(task:task,request:request).environmentObject(store)
            case .releaseOwner(let attempt): ExistingOwnerReviewReleaseSheet(task:task,attempt:attempt).environmentObject(store)
            case .waiver(let finding): FindingWaiverSheet(finding: finding).environmentObject(store)
            case .retry(let request): ReviewRetrySheet(task: task, request: request).environmentObject(store)
            case .recover(let attempt): TaskRecoverySheet(task: task, attempt: attempt).environmentObject(store)
            }
        }
    }
    @ViewBuilder var details: some View {
        DetailSection(title: "Review & completion") {
            let hold = Record(values: task.object("release_hold"))
            if !hold.values.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Label("Accepted and held for release set \(hold.string("release_set"))", systemImage: "shippingbox").checklistFont(.captionStrong)
                    Text(hold.string("reason")).checklistFont(.micro).textSelection(.enabled)
                    Text("It completes when its release set is completed. It is not reopened or reviewed again.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
            }
            ForEach(projection.repeatedCauses, id: \.first?.id) { group in
                Label("The same cause returned for the second time (\(group.count) findings). Change the approach: split the ticket or write a new brief before another round.", systemImage: "exclamationmark.triangle").checklistFont(.micro).foregroundStyle(.orange)
            }
            if !task.strings("acceptance").isEmpty {
                DisclosureGroup("Acceptance") {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        ForEach(StableListRows.acceptance(task.strings("acceptance"), task: task)) { row in
                            Text("\(row.number). \(row.value)").checklistFont(.callout).textSelection(.enabled)
                        }
                        Text("Criteria describe the expected outcome. Only recorded evidence and gate verdicts establish completion.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    }.padding(.top, Spacing.small)
                }.checklistFont(.micro)
            }
            if !projection.manifests.isEmpty {
                Picker("Show submission", selection: $selectedManifestID) {
                    if projection.current == nil { Text("No current submission").tag("") }
                    ForEach(RecordOrdering.newestFirst(projection.manifests)) { manifest in
                        Text(submissionLabel(manifest)).tag(manifest.id)
                    }
                }.checklistFont(.micro)
                if let selected {
                    target(selected)
                    ForEach(projection.gates(for: selected), id: \.self) { gate in
                        ReviewGateCard(gate: gate, manifest: selected, projection: projection)
                    }
                    if projection.gates(for: selected).isEmpty { Text("This target's captured policy requires no review gates.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                } else if !selectedManifestID.isEmpty {
                    Label("The selected target is unavailable. Your selection and note draft are retained.", systemImage: "exclamationmark.circle").checklistFont(.micro).foregroundStyle(.orange)
                }
            } else {
                Text("No implementation target has been submitted. Required gates: \(projection.requiredGates.map(ReviewProjection.gateName).joined(separator: ", ").isEmpty ? "none" : projection.requiredGates.map(ReviewProjection.gateName).joined(separator: ", ")).").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            TestResultEvidenceView(task: task, manifest: selected, projection: projection)
            let targetHistory = store.selectedReviewData(task)["review_target_history"] as? [String: Any] ?? [:]
            if let problem = targetHistory["problem"] as? String, !problem.isEmpty {
                Text(problem).checklistFont(.micro).foregroundStyle(.orange)
            }
            ImageReviewSection(manifest: selected, projection: projection)
            EvidenceMeasuresView(manifest: selected, projection: projection)
            PlaytestBundleView(manifest: selected, projection: projection)
            if !projection.findings.isEmpty {
                Divider()
                let advice = projection.openFindings.count - projection.openBlockingFindings.count
                Text("Findings · \(projection.openFindings.count) open" + (advice > 0 ? " (\(advice) advice)" : "")).checklistFont(.captionStrong)
                ForEach(RecordOrdering.newestFirst(projection.findings)) { finding in
                    ReviewFindingCard(finding: finding, resolutions: projection.resolutions.filter { $0.string("finding_id") == finding.id }, inspect: { selectedManifestID = finding.string("first_manifest_id") }, waive: { sheet = .waiver(finding) })
                }
            }
        }
    }
    @ViewBuilder var nextAction: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // A blocking request comes first; then recovery, a Draft, and the guarded work actions.
            if let lead = TicketNextAction.lead(task: task, requests: projection.humanRequests, activeAttempt: projection.activeAttempt,
                                                session: projection.activeAttempt.flatMap { active in store.detailRecords("sessions", task: task).first { $0.id == active.string("session_id") } }) {
                NextActionLead(task: task, step: lead) { sheet = .recover($0) }
            } else if task.integer("pending_policy_revision", fallback: 0) > 0 && projection.activeAttempt == nil {
                Text("The review rules for this project changed").checklistFont(.captionStrong)
                Text("Check what changed. Earlier evidence and verdicts stay with their submissions; the new checks must pass before completion.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                TechnicalDetails([("Policy revision", "\(task.integer("pending_policy_revision"))")], raw: [("Revised completion rules", task.object("pending_policy_snapshot"))])
                TextField("Why this ticket can use the new rules", text: $policyReason).textFieldStyle(.roundedBorder)
                Button("Use the new rules") {
                    store.run("policy_acknowledge", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "reason": policyReason], success: "New rules applied; evidence and remaining checks rechecked", completion: { _ in policyReason = "" })
                }.buttonStyle(.checklistProminent).checklistDisabled([(policyReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)])
            } else if let active = projection.activeAttempt {
                if active.integer("pending_policy_revision", fallback: 0) > 0 {
                    Label("The review rules changed. Whoever works on this ticket must confirm the new rules before submitting.", systemImage: "exclamationmark.circle").checklistFont(.micro).foregroundStyle(.orange)
                }
                if active.string("phase") == "review" {
                    Label("Reviewer working · \(providerLabel(active))", systemImage: "magnifyingglass").checklistFont(.captionStrong)
                    if active.string("session_id") == "human" {
                        Button("Release prior owner review claim") { sheet = .releaseOwner(active) }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    } else { Text("The current reviewer must finish or release this review before another review can start.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                } else {
                    Text("Implementation working · \(providerLabel(active))").checklistFont(.captionStrong)
                    Text("Next: submit the finished work for review.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
            } else if projection.canComplete {
                Button("Complete ticket") {
                    store.runTaskCommand("task_complete", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "current_manifest_id": task.string("current_manifest_id")], taskID: task.id, success: "Ticket completed after validating the current target and gates")
                }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                Text("Checklist checks the submitted work and every required review again before it completes the ticket.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if let request = projection.eligibleReviewRequest {
                Label("Ready for reviewer · Unassigned", systemImage: "person.crop.circle.badge.questionmark").checklistFont(.captionStrong)
                Button("Start independent review") { startReview(request) }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            } else if let current = projection.current,
                      let blocked = projection.gates(for: current).compactMap({ projection.request(for: $0, manifest: current) }).first(where: { $0.string("state") == "blocked" }),
                      projection.activeAttempt == nil, task.string("active_verification_request_id").isEmpty {
                Button("Request another review") { sheet = .retry(blocked) }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            } else if projection.current == nil && canStartImplementation {
                Button(projection.openFindings.isEmpty ? "Start my work" : "Start fixing findings") { startImplementation() }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                Text("Starts your work on this ticket. Submit it for review when it is ready.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else {
                Text(projection.current == nil ? (projection.openFindings.isEmpty ? "Next: start the work and submit it for review." : "Next: fix the open findings and submit the work again.") : "Completion is waiting for the requirements below.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            if task.string("status_category") != "done" && !projection.completionBlockers.isEmpty {
                DisclosureGroup("Remaining requirements · \(projection.completionBlockers.count)") {
                    VStack(alignment: .leading, spacing: Spacing.compact) { ForEach(projection.completionBlockers, id: \.self) { Text("• \($0)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) } }.padding(.top, Spacing.compact)
                }.checklistFont(.micro)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder func target(_ manifest: Record) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(projection.targetWarnings(manifest), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").checklistFont(.micro).foregroundStyle(.orange) }
            if manifest.id != task.string("current_manifest_id"), !task.string("current_manifest_id").isEmpty {
                Button("Show current submission") { selectedManifestID = task.string("current_manifest_id") }.checklistFont(.micro)
            }
            Text(submissionLabel(manifest)).checklistFont(.microEmphasis)
            if task.string("completion_policy_manifest_id") == manifest.id {
                Text("Uses the updated review rules").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            ForEach(StableListRows.artifacts(projection.artifactRefs(for: manifest), manifest: manifest)) { row in
                let ref = row.value
                if let file = projection.artifact(ref) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        AttachmentRow(file: file, targetManifestID: manifest.id)
                    }
                } else { Text("A submitted file is missing").checklistFont(.micro).foregroundStyle(.orange) }
            }
            let evidence = Record(values: manifest.object("evidence"))
            let source = Record(values: evidence.object("source_capture"))
            if !source.values.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("Captured source · \(source.records("files").count) files").checklistFont(.microEmphasis)
                    let localSource = Record(values: manifest.object("resolved_source_capture"))
                    if !localSource.string("snapshot_path").isEmpty {
                        Button("Reveal captured source") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: localSource.string("snapshot_path"))]) }.checklistFont(.micro)
                    }
                }
            }
            let executions = projection.executions.filter { $0.string("manifest_id") == manifest.id }
            let artifactRows = projection.artifactRefs(for: manifest).map { ("Attachment", "\($0.string("artifact_id")) · SHA-256 \($0.string("sha256"))") }
            TechnicalDetails([("Submission manifest", manifest.id), ("Implementation attempt", manifest.string("attempt_id")),
                              ("Evidence digest", manifest.string("digest", fallback: "Not recorded")), ("Submitted at", manifest.string("created_at", fallback: "Not recorded")),
                              ("Acceptance revision", "\(manifest.integer("acceptance_revision"))"), ("Policy revision", "\(manifest.integer("policy_revision"))")]
                             + (task.string("completion_policy_manifest_id") == manifest.id ? [("Updated rules revision", "\(task.integer("completion_policy_revision"))")] : [])
                             + artifactRows
                             + (source.values.isEmpty ? [] : [("Source fingerprint", source.string("sha256")), ("Base revision", source.string("base_revision", fallback: "Not recorded"))]),
                             raw: (evidence.values.isEmpty ? [] : [("Captured source, build and check evidence", evidence.values)])
                                + executions.map { ("Service-run check", $0.values) })
        }.padding(Spacing.control).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: Radius.medium))
    }
    /// The ticket view loads a bounded set of submissions, so a label never claims a position number.
    func submissionLabel(_ manifest: Record) -> String {
        let state = manifest.id == task.string("current_manifest_id") ? "Current submission" : "Earlier submission"
        return "\(state) · \(relativeTime(manifest.string("created_at")))"
    }
    func providerLabel(_ attempt: Record) -> String {
        if attempt.string("session_id") == "human" { return "You" }
        return store.detailRecords("sessions",task:task).first { $0.id == attempt.string("session_id") }?.string("provider", fallback: "Agent").capitalized ?? "Agent"
    }
    func startImplementation() {
        store.runTaskCommand("work_claim", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "phase": AttemptPhase.implementation.rawValue], taskID: task.id, success: "Your implementation attempt started") { result in
            guard let id = result["id"] as? String, let token = result["claim_token"] as? String else { store.error = "The service did not confirm that your work started. Refresh the ticket before you continue."; return }
            do { try HumanClaims.save(token, attempt: id) } catch { store.error = "The claim started, but its local credential could not be saved: \(PlainError.text(error)). Verify this attempt before recovery." }
        }
    }
    func startReview(_ request: Record) {
        sheet = .prepare(request)
    }

}

private enum ReviewSheet: Identifiable {
    case prepare(Record), releaseOwner(Record), waiver(Record), retry(Record), recover(Record)
    var id: String { switch self { case .prepare(let value): return "prepare:" + value.id;case .releaseOwner(let value): return "release:" + value.id; case .waiver(let value): return "waiver:" + value.id; case .retry(let value): return "retry:" + value.id; case .recover(let value): return "recover:" + value.id } }
}

private struct ReviewGateCard: View {
    @EnvironmentObject var store: ChecklistStore
    let gate: String
    let manifest: Record
    let projection: ReviewProjection
    var request: Record? { projection.request(for: gate, manifest: manifest) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack { Text(ReviewProjection.gateName(gate)).checklistFont(.captionStrong); Spacer(); Text(stateLabel).checklistFont(.micro).foregroundStyle(stateColor) }
            let failed = projection.failedRounds(for: gate)
            if failed > 0 { Text("Failed rounds: \(failed)").checklistFont(.micro).foregroundStyle(failed >= 2 ? .orange : Color.checklistSecondaryText) }
            if let request {
                let evidence = Record(values: request.object("evidence_request"))
                if request.string("state") == "evidence_requested", !evidence.values.isEmpty {
                    Text("More evidence requested: \(evidence.string("reason"))").checklistFont(.micro).textSelection(.enabled)
                    Text("Add the evidence to this ticket and request the review again. The submission stays the same.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                ForEach(request.records("not_run_checks"), id: \.values.description) { check in
                    Text("Not run: \(check.string("check")) · \(check.string("reason"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
                }
                if !request.records("supplemental_evidence_refs").isEmpty {
                    Text("Added evidence: " + request.records("supplemental_evidence_refs").map { $0.string("name", fallback: "Attachment") }.joined(separator: ", ")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                if let reviewer = projection.reviewer(for: request) {
                    let session = store.detailRecords("sessions",task:projection.task).first { $0.id == reviewer.string("session_id") }
                    Text("Reviewer working · \(reviewer.string("session_id") == "human" ? "You" : session?.string("provider", fallback: "Agent").capitalized ?? "Agent")").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    if !reviewer.string("progress").isEmpty { Text(reviewer.string("progress")).checklistFont(.micro).textSelection(.enabled) }
                    let draft = Record(values: reviewer.object("draft_verdict"))
                    if !draft.values.isEmpty { Text("Draft verdict saved · \(ReviewProjection.verdictLabel(draft.string("verdict"))) · \(relativeTime(draft.string("saved_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    if gate == "review" {
                        ReviewRequirementsSummaryView(title:"Applied review requirements",snapshot:reviewer.object("review_requirement_snapshot"),projectID:projection.task.string("project_id"),taskKind:projection.task.string("kind"))
                    }
                } else if request.string("state") == "queued" { Text(gate == "human_approval" ? "Waiting for exact-target owner approval request" : "Ready for reviewer · Unassigned").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                if let review = projection.verdict(for: request) {
                    Text("\(ReviewProjection.verdictLabel(review.string("verdict"))) · \(review.string("actor_display", fallback: "Reviewer")) · \(relativeTime(review.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    if !review.records("inspected_images").isEmpty {
                        Text("Inspected originals: \(review.records("inspected_images").count)").checklistFont(.micro)
                    }
                    let submitter = Record(values: review.object("submitted_by"))
                    if !submitter.values.isEmpty { Text("Draft by this reviewer, submitted by \(submitter.string("actor_display", fallback: "the coordinator"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    if !review.string("reason").isEmpty { Text((review.string("check").isEmpty ? "" : review.string("check") + ": ") + review.string("reason")).checklistFont(.micro).textSelection(.enabled) }
                    ForEach(StableListRows.checks(review.records("checks"), review: review)) { row in
                        let check = row.value
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text("\(check.string("label", fallback: check.string("name", fallback: "Recorded check"))) · \(check.string("result", fallback: check.string("status", fallback: "Recorded")))").checklistFont(.microEmphasis)
                            if !check.string("notes", fallback: check.string("detail")).isEmpty { Text(check.string("notes", fallback: check.string("detail"))).checklistFont(.micro).textSelection(.enabled) }
                            if let cause = ReviewProjection.failureCauseLabel(check) { Text(cause).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                        }
                    }
                    let assessment = Record(values:review.object("review_assessment"))
                    if gate == "review" {
                        ReviewRequirementsSummaryView(title:"Recorded review requirements",snapshot:review.object("review_requirement_snapshot"),projectID:projection.task.string("project_id"),taskKind:projection.task.string("kind"),preflight:assessment.object("review_evidence_requirements"))
                    }
                    if !assessment.values.isEmpty {
                        Text("Acceptance and project requirements assessed by this reviewer").checklistFont(.microStrong)
                        ForEach(StableListRows.assessments(AgentReviewAssessmentProjection(assessment:assessment).rows, review: review)) { item in
                            let row = item.value
                            VStack(alignment:.leading,spacing: Spacing.tight) {
                                Text("\(row.string("requirement")) · \(GlossaryText.humanize(row.string("result")))").checklistFont(.microEmphasis)
                                Text(row.string("rationale")).checklistFont(.micro).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let human = store.detailRecords("requests",task:projection.task).first(where: { $0.id == request.string("human_request_id") }), !["answered", "canceled", "superseded"].contains(human.string("state")) {
                    Button("Open owner verification") { store.open(.request(human.id)) }.checklistFont(.micro)
                }
                TechnicalDetails([("Review request", request.id), ("Submission manifest", manifest.id), ("Latest verdict", request.string("latest_verdict_id", fallback: "None")),
                                  ("Review attempt", projection.reviewer(for: request)?.id ?? "")],
                                 raw: projection.verdict(for: request).map { [("Verdict and check evidence", $0.values)] } ?? [])
            } else { Text("No request recorded for this gate and target. Completion remains blocked.").checklistFont(.micro).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
    var stateLabel: String {
        guard let request else { return "Missing" }
        let historical = manifest.id != projection.task.string("current_manifest_id")
        let suffix = historical ? " · earlier submission" : (projection.targetWarnings(manifest).isEmpty ? "" : " · submission changed")
        switch request.string("state") {
        case "queued": return "Waiting" + suffix
        case "active": return "In review" + suffix
        case "human_pending": return "Waiting for you" + suffix
        case "pass": return "Passed" + suffix
        case "reject": return "Needs changes" + suffix
        case "blocked": return "Blocked" + suffix
        case "evidence_requested": return "More evidence requested" + suffix
        case "superseded": return "Superseded"
        default: return GlossaryText.title(request.string("state")) + suffix
        }
    }
    var stateColor: Color {
        guard manifest.id == projection.task.string("current_manifest_id"), projection.targetWarnings(manifest).isEmpty else { return Color.checklistSecondaryText }
        switch request?.string("state") { case "pass": return .green; case "reject", "blocked", "evidence_requested": return .orange; default: return Color.checklistSecondaryText }
    }
}

private struct ReviewFindingCard: View {
    @EnvironmentObject var store: ChecklistStore
    let finding: Record
    let resolutions: [Record]
    let inspect: () -> Void
    let waive: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            let advice = finding.string("severity") == "advice"
            AccessibleHStack { Text("\(advice ? "Advice · does not block completion" : GlossaryText.title(finding.string("severity", fallback: "blocking"))) · \(GlossaryText.title(finding.string("state")))").checklistFont(.microStrong).foregroundStyle(finding.string("state") == "open" && !advice ? .orange : Color.checklistSecondaryText) }
            if let change = finding.records("severity_history").last { Text("Severity changed to \(change.string("to")) by \(change.string("actor_display", fallback: "Reviewer")): \(change.string("reason"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled) }
            Text(finding.string("description")).checklistFont(.callout).textSelection(.enabled)
            Text("\(ReviewProjection.gateName(finding.string("gate"))) · \(finding.string("author_display", fallback: "Reviewer"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            AccessibleHStack {
                Button("Show the reviewed submission", action: inspect)
                if finding.string("state") == "open" { Button("Waive finding…", action: waive).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
            }.checklistFont(.micro)
            ForEach(RecordOrdering.newestFirst(resolutions)) { resolution in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(ReviewProjection.findingDispositionLabel(resolution)).checklistFont(.microEmphasis)
                    Text(resolution.string("reason")).checklistFont(.micro).textSelection(.enabled)
                    Text("\(resolution.string("actor_display", fallback: "Reviewer")) · \(relativeTime(resolution.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
            }
            TechnicalDetails([("Finding", finding.id)], raw: [("Finding history and evidence", ["finding": finding.values, "dispositions": resolutions.map(\.values)])])
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
}

private struct FindingWaiverSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) var dismiss
    let finding: Record
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Explicitly waive this finding").checklistFont(.sheetTitle)
            Text(finding.string("description")).checklistFont(.callout).textSelection(.enabled)
            Text("A waiver records your reason and identity. It does not turn a failed check into a pass or waive other gates.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            TextField("Reason for accepting this unresolved issue", text: $reason).textFieldStyle(.roundedBorder)
            AccessibleHStack { Button("Cancel") { dismiss() }; Spacer(); Button("Record owner waiver") { store.run("finding_waive", ["project_id": finding.string("project_id"), "finding_id": finding.id, "expected_revision": finding.integer("revision"), "reason": reason], success: "Explicit owner waiver recorded", completion: { _ in dismiss() }) }.buttonStyle(.checklistProminent).checklistDisabled([(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)]) }
        }.padding(Spacing.page).checklistSheet(width: 520)
    }
}

private struct ReviewRetrySheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) var dismiss
    let task: Record
    let request: Record
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Request another review").checklistFont(.sheetTitle)
            Text("The blocked verdict and stable findings remain in history. A new request names the same exact current target.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            TextField("What changed so this review can continue?", text: $reason).textFieldStyle(.roundedBorder)
            AccessibleHStack { Button("Cancel") { dismiss() }; Spacer(); Button("Request review") { store.run("review_request", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "target_manifest_id": request.string("manifest_id"), "gate": request.string("gate"), "supersedes_request_id": request.id, "reason": reason], success: "Another exact-target review requested", completion: { _ in dismiss() }) }.buttonStyle(.checklistProminent).checklistDisabled([(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)]) }
        }.padding(Spacing.page).checklistSheet(width: 520)
    }
}

private struct AgentReviewPreparationSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) var dismiss
    let task: Record
    let request: Record
    @State private var provider = ProviderPolicyDefaults.defaultReviewProvider
    @State private var preparation: [String:Any] = [:]
    @State private var loading = true
    @State private var failure = ""
    @State private var opened = false
    @State private var copied = false
    @State private var preparationID = UUID()
    var providers: [String] {
        let policy = store.project(task.string("project_id"))?.object("policy") ?? [:]
        return HandoffProvider.eligibleIDs(role: "reviewer", policy: policy, taskKind: task.string("kind"))
    }
    var selectedProvider: HandoffProvider { HandoffProvider(id: provider) }
    var instruction: String { preparation["instruction"] as? String ?? "" }
    var applicationURL: URL? { selectedProvider.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var composeURL: URL? { guard let raw = preparation["compose_url"] as? String else {return nil};return selectedProvider.validatedComposeURL(raw) }
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.group) {
            Text("Prepare independent agent review").checklistFont(.sheetTitle)
            Text("A fresh non-contributor reviews this exact target against its acceptance and the project's requirements. The reviewer chooses its own checks and attaches its own evidence.").checklistFont(.callout)
            // The prepared instruction names IDs and raw records; it is copied or opened, not read in the main flow.
            TechnicalDetails([("Review request", request.id), ("Submission", request.string("manifest_id"))], blocks: [("Reviewer instruction", instruction)])
            Picker("Reviewer provider",selection:$provider) { ForEach(providers,id:\.self) { Text(HandoffProvider(id: $0).name).tag($0) } }.pickerStyle(.segmented).tint(.checklistAccent)
            if loading {ProgressView("Preparing exact review context…")}
            if !failure.isEmpty {Text(failure).foregroundStyle(.orange);Button("Retry preparation") {Task {await prepare()}}}
            if !instruction.isEmpty {
                let contract = Record(values:preparation["review_contract"] as? [String:Any] ?? [:])
                ReviewRequirementsSummaryView(title:"Review requirement preview",snapshot:contract.object("review_requirements"),projectID:task.string("project_id"),taskKind:task.string("kind"),preflight:preparation["review_evidence_requirements"] as? [String:Any] ?? [:],previewOnly:true)
                Text(preparation["limitation"] as? String ?? "").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Text("No review turn, connection or claim has started. Send the prepared prompt in a fresh conversation; its actual session must connect and claim this request.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                if opened {Label("Prepared \(selectedProvider.name) composer opened. Press Send there to start the reviewer.",systemImage:"arrow.up.right.square").checklistFont(.micro)}
            }
            AccessibleHStack {
                Button("Close") {dismiss()};Spacer()
                Button(copied ? "Copied" : "Copy reviewer instruction") {clipboard(instruction);copied = true}.checklistDisabled([(loading, "Still loading."), (instruction.isEmpty, "The ticket instruction is not ready yet.")])
                if let url = composeURL,let app = applicationURL {
                    Button("Open prepared \(selectedProvider.name) review") {
                        NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()) {_,error in Task {@MainActor in if let error {failure = PlainError.text(error)}else{opened = true}}}
                    }.buttonStyle(.checklistProminent).checklistDisabled([(loading, "Still loading."), (!failure.isEmpty, "Loading failed. Read the message above.")])
                }
            }
        }.padding(Spacing.page).checklistSheet(width: 650)
            .task {if !providers.contains(provider),let first = providers.first {provider = first};await prepare()}
            .onChange(of:provider) {_,_ in Task {await prepare()}}
    }
    func prepare() async {
        let generation = UUID(), selected = selectedProvider
        preparationID = generation
        loading = true;failure = "";preparation = [:];opened = false;copied = false
        defer {if preparationID == generation {loading = false}}
        guard providers.contains(selected.id) else {failure = "No enabled, qualified provider is eligible for this review.";return}
        do {
            let response = try await store.request("review_prepare",["project_id":task.string("project_id"),"task_id":task.id,"review_request_id":request.id,"target_manifest_id":request.string("manifest_id"),"gate":request.string("gate"),"provider":selected.id])
            guard preparationID == generation, provider == selected.id else {return}
            if let raw = response["compose_url"] as? String, selected.validatedComposeURL(raw) == nil {
                throw NSError(domain:"Checklist",code:2,userInfo:[NSLocalizedDescriptionKey:"The service returned an unsupported compose link for \(selected.name). No chat was opened."])
            }
            preparation = response
        }
        catch {if preparationID == generation {failure = PlainError.text(error)}}
    }
}

private struct ExistingOwnerReviewReleaseSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) var dismiss
    let task: Record
    let attempt: Record
    @State private var reason = "Release the prior owner claim so a fresh independent agent can review."
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.group) {
            Text("Release prior owner review claim").checklistFont(.sheetTitle)
            Text("This prior owner claim is separate from a fresh agent review. Release it, then prepare an independent reviewer conversation. Owner approval and explicit waivers keep their own labeled actions.").checklistFont(.callout)
            TextField("Release reason",text:$reason).textFieldStyle(.roundedBorder)
            AccessibleHStack {Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Release without a verdict") {
                guard let token = HumanClaims.read(attempt.id) else {store.error = "The exact prior claim credential is unavailable. Use verified recovery after inspecting its handler.";return}
                store.runTaskCommand("work_release",["project_id":task.string("project_id"),"attempt_id":attempt.id,"claim_token":token,"reason":reason],taskID:task.id,success:"Prior owner review released without a verdict") {_ in HumanClaims.remove(attempt.id);dismiss()}
            }.checklistDisabled([(reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, "Write a reason first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)])}
        }.padding(Spacing.page).checklistSheet(width: 560)
    }
}

/// Presentation-only targets never add historical requests or verdicts to action
/// authority. Current attachment observations win when an ID appears in both sets.
enum ReviewTargetPresentation {
    static func projection(task: Record, project: Record?, data: [String: Any]) -> ReviewProjection {
        let history = data["review_target_history"] as? [String: Any] ?? [:]
        var display = data
        for family in ["manifests", "attachments"] {
            let current = (data[family] as? [[String: Any]] ?? []).map(Record.init)
            let prior = (history[family] as? [[String: Any]] ?? []).map(Record.init)
            let currentByID = Dictionary(current.map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<Data>()
            display[family] = (prior + current).compactMap { row -> [String: Any]? in
                let id = Data(row.id.utf8)
                guard seen.insert(id).inserted else { return nil }
                var result = (currentByID[id] ?? row).values
                // This link is service presentation metadata, not a stored manifest edit.
                if family == "manifests", let previous = row.values["previous_manifest_id"] { result["previous_manifest_id"] = previous }
                return result
            }
        }
        return ReviewProjection(task: task, project: project, data: display)
    }
}
