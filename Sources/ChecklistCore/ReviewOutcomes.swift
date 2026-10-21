import Foundation
import GRDB

/// Review outcomes and attempt records (Triage 3fd2303d): evidence_missing and not_run verdicts
/// (CL-41), advice findings (CL-42), repeated-cause warnings (CL-43), final reports (CL-46),
/// resource waits and failure causes (CL-47) and release-set holds (CL-45).
extension CommandRouter {
    static let reviewVerdicts: Set<String> = ["pass", "reject", "blocked", "evidence_missing", "not_run"]
    static let findingSeverities: Set<String> = ["blocking", "advice", "critical", "high", "normal", "low", "info", "blocker", "major", "minor"]
    static let checkFailureCauses: Set<String> = ["defect", "environment", "other_ticket"]
    static let finalReportLimit = 64_000
    /// Fields that belong to one attempt only: a new attempt made from it (handoff, delegation or
    /// takeover) never inherits its draft verdict, final report or resource wait.
    static let attemptOwnRecordKeys = ["draft_verdict", "final_report", "final_report_at", "final_report_origin", "final_report_author", "final_report_sha256", "waiting_for_resource", "waiting_since", "waiting_seconds"]
    /// An active attempt without a checkpoint for this long is quiet, unless it waits for a resource.
    static let quietCheckpointSeconds: TimeInterval = 30 * 60

    /// Only `advice` leaves completion open; every other severity, including older values, blocks it.
    static func findingBlocksCompletion(_ finding: JSON) -> Bool { finding["severity"] as? String != "advice" }

    /// `reason` (and `check` for not_run) for the two verdicts that are neither a pass nor a fail.
    /// They name a gap, not a defect, so they carry no findings, dispositions or release hold.
    func reviewOutcomeDetails(_ p: JSON, verdict: String) throws -> JSON {
        guard ["evidence_missing", "not_run"].contains(verdict) else {
            guard p["reason"] == nil, p["check"] == nil else { throw CoreError("INVALID_INPUT", "reason and check belong to an evidence_missing or not_run verdict.") }
            return [:]
        }
        guard (p["findings"] as? [Any] ?? []).isEmpty, (p["finding_resolutions"] as? [Any] ?? []).isEmpty else {
            throw CoreError("INVALID_INPUT", "An \(verdict) verdict records no findings or dispositions. Use reject for a defect.")
        }
        var details: JSON = ["reason": try text(p, "reason", max: 8000)]
        if verdict == "not_run" { details["check"] = try text(p, "check", max: 200) }
        else if p["check"] != nil { throw CoreError("INVALID_INPUT", "check names the check that did not run; use it only with not_run.") }
        return details
    }

    /// Review checks are stored as reported. A failed check may name its cause: a defect in this
    /// ticket, the environment, or another named ticket in this project (CL-47).
    func normalizedReviewChecks(_ db: Database, _ p: JSON, task: JSON) throws -> [Any] {
        let checks = p["checks"] as? [Any] ?? []
        guard checks.count <= 100 else { throw CoreError("INVALID_INPUT", "Report at most 100 checks.") }
        let pid = task["project_id"] as! String
        return try checks.map { item -> Any in
            guard var check = item as? JSON else { return item }
            if let cause = check["failure_cause"] {
                guard let cause = cause as? String, Self.checkFailureCauses.contains(cause) else { throw CoreError("INVALID_INPUT", "failure_cause is defect, environment or other_ticket.") }
                guard ["fail", "failed"].contains(check["result"] as? String ?? "") else { throw CoreError("INVALID_INPUT", "Only a failed check names a failure cause.") }
                if cause == "other_ticket" {
                    let other = try scoped(db, try text(check, "cause_task_id", max: 200), pid, type: "task")
                    guard other["id"] as? String != task["id"] as? String else { throw CoreError("INVALID_INPUT", "Use defect for a failure caused by this ticket.") }
                    check["cause_task_key"] = other["key"] ?? NSNull();check["cause_task_title"] = other["title"] ?? ""
                } else if check["cause_task_id"] != nil { throw CoreError("INVALID_INPUT", "cause_task_id belongs to failure_cause other_ticket.") }
            } else if check["cause_task_id"] != nil { throw CoreError("INVALID_INPUT", "cause_task_id needs failure_cause other_ticket.") }
            return check
        }
    }

    /// `release_set` and `hold_reason` on a passing verdict (CL-45).
    func releaseHoldRequest(_ p: JSON, verdict: String) throws -> (set: String, reason: String)? {
        guard p["release_set"] != nil else {
            guard p["hold_reason"] == nil else { throw CoreError("INVALID_INPUT", "hold_reason needs release_set.") }
            return nil
        }
        guard verdict == "pass" else { throw CoreError("INVALID_INPUT", "Only a passing verdict can wait for a release set.") }
        return (try text(p, "release_set", max: 120), try text(p, "hold_reason", max: 4000))
    }

