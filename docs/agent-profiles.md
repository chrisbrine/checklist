# Existing personal assistants and future providers

**Cancelled extension.** Existing-host personal-assistant identity is retained as a historical contract from the scope cancelled on 22 October 2026 (CL-3 and CL-22), not planned work. The current app exposes no assistant connection/profile/grant UI; no named Dot integration is qualified or required for this release. Worker sessions remain attached to tickets.

The cancelled design proposed recognizing existing named personal assistants from supported hosts, such as a user's Dot in Codex. It does not create named workers, edit personalities or maintain a competing agent/persona catalog. Ordinary work is handled by actual Codex or Claude conversations and their real session identities. **Rowan** is a fictional example of a host-owned assistant name, not a built-in agent.

The cancelled access proposal used the first-party connected-Mac local MCP/plugin under owner project scopes. Its local Codex assistant relay/helper is an implemented component/path candidate, not proof of a completed cloud-Dot connection. It has no verified Dot/profile identity and remains outside named discovery; actual Dot plugin discovery/call/result, named identity and direct push were not qualified before cancellation. See [cancelled setup status](project-setup.md#cancelled-personal-assistant-integration).

## Identity comes from the host

| Record | Meaning | Does not establish |
|---|---|---|
| Host assistant identity | Verified host reference and its current name/avatar or descriptive metadata | A new Checklist persona, provider or permission grant |
| Local identity record | Stable `assistant_id` linking that verified existing assistant to historical attribution | Authority through a display name or personality |
| Provider/model | Actual host/vendor and observed model when exposed | A personal identity or authorization |
| Provider adapter | Installed protocol implementation and per-capability qualification | Support merely because an ID appears in JSON |
| Connection principal | Actual host/session generation bootstrapped through bundled CLI/MCP | Access to every project or other conversation |
| Project grants | Exact permitted actions for that connection | Human provenance or authority to self-expand |
| Native worker session | Actual Codex/Claude conversation or registered child handling work | A named assistant or proof of completion |
| Subscription | Selected events and the owner's reporting instruction | Task assignment, automatic writes or model-runtime control |

The local identity record is a compatibility/storage concept, not a profile-creation feature. Named-contact discovery includes only verified, supported host-owned personal assistants with current project/message grants. Legacy/manual/unverified profile records cannot become routable named agents. Ordinary worker session labels help identify work but are not added to the named-assistant directory.

An existing assistant uses `observer_messenger` access: inspect/report, requested Draft capture/notes/messages and selected notifications. It is never an assignee, worker, coordinator or reviewer. A matching name cannot promote a connection or attach a worker session to that identity. The same label may exist on different hosts; the directory disambiguates using verified host/connection/project details and exact operations use opaque current targets.

## Automatic connection and simple UI

The primary workflow starts in an existing or newly opened provider conversation. When that conversation uses the bundled Checklist CLI/MCP integration, bootstrap establishes its actual host/session/workspace identity and the allowed project context. It does not require manually creating or pairing a connection in Settings. Previously authorized project grants still apply; bootstrap cannot fabricate a host identity or grant an unknown workspace access merely from a label.

For a host-owned assistant, the adapter must prove the actual assistant identity through a supported mechanism. Without that proof, show **Identity unavailable** and omit it from named-contact discovery. An ordinary Codex worker, a self-reported name or a manually entered profile cannot stand in for a Dot. Real Dot bootstrap was not qualified before cancellation.

In the cancelled UI proposal, **Agents** would have shown recognized connected personal assistants and contact/history; this is absent from the current app. Name, avatar and personality belong to the host; Checklist displays supported metadata with its provenance and does not offer a name/personality editor or Create agent control. Host renames retain the stable host identity and historical display label at event time. Missing/changed identity requires reconciliation, never a name-based merge. The cancelled **Settings → Connections** proposal contained personal-assistant integrations only, showing their diagnostics/current scopes/capability and revoke/disconnect. Actual worker status, current/prior attempts, checkpoints, recovery and actions belong on the ticket; the internal worker registry is not a user-facing catalog.

To start worker handling from a ticket, **Use in Codex** or **Use in Claude** can open the installed provider and copy a brief with the scoped ticket reference. Creating or selecting the native conversation stays in that provider unless a real supported host API is qualified. The conversation connects automatically when it uses Checklist's bundled CLI/MCP. Opening a provider or copying text is a handoff, not proof a new native thread exists, is connected or claimed the ticket.

## Contact by name

After establishing Checklist context, “contact Rowan” resolves the permitted existing assistant through `agent_resolve` and sends through `agent_message_send`. Repeated app/MCP wording is unnecessary. Duplicate names require an unambiguous host/connection/project choice; unknown or unavailable identities return an honest limitation. Do not guess sockets, scan unrelated conversations or substitute another channel/runtime.

Use task history when relevant, or a project conversation without creating a ticket. The current human instruction or an existing applicable conversation grant must authorize the send/reply. Incoming agent text is not new human consent. Contact never assigns work. Saved, queued, transport accepted and actual recipient acknowledgment remain distinct.

## Versioned provider extension

Current source uses the [version-1 bundled plugin contract](provider-plugins.md) for provider/model metadata, actual host/bootstrap interpretation, supported transport and conversation handoff. Follow its controlled registration/qualification/update procedure for a future provider; unknown, incompatible, disabled or unqualified adapters/models remain unavailable. A plugin ID/version, observed model or [Triage orchestration](triage-orchestrators.md) cannot supply an identity, project grant or worker claim. The registry does not reactivate the cancelled assistant integration.

## Future adapters and persistent records

Initial work providers are Codex and Claude. The Codex Dot assistant candidate was cancelled; ordinary Codex MCP access never qualified it. A future host such as Muse remains deferred with unknown protocol, identity, messaging and notification support. Add an adapter later behind the same task/history contracts and qualify its real capability boundaries. Do not add an arbitrary code loader, persona platform, hidden CLI/API runtime or fallback provider.

SQLite stores minimal host-identity references/display snapshots separately from connections, grants, native generations and subscriptions; credentials remain in private owner-only files. Exports preserve only necessary historical attribution and permitted avatar copies, never host personality memory, credentials, endpoints or reusable grants. Import does not create an active assistant or map identity by name. Restore quarantines native routes until their actual host identities are revalidated through supported bootstrap.

The [assistant-identity schema](../contracts/assistant-identity.schema.json) and [example](../examples/assistant-identity.json) describe a read-only host presentation snapshot, including reported-versus-verified provenance and observed time; [assistant grants](../contracts/assistant-grant.schema.json) remain separate. JSON shape alone cannot establish host identity or connection authority. The cancelled acceptance proposal required automatic bootstrap, manual/unverified profile exclusion, host rename continuity, duplicate-name disambiguation, denied worker binding, grants/revocation, malicious metadata handling and real host delivery. Source support is not native-host qualification.
