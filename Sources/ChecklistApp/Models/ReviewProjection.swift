import Foundation

enum WorkActionProjection {
    static func needsSourceStopConfirmation(_ execution: Record) -> Bool {
        ["queued", "running", "interrupted"].contains(execution.string("state")) || execution.bool("process_stop_unverified")
    }
    static func sourceObservationIdentity(_ execution: Record) -> String {
        [execution.id, String(execution.integer("revision")), execution.string("state"), execution.string("started_at"), String(execution.bool("process_stop_unverified"))].joined(separator: ":")
    }
    static func canStartHumanWork(_ task: Record) -> Bool {
        task.bool("pickup_eligible") && task.values["pending_policy_revision"] == nil
    }
    static func humanPickupBlocker(_ task: Record) -> String {
        if task.values["pending_policy_revision"] != nil { return "The review rules changed. Confirm the new rules before starting this ticket." }
        if !task.records("prerequisite_blockers").isEmpty { return "Finish the required prerequisites before starting this ticket." }
        if !task.string("active_verification_request_id").isEmpty { return "Finish the current human approval before starting this ticket." }
        return "This ticket is not currently eligible to start. Check its requirements and current state."
    }
}

/// Presentation of the exact submitted target. A passing historical verdict is never
/// treated as authority for a replacement manifest or changed acceptance criteria.
struct ReviewProjection {
    let task: Record
    let project: Record?
    let manifests: [Record]
    let requests: [Record]
    let reviews: [Record]
    let findings: [Record]
    let resolutions: [Record]
    let attempts: [Record]
    let attachments: [Record]
    let humanRequests: [Record]
    let messages: [Record]
    let executions: [Record]

    init(task: Record, project: Record?, data: [String: Any]) {
        self.task = task; self.project = project
        func scoped(_ name: String) -> [Record] {
            (data[name] as? [[String: Any]] ?? []).map(Record.init).filter {
                $0.string("task_id") == task.id && $0.string("project_id") == task.string("project_id")
            }
        }
        manifests = scoped("manifests"); requests = scoped("review_requests")
        reviews = scoped("reviews"); findings = scoped("findings")
        resolutions = scoped("finding_resolutions"); attempts = scoped("attempts")
        attachments = scoped("attachments"); humanRequests = scoped("requests")
        messages = scoped("messages"); executions = scoped("source_executions")
    }

