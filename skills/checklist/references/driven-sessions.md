# Sessions that another agent starts (optional)

Read this only when an orchestrator starts a provider session outside that provider's own desktop or terminal host, for example `codex exec` started from a Claude conversation or a script. A native Codex or Claude conversation, including a Triage that Codex itself orchestrates, uses its MCP connection; skip this reference.

Each host has its own section. A host without a section here is not supported for this route until someone observes and records it.

## Codex CLI (`codex exec`)

Observed on 19 October 2026 with codex-cli 0.159.0 and installed Checklist build 47:

- `codex exec` starts stdio MCP servers with a filtered environment that has no `CODEX_THREAD_ID`. The bundled `checklist mcp` server cannot find the native thread, so no Checklist tools appear in the thread and no error is shown. A `-c mcp_servers.checklist=...` override does not change this.
- Shell commands that Codex runs have `CODEX_THREAD_ID` and a `codex` ancestor process. From such a shell, `/Applications/Checklist.app/Contents/MacOS/checklist call` bootstraps the actual Codex thread as its own session. Its caller `session_id` is the thread ID, and its installation differs from the orchestrator's.
- The `read-only` and `workspace-write` sandboxes block the call. `workspace-write` cannot write the Checklist folder in `~/Library/Application Support`. With that folder added as a writable root, the call returns `OUTCOME_UNKNOWN` because the sandbox blocks the service connection. Only `danger-full-access` reached the service.

### Procedure

1. Decide which threads need Checklist. A helper that only edits files and reports back does not need it: the orchestrator keeps the claim, and the helper can stay in `workspace-write`. A thread that claims, reviews or sends notes needs the route below.
2. Start that thread in the registered project folder (`codex exec -C <project root> -s danger-full-access ...`). `danger-full-access` removes the sandbox for every shell command of the thread. Give such a thread a narrow task (for example, review only, no file edits), and do not use it for unrelated work.
3. Make the first command `checklist call service_info '{}'`. Continue only if `caller.session_id` equals the thread ID and `project_ids` contains the project.
4. Call tools as `checklist call <tool> '<json arguments>'`. The names and arguments are the same as the MCP tools; `checklist tools` lists the catalog. Each write needs a new random UUID `command_id`; reuse it only to retry the same command with the same input.
5. Keep claim tokens out of prompts, notes, logs and reports that another agent reads. The thread obtains and uses its own tokens.
6. Finish all Checklist work in the same `codex exec` run that made the first call: connect, read context, claim, check, add evidence and record the verdict, submission or release before the run ends. Write the prompt so that the thread does not stop early to ask a question.
7. Do not use `codex exec resume` for more Checklist work. A resumed run is a new Codex process. Checklist binds a Codex thread to the process that first connected it (provider, PID and kernel start identity), and it lets only a verified Claude session resume after its process closes. On 19 October 2026 (build 47) a resumed reviewer thread got `NATIVE_SESSION_MISMATCH` on its first call. For later Checklist work, start a fresh thread. A resumed thread can still edit files or report without Checklist.

### Run lifetime

- A run that ends does not release its claim, prove native closure, complete work or acknowledge a message. A claim that a finished run still holds stays until an eligible session takes it over with `work_takeover` and a reason, or the owner recovers it.
- A queued Checklist note does not wake a finished `codex exec` thread, and a resumed thread cannot read that thread's inbox. Send the next step to a fresh thread in its prompt.

### Identity and review independence

- Each `codex exec` thread is a session separate from its orchestrator. Its Checklist authority belongs to the process of the run that connected it, not only to the thread ID.
- A fresh thread is a new session. It gets no claim, message or authority of an earlier thread, and it follows the ordinary claim and takeover rules.
- A thread that edited files for a ticket is an implementation contributor, even when the orchestrator held the claim and the thread never connected to Checklist. Record its thread ID in a note on the ticket. It never reviews that ticket.
- A fresh thread that did not contribute can review, under the ordinary review rules in [review](review.md).

### Reviewer brief template

