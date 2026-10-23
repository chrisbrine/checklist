# Project customization

The development build provides bounded identity, workflow, capture, view and alert settings. [Implementation status](implementation-status.md) records remaining release qualification. Each game or app gets a recognizable project and a few useful defaults. The owner can leave every setting at its production preset and start with a title and project.

## What belongs to a project

Project Settings opens from the project menu in the same right-hand slide-in overlay as other detail. Start with **Identity**, **Work**, and **Storage** sections; advanced diagnostics remain behind contextual links. The ordinary identity form shows name, icon, accent and key prefix with a live sidebar preview.

| Element | Useful customization for games and apps | Source of truth |
|---|---|---|
| Identity | Display name, project icon, restrained accent and future ticket/Triage/Epic key prefix | Versioned project settings |
| Production context | Short brief and pinned decisions, with links to existing design/source documents | Versioned project context; settings references its revision |
| Capture starters | Show relevant Work, Bug, Asset, Playtest and Question starters; optional short brief/outcome prompt wording | Project settings; Work remains available and title-only capture stays valid |
| Work defaults | Assignment preset, participating providers, task-kind exceptions, independent review/completion gates and human-contact routing | Canonical [project policy](policies.md), not another settings copy |
| Statuses and tags | Names, colors, order and several Parked types; independent ticket tags | Canonical [taxonomy](statuses-tags-live.md), not presentation labels with hidden behavior |
| Initial task view | Group by status, epic or nothing; order manually, by priority or recent update | Project presentation defaults; an owner's personal saved view takes precedence |
| Owner alerts | Inherit app preference, actionable Needs You only, or quiet OS alerts | Project notification override; inbox visibility and delivery receipts remain truthful |
| Attachment retention | Large-file/archive-budget thresholds and Keep originals preset | Policy storage section and individual attachment holds; see [attachments](attachments.md) |
| Worker session details | Inspect current/prior actual worker attempts, capabilities and recovery from the ticket | Internal session/attempt records; no global worker connection catalog |

No project setting changes protected ownership, human authorship, evidence or delivery semantics. An accent never means Working or Verified. Disabling a starter hides that capture shortcut; it does not remove that kind from existing tickets, change policy eligibility or invalidate a request. The starter's brief/outcome hints are optional prompt text, not new mandatory fields or executable instructions. Work is the default fallback if a personal last-used kind becomes unavailable.

Changing a key prefix affects **new tickets, Triages and Epics only**. Existing keys, aliases, links and external references keep their original values. Separate project-wide monotonic counters for tickets, Triages and Epics never reset on a prefix change, and retired keys are not reused. Prefixes can match across projects because all resolution remains scoped by stable project UUID. Renaming a project or replacing its icon never creates a new project or changes its root binding.

Enrolled workers may import/clear project icons and change archive storage settings while `agent_rule_changes=allowed`. Icon sources must stay inside the actual workspace and enrolled project; the service reads through a checked descriptor. Root moves and the switch itself remain owner actions.

## Icons that remain readable and portable

Choose a built-in symbol from the supported picker or import a local PNG, JPEG or WebP using Finder, paste or drop. The initial design limit is **5 MiB and 4,096 pixels per edge**, with bounded decoding and a useful rejection message. Normalize a successful import into a metadata-free 256-pixel PNG thumbnail in the managed blob store; retain that thumbnail rather than the large source image. Never modify or remove the Finder original. Animated, vector and active-content formats are outside the first release.

The project-icon record has a stable asset ID, normalized-byte checksum, fallback symbol and accessible label. The active icon holds its thumbnail independently of ticket attachments, so archiving tickets cannot clean it. Replacement commits the new record/reference atomically and retains the old thumbnail during the guarded Undo window. Historical events retain icon identity/checksum even if later retention reclaims an unreferenced old thumbnail. Reclamation uses the normal managed-storage job and respects export/backup/reader holds; it never deletes source files. A missing icon falls back to its symbol and project name, with repair available in settings.

Include the active thumbnail and checksum in a project export. Import verifies the bytes before linking the asset; a missing/corrupt icon produces the fallback and a visible warning without preventing task recovery. A project name and accessible icon label accompany the color; do not rely on color or a tiny picture to identify a project. Check chosen accents for contrast in both appearances, and use the system selection/focus treatment where an accent would be unreadable.

## Project data, personal preferences and local authority