    var current: Record? { manifests.first { $0.id == task.string("current_manifest_id") } }
    var activeAttempt: Record? { attempts.first { $0.id == task.string("active_attempt_id") && $0.string("state") == "active" } }
    var openFindings: [Record] { findings.filter { $0.string("state") == "open" } }
    /// Advice findings stay visible but never block completion (CL-42).
    var openBlockingFindings: [Record] { openFindings.filter { $0.string("severity") != "advice" } }
    /// Reject verdicts of one gate across every submission of this ticket (CL-43).
    func failedRounds(for gate: String) -> Int { reviews.filter { $0.string("gate") == gate && $0.string("verdict") == "reject" }.count }
    /// Causes that returned for the second time: three or more findings share one cause (CL-43).
    var repeatedCauses: [[Record]] {
        let groups = Dictionary(grouping: findings) { $0.string("cause_id", fallback: $0.id) }
        return groups.keys.sorted().compactMap { groups[$0]!.count >= 3 ? groups[$0]! : nil }
    }
    static func verdictLabel(_ verdict: String) -> String {
        switch verdict {
        case "pass": return "Passed"
        case "reject": return "Needs changes"
        case "blocked": return "Blocked"
        case "evidence_missing": return "More evidence requested"
        case "not_run": return "Check not run"
        default: return GlossaryText.title(verdict)
        }
    }
    static func failureCauseLabel(_ check: Record) -> String? {
        switch check.string("failure_cause") {
        case "defect": return "Caused by this ticket"
        case "environment": return "Caused by the environment, not this ticket"
        case "other_ticket": return "Caused by \(check.string("cause_task_key", fallback: "another ticket")), not this ticket"
        default: return nil
        }
    }
    var pendingHumanRequest: Record? {
        TicketNextAction.blockingRequest(humanRequests)
    }
    var requiredGates: [String] {
        guard let current else { return project?.object("policy")["required_gates"] as? [String] ?? [] }
        return gates(for: current)
    }
    func gates(for manifest: Record) -> [String] {
        if task.string("completion_policy_manifest_id") == manifest.id,
           let gates = task.object("completion_policy_snapshot")["required_gates"] as? [String] { return gates }
        if let gates = manifest.values["required_gates"] as? [String] { return gates }
        return manifest.object("policy_snapshot")["required_gates"] as? [String] ?? []
    }
    func request(for gate: String, manifest: Record) -> Record? {
        let matches = requests.filter { $0.string("manifest_id") == manifest.id && $0.string("gate") == gate }
        let superseded = Set(matches.map { $0.string("supersedes_request_id") })
        return matches.last { !superseded.contains($0.id) && $0.string("state") != "superseded" } ?? matches.last
    }
    func verdict(for request: Record) -> Record? { reviews.first { $0.id == request.string("latest_verdict_id") && $0.string("manifest_id") == request.string("manifest_id") && $0.string("review_request_id") == request.id } }
    func reviewer(for request: Record) -> Record? { attempts.last { $0.string("review_request_id") == request.id && $0.string("state") == "active" } }
    func artifactRefs(for manifest: Record) -> [Record] { (manifest.object("evidence")["artifact_refs"] as? [[String: Any]] ?? []).map(Record.init) }
    func artifact(_ ref: Record) -> Record? { attachments.first { $0.id == ref.string("artifact_id") } }
    /// Service blocker codes in plain words; the service's own message stays in its records (CL-55).
    static func plainBlocker(_ code: String) -> String? {
        switch code {
        case "EVIDENCE_STALE", "SOURCE_CHANGED": return "The project files changed after this submission. Submit the work again."
        case "REVIEW_TARGET_MISMATCH": return "The submitted evidence belongs to another submission. Submit the work again."
        case "SOURCE_CAPTURE_INCOMPLETE": return "The submitted copy of the source is incomplete. Submit the work again."
        default: return nil
        }
    }
    func targetWarnings(_ manifest: Record) -> [String] {
        var result: [String] = []
        if manifest.id != task.string("current_manifest_id") { result.append("Earlier submission. Its verdicts cannot complete the current ticket.") }
        if manifest.integer("acceptance_revision") != task.integer("acceptance_revision") { result.append("The acceptance criteria changed after this submission. Submit the work again.") }
        if manifest.id == task.string("current_manifest_id") {
            for blocker in task.object("completion_eligibility")["blockers"] as? [[String: Any]] ?? [] {
                if let plain = Self.plainBlocker(blocker["code"] as? String ?? "") { result.append(plain) }
            }
        }
        for ref in artifactRefs(for: manifest) {
            guard let file = artifact(ref) else { result.append("A submitted file is missing from this ticket."); continue }
            if file.string("availability") != "available" || file.string("sha256") != ref.string("sha256") || file.string("mode") != "managed" {
                result.append("\(file.string("name", fallback: "A submitted file")) is missing or changed since it was submitted.")
            }
        }
        return result
    }
    var completionBlockers: [String] {
        var result: [String] = []
        result.append(contentsOf: task.records("prerequisite_blockers").map { $0.string("reason") }.filter { !$0.isEmpty })
        if task.integer("pending_policy_revision", fallback: 0) > 0 { result.append("Confirm the changed review rules before continuing.") }
        if task.bool("archived") || task.bool("trashed") { result.append("Restore the ticket before continuing.") }
        if activeAttempt != nil { result.append("Finish or release the current work attempt.") }
        if !task.string("active_verification_request_id").isEmpty { result.append("Finish the current owner check.") }
        if pendingHumanRequest != nil { result.append("Answer the open request that blocks this ticket.") }
        if messages.contains(where: { $0.bool("requires_action") && !$0.bool("addressed") }) { result.append("Address the outstanding owner direction.") }
        guard let current else { result.append("Submit the work for review."); return result }
        result.append(contentsOf: targetWarnings(current))
        if !openBlockingFindings.isEmpty { result.append("\(openBlockingFindings.count) open finding\(openBlockingFindings.count == 1 ? " needs" : "s need") a fix or an owner waiver.") }
        let hold = task.object("release_hold")
        if !hold.isEmpty { result.append("Accepted and held for release set \(hold["release_set"] as? String ?? ""). It completes with that set.") }
        for gate in gates(for: current) {
            guard let request = request(for: gate, manifest: current) else { result.append("\(Self.gateName(gate)) has no review request for the current submission."); continue }
            if request.string("state") != "pass" || verdict(for: request)?.string("verdict") != "pass" { result.append("\(Self.gateName(gate)) has not passed for the current submission.") }
        }
        // A service projection includes disk/source/build validation which the UI cannot prove.
        let eligibility = task.object("completion_eligibility")
        if eligibility.isEmpty { result.append("The service has not yet checked whether this ticket can complete.") }
        else if (eligibility["task_revision"] as? NSNumber)?.intValue != task.integer("revision") || eligibility["manifest_id"] as? String != task.string("current_manifest_id") {
            result.append("Refresh the ticket: its completion check is out of date.")
        }
        // Coded service blockers use the same plain sentences as the submission warnings.
        let serverBlockers = (eligibility["blockers"] as? [String] ?? [])
            + (eligibility["blockers"] as? [[String: Any]] ?? []).compactMap { Self.plainBlocker($0["code"] as? String ?? "") ?? $0["message"] as? String }
        result.append(contentsOf: serverBlockers)
        if eligibility["eligible"] as? Bool == false && serverBlockers.isEmpty { result.append("The service has not yet checked whether this ticket can complete.") }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
    var eligibleReviewRequest: Record? {
        guard task.values["prerequisites_satisfied"] as? Bool != false, !task.bool("archived"), !task.bool("trashed"),
              task.string("disposition") != "superseded", ["review", "queued", "blocked"].contains(task.string("status_category")),
              task.integer("pending_policy_revision", fallback: 0) == 0, activeAttempt == nil, task.string("active_verification_request_id").isEmpty,
              pendingHumanRequest == nil, let current, targetWarnings(current).isEmpty else { return nil }
        return gates(for: current).compactMap { request(for: $0, manifest: current) }.first {
            $0.string("state") == "queued" && $0.string("gate") != "human_approval"
        }
    }
    var canComplete: Bool {
        let eligibility = Record(values: task.object("completion_eligibility"))
        return !["done", "canceled"].contains(task.string("status_category")) && current != nil && completionBlockers.isEmpty &&
            eligibility.bool("eligible") && eligibility.integer("task_revision", fallback: 0) == task.integer("revision") && eligibility.string("manifest_id") == task.string("current_manifest_id")
    }
    static func gateName(_ gate: String) -> String {
        switch gate {
        case "review": return "Independent review"
        case "human_approval": return "Owner approval"
        case "installed_build_verified": return "Installed build verification"
        default: return GlossaryText.humanize(gate).capitalized
        }
    }
    static func readableJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: bytes, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}


struct ReviewFormDraft: Codable {
    var verdict = "pass"
    var summary = ""
    var inspected = false
    var findingText = ""
    var dispositionReasons: [String: String] = [:]
    var resolved: [String] = []

    static func load(attemptID: String) -> ReviewFormDraft? {
        guard let bytes = UserDefaults.standard.data(forKey: "reviewDraft:" + attemptID) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
    func save(attemptID: String) {
        if let bytes = try? JSONEncoder().encode(self) { UserDefaults.standard.set(bytes, forKey: "reviewDraft:" + attemptID) }
    }
    static func remove(attemptID: String) { UserDefaults.standard.removeObject(forKey: "reviewDraft:" + attemptID) }
}
