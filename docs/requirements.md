# Requirements coverage

This table maps the target to design and release evidence. Personal-assistant/Dot integration was cancelled on 22 October 2026 (CL-3 and CL-22), with no active assistant UI/setup or release dependency; its rows are historical reference, not planned work. The [implementation status](implementation-status.md) records existing local source support and remaining native/release qualification; no row alone claims every proof has passed. Owner means the human operator of a local single-human installation, not a hard-coded developer identity.

| Requested behavior | Design location | Proof required |
|---|---|---|
| Database and storage plan | database-storage.md, architecture.md | Composite project isolation, SQLite/outbox transactions, filesystem crash/backup/restore/cleanup and disk-failure evidence |
| Project icon and useful customization | project-customization.md, ../contracts/project-settings.schema.json | Icon import/Undo/fallback/export, retained icon through archive, new-key prefix only, personal/global setting separation |
| Cancelled personal-assistant ticket/follow-up plugin (historical reference) | assistant-plugin.md, ../plugins/checklist/README.md | Canonical checklist-assistant skill; real qualified host tools, requested capture/notes, event/report receipts; assistant-only access excluded from work assignment/review |
| Cancelled named-assistant contact after initial context (historical reference) | operations.md, agent-profiles.md, mcp-contract.md, ../skills/checklist/references/coordinate.md | Scoped name resolution, duplicate-name disambiguation, opaque current targets, truthful delivery and task/project history; no assignment, automatic ticket or alternate channel |
| Cancelled existing-assistant design; separate future provider adapters | agent-profiles.md, integrations.md, domain.md | Verified existing host identity, no app-created persona/named worker, host rename history, worker-session separation and unavailable future adapters |
| Automatic actual-thread connection and honest provider handoff | project-setup.md, implementation-status.md, integrations.md | Bundled CLI/MCP bootstraps actual host/session/workspace; workers are ticket-attached; no assistant controls are active; GUI composer needs Send; separate real Codex native creation/context attachment observed; association is not assignment/claim |
| Global macOS checklist with built-in MCP | architecture.md, mcp-contract.md | Signed app, shared service, both real clients can use tools |
| Each project has a separated checklist, duplicate names/keys | domain.md, project-setup.md | Cross-project ID/search/relationship containment |
| Active item names its actual session | domain.md, integrations.md | Stable native/child IDs, exclusive claim and real observations |
| Review done versus ready pickup | domain.md, interface.md | Separate reviewer claim, target-bound verdict and derived eligibility |
| Setup/edit/delete documentation and skills | project-setup.md, operations.md, ../skills/checklist | Readable guides, skill validation, future integration exercises |
| Claude ↔ Codex and subagent communication | integrations.md, mcp-contract.md | Both directions and exact child receipts in native clients |
| Retained communications, notes, task context | domain.md, architecture.md | Crash-safe history/outbox and context handoff |
| Cross-Epic Triages: one orchestrator's work list or a plan | domain.md, interface.md, triage-orchestrators.md | One Triage per ticket, derived shared/Mixed/Empty status, atomic guarded group transitions, membership kept through status changes with departure only on Done or canceled, another orchestrator's handling or removal, and immutable batches; leaving never changes primary Epic |
| Epics as stable project subprojects by task type | domain.md, operations.md | Contained related tickets, one primary Epic, atomically reconciled moves; separate from Triages/tags |
| Easy navigation and image-generated design | interface.md, design/README.md | Revised production-task and exact-candidate request concepts; eventual keyboard/resize/appearance checks |
| Owner note immediately sent, visibly from owner | integrations.md, interface.md | Trusted author, immediate outbox, actual delivery/ack states |
| Human-assigned tasks separately shown | interface.md, operations.md | Your Tasks distinct from agent queue and question inbox |
| Questions with buttons/custom options | interface.md, ../examples/human-request.json | Typed forms, revision-safe answers and custom response |
| Finder file/directory references + explanation | interface.md, architecture.md | Native panel/grants, reference default, requester receipt |
| Later one-way transfer from existing checklist formats | migration.md | No source changes now; versioned format readers, synthetic public fixtures, staged preview, full provenance and round-trip integrity |
| Initial Codex/Claude work, future other clients such as Muse | integrations.md, architecture.md | Capability registry without hard-coded provider task state; future adapters require qualification and explicit enrollment, no hidden runtime |
| Editable per-project orchestration/assignment rules | policies.md, ../examples/project-policy.json | Versioned preview, runtime effects and authority checks |
| Custom statuses, including multiple Parked types | statuses-tags-live.md | Stable project status IDs, guarded semantics, rename/retire/remap and migration preservation |
| Ticket tags | statuses-tags-live.md | Many-to-many project tags, any/all/none filters, history and bulk updates |
| Live updates | architecture.md, statuses-tags-live.md | Committed changes appear across windows; reconnect replay, truthful offline state and preserved drafts |
| Left sidebar slides/toggles in and out | interface.md | Always-visible toggle/shortcut, remembered state and independent list/overlay behavior |
| Right panel is a slide-in overlay for tickets/forms | interface.md | No fixed third column; close/Escape/focus/draft/list preservation across detail types |
| MCP bundled into app; agents start it as needed | architecture.md, project-setup.md | UI-closed cold start, concurrent singleton handshake, diagnostic start/status and clear failures |
| Owner/agent images and files on tickets | attachments.md | Scoped local imports, previews, checksums, retained attribution and authorized reads |
| Clean large files on archive | attachments.md | Configurable threshold/budget, shared/active/backup holds, explicit pruned metadata, no external deletion |
| Optional Checklist project and automatic Applications build/install | self-hosting.md, build-plan.md | Installation-specific helper/destination grant; staged checks, safe replacement, installed-version critique and resumable self-development; existing local grants remain valid |

Additional approved critique fixes are part of the baseline: cheap Draft capture; optional game/app work starters; compact project brief/pinned decisions; exact candidate/build approvals; mixed-capability requests with one blocking request per task; anchored live rows; basic bulk/guarded Undo; canonical writable-root isolation; atomic scope expansion; one active target-bound review and stable findings; all-gates triage exit; limited policy presets; local import only; installed_build_verified completion gate. Their observable checks are in acceptance.md and the staged first production slice in build-plan.md.

A separately authorized probe completed one corrected native Claude SendMessage round trip to a temporary receiver. It proves that route/version, not automatic idle Codex/subagent delivery or qualification of the current MCP service. Reusable release evidence must come from explicitly enrolled synthetic sessions; see integrations.md.

Preparation completed in this folder: written design, generic transfer specification, generated concepts, JSON examples/schemas, instruction snippets and portable skill draft. The product runtime exists locally; full native qualification and any real source migration remain separate.