| Scope | Examples | Transfer behavior |
|---|---|---|
| Project data | Identity/icon, starter prompts, default view, notification override; referenced policy, taxonomy and production context | Included in the canonical project export with referenced definitions and available icon bytes |
| Per-user/per-Mac UI preferences | Sidebar visibility/width, window placement, overlay width, last view, drafts, personal filters, snoozed requests | Local preferences; not a project's shared settings or agent instructions |
| Store-wide settings | One database/managed-store location, backup destination/retention, app-level OS alerts | Installation settings; never a project-specific pretend database or an exported machine path |
| Local authority | Finder bookmarks, canonical root grants, native bootstrap bindings, endpoints, credentials and project/role grants (retained assistant grants belong to cancelled scope) | Excluded from export; explicitly revalidate/re-enroll on another installation |

Project defaults seed the task view until the owner saves a personal choice. Later default changes do not silently replace a personal view; **Use project defaults** resets it explicitly. Live cosmetic changes update sidebar/list/detail without losing task selection, focus or drafts. Cosmetic edits do not invalidate work evidence or claims. Behavior-changing policy/context edits follow their existing preview, version and reconciliation rules.

Desktop alerts are off on each Mac until the owner explicitly enables them and macOS permits notifications. While Checklist is open, alerts cover newly observed Needs You/human-assignment items and, when this Mac’s default allows them, actual delivery issues. Initial inbox contents and quiet periods are not replayed. Project Inherit uses this Mac’s app default; Actionable Needs You limits desktop alerts to those items; Quiet suppresses them and removes alerts sent in the current app session. Quiet projects still appear in Needs You, retain actionable counts and in-app failures, and receive live data updates. Permission/notification status stays visible; owner notes still enter the durable outbox immediately. No alert preference authorizes waking a model, enrolling an assistant, scheduled pickup or an external notification service.

## Cancelled personal-assistant customization boundary

Personal-assistant integration was cancelled on 22 October 2026 (CL-3 and CL-22). No assistant settings/sidebar/project-grant controls exist in the current UI, and the development installation's grants are disabled and plugin removed. The following describes the historical identity boundary, not planned features or available setup.

An assistant's name, avatar and personality already belong to its host. Checklist recognizes supported verified identity/display metadata and contact history; it does not create named workers, rename assistants or offer a personality/profile catalog. Ordinary work uses actual Codex/Claude sessions. The [assistant identity guide](agent-profiles.md) defines minimal local records and host-rename continuity; a project setting cannot manufacture or authenticate an agent.

Primary connection happens automatically when an actual provider conversation uses the bundled CLI/MCP, under the supported host identity/bootstrap mechanism. The cancelled design proposed assistant settings for status, permitted-project grants and revoke/disconnect; they are absent from this build. Actual worker details belong to their tickets. Without verified supported assistant identity, named-contact discovery stays unavailable rather than accepting a manually entered name. Real Dot discovery/bootstrap was not qualified before cancellation; ordinary worker MCP access does not qualify it.

The cancelled [Checklist assistant plugin](assistant-plugin.md) would permit read/report, requested Draft creation/notes/messages and selected event reporting. Assistant-only access never becomes an assignee, coordinator, claimant, reviewer, trusted human answerer or project-rule editor. The five per-project grants remain separate from both project presentation settings and the assistant's host persona. An alert preference cannot enroll an assistant or enable push.

Exports preserve necessary historical assistant labels/opaque identity snapshots, never live host grants, endpoints, subscriptions or personality memory. Import does not create an active named agent or map identity by name. Future hosts such as Muse need their own qualified adapter later; no provider can be enabled through a project icon, profile label or settings payload.

## Saving, proposals and validation

Agents apply project settings through `project_settings_save`, `project_edit` and `project_archive` (owner decision, 18 October 2026: Checklist is built for AI agents). Each agent change records agent provenance. The owner can limit a project to app-only changes with the policy switch `agent_rule_changes=owner_only`; only the owner moves that switch. Icon image import and managed-file cleanup remain app actions today. Save with an expected settings revision and a durable command receipt. Conflicts preserve the draft and show changed fields; invalid icons or reference revisions fail without partly changing identity.