    /// The final report that an agent writes when it submits, releases or records a verdict (CL-46).
    /// It is agent text on the attempt and never owner provenance or a direction.
    func recordFinalReport(_ p: JSON, caller: Caller, attempt a: inout JSON) throws {
        guard p["final_report"] != nil else { return }
        guard !caller.isOwner else { throw CoreError("INVALID_INPUT", "A final report is an agent's report on its own attempt. Add an owner note instead.") }
        let report = try text(p, "final_report", max: Self.finalReportLimit)
        a["final_report"] = report; a["final_report_at"] = now(); a["final_report_origin"] = "agent"; a["final_report_author"] = caller.principal
        a["final_report_sha256"] = hash(Data(report.utf8))
    }

    /// A checkpoint names the shared resource it waits for, or ends an earlier wait (CL-47).
    func recordResourceWait(_ p: JSON, attempt a: inout JSON) throws {
        let formatter = ISO8601DateFormatter()
        if p["waiting_for_resource"] != nil {
            let resource = try text(p, "waiting_for_resource", max: 200)
            if a["waiting_for_resource"] as? String != resource {
                if let since = (a["waiting_since"] as? String).flatMap(formatter.date(from:)) { a["waiting_seconds"] = int(a, "waiting_seconds") + max(0, Int(Date().timeIntervalSince(since))) }
                a["waiting_for_resource"] = resource; a["waiting_since"] = now()
            }
        } else if let since = (a["waiting_since"] as? String).flatMap(formatter.date(from:)) {
            a["waiting_seconds"] = int(a, "waiting_seconds") + max(0, Int(Date().timeIntervalSince(since)))
            a.removeValue(forKey: "waiting_for_resource"); a.removeValue(forKey: "waiting_since")
        }
    }

    /// Checkpoint health of an active attempt. A resource wait is never quiet: time spent
    /// waiting does not count toward the quiet warning (CL-47).
    static func checkpointHealth(_ attempt: JSON, now current: Date = Date()) -> JSON? {
        guard attempt["state"] as? String == "active" else { return nil }
        let formatter = ISO8601DateFormatter()
        if let resource = attempt["waiting_for_resource"] as? String {
            return ["state": "waiting_for_resource", "resource": resource, "since": attempt["waiting_since"] ?? NSNull()]
        }
        guard let last = (attempt["last_checkpoint"] as? String ?? attempt["started_at"] as? String).flatMap(formatter.date(from:)) else { return ["state": "current"] }
        let quiet = max(0, Int(current.timeIntervalSince(last)))
        return quiet >= Int(quietCheckpointSeconds) ? ["state": "quiet", "quiet_seconds": quiet] : ["state": "current", "quiet_seconds": quiet]
    }

    /// Failed rounds per gate and repeated-cause warnings for one ticket (CL-43). A cause that
    /// returns for the second time (its third finding) warns the ticket and its coordinator. The
    /// warning is advice only; it changes no status, claim or verdict.
    func reviewSummary(_ db: Database, task: JSON) throws -> JSON {
        let reviews = try scopedTaskRows(db, type: "review", task: task)
        var gates: [String: JSON] = [:]
        for review in reviews {
            let gate = review["gate"] as? String ?? "review", verdict = review["verdict"] as? String ?? ""
            var row = gates[gate] ?? ["gate": gate, "failed_rounds": 0, "passes": 0, "blocked": 0, "evidence_missing": 0, "not_run": 0]
            switch verdict {
            case "reject": row["failed_rounds"] = int(row, "failed_rounds") + 1
            case "pass": row["passes"] = int(row, "passes") + 1
            case "blocked", "evidence_missing", "not_run": row[verdict] = int(row, verdict) + 1
            default: break
            }
            gates[gate] = row
        }
        return ["rounds": gates.keys.sorted().map { gates[$0]! }, "warnings": try reviewWarnings(db, task: task)]
    }

    func reviewWarnings(_ db: Database, task: JSON) throws -> [JSON] {
        let findings = try scopedTaskRows(db, type: "finding", task: task)
        var causes: [String: [JSON]] = [:]
        for finding in findings { causes[finding["cause_id"] as? String ?? finding["id"] as? String ?? "", default: []].append(finding) }
        return causes.keys.sorted().compactMap { cause -> JSON? in
            let group = causes[cause]!
            guard group.count >= 3 else { return nil }
            return ["kind": "repeated_finding", "task_id": task["id"]!, "task_key": task["key"] ?? NSNull(), "cause_id": cause, "occurrences": group.count,
                    "finding_ids": group.compactMap { $0["id"] as? String },
                    "message": "The same cause returned for the second time. Change the approach: split the ticket or write a new brief before another round."]
        }
    }

