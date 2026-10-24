# Acceptance scenarios

These are release checks except the historical personal-assistant section, cancelled on 22 October 2026 (CL-3 and CL-22). Assistant/Dot integration is outside the current release: no assistant UI/setup is active, and its prior component tests do not prove a completed Dot/plugin/helper result. A development implementation and tests exist; [implementation status](implementation-status.md) and actual evidence identify what has been observed. This full list is not claimed passed. Keep evidence of client versions, machine, source revisions, command results and observed outcomes. Use synthetic work until a real transfer is authorized.

## First production slice

Prove title/project capture → Draft/Ready → worker claim → owner note/image → blocking multi-question/file request → trusted answer → immutable implementation submission → exact review claim/finding → fix/new review target → completion → archive/restore. Run through the installed synthetic test app with actual receipts where native delivery is claimed. Add an Asset approval, Playtest build and Question task with suitable gates after this loop works. A partial/local test pass cannot stand in for the complete installed/native release loop.

## Authority, claims and recovery

| Scenario | Required result |
|---|---|
| Same key/title in two projects | Separate tasks, notes, epics, dependencies, search results and session grants |
| Cross-project UUID/alias in any command | Reject with no content leak and no partial write |
| MCP working directory differs from open project | Resolve caller workspace, never service/app selected folder |
| Title-only capture / incomplete brief | Saved Draft visible; no worker/batch may claim until validated readiness=ready |
| Symlink/case/ancestor overlap between project writable roots | Reject physical overlap before registration/claim; read-only references remain allowed |
| Scope expansion conflicts with another attempt | Atomic failure leaves original scope/reservations intact |
| Two sessions claim one queued task concurrently | Exactly one attempt/token; other receives conflict |
| Competing batch/path/lane claims | All-or-nothing reservations; no hidden partial batch start |
| Stale revision/idempotent retry | No overwritten intent or duplicate message/attempt; payload mismatch rejected |
| Busy agent has no check-in | Show stale/unknown; no automatic takeover |
| Owner verifies stop and takes over | New fenced generation; old token cannot mutate; filesystem risk explicitly reconciled |
| Parent ends while child edits | Child claim/contributor remains visible; no false completion or unsafe release |
| Restore old backup | New store incarnation; old tokens/endpoints cannot regain authority |
| Reconnect after successful claim response is lost | Same semantic receipt; authenticated reattach can rotate only live authority; released/revoked authority never returns |
| Parent submits while child still has writable scope | Reject and retain reservations until descendant stop/release is verified |

## Review, context and grouping

- Optional submission/reviewer measures retain named units, finite numeric before/after values and upper limits inside hashed evidence. An after value above its limit warns on the ticket; equality does not. Compare the immediately previous loaded submission/review attempt by exact name/unit (and report title for reviewer evidence), preserving provenance and showing changed limits or missing/ambiguous history. A warning alone never creates a failed gate.
- A Playtest bundle retains exact managed build identity plus hashed scenario, state files, screenshots and log through the existing manifest/attachment system. New build identities reject reuse of earlier run attachment IDs. Pass/reject requires a pass/fail result for every acceptance item through `review_assessment`; no result transfers to a replacement target. Opt-in cited-file retention protects only cited bundle files with ordinary Keep original, and normal cleanup preview/jobs select eligible uncited originals while respecting all other holds. Cleaned bytes remain unavailable; hashes/results survive.

