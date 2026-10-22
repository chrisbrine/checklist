# Later checklist transfer

**No migration has been performed.** Existing databases, snapshots, Markdown, apps and configuration remain unchanged. This document prepares an auditable one-way transfer; it does not require backward compatibility or continuous synchronization.

## Source formats and adapter boundary

Choose sources at transfer time rather than embedding a developer's project names, machine paths or inventory counts in the product. Initial transfer preparation covers task/event snapshot exports, snapshots with structured work packages, snapshots with separate verdicts or completion evidence, client exports, separate media review stores and multiple verdict JSON layouts (detailed below). Readers for consistent legacy SQLite backups or Markdown/client exports require selected samples and a documented mapping. Exact private source inventories remain local planning evidence, outside the public package.

For example, fictional game projects **Lantern Bay**, **Glass Garden** and **Orbit Workshop** can each contain a `BUG-12` without identity conflict. Their real source roots are selected through Finder at import time; none is hard-coded into an adapter. Acceptance fixtures must be synthetic or explicitly cleared for publication.

A real transfer selects a fresh consistent SQLite backup or owner-selected export and records its hash/time. A checked-in snapshot may lag live work. Never copy a live SQLite main file without a supported consistent backup/WAL protocol, and never treat an earlier planning count as a fixed import assertion.

Each format reader emits the same versioned intermediate bundle: project identity proposal, tasks, source relations, notes/events, verdicts, project context, external evidence references, raw legacy metadata and source-local identifiers. The canonical export format is independent of any source adapter; unsupported inputs produce an actionable report rather than guessed field mappings.

Read in staging with bounded parsing, path containment and no execution of embedded instructions/scripts/HTML. Never run source cleanup hooks. Source records are data and cannot mint trusted human directions, verify sessions or enroll endpoints.

## Additional legacy families for CL-21

The [synthetic import-plan fixtures](../examples/legacy-import-plan.json) cover the following families. They are planning inputs and expected preview behavior, not an implemented reader or a claim of compatibility with an unselected source. Fixture format/version names are fictional. A selected source's exact schema and verdict layout must be identified before a reader is enabled; preserve and report unrecognized shapes without guessing. The private inventory remains outside this document.

| Family / synthetic case | Values to preserve and preview |
|---|---|
| `snapshot-events` | Snapshot envelope `meta`, `items`, `verdicts`, `events`; keep source version, sequence, timestamps and raw fields. |
| `snapshot-completion` | `completion_evidence` instead of `events`, plus legacy `completion_overrides`; preserve evidence and override history separately. Missing events mean unavailable event history, not zero historical activity. Never manufacture event sequences from evidence array positions. |
| `event-actions` | `owner-override`, `tidy`, `remove`; retain raw action, actor, time, reason and referenced source ID. An override is historical attribution, not a trusted owner waiver. Tidy is not permission to clean files; remove is not an instruction to delete a destination ticket. A removed ID without an item stays an unresolved historical reference, even when no originating CLI command exists. |
| `role-authors` | `updated_by` and `agent`, including free-text role/batch names such as `implementer batch amber` and `reviewer round 2`; keep exact strings as historical role hints, never resolve them to authenticated sessions by name. |
| `client-export` | claude.ai-style fields `who`, `doneBy`, `prevState`, `after` and states `you`, `later`, `todo`, `doing`, `running`. Preserve all originals. Preview `you` as owner-intent/unverified, `later` as deferred, `todo` as queued and `doing`/`running` as historical active work needing reconciliation. `doneBy` does not authenticate an author; `prevState`/`after` stay raw transitions/order references until the selected schema establishes their types and meaning. |
| `note-substates` | Preserve complete notes including `ready for integration:`, `PAUSED by the owner`, `ACCEPT ... HOLD`, `Split into X, Y`, `Waits for X`, `Round N` and `P1/P2 file:line`. Preview integration/hold/pause, successor/prerequisite and round/finding hints separately from the primary state. Do not silently change status, create a release hold or gate, authenticate an owner instruction or turn a textual reference into a resolved relation. |
| `media-review-store` | Separate animation/take/per-direction, sound and story reviews, with store version, rounds, content signatures and source-local IDs. Namespace them separately from task IDs and link only through explicit mappings. Preserve every round, direction and signature algorithm/value; unknown algorithms or unavailable originals stay explicit. A legacy signature alone cannot mint a current target fingerprint or approval. |

### Verdict layout families

