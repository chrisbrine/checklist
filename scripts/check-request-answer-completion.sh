#!/bin/bash
set -euo pipefail
ANSWER_CHECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANSWER_CHECK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/checklist-answer-completion.XXXXXX")"
trap 'rm -rf "$ANSWER_CHECK_TEMP"' EXIT
xcrun swiftc -swift-version 5 \
  "$ANSWER_CHECK_ROOT/Sources/ChecklistApp/Support/Canceled.swift" \
  "$ANSWER_CHECK_ROOT/Sources/ChecklistApp/Models/Record.swift" \
  "$ANSWER_CHECK_ROOT/Sources/ChecklistApp/Models/RequestDraft.swift" \
  "$ANSWER_CHECK_ROOT/Sources/ChecklistApp/Models/RequestAnswerCompletion.swift" \
  "$ANSWER_CHECK_ROOT/Tests/RequestAnswerCompletionTests/RequestAnswerCompletionChecks.swift" \
  -o "$ANSWER_CHECK_TEMP/check"
"$ANSWER_CHECK_TEMP/check"