Fill the placeholders before starting a fresh Codex thread on `gpt-6.1-sol` for one batch: `<project folder>`, `<project_id>`, `<triage_id>`, `<build ID>`, `<checklist CLI>`, `<source capture>`, `<scratch folder>`, `<handoff details>` and `<contributors>`. Follow [combined build rounds](coordinate.md#combined-build-rounds) when preparing the round.

You are an independent reviewer. You did not contribute to these tickets. Find real defects and pass a ticket only when evidence and your own checks prove every acceptance item and applicable project requirement. Recorded contributors include `<contributors>`; their reports remain attributed to them.

1. Read `<project folder>/AGENTS.md`, `skills/checklist/references/review.md` and this reference first.
2. Run ticket service calls from `<project folder>` as `<checklist CLI> call <tool> '<json>'`. The first call is `service_info '{}'`. Continue only if `caller.session_id` equals your actual Codex thread ID and `project_ids` contains `<project_id>`. Use `<checklist CLI> tools` to read current schemas. Each write has a new random UUID `command_id`; reuse it only for an exact retry.
3. Treat the shared checkout and `<source capture>` as read-only. Create, edit and delete files only under `<scratch folder>`. Run SwiftPM only on a private copy of the capture with your own `--scratch-path` there. Do not run `script/build_and_run.sh`, install, quit or relaunch the live app, change system settings or answer macOS permission prompts. Keep claim tokens out of prompts, notes, evidence, logs and reports shared with others.
4. Call `review_batch_inputs` with `project_id:<project_id>` and `triage_id:<triage_id>`. Inspect `tasks`, `not_ready` and contributor identities. Report unavailable targets; if no tasks are ready, report and stop. This read grants no claim and does not replace stored independence checks.
5. Call `batch_prepare` with that `triage_id`, `phase:"review"`, `tasks` unchanged and `triage_revision` as `expected_revision`. File/lane scopes default empty. Call `batch_claim` with the returned batch identity, its revision as `expected_revision` and its `policy_revision`. On a revision conflict, reread `review_batch_inputs` and prepare again. On another error, correct only your input and retry once; after two identical failures, report and stop.
6. After claiming, read `review_context` for each exact `task_id`, `review_request_id`, `target_manifest_id` and `gate`. Read the current acceptance, applied project review contract, captured instruction references, source relevance scopes, acceptance evidence and contributors. Read `<handoff details>` as claims to verify.
7. Compare the submitted capture with the capture for `<build ID>` and inspect each ticket's hunks in shared files. Choose your own code inspection and focused checks in your private copy. Carry valid passing cases with their original producer, target and hash; run failed, inconclusive or materially affected cases. A test result alone is not a review.
8. Read the attached check-runner reports for installed observations on `<build ID>`; verify hashes, producer and item coverage. Do not drive the live app or create a test slot yourself. Read-only service calls are allowed. Record an uncovered observation as `evidence_missing` or an unrun check as `not_run`, with the reason; never infer an observation from code or a contributor's report.
9. Add your own per-ticket report with `review_evidence_add` using your exact review claim: inspected target, checks, commands, results, evidence references and limits. Refresh `review_context` with your chosen evidence references. Each pass needs a current `review_assessment` with one reasoned, evidence-backed result per acceptance item and project requirement, plus complete instruction coverage.
10. Record verdicts with `batch_review_record` for every remaining live batch claim exactly once. Supply the exact request/manifest/gate, claim, direction cursor and verdict fields from the discovered schema. Use `pass`, `reject` with `blocking` or `advice` findings, `evidence_missing` with a reason, `not_run` with a check and reason, or `blocked`. Non-final verdicts (`blocked`, `not_run`, `evidence_missing`) retain Review Triage memberships; reject and pass keep their departure effects. Do not substitute individual `review_record` calls when membership must stay.
11. Finish connect, claim, review, evidence and verdicts in this run. If interrupted, save each available verdict with `review_draft_save` and report the still-active claims; a saved draft does not end them. Use `batch_release` with selected `{attempt_id,claim_token}` members and a non-empty reason for an authorized release that preserves membership. Report failed tickets to the review orchestrator, which routes their rework to the implementation orchestrator; preserve passing tickets.

Final report: one line per ticket with key/title, verdict, review ID and finding IDs. Then list new checks, carried evidence with original producer/target/hash, missing observations, still-active claims and review limits. Keep claim tokens out of the report.

### Check-runner brief template

Fill `<project folder>`, `<project_id>`, `<task_id>`, `<acceptance items>`, `<build ID>`, `<checklist CLI>`, `<slot>`, `<slot CLI>`, `<slot project_id>`, `<scratch folder>`, `<evidence folder>` and `<check plan>`. The implementation orchestrator supplies a prepared test slot of that build, seeded empty or from a verified backup. Up to four runners use separate slots in parallel.

You are a fresh non-contributor Codex check runner on `gpt-6.1-sol`. Record installed-app observations for `<acceptance items>` on `<build ID>`. You do not claim work, review or record verdicts. Your only real-ticket write is attaching the requested evidence to `<task_id>`.

1. Read `<project folder>/AGENTS.md`, `docs/test-instances.md` and `<check plan>`. Keep the shared checkout and source captures read-only. Write scratch and reports only under `<scratch folder>` and `<evidence folder>`, outside the shared checkout.
2. Run ticket evidence calls from `<project folder>` with `<checklist CLI> call <tool> '<json>'`. First call `service_info '{}'`; continue only if `caller.session_id` equals your actual Codex thread ID and `project_ids` contains `<project_id>`. Read schemas with `<checklist CLI> tools`. Each write has a new random UUID `command_id`; reuse it only for the same input. Keep claim tokens out of shared outputs.
3. Verify the assigned `<slot>` and its running build identity against `<build ID>` before checking. Use `<slot CLI>` for synthetic slot data, with its actual authorized slot workspace; verify `service_info` and `<slot project_id>` there too. A copied grant is no authority. If identity, build or enrollment is missing, report the limit instead of using the live store or enrolling a new session.
4. Identify the test app and synthetic data before opening its GUI. Use only the assigned slot. Do not run `script/build_and_run.sh`, install, quit or relaunch the live app, change macOS settings, answer permission prompts or open video, audio or unknown-file attachment previews. Leave unrelated crash dialogs alone.
5. Follow `<check plan>` item by item. Create only its named synthetic records, labeled `[Synthetic check]`, in the slot. Record the baseline, action and expected/observed values, screenshots and errors. Record `sysctl -n vm.loadavg` at each check's start and end and on an error state. Preserve earlier methods and results as attributed evidence; verify any proposed workaround yourself.
6. For a live-update check, record the open synthetic ticket and scroll position before and after the change. For a badge/count check, record baseline, added-item count, in-app toggle off/on and return to zero where required. Restore app settings, remove synthetic records through supported commands and verify their final states. Record any incomplete cleanup.
7. Write a report in `<evidence folder>` naming the actual runner, build ID, slot/seed, each acceptance item, method, commands, observations, load values, limits and synthetic record final states. Hash the report and screenshots with SHA-256. Use `attachment_add` on `<task_id>` with an authorized managed source, `expected_sha256` and a description naming you as check runner and the exact `<build ID>`. Attach the report and key screenshots before the ticket owner submits; retain attachment IDs and hashes.
8. Close the clearly marked test GUI after the bounded check and restore the real Checklist window. Report slot cleanup to the implementation orchestrator; do not destroy another runner's slot. Finish evidence attachment in this run without asking the owner engineering or sequencing questions.

Final report: actual Codex thread identity; build ID and slot; each acceptance item shown yes/no with the key observed values; report and screenshot attachment IDs with SHA-256; synthetic data final states; cleanup result; anything not checked and why. These are observations, not review verdicts.

### Limitation

The MCP route for `codex exec` stays unavailable while Codex does not pass the thread identity to MCP servers. Do not set `CODEX_THREAD_ID` or another identity variable by hand: Checklist must observe the actual host, and a supplied value is not evidence.

## Other hosts

Before a host (for example T3 Code) gets a section here, observe and record:

- How the host gives its session identity to MCP servers and to shell commands, and whether the Checklist bootstrap finds the host process.
- Which sandbox or permission mode lets `checklist call` or `checklist mcp` reach the service, and what else that mode allows.
- That `service_info` returns the host's own session, separate from the orchestrator, in the expected project.
- How a finished session continues: whether a continued session keeps its Checklist binding or is refused as a new process, and whether a queued note can wake it.

Until then, report the host as unsupported for this route. Do not fake identity variables or reuse another session's identity.
