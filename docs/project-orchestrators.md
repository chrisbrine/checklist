# Project orchestrator contract

**Planned contract (CL-124).** Project orchestrator registration, the optional Orchestrators tab, group inboxes, and the commands below are not implemented or qualified by this document. Existing native sessions, ticket claims, Triage orchestration, scoped messaging, and Human Requests keep their current contracts. The running server's discovered tools remain authoritative. Implementation phases and qualification exits appear below.

A project orchestrator is an actual registered provider conversation that accepts responsibility for coordinating some project work. A group contains several such conversations. Registration records responsibility and how to contact it. Registration grants no project access, worker role, ticket assignment, claim, review eligibility, filesystem scope, or permission to launch a model. The implemented [bundled provider plugin interface](provider-plugins.md) supplies verified session references and separately qualified host capabilities.

The prepared [project orchestrator schema](../contracts/project-orchestrator.schema.json) and [synthetic example](../examples/project-orchestrator.json) describe a bounded snapshot containing one registration, a participant projection, one conversation, and a request projection. They are neither command inputs nor complete history. Service validation must enforce same-project references, keyed uniqueness, verified native identity, current grants/generations, and UTF-8 byte limits beyond JSON shape.

## Project configurations

| Configuration | Records and behavior | Native presentation |
|---|---|---|
| Zero orchestrators / manual handling | No enabled registration. Eligible sessions handle tickets directly under existing grants. No default coordinator or inbox is invented. | Tickets and Epics remain the ordinary project tabs. There is no Orchestrators tab or empty setup task. |
| One conversation | One single registration with its actual participant. General or focused responsibility is explicit. | Orchestrators opens that conversation and its responsibility, current route, and requests. |
| Several conversations | Several independent single registrations, with general or focused responsibility. A sender selects one exact recipient when responsibility overlaps. | Orchestrators lists registrations and opens the selected conversation in the existing detail overlay. |
| Conversation group | One group registration with at least two accepted actual participants. Participants may use the same provider or different supported providers. | Orchestrators shows one shared conversation, participants, and each request's responsible recipient or shared-inbox state. |

The tab appears when at least one registration is enabled (`active` or `paused`). Ending the last registration removes the tab while retaining its history through Activity and existing scoped conversation links. A group starts with its creator as its only accepted participant and displays **Waiting for participants** until another conversation joins. This temporary state creates no fictional second conversation. A group that later has one participant retains its identity and history. It does not create another worker to preserve its grouping.

Registration is optional. Existing ticket/Triage workflows do not require a project orchestrator. Epics remain stable ticket containers, and Triages remain temporary Implementation or Review groups expanded within Tickets. Project orchestrators do not replace either entity or add a second ticket lifecycle.

## Identity and responsibility

All IDs are service-assigned UUIDs scoped to one project. Stored record shapes have `schema_version=1`. Names are bounded display metadata and can collide. Mutations use IDs after scoped resolution. The following are closed shapes. Fields marked **derived** cannot be supplied as authority by a caller.

| Record | Required fields | Meaning |
|---|---|---|
| Registration | `orchestrator_id, project_id, revision, kind, label, responsibility, state, created_at, created_by` | `kind=single|group`; `state=active|paused|ended`. A single registration has one participant identity; its participation can later pause or end. |
| Participant | `participant_id, orchestrator_id, project_id, revision, provider_session_ref, participation, joined_at` | `participation=active|paused|left`. The participant is an actual conversation, separate from the registration and from a ticket attempt. |
| Provider-session reference | `session_id, authorization_generation, provider, installation_id, native_session_id, native_generation` | All fields are derived from the current authenticated native registration. An optional verified `subagent_id` and parent relation come from that registration. |
| Responsibility | `{kind:"general"}` or `{kind:"focused", task_ids, epic_ids, triage_ids}` | Focused arrays contain distinct same-project IDs. At least one array is nonempty. Each array has at most 200 IDs. Omitted arrays are empty. |
| Conversation | `conversation_id, project_id, orchestrator_id, revision, participant_ids` | Shared immutable message history with current participant/read checks. It is not a transcript imported from the provider. |

