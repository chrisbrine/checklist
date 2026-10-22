# Product brief

Checklist is a native macOS home for independent game and app production. Capture an idea, see who is handling work, answer an agent, inspect a build or image, and find what can be picked up next. Codex and Claude are the initial work providers; personal-assistant follow-up is cancelled, with its generic historical design retained separately. A local development app/service exist; [implementation status](implementation-status.md) distinguishes implemented behavior from the full release target.

In this plan, **owner** means the human operator of this local installation. The first release supports one human on one Mac; it does not imply one particular developer, project, assistant name or workflow.

## The daily workflow

1. Capture a title in the current project, optionally with a note or image. It saves as a Draft immediately. Add a clear outcome and the needed context before marking it Ready; agents cannot claim an unfinished brief.
2. An eligible session claims ready work under that project's rules. The task shows the actual handler, last checkpoint and next action. A human assignment goes to **Needs You → Your tasks**.
3. Notes, screenshots, clips and questions stay with the task. An owner note saves to history and the delivery outbox immediately; saved, held, delivered and acknowledged are different facts.
4. Review names the exact source snapshot, build or asset. Findings stay identifiable across fixes. An approved old image or successful old build cannot approve its replacement.
5. Finish the configured checks, then complete the task. Archive later; explain any removal of large managed originals. An individual ticket status action, even same-status marking, removes it from every current Triage without losing history. Group status changes retain ordinary membership and remove completed tickets on Done; notes and metadata retain membership. A group status change applies to every current ticket through normal guards; one blocker prevents the whole change. Epics remain stable subprojects containing related task types, while temporary Triages may span those subprojects.

This supports bugs, code work, art/audio assets, playtests, design decisions and app improvements without adding a production-management suite. Optional Work, Bug, Asset, Playtest and Question starters give useful headings; no template is required to capture a thought. A short project brief and pinned decisions prevent repeated rediscovery of production direction. These are compact context, not a wiki.

## First complete release

| Need | Product decision |
|---|---|
| Separate games and apps | Recognizable project icon/accent/name and future-key prefix; one local store; strict project scope; stable internal IDs and project-scoped display keys; duplicate keys/titles across projects are fine |
| See useful work quickly | Overview, Needs You and project names; project opens Tickets with expandable Triage rows; Epics is the other project tab; secondary tools live in the project menu |
| Clear work ownership | Separate planned assignee, active implementation/review attempt, actual session and observed presence; no timeout implies completion or abandonment |
| Flexible workflow | Project status names including several Parked types; tags; simple routing/completion presets and limited task-kind overrides; versioned changes |
| Human participation | Direct human assignments and requests with questions/buttons/custom answers, checks, exact approvals, Finder file/directory references and optional explanation |
| Context and immediate notes | Durable history, notes, decisions, identified review findings, delivery receipts and honest native-provider capability labels |
| Group related work | Stable Epic subprojects by task type; one primary Epic per ticket; temporary cross-Epic Triages with immutable dispatched batches; add/remove Triage members without changing their Epic or history |
| Files and visual production | Agent/owner local attachment import, paste/drop, useful previews, exact candidate/build identity and safe archive cleanup |
| Reliable local app | Live updates/catch-up, preserved drafts/focus, backups/export/recovery, guarded Undo and basic bulk edits |
| Cancelled personal assistant follow-up | Historical generic plugin design only; no active assistant UI/setup or current release gate; preserved read/requested Draft/note/event design never confers work authority |
| Existing agent clients | Bundled MCP/service, on-demand startup while UI is closed, portable skills and setup/edit/delete guides; qualified native Codex/Claude routes |
| Later transfer and self-use | Prepare source-format transfer without changing source boards; optionally let Checklist track and build its own improvements under an installation-specific build/install grant |

Project customization stays small: identity/icon/accent, optional starter prompts and initial view, actionable alert override, plus the existing workflow/status/tag/storage presets. The cancelled personal-assistant design retained host-owned names/personalities without a persona editor or named-worker catalog; no such connection or contact UI is active now. Personal sidebar/window/draft preferences and global backup/store configuration stay separate. See [project customization](project-customization.md), [database/storage](database-storage.md) and the [assistant plugin](assistant-plugin.md).

macOS 14+ is the proposed target, subject to dependency/packaging qualification. Use SwiftUI, focused AppKit bridges and one authoritative local SQLite service. Package the MCP executable and service inside the app; no separate Python/Node installation. Closing the UI does not prevent agents from starting coordination infrastructure on demand. No model runs inside that service.

## Keep it small

Do not add sprints, calendars, estimates, time tracking, enterprise permissions, dashboards of metrics, accounts, cloud sync, a web/iOS client, an embedded terminal, an asset catalog, arbitrary automation/routing languages or a second model runtime. A board view, streamed/remote uploads, full task split/merge and conversation redaction are deferred. Basic duplicate linking and linked follow-up tasks cover the practical need first.

Provider, adapter, model, existing host-assistant identity, worker session and access mode are separate concepts. Codex/Claude work is the current qualification scope. Dot/personal-assistant integration was cancelled on 22 October 2026 (CL-3 and CL-22) and is not planned release work. Future clients, including Muse, can gain adapters later without changing task/history identity; they remain unavailable until implemented, enrolled and tested. A host name/personality never selects a runtime, authenticates a session, grants a role or changes assistant-only access. Provider threads connect automatically through bundled CLI/MCP bootstrap; worker status/actions stay attached to the ticket with no assistant Settings catalog. Use in Codex prepares the native composer for user Send and real thread attachment; a draft or unsupported native API cannot count as a created/claimed worker. No marketplace, general plugin framework or custom agent orchestration UI is required now.

## Boundaries and evidence

This remains a single-human, single-Mac plan suitable for public distribution. Existing source boards remain unchanged; transfer needs a later explicit cutover. The local app/service do not imply enrollment of existing source projects, real assistant identity support, a model runtime or a schedule. Private source inventories and local authorizations are not public defaults or reusable permission grants.

A separately authorized existing-session communication probe demonstrated one corrected native Claude SendMessage round trip to a temporary receiver. It does not qualify idle Codex, child routes, restarts or all implemented MCP service routes. Release claims depend on repeatable synthetic qualification of the actual supported adapters; see [integrations](integrations.md) and the [build sequence](build-plan.md).