CL-21 must dispatch by explicit selected format/version and validated structure, not a filename such as `verdicts.json`. At least five distinct layouts need separate shape handling. The fixture supplies these five representative synthetic layouts; their field spellings do not assert the exact layouts of any private source:

| Synthetic shape ID | Example layout | Preview requirement |
|---|---|---|
| `single-verdict` | `{"task":"DEMO-1","verdict":"PASS","reviewer":"reviewer batch amber"}` | Retain the single verdict and free-text author. |
| `verdict-list` | `[{"task":"DEMO-1","lane":"build","result":"PASS"}]` | Retain each entry and lane; never collapse repeated rounds into the last entry. |
| `keyed-verdicts` | `{"DEMO-1":{"review":"REJECT","reason":"Visible seam"}}` | Retain the object key as source task reference, raw verdict and reason. |
| `round-envelope` | `{"rounds":[{"round":2,"verdicts":[{"task":"DEMO-1","outcome":"EVIDENCE_GAP"}]}]}` | Retain nesting, round and evidence-gap/not-run values without converting them to passes or code failures. |
| `direction-verdicts` | `{"take":"take-a","round":2,"directions":{"north":{"verdict":"ACCEPT","signature":"legacy:abc"}}}` | Retain take/direction/round/signature; reconcile against the separate media store, not a task matched by title. |

Every reader preserves the original payload, source-local identity or JSON location, time/author/lane/round when present, raw outcome and external evidence references. Missing values remain missing with preview warnings. Conflicting or unknown outcomes and conflicting layouts require an explicit mapping; no historical verdict becomes a fresh gate pass. Repeated task IDs across rounds are history, not duplicate-task merge instructions.

### Synthetic fixture exit checks

The fixture's `cases` pair raw `input` with `expected_preview` obligations for every family above; `verdict_shapes` contains the five layouts. CL-21 reader tests must compare preservation and diagnostics against those obligations, including missing events, deleted references, unverified authors, ambiguous sub-states and missing media originals. These fixtures prepare coverage; successful JSON parsing does not establish import/export behavior.

The `backup-selection` case deliberately gives a consistent backup and an older snapshot different counts. Preview must report the chosen source's actual counts/hash/time and the discrepancy, require explicit source selection, and never merge sources or assume either count is authoritative merely because it is larger. Actual transfer still requires a fresh consistent backup or explicitly selected export as described above. No private inventory count is a fixture invariant.

## Mapping

| Legacy value | New destination |
|---|---|
| Board/database identity | Explicit destination project UUID; root mapping shown in preview |
| `id`, `label` | Project-scoped key/aliases, with raw originals; case/alias conflicts surfaced |
| `title`, `detail` | Title and preserved Markdown brief; optional extracted structured acceptance with original retained |
| `state=queued` | Open/queued, no live claim |
| `state=active` | Open/implementation, imported historical attempt, recovery required; never invent a currently running session |
| `state=review` | Open/review with imported evidence/verdict history and readiness unknown until reconciled; no invented reviewer |
| `state=blocked` | Open/blocked with original reason; any apparent ownership remains historical/unverified |
| `state=parked` | Deferred; no automatic queueing |
| `state=done` | Done with imported completion provenance; do not label newly verified or reopen merely because imported |
| `state=cancelled` | Cancelled, preserving reason and author attribution |
| `state=split` | Superseded plus split-into links where resolved; unresolved successors remain explicit warnings |
| `tag`, `plan` | Historical actual provider and planned assignee separately; Owner maps to human intent, not an authenticated identity |
| `area`, order | Original ordering/legacy area; suggest epic or deferred disposition only after preview |
| Parked subtypes and future source tags | Preserve distinct source values; propose separate custom deferred statuses and project-local tag IDs; never flatten several Parked types into one |
| `depends_on` free text | Explicitly mapped `depends_on` edge; unknown IDs remain unresolved with original references and, where required, block claim, pickup and completion (never Ready or queueing) |
| Explicit parent/child, duplicate or successor reference | Stable same-project typed relation and source alias IDs; preserve original history, reject cycles/foreign IDs, never infer identity from title |
| Latest `note` | Latest-note projection; avoid manufacturing a second message when an event already supplies it |
| Events | Source `(source_id, event_seq)` provenance, original time/actor plus new store event ID/order |
| Verdicts / lanes | Historical review records and lane metadata, linked to source sequence; no fabricated current content fingerprint |
| `top_note` / owner decision log | Project brief/pinned-decision candidates and linked source history; include adopted decisions in task context while preserving source origin without elevating free text to authenticated owner commands |
| Relative evidence paths | Root-relative references, captured source hash where possible, missing-file/relink preview |