`general` means coordination across the project. `focused` means coordination of the named tickets, primary Epic members, or current Triage members. Membership changes affect future routing and context reads. Earlier messages retain their original selectors, revisions, and actual recipients. A focus is a handling responsibility, not an authorization grant or a write reservation. Every referenced object and every read still requires the caller's and recipient's current project authority.

A participant can belong to several registrations without becoming several sessions. In one registration, the same verified native conversation can have only one non-left participant. A session can independently implement a ticket, orchestrate a Triage, and participate here, provided its actual grants permit each action. These records never clear contributor history or make that session an independent reviewer.

The service accepts only an already enrolled worker with the applicable coordinator capability for registration. An assistant-only observer/messenger cannot register or join as an orchestrator. Self-reported provider IDs, names, personas, imported records, and provider manifests cannot establish identity. Provider capability observations name their plugin version, host version, source, time, and qualification state. Missing native identity returns a specific unavailable result.

Default v1 bounds are 32 enabled registrations per project, 16 accepted participants per group, and a label of at most 160 characters and 640 UTF-8 bytes. These bounds limit records and reads. They do not reserve model capacity.

## Lifecycle and self-maintenance

A conversation registers itself through its existing authenticated connection. Creating a group registers only the caller. Other conversations join themselves after authorized discovery or an existing scoped coordination message. One conversation cannot accept participation, report acknowledgment, or claim activity for another conversation. A join does not enroll a connection or widen its grants.

Each participant can update its own participation, responsibility checkpoint, and current verified binding. Registration-wide label, responsibility, pause, and end changes require an existing participant with coordinator authority and the registration's expected revision. Those changes record the actor and reason. Participants cannot update another participant's native identity or observed liveness. A group registration's shared responsibility does not prevent participants from publishing their own narrower handling notes.

Pausing stops selection for new requests. Existing requests, messages, and ticket claims remain visible. Leaving or ending retains history and identifies unresolved communication responsibility. It does not end the native conversation, release ticket claims, stop a child writer, cancel a Human Request, or complete work. An explicit service end action is intent to stop coordination, not proof of native process closure.

