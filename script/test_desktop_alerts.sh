#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_scratch="$(mktemp -d "${TMPDIR:-/tmp}/checklist-desktop-alert-tests.XXXXXX")"
trap 'rm -rf "$task_scratch"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$task_root/Sources/ChecklistApp/Support/DesktopAlerts.swift" \
  "$task_root/Sources/ChecklistApp/Support/Canceled.swift" \
  "$task_root/Tests/DesktopAlertsTests/DesktopAlertsChecks.swift" \
  -o "$task_scratch/desktop-alert-checks"
"$task_scratch/desktop-alert-checks"