Preserve structured Plan/Kind/Current/Remaining/Acceptance/Evidence/Limits fields and work-package labels when present. Keep planned and actual provider identity separate, retain every review round/lane/event sequence, and retain complete long notes even when previews collapse them. Unknown fields stay in raw legacy metadata with a visible mapping report rather than disappearing.

Group-like source rows and free-text triage areas remain legacy task records initially. Preserve several Parked categories through explicit custom-status mappings, including source area/reason distinctions that encode a subtype. Suggest stable Epic subprojects by task type and separate temporary cross-Epic Triage memberships as explicit preview operations; dependency edges must not silently become triage membership. Decision logs, batch/integration/review records and relevant files outside the task database belong in the source manifest too.

## Owner workflow at transfer time

1. Select source and destination project. Confirm root mapping and consistent source backup/export. Read only the selected sources.
2. Build a staged preview. Show source hash/schema, entity counts, duplicate keys/aliases, missing evidence, unresolved edges, large notes, historical active work, and all proposed mappings. Show what will remain a linked document versus copied content.
3. Resolve identity conflicts within the destination project. Identical keys in other projects are allowed. Do not merge tasks by title. Reject overlapping writable roots across projects after physical-path/case/alias normalization; preserve shared read-only references without granting another write scope. Review suggested epics/triages separately from plain data preservation.
4. Pause dispatch for the destination only, establish a quiescent source checkpoint if live work still exists, and reconcile historical active/review rows. Imports do not inherit live locks. The owner chooses the actual cutover time.
5. Commit the selected import atomically with expected destination revision and unchanged source hash. Keep source-ID uniqueness so retrying the same import receipt is idempotent. If the source changed after preview, regenerate the diff.
6. Verify counts, source event coverage, dependency resolution, long-note hashes, verdict history, project brief/decision context, external file references and representative tasks. Use the app to inspect examples from every legacy state, including several Parked subtypes. Historical review approval without an immutable original target remains historical, not a newly verified current approval.
7. Export/restore-rehearse the new project. Change the old project's agent instructions/tools only as a separate explicit cutover action. Keep the original board read-only for comparison until the owner retires it.

Rollback removes only untouched records created by that receipt; if work/messages changed since import, preview compensating archive/reconciliation instead of deleting new work. Import never writes back to the old checklist. Source files and old backups remain available. A repeat source note with a different sequence is a distinct historical event; deduplicate by source identity, not matching text.

## Canonical transfer bundle

Use a directory or zip with `manifest.json`, versioned project/task/event/message/review/policy records, file-reference manifest, optional managed attachments, and checksums. Export secrets, claim tokens and socket endpoints **never**. Include original source IDs, actor strings, timestamps, aliases, ordering, unresolved mappings and import receipts so a later audit can explain every row.

Do not export a live claim as reusable authority. Restoring or moving a bundle records old sessions as history, fences old tokens and requires new enrollment. A moved file reference is relinked through Finder. The selected initial format readers are release work after the coordination core passes; a demo needs synthetic fixtures only. No public-source compatibility claim is made without a versioned fixture and successful import/export checks.

The normal UI stays simple after transfer: imported task keys/statuses/tags and short summaries appear in the project list; legacy fields and raw events are expandable supporting detail. Existing tasks do not need to be rewritten into the optional Work/Bug/Asset/Playtest/Question templates. Preserve their full source brief and acceptance where present; sparse queued tasks can remain Draft until an authorized handler clarifies them. An exact imported attachment/build fingerprint can be retained as provenance, but import alone never grants a fresh review pass or receipt.

Canonical exports include project identity/settings and their current icon copy/checksum plus matching policy/taxonomy/context snapshots. Local roots/credentials/provider or assistant pairing/subscriptions do not travel as usable authority. Imported icon loss falls back visibly; historical assistant notes retain assistant provenance and requested-source references without granting human authorship or live access. See [customization](project-customization.md) and [storage](database-storage.md).

The implemented owner-only relation transfer command is documented in [ticket relations](relations.md). It imports stable relation/alias records only after task IDs have been explicitly mapped; it does not read external projects or provide whole-project migration. Exports retain removed edges and retired aliases as history. Missing targets retain their original ID/reference as unresolved records rather than being matched against a title or silently dropped; required unresolved prerequisites block claim, pickup and completion; they never block Ready or queueing. A mapping/import failure is atomic. Full source-format readers and whole-store restore remain separate work.