- A direction or relevant approved decision arrives after a human approval form opens: complete approval with missing/stale observed task revision/direction cursor or unresolved direction fails before file import, response/verdict mutation or slot release. Ordinary answers and unresolved Not checked through clarification/cannot-do stay possible.
- Owner recovery shows queued/running/interrupted source checks and every `process_stop_unverified` check even when its descriptive state is stale/failed; revision/state/stop-flag changes invalidate the previous stop observation.
- Review claim must name review_request_id, gate and exact manifest; wrong/missing/mismatched target rejects; second active review/approval on same task conflicts.
- Tests execute on the captured snapshot or with all relevant writers excluded and before/after fingerprints; a different mutable checkout cannot pass.
- Finding IDs survive fix rounds; every applicable open finding is resolved/rejected with evidence or explicitly waived; later verdict supersession retains history.
- Retained historical/future review_accepted milestone labels require all valid gates; zero-gate completion uses No review required and waived completion never claims accepted review. Individual review/status actions still detach even on rejection; they cannot claim an accepted-review milestone falsely. Any actual Done transition removes every current Triage membership regardless of milestone.
- Compact context includes project brief/pinned decisions, unresolved findings and owner direction with links; updates to decisions appear without rewriting old messages.
- Implementation session ends before submission: task remains unfinished/recovery-required.
- Submitted implementation has no reviewer: show ready for review, not in-progress review.
- Same contributor under another child/profile attempts review: independence fails. A separate actual non-contributor reviewer subagent on the same authenticated host is eligible under provider policy.
- Relevant dirty file or acceptance changes after pass: applicable verdict is stale; cosmetic title/order changes do not automatically invalidate code evidence.
- New composer notes are informational and never block work; the recipient may react with one fixed marker. A requires-action direction from an approved project-context change or older flagged note requires an addressed disposition/evidence or an explicit reasoned owner waiver or enrolled-worker waiver while `agent_rule_changes=allowed`, retaining the actual origin and waiver kind, not just acknowledgment; a direction arriving during completion causes an atomic stale-cursor rejection.
- Review pass/reject/blocked releases its review reservation correctly; unrelated gates remain; completion leaves no live writable/review descendants.
- One integration can satisfy configured integration/review gates; accepted tasks close individually and failed ones alone return for fixes.
- Project navigation has Tickets and Epics tabs; Tickets contains expandable Triage group rows listing their members, with group editing in the right overlay and no separate Triage workspace.
- A ticket belongs to several Triages, then receives an individual built-in/custom status action, including an explicit mark to the same current status: all current memberships depart in the same transaction, with departure history, Epic and frozen batch records preserved. Notes, attachments, title/tags/Epic and other metadata-only edits do not detach. Waived completion stays labeled waived; a Done departure does not fabricate review acceptance.
- Triage status is derived from current members as their shared status, Mixed or Empty, with no independent persisted group status. A group transition applies the selected ordinary/custom status to every current member through current task guards, retaining ordinary membership. Group Done removes each completed member from all current Triages. No client-supplied keep-membership/bypass flag is accepted.
- Individual claim/release/submission, review request/verdict, completion/recovery and gate-bearing human approval status workflows remove all current Triage memberships, including same-status actions. Ordinary human answers, notes, attachment and metadata edits retain membership.
- Empty group transition returns no-op/empty_triage; a uniform same-status group action preserves member/group revisions and memberships. Explicit same-status individual marking still detaches. Active/Review targets cannot acquire authority through a group status picker.
- Triage transition validates the exact member set, group revision and every task revision. A concurrent add/remove/status edit, blocked member, missing completion gate, unresolved direction, denied role or active claim aborts the entire command without partial ticket/status/membership/history changes; a successful Done transition removes members from every current Triage.
- Triage adds/removes tasks during a batch; manifest remains fixed, membership history survives, and exit-on-submit versus exit-on-review behaves per member.
- Epic is a stable project subproject by task type: moving a ticket atomically updates its old/new Epic containers. Triages temporarily include tasks from several Epics; add/remove/implementation-review exit never changes a task's Epic or history. A task in two Triages still has one exclusive edit claim.
- Context is compacted/handed off: all owner direction, unresolved findings, limitations and message cursors remain retrievable.
- Policy changes while active: no stolen assignment; new queued work uses new rules; checkpoint and ordinary pinned-policy modes explain their effects.
- Several custom Parked statuses remain distinct, non-pickable and exportable; guarded custom transitions cannot bypass claims/reviews; status retirement remap preserves history.
- Category/gate defaults and explicit custom destination selections are represented/validated; a review claim preserves the selected review status unless an explicit route changes it.
- Project tags support many-to-many/bulk/any-all-none filtering and rename/merge/retirement without affecting provider attribution or other projects.

