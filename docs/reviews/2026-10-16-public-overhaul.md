# Generic public-reuse overhaul and critique

**16 October 2026.** This revises the complete planning baseline for a reusable macOS game/app production tool. The app/service are unbuilt. No source was published, license selected, provider installed/enrolled, message sent or event subscription created by this revision.

## Product and package changes

The assistant skill is **checklist-assistant**, with generic plugin/installation terminology. A chosen agent name is data, not a role, namespace or product integration. Named profiles hold optional avatar/pronouns/short descriptive personality hints, separate from provider/model/adapter, native session, authenticated principal and grants. The host owns actual persona/memory. Historical attribution keeps name/avatar/provider snapshots plus stable IDs.

Codex/Claude work and the initial Dot assistant adapter remain specific qualification targets. The registry permits future adapter references such as Muse without claiming a protocol, installed implementation or enabled capability. V1 adds no arbitrary downloaded adapter loader or marketplace. Assistant-only mode stays nonassignable: scoped checks/reports, requested Draft capture/notes/messages and selected owner notifications.

After an initial Checklist context, **contact Rowan** prefers the app automatically. Scoped resolution handles duplicate names, exact current opaque targets, unavailable routes and rename/rebinding. Messages use task history when appropriate or a project conversation without inventing a ticket/assignment. Participant-bound conversation bodies/history and direct acknowledgments work without ticket subscriptions. Requested single replies are bound to original authorization, not invented by inbound text.

Product docs, contracts, schemas/examples, plugin/skills, operational guides, storage, build/acceptance and synthetic concepts are aligned. Private source audits/native receipts/probes/old images/local grants remain ignored local history; public documentation uses synthetic material and does not link those files. An installation's self-build consent is never a blanket public-user grant.

## Fresh critique and applied fixes

| Finding | Applied contract correction |
|---|---|
| Scoped clients could infer unrelated activity from global sequence gaps | Global ordering stays private; opaque cursors bind to principal/project/filter/grant/incarnation. CURSOR_RESET requires an authorized snapshot/catch-up. |
| In-flight revocation implied stronger control than possible | Final pre-send generation check, unsent cancellation, best-effort in-flight stop, truthful sent/accepted chronology; no claim that remote bytes can be recalled. Later reads/replay reject revoked access. |
| Notification failures could notify their own failing route | Exclude same-route failure from its own stream; local/other chosen-route health with causal dedup. |
| Reconnect could trigger a report storm | Preserve source receipts/timestamps, coalesce obsolete same-ticket/cause events and use one bounded catch-up report while preserving unanswered requests. |
| Rename/personality/provider changes could rewrite authorship or transfer authority | Store historical display/provider snapshots alongside stable IDs. Rebinding needs reviewed pairing/grants; style cannot change policy/runtime. |
| Conflicting duplicate project grant entries could merge unpredictably | Reject duplicate project keys as a whole grant, with expected revision/generation. JSON uniqueItems handles exact duplicates only; service keyed validation remains required. |
| Future provider IDs could be mistaken for support | Registry references are data only; implemented/installed/paired/qualified capabilities required. Unknown/unqualified adapters stay unavailable. |
| Public self-build wording inherited a personal grant | Per-installation opt-in and private local authorization boundary; existing applicable local grants remain valid. |
| Ticketless contact had no explicit message/history/receipt path | Participant-scoped inbox bodies/history_list(conversation_id), exact direct delivery message_ack and overlay history; no fake task or subscription. |
| Communication grants were undefined and replies could inherit wrong notification settings | Sender project messaging permission and recipient receipt consent are explicit. Direct Messages/replies and optional Ticket updates are separate; original question may authorize one exact correlated reply. |
| Task-required events could not notify ticketless contact | Separate recipient-bound checklist.agent_message event with conversation/message IDs and optional task link; shared causal dedup avoids a duplicate linked-task notification. |

Each change has a corresponding observable acceptance scenario. No extra production-management suite, persona framework, cloud database or hidden model runtime was introduced.

## Validation and remaining proof

The [reproducible planning validator](../../scripts/validate-plan.py) passed on 16 October 2026: **7 schema/example pairs, 22 invalid-shape cases rejected, 58 candidate public files, 144 public Markdown links/anchors, 2 generic skills and 2 synthetic concepts; zero errors.** It also checked synthetic references, plugin structure and generated raster provenance. A separate public-text sweep found no personal names, source-project labels or concrete local identifiers. Neither check executes historical probes or product tools.

Independent re-review confirmed the semantic fixes and the four contact paths: participant-scoped history/body retrieval, exact direct-message acknowledgment, explicit communication grants, and direct replies independent of ticket updates. Its final event filter/payload naming mismatch was aligned across both contracts. Real packaging/service startup, store crashes, provider routes, persona binding, name resolution/contact, direct-message replies and assistant events remain implementation gates. A successful static package or one local historic transport sample is not a release qualification.

See [build plan](../build-plan.md), [acceptance](../acceptance.md) and [public-source boundary](../public-source.md).
