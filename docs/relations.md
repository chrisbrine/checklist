# Ticket relations

Relations use stable IDs inside one project. The native ticket overlay adds, removes and opens linked tickets; opening a link uses the existing overlay Back stack. No title matching, diagram editor, task merge or automatic parent completion is involved.

`task_link` takes `project_id`, UUID `command_id`, `task_id`, the source ticket's `expected_revision`, and `action=add|remove`. Add requires `relation` and `target_task_id`; remove accepts the existing `relation_id` (including unresolved imported links), or the exact relation and target. A stale source revision, foreign project ID, self-link, repeated edge or dependency/parent/duplicate cycle rejects the whole command, including history and membership changes. `related_to` treats reversed endpoints as the same edge.

| Relation | Source → target meaning | Effect |
|---|---|---|
| `depends_on` | Dependent → prerequisite | Required by default; optional with `required=false` |
| `related_to` | Related tickets | Context only; symmetric |
| `parent_child` | Parent → child | Context only; parent cycles rejected |
| `duplicate_of` | Preserved duplicate → canonical ticket | Explicitly supersedes the source after active work is resolved |
| `follow_up_of` | New follow-up → original ticket | Independent work, preserving both histories |

Only an actual Done prerequisite satisfies a required edge. Canceled, reopened, trashed, superseded or unresolved prerequisites block claiming and completing the dependent. They never block marking it Ready or queueing it: Draft means the brief needs refinement, and Triage planning orders Queued work by its prerequisites. Eligibility is computed from current prerequisite records, so reopen/cancel takes effect immediately; it does not fabricate a dependent status change or undo historical completion. `prerequisite_blockers` gives safe ticket keys and an actionable reason. `pickup_eligible` and `effective_readiness` are projections; the stored readiness choice is retained. Metadata corrections remain possible while a previously Ready ticket is blocked.

Duplicate links retain the original notes, attachments, findings, attempts, review records and history. `canonical_task_id` follows explicit redirect IDs, and the original context remains readable. An active source claim or verification must be released/recovered first. Marking a duplicate records `disposition=superseded`, its redirect and an alias; it does not mark either ticket Done or resolve findings. Its superseded disposition removes the source from its Triage, as Done or canceled does (CL-125). Other relation edits retain membership. Removing a duplicate link preserves its already recorded superseded disposition and redirect. Explicit `task_transition action=reopen` restores open disposition and retires duplicate edges/aliases while retaining their history.

`relation_list` returns project-scoped active/unresolved edges and aliases, optionally for one ticket. Task context includes `relation_context`; the owner snapshot includes `relations` and `task_aliases`. Neither aliases nor matching titles select a target for a mutation.

The trusted owner or an enrolled worker while `agent_rule_changes=allowed` can use `relation_import`, with agent provenance for worker imports. It accepts an expected project revision plus `relations` and `aliases` arrays for tickets that have already been explicitly mapped. It performs no source reads or external migration. Relation and alias UUIDs remain stable; existing IDs and conflicting source namespaces/aliases are rejected. Source ticket IDs must resolve exactly. A known foreign target is rejected. An unknown target is retained as an unresolved edge with its original target ID/reference, and a required unresolved dependency blocks eligibility. No title or free-text guess resolves it. Cycle/alias failure rolls back the entire import. Removed historical edges remain removed.

Project export and consistent backup include full `relation` and `task_alias` records, including removed edges, retired aliases, unresolved references and original identifiers. A fresh-store importer explicitly maps task IDs before importing these records. This relation-only import does not provide full-store restore, revive claims, authenticate an imported actor or grant a live connection.