    /// CL-42: the finding's reviewer, the current reviewer of its gate, or the owner changes a
    /// finding between blocking and advice (or another severity). History keeps every change.
    func findingSeveritySet(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: true)
        var finding = try scoped(db, try text(p, "finding_id"), pid, type: "finding"); try revision(p, finding)
        let severity = try text(p, "severity", max: 40), reason = try text(p, "reason", max: 8000)
        guard Self.findingSeverities.contains(severity) else { throw CoreError("INVALID_INPUT", "Use blocking or advice (older severities count as blocking).") }
        guard finding["state"] as? String == "open" else { throw CoreError("FINDINGS_UNRESOLVED", "Only an open finding's severity can change.") }
        if !c.isOwner {
            let author = finding["author"] as? String
            let reviewing = try records(db, type: "attempt", project: pid).contains {
                $0["task_id"] as? String == finding["task_id"] as? String && $0["phase"] as? String == "review" && $0["state"] as? String == "active"
                    && $0["gate"] as? String == finding["gate"] as? String && $0["principal"] as? String == c.principal
            }
            guard author == c.principal || reviewing else { throw CoreError("FORBIDDEN", "Only the finding's reviewer, the current reviewer of its gate or the owner can change its severity.") }
        }
        let previous = finding["severity"] as? String ?? "normal"
        guard previous != severity else { return finding }
        var history = finding["severity_history"] as? [JSON] ?? []
        history.append(["from": previous, "to": severity, "reason": reason, "actor": c.principal, "actor_display": author(db, c), "origin": c.isOwner ? "human_ui" : "agent", "changed_at": now()])
        finding["severity"] = severity; finding["severity_history"] = history; finding = revised(finding)
        try save(db, finding, type: "finding")
        try event(db, caller: c, project: pid, entity: finding["task_id"] as? String, kind: "finding_severity_changed", data: ["finding_id": finding["id"]!, "from": previous, "to": severity])
        return finding
    }

    /// CL-45: completes every ticket held for one release set through its normal fresh gates.
    /// The set completes together or not at all; the refusal names each ticket that is not ready.
    func releaseSetComplete(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: true)
        let name = try text(p, "release_set", max: 120)
        let held = try records(db, type: "task", project: pid).filter { ($0["release_hold"] as? JSON)?["release_set"] as? String == name }
        guard !held.isEmpty else { throw CoreError("NOT_FOUND", "No ticket waits for release set \(name).") }
        if let expected = p["expected_task_revisions"] as? JSON {
            for task in held where expected[task["id"] as! String] != nil {
                guard int(expected, task["id"] as! String) == int(task, "revision") else { throw CoreError("REVISION_CONFLICT", "A held ticket changed. Read the release set again.", details: ["task_id": task["id"]!]) }
            }
        }
        let done = try status(db, pid, "done")
        guard done["category"] as? String == "done", !bool(done, "retired") else { throw CoreError("INVALID_TRANSITION", "Completion requires an available Done status in this project.") }
        var refusals: [JSON] = []
        for task in held {
            do {
                let hold = task["release_hold"] as? JSON ?? [:]
                guard task["current_manifest_id"] as? String == hold["manifest_id"] as? String else { throw CoreError("EVIDENCE_STALE", "The ticket has a new target since its accepted review.") }
                try requirePrerequisitesSatisfied(db, task: task)
                try requireCompletable(db, task: task, pid: pid, releasingHold: true)
            } catch let error as CoreError { refusals.append(["task_id": task["id"]!, "task_key": task["key"] ?? NSNull(), "code": error.code, "reason": error.message]) }
        }
        guard refusals.isEmpty else { throw CoreError("RELEASE_SET_NOT_READY", "Every ticket in the release set must pass its fresh completion checks; none was completed.", details: ["release_set": name, "not_ready": refusals]) }
        var completed: [JSON] = []
        for var task in held {
            task.removeValue(forKey: "release_hold"); task["status_id"] = done["id"]; task["completed_at"] = now(); task = revised(task)
            try save(db, task, type: "task"); try recordTicketStatusAction(db, task: task, caller: c)
            try event(db, caller: c, project: pid, entity: task["id"] as? String, kind: "task_completed", data: ["origin": "release_set", "release_set": name])
            completed.append(try taskProjection(db, task))
        }
        try event(db, caller: c, project: pid, entity: nil, kind: "release_set_completed", data: ["release_set": name, "task_ids": held.compactMap { $0["id"] as? String }])
        return ["release_set": name, "completed": completed]
    }
}