The native form saves identity, brief and defaults directly when the workflow matches its saved baseline; it omits the policy proposal and leaves the policy revision unchanged. Workflow changes require a matching preview, then save the settings and previewed policy proposal in one `project_settings_save` transaction. A validation error, stale proposal or revision conflict leaves all of them unchanged. There is no second policy save that can fail after identity already committed. Managed-icon import/replacement remains its own guarded transaction and never removes the Finder original. A prefix change affects future keys, keeps the monotonic counter and leaves existing keys untouched.

Runtime project fields have one canonical source: `capture_defaults` contains `enabled_kinds`, `default_kind` and per-kind `starter_overrides` with optional `brief_hint`/`outcome_hint`; `default_view` contains `group_by` and `order_by`; `alert_override` is `inherit`, `needs_you` or `quiet`. Work remains enabled and the selected default must be enabled. Hints are bounded optional text, not required task fields. The project revision fences the whole save, while settings/context/policy/taxonomy revisions identify the corresponding snapshots. Personal saved views and desktop-alert permissions are separate local preferences.

Workflow includes the shared passing-review default: complete passing tickets independently and work only failed or remaining tickets. A project can explicitly override the batch hold behavior through `review_batch_policy`; protected review and completion gates remain independent of this editable workflow choice. A second explicit override, `release_set_holds: true` (default false), lets a passing verdict name a release set and a reason: the ticket then waits, accepted and held, with that reason shown, until `release_set_complete` completes the whole set through each ticket's normal fresh gates. The hold never reopens or re-reviews the ticket; without the policy, passing tickets complete independently. See [project policy](policies.md).

The [resolved settings schema](../contracts/project-settings.schema.json) and [synthetic example](../examples/project-settings.json) define the portable shape. Canonical policy/taxonomy/context references use the enclosing project UUID plus revision; they are read-only snapshot references, not duplicate editable rules. A coherent export includes the matching snapshots. Runtime validation additionally verifies those same-project revisions, unique starter kinds, selected default availability, normalized icon checksum/limits and any prefix collision. JSON shape validation cannot prove those conditions or local authority.

Release checks must demonstrate icon replacement/export/fallback/Undo, no icon pruning during ticket archive, prefix changes without key renumbering, disabled-starter fallback, independent personal views, quiet alerts with retained Needs You/live state, revision conflicts, and export/restore without credentials or grants. Existing source projects are not edited to supply example icons or settings.

## Review requirement controls

Project Settings keeps review requirements beside workflow controls. The project default can inherit generic acceptance/project checks or use a complete custom rule. Each ticket kind can inherit that default, customize its checks, reject/block guidance and required evidence types, or reset to inheritance. Editing check text preserves its stable requirement identity; adding a check creates a new identity. Other policy settings remain intact.

An untouched generic default does not create a workflow change. Project details still save directly when workflow is unchanged; changing requirements needs a matching workflow preview. Editing requirements or application mode after preview makes the old preview inapplicable. Validation errors and conflicts keep the visible draft. Changed review requirements use future review claims; same-gate active requirement reconciliation remains unavailable and is rejected by the service.

New agent reviews pin the then-current requirement revision separately from their submitted target's gate policy. Active and recorded requirements remain read-only in review details. A preparation preview starts no claim; the actual reviewer refreshes service context after claiming. Historical verdicts show their own stored requirements and never substitute today's project rules. Evidence classes describe selected bytes/provenance, not successful tests, native observations or approval.

## Active work health settings

The native form and agent settings commands expose `work_health_settings`: `enabled` (default true), `inactivity_minutes` and `response_grace_minutes` (both default 20; whole minutes 1–10080). Pause retains requests; resume grants a new observation window. Unchanged saves do not postpone checks. Settings remain subject to project revision/agent-rule authority. [Work health](work-health.md) describes progress, liveness, waits, pickup limits and late-response reconciliation.

**Closed ticket cleanup (CL-193).** The native Project settings section and `project_settings_save` expose `ticket_cleanup` with independent `done_evidence_enabled` and `closed_purge_enabled` switches (default true) and `closed_days` (default 15, integer 1–36500). These defaults run automatically for every project after startup, with no preview or activation. Save either rule or the day count directly with the expected project revision. Pass receipts supply the selected, removed, missing and kept pathname-byte summary. See [cleanup policy, holds and receipts](archive-cleanup.md#done-evidence-and-aged-closed-tickets-cl-193). Agent settings retain ordinary project policy authority; no new owner-only approval or grant is introduced.
