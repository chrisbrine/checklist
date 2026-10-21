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

### Limitation

The MCP route for `codex exec` stays unavailable while Codex does not pass the thread identity to MCP servers. Do not set `CODEX_THREAD_ID` or another identity variable by hand: Checklist must observe the actual host, and a supplied value is not evidence.

## Other hosts

Before a host (for example T3 Code) gets a section here, observe and record:

- How the host gives its session identity to MCP servers and to shell commands, and whether the Checklist bootstrap finds the host process.
- Which sandbox or permission mode lets `checklist call` or `checklist mcp` reach the service, and what else that mode allows.
- That `service_info` returns the host's own session, separate from the orchestrator, in the expected project.
- How a finished session continues: whether a continued session keeps its Checklist binding or is refused as a new process, and whether a queued note can wake it.

Until then, report the host as unsupported for this route. Do not fake identity variables or reuse another session's identity.
