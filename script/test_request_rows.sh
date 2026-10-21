#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_scratch="$(mktemp -d "${TMPDIR:-/tmp}/checklist-request-row-tests.XXXXXX")"
trap 'rm -rf "$task_scratch"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$task_root/Sources/ChecklistApp/Models/Record.swift" \
  "$task_root/Sources/ChecklistApp/Support/RequestRowPresentation.swift" \
  "$task_root/Tests/RequestRowPresentationTests/RequestRowPresentationChecks.swift" \
  -o "$task_scratch/request-row-checks"
"$task_scratch/request-row-checks"
