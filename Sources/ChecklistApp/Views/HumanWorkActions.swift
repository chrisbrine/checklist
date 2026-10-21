import SwiftUI

struct HumanWorkActions: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var progress = ""
    @State private var decision = ""
    var project: String { task.string("project_id") }
    var attempt: Record? { store.detailRecords("attempts",task:task).first { $0.id == task.string("active_attempt_id") } }
    var yourAttempt: Record? { guard let attempt, attempt.string("session_id") == "human", attempt.string("state") == "active" else { return nil }; return attempt }
    var ownTask: Bool { task.string("planned_assignee") == "human" || task.object("planned_assignee")["kind"] as? String == "human" }
    var permitsDecision: Bool {
        let policy = yourAttempt?.object("policy_snapshot") ?? store.projects.first { $0.id == project }?.object("policy") ?? [:]
        return task.string("kind") == "question" || (ownTask && policy["allow_human_decision_evidence"] as? Bool == true)
    }
    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        if ownTask || yourAttempt != nil {
            DetailSection(title: "Your work") {
                if let attempt = yourAttempt {
                    Text(permitsDecision ? "Record your decision and submit it when ready." : "Save a checkpoint or submit the actual managed evidence when ready.").checklistFont(.micro).foregroundStyle(.secondary)
                    TextField("Progress / next step", text: $progress).textFieldStyle(.roundedBorder)
                    AccessibleHStack {
                        Button("Save checkpoint") { command("work_checkpoint", attempt, extras: ["progress": progress]) }.checklistDisabled([(!store.connected, DisabledReasons.offline), (progress.isEmpty, "Write your progress first.")])
                        Button("Release…") { confirmation = Confirmations.releaseWork(task.string("key")) { command("work_release", attempt, extras: ["reason": progress.isEmpty ? "Owner released for later pickup" : progress]) } }
                        Spacer()
                    }
                    if attempt.values["pending_policy_revision"] != nil {
                        Text("The review rules changed. Save your progress, read the new required reviews below, then confirm them with a reason.").checklistFont(.micro).foregroundStyle(.orange)
                        Text("Required reviews: \((attempt.object("pending_policy_snapshot")["required_gates"] as? [String] ?? []).map(ReviewProjection.gateName).joined(separator: ", "))").checklistFont(.micro).foregroundStyle(.secondary)
                        Button("Confirm the new rules") { command("policy_acknowledge", attempt, extras: ["reason": progress]) }
                            .checklistDisabled([(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (attempt.string("last_checkpoint").isEmpty, "Save a checkpoint first."), (progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first.")])
                    }
                    if permitsDecision {
                        TextEditor(text: Binding(get: { decision }, set: { decision = $0; store.windowPreferences.set($0, forKey: "humanDecisionDraft:" + task.id) })).checklistFont(.body).frame(minHeight: 80).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).accessibilityLabel("Recorded decision").onAppear { if decision.isEmpty { decision = store.windowPreferences.string(forKey: "humanDecisionDraft:" + task.id) ?? "" } }
                        Button("Submit recorded decision") {
                            command("work_submit", attempt, extras: ["acceptance_revision": task.integer("acceptance_revision"), "evidence_manifest": ["kind": "decision", "decision": ["text": decision]]])
                        }.buttonStyle(.checklistProminent).checklistDisabled([(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write your decision first.")])
                        Text("Your recorded decision is the evidence. Checklist still checks the applicable project gates.").checklistFont(.micro).foregroundStyle(.secondary)
                    }
                    Button("Submit current evidence") {
                        let artifacts: [[String: Any]] = store.detailRecords("attachments",task:task).filter { $0.string("task_id") == task.id && $0.string("mode") == "managed" && $0.string("availability") == "available" }.map { ["artifact_id": $0.id, "sha256": $0.string("sha256")] }
                        command("work_submit", attempt, extras: ["acceptance_revision": task.integer("acceptance_revision"), "evidence_manifest": ["artifact_refs": artifacts]])
                    }.buttonStyle(.checklistBordered).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    if !permitsDecision { Text("Add a file or image as evidence first. Technical work follows this project's evidence and review rules.").checklistFont(.micro).foregroundStyle(.secondary) }
                } else if task.string("readiness") == "ready" && task.string("active_attempt_id").isEmpty && ["queued", "blocked"].contains(task.string("status_category")) {
                    Button("Start my work") {
                        store.run("work_claim", ["project_id": project, "task_id": task.id, "expected_revision": task.integer("revision"), "phase": "implementation"], success: "Your work started") { result in
                            if let id = result["id"] as? String, let token = result["claim_token"] as? String { do { try HumanClaims.save(token, attempt: id) } catch { store.error = PlainError.text(error) } }
                        }
                    }.buttonStyle(.checklistProminent).checklistDisabled([(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (!WorkActionProjection.canStartHumanWork(task), "This ticket cannot start now. Check its requirements.")])
                    if !WorkActionProjection.canStartHumanWork(task) {
                        Text(WorkActionProjection.humanPickupBlocker(task)).checklistFont(.micro).foregroundStyle(.secondary)
                    }
                }

            }
        }
    }
    func command(_ method: String, _ attempt: Record, extras: [String: Any]) {
        guard let token = HumanClaims.read(attempt.id) else { store.error = "The local claim credential is unavailable. Keep this ticket open and use recovery after confirming the work is stopped; ending a session is not proof."; return }
        var params = extras
        params["project_id"] = project; params["attempt_id"] = attempt.id; params["claim_token"] = token
        store.runTaskCommand(method, params, taskID: task.id, success: method == "work_submit" ? "Evidence submitted for review" : "Work updated") { _ in
            if method == "work_submit" || method == "work_release" { HumanClaims.remove(attempt.id) }
            if method == "work_submit" { store.windowPreferences.removeObject(forKey: "humanDecisionDraft:" + task.id); decision = "" }
        }
    }
}
