#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checklist-review-projection.XXXXXX")"
trap 'rm -rf "$REVIEW_CHECK_DIR"' EXIT
cat > "$REVIEW_CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

var checked = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checked += 1
}
let pid = "project", tid = "ticket", mid = "manifest"
let target: [String: Any] = ["id": mid, "project_id": pid, "task_id": tid, "attempt_id": "implementation", "author_session_id": "worker", "acceptance_revision": 2, "required_gates": ["review"], "evidence": ["artifact_refs": [["artifact_id": "original", "sha256": "captured"]]]]
let original: [String: Any] = ["id": "original", "project_id": pid, "task_id": tid, "sha256": "captured", "mode": "managed", "availability": "available"]
let request: [String: Any] = ["id": "request", "project_id": pid, "task_id": tid, "manifest_id": mid, "gate": "review", "state": "queued"]
var task: [String: Any] = ["id": tid, "project_id": pid, "current_manifest_id": mid, "revision": 4, "acceptance_revision": 2, "status_category": "review", "readiness": "ready", "completion_eligibility": ["eligible": true, "task_revision": 4, "manifest_id": mid, "blockers": []]]
var data: [String: Any] = ["manifests": [target], "attachments": [original], "review_requests": [request]]
func projection(_ taskOverride: [String: Any]? = nil, _ dataOverride: [String: Any]? = nil) -> ReviewProjection {
    ReviewProjection(task: Record(values: taskOverride ?? task), project: nil, data: dataOverride ?? data)
}
if CommandLine.arguments.contains("--agent-preparation-only") {
    var human = target;human["author_session_id"] = "human"
    var input = data;input["manifests"] = [human]
    check(projection(nil,input).eligibleReviewRequest?.id == "request", "A separate eligible agent may prepare review of a human-authored target")
    var installed = target;installed["required_gates"] = ["installed_build_verified"]
    var installedRequest = request;installedRequest["gate"] = "installed_build_verified"
    input = data;input["manifests"] = [installed];input["review_requests"] = [installedRequest]
    check(projection(nil,input).eligibleReviewRequest?.string("gate") == "installed_build_verified", "Installed-build verification uses a separate eligible reviewer")
    var approval = target;approval["required_gates"] = ["human_approval"]
    var approvalRequest = request;approvalRequest["gate"] = "human_approval"
    input = data;input["manifests"] = [approval];input["review_requests"] = [approvalRequest]
    check(projection(nil,input).eligibleReviewRequest == nil, "Human approval cannot prepare an agent review")
    print("Passed \(checked) newly affected review preparation checks")
    exit(0)
}
check(!projection().canComplete, "Queued review cannot complete")
check(projection().eligibleReviewRequest?.id == "request", "Exact queued review is available")
var humanTarget = target; humanTarget["author_session_id"] = "human"
var variation = data; variation["manifests"] = [humanTarget]
check(projection(nil, variation).eligibleReviewRequest?.id == "request", "Owner may prepare a separate independent reviewer for a human-authored target")
var activeTask = task; activeTask["active_attempt_id"] = "reviewer"
variation = data; variation["attempts"] = [["id": "reviewer", "project_id": pid, "task_id": tid, "phase": "review", "state": "active"]]
check(projection(activeTask, variation).eligibleReviewRequest == nil, "An active reviewer excludes another claim")
var passed = request; passed["state"] = "pass"; passed["latest_verdict_id"] = "verdict"
let verdict: [String: Any] = ["id": "verdict", "project_id": pid, "task_id": tid, "manifest_id": mid, "review_request_id": "request", "verdict": "pass"]
data["review_requests"] = [passed]; data["reviews"] = [verdict]
check(projection().canComplete, "Matching pass plus exact authoritative eligibility permits completion")
var changedTask = task; changedTask["acceptance_revision"] = 3
check(!projection(changedTask).canComplete, "Acceptance change invalidates prior pass")
variation = data; variation["attachments"] = []
check(!projection(nil, variation).canComplete, "Missing original blocks completion")
var replacedOriginal = original; replacedOriginal["sha256"] = "new bytes"
variation = data; variation["attachments"] = [replacedOriginal]
check(!projection(nil, variation).canComplete, "Replacement original cannot inherit approval")
let oldFinding: [String: Any] = ["id": "stable-finding", "project_id": pid, "task_id": tid, "first_manifest_id": "prior", "gate": "review", "state": "open"]
variation = data; variation["findings"] = [oldFinding]
check(!projection(nil, variation).canComplete, "Open finding on prior target remains blocking")
var waived = oldFinding; waived["state"] = "waived"; variation["findings"] = [waived]
check(projection(nil, variation).canComplete, "Explicit waiver is a disposition, with other gates retained")
var blocked = request; blocked["id"] = "new-round"; blocked["state"] = "blocked"; blocked["supersedes_request_id"] = "request"
variation = data; variation["review_requests"] = [passed, blocked]
check(!projection(nil, variation).canComplete, "Superseding blocked review cannot reuse older pass")
variation = data; variation["requests"] = [["id": "question", "project_id": pid, "task_id": tid, "state": "pending", "blocking": true]]
check(!projection(nil, variation).canComplete, "Pending blocking human request prevents completion")
variation = data; variation["messages"] = [["id": "direction", "project_id": pid, "task_id": tid, "requires_action": true, "addressed": false]]
check(!projection(nil, variation).canComplete, "Acknowledgment cannot bypass unresolved owner direction")
changedTask = task; changedTask["completion_eligibility"] = ["eligible": false, "task_revision": 4, "manifest_id": mid, "blockers": [["code": "EVIDENCE_STALE", "message": "Captured source changed"]]]
check(!projection(changedTask).canComplete && projection(changedTask).completionBlockers.contains("Captured source changed"), "Actual service source failure is visible and blocks primary completion")
changedTask = task; changedTask["revision"] = 5
check(!projection(changedTask).canComplete, "Old eligibility cannot authorize changed ticket revision")
changedTask = task; changedTask.removeValue(forKey: "completion_eligibility")
check(!projection(changedTask).canComplete, "Absent authoritative eligibility cannot offer completion")
changedTask = task; changedTask["pending_policy_revision"] = 8
check(!projection(changedTask).canComplete && projection(changedTask).eligibleReviewRequest == nil, "Pending completion-policy reconciliation blocks protected actions")
changedTask = task; changedTask["completion_policy_manifest_id"] = mid; changedTask["completion_policy_snapshot"] = ["required_gates": ["review", "human_approval"]]
check(projection(changedTask).requiredGates == ["review", "human_approval"] && !projection(changedTask).canComplete, "Reconciled contract adds exact target gates without accepting missing verdicts")
changedTask = task; changedTask["current_manifest_id"] = "replacement"
check(!projection(changedTask).canComplete, "Historical target cannot complete replacement target")
for state in ["stale", "failed"] {
    let unresolved = Record(values: ["id": "check", "revision": 3, "state": state, "process_stop_unverified": true])
    check(WorkActionProjection.needsSourceStopConfirmation(unresolved), "A \(state) execution with an unverified stop remains visible for owner recovery")
    let stopped = Record(values: ["id": "check", "revision": 3, "state": state, "process_stop_unverified": false])
    check(!WorkActionProjection.needsSourceStopConfirmation(stopped), "A verified stopped \(state) execution needs no extra stop observation")
    check(WorkActionProjection.sourceObservationIdentity(unresolved) != WorkActionProjection.sourceObservationIdentity(stopped), "Stop flag changes invalidate the previous owner confirmation")
}
var ownerTask: [String: Any] = ["id": "human", "pickup_eligible": true]
check(WorkActionProjection.canStartHumanWork(Record(values: ownerTask)), "An authoritative eligible owner task can start")
ownerTask["pickup_eligible"] = false; ownerTask["prerequisite_blockers"] = [["task_id": "reopened"]]
check(!WorkActionProjection.canStartHumanWork(Record(values: ownerTask)) && WorkActionProjection.humanPickupBlocker(Record(values: ownerTask)).contains("prerequisites"), "A reopened required prerequisite disables owner pickup with an explanation")
ownerTask["pickup_eligible"] = true; ownerTask["pending_policy_revision"] = 9
check(!WorkActionProjection.canStartHumanWork(Record(values: ownerTask)), "Pending workflow reconciliation prevents an owner pickup action")
print("\(checked) review projection checks passed")
SWIFT
xcrun swiftc "$PROJECT_ROOT/Sources/ChecklistApp/Models/Record.swift" "$PROJECT_ROOT/Sources/ChecklistApp/Models/ReviewProjection.swift" "$REVIEW_CHECK_DIR/main.swift" -o "$REVIEW_CHECK_DIR/review-projection-check"
"$REVIEW_CHECK_DIR/review-projection-check" "$@"
