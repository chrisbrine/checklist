# Triage orchestrator contract

**Contract (CL-269, owner direction 24 October 2026).** A Triage is the work list of one orchestrator, which is one actual Codex or Claude conversation. A Triage holds 0 or more tickets, and its orchestrator receives every communication about them. This contract applies to every project. CL-125 implements ownership and membership, CL-248 implements message routing and CL-126 implements the app view. The [retired rules](#retired-rules) are history; the running server's discovered tools remain authoritative for what a call does.

This contract replaces the separate project orchestrator registry that CL-124 planned (registrations, participant groups, a shared inbox, request take, handoff and close, and an Orchestrators tab). That registry was never built and is not planned. The CL-124 [conversation content](conversation-content.md) contract stays.

The [Triage orchestrator schema](../contracts/triage-orchestrator.schema.json) and its [synthetic example](../examples/triage-orchestrator.json) describe a bounded snapshot of one orchestrated Triage, its members and holders, and the deliveries of one default ticket note. They are not command inputs or complete history. Service validation must enforce same-project references, one Triage per ticket, one orchestrated Triage per conversation per project, verified native identity, current grants and generations.

## Product rules

These rules are product invariants for every project. Project workflow policy (pass names, pass sizes, review cadence, which conversation implements or reviews) is editable project policy and cannot change them.

1. A Triage is the work list of one orchestrator. It holds 0 or more tickets. There is no minimum size.
2. A Triage with no orchestrator is a **plan** (for example "Pass 5"). Plans are optional; a project that does not plan never has one.
3. One conversation orchestrates at most one Triage per project. `triage_orchestrate` `start` with no Triage creates the caller's Triage (optional name; default `<Provider> · <short thread id>`). `start` with a plan makes the caller its orchestrator, only when the caller has no orchestrated Triage in that project. A second active Triage for the same conversation in the same project is refused with a clear error.
4. A ticket is in at most one Triage at a time.
5. A ticket moves into the orchestrator's Triage when that orchestrator handles it: its own `work_claim`, `batch_claim`, review claim, `work_takeover` or handoff acceptance, or an explicit add. Only the orchestrator, or the owner in the app, adds tickets to a Triage that has an orchestrator. Any eligible agent can still edit a plan.
6. A claim by another session (a subagent, sub-thread or helper conversation) does not move the ticket. That session becomes the **ticket holder**, and the ticket stays in the orchestrator's Triage. Dispatch pattern: the orchestrator adds the ticket to its Triage, then hands it out.
7. A claim on a ticket in a plan removes the ticket from the plan (and, when the claimant orchestrates a Triage, moves it there by rule 5).
8. Status changes do not remove membership. A ticket leaves a Triage only when it is Done or canceled, when another orchestrator handles it, or when it is removed.
9. A Triage has no phase. Each ticket's status gives its phase. A frozen [batch](batches.md) keeps its own phase and its current guards.
10. Submission keeps the ticket in the implementing Triage and records that Triage as its **return Triage**. A review claim by another orchestrator moves the ticket to that orchestrator's Triage. A verdict that returns work to implementation (reject, `evidence_missing`, `not_run`, or `blocked` with `blocked_on:"implementation"`) moves the ticket back to the return Triage when that Triage still has an orchestrator; otherwise the ticket leaves to no Triage.
11. `finish` ends orchestration with a reason. A Triage that still has tickets becomes a plan for a successor to start or take over. An empty Triage with no orchestrator, including a plan that empties, archives automatically with its history kept.
12. Claims, review independence, contributor records, batches, Epics, takeover rules, Human Requests and "silence never releases a claim" do not change. A project with no orchestrator works as before, with no setup and no empty screen.

Every move closes the old membership interval with a reason (`orchestrator_claim`, `orchestrator_review_claim`, `plan_claim`, `verdict_return`, `done`, `canceled`, `removed`, `other_orchestrator`) and opens the new one. Membership intervals, departure records and frozen batch snapshots stay in history. A move never changes a ticket's primary Epic, claim, planned assignee or status.

### Membership moves

| Event | Ticket in the caller's Triage | Ticket in another orchestrated Triage | Ticket in a plan | Ticket in no Triage |
|---|---|---|---|---|
| Orchestrator's own claim, batch claim, review claim, takeover or handoff acceptance | Stays | Moves to the caller's Triage | Leaves the plan; joins the caller's Triage | Joins the caller's Triage |
| Claim by a session that orchestrates no Triage (subagent, helper) | Stays; that session is the holder | Stays | Leaves the plan | Stays in no Triage |
| Submission | Stays; return Triage recorded | Stays; return Triage recorded | Not applicable (a claim left the plan) | Stays in no Triage |
| Verdict that returns work to implementation | Moves to the return Triage when it has an orchestrator, else leaves | Same | Same | Same |
| Pass verdict without Done, reviewer-side `blocked`, ordinary status action, note, metadata edit | Stays | Stays | Stays | Stays |
| Done or canceled | Leaves | Leaves | Leaves | Not applicable |

### Orchestrator lifecycle

`start`, `checkpoint`, `finish` and `takeover` keep their current receipts and history, and verified resumed-session recovery keeps its current rule. `takeover` of a Triage needs a different eligible session and a reason, makes the caller the orchestrator and keeps every member. A takeover by a conversation that already orchestrates another Triage in the project is refused under rule 3; that conversation finishes its own Triage first or moves the tickets by handling them. An ended route never implies abandonment and never makes a Triage a plan; only `finish` or takeover changes the orchestrator.

The Triage's displayed status still derives from its members (uniform, Mixed or Empty). The Active section, its counts and its filters include only tickets whose own status category is active (owner decision, 22 October 2026). Orchestration is Triage information and never promotes a member into Active.

## Message routing

Each ticket has two roles:

- the **ticket holder**: the session with the active claim, plus its accepted subagents;
- the **Triage orchestrator**: the orchestrator of the Triage that holds the ticket.

| Rule | Behaviour |
|---|---|
| Default (`audience=all`) | A ticket note goes to both roles, one delivery per session. When the orchestrator is also the holder, it gets one delivery. The sender gets none. |
| `audience` field | New `message_send` field `audience=all\|holder\|orchestrator` (default `all`) in a closed schema. `holder`: the holder and its accepted subagents only; the note stays readable in ticket history. `orchestrator`: the Triage orchestrator only. |
| Exact recipient | The `recipient` field stays exactly `{"kind":"session","session_id":"<verified scoped session>"}`. `recipient` and `audience` cannot be combined; the call refuses atomically and saves no message. `audience=orchestrator` on a ticket whose Triage has no orchestrator also refuses. |
| Mandatory both | Owner directions, Human Request answers, review verdict notices, ticket takeover and handoff notices and work-health notices always reach both roles. `audience` cannot narrow them. A verdict notice is written after the verdict's Triage move, so it reaches the holder and the orchestrator of the return Triage, never the reviewer's own Triage; a reject notice goes out when the ticket lands in a Triage whose orchestrator is not the reviewer. |
| Copy labels | The orchestrator's delivery has `recipient_role=triage_orchestrator` and the label "Also sent to <provider · thread>, which holds <KEY>." The holder's delivery names the orchestrator copy. `session_inbox` and `message_delivery_list` show these roles and labels. |
| No holder | The orchestrator receives the note. |
| No holder and no orchestrator | The note is saved for pickup, then delivered once when a holder or an orchestrator joins, and to a new orchestrator after a Triage takeover (existing saved-note pickup, at most 50 per pickup). |
| Triage note | `message_send` with `triage_id` and no `task_id` goes to that Triage's orchestrator, or to an exact recipient. An empty Triage is a valid subject. A plan needs an exact recipient, or the note is saved. |
| Project note | A note with no ticket and no Triage needs an exact recipient. |
| Reply allowance | The holder for `all` and `holder`; the orchestrator for `orchestrator`; the exact recipient as today. |

CL-248 implements this routing. Limits: a tagged mention note keeps its exact mention projection (holders and the tagged sessions); saved notes are delivered on the holder's or the orchestrator's `task_context` pickup and on `triage_orchestrate start` or `takeover` (the result reports `saved_notes_delivered` and `saved_note_delivery_has_more`); a Triage-note reply (`reply_to`) without a recipient goes to the original note's author; the orchestrator copy needs the orchestrator session's current authorization generation to equal the orchestration record, otherwise `audience=orchestrator` and Triage notes refuse `RECIPIENT_CHANGED`; `audience` other than `all` with a `requires_action` direction, correction or mention plan refuses `INVALID_INPUT`; a missing orchestrator for `audience=orchestrator` refuses `TRIAGE_ORCHESTRATOR_REQUIRED`. Every refusal saves no message. The stored message keeps `audience` and, when no role could receive it, `pickup_pending`; each delivery keeps `recipient_role` and its `label`.

The project policy field `coordinator_session_id` no longer routes anything; the Triage orchestrator replaces it. New policy saves do not accept it, and old values stay readable in exports and history. Delivery states stay truthful: saved for pickup, queued for an exact recipient and that recipient's acknowledgment are separate, and a missing reply never means failure, acknowledgment or completion. No route broadcasts to other sessions, wakes a native model, adds grants or routes to an assistant.

## Store upgrade rules

The store upgrade that introduces this model (CL-125) converts existing data as follows:

1. Active orchestrations are kept with their Triage, receipts and history.
2. A Triage with tickets and no active orchestration becomes a plan.
3. A ticket in several Triages keeps the orchestrated one; if none or several are orchestrated, it keeps the newest. Each other membership closes with a recorded exit (`upgrade_single_membership`).
4. A conversation with two active orchestrated Triages in one project keeps both until it finishes one. Until then, new work it handles joins the Triage it started last.
5. An empty Triage with no orchestrator archives, with its history kept.
6. The old Triage `phase` and the policy `coordinator_session_id` stay readable as history labels; neither drives behaviour, with one display exception: the owner's `workspace_page` surface `triage_candidates` lists Review tickets for an older Triage that keeps the history label `review` (see [commands](mcp-contract.md)).

Before installing the upgrade over a working installation, qualify the exact staged code through complete startup and the protected pre-upgrade backup against an owned, consistent copy of the actual existing store, with its retained record families and required managed files (AGENTS.md; [WAL, upgrades and recovery](database-storage.md#wal-upgrades-and-recovery)). Synthetic fixtures alone do not establish compatibility. Never repair the live database by hand.

## Retired rules

These rules are superseded by this contract. They are history, not current or planned behaviour:

- the CL-124 project orchestrator registry: registrations, participant groups, the shared inbox, request take, handoff and close, the Orchestrators tab, and the planned `orchestrator_*` commands;
- the fixed Triage phase and its errors (`TRIAGE_PHASE_CONFLICT`, `TRIAGE_PHASE_REQUIRED`); the older phase stays as a history label;
- the two-ticket minimum and the singleton rule;
- "any individual status action removes all Triage memberships" and the work-arounds that exist only to keep membership;
- membership in several Triages;
- a separate Review Triage for each round;
- the project policy field `coordinator_session_id`.

## Implementation sequence

1. **CL-125, ownership and membership.** Orchestrator per Triage, one Triage per ticket, moves, plans, finish and automatic archive, no Triage phase, return Triage, tool descriptions, and the store upgrade above with its qualification. Core tests cover every rule.
2. **CL-248, routing.** Default copies to both roles, the `audience` field, mandatory notices, copy labels, saved-note pickup on join and takeover, Triage notes, reply allowance, and retirement of `coordinator_session_id`. An installed check uses actual Codex and Claude conversations.
3. **CL-126, app view.** Triage rows with orchestrator, state and counts; plans shown as Planned; Triage detail with combined messages and a composer; the ticket composer's Both, Holder only and Orchestrator only choice; no Orchestrators tab; the coordinator field removed from Project Settings.

Each step needs independent review against its captured target before it is described as available. No step launches a model, adds a grant, routes to an assistant or wakes a native conversation.