## Real messaging qualification

For each supported native route, run idle and busy, parent and child, both provider directions. Record transport accepted ID and exact recipient acknowledgment. A CLI's help text, open socket, simulated adapter or parent receipt alone is insufficient.

- `service_info.native_routes` and the ticket communication disclosure agree with the [native route table](integrations.md#native-communication-route-qualification); unavailable routes have no qualifying versions/receipts. Enrollment, socket writes and parent receipts do not promote a route. Qualifying a child or relay direction requires its own exact child acknowledgment and every hop.
- Human note saved: immediate durable history/outbox; transport attempt starts within the stated awake/connected target.
- Receiver sees trusted human provenance via MCP; an agent message claiming “I am the owner” cannot gain it.
- Provider accepted but reply lost: stable ID retry where supported; otherwise uncertain state with no automatic duplicate work.
- Sleep/wake, closed provider, permission prompt, expired token and quota failure: pending message survives and truthful status appears.
- Missing Codex desktop endpoint: no new embedded server, daemon, CLI model, or managed runtime fallback.
- Canonical Claude serializer/parser includes the actual sender permission class, never an invented field or more permissive claim; missing-mode negative fixture explains hold, corrected fixture matches the successful recorded envelope. Test both truthful permission classes/mismatch without recipient-setting changes.
- Held route survives service restart and delayed native approval; expired return correlation cannot acknowledge a new attempt; no repeated send or permission/token impersonation bypasses the hold.
- Claude Desktop held/refused message: app reports held/refused, not acknowledged; socket token expiry does not expose credentials.
- Cancelled/ended child or reused display name: exact old delivery cannot reach a different child.
- Parent relay: every hop recorded; only child acknowledgment satisfies child delivery.
- Two identical route failures: route is suspended with a useful diagnosis, not an indefinite retry loop.

## Native UI and human requests

- Quick capture accepts title/project and optional note/image without full template; required readiness context is explained before Ready.
- Asset/build approval binds review_request_id and immutable attachment/build identity plus fingerprint; replacement/cleaned/inaccessible target blocks stale approval and preserves the draft.
- Select Approve or I ran it, then replace the exact candidate/build: old draft stays linked to old target; choice/check outcome clears, Send disables and new inspection is required.
- Ordinary answer clears dependency; exact human approval additionally records named human gate pass/reject, never passes unrelated technical gates or directly closes task.
- Send answer (including explicit No for check/approval) atomically answers the request and saves requester delivery; the request leaves Needs You and sidebar/Dock counts update from the committed receipt before a refresh. Not checked with the owner’s explanation sends and records `not_checked` plus the text, reaches the requester, and retains the pending request and any approval slot without a verdict. Not checked without an explanation, missing questions and missing files refuse Send with the named item and save no answer/note/delivery. A declined check asserts no run; a declined approval rejects its exact gate. Qualify answering/declining in an installed test slot with a non-contributor observer.
- One active blocking request per task supports mixed question/file/check capabilities; clarification/cannot-do/partial/snooze never silently clear its dependency; complete valid answer clears only that dependency.
- Create/edit/search/assign/note/review flows work by keyboard with visible focus and accessible labels.
- Long Unicode titles/briefs/6,000-character notes and 200-percent text scale do not lose stored text or hide required actions.
- Both appearances, high contrast, reduced motion and collapsed panes remain usable.
- Left sidebar toggles/slides with toolbar/menu/shortcut and remembers state; right ticket/request/details overlay closes/restores focus without reallocating a permanent third column or losing underlying list/drafts.
- Note receipt stays attached to its message with exact per-recipient outcomes; active Codex receipt and held Claude coordinator remain separately visible.
- Related-item overlay Back restores scroll/draft/focus; Escape exits editor before closing; rules/sessions/activity remain secondary.
- Live filter-changing update keeps open task anchored with Moved to status, does not replace it; no disruptive row reordering during selection.
- Every task overlay exposes its contextual action menu; Needs You retains capture; original candidate bytes open in Quick Look or show unavailable before approval.
- Basic bulk commands preview/return per-row conflicts; guarded Undo never erases later intent or reconstructs pruned file bytes.
- Status/text, tags any/all/none, planned/current assignee and Epic/Triage filters combine within the selected project/surface; empty results name the filters and offer Reset. Up to 10 personal views per project save/apply/update without changing project defaults or manual positions.
- Bulk status/tag/planned-assignee/Epic/Triage/archive preview names every blocked row; atomic apply changes nothing on any conflict, and an explicit eligible-only retry uses a new command. Undo binds the original receipt/current revisions, retains later field edits and notes, refuses advanced ownership/review, and never restores claims or cleaned originals. Worker choices exclude personal assistants; whole-ticket human assignment stays under Needs You.
- Offline drafts say local/not sent; no offline authoritative claims or status transitions; reconnect replays before enabling writes.
- Switching task/project preserves the original draft and prevents sending it to the wrong task.
- Multi-question single/multiple choices, custom answer, required fields and optional explanation validate correctly; no default submits itself.
- Finder file/directory/multiple selection, picker cancel, remove/relink, missing paths and reference-versus-copy behave as described.
- Manual command request records human-reported result/output; the app executes nothing implicitly.
- Request edits/cancellation during an open draft preserve it and prevent stale response submission.
- Whole human assignment and a blocking/nonblocking human question appear distinctly; agents cannot auto-claim either through a routing loophole.
- Human start/progress/submit/complete records a real human attempt with normal configured gates, without requiring provider impersonation or an automatic waiver.
- Live updates across windows include taxonomy, counts, messages and delivery; disconnect/replay has no gap or duplicates and never overwrites drafts.
- Service offline and pending delivery explain recovery without losing a saved note or answer.

## Transfer and operations

- All legacy states, aliases, raw actor identities, event order, verdict rounds, rich briefs and long notes survive preview/import/export/restore.
- Source changes after preview, unresolved dependencies, duplicate aliases and missing files are surfaced; wrong-project import rejected.
- Import retry does not duplicate source events, but separate equal-text notes retain their distinct source sequences.
- Historical active rows never become fabricated live sessions/claims. Imported done remains historically done without claiming fresh independent verification.
- Archive/trash/restore preserve relations; active unresolved attempts and accepted children block unsafe removal. The ticket list has no Trash button or Trash sheet; agents can still trash/restore through `task_bulk_edit` (archive kind). Trashed records stay out of ordinary lists/search/Overview/pickup. Unarchive reports cleaned originals without inventing bytes; single-ticket Undo checks the action revision, claims and original availability.
- Own-note correction/retraction appends linked text without rewriting attribution or receipts; trusted owner retraction withdraws future direction action while preserving earlier acknowledgment/work and notifying current handlers.
- Cancel/reopen/reassignment require reasons; status edits cannot release writers. Reopen returns to Queued with old evidence/history retained and fresh completion required. Epic/Triage archive preserves member tickets.
- Owner-only permanent record purge requires a current revision/digest-bound preview, retains a minimal immutable tombstone, incoming relations and shared records, removes exclusive records/grouping, and scrubs event data without deleting sequence rows. Active work, verification, source execution and pending owner requests refuse it. Exclusive managed bytes enter durable post-commit deletion with receipts and fresh ownership checks. Shared, held, backup-referenced bytes and retained captured links' complete target chains stay; existing backups/exports and external/workspace files are never deleted.
- Interrupted write/migration/restore recovers atomically; backup includes committed WAL and managed attachment manifest.
- Config/skill install/uninstall changes only owned entries; relocation and upgrades keep MCP/service paths coherent.
- Agent MCP connection cold-starts the bundled service with UI closed; concurrent starts yield one store/service, dispatch pause survives, and two identical start failures return repair guidance without runtime/store fallback.
- A user-scope MCP registration used by a verified native Codex/Claude conversation in an unregistered folder starts with `service_info` and `project_create`, with no project enrollment or stored credential before creation. Creation accepts only the actual verified existing workspace, refuses overlap/existing registration, atomically registers/enrolls/grants the worker, records agent provenance and replays its original result. The same MCP connection exposes full tools with one list-change notice; CLI creation and later bound calls work too. Root moves, the permission switch and owner answers stay owner-only, assistants cannot create, and revoked/changed/mismatched bindings still stop startup. An installed non-contributor runner creates and fully sets up a synthetic project in an assigned disposable test slot, using `project_create` through that slot’s CLI from an actual authorized empty workspace outside existing roots and Checklist data roots. Verify the slot/build identity first; never create the project in the live installation. Record exact build/results, close the slot GUI and destroy the owned slot with `script/test_instances.py destroy --slot N` after evidence capture. Synthetic projects must be removed with their slot, never retained by archiving. Separately verify the live `project_list` with `include_archived=true` and the live `connections.json` contain no synthetic project or enrollment; record any scope/inspection limitation without claiming a complete inventory.
- Release-build 20,000-task/500,000-event fixture meets measured UI targets or reports the actual bottleneck before release.
- Human/agent local image/file import and preview survive restart; interrupted staged imports/hash mismatch are contained; archive prunes eligible large copies under configurable limits while preserving shared/active/pinned content and all external originals.
- Aggregate archive overflow containing only sub-threshold files is reclaimed under the defined policy, with any protected excess explained.
- Unarchive/export explicitly reports pruned originals; recovery by checksum does not pretend missing bytes are available.
- After first release, Checklist's own project can stage/build/install to Applications once per source fingerprint, resume state and verify the actual installed build; failed/interrupted/denied install and incompatible rollback do not lose production work or trigger a build loop.
- A concurrent source edit during self-build cannot produce a mislabeled build: capture is checked, compilation uses an immutable dirty/untracked-inclusive input snapshot, and install/critique identify that snapshot.

Optional board view, remote/streamed uploads, full atomic split/merge/redaction and enterprise planning are outside v1; absence of these is not a failed acceptance scenario.

The complete first-release promise requires the live messaging gates. If any route remains checkpoint/manual only, publish that reduced capability clearly rather than marking the full specification complete.

## Database and customization

- One authoritative database survives UI/MCP/service restarts; same-key projects remain isolated at FK/query/search/attachment boundaries. Private dedup reveals no other-project content/refcounts or reusable blob paths.
- Crash each file finalization/SQL commit/outbox/cleanup boundary; neither missing bytes reported Available nor a committed command duplicated after lost response. Disk-full/failed draft writes show Not saved; corruption preserves originals and enters recovery.
- Backup's database snapshot and exact object manifest agree while imports/notes/cleanup continue; capture holds/barrier preserve all snapshot bytes, incomplete generations never displace the last good backup. On an owned real-store copy, compare normal note/edit latency with the same commands during managed copying; new immutable imports also finish while copying/verification is paused. An inventoried pending import stage survives its parent commit until copying ends. A newly created report whose transaction rolls back leaves no orphan during capture; committed reports remain and inventoried objects stay protected. Cleanup reports a backup-capture hold without failure counts or repeated wakes; admitted cleanup finishes before the barrier activates, and success/failure rearms its one-shot deadline. A killed capture releases retention without changing its recovery stage, and retry verifies a complete stage or recaptures an incomplete one. Settings shows backup activity and large-store duration guidance. Verify checksums on real restored originals/previews/icons, including hard-link/copy behavior and actual physical space accounting.
- Restore creates a new incarnation, invalidates old grants/claims, reconciles local drafts/cursors, and quarantines restored unresolved deliveries until reconciled; no blind duplicate messages after returning to an older snapshot.
- Project icon symbol/import/size/type/metadata/contrast/fallback/Undo/export/restore works; task archive cannot clean a referenced icon. Future-prefix change never renumbers/reuses old keys, and cosmetics leave review targets intact.
- Optional starters/default views/notification overrides remain project-specific; personal sidebar/window/draft preferences and global backup/store settings remain separate. Quiet OS alerts keep Needs You/live history while personal-assistant subscriptions remain cancelled.

## Public source and authority

- Future adapter IDs are shape-valid data only: absent/unqualified/disabled adapter rejects bootstrap/action. An assistant label or imported settings never install code, enroll a provider or enable Muse. Multiple named assistant principals on one adapter retain separate grants. Assistant-mode assignment/claim/review denial remains fixed.
- External cursors are opaque and bound to principal/project/filter/grant/incarnation; another project's events do not expose numeric gaps. Wrong scope/revocation/restore gives CURSOR_RESET with only authorized snapshot/catch-up. Direction cursors remain task/round scoped.
- Revoke during callback/native submission: cancel unsent/best-effort in-flight work, preserve actual sent/accepted receipts and deny later reads/replay. Never claim already transmitted remote bytes were recalled.
- Public validation selects only generic source/synthetic fixtures/current public images; no real user home paths, native inbox addresses, session IDs, historical probes/private audits or installation grants are included. Public documentation links stay inside that set. Existing local evidence remains private without rewriting its historical facts.
- New-user self-build/install remains off until installation-specific opt-in. A valid maintainer's local grant is not revoked or needlessly re-requested, but it cannot grant another user permission. Public source publication, license selection and public plugin listing are separate actions, not implied by the plan.


- An existing or new actual provider conversation connects automatically on bundled CLI/MCP use, without manual Settings pairing. Bootstrap pins signed native host PID plus kernel start time/execution domain and actual kernel cwd; a wrong host/cwd or revoked context fails. Codex host-exported thread IDs are observations, not signed thread attestation. A separate non-contributor reviewer on the same verified host can claim; the author, delegated contributors and a contributor under a changed label remain denied. Cross-check Claude native registry PID/session/workspace/socket where used.
- Use in Codex opens a prepared native composer; user Send is required. A separate explicit native Codex creation test returned a real thread and automatic context-only ticket association; it is not assignment/claim. Claude keeps its honest fallback until automatic native creation is qualified. Opening a window or copying a brief alone proves none of these outcomes. Current/prior actual worker session status/checkpoints/recovery/actions are attached to their tickets; no global worker Connections catalog exists. The current app has no assistant settings/sidebar/grant UI. Idle Codex push and exact child push need independent receipts; cancelled Dot qualification is not planned release work.


## Cancelled personal-assistant qualification (historical reference)

These are historical checks for cancelled scope, not planned qualification, release prerequisites or runnable setup instructions. Assistant controls are absent; development relay grants remain disabled and the plugin uninstalled. A new separately authorized proposal would need reviewed owner controls and a supported, terms-compliant host route. Local component results, or a Dot opening a Work thread without a completed result, do not pass these gates.

- The actual assistant plugin resolves explicitly granted projects without pretending to have a workspace; duplicate keys cause project clarification before writes. Requested creation returns one Draft; requested note stores actor assistant, request correlation and actual handler delivery. No human_ui/approval/owner-read fabrication.
- assistant is absent from assignees/coordinator/provider-policy/active work lanes, and crafted assign/claim/delegate/review/answer/waiver/complete/rules/purge/build calls fail. Read-only grants reject create/note even with cached tool discovery. An incoming event or agent message cannot authorize spontaneous ticket writes.
- Qualified MCP Events subscription delivers an actual matching event through a verified signed callback and results in an actual assistant report. Record callback acceptance, assistant acknowledgment and report reference separately. A resource hint or socket demo alone does not pass this gate. Prove SDK version negotiation with other enrolled clients.
- Notification summaries are server-generated from allowlisted metadata; a note/answer/tool output containing local paths, secrets or injected notification instructions never appears in outbound preview. Generic fallback plus authenticated context supplies details.
- Revocation, changed callback, expiry, repeated/out-of-order event, lost reply, self-originated notes, offline Mac and host unavailability preserve truthful status without data leak, duplicate note/ticket, echo loop, repeating polling or model launch. No actual subscription is created by this acceptance specification.
- Named discovery includes only existing verified host-owned personal assistants, never manual/unverified profiles or ordinary workers. Checklist offers no create/rename/personality editor. Verified host renames update current labels while historical snapshots/authors remain; duplicate names disambiguate by granted project/host/surface. Names and imported metadata grant no access.
- After first explicit Checklist context, contact Rowan uses the app's resolver and current opaque recipient target. Test duplicate names, renamed/reused labels, changed generations, unsupported route and revoked target. Task contact shares task history; a no-ticket contact has a scoped project conversation without task/assignment creation. No alternate-channel/model fallback.
- Conflicting duplicate project grant entries reject the entire update, with expected grant revision/generation. Host-identity/adapter changes never transfer old grants, subscriptions or pending route authority silently.
- A notification transport failure cannot emit a delivery_problem callback through its own failed route; causal dedup prevents secondary loops. Reconnect retains source receipts but coalesces obsolete same-ticket/cause events into one bounded catch-up report, preserving unanswered requests and original times.
- A ticketless message's body/history survives reconnect through participant-scoped inbox/history_list(conversation_id); another same-project nonparticipant cannot read it merely by knowing an assistant/conversation UUID. The exact direct delivery can be acknowledged without a fabricated ticket or event subscription.
- Requested question/reply uses an original-authorized exact single reply allowance; simultaneous duplicate reply consumes it once. A reply cannot mint another allowance, work assignment or spontaneous ticket mutation. Worker project messaging consent and assistant send/receive grant are checked separately from read access.
- receive_notifications=false leaves an authorized direct requested reply available when receive_messages=true; receive_messages=false/revocation blocks new direct receipt. Native push/contact-event choice remains explicit, no hidden ticket subscription. A linked task/direct event notifies once via shared message/cause correlation.
- The cancelled proposal required assistant setup to use supported package commands and reviewed trusted owner scope controls; those controls are absent from the current UI. The retained historical stdio MCP mapping uses `--assistant --project @enabled`, selects only current owner-enabled project relay grants, revalidates all grant/policy revisions per call and rotates authority on reconnect when the set changes. No fixed project label or general worker access is baked in.
- Proper Dot access requires the actual Dot to discover the local plugin on its connected Mac, make an authorized scoped call and return the result. Local plugin installation, skill availability and a local Codex helper test are component evidence only. Do not claim account-global/cloud discovery, verified named Dot identity or unattended events from them. The cancelled proposal retained the local helper candidate and considered a separately selected authenticated outbound alternative after a concrete first-party local-forwarding limitation. These historical checks authorize no further route investigation or network exposure.

## Directed Triage passes

- An already In Progress ticket can join an Implementation Triage without losing its actual claim or Epic. An actual authenticated Codex/Claude coordinator can start, checkpoint and finish orchestration without claiming member work on anyone's behalf.
- Owner decision, 22 October 2026 (CL-215): Active sections, counts and filters in the app and agent reads use only the ticket's own active status category (In progress). An orchestrated Triage with Queued, Review and In progress members shows only the In progress member under Active; Queued, Draft, Review, Blocked, Parked and Done never enter Active through membership. Verify the same counts without orchestration and the sidebar counts. Triage rows and detail still show orchestration and its actual coordinator. Advisory `active_attention` remains separate for work health. Ended or unknown orchestration remains recovery-required; timeout never invents completion.
- Implementation and Review Triages remain separate. Submission leaves the implementation pass; review outcomes leave the review pass. Current exact target/gate guards apply to each ticket.
- In a mixed review result, complete passing tickets independently under the default and retriage only failed or remaining work. An explicit project override may hold passes but never reimplements them or weakens their gates.

## Active work health

For [work health](work-health.md), verify 20-minute defaults and a 15-minute override; enable/pause and retained deadlines; current implementation/review and unclaimed actively orchestrated Triage members; accepted-child progress versus metadata/liveness/unchanged checkpoints; known waits/jobs; exact-handler request and truthful delivery; grace/no-response/restart deduplication; current and replaced-owner late replies; unchanged claims, writable scopes and Triage membership. Component fixtures are bounded and deterministic. Installed synthetic MCP/native visibility and actual qualified host pickup require separate observations. By owner decision (22 October 2026, CL-129), sleep/wake overdue recovery and backward wall-clock recovery are qualified by the deterministic WorkHealth component tests `testWorkHealthInactivityGraceAckIsNotResponseAndNoAuthorityChange` and `testWorkHealthPauseResumeAndBackwardClockRebaseWithoutDuplicatePing`, respectively: installed observations would require Mac sleep or a system clock change that the owner declines and agents may not make. No model runtime or assistant qualification is implied.

## Read-only provider message readiness (CL-37)

On the exact installed target, Settings → General → Message readiness must show the selected project and actual ticket handler when observed, candidate source paths/values, time and explicit unavailable live version/policy inputs. Refreshing a personal accept with unobserved managed/flag/host inputs must remain Unknown. In a clearly identified isolated qualification context, inspect held/refused, invalid, absent, unreadable and unsupported sources; name the responsible known path and project/admin repair. Check stricter project/local and managed/session/user precedence, unset parity and invalid-value rules with component fixtures.

Change project/recipient and deliver a later host hold while a Refresh is pending: the earlier observation must disappear and a late old response must not fill the new context. Guidance must show the top-level user-scope key and all-local-senders consequence, conditional terminal /config option and administrator/project remedies. Hash inspected provider files before/after; read/Refresh/guidance must change no settings/permissions/grants and launch no provider/model. Codex must say Pickup only, consistent with service_info and existing receipts. Queue/resume/notify/hooks must create no native-wake or success claim. Exact MCP acknowledgment retains its meaning. Automatic durable writes and native Codex wake are deferred. Close qualification apps and restore the real Checklist window. These display checks do not claim a new native delivery qualification.

- CL-193: automatic project cleanup without preview or activation must preserve Done records/file identity while deleting only exclusive managed bytes, purge only unchanged Done/Canceled tickets after the configured days (default 15), and preserve open, active, held, external and shared targets. Prove scoped settings/receipts, exact N-day equality, independent rule switches, automatic first startup, concurrent ordinary read/write response within a stated bound on tens of thousands of managed objects, stale-preparation rejection, bounded backlog progress, restart and rollback boundaries, late reopen/hold/settings races and backup after retained capture metadata loses its bytes. Qualify native settings and first automatic selected/removed-byte receipts and service responsiveness during that pass separately on the installed exact build.


### CL-258 / CL-6 backup and disposable restore

- An enrolled worker creates and replays a complete backup in the published or named qualification folder with agent provenance; owner-only project policy, assistant role, arbitrary path, traversal and no-follow violations refuse.
- A current-schema agent snapshot seeds an authorized disposable slot with identical database bytes/schema and no migration.
- Owner-only native preview verifies every record family/table and managed file before confirmation. Wrong schema, changed digest, missing file or checksum failure leaves the working store and backup intact and publishes no candidate.
- A successful restore produces a separately published data root with a new incarnation. Old cursors/tokens/native registrations fail, active work requires explicit recovery, uncertain/pending deliveries stay quarantined across restart, and acknowledged history and immutable media/evidence remain unchanged. No credentials, model launch, automatic reconnect or message resend occurs.
- Qualify exact composed startup/protected pre-upgrade backup, agent backup and disposable restore on an owned consistent real-size store copy. Record complete copy/verification/restore timing against the shared 1,800-second budget. Native UI, installed IPC and actual bootstrap observations remain separate from Core fixtures.


CL-6 / CL-258 rework observations:
- On a disposable installation, Storage's restore preview shows source installation/store, backup folder, capture/verification times, contents and missing-content reasons before confirmation. An older backup labels absent capture time as unknown. Cancel or failed verification leaves the working store intact.
- Storage shows last verified backup/rehearsal and timestamped retained logical lengths/allocated blocks, with older measurements unknown and exclusive/reclaimable physical space unmeasured. Restore-copy verification must not imply native startup or reconnection.
- Core and actual MCP `tools/call` tests cover an allowed agent backup, owner-only project policy, assistant refusal, invalid destinations and a worker note committed during the production backup route. The verified captured database excludes the later note. Portable metadata exports contain no structured credentials/native authority while retaining historical actors and note text.
