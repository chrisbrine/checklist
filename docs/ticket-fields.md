# Ticket fields and prerequisite handling

References in agent notes, checkpoints, messages and final reports use `KEY "Title"`; use `KEY "Name"` for Triages and Epics and add the project name when the scope is unclear. Tool arguments keep stable IDs. Triages use `PREFIX-Tn`, Epics use `PREFIX-En`, and their counters are independent of ticket numbering. Service-rendered text removes control/format characters and paragraph separators, bounds names/titles to 160 characters and 640 UTF-8 bytes and keys to 80 characters and 320 bytes, then JSON-quotes titles. A custom key outside letters/numbers/`-_.` is JSON-quoted too.

Ticket fields describe facts the service must validate or agents must select reliably. Notes and the brief carry rationale, context, alternatives and open-ended decisions. Typed relations are the canonical dependency store; text that mentions another ticket never creates a prerequisite by itself.

## Required and optional information

| Information | Draft capture | Ready | Queue / pickup | Review | Completion |
| --- | --- | --- | --- | --- | --- |
| Project and title | Required; the project scopes identity and the title makes capture usable | Retained | Retained | Retained | Retained |
| Requested outcome in brief | Optional | Required, so a handler knows the intended result | Required for pickup through Ready; queueing alone does not make a Draft Ready | Included in the exact acceptance revision | Current submitted acceptance must still match |
| Acceptance criteria | Optional | Optional explicit checks; a concrete brief remains required | Included in context when present | Reviewer checks the captured criteria and target | Each configured gate must pass for current acceptance |
| Kind | Optional; defaults to Work | Select only when its starter or policy helps | Effective kind policy applies | Captured kind policy determines gates | Captured/reconciled policy determines gates |
| Planned assignee | Optional; unassigned is valid | An explicit agent exception must name an eligible provider/session and record a reason | Actual caller role/session/grants are validated; human assignment remains separate | Actual reviewer identity and independence required | Actual authority and all gates required |
| Required prerequisites | Optional typed same-project links | Not required: a refined brief can be Ready while prerequisites are open | Queueing and Triage planning are allowed; required links gate pickup and claim | Claiming review still uses dependency guards | Required prerequisites are rechecked |
| Priority, tags, Epic | Optional | Optional | Hints/context; never authority | Context only | No invented requirements |
| Starter fields (`starter_fields`: Bug reproduction/expected/actual; Playtest build/platform/clip) | Optional; capture offers them for that kind only | Optional; the brief still carries the outcome | Included in task context when present | Context for the reviewer | No invented requirements |
| Triage | Optional temporary phase grouping | Optional | Grouping does not grant a claim | Separate Review Triage; exact per-ticket results | Passing tickets complete independently |
| Evidence / attempts / checks | None required to capture | None required to prepare work | Real claim and bounded scopes precede actual work | Immutable target, exact gate/request and independent review identity required | Current evidence, accepted gates, resolved findings and applicable human/direction dependencies required |
| Notes / decision rationale | Optional | Add useful context without making fields compulsory | Preserve source and full history | Link findings/dispositions to exact evidence | History remains retrievable |

Draft readiness means the brief still needs refinement; Ready means it is refined. Prerequisites never decide readiness (owner decision, 18 October 2026, CL-133). Queueing is a status action. It can queue a Draft for later preparation, and it accepts tickets with open prerequisites so a planned Triage can order them. Only Ready tickets whose required prerequisites are Done can be picked up or claimed. A prerequisite reopening or being canceled changes the dependent's derived eligibility immediately; it does not silently rewrite the dependent's status, readiness, brief, or revision.

## Canonical prerequisite view

Create or remove `depends_on` links through the revision-checked relation command. The source is the dependent ticket; the target is its prerequisite. IDs are stable and project-scoped. Required links block work until the target is Done; an optional link retains a useful dependency reference without blocking. Canceled, trashed, superseded and unresolved targets do not satisfy a required link. Archived Done work remains satisfied. Cross-project links and dependency cycles are rejected atomically.

Every task projection, including `task_context.task`, derives:

- `prerequisites`: all outgoing `depends_on` entries, including optional and satisfied links. Each carries its relation ID, required/resolved/satisfied flags, and the target's stable ID, display key, title, revision and current status when resolved. Missing imported references retain their legacy reference without inventing a target ID.
- `prerequisite_ids` and `required_prerequisite_ids`: convenient resolved-ID arrays derived from those same links. They are projections, not separately editable fields.
- `prerequisite_blockers` and `prerequisites_satisfied`: only unmet required links affect blocking.
- `queue_eligible`: dependency/disposition/visibility/active-claim conditions for an explicit queue action.
- `pickup_eligible`: shared readiness/status/visibility/claim/dependency conditions. A real pickup also checks the caller's project grant, current session, policy/provider, assignment and reservation capacity. This flag does not grant authority or launch a model.

The relation context contains the same derived eligibility. The existing related-ticket editor adds/removes links and shows whether each outgoing prerequisite is satisfied. Related, duplicate, parent and follow-up relations retain their own meanings; none becomes a required prerequisite merely because it appears next to one.

## Reconcile explicit Checklist prerequisite text

Reconciliation is a bounded service operation requested for this Checklist board, not a migration facility or an automatic prose parser. Inspect the latest source text, exact project-scoped identifiers, existing relation IDs, target states and affected current handlers before mutating. Add only explicitly listed prerequisite IDs, skip existing identical links, and let normal revision/cycle/scope guards reject conflicts. Keep the original brief/note intact and append a ticket note identifying the source text and resulting relation IDs. Statuses are not changed merely because a new link exposes a blocker.

Historical completed tickets and owner-cancelled assistant tickets retain their original planning context without retroactively introducing new work gates. If such text is obsolete, record the discrepancy for owner review rather than reinterpret it. Conversion receipts and the installation's exact identifiers are private verification material; they are not product defaults.

## Deliberately deferred fields

No duplicate editable `prerequisite_ids` store, automatic dependency inference, provider ownership tags, assistant assignees, generic custom-field language, required dates/estimates, or mandatory platform/build fields are introduced. A build or platform identity belongs in typed evidence/request data when the task actually needs it; the optional Playtest `build`/`platform` starter fields describe what to play, and they never stand in for an exact build approval target. Kind-specific starter fields (CL-68) use this same model without requiring metadata on every captured ticket.

Optional [playtest bundles](source-evidence.md#exact-build-playtest-bundles) live in the immutable submission evidence, rather than adding editable ticket fields. Their exact managed build ID/hash/version/platform and scenario/state/screenshot/log references are distinct from starter hints. Bundle pass/reject results use the existing `review_assessment.acceptance` rows against the captured acceptance revision; ordinary Draft capture and Ready remain possible without a bundle.