Route observations (`connected`, `busy`, `idle`, `disconnected`, `ended`, `unknown`) retain their source and observation time separately from participation and last meaningful checkpoint. Quiet checkpoints and provider/plugin changes can mark the display stale. Staleness never releases a claim or transfers a request. Native `ended` requires the existing [confirmed native conversation closure](work-authority.md#confirmed-native-conversation-closure) evidence. Idle turns, lost MCP connections, archived logs, and shared-host thread unloads are insufficient.

A supported resumed conversation can rebind the same participant only after bootstrap verifies the same native identity and its new authorization generation. The participant retains the binding history. Provider-session references use bounded strings for native and authorization generations; an optional verified `parent_session_id` identifies the enrolled parent. Old delivery generations, claims, reply allowances, and routing targets do not migrate. An unrelated replacement conversation receives a new participant ID and accepts an explicit handoff. Names never merge those records.

## Planned service surface

These are proposed command names and closed inputs for implementation, not instructions to call an undiscovered tool. Reads require `project_id`. Writes additionally require UUID `command_id`; edits require the named record's `expected_revision`. The existing idempotency, project-grant, store-incarnation, and unknown-outcome rules apply. Actor/session references always come from authentication.

| Proposed command | Input beyond shared fields | Result and guard |
|---|---|---|
| `orchestrator_register` | `kind,label,responsibility` | Create registration, shared conversation, and caller participant atomically. Return IDs, revisions, verified reference, and capabilities. Creates no grant, claim, or provider conversation. |
| `orchestrator_update` | `orchestrator_id,expected_revision,patch,reason` | `patch` is a nonempty subset of `label,responsibility,state`. Revalidate referenced scope. End is terminal; later handling creates a new registration linked to the old one. |
| `orchestrator_participate` | `orchestrator_id,expected_revision,action`; optional `checkpoint,reason` | `action=join|checkpoint|pause|resume|leave|rebind`. Join compares the registration revision; other actions compare the caller's participant revision. Changes only the caller's participation. Rebind uses the current bootstrap result, with no caller-supplied session selector. Join refuses a single registration owned by another conversation. |
| `orchestrator_list` | optional `task_id,epic_id,triage_id,include_ended,cursor,limit` | Only current authorized registrations/participants and safe route observations. Filters combine with AND. Default 50, maximum 100 rows, with opaque scoped cursors and truthful totals. No endpoint, credential, or unrelated native-session inventory. |
| `orchestrator_context` | `orchestrator_id`; optional `conversation_id,cursor,limit` | Responsibility revisions, permitted project brief/pins, bounded relevant ticket/Triage summaries, pending requests, and conversation references. Sections give counts, completeness, and independent cursors. Default 50, maximum 100 per requested page. |
| `orchestrator_resolve` | `orchestrator_id`; optional `participant_id,task_id` | Return `resolved|ambiguous|unavailable` with safe candidates and an opaque `recipient_target`. A single registration resolves its participant. A group resolves an explicit participant or its shared inbox. An overlapping focus never silently chooses another registration. |
| `orchestrator_message_send` | `recipient_target,body,expects_reply`; optional `context_refs,reply_to,content` | Reuse the existing attributed message/outbox handler. Commit one message and, for a question, one correlated request. Return conversation/message/request IDs and exact delivery state. Optional `content` follows [conversation content](conversation-content.md). |
| `orchestrator_request_take` | `request_id,expected_revision` | A current eligible group participant atomically accepts an unassigned shared-inbox request. Pin its exact current generation and create one recipient delivery. A competing take returns `REQUEST_ALREADY_TAKEN` without another delivery. |
| `orchestrator_request_handoff` | `request_id,expected_revision,action,reason`; `to_participant_id` on offer | `action=offer|accept|cancel|return_to_inbox`. Offer names an existing eligible participant. Only that participant accepts. The current recipient remains responsible until acceptance. Return to inbox requires the responsible recipient or an authorized coordinator and records why. No work claim transfers. |
| `orchestrator_request_close` | `request_id,expected_revision,reason` | Sender, responsible recipient, or authorized registration coordinator closes communication with attributed reason. Keeps unanswered/responded history and every delivery. Creates no acceptance or work outcome. |
| `orchestrator_reply` | `request_id,expected_revision,reply_to,body`; optional `content` | Only the responsible exact recipient generation appends the formal correlated response and marks that request responded. The response is agent content. Ticket completion, work handoff, and human answers remain separate commands. |

Checkpoints and reasons are strings of at most 4,000 UTF-8 bytes. Message `body` keeps the existing 65,536-byte limit. `context_refs` contains at most 50 closed references `{kind,id,revision?}`, where `kind=task|epic|triage|human_request|attachment`. All IDs must resolve in the same authorized project. References do not grant their bytes to the recipient. Provider memory, hidden transcripts, arbitrary paths, and raw native endpoints are not context sources.

A recipient target binds caller, project, registration/participant and membership revisions, communication grants, exact native route generation when selected, and store incarnation. The service rechecks them before commit and immediately before external transport. Changed targets return `RECIPIENT_CHANGED`, revoked authority returns `FORBIDDEN`, and foreign IDs disclose no foreign data. A missing capability returns `CAPABILITY_UNAVAILABLE`. No command silently falls back to a label, newest session, different provider, external channel, or hidden runtime.

The service must check current authority on reads, writes, retry, and pickup, even with cached discovery. Invalid version/shape, stale revisions, or failed authorization commit no partial records. Lost write replies retain the original `command_id`; a retry reconciles that intent rather than creating a new request.

## Synthetic registration and request example

These planned inputs describe an existing authorized Codex conversation registering itself for two tickets. They do not create the conversation or enroll it. Names and UUIDs are synthetic.

```json
{
	"project_id": "20000000-0000-4000-8000-000000000001",
	"command_id": "20000000-0000-4000-8000-000000000002",
	"kind": "group",
	"label": "Rendering coordination",
	"responsibility": {
		"kind": "focused",
		"task_ids": ["20000000-0000-4000-8000-000000000003", "20000000-0000-4000-8000-000000000004"]
	}
}
```

The registration receipt returns `orchestrator_id`, `conversation_id`, the caller's `participant_id`, and `revision=1`. An already enrolled Claude conversation calls `orchestrator_participate` with that project/registration, its own new command UUID, `expected_revision=1`, and `action="join"`. The service derives Claude's actual native reference and returns a distinct participant ID. Neither call assigns or claims the two tickets.

A sender resolves the group inbox and sends one question with `expects_reply=true`. Its receipt names `request_id`, `revision=1`, and `state="inbox_pending"`, without an exact-recipient delivery. The Claude participant takes that request at revision 1. The receipt names revision 2 and one queued delivery whose `recipient_session_id` and generation match Claude's verified current binding. A simultaneous Codex take of revision 1 fails without a second responsibility or delivery. Claude reads and acknowledges its own delivery, then replies using the exact request/message IDs. The correlated response records `responded`; all work claims and completion gates remain unchanged.

## One responsible recipient and truthful replies

A request names `request_id, project_id, conversation_id, message_id, revision, state`, its exact context references, and either `responsible_participant_id` with `recipient_session_generation`, or `shared_inbox_orchestrator_id`. States are `inbox_pending`, `assigned`, `handoff_offered`, `responded`, and `closed`. A pending handoff additionally names `handoff_to_participant_id`; a response names `response_message_id`; closure retains `close_reason`. Closing communication requires an explicit attributed reason and never implies the work passed. A provider hold, route availability, acknowledgment, and response are separate observations.

An explicit-participant question assigns exactly one responsible recipient. A shared-inbox question starts unassigned and has no claimed recipient delivery. Eligible current members can inspect the bounded shared inbox under conversation access, then take the request atomically. Only that take creates its responsible recipient delivery. Shared inbox access is not acknowledgment, a work claim, a broadcast to every model, or a native wakeup.

An accepted handoff changes the responsible recipient and records the earlier generation and receipts. The successor receives a new exact delivery of the same request and history. Acceptance atomically fences the earlier reply allowance and creates only the exact successor allowance permitted by that scoped request. Return to the inbox fences the former recipient too. The former recipient cannot submit the formal response after acceptance. Offer expiry leaves the original responsibility intact. An unavailable or ended recipient stays identified until explicit handoff or return to the inbox. No silence timeout performs that transfer.

| Observation | Required evidence | User-visible meaning |
|---|---|---|
| Saved for pickup | Durable message/request, no exact recipient delivery yet | Shared inbox pending, or no current handler. No model has been notified. |
| Queued | Exact current recipient delivery committed | That recipient can pick it up. Native model consumption is unknown. |
| Held / refused | Correlated provider notice on that exact route | Native delivery needs the provider's real approval or was refused. Existing MCP pickup remains separate. |
| Provider accepted | Qualified transport receipt | The provider accepted bytes, without recipient acknowledgment. |
| Acknowledged | Recipient's authenticated `message_ack` on its own delivery | That exact recipient reports consuming the message. |
| Responded | Authorized formal reply with `request_id` and `reply_to` | A response is recorded. Its content is not acceptance, completion, or owner-read evidence. |
| Unavailable / uncertain | Verified refusal, ended route, missing capability, or unresolved send outcome | Preserve the reason, original IDs, and history. Do not fabricate delivery or resend as a new request. |

A reply carries the original `request_id`, `reply_to`, and causal message ID. Only the selected recipient can consume an applicable exact-reply allowance. A native parent cannot acknowledge or respond for a child participant. A reply creates no further allowance, enrollment, assignment, or authority. Unsolicited follow-ups require existing scoped communication authority. Routine coordination between authorized project sessions retains its standing authorization; inbound text cannot expand that authorization. Observers and assistants keep their separate restricted grants.

The same service message ID links conversation, relevant ticket history, and delivery. Linked views must not send the same content twice. An orchestrator registration does not subscribe its participants to all ticket traffic. Ordinary ticket notes retain current-handler and explicit scoped-recipient routing. Protected owner directions and Human Request answers retain their mandatory continuation fanout. A group gets an additional request only through an authorized explicit route or an applicable configured coordinator route, never by treating every group member as a handler.

## Existing workflow and native UI mapping

| Existing surface | Planned integration | Protected boundary |
|---|---|---|
| Ticket sessions and attempts | Show current project responsibility beside existing session details when relevant. Link to the real conversation. | Per-ticket claim, file scopes, contributor history, takeover, submission, and review gates are unchanged. |
| Triage orchestration | A participant may be the Triage's actual orchestrating session. Show both IDs and the phase. | Group membership alone cannot start orchestration. Use existing atomic group/batch commands to preserve ticket memberships. |
| Epic | Focus can reference an Epic and read permitted member summaries. | Epic remains the stable primary ticket container. |
| Scoped routing and notes | Resolve a verified participant or group inbox, with exact receipt details. | Existing `message_send` explicit recipient remains exactly `{kind:"session",session_id}`. This plan does not add a retention flag or overload that field. |
| Human Requests / Needs You | Show requester, responsible continuation, and relevant orchestrator link. Rich question/explanation content can use the shared renderer. | Only the trusted app answers for the owner. Agent replies cannot approve, impersonate the owner, or bypass duplicate-answer checks. |
| Attachments and previews | Use authorized immutable attachment references and the [shared file previews](attachments.md#shared-native-file-previews-cl-121). | A context link or chart is not permission to read a file, inspect an image, or satisfy a gate. |

The Orchestrators tab contains conversations and responsibility, not a global worker or provider catalog. Single and group conversations reuse the existing overlay, Back, draft preservation, scoped history pagination, note composer, accessible delivery labels, and offline behavior. The composer states the project, registration, and exact participant or shared inbox. A changed destination preserves the draft and requires destination reconciliation before sending. Opening a native conversation is offered only when its verified host link is supported.

Request rows show **Unassigned in shared inbox**, **Responsible: provider · conversation**, **Handoff pending**, **Responded**, and actual route/receipt details. Identity, provider versions, generations, and revisions stay in Technical details. Busy, idle, stale, unavailable, and ended never share one green “working” indicator. No zero-orchestrator prompt launches or enrolls anything.

## Bounded implementation sequence

These phases are planned delivery units. None starts a timer, subscription, model, installation, or live data write through this document.

1. **Records and scoped reads.** Add closed schemas, canonical record/export/backup registration, expected-revision commands, self-only participation, and bounded discovery/context. Prove zero/manual mode, one conversation, overlap ambiguity, cross-project denial, spoofed identity denial, generation changes, and lossless history. Use protected store-upgrade qualification before replacing a working installation.
2. **Responsibility and messaging.** Reuse durable outbox/inbox and reply handlers for exact recipients and one shared-inbox request. Prove simultaneous take, idempotent lost-reply recovery, accepted/canceled handoff, late former-recipient reply, paused/left/ended peers, grant revocation, and recipient-specific acknowledgments. Existing ticket claims and Triage memberships must remain unchanged.
3. **Native composition.** Add the optional tab and shared conversation UI, [optional rich content](conversation-content.md), Human Request links, and authorized previews. Prove manual absence, single and several layouts, same-provider and cross-provider groups, keyboard/large-text behavior, saved drafts, offline recovery, and bounded long history.
4. **Actual host qualification.** Exercise deliberately selected registered conversations through each advertised plugin/host version. Record exact producer, target/hash, recipient generation, transport/hold, consumption, reply, and handoff evidence. MCP pickup does not qualify idle native push, creation, child delivery, or resumption. Unsupported routes stay pickup-only or unavailable. After two identical failures, stop that route attempt and diagnose or report its limitation.

Each phase requires independent review against its captured target before it is described as available. Deterministic fixtures qualify service behavior. Real native receipts qualify host capabilities separately. No new decision about assistant integration, model launch policy, provider fallback, automatic supervision, or owner authority is part of this contract.
