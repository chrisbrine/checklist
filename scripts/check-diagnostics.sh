#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAGNOSTICS_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checklist-diagnostics.XXXXXX")"
trap 'rm -rf "$DIAGNOSTICS_CHECK_DIR"' EXIT
cat > "$DIAGNOSTICS_CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

var checked = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checked += 1
}
let date = Date(timeIntervalSince1970: 1_792_272_000)
let privateHomeFixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("SyntheticPrivateProject").path
let secrets = ["Private note body and user answer", "FILE-CONTENT-DO-NOT-EXPORT", privateHomeFixture, "secret-claim-token", "secret-session-id", "/tmp/private-native.sock", "secret-native-endpoint", "private://reusable-route"]
let metadata: [String: Any] = ["build_id": "0123456789abcdef", "source_root": secrets[2], "toolchain": secrets[2], "token": secrets[3], "session_id": secrets[4]]
let summary: [String: Any] = ["service": ["version": "0.1.0", "state": "responsive", "endpoint": secrets[5]], "record_counts": ["task": 5, "message": 7, "other": 2, secrets[2]: 99, "project": true, "attachment": -1, "session": 1.5], "notes": [secrets[0]], "content": secrets[1], "credential": secrets[3], "session_id": secrets[4], "route": secrets[7]]
let recorder = DiagnosticsRecorder()
recorder.record("FILE_ACCESS_REQUIRED: \(secrets[2]) \(secrets[0])", at: date)
recorder.record("Checklist service: OUTCOME_UNKNOWN: \(secrets[3]) \(secrets[4])", at: date)
recorder.record("\(secrets[7]): \(secrets[6])", at: date)
recorder.record(nil, at: date)
let report = DiagnosticsExport.report(buildMetadata: metadata, appVersion: "1.2.3", bundleVersion: "25", serviceSummary: summary, recentErrors: recorder.snapshot(), at: date, operatingSystem: .init(majorVersion: 26, minorVersion: 5, patchVersion: 0))
let bytes = try DiagnosticsExport.encoded(report)
let output = String(decoding: bytes, as: UTF8.self)
for secret in secrets { check(!output.contains(secret), "Diagnostics must exclude private notes, file content, paths, credentials, sessions and routes") }
check(report.versions.buildID == "0123456789abcdef" && report.versions.app == "1.2.3" && report.versions.bundle == "25", "Permitted version/build identity must be retained")
check(report.service.state == "responsive" && report.service.countsAvailable && report.recordCounts["task"] == 5 && report.recordCounts["message"] == 7, "Responsive service aggregate counts must remain useful")
check(report.recordCounts["project"] == nil && report.recordCounts["attachment"] == nil && report.recordCounts["session"] == nil && report.recordCounts[secrets[2]] == nil, "Malformed counts and dynamic record labels must be excluded")
check(report.recentErrors.map(\.code) == ["FILE_ACCESS_REQUIRED", "OUTCOME_UNKNOWN", "OTHER_ERROR"], "Only known error codes survive; error descriptions never do")
check(report.errorHistoryScope == "owner_app_current_run", "The exported error history must state its actual bounded scope")
let poisoned = DiagnosticsExport.report(buildMetadata: ["build_id": secrets[3]], appVersion: secrets[2], bundleVersion: secrets[4], serviceSummary: ["service": ["version": secrets[7], "state": secrets[6]], "record_counts": ["task": 5]], recentErrors: [DiagnosticErrorRecord(code: secrets[3], recordedAt: date)], at: date)
let poisonedText = String(decoding: try DiagnosticsExport.encoded(poisoned), as: UTF8.self)
for secret in secrets { check(!poisonedText.contains(secret), "Even permitted fields must reject private-looking untrusted values") }
check(poisoned.versions.buildID == "development" && poisoned.versions.app == "unknown" && poisoned.service.version == "unknown" && poisoned.service.state == "unavailable" && poisoned.recordCounts.isEmpty, "Unavailable or malformed service data must not masquerade as current counts")
for _ in 0..<35 { recorder.record("SERVICE_UNAVAILABLE: \(secrets[2])", at: date) }
check(recorder.snapshot().count == DiagnosticsRecorder.limit && recorder.snapshot().allSatisfy { $0.code == "SERVICE_UNAVAILABLE" }, "Error history must be bounded and content-free")
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("local-diagnostics.json")
try DiagnosticsExport.write(report, to: destination)
let savedBytes = try Data(contentsOf: destination)
check(savedBytes == bytes, "Local saved diagnostics must exactly match the reviewed privacy-safe bytes")
let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
check(mode?.intValue == 0o600, "Saved diagnostics must be owner-readable only")
check(!String(decoding: savedBytes, as: UTF8.self).contains(destination.path), "The export destination itself must not leak into the report")
var rejectedRemote = false
do { try DiagnosticsExport.write(report, to: URL(string: "https://example.invalid/diagnostics")!) } catch { rejectedRemote = true }
check(rejectedRemote, "Diagnostics writer must reject remote URLs")
print("\(checked) diagnostics privacy checks passed")
SWIFT
xcrun swiftc "$PROJECT_ROOT/Sources/ChecklistApp/Support/DiagnosticsExport.swift" "$DIAGNOSTICS_CHECK_DIR/main.swift" -o "$DIAGNOSTICS_CHECK_DIR/diagnostics-check"
"$DIAGNOSTICS_CHECK_DIR/diagnostics-check" "$DIAGNOSTICS_CHECK_DIR"
