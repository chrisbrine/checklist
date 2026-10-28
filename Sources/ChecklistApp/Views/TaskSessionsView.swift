import SwiftUI
import AppKit
import ChecklistCore

struct TaskSessionsView: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var recoveryAttempt: Record?
    @State private var handoffProvider: HandoffProvider?
    @State private var accessConfirmation: PendingConfirmation?
    var attempts: [Record] { RecordOrdering.newestFirst(store.detailRecords("attempts",task:task).filter { $0.string("task_id") == task.id }, timestamp: "started_at") }
    var current: Record? { attempts.first { $0.id == task.string("active_attempt_id") } }
    var activeContributors: [Record] { attempts.filter { $0.id != current?.id && $0.string("state") == "active" } }
    var links: [Record] { store.detailRecords("task_sessions",task:task).filter { $0.string("task_id") == task.id } }
    var contextLinks: [Record] {
        let currentLinks = RecordOrdering.newestFirst(links.filter { $0.bool("binding_current") }, timestamp: "updated_at")
        var seen = Set<String>()
        let activeSessions = Set(attempts.filter { $0.string("state") == "active" }.map { $0.string("session_id") })
        return currentLinks.filter { !activeSessions.contains($0.string("session_id")) && seen.insert($0.string("session_id")).inserted }
    }
    var previousAttempts: [Record] {
        let linked = Set(contextLinks.map { $0.string("session_id") })
        return attempts.filter { $0.id != current?.id && $0.string("state") != "active" && !linked.contains($0.string("session_id")) }
    }
    var historicalLinks: [Record] {
        let known = Set(attempts.map { $0.string("session_id") } + contextLinks.map { $0.string("session_id") })
        var seen = Set<String>()
        return RecordOrdering.newestFirst(links.filter { !$0.bool("binding_current") }, timestamp: "updated_at").filter { !known.contains($0.string("session_id")) && seen.insert($0.string("session_id")).inserted }
    }
    var body: some View {
        if !attempts.isEmpty || !links.isEmpty || task.bool("active_attention") {
            DetailSection(title: "Work on this ticket") {
                WorkHealthSummary(health:task.object("work_health"))
                DisclosureGroup("Communication availability") {
                    VStack(alignment: .leading, spacing: Spacing.control) {
                        Text(NativeCommunicationRoutes.summary).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        ForEach(NativeCommunicationRoutes.all) { route in
                            VStack(alignment: .leading, spacing: Spacing.hairline) {
                                Text("\(route.title) · \(route.statusLabel)").checklistFont(.microEmphasis)
                                Text(route.reason).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                            }
                        }
                    }.padding(.top, Spacing.row)
                }.checklistFont(.micro)

                if let current {
                    attemptRow(current)
                    Button("Recover stopped work…") { recoveryAttempt = current }.checklistFont(.micro).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    Text("Only recover after checking that the handler has stopped. A timeout does not prove it.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                ForEach(activeContributors) { contributor in
                    attemptRow(contributor)
                    Button("Recover stopped contributor…") { recoveryAttempt = contributor }.checklistFont(.micro).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                }
                ForEach(contextLinks) { link in contextRow(link, historical: false) }
                if !previousAttempts.isEmpty {
                    DisclosureGroup("Previous work · \(previousAttempts.count)") {
                        VStack(alignment: .leading, spacing: Spacing.control) { ForEach(previousAttempts) { attempt in attemptRow(attempt) } }.padding(.top, Spacing.row)
                    }.checklistFont(.micro)
                }
                if !historicalLinks.isEmpty {
                    DisclosureGroup("Earlier context links · \(historicalLinks.count)") {
                        VStack(alignment: .leading, spacing: Spacing.control) { ForEach(historicalLinks) { link in contextRow(link, historical: true) } }.padding(.top, Spacing.row)
                    }.checklistFont(.micro)
                }
            }.sheet(item: $recoveryAttempt) { attempt in TaskRecoverySheet(task: task, attempt: attempt).environmentObject(store) }
                .sheet(item: $handoffProvider) { provider in TaskHandoffSheet(task: task, provider: provider).environmentObject(store) }
                .checklistConfirmation($accessConfirmation)
        }
    }
    @ViewBuilder func contextRow(_ link: Record, historical: Bool) -> some View {
        let session = store.detailRecords("sessions",task:task).first { $0.id == link.string("session_id") }
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(sessionLabel(link, session)).checklistFont(.calloutStrong)
            Text(historical ? "Historical context link · no current access implied" : "Connected for context · no work claim").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Text("\(session?.string("provider").capitalized ?? "Agent") · Linked \(relativeTime(link.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            let earlier = attempts.filter { $0.string("session_id") == link.string("session_id") }
            if !earlier.isEmpty {
                DisclosureGroup("Work history on this ticket") { VStack(spacing: Spacing.small) { ForEach(earlier) { attempt in attemptRow(attempt) } }.padding(.top, Spacing.small) }.checklistFont(.micro)
            }
            sessionActions(session)
            technicalIdentity(link, session: session, isAttempt: false)
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
    @ViewBuilder func attemptRow(_ attempt: Record) -> some View {
        let session = store.detailRecords("sessions",task:task).first { $0.id == attempt.string("session_id") }
        VStack(alignment: .leading, spacing: Spacing.compact) {
            AccessibleHStack {
                Text(sessionLabel(attempt, session)).checklistFont(.calloutStrong)
                Spacer()
                Text(attempt.id == task.string("active_attempt_id") ? "Current handler" : attempt.string("state") == "active" ? "Current contributor" : GlossaryText.humanize(attempt.string("state")).capitalized).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Text("\(session?.string("provider").capitalized ?? (attempt.string("session_id") == "human" ? "You" : "Agent")) · \(attempt.string("phase", fallback: "implementation").capitalized)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if attempt.string("state") == "active", !attempt.string("waiting_for_resource").isEmpty {
                // CL-47: a resource wait is shown instead of a quiet claim.
                Label("Waiting for \(attempt.string("waiting_for_resource")) since \(relativeTime(attempt.string("waiting_since")))", systemImage: "hourglass").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if !attempt.string("last_checkpoint").isEmpty {
                Text("Last checkpoint \(relativeTime(attempt.string("last_checkpoint")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else {
                Text("Started \(relativeTime(attempt.string("started_at"))) · No checkpoint yet").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            if !attempt.string("progress").isEmpty { Text(attempt.string("progress")).checklistFont(.callout).textSelection(.enabled) }
            if !attempt.string("final_report").isEmpty {
                // CL-46: the agent's own final report on this attempt; agent text, never an owner note.
                DisclosureGroup("Final report from this agent") {
                    Text(attempt.string("final_report")).checklistFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Spacing.tight)
                }.checklistFont(.micro)
            }
            if !attempt.string("continuation").isEmpty {
                VStack(alignment: .leading, spacing: Spacing.tight) { Text("Continuation").checklistFont(.microEmphasis); Text(attempt.string("continuation")).checklistFont(.callout).textSelection(.enabled) }
            }
            if !attempt.string("reason", fallback: attempt.string("recovery_reason")).isEmpty { Text("Disposition: \(attempt.string("reason", fallback: attempt.string("recovery_reason")))").checklistFont(.micro).textSelection(.enabled) }
            if let session { Text("Session: \(GlossaryText.humanize(session.string("state", fallback: "Unknown")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            sessionActions(session)

            technicalIdentity(attempt, session: session, isAttempt: true)
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
    @ViewBuilder func sessionActions(_ session: Record?) -> some View {
        if let session {
            let provider = HandoffProvider(id: session.string("provider").lowercased())
            if provider.isAvailable {
                AccessibleHStack {
                    if let bundleID = provider.bundleID, let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Button("Open \(provider.name) app") {
                            NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                                if let error { Task { @MainActor in store.error = PlainError.text(error) } }
                            }
                        }
                    }
                    Button("Prepare continuation…") { handoffProvider = provider }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                }.checklistFont(.micro)
                Text("An exact conversation link is unavailable. Open the provider app to find this session, or prepare this ticket for a new thread.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if let reason = provider.unavailabilityReason {
                Text(reason).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            if session.bool("owner_revoked") {
                Text("Disconnected by you · reconnect refused until Allow again").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if session.bool("owner_reconnect_allowed") {
                Text("Allowed again · waiting for this conversation to reconnect").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            if !session.strings("owner_disconnect_pending_attempt_ids").isEmpty {
                Text("Retained claims need stopped-work recovery before Allow again. Reservations stay protected.").checklistFont(.micro).foregroundStyle(.orange)
            }
            if let action = ConversationAccessAction.available(for:session) {
                Button(action.label) {
                    accessConfirmation = action.confirmation(session) {
                        store.run(action.method,action.parameters(session,task:task),success:action.success)
                    }
                }.checklistFont(.micro).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
        }
    }
    func technicalIdentity(_ record: Record, session: Record?, isAttempt: Bool) -> some View {
        TechnicalDetails([("Session", record.string("session_id")), (isAttempt ? "Attempt" : "Context link", record.id),
                          ("Parent attempt", record.string("parent_attempt_id")),
                          ("Recovery file observations", record.strings("file_state_refs").joined(separator: "; ")),
                          ("Installation", session?.string("installation") ?? "")])
    }
    func sessionLabel(_ record: Record, _ session: Record?) -> String {
        if record.string("session_id") == "human" { return "You" }
        if let name = ConversationName.readable(session: session, actorDisplay: record.string("actor_display")) { return name }
        return "Work session · " + String(record.string("session_id").prefix(8))
    }
}

struct TaskRecoverySheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let task: Record
    let attempt: Record
    @State private var reason = ""
    @State private var observation = ""
    @State private var fileState = ""
    @State private var verifiedStopped = false
    @State private var confirmedSourceExecutions: [String: String] = [:]
    var unfinishedSourceExecutions: [Record] {
        store.detailRecords("source_executions",task:task).filter { $0.string("project_id") == task.string("project_id") && $0.string("task_id") == task.id && $0.string("attempt_id") == attempt.id && WorkActionProjection.needsSourceStopConfirmation($0) }
    }
    func executionIdentity(_ execution: Record) -> String { WorkActionProjection.sourceObservationIdentity(execution) }
    func isSourceExecutionConfirmed(_ execution: Record) -> Bool { confirmedSourceExecutions[execution.id] == executionIdentity(execution) }
    var allSourceExecutionsConfirmed: Bool { unfinishedSourceExecutions.allSatisfy(isSourceExecutionConfirmed) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Recover stopped work").checklistFont(.sheetTitle)
            Text("\(task.string("key")) · \(task.string("title"))").checklistFont(.bodyStrong).lineLimit(2)
            Text(attempt.string("parent_attempt_id").isEmpty ? "Check the actual handler and reserved files first. Checklist will revoke this claim and mark the ticket blocked so its next step can be decided. It will not stop a running agent or infer completion." : "Check this exact contributor and its reserved files first. Checklist will revoke its stopped claim; the parent handler must still check the work. This action does not stop a running agent or infer completion.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            TextField("Why does this work need recovery?", text: $reason).textFieldStyle(.roundedBorder)
            TextField("How did you verify that this exact handler stopped?", text: $observation).textFieldStyle(.roundedBorder)
            TextField("Where did you inspect the reserved files, and what state remains?", text: $fileState).textFieldStyle(.roundedBorder)
            Toggle("I verified this handler is stopped", isOn: $verifiedStopped).toggleStyle(.checkbox)
            if !unfinishedSourceExecutions.isEmpty {
                Text("Source checks retain this attempt's reservations").checklistFont(.captionStrong)
                Text("Verify each exact external process and its files before confirming it stopped. A failed or stale result can still have an unverified process stop. Recovery records your observations and does not terminate a process.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                if unfinishedSourceExecutions.contains(where: { confirmedSourceExecutions[$0.id] != nil && !isSourceExecutionConfirmed($0) }) {
                    Text("A source check changed after your earlier observation. Confirm its current state again.").checklistFont(.micro).foregroundStyle(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.row) {
                        ForEach(unfinishedSourceExecutions) { execution in
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("\(execution.string("tool")) · \(GlossaryText.title(execution.string("state")))").checklistFont(.microEmphasis)
                                TechnicalDetails([("Execution", execution.id), ("Submission manifest", execution.string("manifest_id")), ("Input SHA-256", execution.string("input_sha256"))])
                                Toggle("I verified this exact source check process stopped", isOn: Binding(get: { isSourceExecutionConfirmed(execution) }, set: { value in if value { confirmedSourceExecutions[execution.id] = executionIdentity(execution) } else { confirmedSourceExecutions.removeValue(forKey: execution.id) } })).toggleStyle(.checkbox).checklistFont(.micro)
                            }.padding(Spacing.small).frame(maxWidth: .infinity, alignment: .leading).checklistCard()
                        }
                    }
                }.frame(maxHeight: 230)
            }
            AccessibleHStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Revoke stopped claim") {
                    store.run("work_recover", ["project_id": task.string("project_id"), "task_id": task.id, "attempt_id": attempt.id, "expected_revision": task.integer("revision"), "action": "confirm_stopped_revoke", "reason": reason, "observation_refs": [observation], "file_state_refs": [fileState], "source_execution_ids": unfinishedSourceExecutions.filter(isSourceExecutionConfirmed).map(\.id), "expected_source_execution_revisions": Dictionary(uniqueKeysWithValues: unfinishedSourceExecutions.filter(isSourceExecutionConfirmed).map { ($0.id, $0.integer("revision")) })], success: attempt.string("parent_attempt_id").isEmpty ? "Stopped claim revoked; ticket is blocked for its next step" : "Stopped contributor claim revoked; parent still owns its work", completion: { _ in dismiss() })
                }.buttonStyle(.checklistProminent).checklistDisabled([(!verifiedStopped, "Confirm that the work stopped first."), (!allSourceExecutionsConfirmed, "Confirm that every source check stopped first."), (reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."), (observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write what you observed first."), (fileState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Describe the state of the reserved files first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
        }.padding(Spacing.page).checklistSheet(width: 550)
    }
}

/// The same service projection is shown for claimed work and unclaimed Triage members.
struct WorkHealthSummary: View {
    let health: [String: Any]
    var body: some View {
        let state = health["state"] as? String ?? "pending_check"
        let target = health["current_target"] as? [String:Any] ?? [:]
        VStack(alignment:.leading, spacing:Spacing.small) {
            Label("Work health · " + GlossaryText.humanize(state), systemImage: health["attention"] as? Bool == true ? "exclamationmark.circle" : "heart.text.square").checklistFont(.microEmphasis)
            if state != "inactive", target["kind"] as? String != "attempt" { Text("Missing ticket handler · " + (target["kind"] as? String == "orchestration" ? "Checking the actual phase orchestrator" : (target["reason"] as? String ?? "No actual phase orchestrator"))).checklistFont(.micro) }
            if let progress = health["last_progress_at"] as? String { Text("Last substantive progress: " + relativeTime(progress)).checklistFont(.micro) }
            if let next = health["next_check_at"] as? String, state != "paused" { Text("Next check: " + next).checklistFont(.micro) }
            Text("Session: " + (health["session_state"] as? String ?? "unknown") + " · Last seen: " + (health["last_seen"] as? String ?? "unknown")).checklistFont(.micro)
            ForEach(Array((health["known_waits"] as? [[String:Any]] ?? []).enumerated()), id: \.offset) { _, wait in Text("Known wait · " + (wait["kind"] as? String ?? "") + ": " + (wait["reason"] as? String ?? "Open prerequisite")).checklistFont(.micro) }
            if let jobs = health["running_jobs"] as? [[String:Any]], !jobs.isEmpty { Text("Running source checks: \(jobs.count) · A running job does not prove substantive progress").checklistFont(.micro) }
            if let delivery = health["delivery_state"] as? String { Text("Health request: " + GlossaryText.humanize(delivery) + " · A queued or acknowledged note is not a response").checklistFont(.micro) }
            if health["response_without_new_progress"] as? Bool == true { Text("Handler replied; substantive progress is still overdue").checklistFont(.micro).foregroundStyle(.orange) }
            Text("Native wake unavailable · MCP pickup only").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }.frame(maxWidth:.infinity, alignment:.leading)
    }
}
